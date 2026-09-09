import Foundation
import simd

/// Per-galaxy aggregate for render systems that think in GALAXIES rather
/// than nodes: titles, far-LOD gas, and bridges. The provider flattens
/// galaxy identity out of nodes at merge time, so anything galaxy-shaped
/// has to travel separately.
public struct RKGalaxySnapshot: Sendable {
    public let id: String
    public let displayName: String
    public let worldCenter: SIMD3<Float>
    /// Color of the galaxy's largest project — the single-color far gas.
    public let dominantColor: SIMD3<Float>
    public let nodeCount: Int
    /// Max node distance from worldCenter — the galaxy's visual extent.
    public let radius: Float
    public let parentGalaxyId: String?

    public var isGroup: Bool { id.hasPrefix("group:") }

    public init(id: String, displayName: String, worldCenter: SIMD3<Float>,
                dominantColor: SIMD3<Float>, nodeCount: Int, radius: Float,
                parentGalaxyId: String?) {
        self.id = id
        self.displayName = displayName
        self.worldCenter = worldCenter
        self.dominantColor = dominantColor
        self.nodeCount = nodeCount
        self.radius = radius
        self.parentGalaxyId = parentGalaxyId
    }
}

/// One nebula-worthy cluster: a project's nodes WITHIN one galaxy.
///
/// Keyed by (galaxy, project), never bare project: a project whose rows
/// span two galaxies (private rows stay personal while the rest render in
/// synced/group) used to get ONE nebula at the cross-galaxy blended
/// centroid — parked thousands of units off both clusters, which is why
/// the personal cloud looked gasless.
public struct RKNebulaCluster: Sendable {
    public let galaxyId: String
    public let project: String
    public let centroid: SIMD3<Float>
    public let count: Int
    /// Live cluster radius — recomputed with the centroid pass, so nebulae
    /// can RESIZE (creation-frozen radii left mid-load clusters invisible).
    public let radius: Float

    public var key: String { "\(galaxyId)|\(project)" }

    public init(galaxyId: String, project: String, centroid: SIMD3<Float>,
                count: Int, radius: Float) {
        self.galaxyId = galaxyId
        self.project = project
        self.centroid = centroid
        self.count = count
        self.radius = radius
    }
}

/// Core abstraction for all data the RealityKit scene needs per frame.
///
/// EngramVisualizer implements this via GalaxyRegistryAdapter;
/// EngramPreview implements with mock data.
@MainActor
public protocol SceneDataProvider: AnyObject {
    /// All nodes to potentially render (LOD system filters these).
    var nodes: [RKNodeSnapshot] { get }
    /// All edges to potentially render.
    var edges: [RKEdgeSnapshot] { get }
    /// Hub node IDs.
    var hubs: Set<UUID> { get }
    /// Project → color mapping.
    var projectColorMap: [String: SIMD3<Float>] { get }
    /// Current positions for all nodes.
    var positions: [UUID: SIMD3<Float>] { get }
    /// Nodes with active recall glow — value is elapsed seconds since glow start.
    var glowingNodes: [UUID: Float] { get }
    /// Nodes with arrival glow — value is elapsed seconds since creation.
    var newNodeGlows: [UUID: Float] { get }
    /// Nodes being deleted (dying animation).
    var dyingNodes: Set<UUID> { get }
    /// Currently selected node.
    var selectedNode: UUID? { get set }
    /// Hubs that have been expanded.
    var expandedHubs: Set<UUID> { get }
    /// Node IDs matching current search.
    var searchMatchIds: Set<UUID> { get }
    /// Whether search mode is active (dims non-matching nodes).
    var isSearchActive: Bool { get }
    /// Centroid position per project cluster.
    var projectCentroids: [String: SIMD3<Float>] { get }
    /// Increments on topology or render metadata changes (including labels/hubs).
    var topologyVersion: UInt64 { get }
    /// Increments when positions or their node ordering change; stable while idle.
    var positionVersion: UInt64 { get }

    /// Positions as a flat array indexed parallel to `nodes`. Avoids UUID dict lookups.
    var positionArray: [SIMD3<Float>] { get }

    /// Per-galaxy aggregates (titles, far-LOD gas, bridges).
    var galaxySnapshots: [RKGalaxySnapshot] { get }
    /// Per-(galaxy, project) nebula clusters.
    var nebulaClusters: [RKNebulaCluster] { get }

    /// Per-frame update — drain pending changes, tick simulation.
    func tick(dt: Float)
}

extension SceneDataProvider {
    public var positionArray: [SIMD3<Float>] {
        nodes.map { positions[$0.id] ?? .zero }
    }

    /// Defaults keep single-galaxy providers (EngramPreview's mock) working
    /// unchanged: everything is one "main" galaxy, clusters derive from the
    /// same projectCentroids the old nebula path used.
    public var galaxySnapshots: [RKGalaxySnapshot] { [] }
    public var nebulaClusters: [RKNebulaCluster] {
        // Keep the default's missing-position semantics, but scan all nodes
        // once rather than once per project and read the position map once.
        deriveSingleGalaxyNebulaClusters(nodes: nodes, centroids: projectCentroids,
                                         positionArray: [], positions: { positions })
    }
}
