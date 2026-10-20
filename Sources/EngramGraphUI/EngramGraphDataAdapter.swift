import Foundation
import simd
import EngramRealityKit
import EngramSceneKit

/// Exact-graph counterpart of GalaxyRegistryAdapter. The renderer consumes the same
/// node, edge, label, nebula and galaxy-title contracts; no registry is discovered.
@MainActor
final class EngramGraphDataAdapter: SceneDataProvider {
    let simulation = ForceSimulation3D()
    var hubExpansion = EngramGraphHubExpansionController()
    private(set) var nodes: [RKNodeSnapshot] = []
    private(set) var edges: [RKEdgeSnapshot] = []
    private(set) var hubs: Set<UUID> = []
    private(set) var projectColorMap: [String: SIMD3<Float>] = [:]
    private(set) var topologyVersion: UInt64 = 0
    // Renderer systems that still need UUID lookup share one lazy map per position
    // revision. The per-frame adapter path only touches flat/indexed storage.
    private var positionLookup: [UUID: SIMD3<Float>] = [:]
    private var lookupRevision: UInt64 = .max
    private var renderedRevision: UInt64 = 0
    var positionRevision: UInt64? { renderedRevision }
    var positions: [UUID: SIMD3<Float>] {
        if lookupRevision != renderedRevision {
            positionLookup.removeAll(keepingCapacity: true)
            positionLookup.reserveCapacity(nodes.count)
            for index in nodes.indices { positionLookup[nodes[index].id] = positionArray[index] }
            lookupRevision = renderedRevision
            work.dictionaryBuilds += 1; work.dictionaryRows += nodes.count
        }
        return positionLookup
    }
    private(set) var positionArray: [SIMD3<Float>] = []
    struct ClusterAnchor {
        let position: SIMD3<Float>
        let kind: ClusterLabelKind
    }
    struct FramingBounds {
        let center: SIMD3<Float>
        let radius: Float
        let renderedRevision: UInt64
        let forceRevision: UInt64
        let clusterAnchors: [ClusterAnchor]
    }
    private(set) var framingBounds: FramingBounds?
    // Installed only during initial framing; cleared on interaction or convergence.
    var onFramingUpdate: (() -> Void)?
    private(set) var projectCentroids: [String: SIMD3<Float>] = [:]
    private(set) var nebulaClusters: [RKNebulaCluster] = []
    private(set) var galaxySnapshots: [RKGalaxySnapshot] = []
    var selectedNode: UUID?
    var searchMatchIds: Set<UUID> = []
    var isSearchActive = false
    var isActive = false
    var semanticPositions: [UUID: SIMD3<Float>]? {
        didSet {
            semanticEntries = (semanticPositions ?? [:]).compactMap { id, target in
                guard let index = nodeIndex[id] else { return nil }
                return SemanticEntry(index: index, target: target, current: positionArray[index])
            }.sorted { $0.index < $1.index }
            semanticAnimating = !semanticEntries.isEmpty
            lastForceRevision = nil
        }
    }
    var glowingNodes: [UUID: Float] { [:] }
    var newNodeGlows: [UUID: Float] { [:] }
    var dyingNodes: Set<UUID> { [] }
    var expandedHubs: Set<UUID> { hubExpansion.expandedHubs }
    private var graphID = ""
    private var title = ""
    private var frameCounter = 0
    private var nodeIndex: [UUID: Int] = [:]
    private var simulationIndices: [Int] = []
    private var lastForceRevision: UInt64?
    private var aggregatesDirty = false
    private struct SemanticEntry {
        let index: Int
        let target: SIMD3<Float>
        var current: SIMD3<Float>
    }
    private var semanticEntries: [SemanticEntry] = []
    private var semanticAnimating = false
    struct Work: Equatable {
        var activeTicks = 0
        var positionRefreshes = 0
        var flatBufferResizes = 0
        var forceRows = 0
        var semanticRows = 0
        var dictionaryBuilds = 0
        var dictionaryRows = 0
        var aggregatePasses = 0
        var aggregateRows = 0
    }
    private(set) var work = Work()

    func replace(snapshot: EngramGraphSnapshot, hiddenProjects: Set<String>, hiddenRelations: Set<String>) {
        graphID = snapshot.graphID.uuidString.lowercased(); title = snapshot.title
        let memories = snapshot.memories.filter { !hiddenProjects.contains($0.project) }
        let ids = Set(memories.map(\.id))
        let visibleEdges = snapshot.edges.filter {
            ids.contains($0.sourceID) && ids.contains($0.targetID) && !hiddenRelations.contains($0.relation)
        }
        hubs = Set(visibleEdges.lazy.filter { $0.relation == "part_of" }.map(\.targetID))
        nodes = memories.map { memory in
            RKNodeSnapshot(id: memory.id, project: memory.project, topic: memory.topic,
                label: engramGraphLabel(content: memory.content, topic: memory.topic), content: memory.content,
                importance: memory.importance, isHub: hubs.contains(memory.id),
                createdAt: memory.createdAt, lastAccessedAt: memory.lastAccessedAt)
        }
        edges = visibleEdges.map { RKEdgeSnapshot(id: $0.id, sourceId: $0.sourceID, targetId: $0.targetID, relation: $0.relation) }

        for project in Set(snapshot.memories.map(\.project)).sorted() where projectColorMap[project] == nil {
            projectColorMap[project] = Self.palette[projectColorMap.count % Self.palette.count]
        }
        for id in hubExpansion.preExpansionPositions.keys { simulation.unpin(id) }
        simulation.updateGraph(nodeIds: ids, edges: visibleEdges.map { ($0.sourceID, $0.targetID) },
            projectForNode: Dictionary(uniqueKeysWithValues: memories.map { ($0.id, $0.project) }),
            topicForNode: Dictionary(uniqueKeysWithValues: memories.map { ($0.id, $0.topic) }))
        nodeIndex = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
        let forceIndices = Dictionary(uniqueKeysWithValues: simulation.nodeIds.enumerated().map { ($0.element, $0.offset) })
        simulationIndices = nodes.map { forceIndices[$0.id]! }
        if positionArray.count != nodes.count {
            positionArray = Array(repeating: .zero, count: nodes.count)
            work.flatBufferResizes += 1
        }
        semanticPositions = nil; hubExpansion = EngramGraphHubExpansionController()
        hubExpansion.installTopology(edges: visibleEdges.map { ($0.sourceID, $0.targetID, $0.relation) }, nodeIndices: nodeIndex)
        topologyVersion &+= 1; renderedRevision &+= 1
        lastForceRevision = nil
        refreshPositions(dt: 0); refreshAggregates()
    }

    func tick(dt: Float) {
        guard isActive else { return }
        work.activeTicks += 1
        if semanticPositions == nil { simulation.tick() }
        refreshPositions(dt: dt)
        frameCounter = (frameCounter + 1) % 30
        // Flush the final changed layout once it settles. Subsequent idle frames
        // do not revisit nodes or clusters; a late GPU delivery has a new revision.
        if aggregatesDirty && (frameCounter == 0 || (simulation.isSettled && !semanticAnimating && !hubExpansion.isIndexedAnimating)) {
            refreshAggregates()
        }
        // Settling may change without another position revision. The host also
        // checks the final in-flight GPU token before retiring this callback.
        if simulation.isSettled && !aggregatesDirty { onFramingUpdate?() }
    }

    /// An explicit Center action may request current bounds between aggregate passes.
    /// Initial automatic framing reuses those passes instead of scanning per frame.
    func currentFramingBounds() -> FramingBounds? {
        refreshPositions(dt: 0)
        if aggregatesDirty { refreshAggregates() }
        return framingBounds
    }

    private func refreshPositions(dt: Float) {
        let forceChanged = lastForceRevision != simulation.positionRevision
        guard forceChanged || semanticAnimating || hubExpansion.isIndexedAnimating else { return }
        work.positionRefreshes += 1
        var changed = false
        if forceChanged {
            let x = simulation.posX, y = simulation.posY, z = simulation.posZ
            for index in nodes.indices {
                let source = simulationIndices[index]
                let next = SIMD3(x[source], y[source], z[source])
                if positionArray[index] != next { positionArray[index] = next; changed = true }
            }
            work.forceRows += nodes.count
            lastForceRevision = simulation.positionRevision
        }
        if forceChanged || semanticAnimating {
            let blend = min(1, max(0, dt) * 5)
            var unsettled = false
            for index in semanticEntries.indices {
                work.semanticRows += 1
                var entry = semanticEntries[index]
                let delta = entry.target - entry.current
                // Continue the original exponential smoothing until it is below
                // a subpixel world-space tolerance, then publish the exact target.
                if simd_length_squared(delta) <= 0.00000001 {
                    entry.current = entry.target
                } else {
                    let next = entry.current + delta * blend
                    if blend > 0 && next == entry.current { entry.current = entry.target }
                    else { entry.current = next; unsettled = true }
                }
                if positionArray[entry.index] != entry.current {
                    positionArray[entry.index] = entry.current; changed = true
                }
                semanticEntries[index] = entry
            }
            semanticAnimating = unsettled
        }
        let sim = simulation
        let hubChanged = hubExpansion.updateIndexed(dt: dt, positions: &positionArray, baseChanged: forceChanged || changed) { id, position in
            sim.setPosition(id, to: position); sim.unpin(id)
        }
        // Collapsing restored these exact positions in both arrays; avoid a
        // redundant full copy on the next frame just for that publication.
        lastForceRevision = simulation.positionRevision
        if changed || hubChanged {
            renderedRevision &+= 1
            aggregatesDirty = true
        } else if !aggregatesDirty, let bounds = framingBounds,
                  bounds.forceRevision != simulation.positionRevision {
            // A force delivery may confirm identical coordinates. Acknowledge its
            // revision in O(1); do not rescan/re-fit unchanged rendered positions.
            framingBounds = FramingBounds(center: bounds.center, radius: bounds.radius,
                renderedRevision: bounds.renderedRevision, forceRevision: simulation.positionRevision,
                clusterAnchors: bounds.clusterAnchors)
        }
    }

    private func refreshAggregates() {
        // Same two-pass calculation as GalaxyRegistryAdapter, using indexed
        // positions and only when a published position revision made it dirty.
        work.aggregatePasses += 1; work.aggregateRows += nodes.count * 2
        aggregatesDirty = false
        var sums: [String: SIMD3<Float>] = [:]
        var counts: [String: Int] = [:]
        var projectMaxY: [String: Float] = [:]
        var topicStats: [String: (sum: SIMD3<Float>, count: Int, maxY: Float)] = [:]
        var total = SIMD3<Float>.zero
        for index in nodes.indices {
            let node = nodes[index]
            sums[node.project, default: .zero] += positionArray[index]
            counts[node.project, default: 0] += 1
            let position = positionArray[index]
            projectMaxY[node.project] = max(projectMaxY[node.project] ?? -Float.greatestFiniteMagnitude, position.y)
            let topic = topicStats[node.topic] ?? (.zero, 0, -Float.greatestFiniteMagnitude)
            topicStats[node.topic] = (topic.sum + position, topic.count + 1, max(topic.maxY, position.y))
            total += position
        }
        let center = nodes.isEmpty ? SIMD3<Float>.zero : total / Float(nodes.count)
        projectCentroids.removeAll(keepingCapacity: true)
        for (project, sum) in sums { projectCentroids[project] = sum / Float(counts[project] ?? 1) }
        var radii: [String: Float] = [:]
        var galaxyRadius: Float = 0
        var graphRadius: Float = 0
        for index in nodes.indices {
            let node = nodes[index]
            let position = positionArray[index]
            radii[node.project] = max(radii[node.project] ?? 0, simd_length(position - (projectCentroids[node.project] ?? .zero)))
            galaxyRadius = max(galaxyRadius, simd_length(position))
            graphRadius = max(graphRadius, simd_length(position - center))
        }
        nebulaClusters = counts.keys.sorted().map { project in
            RKNebulaCluster(galaxyId: graphID, project: project, centroid: projectCentroids[project] ?? .zero,
                count: counts[project] ?? 0, radius: (radii[project] ?? 0) + 40)
        }
        let dominant = counts.keys.sorted().max { (counts[$0] ?? 0) < (counts[$1] ?? 0) }
        galaxySnapshots = nodes.isEmpty ? [] : [RKGalaxySnapshot(id: graphID, displayName: title,
            worldCenter: .zero, dominantColor: dominant.flatMap { projectColorMap[$0] } ?? SIMD3(0.5, 0.5, 0.6),
            nodeCount: nodes.count, radius: galaxyRadius, parentGalaxyId: nil)]
        // The renderer anchors projects above their highest node and topics
        // above their highest member (including shared topic names across projects).
        // Reuse this aggregate pass; camera fitting never rematerializes node maps.
        var clusterAnchors: [ClusterAnchor] = []
        clusterAnchors.reserveCapacity(projectCentroids.count + topicStats.count)
        for project in projectCentroids.keys.sorted() {
            guard let centroid = projectCentroids[project], let top = projectMaxY[project] else { continue }
            clusterAnchors.append(ClusterAnchor(position: SIMD3(centroid.x,
                top + ClusterLabelKind.project.graphVerticalOffset, centroid.z), kind: .project))
        }
        for topic in topicStats.keys.sorted() {
            guard let stat = topicStats[topic], stat.count >= 2 else { continue }
            let centroid = stat.sum / Float(stat.count)
            clusterAnchors.append(ClusterAnchor(position: SIMD3(centroid.x,
                stat.maxY + ClusterLabelKind.topic.graphVerticalOffset, centroid.z), kind: .topic))
        }
        framingBounds = nodes.isEmpty ? nil : FramingBounds(center: center, radius: graphRadius,
            renderedRevision: renderedRevision, forceRevision: simulation.positionRevision,
            clusterAnchors: clusterAnchors)
        onFramingUpdate?()
    }

    func toggleHub(_ id: UUID) {
        guard hubs.contains(id) else { return }
        if !hubExpansion.expandedHubs.contains(id) {
            for child in hubExpansion.indexedChildren(of: id) { simulation.pin(child) }
        }
        hubExpansion.toggleIndexed(hub: id, positions: positionArray)
    }

    static let palette: [SIMD3<Float>] = [
        SIMD3(0.35, 0.80, 0.95), SIMD3(0.85, 0.55, 0.95), SIMD3(0.35, 0.85, 0.60),
        SIMD3(1.0, 0.70, 0.30), SIMD3(0.95, 0.40, 0.55), SIMD3(0.50, 0.65, 1.0)
    ]
}
