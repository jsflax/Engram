@testable import EngramKit
import EngramMemoryCore
import EngramModels
import Foundation
import Lattice
import MCP
import SQLite3
import Testing

// Synthetic stores only. Exercise the actual handler, detached setters and
// checked transactions; a separate SQLite reader verifies committed bytes.
// No executable, provider, embedding model, groups.json or live store is used.
@Suite("Update durable acknowledgements", .serialized)
struct UpdatePersistenceTests {
    private static let oldDate = Date(timeIntervalSince1970: 946_684_800)
    private static let project = "UpdatePersistence"
    private static let routes = ["local-id", "synced-id", "group-id",
                                 "local-query", "synced-query", "group-query"]

    private enum Owner: String, CaseIterable, Sendable {
        case local, synced, group
    }

    private struct FixedEmbedder: Embedder {
        var dimension: Int { 384 }
        func embed(text: String) async throws -> [Float]? {
            var vector = [Float](repeating: 0, count: dimension)
            vector[0] = 1
            return vector
        }
    }

    private struct SavedMemory: Equatable {
        let topic: String
        let source: String
        let importance: Int
        let accessedAt: Double
        let modifiedAt: Double?
        let deletedAt: Double?
    }

    private struct SavedEdge: Equatable {
        let deletedAt: Double?
    }

    private struct SQLiteFailure: Error { let message: String }

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

        func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw SQLiteFailure(message: String(cString: sqlite3_errmsg(db)))
            }
        }

        private func prepare(_ sql: String) throws -> OpaquePointer {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw SQLiteFailure(message: String(cString: sqlite3_errmsg(db)))
            }
            return statement
        }

        private func optionalDate(_ statement: OpaquePointer, _ column: Int32) -> Double? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
        }

        func memories() throws -> [UUID: SavedMemory] {
            let statement = try prepare("SELECT globalId, topic, source, importance, lastAccessedAt, modifiedAt, deletedAt FROM Memory")
            defer { sqlite3_finalize(statement) }
            var rows: [UUID: SavedMemory] = [:]
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                guard let idText = sqlite3_column_text(statement, 0),
                      let id = UUID(uuidString: String(cString: idText)),
                      let topic = sqlite3_column_text(statement, 1),
                      let source = sqlite3_column_text(statement, 2) else {
                    throw SQLiteFailure(message: "invalid synthetic memory metadata")
                }
                rows[id] = SavedMemory(topic: String(cString: topic), source: String(cString: source),
                                       importance: Int(sqlite3_column_int64(statement, 3)),
                                       accessedAt: sqlite3_column_double(statement, 4),
                                       modifiedAt: optionalDate(statement, 5),
                                       deletedAt: optionalDate(statement, 6))
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else {
                throw SQLiteFailure(message: String(cString: sqlite3_errmsg(db)))
            }
            return rows
        }

        func edges() throws -> [UUID: SavedEdge] {
            let statement = try prepare("SELECT globalId, deletedAt FROM Edge")
            defer { sqlite3_finalize(statement) }
            var rows: [UUID: SavedEdge] = [:]
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                guard let idText = sqlite3_column_text(statement, 0),
                      let id = UUID(uuidString: String(cString: idText)) else {
                    throw SQLiteFailure(message: "invalid synthetic edge identity")
                }
                rows[id] = SavedEdge(deletedAt: optionalDate(statement, 1))
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else {
                throw SQLiteFailure(message: String(cString: sqlite3_errmsg(db)))
            }
            return rows
        }
    }

    private struct Fixture {
        let tools: MemoryTools
        let writers: [Owner: Lattice]
        let paths: [Owner: URL]
        let ids: [Owner: UUID]
        let owner: Owner
        let query: Bool

        var targetID: UUID { ids[owner]! }
        var ownerPath: URL { paths[owner]! }

        func snapshot() throws -> [Owner: [UUID: SavedMemory]] {
            try Dictionary(uniqueKeysWithValues: Owner.allCases.map {
                ($0, try SQL(paths[$0]!, readOnly: true).memories())
            })
        }

        func request(topic: String = "after", importance: Int = 5) -> CallTool.Parameters {
            var arguments: [String: Value] = ["topic": .string(topic), "importance": .int(importance)]
            if query {
                arguments["query"] = .string("synthetic exact unit vector")
                arguments["project"] = .string(UpdatePersistenceTests.project)
            } else {
                arguments["id"] = .string(targetID.uuidString)
            }
            return CallTool.Parameters(name: "update", arguments: arguments)
        }
    }

    private func fixture(_ route: String, tombstoned: Bool = false) throws -> Fixture {
        let pieces = route.split(separator: "-")
        let owner = try #require(Owner(rawValue: String(pieces[0])))
        let query = pieces[1] == "query"
        let environment = ProcessInfo.processInfo.environment
        let configured = environment["ENGRAM_UPDATE_PERSISTENCE_TEST_ROOT"]
            ?? environment["ENGRAM_TEST_ROOT"]
        let root = configured.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("update-\(route)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var writers: [Owner: Lattice] = [:]
        var paths: [Owner: URL] = [:]
        var ids: [Owner: UUID] = [:]
        // Each store gets rowid 1 with a different globalId. Query tests select
        // exactly one owner through a real local+synced+group union, so borrowed
        // rowids and writes to a selection handle cannot pass the readback.
        for store in Owner.allCases {
            let path = directory.appendingPathComponent("\(store.rawValue).sqlite")
            let writer = try Lattice(Memory.self, Edge.self, SyncConfig.self, GroupProjectMap.self,
                                     configuration: .init(fileURL: path, busyTimeoutMs: 100))
            var vector = [Float](repeating: 0, count: 384)
            vector[0] = store == owner ? 1 : -1
            let memory = Memory(content: "synthetic \(store.rawValue) update fixture",
                                topic: "before", project: Self.project, source: "synthetic-fixture",
                                embedding: Vector<Float>(vector), createdAt: Self.oldDate,
                                lastAccessedAt: Self.oldDate, importance: 1,
                                deletedAt: store == owner && tombstoned ? Self.oldDate : nil,
                                modifiedAt: Self.oldDate)
            try writer.add(memory)
            writers[store] = writer
            paths[store] = path
            ids[store] = try #require(memory.globalId)
        }
        let local = writers[.local]!
        try local.add(SyncConfig(project: Self.project, policy: .sync))
        let group = MemoryTools.GroupSpokeRef(groupId: UUID(), path: paths[.group]!.path,
                                             ref: writers[.group]!.sendableReference)
        let tools = MemoryTools(localRef: local.sendableReference,
                                syncedRef: writers[.synced]!.sendableReference,
                                groupRefs: [group], embedder: FixedEmbedder(),
                                identity: StaticIdentityProvider(.anonymous))
        return Fixture(tools: tools, writers: writers, paths: paths, ids: ids,
                       owner: owner, query: query)
    }

    private func assertCommitted(_ fixture: Fixture, before: [Owner: [UUID: SavedMemory]],
                                 since: Date) throws {
        let after = try fixture.snapshot()
        let target = try #require(after[fixture.owner]?[fixture.targetID])
        #expect(target.topic == "after")
        #expect(target.importance == 5)
        let modifiedAt = try #require(target.modifiedAt)
        #expect(modifiedAt >= since.timeIntervalSince1970 - 0.001)
        #expect(modifiedAt <= Date().timeIntervalSince1970 + 0.001)
        #expect(target.accessedAt >= since.timeIntervalSince1970 - 0.001)
        for store in Owner.allCases {
            #expect(Set(after[store]!.keys) == Set(before[store]!.keys))
            if store != fixture.owner { #expect(after[store] == before[store]) }
        }
    }

    @Test(arguments: UpdatePersistenceTests.routes)
    func metadataSuccessCommitsToExactOwner(_ route: String) async throws {
        let fixture = try fixture(route)
        let before = try fixture.snapshot()
        let started = Date()
        let result = try await fixture.tools.handle(fixture.request())
        #expect(result.isError != true)
        #expect(text(from: result).contains("Updated memory"))
        #expect(text(from: result).contains(fixture.targetID.uuidString))
        try assertCommitted(fixture, before: before, since: started)
    }

    @Test(arguments: UpdatePersistenceTests.routes)
    func busyBeforeBeginReturnsExactNoWriteReceipt(_ route: String) async throws {
        let fixture = try fixture(route)
        // Warm a query union before taking the storage lock. This also proves
        // the same exact route is writable when no external writer owns it.
        let control = try await fixture.tools.handle(fixture.request(topic: "before", importance: 1))
        #expect(control.isError != true)
        let before = try fixture.snapshot()
        let blocker = try SQL(fixture.ownerPath)
        try blocker.execute("BEGIN IMMEDIATE")
        defer { try? blocker.execute("ROLLBACK") }
        let started = Date()
        let result = try await fixture.tools.handle(fixture.request())
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(result.isError == true)
        #expect(result.structuredContent == .object([
            "engram_write_receipt": .object([
                "schema_version": .int(1), "tool": .string("update"),
                "write_outcome": .string("not_stored_transaction_not_started"),
                "reason": .string("database_busy"), "memory_ids": .array([]),
            ]),
        ]))
        #expect(text(from: result) == "Memory was not updated: the database was busy before the write transaction started. Retry on a later turn.")
        #expect(try fixture.snapshot() == before)
        try blocker.execute("ROLLBACK")
        let recoveredAt = Date()
        let recovered = try await fixture.tools.handle(fixture.request())
        #expect(recovered.isError != true)
        try assertCommitted(fixture, before: before, since: recoveredAt)
    }

    @Test(arguments: UpdatePersistenceTests.routes, ["abort", "rollback", "begin-busy-text"])
    func laterSetterFailureThrowsAndRollsBackEarlierEdits(_ route: String, _ fault: String) async throws {
        let fixture = try fixture(route)
        let before = try fixture.snapshot()
        let blocker = try SQL(fixture.ownerPath)
        let action = fault == "rollback" ? "ROLLBACK" : "ABORT"
        let detail = fault == "begin-busy-text" ? "Failed to begin transaction: database is locked" : "synthetic-update-body-fault"
        // modifiedAt is assigned after topic, importance and lastAccessedAt.
        // The failed setter must roll all earlier assignments back as well.
        try blocker.execute("CREATE TRIGGER update_metadata_fault BEFORE UPDATE OF modifiedAt ON Memory BEGIN SELECT RAISE(\(action), '\(detail)'); END")
        defer { try? blocker.execute("DROP TRIGGER IF EXISTS update_metadata_fault") }
        await #expect(throws: (any Error).self) {
            _ = try await fixture.tools.handle(fixture.request())
        }
        #expect(try fixture.snapshot() == before)
        try blocker.execute("DROP TRIGGER update_metadata_fault")
        let recoveredAt = Date()
        let recovered = try await fixture.tools.handle(fixture.request())
        #expect(recovered.isError != true)
        try assertCommitted(fixture, before: before, since: recoveredAt)
    }

    @Test(arguments: ["edge-fault", "begin-busy-text"])
    func undeleteGraphFailureDoesNotAttestNoWriteAfterPrimaryCommit(_ fault: String) async throws {
        let fixture = try fixture("local-id", tombstoned: true)
        let edge = Edge(sourceGlobalId: fixture.targetID, targetGlobalId: fixture.ids[.synced]!,
                        relation: .relatesTo, deletedAt: Self.oldDate)
        try fixture.writers[.local]!.add(edge)
        let before = try fixture.snapshot()
        let edgesBefore = try SQL(fixture.ownerPath, readOnly: true).edges()
        let blocker = try SQL(fixture.ownerPath)
        let detail = fault == "begin-busy-text" ? "Failed to begin transaction: database is locked" : "synthetic-edge-restore-fault"
        try blocker.execute("CREATE TRIGGER update_edge_fault BEFORE UPDATE OF deletedAt ON Edge BEGIN SELECT RAISE(ABORT, '\(detail)'); END")
        defer { try? blocker.execute("DROP TRIGGER IF EXISTS update_edge_fault") }
        let started = Date()
        // A later graph failure is a partial outcome, even if its text mimics
        // a BEGIN failure. It must throw, not report Updated or known no-write.
        await #expect(throws: (any Error).self) {
            _ = try await fixture.tools.handle(CallTool.Parameters(name: "update", arguments: [
                "id": .string(fixture.targetID.uuidString), "undelete": .bool(true),
            ]))
        }
        let after = try fixture.snapshot()
        let restored = try #require(after[.local]?[fixture.targetID])
        #expect(restored.deletedAt == nil)
        let modifiedAt = try #require(restored.modifiedAt)
        #expect(modifiedAt >= started.timeIntervalSince1970 - 0.001)
        #expect(restored.topic == "before")
        #expect(try SQL(fixture.ownerPath, readOnly: true).edges() == edgesBefore)
        #expect(after[.synced] == before[.synced])
        #expect(after[.group] == before[.group])
    }
}
