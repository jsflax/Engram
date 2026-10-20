import EngramLattice
import Foundation
import Lattice
import MCP
import Testing

@Suite("Portable agent memory")
struct AgentMemoryStoreTests {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agent-memory-tests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func offlineMemorySurvivesReopenAndIdentityRename() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let binding = AgentMemoryBinding(agentId: id, displayName: "Astra")
        let service = try AgentMemoryStore.open(binding: binding, directory: dir)
        let stored = try await service.remember(.init(content: "violet lighthouse orbital offline fixture"))
        #expect(stored.embeddingPending)
        let reopened = try AgentMemoryStore.open(binding: .init(agentId: id, displayName: "Renamed Astra"), directory: dir)
        let recalled = try await reopened.recall(.init(query: "violet lighthouse", depth: 0))
        #expect(recalled.mode == .fullText)
        #expect(recalled.hits.contains { $0.memory.id == stored.id && $0.memory.authorUserId == id })
        let peer = try AgentMemoryStore.open(binding: .init(agentId: UUID()), directory: dir)
        #expect(try await peer.recall(.init(query: "violet lighthouse")).hits.isEmpty)
        #expect(throws: MemoryServiceError.self) {
            try AgentMemoryStore.open(binding: .init(agentId: UUID(), graphId: binding.graphId), directory: dir)
        }
    }

    @Test func sharedGraphIsReadOnlyAcrossMutationsAndMaintenance() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = dir.appendingPathComponent("shared.sqlite")
        let source = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self,
                                 GroupProjectMap.self, configuration: .init(fileURL: sourceURL))
        let first = Memory(content: "quartz otter shared architecture", topic: "fixture")
        let second = Memory(content: "quartz otter related decision", topic: "fixture")
        try source.add(first); try source.add(second)
        let episode = Memory(content: "Shared episode", topic: "episode")
        try source.add(episode)
        let episodeId = try #require(episode.globalId)
        let firstId = try #require(first.globalId), secondId = try #require(second.globalId)
        let edge = Edge(sourceGlobalId: firstId, targetGlobalId: secondId, relation: .partOf)
        try source.add(edge)
        let edgeId = try #require(edge.globalId)
        let service = try AgentMemoryStore.open(binding: .init(agentId: UUID()), directory: dir,
             sharedSources: [.init(graphId: UUID(), name: "Personal", fileURL: sourceURL, reference: source.sendableReference)])
        #expect(try await service.recall(.init(query: "quartz otter", depth: 0)).hits.count == 2)
        let advice = try await service.advise(.init(prompt: "quartz otter"))
        #expect(advice.query?.contains("quartz") == true)
        #expect(advice.hits?.allSatisfy { $0.sourceGraphName == "Personal" } == true)
        #expect(try await service.handle(.init(name: "end_episode", arguments: ["episode_id": .string(episodeId.uuidString), "summary": .string("unauthorized")])).isError == true)
        #expect(try await service.update(.init(id: firstId, content: "unauthorized")).isError)
        #expect(try await service.forget(.init(id: firstId)).isError)
        #expect(try await service.connect(.init(sourceId: firstId, targetId: secondId, relation: "relates_to")).isError)
        #expect(try await service.disconnect(.init(sourceId: firstId, targetId: secondId, relation: "part_of")).isError)
        #expect(try await service.handle(.init(name: "disconnect", arguments: ["id": .string(edgeId.uuidString)])).isError == true)
        #expect(try await service.merge(ids: [firstId, secondId], content: "merged", topic: nil, project: nil).isError)
        #expect(try await service.organize(ids: [firstId, secondId], label: "hub", project: nil, summary: nil).isError)
        #expect(try await service.consolidate(ids: [firstId, secondId], content: "summary", topic: nil, project: nil, force: true).isError)
        do {
            _ = try await service.remember(.init(content: "invalid parent fixture", parentId: firstId))
            Issue.record("Shared source parent must not create a private cross-graph edge")
        } catch { }
        _ = try await service.forget(.init(topic: "fixture", project: "global"))
        _ = try await service.vacuum()
        _ = try await service.trainVectors()
        #expect(source.objects(Memory.self).count == 3)
        #expect(source.objects(Edge.self).count == 1)
        #expect(source.objects(Memory.self).where { $0.globalId == firstId }.first?.content == first.content)
        #expect(source.objects(Memory.self).where { $0.globalId == firstId }.first?.accessCount == 0)
        #expect(try await service.backfillPendingEmbeddings() == 0)
        try FileManager.default.moveItem(at: sourceURL, to: sourceURL.appendingPathExtension("revoked"))
        #expect(try await service.recall(.init(query: "quartz otter", depth: 0)).hits.isEmpty)
    }

    @Test func existingMemorySchemaMigratesWithoutLosingIdentityOrContent() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let binding = AgentMemoryBinding(agentId: UUID())
        let file = AgentMemoryStore.fileURL(binding: binding, directory: dir)
        let old = try Lattice(MemorySchemaV3.Memory.self, Edge.self, Checkpoint.self, HookState.self,
                              SyncConfig.self, GroupProjectMap.self,
                              configuration: .init(fileURL: file, migration: [3: Migration()]))
        let memory = MemorySchemaV3.Memory(content: "legacy topaz compass", topic: "old", importance: 4)
        try old.add(memory)
        let id = try #require(memory.globalId)
        old.checkpoint()
        old.close()
        let opened = try AgentMemoryStore.open(binding: binding, directory: dir, embedder: FixedEmbedder())
        let result = try await opened.recall(.init(query: "topaz compass", depth: 0))
        #expect(result.mode == .fullText)
        #expect(result.hits.contains { $0.memory.id == id && $0.memory.importance == 4 && $0.memory.topic == "old" })
        #expect(try await opened.backfillPendingEmbeddings() == 1)
    }

    @Test func legacySharedSourceStaysReadOnlyAndUnmodified() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("legacy-shared.sqlite")
        let old = try Lattice(MemorySchemaV3.Memory.self, Edge.self, Checkpoint.self, HookState.self,
                              SyncConfig.self, GroupProjectMap.self,
                              configuration: .init(fileURL: file, migration: [3: Migration()]))
        try old.add(MemorySchemaV3.Memory(content: "legacy amber otter"))
        old.checkpoint()
        old.close()
        let before = try Data(contentsOf: file)
        let readOnly = try Lattice(MemorySchemaV3.Memory.self, Edge.self, Checkpoint.self, HookState.self,
                                   SyncConfig.self, GroupProjectMap.self,
                                   configuration: .init(fileURL: file, isReadOnly: true))
        let service = try AgentMemoryStore.open(binding: .init(agentId: UUID()), directory: dir,
            sharedSources: [.init(graphId: UUID(), name: "Legacy personal", fileURL: file, reference: readOnly.sendableReference)])
        #expect(readOnly.objects(MemorySchemaV3.Memory.self).count == 1)
        let local = try #require(await service.privateGraphReference.resolve())
        let union = try local.attaching(lattice: readOnly)
        #expect(union.objects(Memory.self).count == 1)
        let result = try await service.recall(.init(query: "amber otter", depth: 0))
        #expect(result.hits.count == 1)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func embeddingFailurePersistsButCancellationDoesNot() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let unavailable = try AgentMemoryStore.open(binding: .init(agentId: UUID()), directory: dir,
                                                     embedder: FailingEmbedder(cancel: false))
        #expect(try await unavailable.remember(.init(content: "offline network outage persists")).embeddingPending)
        let cancelled = try AgentMemoryStore.open(binding: .init(agentId: UUID()), directory: dir,
                                                   embedder: FailingEmbedder(cancel: true))
        await #expect(throws: CancellationError.self) {
            try await cancelled.remember(.init(content: "cancelled write must not persist"))
        }
    }

    @Test func pendingEmbeddingsBackfillAndOfflineEditsClearStaleVectors() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let binding = AgentMemoryBinding(agentId: UUID())
        let offline = try AgentMemoryStore.open(binding: binding, directory: dir)
        let stored = try await offline.remember(.init(content: "marigold trawler fixture"))
        let online = try AgentMemoryStore.open(binding: binding, directory: dir, embedder: FixedEmbedder())
        #expect(try await online.recall(.init(query: "marigold trawler", depth: 0)).mode == .fullText)
        #expect(try await online.backfillPendingEmbeddings() == 1)
        #expect(try await online.recall(.init(query: "marigold trawler", depth: 0)).mode == .vector)
        _ = try await offline.update(.init(id: stored.id, content: "changed sapphire orchard"))
        let recalled = try await online.recall(.init(query: "sapphire orchard", depth: 0))
        #expect(recalled.mode == .fullText)
        #expect(recalled.hits.contains { $0.memory.id == stored.id })
        #expect(try await online.backfillPendingEmbeddings() == 1)
    }
}

private struct FixedEmbedder: Embedder {
    var dimension: Int { 384 }
    func embed(text: String) async throws -> [Float]? { [1] + Array(repeating: 0, count: 383) }
}

private struct FailingEmbedder: Embedder {
    let cancel: Bool
    var dimension: Int { 384 }
    func embed(text: String) async throws -> [Float]? {
        if cancel { throw CancellationError() }
        throw URLError(.notConnectedToInternet)
    }
}
