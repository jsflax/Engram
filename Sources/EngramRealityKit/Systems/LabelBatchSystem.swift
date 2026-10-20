import RealityKit
import CoreGraphics
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

    // Post-creation material reassignments only; no extra resource retention.
    private(set) var diagnosticMaterialAssignments: UInt64 = 0
    private var lastAtlasVersion: UInt64?
    private var lastAtlasFrame: UInt64?
    private var labelStaging: [BatchVertex] = []

    // Cached cluster data — recomputed every N frames instead of every frame
    private var cachedProjectMaxY: [String: Float] = [:]
    private var cachedTopicSums: [String: (sum: SIMD3<Float>, count: Int, project: String, maxY: Float)] = [:]
    private var lastClusterFrame: UInt64 = 0
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
        if frameCount % 120 == 0 {
            print("[labels] frame=\(frameCount) visibleNodes=\(visibleCount) projects=\(projCount) topics=\(topicCount) totalNodes=\(dataProvider.nodes.count) projRects=\(scene.labelAtlasGenerator.projectRects.count) topicRects=\(scene.labelAtlasGenerator.topicRects.count) atlasFrame=\(lastAtlasFrame ?? 0)")
        }
        scene.labelBatchEntity?.isEnabled = totalLabelCount > 0
        guard totalLabelCount > 0 else { return }

        // The scene's topologyChanged flag lasts one frame. Keep the last
        // successful version until this system's debounce admits the latest data.
        let version = dataProvider.topologyVersion
        let needsAtlas = lastAtlasVersion != version || scene.labelAtlasGenerator.atlasTexture == nil
        let mayAttempt = lastAtlasFrame.map { (frameCount &- $0) > 60 } ?? true
        if needsAtlas, mayAttempt, !dataProvider.nodes.isEmpty {
            lastAtlasFrame = frameCount
            let (projects, topics) = projectTopicSets(dataProvider)
            let previousTexture = scene.labelAtlasGenerator.atlasTexture
            let succeeded = scene.labelAtlasGenerator.refreshAtlas(
                nodes: dataProvider.nodes,
                hubs: dataProvider.hubs,
                projects: projects,
                topics: topics
            )
            if succeeded {
                lastAtlasVersion = version
                // Edge-only topology changes can reuse the exact raster inputs.
                // Keep the existing material when the atlas resource is unchanged.
                if let texture = scene.labelAtlasGenerator.atlasTexture,
                   texture !== previousTexture, let labelEntity = scene.labelBatchEntity {
                    let mat = MaterialFactory.makeLabelMaterial(device: scene.device, atlasTexture: texture)
                    labelEntity.model?.materials = [mat]
                    if labelEntity.model != nil { diagnosticMaterialAssignments &+= 1 }
                }
            }
        }

        mark("atlas")
        LowLevelMeshFactory.ensureLabelBatchMesh(scene: scene, capacity: totalLabelCount)
        guard let mesh = scene.labelBatchMesh else { return }

        let nodes = dataProvider.nodes
        let positions = dataProvider.positions
        let positionArray = dataProvider.positionArray
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
        let cameraState = scene.cameraProvider?.cameraState

        if let provider = scene.cameraProvider {
            let state = provider.cameraState
            camRight = state.right
            camUp = state.up
        } else {
            camRight = SIMD3<Float>(1, 0, 0)
            camUp = SIMD3<Float>(0, 1, 0)
        }

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
        // Compute per-project max Y + topic sums (throttled — every 10 frames or on topology change)
        if frameCount - lastClusterFrame >= clusterRescanInterval
            || cachedProjectMaxY.isEmpty || topologyChanged {
            lastClusterFrame = frameCount
            cachedProjectMaxY.removeAll(keepingCapacity: true)
            cachedTopicSums.removeAll(keepingCapacity: true)
            for node in nodes {
                guard let pos = positions[node.id] else { continue }
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
        if frameCount % 120 == 0 && !dataProvider.projectCentroids.isEmpty {
            print("[labels] projCentroids=\(Array(dataProvider.projectCentroids.keys)) projRects=\(Array(projRects.keys)) staging=\(labelStaging.count) instanceIdx=\(instanceIdx)")
        }
        for (project, centroid) in dataProvider.projectCentroids {
            guard let rect = projRects[project] else { continue }
            let color = colorMap[project] ?? SIMD3<Float>(0.9, 0.9, 0.9)
            let topY = projectMaxY[project] ?? centroid.y
            let anchor = SIMD3<Float>(centroid.x, topY + ClusterLabelKind.project.graphVerticalOffset, centroid.z) * scaleFactor
            let labelAspect = (rect.u1 - rect.u0) / max(rect.v1 - rect.v0, 0.001) * aspectCorrection
            let halfH = ClusterLabelSizing.halfHeight(legacy: 14.0, bounded: scene.usesViewportBoundedClusterLabels,
                aspect: labelAspect, depth: cameraState.map { simd_dot(anchor - camPos, $0.forward) } ?? 0,
                fovDegrees: cameraState?.fovDegrees ?? 0, viewport: scene.clusterLabelViewportSize,
                maximumHeight: Float(ClusterLabelKind.project.maximumPointHeight),
                maximumWidthFraction: Float(ClusterLabelKind.project.maximumViewportWidthFraction))
            guard halfH > 0 else { continue }
            let halfW = halfH * labelAspect
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
                let anchor = SIMD3<Float>(centroid.x, data.maxY + ClusterLabelKind.topic.graphVerticalOffset, centroid.z) * scaleFactor
                let labelAspect = (rect.u1 - rect.u0) / max(rect.v1 - rect.v0, 0.001) * aspectCorrection
                let halfH = ClusterLabelSizing.halfHeight(legacy: 8.0, bounded: scene.usesViewportBoundedClusterLabels,
                    aspect: labelAspect, depth: cameraState.map { simd_dot(anchor - camPos, $0.forward) } ?? 0,
                    fovDegrees: cameraState?.fovDegrees ?? 0, viewport: scene.clusterLabelViewportSize,
                    maximumHeight: Float(ClusterLabelKind.topic.maximumPointHeight),
                    maximumWidthFraction: Float(ClusterLabelKind.topic.maximumViewportWidthFraction))
                guard halfH > 0 else { continue }
                let halfW = halfH * labelAspect
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
            labelStaging.withUnsafeMutableBytes { bytes in
                let offset = usedVerts * MemoryLayout<BatchVertex>.stride
                let byteCount = (totalVerts - usedVerts) * MemoryLayout<BatchVertex>.stride
                precondition(offset >= 0 && offset + byteCount <= bytes.count)
                bytes.baseAddress!.advanced(by: offset).initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
            }
        }

        // CPU replacement owns writable storage only for this synchronous callback.
        // replace(bufferIndex:using:) is reserved for GPU writes, not CPU contents().
        mesh.replaceUnsafeMutableBytes(bufferIndex: 0) { destination in
            labelStaging.withUnsafeBytes { source in
                let byteCount = totalVerts * MemoryLayout<BatchVertex>.stride
                precondition(byteCount <= destination.count && byteCount <= source.count)
                destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: byteCount)
            }
        }
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

/// Shared placement and screen-size contract for rendered cluster labels and
/// an embedded host's initial/explicit camera fit. Desktop sizing stays opt-in.
public enum ClusterLabelKind: Sendable, Equatable {
    case project, topic
    public var graphVerticalOffset: Float { self == .project ? 40 : 25 }
    public var maximumPointHeight: CGFloat { self == .project ? 18 : 12 }
    public var maximumViewportWidthFraction: CGFloat { self == .project ? 0.6 : 0.5 }
    public func maximumPointSize(in viewport: CGSize) -> CGSize {
        CGSize(width: viewport.width * maximumViewportWidthFraction, height: maximumPointHeight)
    }
}

/// Billboard point size follows perspective depth; it never enlarges the legacy
/// world-space glyphs. Invalid/unmeasured mobile geometry renders no cluster title.
/// This scalar calculation runs only for the already-cached cluster labels.
enum ClusterLabelSizing {
    static func halfHeight(legacy: Float, bounded: Bool, aspect: Float, depth: Float,
                           fovDegrees: Float, viewport: CGSize?, maximumHeight: Float,
                           maximumWidthFraction: Float) -> Float {
        guard bounded else { return legacy }
        guard let viewport, viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0,
              aspect.isFinite, aspect > 0, depth.isFinite, depth > 0,
              fovDegrees.isFinite, fovDegrees > 0, fovDegrees < 180,
              maximumHeight.isFinite, maximumHeight > 0,
              maximumWidthFraction.isFinite, maximumWidthFraction > 0,
              legacy.isFinite, legacy > 0 else { return 0 }
        let height = min(Double(maximumHeight),
                         Double(viewport.width) * Double(maximumWidthFraction) / Double(aspect))
        let half = height * Double(depth) * tan(Double(fovDegrees) * .pi / 360) / Double(viewport.height)
        guard half.isFinite, half > 0 else { return 0 }
        return Float(min(Double(legacy), half))
    }
}
