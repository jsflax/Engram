import RealityKit
import Metal
import simd
import EngramSceneKit

/// Instanced edge rendering — 6-sided cylinder per edge.
///
/// macOS selects the existing LowLevelMesh path for this candidate.
/// iOS retains the following availability-based selection:
/// - **macOS 26+**: `MeshInstanceCollection` — one unit cylinder template, N instance
///   transforms encoding position + rotation + scale. Visual data in `LowLevelTexture`.
/// - **< macOS 26**: Single-buffer `LowLevelMesh` — full vertex data per edge (existing approach).
///   No two-buffer optimization here since edge cylinder geometry needs 48 bytes/vert anyway.
@MainActor
public final class EdgeBatchSystem {
    // Candidate macOS containment: keep one native mesh backend for this scene.
    // iOS retains its existing availability-based instancing selection.
    #if os(macOS)
    private static let usesMeshInstances = false
    #else
    private static let usesMeshInstances = true
    #endif

    private static let sides = 6
    private static let vertsPerEdge = sides * 2  // 12
    private static let indicesPerEdge = sides * 6 // 36

    private var staging: [BatchVertex] = []
    private let textureUploads = TextureUploadStagingPool()
    private let instanceUploads = InstanceUploadState()
    var instanceUploadStatistics: InstanceUploadState.Statistics { instanceUploads.statistics }

    // Stable instance-slot assignment — see NodeBatchSystem: keeps per-slot
    // color and transform associated per EDGE across frames of LOD churn.
    private var slotForEdge: [Int: Int] = [:]
    private var slotHighWater = 0
    private var freeSlots: [Int] = []
    private var slotsTopologyVersion: UInt64 = .max

    /// Cached node→project mapping — rebuilt only on topology change.
    private var cachedNodeProject: [UUID: String] = [:]
    /// Cached node UUID→positionArray index mapping — rebuilt only on topology change.
    private var nodeIdToIndex: [UUID: Int] = [:]
    private var lastTopologyVersion: UInt64 = 0

    /// Precomputed sin/cos for 6-sided cylinder (same every frame).
    private static let sideAngles: [(c: Float, s: Float)] = (0..<sides).map { i in
        let angle = Float(i) / Float(sides) * 2.0 * .pi
        return (cos(angle), sin(angle))
    }

    public init() {}

    public func update(
        scene: EngramRealityScene,
        dataProvider: SceneDataProvider,
        visibleSet: VisibleSet,
        topologyChanged: Bool,
        scaleFactor: Float,
        commandBuffer: MTLCommandBuffer? = nil
    ) {
        let hasVisibleItems = visibleSet.visibleEdgeIndices.count > 0
        scene.edgeBatchEntity?.isEnabled = hasVisibleItems
        if #available(macOS 26, iOS 26, *), Self.usesMeshInstances {
            if !hasVisibleItems { scene.edgeTemplateEntity?.isEnabled = false }
            if !hasVisibleItems, let data = scene.edgeInstanceData {
                instanceUploads.hide(data)
            }
        }
        // Preserve mesh/component ownership while an empty filter hides the batch.
        // Returning without hiding it leaves the preceding frame on screen.
        guard hasVisibleItems else { return }
        if #available(macOS 26, iOS 26, *), Self.usesMeshInstances {
            updateWithMeshInstances(
                scene: scene, dataProvider: dataProvider,
                visibleSet: visibleSet, scaleFactor: scaleFactor,
                commandBuffer: commandBuffer
            )
        } else {
            updateCurrentApproach(
                scene: scene, dataProvider: dataProvider,
                visibleSet: visibleSet, scaleFactor: scaleFactor,
                commandBuffer: commandBuffer
            )
        }
    }

    // MARK: - < macOS 26: Single-buffer LowLevelMesh (existing approach)

    func updateCurrentApproach(
        scene: EngramRealityScene,
        dataProvider: SceneDataProvider,
        visibleSet: VisibleSet,
        scaleFactor: Float,
        commandBuffer: MTLCommandBuffer? = nil
    ) {
        let visibleCount = visibleSet.visibleEdgeIndices.count
        guard visibleCount > 0 else { return }

        LowLevelMeshFactory.ensureEdgeBatchMesh(scene: scene, capacity: visibleCount)
        guard let mesh = scene.edgeBatchMesh, scene.edgeBatchCapacity >= visibleCount else { return }

        let edges = dataProvider.edges
        let positions = dataProvider.positions
        let selectedNode = dataProvider.selectedNode
        let colorMap = dataProvider.projectColorMap
        let nodes = dataProvider.nodes
        let isSearchActive = dataProvider.isSearchActive
        let searchMatchIds = dataProvider.searchMatchIds

        // Rebuild node→project and node→index caches only on topology change
        let topoVersion = dataProvider.topologyVersion
        if topoVersion != lastTopologyVersion {
            lastTopologyVersion = topoVersion
            cachedNodeProject.removeAll(keepingCapacity: true)
            nodeIdToIndex.removeAll(keepingCapacity: true)
            for (i, node) in nodes.enumerated() {
                cachedNodeProject[node.id] = node.project
                nodeIdToIndex[node.id] = i
            }
        }
        let nodeProject = cachedNodeProject
        let positionArray = dataProvider.positionArray
        let idToIndex = nodeIdToIndex

        let totalVerts = scene.edgeBatchCapacity * Self.vertsPerEdge
        if staging.count < totalVerts {
            staging = [BatchVertex](repeating: BatchVertex(
                px: 0, py: 0, pz: 0, nx: 0, ny: 0, nz: 0,
                u: 0, v: 0, cr: 0, cg: 0, cb: 0, ca: 0
            ), count: totalVerts)
        }

        // One synchronous borrow avoids repeated array COW/exclusivity checks per vertex.
        staging.withUnsafeMutableBufferPointer { destination in
            precondition(totalVerts <= destination.count)
            var instanceIdx = 0
            for edgeIdx in visibleSet.visibleEdgeIndices {
                let edge = edges[edgeIdx]
                let srcPos: SIMD3<Float>
                let tgtPos: SIMD3<Float>
                if let si = idToIndex[edge.sourceId], si < positionArray.count,
                   let ti = idToIndex[edge.targetId], ti < positionArray.count {
                    srcPos = positionArray[si]
                    tgtPos = positionArray[ti]
                } else {
                    guard let sp = positions[edge.sourceId], let tp = positions[edge.targetId] else { continue }
                    srcPos = sp; tgtPos = tp
                }

                let src = srcPos * scaleFactor
                let tgt = tgtPos * scaleFactor

                let project = nodeProject[edge.sourceId]
                var color = colorMap[project ?? ""] ?? SIMD3<Float>(0.6, 0.6, 0.6)
                color = min(color * 1.4 + 0.15, SIMD3<Float>(repeating: 1.0))

                var alpha: Float = 0.35
                if let sel = selectedNode {
                    if edge.sourceId == sel || edge.targetId == sel { alpha = 0.8 }
                    else { alpha = 0.15 }
                }
                if isSearchActive {
                    let srcMatch = searchMatchIds.contains(edge.sourceId)
                    let tgtMatch = searchMatchIds.contains(edge.targetId)
                    if !srcMatch && !tgtMatch { alpha *= 0.2 }
                }

                let dir = tgt - src
                let length = simd_length(dir)
                guard length > 0.0001 else { continue }
                let axis = dir / length

                let tempUp: SIMD3<Float> = abs(axis.y) < 0.99 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
                let right = normalize(cross(axis, tempUp))
                let up = cross(right, axis)
                let radius: Float = 1.0 * scaleFactor

                let baseVert = instanceIdx * Self.vertsPerEdge
                for s in 0..<Self.sides {
                    let (c, sn) = Self.sideAngles[s]
                    let normal = right * c + up * sn
                    let offset = normal * radius

                    let botPos = src + offset
                    destination[baseVert + s] = BatchVertex(
                        px: botPos.x, py: botPos.y, pz: botPos.z,
                        nx: normal.x, ny: normal.y, nz: normal.z,
                        u: Float(s) / Float(Self.sides), v: 0,
                        cr: color.x, cg: color.y, cb: color.z, ca: alpha
                    )

                    let topPos = tgt + offset
                    destination[baseVert + Self.sides + s] = BatchVertex(
                        px: topPos.x, py: topPos.y, pz: topPos.z,
                        nx: normal.x, ny: normal.y, nz: normal.z,
                        u: Float(s) / Float(Self.sides), v: 1,
                        cr: color.x, cg: color.y, cb: color.z, ca: alpha
                    )
                }
                instanceIdx += 1
            }

            // Zero remaining
            let usedVerts = instanceIdx * Self.vertsPerEdge
            if usedVerts < totalVerts {
                let zeroVertex = BatchVertex(
                    px: 0, py: 0, pz: 0, nx: 0, ny: 0, nz: 0,
                    u: 0, v: 0, cr: 0, cg: 0, cb: 0, ca: 0
                )
                destination.baseAddress!.advanced(by: usedVerts).update(repeating: zeroVertex, count: totalVerts - usedVerts)
            }
        }

        // CPU replacement owns writable storage only for this synchronous callback.
        // replace(bufferIndex:using:) is reserved for GPU writes, not CPU contents().
        mesh.replaceUnsafeMutableBytes(bufferIndex: 0) { destination in
            staging.withUnsafeBytes { source in
                let byteCount = totalVerts * MemoryLayout<BatchVertex>.stride
                precondition(byteCount <= destination.count && byteCount <= source.count)
                destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: byteCount)
            }
        }
    }

    // MARK: - macOS 26+: MeshInstanceCollection

    /// MeshInstanceCollection path: one unit cylinder template, N instance transforms.
    /// Each transform encodes: translate(src) × rotate(Y→direction) × scale(radius, length, radius).
    /// Per-instance visual data (color, alpha) stored in a LowLevelTexture.
    @available(macOS 26, iOS 26, *)
    private func updateWithMeshInstances(
        scene: EngramRealityScene,
        dataProvider: SceneDataProvider,
        visibleSet: VisibleSet,
        scaleFactor: Float,
        commandBuffer: MTLCommandBuffer? = nil
    ) {
        let visibleCount = visibleSet.visibleEdgeIndices.count
        guard visibleCount > 0 else { return }

        // Reserve before touching resources, stable slots, or transforms. The
        // caller may supply an uncommitted frame command, so elapsed frames do
        // not establish that its previous staging bytes are reusable.
        guard let upload = textureUploads.reserve() else { return }
        var submitted = false
        defer { if !submitted { upload.release() } }
        guard let cmdBuf = commandBuffer ?? scene.commandQueue.makeCommandBuffer() else { return }

        // Ensure cylinder template entity and instance texture exist
        scene.ensureEdgeInstanceResources(capacity: visibleCount)
        guard let entity = scene.edgeTemplateEntity,
              let instanceData = scene.edgeInstanceData,
              let instanceTexture = scene.edgeInstanceTexture else {
            return
        }

        let edges = dataProvider.edges
        let positions = dataProvider.positions
        let selectedNode = dataProvider.selectedNode
        let colorMap = dataProvider.projectColorMap
        let nodes = dataProvider.nodes
        let isSearchActive = dataProvider.isSearchActive
        let searchMatchIds = dataProvider.searchMatchIds

        // Rebuild node→project and node→index caches only on topology change
        let topoVersion = dataProvider.topologyVersion
        if topoVersion != lastTopologyVersion {
            lastTopologyVersion = topoVersion
            cachedNodeProject.removeAll(keepingCapacity: true)
            nodeIdToIndex.removeAll(keepingCapacity: true)
            for (i, node) in nodes.enumerated() {
                cachedNodeProject[node.id] = node.project
                nodeIdToIndex[node.id] = i
            }
        }
        let nodeProject = cachedNodeProject
        let positionArray = dataProvider.positionArray
        let idToIndex = nodeIdToIndex

        let texWidth = instanceTexture.descriptor.width
        let texHeight = instanceTexture.descriptor.height
        var texData = [SIMD4<Float16>](repeating: .zero, count: texWidth * texHeight)

        // Plan slot changes locally. Failed texture admission must not publish
        // a new mapping or cache payload while the previous pair is still drawn.
        var slotForEdge = self.slotForEdge
        var slotHighWater = self.slotHighWater
        var freeSlots = self.freeSlots
        var slotsTopologyVersion = self.slotsTopologyVersion
        // --- Stable slot maintenance (see NodeBatchSystem) ---
        if dataProvider.topologyVersion != slotsTopologyVersion
            || !instanceUploads.matches(entity: entity, data: instanceData, texture: instanceTexture) {
            slotsTopologyVersion = dataProvider.topologyVersion
            slotForEdge.removeAll(keepingCapacity: true)
            freeSlots.removeAll(keepingCapacity: true)
            slotHighWater = 0
        }
        let capacity = instanceData.instanceCapacity
        let visibleEdgeSet = Set(visibleSet.visibleEdgeIndices)
        var freed: [Int] = []
        slotForEdge = slotForEdge.filter { (edgeIdx, slot) in
            if visibleEdgeSet.contains(edgeIdx) { return true }
            freed.append(slot)
            return false
        }
        freeSlots.append(contentsOf: freed)
        var occupied = [Bool](repeating: false, count: min(slotHighWater, capacity))
        var writes: [(slot: Int, edgeIdx: Int)] = []
        writes.reserveCapacity(min(visibleCount, capacity))
        for edgeIdx in visibleSet.visibleEdgeIndices {
            let slot: Int
            if let existing = slotForEdge[edgeIdx] {
                slot = existing
            } else if let reused = freeSlots.popLast() {
                slot = reused
                slotForEdge[edgeIdx] = reused
            } else if slotHighWater < capacity {
                slot = slotHighWater
                slotHighWater += 1
                slotForEdge[edgeIdx] = slot
            } else {
                continue
            }
            if slot < occupied.count { occupied[slot] = true }
            writes.append((slot, edgeIdx))
        }
        let slotWrites = writes
        let holes = occupied.enumerated().compactMap { $1 ? nil : $0 }
        let usedCount = min(slotHighWater, capacity)

        var transforms = [simd_float4x4](repeating:
            simd_float4x4(diagonal: SIMD4<Float>(0, 0, 0, 1)), count: usedCount)
        for (slot, edgeIdx) in slotWrites {
            let instanceIdx = slot
            guard instanceIdx < transforms.count, instanceIdx < texData.count else { continue }
            // Replacement storage is unspecified. Even a skipped occupied
            // slot needs a finite, collapsed transform for this frame.
            transforms[instanceIdx] = simd_float4x4(diagonal: SIMD4<Float>(0, 0, 0, 1))
            let edge = edges[edgeIdx]
            let srcPos: SIMD3<Float>
            let tgtPos: SIMD3<Float>
            if let si = idToIndex[edge.sourceId], si < positionArray.count,
               let ti = idToIndex[edge.targetId], ti < positionArray.count {
                srcPos = positionArray[si]
                tgtPos = positionArray[ti]
            } else {
                guard let sp = positions[edge.sourceId], let tp = positions[edge.targetId] else { continue }
                srcPos = sp; tgtPos = tp
            }

            let src = srcPos * scaleFactor
            let tgt = tgtPos * scaleFactor
            let radius: Float = 1.0 * scaleFactor

            let transform = Self.cylinderTransform(
                from: src, to: tgt, radius: radius
            )
            guard transform != matrix_identity_float4x4 else { continue }
            transforms[instanceIdx] = transform

            // Per-instance color
            let project = nodeProject[edge.sourceId]
            var color = colorMap[project ?? ""] ?? SIMD3<Float>(0.6, 0.6, 0.6)
            color = min(color * 1.4 + 0.15, SIMD3<Float>(repeating: 1.0))

            var alpha: Float = 0.35
            if let sel = selectedNode {
                if edge.sourceId == sel || edge.targetId == sel { alpha = 0.8 }
                else { alpha = 0.15 }
            }
            if isSearchActive {
                let srcMatch = searchMatchIds.contains(edge.sourceId)
                let tgtMatch = searchMatchIds.contains(edge.targetId)
                if !srcMatch && !tgtMatch { alpha *= 0.2 }
            }

            texData[instanceIdx] = SIMD4<Float16>(
                Float16(color.x), Float16(color.y), Float16(color.z), Float16(alpha)
            )
        }

        // Zero departed slots (see NodeBatchSystem).
        for slot in holes where slot < transforms.count {
            transforms[slot] = simd_float4x4(diagonal: SIMD4<Float>(0, 0, 0, 1))
            if slot < texData.count { texData[slot] = .zero }
        }

        guard let ownsLease = instanceUploads.publish(
            transforms: transforms, colors: texData, entity: entity, data: instanceData,
            texture: instanceTexture, device: scene.device, command: cmdBuf, upload: upload
        ) else { return }
        self.slotForEdge = slotForEdge
        self.slotHighWater = slotHighWater
        self.freeSlots = freeSlots
        self.slotsTopologyVersion = slotsTopologyVersion
        submitted = ownsLease
        if ownsLease && commandBuffer == nil { cmdBuf.commit() }
    }

    /// Build a 4×4 transform that places a unit cylinder between `src` and `tgt`.
    ///
    /// `MeshResource.generateCylinder(height: 1)` produces geometry centered at origin,
    /// spanning Y = -0.5 to Y = +0.5. So translation must go to the edge midpoint,
    /// not the source position.
    private static func cylinderTransform(
        from src: SIMD3<Float>,
        to tgt: SIMD3<Float>,
        radius: Float
    ) -> simd_float4x4 {
        let dir = tgt - src
        let length = simd_length(dir)
        guard length > 0.0001 else { return matrix_identity_float4x4 }
        let y = dir / length

        let tempUp: SIMD3<Float> = abs(y.y) < 0.99 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let x = normalize(cross(y, tempUp))
        let z = cross(x, y)

        // Midpoint of the edge (cylinder is centered at origin, not based at origin)
        let mid = (src + tgt) * 0.5

        // Combine rotation × scale (radius on X/Z, length on Y) + translation to midpoint
        return simd_float4x4(columns: (
            SIMD4<Float>(x.x * radius, x.y * radius, x.z * radius, 0),
            SIMD4<Float>(y.x * length, y.y * length, y.z * length, 0),
            SIMD4<Float>(z.x * radius, z.y * radius, z.z * radius, 0),
            SIMD4<Float>(mid.x, mid.y, mid.z, 1)
        ))
    }
}
