import Foundation
import Lattice
import EngramModels
import EngramLattice
import Testing

@Suite("AgentMemoryTransfer")
struct AgentMemoryTransferTests {
    @Test func actualAuditTransportPreservesCompleteSnapshotIncludingDatesAndVectors() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "engram-transfer-wire-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try Lattice(for: AgentMemoryStore.schema,
            configuration: AgentMemoryStore.configuration(fileURL: root.appending(path: "source.sqlite")))
        let target = try Lattice(for: AgentMemoryStore.schema,
            configuration: AgentMemoryStore.configuration(fileURL: root.appending(path: "target.sqlite")))
        let binding = AgentMemoryBinding(agentId: UUID())
        try source.add(AgentMemoryGraph(agentId: binding.agentId, graphId: binding.graphId), preservingGlobalId: binding.graphId)
        let time = Date(timeIntervalSince1970: 1_788_921_763.083822)
        let vector = (0..<384).map { Float($0 - 192) / 997 }
        let memory = Memory(content: "Wire snapshot fixture", embedding: Vector<Float>(vector),
                            createdAt: time, lastAccessedAt: time, expiresAt: .distantFuture,
                            authorUserId: binding.agentId, modifiedAt: time)
        try source.add(memory)
        let seal = try AgentMemoryTransfer.seal(in: source, binding: binding)
        let frame = try JSONEncoder().encode(ServerSentEvent.auditLog(Array(source.eventsAfter(globalId: nil))))
        #expect(try target.receive(frame).count > 0)
        let received = try #require(target.objects(Memory.self).first)
        #expect(Array(received.embedding) == vector)
        #expect(received.expiresAt == memory.expiresAt)
        #expect(received.modifiedAt == memory.modifiedAt)
        let result = try AgentMemoryTransfer.verify(in: target, expected: seal)
        #expect(result.isReady, "\(result.reason): expected \(result.expectedCounts), got \(result.actualCounts)")
        let cursor = source.eventsAfter(globalId: nil).snapshot().last?.primaryKey ?? 0
        let publicationKey = seal.manifestId.uuidString.lowercased()
        let republished = try AgentMemoryTransfer.verify(in: source, expected: seal, onReady: {
            let appended = try source.appendCurrentSnapshots(tables: Set(AgentMemoryTransfer.coveredTables), publicationKey: publicationKey)
            #expect(appended == 2)
        })
        #expect(republished.isReady)
        let snapshots = source.eventsAfter(id: cursor).snapshot()
        #expect(snapshots.count == 2)
        #expect(try target.receive(JSONEncoder().encode(ServerSentEvent.auditLog(snapshots))).count == 2)
        let repaired = try #require(target.objects(Memory.self).first)
        #expect(Array(repaired.embedding) == vector)
        #expect(repaired.expiresAt == memory.expiresAt && repaired.modifiedAt == memory.modifiedAt)
        #expect(try AgentMemoryTransfer.verify(in: target, expected: seal).isReady)
        try source.withTransaction {
            let appended = try source.appendCurrentSnapshots(tables: Set(AgentMemoryTransfer.coveredTables), publicationKey: publicationKey)
            #expect(appended == 0)
        }
    }

    @Test func fencingCallbacksRunInsideCheckedTransactionAndOnlyWhenReady() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "engram-transfer-fence-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let graph = try Lattice(for: AgentMemoryStore.schema, configuration: AgentMemoryStore.configuration(fileURL: root.appending(path: "graph.sqlite")))
        let binding = AgentMemoryBinding(agentId: UUID())
        try graph.add(AgentMemoryGraph(agentId: binding.agentId, graphId: binding.graphId), preservingGlobalId: binding.graphId)
        let memory = Memory(content: "Before fence"); try graph.add(memory)
        var beforeRan = false
        let seal = try AgentMemoryTransfer.seal(in: graph, binding: binding, beforeSnapshot: {
            #expect(throws: (any Error).self) { try graph.withTransaction {} }
            memory.content = "Snapshot under fence"
            beforeRan = true
        })
        #expect(beforeRan)
        var readyCalls = 0
        let callback = {
            #expect(throws: (any Error).self) { try graph.withTransaction {} }
            readyCalls += 1
        }
        #expect(try AgentMemoryTransfer.verify(in: graph, expected: seal, onReady: callback).isReady)
        #expect(try AgentMemoryTransfer.accept(in: graph, expected: seal, onReady: callback).isReady)
        #expect(readyCalls == 2)
        memory.content = "New changes still transferring"
        #expect(try !AgentMemoryTransfer.verify(in: graph, expected: seal, onReady: callback).isReady)
        #expect(try !AgentMemoryTransfer.accept(in: graph, expected: seal, onReady: callback).isReady)
        #expect(readyCalls == 2)
        enum FixtureError: Error { case fenceFailed }
        #expect(throws: FixtureError.self) {
            try AgentMemoryTransfer.seal(in: graph, binding: binding, beforeSnapshot: {
                memory.content = "Must roll back"
                throw FixtureError.fenceFailed
            })
        }
        #expect(graph.objects(Memory.self).first?.content == "New changes still transferring")
    }

    @Test func durableWriterFenceIsVisibleAcrossHandlesButExcludedFromMemorySnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "engram-writer-fence-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "graph.sqlite")
        let legacySchema = AgentMemoryStore.schema.filter { $0.entityName != AgentMemoryWriterFence.entityName }
        let old = try Lattice(for: legacySchema, configuration: .init(fileURL: file, migration: [5: Migration()]))
        let binding = AgentMemoryBinding(agentId: UUID())
        try old.add(AgentMemoryGraph(agentId: binding.agentId, graphId: binding.graphId), preservingGlobalId: binding.graphId)
        try old.add(Memory(content: "Existing schema five history"))
        old.close()
        let coordinator = UUID().uuidString.lowercased()
        let database = try Lattice(for: AgentMemoryStore.schema, configuration: AgentMemoryStore.configuration(fileURL: file))
        defer { database.close() }
        let reader = try Lattice(for: AgentMemoryStore.schema, configuration: AgentMemoryStore.configuration(fileURL: file))
        defer { reader.close() }
        let fence = AgentMemoryWriterFence(graphID: binding.graphId.uuidString, coordinatorDeviceID: coordinator,
                                           writerDeviceID: coordinator, baselineDigest: "prior")
        let first = try AgentMemoryTransfer.seal(in: database, binding: binding, beforeSnapshot: {
            try database.add(fence, preservingGlobalId: UUID(uuidString: coordinator)!)
        })
        try reader.withTransaction {
            let observed = try #require(reader.objects(AgentMemoryWriterFence.self).first { $0.key == fence.key })
            #expect(observed.writerDeviceID == coordinator)
            #expect(observed.graphID == binding.graphId.uuidString.lowercased())
        }
        let second = try AgentMemoryTransfer.seal(in: database, binding: binding, beforeSnapshot: {
            fence.writerDeviceID = ""; fence.baselineDigest = first.contentDigest
        })
        #expect(first == second)
        #expect(!first.tableCounts.keys.contains(AgentMemoryWriterFence.entityName))
        try reader.withTransaction {
            #expect(reader.objects(AgentMemoryWriterFence.self).first?.writerDeviceID == "")
        }
        enum Stop: Error { case fixture }
        #expect(throws: Stop.self) {
            try AgentMemoryTransfer.seal(in: database, binding: binding, beforeSnapshot: {
                fence.writerDeviceID = coordinator
                throw Stop.fixture
            })
        }
        try reader.withTransaction {
            #expect(reader.objects(AgentMemoryWriterFence.self).first?.writerDeviceID == "")
        }
        #expect(database.objects(Memory.self).first?.content == "Existing schema five history")
    }

    @Test func fingerprintCoversEveryPortableStoredProperty() {
        // A future schema addition must deliberately update the canonical
        // fingerprint and its protocol version, never silently omit a field.
        let fields: [(String, Set<String>, Set<String>)] = [
            (Memory.entityName, Set(Memory.properties.map { $0.0 }), ["globalId", "content", "topic", "project", "source", "embedding", "embeddingPending", "createdAt", "lastAccessedAt", "expiresAt", "accessCount", "importance", "isPrivate", "authorUserId", "deletedAt", "deletedBy", "modifiedAt"]),
            (Edge.entityName, Set(Edge.properties.map { $0.0 }), ["globalId", "sourceGlobalId", "targetGlobalId", "relation", "createdAt", "authorUserId", "deletedAt"]),
            (Checkpoint.entityName, Set(Checkpoint.properties.map { $0.0 }), ["globalId", "title", "status", "project", "plan", "progress", "context", "createdAt", "checkpointedAt"]),
            (HookState.entityName, Set(HookState.properties.map { $0.0 }), ["globalId", "key", "value", "updatedAt"]),
            (SyncConfig.entityName, Set(SyncConfig.properties.map { $0.0 }), ["globalId", "project", "policy", "exposedTeams", "updatedAt"]),
            (GroupProjectMap.entityName, Set(GroupProjectMap.properties.map { $0.0 }), ["globalId", "memberUserId", "localProject", "groupProject", "updatedAt"]),
            (AgentMemoryGraph.entityName, Set(AgentMemoryGraph.properties.map { $0.0 }), ["globalId", "agentId", "graphId"]),
        ]
        #expect(Set(fields.map { $0.0 }) == Set(AgentMemoryTransfer.coveredTables))
        for (_, actual, names) in fields { #expect(actual == names) }
        #expect(Set(AgentMemoryStore.schema.map { $0.entityName }) == Set(AgentMemoryTransfer.coveredTables + ["AgentMemoryTransferManifest", "AgentMemoryWriterFence"]))
    }

    @Test func ownerFirstMixedBatchesUpdatesAndDeletionRequireCompleteSnapshot() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "engram-transfer-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try Lattice(for: AgentMemoryStore.schema, configuration: AgentMemoryStore.configuration(fileURL: root.appending(path: "source.sqlite")))
        let target = try Lattice(for: AgentMemoryStore.schema, configuration: AgentMemoryStore.configuration(fileURL: root.appending(path: "target.sqlite")))
        let binding = AgentMemoryBinding(agentId: UUID())
        let time = Date(timeIntervalSince1970: 1_788_883_203.123456)
        let firstID = UUID(), secondID = UUID(), edgeID = UUID(), taskID = UUID(), hookID = UUID(), configID = UUID(), mapID = UUID()
        func first() -> Memory { Memory(content: "First history", embedding: Vector<Float>([0.2, -0.3]), createdAt: time,
            lastAccessedAt: time, importance: 4, authorUserId: binding.agentId, modifiedAt: time) }
        func second() -> Memory { Memory(content: "Tombstoned history", embeddingPending: true, createdAt: time,
            lastAccessedAt: time, isPrivate: true, deletedAt: time, deletedBy: binding.agentId) }
        func edge() -> Edge { Edge(sourceGlobalId: firstID, targetGlobalId: secondID, relation: .derivedFrom,
                                   createdAt: time, authorUserId: binding.agentId, deletedAt: time) }
        func task() -> Checkpoint { Checkpoint(title: "Episode of work", plan: "Ship", progress: "In progress", context: "Private", createdAt: time, checkpointedAt: time) }
        func hook() -> HookState { HookState(key: .embeddingSpaceVersion, value: "1", updatedAt: time) }
        func config() -> SyncConfig { SyncConfig(project: "Orbital", policy: .local, exposedTeams: ["a", "b"], updatedAt: time) }
        func map() -> GroupProjectMap { GroupProjectMap(memberUserId: binding.agentId, localProject: "local", groupProject: "shared", updatedAt: time) }
        for database in [source, target] {
            try database.add(AgentMemoryGraph(agentId: binding.agentId, graphId: binding.graphId), preservingGlobalId: binding.graphId)
        }
        try source.add(first(), preservingGlobalId: firstID); try source.add(second(), preservingGlobalId: secondID)
        try source.add(edge(), preservingGlobalId: edgeID); try source.add(task(), preservingGlobalId: taskID)
        try source.add(hook(), preservingGlobalId: hookID); try source.add(config(), preservingGlobalId: configID)
        try source.add(map(), preservingGlobalId: mapID)
        let seal = try AgentMemoryTransfer.seal(in: source, binding: binding)
        #expect(try AgentMemoryTransfer.seal(in: source, binding: binding) == seal)
        #expect(try !AgentMemoryTransfer.verify(in: target, expected: seal).isReady)
        try copyManifest(seal, from: source, to: target)
        let ownerOnly = try AgentMemoryTransfer.verify(in: target, expected: seal)
        #expect(!ownerOnly.isReady && ownerOnly.actualCounts["Memory"] == 0)
        #expect(try !AgentMemoryTransfer.accept(in: target, expected: seal).isReady)
        // An existing prefix and multiple separate sync batches are supported.
        try target.add(first(), preservingGlobalId: firstID)
        #expect(try !AgentMemoryTransfer.verify(in: target, expected: seal).isReady)
        let badVector = second(); badVector.embedding = Vector<Float>([99, 0])
        try target.add(badVector, preservingGlobalId: secondID)
        try target.add(edge(), preservingGlobalId: edgeID); try target.add(task(), preservingGlobalId: taskID)
        try target.add(hook(), preservingGlobalId: hookID); try target.add(config(), preservingGlobalId: configID)
        try target.add(map(), preservingGlobalId: mapID)
        let wrongContent = try AgentMemoryTransfer.verify(in: target, expected: seal)
        #expect(!wrongContent.isReady && wrongContent.actualCounts == seal.tableCounts)
        badVector.embedding = Vector<Float>([])
        #expect(try AgentMemoryTransfer.verify(in: target, expected: seal).isReady)

        let changed = try #require(source.objects(Memory.self).first(where: { $0.globalId == firstID }))
        changed.content = "Newer content after first transfer"
        let next = try AgentMemoryTransfer.seal(in: source, binding: binding)
        #expect(next.manifestId != seal.manifestId)
        #expect(try !AgentMemoryTransfer.verify(in: target, expected: next).isReady)
        try copyManifest(next, from: source, to: target)
        #expect(try !AgentMemoryTransfer.verify(in: target, expected: next).isReady)
        target.objects(Memory.self).first(where: { $0.globalId == firstID })!.content = changed.content
        #expect(try AgentMemoryTransfer.verify(in: target, expected: next).isReady)

        // A phone owner sends its descriptor over an authenticated command;
        // coordinator seals only after content arrives, even when manifest rows
        // are correctly forbidden on the upload channel.
        let coordinator = try Lattice(for: AgentMemoryStore.schema, configuration: AgentMemoryStore.configuration(fileURL: root.appending(path: "coordinator.sqlite")))
        try coordinator.add(AgentMemoryGraph(agentId: binding.agentId, graphId: binding.graphId), preservingGlobalId: binding.graphId)
        #expect(try !AgentMemoryTransfer.accept(in: coordinator, expected: next).isReady)
        #expect(coordinator.objects(AgentMemoryTransferManifest.self).isEmpty)
        let updatedFirst = first(); updatedFirst.content = changed.content
        try coordinator.add(updatedFirst, preservingGlobalId: firstID); try coordinator.add(second(), preservingGlobalId: secondID)
        try coordinator.add(edge(), preservingGlobalId: edgeID); try coordinator.add(task(), preservingGlobalId: taskID)
        try coordinator.add(hook(), preservingGlobalId: hookID); try coordinator.add(config(), preservingGlobalId: configID)
        try coordinator.add(map(), preservingGlobalId: mapID)
        #expect(try AgentMemoryTransfer.accept(in: coordinator, expected: next).isReady)
        #expect(try AgentMemoryTransfer.verify(in: coordinator, expected: next).isReady)

        source.delete(source.objects(Edge.self).first!)
        let deleted = try AgentMemoryTransfer.seal(in: source, binding: binding)
        try copyManifest(deleted, from: source, to: target)
        #expect(try !AgentMemoryTransfer.verify(in: target, expected: deleted).isReady)
        target.delete(target.objects(Edge.self).first!)
        #expect(try AgentMemoryTransfer.verify(in: target, expected: deleted).isReady)
        // A stale prior row must not pass a subset/count-only readiness test.
        try target.add(Memory(content: "Unaccounted historical row"))
        #expect(try !AgentMemoryTransfer.verify(in: target, expected: deleted).isReady)
    }

    @Test func rejectsWrongOwnerUnsupportedSealAndOversizedVerification() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "engram-transfer-bounds-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Lattice(for: AgentMemoryStore.schema, configuration: AgentMemoryStore.configuration(fileURL: root.appending(path: "graph.sqlite")))
        let binding = AgentMemoryBinding(agentId: UUID())
        try store.add(AgentMemoryGraph(agentId: binding.agentId, graphId: binding.graphId), preservingGlobalId: binding.graphId)
        try store.add(Memory(content: String(repeating: "memory", count: 50)))
        #expect(throws: (any Error).self) { try AgentMemoryTransfer.seal(in: store, binding: .init(agentId: UUID())) }
        #expect(throws: (any Error).self) { try AgentMemoryTransfer.seal(in: store, binding: binding, limits: .init(maximumRecords: 1)) }
        #expect(throws: (any Error).self) { try AgentMemoryTransfer.seal(in: store, binding: binding, limits: .init(maximumContentBytes: 8)) }
        let invalid = AgentMemoryTransferSeal(manifestId: UUID(), graphId: binding.graphId, agentId: binding.agentId,
                                             formatVersion: 999, contentDigest: "", tableCounts: [:])
        #expect(try !AgentMemoryTransfer.verify(in: store, expected: invalid).isReady)
    }

    private func copyManifest(_ seal: AgentMemoryTransferSeal, from source: Lattice, to target: Lattice) throws {
        let original = try #require(source.objects(AgentMemoryTransferManifest.self).first { $0.globalId == seal.manifestId })
        let row = AgentMemoryTransferManifest()
        row.sourceGraphId = original.sourceGraphId; row.sourceAgentId = original.sourceAgentId
        row.formatVersion = original.formatVersion; row.schemaVersion = original.schemaVersion
        row.contentDigest = original.contentDigest; row.tableCountsJSON = original.tableCountsJSON; row.createdAt = original.createdAt
        try target.add(row, preservingGlobalId: seal.manifestId)
    }
}
