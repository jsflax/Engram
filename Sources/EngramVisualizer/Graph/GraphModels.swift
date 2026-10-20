import EngramGraphUI
import SwiftUI
import EngramKit

// MARK: - File-level helpers

func extractLabel(content: String, topic: String) -> String {
    engramGraphLabel(content: content, topic: topic)
}

func truncateLabel(_ text: String, to maxLen: Int) -> String {
    engramGraphTruncateLabel(text, to: maxLen)
}

// MARK: - Lightweight data structs (replaces heavy Lattice model objects)

struct NodeData: Sendable {
    let id: UUID
    let project: String
    let topic: String
    let label: String
    let content: String
    let createdAt: Date
    var lastAccessedAt: Date
    let importance: Int
}

struct EdgeData: Sendable {
    let id: UUID        // Edge globalId (stable across DBs for cross-galaxy dedup)
    let sourceId: UUID
    let targetId: UUID
    let relation: String
}

struct DyingNode {
    let id: UUID
    let position: CGPoint
    let project: String
    let isHub: Bool
    let importance: Int
    let startTime: Date
}

/// Shared render data store — written by GraphView (insertNodeBatch, handleNodeChange, etc.),
/// read by Graph3DScene's renderTick. Both run on MainActor, so no race.
/// NOT @Observable — must not trigger SwiftUI re-evaluation.
@MainActor
final class GraphRenderStore {
    var nodes: [NodeData] = [] {
        didSet { _recentNodes = nil }
    }
    /// Top 50 nodes by createdAt — lazily sorted, cached until `nodes` changes.
    var recentNodes: [NodeData] {
        if let cached = _recentNodes { return cached }
        let sorted = Array(nodes.sorted(by: { $0.createdAt > $1.createdAt }).prefix(50))
        _recentNodes = sorted
        return sorted
    }
    private var _recentNodes: [NodeData]?
    var nodeById: [UUID: NodeData] = [:]
    var edges: [EdgeData] = []
    var hubs: Set<UUID> = []
    var colorMap: [String: Color] = [:] {
        didSet { colorMapVersion &+= 1 }
    }
    /// Incremented whenever colorMap changes. Scene checks this to invalidate its SIMD cache.
    private(set) var colorMapVersion: UInt64 = 0

    /// Incremented when nodes/hubs/projects change. Replaces O(n) Set comparison per frame in atlas check.
    private(set) var topologyVersion: UInt64 = 0
    func bumpTopology() { topologyVersion &+= 1 }

    // Internal data — never triggers SwiftUI body re-evaluation.
    var allNodes: [UUID: NodeData] = [:]
    var allEdges: [UUID: EdgeData] = [:]
    var edgesByNode: [UUID: [EdgeData]] = [:]
    var pkToGlobalId: [Int64: UUID] = [:]
    var edgePkToGlobalId: [Int64: UUID] = [:]
    var filteredEdgeIds: Set<UUID> = []
    var visibleNodeIds: Set<UUID> = []
    var edgeCountByNode: [UUID: Int] = [:]

    // Visual effects — written by GraphView's observers/timers, read by MetalSceneManager's renderTick.
    var glowingNodes: [UUID: Date] = [:]
    var newNodeGlows: [UUID: Date] = [:]
    var dyingNodes: [UUID: DyingNode] = [:]
    /// Nodes being conjured by a mascot — scale 0→1 over 1.5s. Key = node UUID, value = start time.
    var birthingNodes: [UUID: Date] = [:]

    // Derived display data — recomputed on structural changes.
    var topicGroups: [TopicGroupInfo] = []
    var relationCounts: [(key: String, value: Int)] = []
    var clusterGroups: [[UUID]] = []

    // Search state — pushed from @State bindings (SearchBarView writes via Binding).
    var searchMatchIds: Set<UUID> = []
    var isSearchActive: Bool = false

    // Batched observer coalescing — accumulates inserts (pre-built on background thread)
    // and flushes once per run loop iteration. No Lattice reads on main thread.
    var pendingNodeInserts: [(pk: Int64, node: NodeData)] = []
    var pendingEdgeInserts: [(pk: UUID, edge: EdgeData)] = []
    var pendingNodeFlush: Task<Void, Never>?
    var pendingEdgeFlush: Task<Void, Never>?
}

// MARK: - Perf tracking (writable from Canvas closure)

final class PerfStats: @unchecked Sendable {
    var lastFrameTime: CFAbsoluteTime = 0
    var fps: Double = 0
    var drawMs: Double = 0
    var hullMs: Double = 0
    var edgeMs: Double = 0
    var nodeMs: Double = 0
}
