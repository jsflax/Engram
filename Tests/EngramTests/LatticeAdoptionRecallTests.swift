@testable import EngramKit
import EngramMemoryCore
import EngramModels
import Foundation
import Lattice
import MCP
import SQLite3
import Testing

// Consumer qualification for the released SDK/Core graph. Only embedding is
// deterministic: queries, model writes and checked transactions use the real
// MemoryTools and Lattice products. No model download or provider is needed.
@Suite("Lattice adoption recall and persistence", .serialized)
struct LatticeAdoptionRecallTests {
    private static let oldAccess = Date(timeIntervalSince1970: 946_684_800)
    private static let project = "Adoption"

    private struct QueryEmbedder: Embedder {
        var dimension: Int { 384 }
        func embed(text: String) async throws -> [Float]? {
            var vector = [Float](repeating: 0, count: dimension)
            vector[0] = 1
            return vector
        }
    }

    private struct Seed {
        let content: String
        let project: String
        let importance: Int
        let accesses: Int
        let rawDistance: Float
        let rankedDistance: Double?
        let renderedDistance: String?
    }

    // Same unit-vector distance, deliberately distinct project/importance/
    // frequency ranks. Ancient access dates make the recency multiplier 1;
    // fresh creation dates avoid the time-dependent staleness penalty.
    private static let seeds = [
        Seed(content: "important row", project: project, importance: 5, accesses: 0,
             rawDistance: 0.5, rankedDistance: 0.280, renderedDistance: "0.280"),
        Seed(content: "frequent row", project: project, importance: 0, accesses: 3,
             rawDistance: 0.5, rankedDistance: 0.322, renderedDistance: "0.322"),
        Seed(content: "same project row", project: project, importance: 0, accesses: 0,
             rawDistance: 0.5, rankedDistance: 0.350, renderedDistance: "0.350"),
        Seed(content: "global row", project: "global", importance: 0, accesses: 0,
             rawDistance: 0.5, rankedDistance: 0.425, renderedDistance: "0.425"),
        Seed(content: "other project row", project: "Other", importance: 0, accesses: 0,
             rawDistance: 0.5, rankedDistance: 0.500, renderedDistance: "0.500"),
        Seed(content: "distant outlier", project: "Other", importance: 0, accesses: 0,
             rawDistance: 1.8, rankedDistance: nil, renderedDistance: nil),
    ]

    private struct Fixture {
        let tools: MemoryTools
        let writer: Lattice
        let path: URL
        let ids: [UUID]
    }

    private func fixture(seed: Bool = true) throws -> Fixture {
        let root = ProcessInfo.processInfo.environment["ENGRAM_ADOPTION_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("lattice-adoption-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("memory.sqlite")
        let writer = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self,
                                 SyncConfig.self,
                                 configuration: .init(fileURL: path, busyTimeoutMs: 100))
        var ids: [UUID] = []
        if seed {
            for item in Self.seeds {
                let x = 1 - item.rawDistance * item.rawDistance / 2
                var vector = [Float](repeating: 0, count: 384)
                vector[0] = x
                vector[1] = (1 - x * x).squareRoot()
                let row = Memory(content: item.content, topic: "contract", project: item.project,
                                 embedding: Vector<Float>(vector), createdAt: Date(),
                                 lastAccessedAt: Self.oldAccess, accessCount: item.accesses,
                                 importance: item.importance)
                try writer.add(row)
                ids.append(try #require(row.globalId))
            }
        }
        return Fixture(tools: MemoryTools(localRef: writer.sendableReference, syncedRef: nil,
                                          embedder: QueryEmbedder(),
                                          identity: StaticIdentityProvider(.anonymous)),
                       writer: writer, path: path, ids: ids)
    }

    private func recall(_ fixture: Fixture) async throws -> RecallResult {
        try await fixture.tools.recall(RecallRequest(query: "fixed unit query",
                                                     project: Self.project, depth: 0, limit: 6))
    }

    private func assertRecallContract(_ result: RecallResult, _ fixture: Fixture) {
        #expect(result.mode == .vector)
        #expect(result.hits.map(\.memory.id) == Array(fixture.ids.prefix(5)))
        #expect(result.hits.map(\.depth) == [0, 0, 0, 0, 0])
        #expect(result.hits.allSatisfy { !$0.isForeign })
        for (hit, seed) in zip(result.hits, Self.seeds.prefix(5)) {
            #expect(abs(hit.distance - (seed.rankedDistance ?? -1)) < 0.00001)
            // The response captures values BEFORE its best-effort writes.
            #expect(hit.memory.accessCount == seed.accesses)
            #expect(hit.memory.lastAccessedAt == Self.oldAccess)
        }
        let expected = zip(fixture.ids.prefix(5), Self.seeds.prefix(5)).map { id, seed in
            let importance = seed.importance == 0 ? "" : ", importance: \(seed.importance)"
            return "[id:\(id.uuidString)] [\(seed.project)/contract] (distance: \(seed.renderedDistance ?? "missing")\(importance)) \(seed.content)"
        }.joined(separator: "\n\n")
        #expect(result.renderedText == expected)
    }

    private struct SavedMemory {
        let id: UUID
        let content: String
        let topic: String
        let accesses: Int
        let accessedAt: Double
    }

    private struct SQLiteFailure: Error { let message: String }

    // A separate SQLite connection observes committed bytes, not Lattice's
    // managed-object cache. It also supplies real trigger/lock failure seams.
    private final class SQL: @unchecked Sendable {
        private let db: OpaquePointer

        init(_ path: URL, readOnly: Bool = false) throws {
            var pointer: OpaquePointer?
            let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX
            let status = sqlite3_open_v2(path.path, &pointer, flags, nil)
            guard status == SQLITE_OK, let pointer else {
                let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite open failed"
                if let pointer { sqlite3_close(pointer) }
                throw SQLiteFailure(message: message)
            }
            db = pointer
            sqlite3_busy_timeout(db, 100)
        }

        deinit { sqlite3_close(db) }

        func execute(_ statement: String) throws {
            guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
                throw SQLiteFailure(message: String(cString: sqlite3_errmsg(db)))
            }
        }

        func edgeCount() throws -> Int {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM Edge", -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw SQLiteFailure(message: String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw SQLiteFailure(message: String(cString: sqlite3_errmsg(db)))
            }
            let count = Int(sqlite3_column_int64(statement, 0))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteFailure(message: String(cString: sqlite3_errmsg(db)))
            }
            return count
        }

        func memories() throws -> [UUID: SavedMemory] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT globalId, content, accessCount, lastAccessedAt, topic FROM Memory", -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw SQLiteFailure(message: String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            var rows: [UUID: SavedMemory] = [:]
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                guard let idText = sqlite3_column_text(statement, 0),
                      let id = UUID(uuidString: String(cString: idText)),
                      let content = sqlite3_column_text(statement, 1),
                      let topic = sqlite3_column_text(statement, 4) else {
                    throw SQLiteFailure(message: "Invalid persisted Memory identity/content")
                }
                rows[id] = SavedMemory(id: id, content: String(cString: content),
                                       topic: String(cString: topic),
                                       accesses: Int(sqlite3_column_int64(statement, 2)),
                                       accessedAt: sqlite3_column_double(statement, 3))
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else {
                throw SQLiteFailure(message: String(cString: sqlite3_errmsg(db)))
            }
            return rows
        }
    }

    private func assertPersistedStats(_ fixture: Fixture, bumped: Bool,
                                      since: Date = .distantPast) throws {
        // Fresh independently opened reader, never the seeding handle.
        let saved = try SQL(fixture.path, readOnly: true).memories()
        #expect(Set(saved.keys) == Set(fixture.ids))
        for (index, pair) in zip(fixture.ids, Self.seeds).enumerated() {
            let row = try #require(saved[pair.0])
            let expectedBump = bumped && index < 5
            #expect(row.content == pair.1.content)
            #expect(row.accesses == pair.1.accesses + (expectedBump ? 1 : 0))
            if expectedBump {
                #expect(row.accessedAt >= since.timeIntervalSince1970 - 0.001)
                #expect(row.accessedAt <= Date().timeIntervalSince1970 + 0.001)
            } else {
                #expect(row.accessedAt == Self.oldAccess.timeIntervalSince1970)
            }
        }
    }

    @Test func recall_preservesRankedIDsOutputAndCommittedAccessStats() async throws {
        let fixture = try fixture()
        let before = Date()
        let result = try await recall(fixture)
        assertRecallContract(result, fixture)
        try assertPersistedStats(fixture, bumped: true, since: before)
    }

    @Test func recall_preservesGradualStalenessRanking() async throws {
        let fixture = try fixture(seed: false)
        var vector = [Float](repeating: 0, count: 384)
        vector[0] = 0.875
        vector[1] = Float(1 - 0.875 * 0.875).squareRoot()
        let fresh = Memory(content: "fresh ranking control", embedding: Vector<Float>(vector),
                           createdAt: Date(), lastAccessedAt: Self.oldAccess)
        let stale = Memory(content: "104 day ranking control", embedding: Vector<Float>(vector),
                           createdAt: Date().addingTimeInterval(-104 * 86400),
                           lastAccessedAt: Self.oldAccess)
        try fixture.writer.add(stale)
        try fixture.writer.add(fresh)
        let freshID = try #require(fresh.globalId)
        let staleID = try #require(stale.globalId)
        let result = try await fixture.tools.recall(RecallRequest(query: "fixed unit query", depth: 0, limit: 2))
        #expect(result.hits.map(\.memory.id) == [freshID, staleID])
        #expect(abs((result.hits.first?.distance ?? -1) - 0.5) < 0.00001)
        // EngramKit gradually reaches +20% over 180 days beyond day 14:
        // day 104 is +10%, not the portable helper's immediate +20%.
        #expect(abs((result.hits.last?.distance ?? -1) - 0.55) < 0.00001)
        #expect(result.renderedText.contains("(distance: 0.550) 104 day ranking control"))
    }

    @Test func recall_preservesRecencyRanking() async throws {
        let fixture = try fixture(seed: false)
        var vector = [Float](repeating: 0, count: 384)
        vector[0] = 0.875
        vector[1] = Float(1 - 0.875 * 0.875).squareRoot()
        let recent = Memory(content: "recent ranking control", embedding: Vector<Float>(vector),
                            createdAt: Date(), lastAccessedAt: Date())
        let old = Memory(content: "old access ranking control", embedding: Vector<Float>(vector),
                         createdAt: Date(), lastAccessedAt: Self.oldAccess)
        try fixture.writer.add(old)
        try fixture.writer.add(recent)
        let recentID = try #require(recent.globalId)
        let oldID = try #require(old.globalId)
        let result = try await fixture.tools.recall(RecallRequest(query: "fixed unit query", depth: 0, limit: 2))
        #expect(result.hits.map(\.memory.id) == [recentID, oldID])
        #expect(abs((result.hits.first?.distance ?? -1) - 0.45) < 0.00001)
        #expect(abs((result.hits.last?.distance ?? -1) - 0.5) < 0.00001)
        #expect(result.renderedText.contains("(distance: 0.450) recent ranking control"))
    }

    @Test(arguments: ["failed-update", "busy-writer"])
    func recall_bookkeepingFailureIsNonfatalAndRecovers(_ failure: String) async throws {
        let fixture = try fixture()
        let blocker = try SQL(fixture.path)
        if failure == "failed-update" {
            // lastAccessedAt is written first. Failing the later increment
            // must roll back that earlier update as well as every other row.
            try blocker.execute("CREATE TRIGGER adoption_access_fault BEFORE UPDATE OF accessCount ON Memory WHEN NEW.content = 'important row' BEGIN SELECT RAISE(ABORT, 'adoption-access-fault'); END")
        } else {
            try blocker.execute("BEGIN IMMEDIATE")
        }
        defer {
            try? blocker.execute(failure == "failed-update" ? "DROP TRIGGER IF EXISTS adoption_access_fault" : "ROLLBACK")
        }
        let started = Date()
        let result = try await recall(fixture)
        #expect(Date().timeIntervalSince(started) < 5, "100 ms busy timeout must bound bookkeeping failure")
        assertRecallContract(result, fixture)
        try assertPersistedStats(fixture, bumped: false)

        try blocker.execute(failure == "failed-update" ? "DROP TRIGGER adoption_access_fault" : "ROLLBACK")
        let beforeRecovery = Date()
        let recovered = try await recall(fixture)
        assertRecallContract(recovered, fixture)
        try assertPersistedStats(fixture, bumped: true, since: beforeRecovery)
    }

    @Test func remember_successIsCommittedAndReopenedByIndependentReader() async throws {
        let fixture = try fixture(seed: false)
        let content = "published dependency persistence fixture"
        let remembered = try await fixture.tools.remember(RememberRequest(content: content,
                                                                           topic: "contract", project: "Persistence"))
        let saved = try SQL(fixture.path, readOnly: true).memories()
        let row = try #require(saved[remembered.id])
        #expect(row.content == content)
        #expect(remembered.message.contains(remembered.id.uuidString))
        let recalled = try await fixture.tools.recall(RecallRequest(query: content,
                                                                     project: "Persistence", depth: 0, limit: 1))
        #expect(recalled.hits.map(\.memory.id) == [remembered.id])
        #expect(recalled.hits.first?.memory.content == content)
    }

    @Test(arguments: ["failed-insert", "busy-writer"])
    func remember_failedWriteDoesNotReportSuccessOrPersistAndRecovers(_ failure: String) async throws {
        let fixture = try fixture(seed: false)
        let blocker = try SQL(fixture.path)
        if failure == "failed-insert" {
            try blocker.execute("CREATE TRIGGER adoption_insert_fault BEFORE INSERT ON Memory BEGIN SELECT RAISE(ABORT, 'adoption-insert-fault'); END")
        } else {
            try blocker.execute("BEGIN IMMEDIATE")
        }
        defer {
            try? blocker.execute(failure == "failed-insert" ? "DROP TRIGGER IF EXISTS adoption_insert_fault" : "ROLLBACK")
        }
        var rejected = false
        let started = Date()
        do {
            _ = try await fixture.tools.remember(RememberRequest(content: "write must fail",
                                                                  project: "Persistence"))
        } catch {
            rejected = true
        }
        #expect(rejected, "A failed real insert must not yield a successful remembered ID")
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(try SQL(fixture.path, readOnly: true).memories().isEmpty)

        try blocker.execute(failure == "failed-insert" ? "DROP TRIGGER adoption_insert_fault" : "ROLLBACK")
        let recovered = try await fixture.tools.remember(RememberRequest(content: "recovered durable write",
                                                                          project: "Persistence"))
        let saved = try SQL(fixture.path, readOnly: true).memories()
        #expect(saved[recovered.id]?.content == "recovered durable write")
        #expect(!saved.values.contains { $0.content == "write must fail" })
    }

    @Test
    func remember_missingParentDoesNotInsertMemoryOrPublishBookkeeping() async throws {
        let fixture = try fixture(seed: false)
        let previousTime = Self.oldAccess
        await fixture.tools.setLastMemoryTime(previousTime)
        await #expect(throws: (any Error).self) {
            _ = try await fixture.tools.handle(CallTool.Parameters(name: "remember", arguments: [
                "content": .string("a rejected parent must not leave an orphan memory"),
                "project": .string("Persistence"),
                "parent_id": .string(UUID().uuidString),
            ]))
        }
        let saved = try SQL(fixture.path, readOnly: true)
        #expect(try saved.memories().isEmpty)
        #expect(try saved.edgeCount() == 0)
        let lastTime = await fixture.tools.lastMemoryTime
        let lastId = await fixture.tools.lastRememberedId
        #expect(lastTime == previousTime)
        #expect(lastId == nil)
    }

    @Test(arguments: ["edge-abort", "edge-rollback", "edge-begin-spoof", "busy-begin"])
    func remember_graphFailurePreservesMemoryAndBookkeepingUntilCommit(_ failure: String) async throws {
        let fixture = try fixture(seed: false)
        _ = try await fixture.tools.handle(CallTool.Parameters(name: "begin_episode", arguments: [
            "title": .string("atomic remember fixture"), "project": .string("Persistence"),
        ]))
        let activeEpisode = await fixture.tools.activeEpisodeId
        let parentId = try #require(activeEpisode)
        _ = try await fixture.tools.handle(CallTool.Parameters(name: "remember", arguments: [
            "content": .string("baseline remembered child"), "project": .string("Persistence"),
            "topic": .string("episode"),
        ]))
        let previousId = await fixture.tools.lastRememberedId
        #expect(previousId != nil)
        let previousTime = Self.oldAccess
        await fixture.tools.setLastMemoryTime(previousTime)
        let originalMemories = try SQL(fixture.path, readOnly: true).memories()
        let originalEdges = try SQL(fixture.path, readOnly: true).edgeCount()
        let blocker = try SQL(fixture.path)
        if failure == "busy-begin" {
            try blocker.execute("BEGIN IMMEDIATE")
        } else {
            let action = failure == "edge-rollback" ? "ROLLBACK" : "ABORT"
            let detail = failure == "edge-begin-spoof" ? "Failed to begin transaction: database is locked" : "remember-edge-fault"
            try blocker.execute("CREATE TRIGGER remember_edge_fault BEFORE INSERT ON Edge BEGIN SELECT RAISE(\(action), '\(detail)'); END")
        }
        defer {
            try? blocker.execute(failure == "busy-begin" ? "ROLLBACK" : "DROP TRIGGER IF EXISTS remember_edge_fault")
        }
        let started = Date()
        let request = CallTool.Parameters(name: "remember", arguments: [
            "content": .string("child must roll back with its required parent edge"),
            "project": .string("Persistence"), "topic": .string("episode"),
            "parent_id": .string(parentId.uuidString),
        ])
        if failure == "busy-begin" {
            let result = try await fixture.tools.handle(request)
            #expect(result.isError == true)
            #expect(result.structuredContent == .object([
                "engram_write_receipt": .object([
                    "schema_version": .int(1), "tool": .string("remember"),
                    "write_outcome": .string("not_stored_transaction_not_started"),
                    "reason": .string("database_busy"), "memory_ids": .array([]),
                ]),
            ]))
            // Verify the actual MCP wire shape, including no extra receipt fields.
            let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
            #expect(Set(wire.keys) == ["content", "structuredContent", "isError"])
            let content = try #require(wire["content"] as? [[String: String]])
            #expect(content == [["type": "text", "text": "Memory was not stored: the database was busy before the write transaction started. Retry on a later turn."]])
        } else {
            // Even matching busy text from inside the body is not a no-write
            // attestation; the caller still receives an unknown storage error.
            await #expect(throws: (any Error).self) {
                _ = try await fixture.tools.handle(request)
            }
        }
        #expect(Date().timeIntervalSince(started) < 5)
        // New independent readers prove committed state, rather than inspecting
        // the failed transaction's managed Memory instance or cached results.
        let afterFailure = try SQL(fixture.path, readOnly: true)
        #expect(Set(try afterFailure.memories().keys) == Set(originalMemories.keys))
        #expect(try afterFailure.edgeCount() == originalEdges)
        let episodeAfterFailure = await fixture.tools.activeEpisodeId
        let timeAfterFailure = await fixture.tools.lastMemoryTime
        let idAfterFailure = await fixture.tools.lastRememberedId
        #expect(episodeAfterFailure == parentId)
        #expect(timeAfterFailure == previousTime)
        #expect(idAfterFailure == previousId)

        try blocker.execute(failure == "busy-begin" ? "ROLLBACK" : "DROP TRIGGER remember_edge_fault")
        _ = try await fixture.tools.handle(CallTool.Parameters(name: "remember", arguments: [
            "content": .string("subsequent child commits with its required parent edge"),
            "project": .string("Persistence"), "topic": .string("episode"),
            "parent_id": .string(parentId.uuidString),
        ]))
        let committedId = await fixture.tools.lastRememberedId
        let id = try #require(committedId)
        let saved = try SQL(fixture.path, readOnly: true)
        let rows = try saved.memories()
        #expect(Set(rows.keys) == Set(originalMemories.keys).union([id]))
        #expect(rows[id]?.content == "subsequent child commits with its required parent edge")
        #expect(try saved.edgeCount() == originalEdges + 1)
        let episodeAfterCommit = await fixture.tools.activeEpisodeId
        let timeAfterCommit = await fixture.tools.lastMemoryTime
        #expect(episodeAfterCommit == nil)
        #expect(timeAfterCommit > previousTime)
    }

    @Test(arguments: ["ABORT", "ROLLBACK"])
    func remember_laterEdgeFailureRollsBackEarlierEdge(_ action: String) async throws {
        let fixture = try fixture(seed: false)
        let parent = Memory(content: "explicit parent", topic: "episode", project: "Persistence")
        try fixture.writer.add(parent)
        let parentId = try #require(parent.globalId)
        _ = try await fixture.tools.handle(CallTool.Parameters(name: "begin_episode", arguments: [
            "title": .string("active episode"), "project": .string("Persistence"),
        ]))
        let episodeId = await fixture.tools.activeEpisodeId
        let episode = try #require(episodeId)
        let previousTime = Date()
        await fixture.tools.setLastMemoryTime(previousTime)
        let original = try SQL(fixture.path, readOnly: true).memories()
        let fault = try SQL(fixture.path)
        // The explicit parent edge succeeds first; the active episode edge
        // then fails, testing rollback of both Memory and an earlier Edge.
        try fault.execute("CREATE TRIGGER remember_later_edge_fault BEFORE INSERT ON Edge WHEN NEW.targetGlobalId = '\(episode.uuidString.lowercased())' BEGIN SELECT RAISE(\(action), 'remember-later-edge-fault'); END")
        defer { try? fault.execute("DROP TRIGGER IF EXISTS remember_later_edge_fault") }
        await #expect(throws: (any Error).self) {
            _ = try await fixture.tools.handle(CallTool.Parameters(name: "remember", arguments: [
                "content": .string("child requires both edges"), "topic": .string("episode"),
                "project": .string("Persistence"), "parent_id": .string(parentId.uuidString),
            ]))
        }
        let saved = try SQL(fixture.path, readOnly: true)
        #expect(Set(try saved.memories().keys) == Set(original.keys))
        #expect(try saved.edgeCount() == 0)
        let time = await fixture.tools.lastMemoryTime
        let id = await fixture.tools.lastRememberedId
        let active = await fixture.tools.activeEpisodeId
        #expect(time == previousTime)
        #expect(id == nil)
        #expect(active == episode)
    }

    @Test(arguments: ["ABORT", "ROLLBACK"])
    func remember_inferredTopicFailureRollsBackMemoryAndEdges(_ action: String) async throws {
        let fixture = try fixture(seed: false)
        var vector = [Float](repeating: 0, count: 384)
        vector[0] = 1 - 0.75 * 0.75 / 2
        vector[1] = (1 - vector[0] * vector[0]).squareRoot()
        for content in ["first related neighbor", "second related neighbor"] {
            try fixture.writer.add(Memory(content: content, topic: "contract", project: "Persistence",
                                          embedding: Vector<Float>(vector)))
        }
        let original = try SQL(fixture.path, readOnly: true).memories()
        let previousTime = Self.oldAccess
        await fixture.tools.setLastMemoryTime(previousTime)
        let fault = try SQL(fixture.path)
        // Topic inference is the final write after Memory and both relates_to
        // edges. Its nonthrowing setter must still poison checked commit.
        try fault.execute("CREATE TRIGGER remember_topic_fault BEFORE UPDATE OF topic ON Memory WHEN OLD.topic = 'general' AND NEW.topic = 'contract' BEGIN SELECT RAISE(\(action), 'remember-topic-fault'); END")
        defer { try? fault.execute("DROP TRIGGER IF EXISTS remember_topic_fault") }
        let arguments: [String: Value] = [
            "content": .string("new connected concept"), "project": .string("Persistence"),
        ]
        await #expect(throws: (any Error).self) {
            _ = try await fixture.tools.handle(CallTool.Parameters(name: "remember", arguments: arguments))
        }
        let failed = try SQL(fixture.path, readOnly: true)
        #expect(Set(try failed.memories().keys) == Set(original.keys))
        #expect(try failed.edgeCount() == 0)
        let time = await fixture.tools.lastMemoryTime
        let id = await fixture.tools.lastRememberedId
        #expect(time == previousTime)
        #expect(id == nil)

        try fault.execute("DROP TRIGGER remember_topic_fault")
        _ = try await fixture.tools.handle(CallTool.Parameters(name: "remember", arguments: arguments))
        let committedId = await fixture.tools.lastRememberedId
        let committed = try #require(committedId)
        let saved = try SQL(fixture.path, readOnly: true)
        let rows = try saved.memories()
        #expect(Set(rows.keys) == Set(original.keys).union([committed]))
        #expect(rows[committed]?.topic == "contract")
        #expect(try saved.edgeCount() == 2)
    }

}
