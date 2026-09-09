import Foundation
import simd
import AppKit
import EngramRealityKit

/// Bridges GalaxyRegistry data to SceneDataProvider for EngramRealityKit.
///
/// Reads from GalaxyRegistry's merged data each frame, converting NodeData/EdgeData
/// to RKNodeSnapshot/RKEdgeSnapshot without depending on EngramKit types in the library.
@MainActor
final class GalaxyRegistryAdapter: SceneDataProvider {
    weak var registry: GalaxyRegistry?

    // Cached snapshots — rebuilt on topology change
    private var cachedNodes: [RKNodeSnapshot] = []
    private var cachedEdges: [RKEdgeSnapshot] = []
    private var cachedHubs: Set<UUID> = []
    private var cachedColorMap: [String: SIMD3<Float>] = [:]
    private var lastTopologyVersion: UInt64 = 0
    private var lastColorMapVersion: UInt64 = 0

    // Visual state — elapsed times tracked per-frame
    private var glowStartTimes: [UUID: Date] = [:]
    private var newNodeStartTimes: [UUID: Date] = [:]

    // Per-frame caches, refreshed once in tick(). The batch systems read
    // these properties several times per frame; computed accessors rebuilt
    // dicts/arrays on every access (positionArray alone was 4×O(n) per
    // frame — the production analog of the preview's V0 hot path).
    private var framePositionArray: [SIMD3<Float>] = []
    private var frameGlowing: [UUID: Float] = [:]
    private var frameNewGlows: [UUID: Float] = [:]
    private var frameCentroids: [String: SIMD3<Float>] = [:]
    private var simIndexByNodeIndex: [Int] = []
    private var simIndexTopologyVersion: UInt64 = .max
    private var cachedPositionVersion: UInt64 = .max
    private var centroidPositionVersion: UInt64 = .max

    init(registry: GalaxyRegistry) {
        self.registry = registry
    }

    // MARK: - SceneDataProvider

    var nodes: [RKNodeSnapshot] { cachedNodes }
    var edges: [RKEdgeSnapshot] { cachedEdges }
    var hubs: Set<UUID> { cachedHubs }
    var projectColorMap: [String: SIMD3<Float>] { cachedColorMap }

    var positions: [UUID: SIMD3<Float>] {
        registry?.mergedPositions ?? [:]
    }

    /// Flat positions parallel to `nodes`, refreshed once per tick from the
    /// unified simulation's flat arrays (no UUID hashing on access).
    var positionArray: [SIMD3<Float>] { framePositionArray }
    var positionVersion: UInt64 { registry?.unifiedSimulation.positionVersion ?? 0 }

    var glowingNodes: [UUID: Float] { frameGlowing }

    var newNodeGlows: [UUID: Float] { frameNewGlows }

    var dyingNodes: Set<UUID> {
        guard let registry else { return [] }
        return Set(registry.mergedDyingNodes.keys)
    }

    var selectedNode: UUID? {
        get { _selectedNode }
        set { _selectedNode = newValue }
    }
    private var _selectedNode: UUID?

    var expandedHubs: Set<UUID> {
        // Hub expansion is managed by the input handler
        []
    }

    var searchMatchIds: Set<UUID> {
        registry?.mergedSearchMatchIds ?? []
    }

    var isSearchActive: Bool {
        registry?.mergedIsSearchActive ?? false
    }

    var projectCentroids: [String: SIMD3<Float>] { frameCentroids }

    var topologyVersion: UInt64 {
        registry?.mergedTopologyVersion ?? 0
    }

    func tick(dt: Float) {
        guard let registry else { return }

        // Drain pending updates from all galaxies
        let drainConfig = registry.currentDrainConfig
        let perGalaxyBudget = 0.002 / Double(max(1, registry.galaxies.count))
        for galaxy in registry.galaxies.values {
            galaxy.drainPendingUpdate(config: drainConfig, workBudget: perGalaxyBudget)
        }

        // Tick unified simulation
        registry.unifiedSimulation.tick()

        // Merge render data
        registry.mergeRenderData()

        // Rebuild snapshots on topology change
        let currentTopology = registry.mergedTopologyVersion
        if currentTopology != lastTopologyVersion {
            lastTopologyVersion = currentTopology
            rebuildSnapshots()
            #if ENGRAM_INSTRUMENTATION
            print("[adapter] topology v\(currentTopology): \(cachedNodes.count) nodes, \(cachedEdges.count) edges, mergedEdges=\(registry.mergedEdges.count), positions=\(registry.mergedPositions.count)")
            #endif
        }

        // Rebuild color map if needed
        let currentColorVersion = registry.mergedColorMapVersion
        if currentColorVersion != lastColorMapVersion {
            lastColorMapVersion = currentColorVersion
            rebuildColorMap()
        }

        // Sync glow state from registry
        syncGlowState()

        refreshFrameCaches()
    }

    /// Once-per-frame snapshot of everything the batch systems poll.
    private func refreshFrameCaches() {
        guard let registry else { return }
        let sim = registry.unifiedSimulation

        // positionArray via flat sim arrays + a topology-cached index map.
        let n = cachedNodes.count
        let indicesChanged = simIndexByNodeIndex.count != n || simIndexTopologyVersion != lastTopologyVersion
        if indicesChanged {
            var idToSim = [UUID: Int](minimumCapacity: sim.nodeIds.count)
            for (si, id) in sim.nodeIds.enumerated() { idToSim[id] = si }
            simIndexByNodeIndex = cachedNodes.map { idToSim[$0.id] ?? -1 }
            simIndexTopologyVersion = lastTopologyVersion
        }
        if framePositionArray.count != n {
            framePositionArray = [SIMD3<Float>](repeating: .zero, count: n)
        }
        if indicesChanged || cachedPositionVersion != sim.positionVersion {
            let px = sim.posX, py = sim.posY, pz = sim.posZ
            simIndexByNodeIndex.withUnsafeBufferPointer { simIdx in
                for i in 0..<n {
                    let si = simIdx[i]
                    framePositionArray[i] = si >= 0 && si < px.count ?
                        SIMD3<Float>(px[si], py[si], pz[si]) : .zero
                }
            }
            cachedPositionVersion = sim.positionVersion
        }

        // Glow elapsed times — one Date() call, one dict build per frame.
        let now = Date()
        frameGlowing.removeAll(keepingCapacity: true)
        for (id, start) in glowStartTimes {
            frameGlowing[id] = Float(now.timeIntervalSince(start))
        }
        frameNewGlows.removeAll(keepingCapacity: true)
        for (id, start) in newNodeStartTimes {
            frameNewGlows[id] = Float(now.timeIntervalSince(start))
        }

        // Project centroids — full scan throttled to every 30 frames (plus
        // topology changes): positions drift during settling, so anchors
        // refresh continuously but not per frame. The SAME pass now also
        // builds the (galaxy, project) nebula clusters and per-galaxy
        // aggregates — this is the only layer holding nodeToGalaxy, the
        // color map, and positions together, and folding them into one scan
        // keeps the per-30-frame cost at O(n).
        frameCounter &+= 1
        let isLoading = registry.galaxies.values.contains { $0.isDrainingInitialSnapshot }
        let topologyNeedsCentroids = lastTopologyVersion != centroidsTopologyVersion
            && (!isLoading || frameCentroids.isEmpty || frameCounter % 30 == 0)
        if topologyNeedsCentroids
            || (frameCounter % 30 == 0 && centroidPositionVersion != sim.positionVersion) {
            let nodeToGalaxy = registry.nodeToGalaxy
            var sums: [String: (sum: SIMD3<Float>, count: Int)] = [:]
            // (galaxyId|project) → accumulator; galaxyId → extent accumulator.
            var clusterSums: [String: (galaxy: String, project: String, sum: SIMD3<Float>, count: Int)] = [:]
            for (index, node) in cachedNodes.enumerated() {
                guard simIndexByNodeIndex[index] >= 0 else { continue }
                let pos = framePositionArray[index]
                let entry = sums[node.project] ?? (.zero, 0)
                sums[node.project] = (entry.sum + pos, entry.count + 1)
                let galaxy = nodeToGalaxy[node.id] ?? "personal"
                let key = "\(galaxy)|\(node.project)"
                let c = clusterSums[key] ?? (galaxy, node.project, .zero, 0)
                clusterSums[key] = (galaxy, node.project, c.sum + pos, c.count + 1)
            }
            frameCentroids = sums.mapValues { $0.sum / Float($0.count) }

            // Second O(n) pass for radii (needs the centroids from pass 1).
            var clusterCentroids: [String: SIMD3<Float>] = [:]
            for (key, c) in clusterSums {
                clusterCentroids[key] = c.sum / Float(c.count)
            }
            var clusterMaxDist: [String: Float] = [:]
            var galaxyMaxDist: [String: Float] = [:]
            var galaxyCounts: [String: Int] = [:]
            var galaxyProjectCounts: [String: [String: Int]] = [:]
            let galaxyCenters = registry.galaxies.mapValues { $0.worldCenter }
            for (index, node) in cachedNodes.enumerated() {
                guard simIndexByNodeIndex[index] >= 0 else { continue }
                let pos = framePositionArray[index]
                let galaxy = nodeToGalaxy[node.id] ?? "personal"
                let key = "\(galaxy)|\(node.project)"
                if let centroid = clusterCentroids[key] {
                    clusterMaxDist[key] = max(clusterMaxDist[key] ?? 0, simd_length(pos - centroid))
                }
                if let center = galaxyCenters[galaxy] {
                    galaxyMaxDist[galaxy] = max(galaxyMaxDist[galaxy] ?? 0, simd_length(pos - center))
                }
                galaxyCounts[galaxy, default: 0] += 1
                galaxyProjectCounts[galaxy, default: [:]][node.project, default: 0] += 1
            }

            frameNebulaClusters = clusterSums.map { key, c in
                RKNebulaCluster(galaxyId: c.galaxy, project: c.project,
                                centroid: clusterCentroids[key] ?? .zero,
                                count: c.count,
                                radius: (clusterMaxDist[key] ?? 0) + 40)
            }
            frameGalaxySnapshots = registry.galaxies.values.map { galaxy in
                // Dominant color = largest project's color in THIS galaxy.
                let dominant = galaxyProjectCounts[galaxy.id]?
                    .max(by: { $0.value < $1.value })?.key
                let color = dominant.flatMap { cachedColorMap[$0] } ?? SIMD3<Float>(0.5, 0.5, 0.6)
                return RKGalaxySnapshot(
                    id: galaxy.id,
                    displayName: galaxy.displayName,
                    worldCenter: galaxy.worldCenter,
                    dominantColor: color,
                    nodeCount: galaxyCounts[galaxy.id] ?? 0,
                    radius: galaxyMaxDist[galaxy.id] ?? 300,
                    parentGalaxyId: galaxy.parentGalaxyId)
            }
            centroidsTopologyVersion = lastTopologyVersion
            centroidPositionVersion = sim.positionVersion
        }
    }
    private var centroidsTopologyVersion: UInt64 = .max
    private var frameCounter: UInt64 = 0
    private var frameNebulaClusters: [RKNebulaCluster] = []
    private var frameGalaxySnapshots: [RKGalaxySnapshot] = []

    var nebulaClusters: [RKNebulaCluster] { frameNebulaClusters }
    var galaxySnapshots: [RKGalaxySnapshot] { frameGalaxySnapshots }

    // MARK: - Snapshot Rebuilding

    private func rebuildSnapshots() {
        guard let registry else { return }

        let mergedHubs = registry.mergedHubs
        let nodes = registry.mergedNodes
        // During loading the graph normally grows by appending. Validate the
        // entire old prefix, including metadata, before reusing its snapshots;
        // count growth alone cannot rule out a simultaneous edit/replacement.
        let canAppendNodes = nodes.count >= cachedNodes.count
            && cachedNodes.indices.allSatisfy { index in
                let old = cachedNodes[index], node = nodes[index]
                return old.id == node.id && old.project == node.project
                    && old.topic == node.topic && old.label == node.label
                    && old.content == node.content && old.importance == node.importance
                    && old.createdAt == node.createdAt && old.lastAccessedAt == node.lastAccessedAt
                    && old.isHub == mergedHubs.contains(node.id)
            }
        if !canAppendNodes { cachedNodes.removeAll(keepingCapacity: true) }
        if cachedNodes.capacity < nodes.count {
            cachedNodes.reserveCapacity(max(nodes.count, max(64, cachedNodes.capacity * 2)))
        }
        for node in nodes.dropFirst(cachedNodes.count) {
            cachedNodes.append(RKNodeSnapshot(
                id: node.id,
                project: node.project,
                topic: node.topic,
                label: node.label,
                content: node.content,
                importance: node.importance,
                isHub: mergedHubs.contains(node.id),
                createdAt: node.createdAt,
                lastAccessedAt: node.lastAccessedAt
            ))
        }

        let edges = registry.mergedEdges
        let canAppendEdges = edges.count >= cachedEdges.count
            && cachedEdges.indices.allSatisfy { index in
                let old = cachedEdges[index], edge = edges[index]
                return old.id == edge.id && old.sourceId == edge.sourceId
                    && old.targetId == edge.targetId && old.relation == edge.relation
            }
        if !canAppendEdges { cachedEdges.removeAll(keepingCapacity: true) }
        if cachedEdges.capacity < edges.count {
            cachedEdges.reserveCapacity(max(edges.count, max(64, cachedEdges.capacity * 2)))
        }
        for edge in edges.dropFirst(cachedEdges.count) {
            cachedEdges.append(RKEdgeSnapshot(
                id: edge.id,
                sourceId: edge.sourceId,
                targetId: edge.targetId,
                relation: edge.relation
            ))
        }

        // Do not pin the mutable render store's Set storage via this cache or
        // LOD's retained prior hub set while the next loading batch inserts.
        cachedHubs = Set(mergedHubs.map { $0 })
    }

    private func rebuildColorMap() {
        guard let registry else { return }
        var colorMap: [String: SIMD3<Float>] = [:]
        for (project, color) in registry.mergedColorMap {
            let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            nsColor.getRed(&r, green: &g, blue: &b, alpha: &a)
            colorMap[project] = SIMD3<Float>(Float(r), Float(g), Float(b))
        }
        cachedColorMap = colorMap
    }

    private func syncGlowState() {
        guard let registry else { return }

        // Preserve restarted timestamps as well as membership. A second recall
        // during an active glow must restart the animation immediately.
        glowStartTimes = registry.mergedGlowingNodes
        newNodeStartTimes = registry.mergedNewNodeGlows
    }
}
