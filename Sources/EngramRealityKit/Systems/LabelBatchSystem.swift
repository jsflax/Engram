import RealityKit
import Metal
import simd
import EngramSceneKit

/// Instanced billboard label rendering system.
///
/// Labels are camera-facing quads with texture atlas UV coordinates.
/// Atlas regeneration is debounced (60-frame minimum between rebuilds).
@MainActor
public final class LabelBatchSystem {
    private static let vertsPerLabel = 4
    private static let indicesPerLabel = 6

    private var lastAtlasVersion: UInt64 = 0
    private var lastAtlasFrame: UInt64 = 0
    private var atlasInvalidation = LabelAtlasInvalidation()
    private var labelStaging: [BatchVertex] = []
    private var lastFrameState: LabelFrameState?

    /// Labels have no clock-driven animation. Reuse their mesh until one of
    /// the actual geometry, visibility, or appearance inputs changes.
    private struct LabelFrameState: Equatable {
        let topologyVersion: UInt64
        let positionVersion: UInt64
        let atlasVersion: UInt64
        let visibleLabels: [Int]
        let cameraPosition: SIMD3<Float>
        let cameraRight: SIMD3<Float>
        let cameraUp: SIMD3<Float>
        let scaleFactor: Float
        let selectedNode: UUID?
        let searchIsActive: Bool
        let searchMatches: Set<UUID>
        let colors: [String: SIMD3<Float>]
        let projectCentroids: [String: SIMD3<Float>]
        var capacity: Int
    }

    // Cached cluster data — recomputed every N frames instead of every frame
    private var cachedProjectMaxY: [String: Float] = [:]
    private var cachedTopicSums: [String: (sum: SIMD3<Float>, count: Int, project: String, maxY: Float)] = [:]
    private var lastClusterFrame: UInt64 = 0
    private var clusterPositionVersion: UInt64?
    private var clusterTopologyVersion: UInt64?
    private let clusterRescanInterval: UInt64 = 10

    // Project/topic sets cached on topologyVersion. Building
    // Set(nodes.map(\.topic)) inline costs ~300ms/frame at 40k nodes —
    // it was 70% of the total frame time in the V0 baseline.
    private var cachedProjects: Set<String> = []
    private var cachedTopics: Set<String> = []
    private var cachedSetsTopologyVersion: UInt64 = .max

    private func projectTopicSets(_ dataProvider: SceneDataProvider) -> (projects: Set<String>, topics: Set<String>) {
        if dataProvider.topologyVersion != cachedSetsTopologyVersion {
            var projects = Set<String>(minimumCapacity: 64)
            var topics = Set<String>(minimumCapacity: 256)
            for node in dataProvider.nodes {
                projects.insert(node.project)
                topics.insert(node.topic)
            }
            cachedProjects = projects
            cachedTopics = topics
            cachedSetsTopologyVersion = dataProvider.topologyVersion
        }
        return (cachedProjects, cachedTopics)
    }

    public init() {}

    // Section-level timing, enabled with the frame-stats harness. Guarded by
    // the same env var so production frames stay branch-cheap.
    private let sectionStats = ProcessInfo.processInfo.environment["ENGRAM_FRAME_STATS"] != nil
    private var marks: [(String, UInt64)] = []
    @inline(__always) private func mark(_ label: String) {
        if sectionStats { marks.append((label, DispatchTime.now().uptimeNanoseconds)) }
    }

    public func update(
        scene: EngramRealityScene,
        dataProvider: SceneDataProvider,
        visibleSet: VisibleSet,
        topologyChanged: Bool,
        cameraPosition: SIMD3<Float>,
        scaleFactor: Float,
        frameCount: UInt64,
        commandBuffer: MTLCommandBuffer? = nil
    ) {
        marks.removeAll(keepingCapacity: true)
        mark("start")
        let visibleCount = visibleSet.visibleLabelIndices.count
        let projCount = dataProvider.projectCentroids.count
        let topicCount = projectTopicSets(dataProvider).topics.count
        let totalLabelCount = visibleCount + projCount + topicCount
        mark("counts")
        if sectionStats && frameCount % 120 == 0 {
            print("[labels] frame=\(frameCount) visibleNodes=\(visibleCount) projects=\(projCount) topics=\(topicCount) totalNodes=\(dataProvider.nodes.count) projRects=\(scene.labelAtlasGenerator.projectRects.count) topicRects=\(scene.labelAtlasGenerator.topicRects.count) atlasFrame=\(lastAtlasFrame)")
        }
        if atlasInvalidation.observe(version: dataProvider.topologyVersion) {
            scene.labelAtlasGenerator.invalidatePendingAtlas()
        }
        if scene.labelAtlasGenerator.needsAtlasRetry {
            atlasInvalidation.markDirty()
        }
        if totalLabelCount > 0 && atlasInvalidation.shouldRequest(frame: frameCount) {
            let (projects, topics) = projectTopicSets(dataProvider)
            scene.labelAtlasGenerator.regenerateAtlas(
                nodes: dataProvider.nodes,
                hubs: dataProvider.hubs,
                projects: projects,
                topics: topics
            )
            lastAtlasFrame = frameCount
        }

        mark("atlas")
        // No label can be drawn until the first background atlas is ready.
        // Avoid allocating an empty mesh and scanning every cluster on the
        // same cold frame as the node/edge resources. Existing atlases remain
        // visible while their replacement is being rasterized.
        guard totalLabelCount > 0, scene.labelAtlasGenerator.atlasTexture != nil else {
            scene.labelBatchEntity?.isEnabled = false
            lastFrameState = nil
            return
        }
        let nodes = dataProvider.nodes
        let positionArray = dataProvider.positionArray
        let positions: [UUID: SIMD3<Float>] = positionArray.count == nodes.count ? [:] : dataProvider.positions
        let atlasRects = scene.labelAtlasGenerator.nodeRects
        let aspectCorrection = scene.labelAtlasGenerator.aspectCorrection
        let selectedNode = dataProvider.selectedNode
        let isSearchActive = dataProvider.isSearchActive
        let searchMatchIds = dataProvider.searchMatchIds
        let colorMap = dataProvider.projectColorMap

        // Camera orientation for billboard
        let camPos = cameraPosition * scaleFactor
        let camRight: SIMD3<Float>
        let camUp: SIMD3<Float>

        if let provider = scene.cameraProvider {
            let state = provider.cameraState
            camRight = state.right
            camUp = state.up
        } else {
            camRight = SIMD3<Float>(1, 0, 0)
            camUp = SIMD3<Float>(0, 1, 0)
        }

        let needsClusterRescan = clusterTopologyVersion != dataProvider.topologyVersion
            || (clusterPositionVersion != dataProvider.positionVersion
                && frameCount &- lastClusterFrame >= clusterRescanInterval)
        var frameState = LabelFrameState(
            topologyVersion: dataProvider.topologyVersion,
            positionVersion: dataProvider.positionVersion,
            atlasVersion: scene.labelAtlasGenerator.atlasVersion,
            visibleLabels: visibleSet.visibleLabelIndices,
            cameraPosition: camPos, cameraRight: camRight, cameraUp: camUp,
            scaleFactor: scaleFactor, selectedNode: selectedNode,
            searchIsActive: isSearchActive, searchMatches: searchMatchIds,
            colors: colorMap, projectCentroids: dataProvider.projectCentroids,
            capacity: scene.labelBatchCapacity)
        let needsMesh = scene.labelBatchMesh == nil || scene.labelBatchEntity?.model == nil
            || scene.labelBatchCapacity < totalLabelCount
        guard frameState != lastFrameState || needsClusterRescan || needsMesh else { return }

        // Obtain upload resources before changing a visible entity/material.
        // A failed allocation keeps the complete old texture + UVs on screen
        // and leaves the frame state uncommitted so unchanged input retries.
        guard let cmdBuf = commandBuffer ?? scene.commandQueue.makeCommandBuffer(),
              LowLevelMeshFactory.ensureLabelBatchMesh(scene: scene, capacity: totalLabelCount),
              let mesh = scene.labelBatchMesh,
              scene.labelBatchEntity?.model != nil,
              scene.labelBatchCapacity >= totalLabelCount else { return }
        frameState.capacity = scene.labelBatchCapacity

        let totalVerts = scene.labelBatchCapacity * Self.vertsPerLabel
        if labelStaging.count < totalVerts {
            labelStaging = [BatchVertex](repeating: BatchVertex(
                px: 0, py: 0, pz: 0, nx: 0, ny: 0, nz: 0,
                u: 0, v: 0, cr: 0, cg: 0, cb: 0, ca: 0
            ), count: totalVerts)
        }

        mark("staginit")
        var instanceIdx = 0
        for nodeIdx in visibleSet.visibleLabelIndices {
            let node = nodes[nodeIdx]
            guard let rect = atlasRects[node.id] else { continue }
            let pos = nodeIdx < positionArray.count ? positionArray[nodeIdx] : (positions[node.id] ?? .zero)

            let anchor = pos * scaleFactor + SIMD3<Float>(0, 12.0, 0)

            let baseHalfH: Float = node.isHub ? 2.5 : 2.0
            let halfH = baseHalfH
            let halfW = halfH * (rect.u1 - rect.u0) / max(rect.v1 - rect.v0, 0.001) * aspectCorrection

            let color = colorMap[node.project] ?? SIMD3<Float>(0.8, 0.8, 0.8)

            let dist = simd_length(anchor - camPos)
            var opacity: Float = 1.0 - min(1.0, dist / 1200.0)
            opacity = max(0.1, opacity)
            if node.id == selectedNode { opacity = 1.0 }
            if isSearchActive && !searchMatchIds.contains(node.id) { opacity *= 0.2 }

            let r = camRight * halfW
            let u = camUp * halfH

            let baseVert = instanceIdx * Self.vertsPerLabel
            labelStaging[baseVert + 0] = BatchVertex(
                px: anchor.x - r.x - u.x, py: anchor.y - r.y - u.y, pz: anchor.z - r.z - u.z,
                nx: 0, ny: 0, nz: 1, u: rect.u0, v: rect.v0,
                cr: color.x, cg: color.y, cb: color.z, ca: opacity
            )
            labelStaging[baseVert + 1] = BatchVertex(
                px: anchor.x + r.x - u.x, py: anchor.y + r.y - u.y, pz: anchor.z + r.z - u.z,
                nx: 0, ny: 0, nz: 1, u: rect.u1, v: rect.v0,
                cr: color.x, cg: color.y, cb: color.z, ca: opacity
            )
            labelStaging[baseVert + 2] = BatchVertex(
                px: anchor.x - r.x + u.x, py: anchor.y - r.y + u.y, pz: anchor.z - r.z + u.z,
                nx: 0, ny: 0, nz: 1, u: rect.u0, v: rect.v1,
                cr: color.x, cg: color.y, cb: color.z, ca: opacity
            )
            labelStaging[baseVert + 3] = BatchVertex(
                px: anchor.x + r.x + u.x, py: anchor.y + r.y + u.y, pz: anchor.z + r.z + u.z,
                nx: 0, ny: 0, nz: 1, u: rect.u1, v: rect.v1,
                cr: color.x, cg: color.y, cb: color.z, ca: opacity
            )
            instanceIdx += 1
        }

        mark("visloop")
        // Moving clusters are throttled, while a settled scene reuses its
        // aggregates indefinitely. Metadata changes invalidate immediately.
        if needsClusterRescan {
            lastClusterFrame = frameCount
            clusterPositionVersion = dataProvider.positionVersion
            clusterTopologyVersion = dataProvider.topologyVersion
            cachedProjectMaxY.removeAll(keepingCapacity: true)
            cachedTopicSums.removeAll(keepingCapacity: true)
            for (index, node) in nodes.enumerated() {
                guard let pos = index < positionArray.count ? positionArray[index] : positions[node.id] else { continue }
                cachedProjectMaxY[node.project] = max(
                    cachedProjectMaxY[node.project] ?? -Float.greatestFiniteMagnitude, pos.y)
                let entry = cachedTopicSums[node.topic] ?? (.zero, 0, node.project, -Float.greatestFiniteMagnitude)
                cachedTopicSums[node.topic] = (entry.sum + pos, entry.count + 1, node.project, max(entry.maxY, pos.y))
            }
        }
        mark("rescan")
        let projectMaxY = cachedProjectMaxY

        // Project cluster labels — large, floating above top of cluster
        // Much larger than node labels and visible from across the scene
        let projRects = scene.labelAtlasGenerator.projectRects
        if sectionStats && frameCount % 120 == 0 && !dataProvider.projectCentroids.isEmpty {
            print("[labels] projCentroids=\(Array(dataProvider.projectCentroids.keys)) projRects=\(Array(projRects.keys)) staging=\(labelStaging.count) instanceIdx=\(instanceIdx)")
        }
        for (project, centroid) in dataProvider.projectCentroids {
            guard let rect = projRects[project] else { continue }
            let color = colorMap[project] ?? SIMD3<Float>(0.9, 0.9, 0.9)
            let topY = projectMaxY[project] ?? centroid.y
            let anchor = SIMD3<Float>(centroid.x, topY + 40.0, centroid.z) * scaleFactor
            let halfH: Float = 14.0
            let halfW = halfH * (rect.u1 - rect.u0) / max(rect.v1 - rect.v0, 0.001) * aspectCorrection
            let dist = simd_length(anchor - camPos)
            let opacity: Float = max(0.5, 1.0 - min(1.0, dist / 8000.0))
            let r = camRight * halfW
            let u = camUp * halfH
            let baseVert = instanceIdx * Self.vertsPerLabel
            guard baseVert + 3 < labelStaging.count else { break }
            labelStaging[baseVert + 0] = BatchVertex(
                px: anchor.x - r.x - u.x, py: anchor.y - r.y - u.y, pz: anchor.z - r.z - u.z,
                nx: 0, ny: 0, nz: 1, u: rect.u0, v: rect.v0,
                cr: color.x, cg: color.y, cb: color.z, ca: opacity)
            labelStaging[baseVert + 1] = BatchVertex(
                px: anchor.x + r.x - u.x, py: anchor.y + r.y - u.y, pz: anchor.z + r.z - u.z,
                nx: 0, ny: 0, nz: 1, u: rect.u1, v: rect.v0,
                cr: color.x, cg: color.y, cb: color.z, ca: opacity)
            labelStaging[baseVert + 2] = BatchVertex(
                px: anchor.x - r.x + u.x, py: anchor.y - r.y + u.y, pz: anchor.z - r.z + u.z,
                nx: 0, ny: 0, nz: 1, u: rect.u0, v: rect.v1,
                cr: color.x, cg: color.y, cb: color.z, ca: opacity)
            labelStaging[baseVert + 3] = BatchVertex(
                px: anchor.x + r.x + u.x, py: anchor.y + r.y + u.y, pz: anchor.z + r.z + u.z,
                nx: 0, ny: 0, nz: 1, u: rect.u1, v: rect.v1,
                cr: color.x, cg: color.y, cb: color.z, ca: opacity)
            instanceIdx += 1
        }

        // Topic cluster labels — mid-size, at topic centroid
        // Larger than node labels but smaller than project labels
        let topicRects = scene.labelAtlasGenerator.topicRects
        if !topicRects.isEmpty {
            // Use cached topic centroids (recomputed above on throttle interval)
            let topicSums = cachedTopicSums
            for (topic, data) in topicSums where data.count >= 2 {
                guard let rect = topicRects[topic] else { continue }
                let centroid = data.sum / Float(data.count)
                let color = colorMap[data.project] ?? SIMD3<Float>(0.7, 0.7, 0.7)
                let anchor = SIMD3<Float>(centroid.x, data.maxY + 25.0, centroid.z) * scaleFactor
                let halfH: Float = 8.0
                let halfW = halfH * (rect.u1 - rect.u0) / max(rect.v1 - rect.v0, 0.001) * aspectCorrection
                let dist = simd_length(anchor - camPos)
                let opacity: Float = max(0.3, 1.0 - min(1.0, dist / 5000.0))
                let r = camRight * halfW
                let u = camUp * halfH
                let baseVert = instanceIdx * Self.vertsPerLabel
                guard baseVert + 3 < labelStaging.count else { break }
                labelStaging[baseVert + 0] = BatchVertex(
                    px: anchor.x - r.x - u.x, py: anchor.y - r.y - u.y, pz: anchor.z - r.z - u.z,
                    nx: 0, ny: 0, nz: 1, u: rect.u0, v: rect.v0,
                    cr: color.x, cg: color.y, cb: color.z, ca: opacity)
                labelStaging[baseVert + 1] = BatchVertex(
                    px: anchor.x + r.x - u.x, py: anchor.y + r.y - u.y, pz: anchor.z + r.z - u.z,
                    nx: 0, ny: 0, nz: 1, u: rect.u1, v: rect.v0,
                    cr: color.x, cg: color.y, cb: color.z, ca: opacity)
                labelStaging[baseVert + 2] = BatchVertex(
                    px: anchor.x - r.x + u.x, py: anchor.y - r.y + u.y, pz: anchor.z - r.z + u.z,
                    nx: 0, ny: 0, nz: 1, u: rect.u0, v: rect.v1,
                    cr: color.x, cg: color.y, cb: color.z, ca: opacity)
                labelStaging[baseVert + 3] = BatchVertex(
                    px: anchor.x + r.x + u.x, py: anchor.y + r.y + u.y, pz: anchor.z + r.z + u.z,
                    nx: 0, ny: 0, nz: 1, u: rect.u1, v: rect.v1,
                    cr: color.x, cg: color.y, cb: color.z, ca: opacity)
                instanceIdx += 1
            }
        }

        mark("labelloops")
        let usedVerts = instanceIdx * Self.vertsPerLabel
        if usedVerts < totalVerts {
            memset(&labelStaging[usedVerts], 0, (totalVerts - usedVerts) * MemoryLayout<BatchVertex>.stride)
        }

        // GPU-synchronized write
        let destBuffer = mesh.replace(bufferIndex: 0, using: cmdBuf)
        let dest = destBuffer.contents().bindMemory(to: BatchVertex.self, capacity: totalVerts)
        labelStaging.withUnsafeBufferPointer { src in
            dest.update(from: src.baseAddress!, count: totalVerts)
        }
        // Bind only after the matching UV upload has been encoded. No actor
        // suspension can expose a new texture with the previous atlas's UVs.
        if scene.labelAtlasGenerator.atlasVersion != lastAtlasVersion,
           let texture = scene.labelAtlasGenerator.atlasTexture,
           let labelEntity = scene.labelBatchEntity {
            labelEntity.model?.materials = [MaterialFactory.makeLabelMaterial(
                device: scene.device, atlasTexture: texture)]
            lastAtlasVersion = scene.labelAtlasGenerator.atlasVersion
        }
        scene.labelBatchEntity?.isEnabled = true
        if commandBuffer == nil { cmdBuf.commit() }
        lastFrameState = frameState
        mark("write")
        if sectionStats && frameCount % 120 == 7 {
            var out = "[labels-sections] frame=\(frameCount)"
            for i in 1..<marks.count {
                let ms = Double(marks[i].1 &- marks[i-1].1) / 1_000_000
                out += " \(marks[i].0)=\(String(format: "%.1f", ms))"
            }
            print(out + " totalLabels=\(totalLabelCount) topics=\(topicCount)")
        }
    }
}
