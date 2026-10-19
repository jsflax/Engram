import SwiftUI
import EngramKit

// MARK: - File-level helpers

func extractLabel(content: String, topic: String) -> String {
    let maxLen = 30
    if let headerRange = content.range(of: #"^#{1,3}\s+"#, options: .regularExpression) {
        let title = content[headerRange.upperBound...].prefix(while: { $0 != "\n" })
        return truncateLabel(String(title), to: maxLen)
    }
    if content.hasPrefix("**"), let end = content.dropFirst(2).range(of: "**") {
        let title = content[content.index(content.startIndex, offsetBy: 2)..<end.lowerBound]
        return truncateLabel(String(title), to: maxLen)
    }
    if let colon = content.firstIndex(of: ":"),
       content.distance(from: content.startIndex, to: colon) < maxLen {
        return String(content[..<colon])
    }
    let firstLine = String(content.prefix(while: { $0 != "\n" }))
    if firstLine.count <= maxLen { return firstLine }
    if topic != "general" {
        let combined = "\(topic): \(firstLine)"
        if combined.count <= maxLen { return combined }
        // Topic fits — truncate content only
        if topic.count + 2 + 5 <= maxLen {
            return "\(topic): \(truncateLabel(firstLine, to: maxLen - topic.count - 2))"
        }
        // Topic too long — truncate both
        let prefix = truncateLabel(topic, to: 12)
        return "\(prefix): \(truncateLabel(firstLine, to: maxLen - prefix.count - 2))"
    }
    return truncateLabel(firstLine, to: maxLen)
}

func truncateLabel(_ text: String, to maxLen: Int) -> String {
    if text.count <= maxLen { return text }
    return String(text.prefix(maxLen - 1)) + "…"
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
        didSet {
            _recentNodes = nil
            nodesVersion &+= 1
            if !appendingVisibleNode { nodeAppendGeneration &+= 1 }
        }
    }
    /// Top 50 nodes by createdAt — lazily sorted, cached until `nodes` changes.
    var recentNodes: [NodeData] {
        if let cached = _recentNodes { return cached }
        let sorted = Array(nodes.sorted(by: { $0.createdAt > $1.createdAt }).prefix(50))
        _recentNodes = sorted
        return sorted
    }
    private var _recentNodes: [NodeData]?
    var nodeById: [UUID: NodeData] = [:] {
        didSet {
            nodeLookupVersion &+= 1
            if !appendingVisibleNode { nodeLookupAppendGeneration &+= 1 }
        }
    }
    var edges: [EdgeData] = [] { didSet { edgesVersion &+= 1 } }
    var hubs: Set<UUID> = [] { didSet { hubsVersion &+= 1 } }
    private(set) var nodesVersion: UInt64 = 0
    private(set) var edgesVersion: UInt64 = 0
    private(set) var hubsVersion: UInt64 = 0
    private(set) var nodeLookupVersion: UInt64 = 0
    private(set) var allEdgesVersion: UInt64 = 0
    private(set) var nodeAppendGeneration: UInt64 = 0
    private(set) var nodeLookupAppendGeneration: UInt64 = 0
    private var appendingVisibleNode = false

    /// Only this store-owned mutation certifies that every existing node is
    /// unchanged. Ordinary assignment, subscript edits, removals and reorders
    /// invalidate continuity, even when count and topology happen to match.
    func appendVisibleNode(_ node: NodeData) {
        if nodeById[node.id] != nil { nodeLookupAppendGeneration &+= 1 }
        appendingVisibleNode = true
        nodes.append(node)
        nodeById[node.id] = node
        appendingVisibleNode = false
    }
    var colorMap: [String: Color] = [:] {
        didSet { colorMapVersion &+= 1 }
    }
    /// Incremented whenever colorMap changes. Scene checks this to invalidate its SIMD cache.
    private(set) var colorMapVersion: UInt64 = 0

    /// General render publication, including load status and derived metadata.
    /// Consumers of individual arrays use the domain revisions above instead.
    private(set) var topologyVersion: UInt64 = 0
    func bumpTopology() { topologyVersion &+= 1 }

    // Internal data — never triggers SwiftUI body re-evaluation.
    var allNodes: [UUID: NodeData] = [:]
    var allEdges: [UUID: EdgeData] = [:] { didSet { allEdgesVersion &+= 1 } }
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
