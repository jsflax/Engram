import RealityKit
import Foundation
import Metal
import simd
import EngramSceneKit

/// 48-byte vertex struct matching LowLevelMesh single-buffer layout (edges/labels).
struct BatchVertex {
    var px: Float, py: Float, pz: Float     // position (12)
    var nx: Float, ny: Float, nz: Float     // normal (12)
    var u: Float, v: Float                   // uv0 (8)
    var cr: Float, cg: Float, cb: Float, ca: Float  // color (16)
}

/// Three independent CPU upload buffers, each unavailable until its GPU command
/// completes. Reservation is nonblocking; saturation preserves the last complete
/// transform/color update instead of overwriting bytes that a blit may still read.
@MainActor
final class TextureUploadStagingPool {
    final class Slot: @unchecked Sendable {
        // Buffer ownership/access stays on MainActor. Only the busy flag crosses
        // to Metal's completion queue, protected by this short critical section.
        private let lock = NSLock()
        private var busy = false
        @MainActor private var buffer: MTLBuffer?
        @MainActor init() {}

        func reserve() -> Bool {
            lock.withLock {
                guard !busy else { return false }
                busy = true; return true
            }
        }
        func release() { lock.withLock { busy = false } }

        @MainActor func storage(device: MTLDevice, byteCount: Int) -> MTLBuffer? {
            guard byteCount > 0 else { return nil }
            if buffer == nil || buffer!.length < byteCount {
                buffer = device.makeBuffer(length: byteCount, options: .storageModeShared)
            }
            return buffer
        }
    }
    private let slots = (0..<3).map { _ in Slot() }
    func reserve() -> Slot? { slots.first { $0.reserve() } }
}

/// Last successfully admitted instance payload. This caches values, not the
/// lifetime of RealityKit resources, and does not suppress shader animation.
@MainActor
final class InstanceUploadState {
    struct Statistics: Equatable {
        var transforms = 0
        var colors = 0
        var counts = 0
    }
    private(set) var statistics = Statistics()
    private weak var entityOwner: AnyObject?
    private weak var dataOwner: AnyObject?
    private weak var textureOwner: AnyObject?
    private var lastTransforms: [simd_float4x4] = []
    private var lastColors: [SIMD4<Float16>] = []

    // Element comparisons deliberately preserve IEEE NaN inequality. A raw
    // input containing NaN must never become an apparently unchanged frame.
    static func sameTransforms(_ lhs: [simd_float4x4], _ rhs: [simd_float4x4]) -> Bool {
        lhs.elementsEqual(rhs, by: { $0 == $1 })
    }
    static func sameColors(_ lhs: [SIMD4<Float16>], _ rhs: [SIMD4<Float16>]) -> Bool {
        lhs.elementsEqual(rhs, by: { $0 == $1 })
    }

    func matches(entity: AnyObject, data: AnyObject, texture: AnyObject) -> Bool {
        entityOwner === entity && dataOwner === data && textureOwner === texture
    }

    @available(macOS 26, iOS 26, *)
    func hide(_ data: LowLevelInstanceData) {
        if data.instanceCount != 0 {
            data.instanceCount = 0
            statistics.counts += 1
        }
    }

    /// nil rejects the entire update before publication; otherwise the Bool
    /// says whether completion now owns the caller's staging lease.
    @available(macOS 26, iOS 26, *)
    func publish(
        transforms: [simd_float4x4], colors: [SIMD4<Float16>],
        entity: ModelEntity, data: LowLevelInstanceData, texture: LowLevelTexture,
        device: MTLDevice, command: MTLCommandBuffer, upload: TextureUploadStagingPool.Slot
    ) -> Bool? {
        let sameResources = matches(entity: entity, data: data, texture: texture)
        let replaceTransforms = !sameResources || !Self.sameTransforms(transforms, lastTransforms)
        let replaceColors = !sameResources || !Self.sameColors(colors, lastColors)
        precondition(transforms.count <= data.instanceCapacity)

        let encodesUpload = replaceTransforms || replaceColors
        if encodesUpload {
            let width = texture.descriptor.width, height = texture.descriptor.height
            let rowBytes = width * MemoryLayout<SIMD4<Float16>>.stride
            let colorBytes = rowBytes * height
            let transformBytes = data.instanceCapacity * MemoryLayout<simd_float4x4>.stride
            // Keep texture copies aligned even for small/odd instance capacities.
            let colorOffset = (transformBytes + 255) & ~255
            precondition(colors.count * MemoryLayout<SIMD4<Float16>>.stride == colorBytes)
            // Acquire every fallible dependency before either RealityKit
            // replacement. One completion-owned slot contains both payloads.
            guard let staging = upload.storage(device: device, byteCount: colorOffset + colorBytes),
                  let blit = command.makeBlitCommandEncoder() else { return nil }
            if replaceTransforms {
                let matrices = staging.contents().bindMemory(to: simd_float4x4.self,
                    capacity: data.instanceCapacity)
                let collapsed = simd_float4x4(diagonal: SIMD4<Float>(0, 0, 0, 1))
                for index in 0..<data.instanceCapacity { matrices[index] = collapsed }
                for index in transforms.indices { matrices[index] = transforms[index] }
                // Write this replacement only through the GPU. The same command
                // owns both this transform blit and the optional color blit.
                let destination = data.replace(using: command)
                precondition(destination.length >= transformBytes)
                blit.copy(from: staging, sourceOffset: 0, to: destination,
                    destinationOffset: 0, size: transformBytes)
                statistics.transforms += 1
            }
            if replaceColors {
                colors.withUnsafeBytes { source in
                    staging.contents().advanced(by: colorOffset).copyMemory(
                        from: source.baseAddress!, byteCount: colorBytes)
                }
                let destination = texture.replace(using: command)
                blit.copy(from: staging, sourceOffset: colorOffset, sourceBytesPerRow: rowBytes,
                    sourceBytesPerImage: colorBytes,
                    sourceSize: MTLSize(width: width, height: height, depth: 1),
                    to: destination, destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                statistics.colors += 1
            }
            blit.endEncoding()
            command.addCompletedHandler { [weak self] command in
                upload.release()
                if command.status == .error {
                    Task { @MainActor [weak self] in self?.entityOwner = nil }
                }
            }
        }
        if data.instanceCount != transforms.count {
            data.instanceCount = transforms.count
            statistics.counts += 1
        }
        if !entity.isEnabled { entity.isEnabled = true }
        entityOwner = entity
        dataOwner = data
        textureOwner = texture
        lastTransforms = transforms
        lastColors = colors
        return encodesUpload
    }
}

/// Instanced node rendering system.
///
/// macOS selects the existing LowLevelMesh path for this candidate.
/// iOS retains the following availability-based selection:
/// - **macOS 26+**: `MeshInstanceCollection` — true GPU instancing with per-instance
///   transforms and visual data in a `LowLevelTexture`.
/// - **< macOS 26**: Two-buffer `LowLevelMesh` — buffer 0 holds static template geometry
///   (written once), buffer 1 holds per-instance data (32 bytes/vert, written per frame).
///   A geometry modifier transforms template verts to world positions on GPU.
///
/// Compared to the old single-buffer approach (48 bytes × 60 verts × N = 2,880N bytes/frame),
/// the two-buffer path writes 32 bytes × 60 verts × N = 1,920N bytes/frame (33% reduction)
/// and eliminates CPU-side position math (offset added on GPU by geometry modifier).
@MainActor
public final class NodeBatchSystem {
    // Candidate macOS containment: keep one native mesh backend for this scene.
    // iOS retains its existing availability-based instancing selection.
    #if os(macOS)
    private static let usesMeshInstances = false
    #else
    private static let usesMeshInstances = true
    #endif

    /// Reusable staging array for buffer 1 — avoids per-frame allocation.
    private var instanceStaging: [LowLevelMeshFactory.NodeInstanceAttribs] = []
    private let textureUploads = TextureUploadStagingPool()
    private let instanceUploads = InstanceUploadState()
    var instanceUploadStatistics: InstanceUploadState.Statistics { instanceUploads.statistics }

    // Stable instance-slot assignment (macOS-26 instanced path). A node keeps
    // its slot for as long as it stays visible. The transform and color blits
    // share a command, and stable slots also preserve their node association
    // through LOD churn without remapping every visible slot each frame.
    private var slotForNode: [Int: Int] = [:]
    private var slotHighWater = 0
    private var freeSlots: [Int] = []
    private var slotsTopologyVersion: UInt64 = .max

    public init() {}

    public func update(
        scene: EngramRealityScene,
        dataProvider: SceneDataProvider,
        visibleSet: VisibleSet,
        topologyChanged: Bool,
        animationTime: Float,
        scaleFactor: Float,
        commandBuffer: MTLCommandBuffer? = nil
    ) {
        let hasVisibleItems = visibleSet.totalNodeCount > 0
        scene.nodeBatchEntity?.isEnabled = hasVisibleItems
        if #available(macOS 26, iOS 26, *), Self.usesMeshInstances {
            if !hasVisibleItems { scene.nodeTemplateEntity?.isEnabled = false }
            if !hasVisibleItems, let data = scene.nodeInstanceData {
                instanceUploads.hide(data)
            }
        }
        // Preserve mesh/component ownership while an empty filter hides the batch.
        // Returning without hiding it leaves the preceding frame on screen.
        guard hasVisibleItems else { return }
        if #available(macOS 26, iOS 26, *), Self.usesMeshInstances {
            updateWithMeshInstances(
                scene: scene, dataProvider: dataProvider,
                visibleSet: visibleSet, animationTime: animationTime,
                scaleFactor: scaleFactor, commandBuffer: commandBuffer
            )
        } else {
            updateWithTwoBufferMesh(
                scene: scene, dataProvider: dataProvider,
                visibleSet: visibleSet, animationTime: animationTime,
                scaleFactor: scaleFactor, commandBuffer: commandBuffer
            )
        }
    }

    // MARK: - < macOS 26: Two-buffer LowLevelMesh + Geometry Modifier

    /// Two-buffer path: buffer 0 = static template (written once by LowLevelMeshFactory),
    /// buffer 1 = per-instance transform + visual data (written per frame here).
    /// The geometry modifier reads buffer 1 attributes to transform template verts on GPU.
    func updateWithTwoBufferMesh(
        scene: EngramRealityScene,
        dataProvider: SceneDataProvider,
        visibleSet: VisibleSet,
        animationTime: Float,
        scaleFactor: Float,
        commandBuffer: MTLCommandBuffer? = nil
    ) {
        let visibleCount = visibleSet.totalNodeCount
        guard visibleCount > 0 else { return }

        LowLevelMeshFactory.ensureNodeBatchMesh(scene: scene, capacity: visibleCount)
        guard let mesh = scene.nodeBatchMesh, scene.nodeBatchCapacity >= visibleCount else { return }

        let nodes = dataProvider.nodes
        let positions = dataProvider.positions
        let positionArray = dataProvider.positionArray
        let dyingNodes = dataProvider.dyingNodes
        let colorMap = dataProvider.projectColorMap
        let vps = scene.vertsPerSphere

        // Ensure staging buffer is large enough (one attrib struct per vertex)
        let totalVerts = scene.nodeBatchCapacity * vps
        if instanceStaging.count < totalVerts {
            instanceStaging = [LowLevelMeshFactory.NodeInstanceAttribs](
                repeating: LowLevelMeshFactory.NodeInstanceAttribs(
                    ox: 0, oy: 0, oz: 0, scale: 0,
                    cr: 0, cg: 0, cb: 0, packedAlpha: 0
                ),
                count: totalVerts
            )
        }

        // One synchronous borrow avoids repeated array COW/exclusivity checks per vertex.
        instanceStaging.withUnsafeMutableBufferPointer { destination in
            precondition(totalVerts <= destination.count)
            var instanceIdx = 0

            let glowingNodes = dataProvider.glowingNodes
            let newNodeGlows = dataProvider.newNodeGlows
            let selectedNode = dataProvider.selectedNode
            let searchMatchIds = dataProvider.searchMatchIds
            let isSearchActive = dataProvider.isSearchActive

            func writeNode(nodeIndex: Int) {
                let node = nodes[nodeIndex]
                let pos = nodeIndex < positionArray.count ? positionArray[nodeIndex] : (positions[node.id] ?? .zero)

                let scaledPos = pos * scaleFactor
                var color = colorMap[node.project] ?? SIMD3<Float>(0.5, 0.5, 0.5)
                let baseRadius: Float = node.isHub ? 12.0 : 8.0
                let radius = baseRadius * scaleFactor

                // Dying nodes: dim the color (shader has no separate dying opacity)
                if dyingNodes.contains(node.id) {
                    color *= 0.3
                }

                // Compute packed visual state for the surface shader:
                //   stateType + intensity * 0.01  (+ 10.0 if search-dimmed)
                //   stateType: 0=normal, 0.25=selected, 0.5=recall, 0.75=arrival, 1.0=search match
                //   Intensity occupies 0.00–0.01 range within each 0.25-wide state band.
                var packedState: Float = 0.0
                if searchMatchIds.contains(node.id) {
                    packedState = 1.0
                } else if let elapsed = newNodeGlows[node.id] {
                    let intensity = arrivalGlowIntensity(elapsed: elapsed)
                    packedState = 0.75 + intensity * 0.01
                } else if let elapsed = glowingNodes[node.id] {
                    let intensity = recallGlowIntensity(elapsed: elapsed)
                    packedState = 0.5 + intensity * 0.01
                } else if selectedNode == node.id {
                    packedState = 0.25 + 0.5 * 0.01
                }

                // Search dimming: non-matched nodes during active search
                if isSearchActive && !searchMatchIds.contains(node.id) {
                    packedState += 10.0
                }

                // Build per-instance attribs (same value for each template vertex)
                let attrib = LowLevelMeshFactory.NodeInstanceAttribs(
                    ox: scaledPos.x, oy: scaledPos.y, oz: scaledPos.z, scale: radius,
                    cr: color.x, cg: color.y, cb: color.z, packedAlpha: packedState
                )

                // Fill all verts for this instance with the same attribs
                let baseVert = instanceIdx * vps
                for vi in 0..<vps {
                    destination[baseVert + vi] = attrib
                }
                instanceIdx += 1
            }

            for idx in visibleSet.nearNodes { writeNode(nodeIndex: idx) }
            for idx in visibleSet.midNodes { writeNode(nodeIndex: idx) }
            for idx in visibleSet.farNodes { writeNode(nodeIndex: idx) }

            // Zero remaining instances
            let usedVerts = instanceIdx * vps
            if usedVerts < totalVerts {
                let zeroAttrib = LowLevelMeshFactory.NodeInstanceAttribs(
                    ox: 0, oy: 0, oz: 0, scale: 0,
                    cr: 0, cg: 0, cb: 0, packedAlpha: 0
                )
                destination.baseAddress!.advanced(by: usedVerts).update(repeating: zeroAttrib, count: totalVerts - usedVerts)
            }
        }

        // CPU replacement owns writable storage only for this synchronous callback.
        // replace(bufferIndex:using:) is reserved for GPU writes, not CPU contents().
        mesh.replaceUnsafeMutableBytes(bufferIndex: 1) { destination in
            instanceStaging.withUnsafeBytes { source in
                let byteCount = totalVerts * MemoryLayout<LowLevelMeshFactory.NodeInstanceAttribs>.stride
                precondition(byteCount <= destination.count && byteCount <= source.count)
                destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: byteCount)
            }
        }
    }

    // MARK: - macOS 26+: MeshInstanceCollection

    /// MeshInstanceCollection path: one sphere template mesh, N instance transforms.
    /// Per-instance visual data (color, alpha) stored in a LowLevelTexture sampled
    /// by the geometry modifier using instance_id().
    @available(macOS 26, iOS 26, *)
    private func updateWithMeshInstances(
        scene: EngramRealityScene,
        dataProvider: SceneDataProvider,
        visibleSet: VisibleSet,
        animationTime: Float,
        scaleFactor: Float,
        commandBuffer: MTLCommandBuffer? = nil
    ) {
        let visibleCount = visibleSet.totalNodeCount
        guard visibleCount > 0 else { return }

        // Reserve before touching resources, stable slots, or transforms. The
        // caller may supply an uncommitted frame command, so elapsed frames do
        // not establish that its previous staging bytes are reusable.
        guard let upload = textureUploads.reserve() else { return }
        var submitted = false
        defer { if !submitted { upload.release() } }
        guard let cmdBuf = commandBuffer ?? scene.commandQueue.makeCommandBuffer() else { return }

        // Ensure sphere template entity and instance texture exist
        scene.ensureNodeInstanceResources(capacity: visibleCount)
        guard let entity = scene.nodeTemplateEntity,
              let instanceData = scene.nodeInstanceData,
              let instanceTexture = scene.nodeInstanceTexture else {
            return
        }

        let nodes = dataProvider.nodes
        let positions = dataProvider.positions
        let positionArray = dataProvider.positionArray
        let dyingNodes = dataProvider.dyingNodes
        let colorMap = dataProvider.projectColorMap
        let glowingNodes = dataProvider.glowingNodes
        let newNodeGlows = dataProvider.newNodeGlows
        let selectedNode = dataProvider.selectedNode
        let searchMatchIds = dataProvider.searchMatchIds
        let isSearchActive = dataProvider.isSearchActive

        // Build per-instance visual data for texture
        let texWidth = scene.nodeInstanceTextureWidth
        var texData = [SIMD4<Float16>](repeating: .zero, count: texWidth)

        // Plan slot changes locally. Failed texture admission must not publish
        // a new mapping or cache payload while the previous pair is still drawn.
        var slotForNode = self.slotForNode
        var slotHighWater = self.slotHighWater
        var freeSlots = self.freeSlots
        var slotsTopologyVersion = self.slotsTopologyVersion
        // --- Stable slot maintenance ---
        // Node indices remap on topology change: reset the mapping.
        if dataProvider.topologyVersion != slotsTopologyVersion
            || !instanceUploads.matches(entity: entity, data: instanceData, texture: instanceTexture) {
            slotsTopologyVersion = dataProvider.topologyVersion
            slotForNode.removeAll(keepingCapacity: true)
            freeSlots.removeAll(keepingCapacity: true)
            slotHighWater = 0
        }
        let capacity = instanceData.instanceCapacity
        var visibleBits = [Bool](repeating: false, count: nodes.count)
        for idx in visibleSet.nearNodes where idx < nodes.count { visibleBits[idx] = true }
        for idx in visibleSet.midNodes where idx < nodes.count { visibleBits[idx] = true }
        for idx in visibleSet.farNodes where idx < nodes.count { visibleBits[idx] = true }
        // Free slots of nodes that left the visible set.
        var freed: [Int] = []
        slotForNode = slotForNode.filter { (nodeIndex, slot) in
            if nodeIndex < visibleBits.count && visibleBits[nodeIndex] { return true }
            freed.append(slot)
            return false
        }
        freeSlots.append(contentsOf: freed)
        var occupied = [Bool](repeating: false, count: min(slotHighWater, capacity))
        // Plan writes as (slot, nodeIndex) in tier order.
        var writes: [(slot: Int, nodeIndex: Int)] = []
        writes.reserveCapacity(visibleCount)
        func assignSlot(_ nodeIndex: Int) {
            let slot: Int
            if let existing = slotForNode[nodeIndex] {
                slot = existing
            } else if let reused = freeSlots.popLast() {
                slot = reused
                slotForNode[nodeIndex] = reused
            } else if slotHighWater < capacity {
                slot = slotHighWater
                slotHighWater += 1
                slotForNode[nodeIndex] = slot
            } else {
                return  // over budget — LOD already caps at capacity
            }
            if slot < occupied.count { occupied[slot] = true }
            writes.append((slot, nodeIndex))
        }
        for idx in visibleSet.nearNodes { assignSlot(idx) }
        for idx in visibleSet.midNodes { assignSlot(idx) }
        for idx in visibleSet.farNodes { assignSlot(idx) }
        let slotWrites = writes
        let holes = occupied.enumerated().compactMap { $1 ? nil : $0 }
        let usedCount = min(slotHighWater, capacity)

        var transforms = [simd_float4x4](repeating:
            simd_float4x4(diagonal: SIMD4<Float>(0, 0, 0, 1)), count: usedCount)
        func writeNode(slot: Int, nodeIndex: Int) {
            guard slot < transforms.count, slot < texData.count else { return }
            let instanceIdx = slot
            let node = nodes[nodeIndex]
            let pos = nodeIndex < positionArray.count ? positionArray[nodeIndex] : (positions[node.id] ?? .zero)

            let scaledPos = pos * scaleFactor
            let baseRadius: Float = node.isHub ? 12.0 : 8.0
            let radius = baseRadius * scaleFactor
            var color = colorMap[node.project] ?? SIMD3<Float>(0.5, 0.5, 0.5)

            if dyingNodes.contains(node.id) { color *= 0.3 }

            // Compute packed visual state (same encoding as two-buffer path)
            var packedState: Float = 0.0
            if searchMatchIds.contains(node.id) {
                packedState = 1.0
            } else if let elapsed = newNodeGlows[node.id] {
                let intensity = arrivalGlowIntensity(elapsed: elapsed)
                packedState = 0.75 + intensity * 0.01
            } else if let elapsed = glowingNodes[node.id] {
                let intensity = recallGlowIntensity(elapsed: elapsed)
                packedState = 0.5 + intensity * 0.01
            } else if selectedNode == node.id {
                packedState = 0.25 + 0.5 * 0.01
            }
            if isSearchActive && !searchMatchIds.contains(node.id) {
                packedState += 10.0
            }

            let s = simd_float4x4(diagonal: SIMD4<Float>(radius, radius, radius, 1.0))
            let t = simd_float4x4(columns: (
                SIMD4<Float>(1, 0, 0, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(0, 0, 1, 0),
                SIMD4<Float>(scaledPos.x, scaledPos.y, scaledPos.z, 1)
            ))
            transforms[instanceIdx] = t * s

            texData[instanceIdx] = SIMD4<Float16>(
                Float16(color.x), Float16(color.y), Float16(color.z), Float16(packedState)
            )
        }

        for w in slotWrites { writeNode(slot: w.slot, nodeIndex: w.nodeIndex) }

        // Collapse holes left by departed nodes (robust to RealityKit
        // re-reading stale slots): zero-scale transform renders nothing.
        for slot in holes where slot < transforms.count {
            transforms[slot] = simd_float4x4(diagonal: SIMD4<Float>(0, 0, 0, 1))
            if slot < texData.count { texData[slot] = .zero }
        }

        guard let ownsLease = instanceUploads.publish(
            transforms: transforms, colors: texData, entity: entity, data: instanceData,
            texture: instanceTexture, device: scene.device, command: cmdBuf, upload: upload
        ) else { return }
        self.slotForNode = slotForNode
        self.slotHighWater = slotHighWater
        self.freeSlots = freeSlots
        self.slotsTopologyVersion = slotsTopologyVersion
        submitted = ownsLease
        if ownsLease && commandBuffer == nil { cmdBuf.commit() }
    }
}
