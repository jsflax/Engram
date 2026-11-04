import Foundation
import simd
import EngramMemoryCore
import EngramRealityKit
import EngramSceneKit

/// One exact, already-authorized snapshot mapped to Engram's existing scene protocol. No store
/// reads, registry singleton or transport. Per-frame arrays change only with actual publications.
@MainActor
final class GraphSceneData: SceneDataProvider {
    let simulation = ForceSimulation3D()
    private(set) var nodes: [RKNodeSnapshot] = []
    private(set) var edges: [RKEdgeSnapshot] = []
    private(set) var hubs: Set<UUID> = []
    private(set) var positions: [UUID: SIMD3<Float>] = [:]
    private(set) var positionArray: [SIMD3<Float>] = []
    private(set) var projectColorMap: [String: SIMD3<Float>] = [:]
    private(set) var projectCentroids: [String: SIMD3<Float>] = [:]
    private(set) var nebulaClusters: [RKNebulaCluster] = []
    private(set) var radius: Float = 0
    var selectedNode: UUID?
    let expandedHubs: Set<UUID> = []
    let searchMatchIds: Set<UUID> = []
    let isSearchActive = false
    let glowingNodes: [UUID: Float] = [:]
    let newNodeGlows: [UUID: Float] = [:]
    let dyingNodes: Set<UUID> = []
    private(set) var topologyVersion: UInt64 = 0
    private(set) var nodeVersion: UInt64 = 0
    private(set) var hubVersion: UInt64 = 0
    private(set) var edgeVersion: UInt64 = 0
    private(set) var positionVersion: UInt64 = 0
    private var sourceNodes: [EngramGraphNode] = []
    private var sourceEdges: [EngramGraphEdge] = []
    private var lastSimulationPositionVersion: UInt64?
    private var suppliedPositionIndices: [Int: SIMD3<Float>] = [:]
    private(set) var needsLayout = false
    var isLayoutPrepared = false
    var isActive = false { didSet { simulation.isActive = isActive && needsLayout } }

    init() { simulation.isActive = false }

    /// Returns whether simulation identity/topology changed, so the session can fence GPU results.
    @discardableResult
    func publish(_ snapshot: EngramGraphSnapshot) -> Bool {
        let oldIDs = sourceNodes.map(\.id), newIDs = snapshot.nodes.map(\.id)
        let metadataChanged = sourceNodes.count != snapshot.nodes.count ||
            !zip(sourceNodes, snapshot.nodes).allSatisfy { pair in Self.sameMetadata(pair.0, pair.1) }
        let hubs = Set(snapshot.edges.filter { $0.relation == "part_of" }.map(\.targetID))
        let hubsChanged = self.hubs != hubs
        let edgesChanged = sourceEdges != snapshot.edges
        let groupingChanged = sourceNodes.count != snapshot.nodes.count ||
            !zip(sourceNodes, snapshot.nodes).allSatisfy { pair in pair.0.id == pair.1.id && pair.0.project == pair.1.project && pair.0.topic == pair.1.topic }
        let structureChanged = groupingChanged || sourceEdges.map { EdgeEndpoints($0) } != snapshot.edges.map { EdgeEndpoints($0) }
        let positionsChanged = sourceNodes.count != snapshot.nodes.count ||
            !zip(sourceNodes, snapshot.nodes).allSatisfy { pair in pair.0.id == pair.1.id && pair.0.position == pair.1.position }
        if structureChanged {
            simulation.updateGraph(nodeIds: Set(newIDs), edges: snapshot.edges.map { ($0.sourceID, $0.targetID) },
                projectForNode: Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0.project) }),
                topicForNode: Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0.topic) }))
        }
        let priorPositions = Dictionary(uniqueKeysWithValues: sourceNodes.map { ($0.id, $0.position) })
        var supplied: [UUID: SIMD3<Float>] = [:]
        for node in snapshot.nodes {
            if let position = node.position, (priorPositions[node.id] ?? nil) != position {
                supplied[node.id] = Self.vector(position)
            }
        }
        if !supplied.isEmpty { simulation.setPositions(supplied) }
        if structureChanged || positionsChanged {
            let suppliedByID = Dictionary(uniqueKeysWithValues: snapshot.nodes.compactMap { node in
                node.position.map { (node.id, Self.vector($0)) }
            })
            suppliedPositionIndices = Dictionary(uniqueKeysWithValues: simulation.nodeIds.enumerated().compactMap { index, id in
                suppliedByID[id].map { (index, $0) }
            })
        }
        needsLayout = snapshot.nodes.contains { $0.position == nil }
        simulation.isActive = isActive && needsLayout
        if metadataChanged || hubsChanged {
            nodes = snapshot.nodes.map { node in
                RKNodeSnapshot(id: node.id, project: node.project, topic: node.topic, label: node.label,
                    content: node.content, importance: node.importance, isHub: hubs.contains(node.id),
                    createdAt: node.createdAt, lastAccessedAt: node.lastAccessedAt)
            }
        }
        if metadataChanged { nodeVersion &+= 1 }
        if hubsChanged { self.hubs = hubs; hubVersion &+= 1 }
        if edgesChanged {
            edges = snapshot.edges.map { RKEdgeSnapshot(id: $0.id, sourceId: $0.sourceID, targetId: $0.targetID, relation: $0.relation) }
            edgeVersion &+= 1
        }
        if metadataChanged || hubsChanged || edgesChanged { topologyVersion &+= 1 }
        if projectColorMap.isEmpty && !snapshot.nodes.isEmpty {
            // The existing single-project palette's first golden-angle hue (global stays gray).
            projectColorMap = [snapshot.scope.project: snapshot.scope.project == "global" ? SIMD3(repeating: 0.5) : SIMD3(0.9, 0.315, 0.315)]
        }
        sourceNodes = snapshot.nodes; sourceEdges = snapshot.edges
        refreshPositions(force: oldIDs != newIDs)
        if let selectedNode, positions[selectedNode] == nil { self.selectedNode = nil }
        return structureChanged || positionsChanged
    }

    func tick(dt: Float) {
        guard isActive else { return }
        // The shared simulation recenters a singleton on its first tick. Keep the already-fitted
        // seeded/supplied position instead; a single node needs no force layout.
        if needsLayout && isLayoutPrepared && nodes.count > 1 { simulation.tick() }
        refreshPositions()
    }

    /// Supplied coordinates are authoritative even when other nodes need layout. Only their
    /// indices are cached; rebuild that cache with every node-order or position-policy change.
    func preservingSuppliedPositions(in result: ForceResult) -> ForceResult {
        guard !suppliedPositionIndices.isEmpty, var positions = result.positions else { return result }
        for (index, position) in suppliedPositionIndices where positions.indices.contains(index) {
            positions[index] = position
        }
        var constrained = ForceResult(positions: positions, diagnosticEnqueuedAt: result.diagnosticEnqueuedAt)
        constrained.cpuPrepMs = result.cpuPrepMs; constrained.gpuMs = result.gpuMs
        constrained.readbackMs = result.readbackMs; constrained.algorithm = result.algorithm
        return constrained
    }

    func refreshPositions(force: Bool = false) {
        guard force || lastSimulationPositionVersion != simulation.positionVersion else { return }
        lastSimulationPositionVersion = simulation.positionVersion
        positions = simulation.positions
        positionArray = nodes.map { positions[$0.id] ?? .zero }
        positionVersion &+= 1
        guard let project = nodes.first?.project, !positionArray.isEmpty else {
            projectCentroids = [:]; nebulaClusters = []; radius = 0; return
        }
        let center = positionArray.reduce(SIMD3<Float>.zero, +) / Float(positionArray.count)
        radius = positionArray.reduce(Float(0)) { max($0, simd_length($1 - center)) }
        projectCentroids = [project: center]
        nebulaClusters = [RKNebulaCluster(galaxyId: "main", project: project, centroid: center,
                                        count: nodes.count, radius: radius)]
    }

    func clear() {
        isActive = false
        simulation.updateGraph(nodeIds: [], edges: [])
        sourceNodes = []; sourceEdges = []; nodes = []; edges = []; hubs = []
        positions = [:]; positionArray = []; projectColorMap = [:]; projectCentroids = [:]; nebulaClusters = []
        selectedNode = nil; needsLayout = false; radius = 0; lastSimulationPositionVersion = nil
        isLayoutPrepared = false
        suppliedPositionIndices = [:]
        topologyVersion &+= 1; nodeVersion &+= 1; edgeVersion &+= 1; hubVersion &+= 1; positionVersion &+= 1
    }

    static func vector(_ value: EngramGraphPosition) -> SIMD3<Float> { SIMD3(Float(value.x), Float(value.y), Float(value.z)) }
    private static func sameMetadata(_ a: EngramGraphNode, _ b: EngramGraphNode) -> Bool {
        a.id == b.id && a.project == b.project && a.topic == b.topic && a.label == b.label &&
        a.content == b.content && a.importance == b.importance && a.createdAt == b.createdAt && a.lastAccessedAt == b.lastAccessedAt
    }
    private struct EdgeEndpoints: Equatable {
        let id: UUID, source: UUID, target: UUID
        init(_ edge: EngramGraphEdge) { id = edge.id; source = edge.sourceID; target = edge.targetID }
    }
}
