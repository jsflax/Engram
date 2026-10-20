import Foundation
import Lattice
import EngramModels
import EngramMemoryCore

/// Durable agent identity and its private graph. Names, rooms, models, and hosts
/// may change without changing either identifier.
public struct AgentMemoryBinding: Sendable, Codable, Equatable {
    public let agentId: UUID
    public let graphId: UUID
    public let displayName: String?

    public init(agentId: UUID, graphId: UUID? = nil, displayName: String? = nil) {
        self.agentId = agentId
        self.graphId = graphId ?? agentId
        self.displayName = displayName
    }
}

/// An explicitly granted recall source. The owner opens and synchronizes this
/// store; the agent never writes it, even for access counters or maintenance.
/// Removing/renaming the source file revokes it on the next recall.
public struct AgentMemorySource: Sendable {
    public let graphId: UUID
    public let name: String
    public let fileURL: URL
    public let reference: LatticeThreadSafeReference

    public init(graphId: UUID, name: String, fileURL: URL,
                reference: LatticeThreadSafeReference) {
        self.graphId = graphId
        self.name = name
        self.fileURL = fileURL
        self.reference = reference
    }
}

public struct AgentMemoryStatus: Sendable, Codable, Equatable {
    public struct SharedSource: Sendable, Codable, Equatable {
        public let graphId: UUID
        public let name: String
        public let isAvailable: Bool
    }

    public let binding: AgentMemoryBinding?
    public let memoryCount: Int
    public let pendingEmbeddingCount: Int
    public let sharedSources: [SharedSource]
}

public enum AgentMemoryStore {
    public static var schema: [any Model.Type] {
        [Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self,
         GroupProjectMap.self, AgentMemoryGraph.self, AgentMemoryTransferManifest.self, AgentMemoryWriterFence.self]
    }

    public static func configuration(fileURL: URL) -> Lattice.Configuration {
        // A relay or transfer verifier may be the graph's first opener. Keep
        // every opener bounded so a competing writer cannot stall UI/dispatch.
        var configuration = Lattice.Configuration(fileURL: fileURL, migration: AgentMemorySchema.migrations, busyTimeoutMs: 2_000)
        var filter = Lattice.SyncFilter()
        for model in schema where model.entityName != AgentMemoryWriterFence.entityName { filter.include(model) }
        configuration.syncFilter = filter
        return configuration
    }

    public static func fileURL(binding: AgentMemoryBinding, directory: URL) -> URL {
        directory.appendingPathComponent(binding.graphId.uuidString.lowercased())
            .appendingPathExtension("sqlite")
    }

    /// Opens the existing Lattice MemoryService with a fixed, private write
    /// graph. It does not discover personal memory, credentials, or hooks.
    public static func open(binding: AgentMemoryBinding, directory: URL,
                            sharedSources: [AgentMemorySource] = [],
                            embedder: any Embedder = UnavailableMemoryEmbedder()) throws -> MemoryTools {
        guard sharedSources.count <= 8 else {
            throw MemoryServiceError.invalidArguments("At most eight shared recall sources can be attached")
        }
        let ids = sharedSources.map(\.graphId)
        guard Set(ids).count == ids.count, !ids.contains(binding.graphId) else {
            throw MemoryServiceError.invalidArguments("Shared graph identities must be unique and exclude the private graph")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = fileURL(binding: binding, directory: directory)
        let lattice = try Lattice(for: schema, configuration: configuration(fileURL: file))
        try lattice.withTransaction {
            let bindingRows = lattice.objects(AgentMemoryGraph.self).snapshot()
            if let existing = bindingRows.first {
                guard bindingRows.count == 1, existing.agentId == binding.agentId,
                      existing.graphId == binding.graphId else {
                    throw MemoryServiceError.invalidArguments("This memory graph belongs to a different agent")
                }
            } else {
                try lattice.add(AgentMemoryGraph(agentId: binding.agentId, graphId: binding.graphId),
                                preservingGlobalId: binding.graphId)
            }
        }
        let sources = sharedSources.map { source in
            MemoryTools.GroupSpokeRef(groupId: source.graphId, path: source.fileURL.path,
                                      ref: source.reference)
        }
        return MemoryTools(localRef: lattice.sendableReference, syncedRef: nil,
                           groupRefs: sources, embedder: embedder,
                           identity: StaticIdentityProvider(Principal(id: binding.agentId, kind: .agent,
                                                                       displayName: binding.displayName)),
                           privateGraphOnly: true, graphBinding: binding,
                           sharedGraphNames: Dictionary(uniqueKeysWithValues: sharedSources.map { ($0.graphId, $0.name) }))
    }
}

/// An honest no-model state for first launch and fully offline operation.
public struct UnavailableMemoryEmbedder: Embedder {
    public init() {}
    public var dimension: Int { 384 }
    public func embed(text: String) async throws -> [Float]? { nil }
}

extension MemoryTools {
    // Desktop hook diagnostics must never receive an embedded agent's private
    // memories or queries. Hosts own their own telemetry and retention policy.
    func log(_ message: String) {
        guard !privateGraphOnly else { return }
        EngramLattice.log(message)
    }

    func sessionLog(_ message: String) {
        guard !privateGraphOnly else { return }
        EngramMemoryCore.sessionLog(message)
    }

    func appendSessionSaveLog(sessionId: String?, globalId: String, project: String, topic: String, preview: String) {
        guard !privateGraphOnly else { return }
        EngramLattice.appendSessionSaveLog(sessionId: sessionId, globalId: globalId,
                                           project: project, topic: topic, preview: preview)
    }

    public nonisolated var agentMemoryBinding: AgentMemoryBinding? { graphBinding }

    /// For the embedding host's Lattice sync coordinator, never exposed as a
    /// model tool. Resolving it preserves the complete registered graph schema.
    public var privateGraphReference: LatticeThreadSafeReference { localLattice.sendableReference }
    public var privateGraphURL: URL { localLattice.configuration.fileURL }

    /// A local, typed snapshot for agent settings. Counts concern the private
    /// graph only; shared-source availability is checked without opening it.
    public func agentMemoryStatus() -> AgentMemoryStatus {
        defer { retireAllReadMarks() }
        let memories = localLattice.objects(Memory.self)
            .where { $0.deletedAt == nil }.snapshot()
        return AgentMemoryStatus(
            binding: graphBinding,
            memoryCount: memories.count,
            pendingEmbeddingCount: memories.filter { $0.embeddingPending == true }.count,
            sharedSources: groupSpokes.map { source in
                AgentMemoryStatus.SharedSource(
                    graphId: source.groupId,
                    name: sharedGraphNames[source.groupId] ?? source.groupId.uuidString,
                    isAvailable: FileManager.default.fileExists(atPath: source.path))
            })
    }

    /// A network/model failure must not discard a user's memory. Cancellation
    /// still aborts before the write; malformed vectors enter the pending path.
    func embedding(for content: String) async throws -> [Float]? {
        do {
            try Task.checkCancellation()
            guard let vector = try await embedder.embed(text: content),
                  !vector.isEmpty, vector.count == (await embedder.dimension),
                  vector.allSatisfy(\.isFinite) else { return nil }
            try Task.checkCancellation()
            return vector
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    func hasPendingEmbeddings(in lattice: Lattice) -> Bool {
        lattice.objects(Memory.self)
            .where { $0.embeddingPending == true && $0.deletedAt == nil }.first != nil
    }

    /// Indexes a bounded batch after a compatible embedder becomes available.
    /// Re-check the content after the await so an edit cannot acquire a stale vector.
    @discardableResult
    public func backfillPendingEmbeddings(limit: Int = 32) async throws -> Int {
        defer { retireAllReadMarks() }
        let pending = localLattice.objects(Memory.self)
            .where { $0.embeddingPending == true && $0.deletedAt == nil }.snapshot()
        var completed = 0
        for memory in pending.prefix(max(0, min(limit, 256))) {
            guard let id = memory.globalId else { continue }
            let content = memory.content
            guard let vector = try await embedding(for: content) else { break }
            guard let (current, _) = findWritableMemory(id: id), current.deletedAt == nil,
                  current.content == content, current.embeddingPending == true else { continue }
            localLattice.transaction {
                current.embedding = Vector<Float>(vector)
                current.embeddingPending = false
            }
            completed += 1
        }
        return completed
    }
}
