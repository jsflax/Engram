import Foundation

// MARK: - The memory contract
//
// `MemoryService` is THE seam: its operations are the recall/advise/remember
// semantics, not storage primitives. MCP (stdio and HTTP) is a thin transport
// above it; Lattice and Postgres are interchangeable conformances below it.
// Everything lattice-shaped (attach chains, live objects, transactions) or
// postgres-shaped (pools, outboxes) stays inside a conformance — it never
// appears in this file.
//
// v1 shape note: the core read/write operations are fully typed. The long
// tail (episodes, tasks, clustering, maintenance) currently speaks the same
// rendered-text contract the MCP tools always have; those signatures firm up
// as increment 1b migrates each handler. `capabilities` gates operations a
// backend cannot honestly implement (sqlite-file maintenance on Postgres) —
// the rule is "real effect or declared-unsupported, never a silent no-op."

/// A memory row as the contract sees it — the transport/DTO shape, never a
/// live storage object.
public struct MemoryRecord: Sendable, Codable, Identifiable {
    public var id: UUID
    public var content: String
    public var topic: String?
    public var project: String?
    public var source: String?
    public var importance: Int
    public var accessCount: Int
    public var isPrivate: Bool
    public var authorUserId: UUID?
    public var createdAt: Date
    public var modifiedAt: Date?
    public var lastAccessedAt: Date?
    public var expiresAt: Date?
    public var deletedAt: Date?
    public var deletedBy: UUID?

    public init(id: UUID, content: String, topic: String? = nil,
                project: String? = nil, source: String? = nil,
                importance: Int = 0, accessCount: Int = 0,
                isPrivate: Bool = false, authorUserId: UUID? = nil,
                createdAt: Date, modifiedAt: Date? = nil,
                lastAccessedAt: Date? = nil, expiresAt: Date? = nil,
                deletedAt: Date? = nil, deletedBy: UUID? = nil) {
        self.id = id
        self.content = content
        self.topic = topic
        self.project = project
        self.source = source
        self.importance = importance
        self.accessCount = accessCount
        self.isPrivate = isPrivate
        self.authorUserId = authorUserId
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.lastAccessedAt = lastAccessedAt
        self.expiresAt = expiresAt
        self.deletedAt = deletedAt
        self.deletedBy = deletedBy
    }
}

public struct EdgeRecord: Sendable, Codable, Identifiable {
    public var id: UUID
    public var sourceId: UUID
    public var targetId: UUID
    public var relation: String
    public var authorUserId: UUID?
    public var createdAt: Date

    public init(id: UUID, sourceId: UUID, targetId: UUID, relation: String,
                authorUserId: UUID? = nil, createdAt: Date) {
        self.id = id
        self.sourceId = sourceId
        self.targetId = targetId
        self.relation = relation
        self.authorUserId = authorUserId
        self.createdAt = createdAt
    }
}

// MARK: Requests / results — core surface

public struct RememberRequest: Sendable, Codable {
    public var content: String
    public var topic: String?
    public var project: String?
    public var source: String?
    public var importance: Int?
    public var isPrivate: Bool
    public var parentId: UUID?
    public var expiresInDays: Int?

    public init(content: String, topic: String? = nil, project: String? = nil,
                source: String? = nil, importance: Int? = nil,
                isPrivate: Bool = false, parentId: UUID? = nil,
                expiresInDays: Int? = nil) {
        self.content = content
        self.topic = topic
        self.project = project
        self.source = source
        self.importance = importance
        self.isPrivate = isPrivate
        self.parentId = parentId
        self.expiresInDays = expiresInDays
    }
}

public struct RememberResult: Sendable, Codable {
    public var id: UUID
    /// Human/agent-facing message (conflict warnings, decomposition nudges,
    /// auto-connect notes) — the MCP tool's rendered reply.
    public var message: String
    /// True when the vector could not be computed and the row was stored in
    /// the pending-embedding state (TEI outage path).
    public var embeddingPending: Bool

    public init(id: UUID, message: String, embeddingPending: Bool = false) {
        self.id = id
        self.message = message
        self.embeddingPending = embeddingPending
    }
}

/// How recall matched — analytics and clients must never compare distances
/// across modes (vector L2 vs FTS rank are incomparable scales).
public enum RecallMode: String, Sendable, Codable {
    case vector
    case fullText
}

public struct RecallRequest: Sendable, Codable {
    public var query: String
    public var project: String?
    /// Graph-traversal depth for the Connected section (0–3).
    public var depth: Int
    public var limit: Int

    public init(query: String, project: String? = nil, depth: Int = 1, limit: Int = 5) {
        self.query = query
        self.project = project
        self.depth = depth
        self.limit = limit
    }
}

public struct RecallHit: Sendable, Codable {
    public var memory: MemoryRecord
    /// Raw distance in the mode's scale (L2 for vector, rank-derived for FTS).
    public var distance: Double
    /// Post-boost ranking key (RecallRanking.boostedDistance) — vector mode only.
    public var boostedDistance: Double?
    /// 0 = direct hit; ≥1 = reached via graph traversal at that depth.
    public var depth: Int
    /// Foreign-authored relative to the service principal (drives fencing).
    public var isForeign: Bool
    /// Provenance when a service reads more than one explicitly granted graph.
    public var sourceGraphId: UUID?
    public var sourceGraphName: String?

    public init(memory: MemoryRecord, distance: Double,
                boostedDistance: Double? = nil, depth: Int = 0,
                isForeign: Bool = false, sourceGraphId: UUID? = nil,
                sourceGraphName: String? = nil) {
        self.memory = memory
        self.distance = distance
        self.boostedDistance = boostedDistance
        self.depth = depth
        self.isForeign = isForeign
        self.sourceGraphId = sourceGraphId
        self.sourceGraphName = sourceGraphName
    }
}

public struct RecallResult: Sendable, Codable {
    public var hits: [RecallHit]
    public var mode: RecallMode
    /// The MCP tool's rendered text — `[id:]`/`[by:]`/`[via:]` markers,
    /// fenced foreign rows, tombstone notices. The transport returns this
    /// verbatim; structured consumers use `hits`.
    public var renderedText: String

    public init(hits: [RecallHit], mode: RecallMode, renderedText: String) {
        self.hits = hits
        self.mode = mode
        self.renderedText = renderedText
    }
}

public struct AdviseRequest: Sendable, Codable {
    /// The raw prompt/event text — the service extracts content words itself.
    public var prompt: String
    public var project: String?
    /// Overall character budget for the returned block.
    public var budget: Int

    public init(prompt: String, project: String? = nil, budget: Int = 4000) {
        self.prompt = prompt
        self.project = project
        self.budget = budget
    }
}

public struct AdviseResult: Sendable, Codable {
    /// Injection-ready block ("## Relevant memories" + fenced content), or
    /// nil when nothing relevant surfaced — callers inject nothing.
    public var block: String?
    /// Ids of the memories inside the block, in rendered order — the
    /// feedback loop's join key (transcript matching → recall_feedback).
    public var memoryIds: [UUID]
    public var mode: RecallMode?
    /// Exact query and source-attributed hits for native Advise hook cards.
    /// Optional for compatibility with older remote backends.
    public var query: String?
    public var hits: [RecallHit]?

    public init(block: String?, memoryIds: [UUID] = [], mode: RecallMode? = nil,
                query: String? = nil, hits: [RecallHit]? = nil) {
        self.block = block
        self.memoryIds = memoryIds
        self.mode = mode
        self.query = query
        self.hits = hits
    }
}

public struct UpdateRequest: Sendable, Codable {
    public var id: UUID
    public var content: String?
    public var append: String?
    public var prepend: String?
    public var find: String?
    public var replace: String?
    public var topic: String?
    public var project: String?
    public var importance: Int?
    public var expiresInDays: Int?
    public var isPrivate: Bool?
    public var undelete: Bool

    public init(id: UUID, content: String? = nil, append: String? = nil,
                prepend: String? = nil, find: String? = nil,
                replace: String? = nil, topic: String? = nil,
                project: String? = nil, importance: Int? = nil,
                expiresInDays: Int? = nil, isPrivate: Bool? = nil,
                undelete: Bool = false) {
        self.id = id
        self.content = content
        self.append = append
        self.prepend = prepend
        self.find = find
        self.replace = replace
        self.topic = topic
        self.project = project
        self.importance = importance
        self.expiresInDays = expiresInDays
        self.isPrivate = isPrivate
        self.undelete = undelete
    }
}

public struct ForgetRequest: Sendable, Codable {
    public var id: UUID?
    public var topic: String?
    public var project: String?

    public init(id: UUID? = nil, topic: String? = nil, project: String? = nil) {
        self.id = id
        self.topic = topic
        self.project = project
    }
}

public struct ConnectRequest: Sendable, Codable {
    public var sourceId: UUID
    public var targetId: UUID
    public var relation: String

    public init(sourceId: UUID, targetId: UUID, relation: String) {
        self.sourceId = sourceId
        self.targetId = targetId
        self.relation = relation
    }
}

public struct GraphRequest: Sendable, Codable {
    public var id: UUID
    public var depth: Int

    public init(id: UUID, depth: Int = 1) {
        self.id = id
        self.depth = depth
    }
}

public struct GraphResult: Sendable, Codable {
    public var root: MemoryRecord
    public var nodes: [MemoryRecord]
    public var edges: [EdgeRecord]
    public var renderedText: String

    public init(root: MemoryRecord, nodes: [MemoryRecord],
                edges: [EdgeRecord], renderedText: String) {
        self.root = root
        self.nodes = nodes
        self.edges = edges
        self.renderedText = renderedText
    }
}

/// Rendered-text reply for the not-yet-structurally-typed tools. The MCP
/// layer passes it through verbatim.
public struct ToolReply: Sendable, Codable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// Operations a backend may legitimately not support. The transport omits
/// unsupported tools from its tool list; direct calls receive a typed
/// `MemoryServiceError.unsupported`.
public enum MemoryCapability: String, Sendable, Codable, CaseIterable {
    /// sqlite-file maintenance (vacuum, checkpoint, vector-index rebuild).
    case fileMaintenance
    /// Episode grouping (begin/end/recall/list).
    case episodes
    /// Task checkpointing (checkpoint/resume/list_tasks).
    case tasks
    /// Cluster analysis + consolidation (find_clusters, detect_communities,
    /// organize, consolidate).
    case clustering
}

public enum MemoryServiceError: Error, Sendable {
    case notFound(UUID)
    case unsupported(operation: String)
    case invalidArguments(String)
    case embeddingUnavailable
    case storageFailure(String)
}

// MARK: - The protocol

public protocol MemoryService: Sendable {
    /// The identity this service instance operates as.
    var principal: Principal { get }
    /// What this backend honestly supports.
    var capabilities: Set<MemoryCapability> { get }

    // Core reads
    func recall(_ request: RecallRequest) async throws -> RecallResult
    func advise(_ request: AdviseRequest) async throws -> AdviseResult
    func graph(_ request: GraphRequest) async throws -> GraphResult

    // Core writes
    func remember(_ request: RememberRequest) async throws -> RememberResult
    func update(_ request: UpdateRequest) async throws -> ToolReply
    func forget(_ request: ForgetRequest) async throws -> ToolReply
    func connect(_ request: ConnectRequest) async throws -> ToolReply
    func disconnect(_ request: ConnectRequest) async throws -> ToolReply
    /// Merge `ids` into one memory whose body is `content` (the tool's
    /// replacement-content semantics — there is no "absorb into target").
    func merge(ids: [UUID], content: String, topic: String?, project: String?) async throws -> ToolReply

    // Rendered-text surface (structured in 1b as handlers migrate).
    // `sessionKey` scopes conversational state (episodes) — the CLI passes
    // its Claude session id; the HTTP service passes the thread ref.
    func stats(project: String?) async throws -> ToolReply
    func listTopics(project: String?) async throws -> ToolReply
    func timeline(project: String?, groupBy: String?) async throws -> ToolReply

    func beginEpisode(title: String, sessionKey: String?) async throws -> ToolReply
    func endEpisode(summary: String?, sessionKey: String?) async throws -> ToolReply
    func recallEpisode(id: UUID, limit: Int?) async throws -> ToolReply
    func listEpisodes(limit: Int?) async throws -> ToolReply

    func checkpoint(title: String, sessionKey: String?) async throws -> ToolReply
    func resume(taskId: Int) async throws -> ToolReply
    func listTasks() async throws -> ToolReply

    func findClusters(project: String?) async throws -> ToolReply
    func detectCommunities(project: String) async throws -> ToolReply
    /// Group `ids` under a labeled hub memory (part_of edges to a new hub).
    func organize(ids: [UUID], label: String, project: String?, summary: String?) async throws -> ToolReply
    /// Collapse `ids` into one memory with `content`; `force` is required
    /// when the cluster contains foreign-authored rows.
    func consolidate(ids: [UUID], content: String, topic: String?, project: String?, force: Bool) async throws -> ToolReply

    func vacuum() async throws -> ToolReply
    func trainVectors() async throws -> ToolReply
}
