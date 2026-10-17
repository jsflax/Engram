@testable import EngramKit
import EngramMemoryCore
import EngramModels
import Foundation
import Lattice
import SQLite3
import Testing

@Suite("Remember operation execution", .serialized)
struct MemoryOperationRememberTests {
    private actor Embed: Embedder {
        nonisolated let dimension = 384
        var calls = 0
        var available = true
        func embed(text: String) async throws -> [Float]? {
            calls += 1
            guard available else { return nil }
            return [1] + [Float](repeating: 0, count: dimension - 1)
        }
        func disable() { available = false }
    }

    private actor LazyEmbed: Embedder {
        var dimension = 0
        var calls = 0
        func embed(text: String) async throws -> [Float]? {
            calls += 1
            dimension = 384
            return [1] + [Float](repeating: 0, count: dimension - 1)
        }
    }

    private struct Fixture {
        let path: URL
        let db: Lattice
        let embedder: Embed
        let tools: MemoryTools
    }

    private func fixture() throws -> Fixture {
        let base = ProcessInfo.processInfo.environment["ENGRAM_ADOPTION_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("operation-remember-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("memory.sqlite")
        try MemoryOperationLedger.preflightLocalStore(at: path)
        let db = try Lattice(for: [Memory.self, Edge.self, SyncConfig.self] + MemoryOperationLedger.localModels,
                             configuration: .init(fileURL: path, busyTimeoutMs: 100))
        try MemoryOperationLedger(lattice: db).bootstrapStoreID()
        let embedder = Embed()
        let tools = MemoryTools(localRef: db.sendableReference, syncedRef: nil, embedder: embedder,
                                identity: StaticIdentityProvider(.anonymous), enableLocalMutationOperations: true)
        return Fixture(path: path, db: db, embedder: embedder, tools: tools)
    }

    private func request(_ fixture: Fixture, operationID: UUID = UUID(), parentID: UUID? = nil,
                         topic: String = "episode", content: String = "synthetic retained memory") async throws -> MemoryOperationRequest {
        try await MemoryOperationRequest(operationID: operationID, expectedScope: fixture.tools.operationScope(),
            provenance: MemoryOperationProvenance(host: "fixture", sessionID: "fixture-session", runID: "fixture-run",
                source: MemoryOperationSourceInterval(startOffset: 1, endOffset: 2,
                    excerptDigest: MemoryOperationDigest(sha256: String(repeating: "a", count: 64)))),
            mutation: .remember(RememberRequest(content: content, topic: topic, project: "OperationRemember",
                                               parentId: parentID, expiresInDays: 1)))
    }

    @Test func firstRememberWaitsForLazyEmbeddingDimensionAndReplaySkipsEmbedding() async throws {
        let f = try fixture()
        defer { f.db.close() }
        let embedder = LazyEmbed()
        let tools = MemoryTools(localRef: f.db.sendableReference, syncedRef: nil, embedder: embedder,
                                identity: StaticIdentityProvider(.anonymous), enableLocalMutationOperations: true)
        let operation = try await request(f)
        #expect(await embedder.dimension == 0)
        let first = try await tools.applyOperation(operation)
        #expect(first.outcome == .applied)
        #expect(first.memoryIDs.count == 1)
        #expect(await embedder.dimension == 384)
        #expect(try await tools.applyOperation(operation) == first)
        #expect(await embedder.calls == 1)
        #expect(try SQL(f.path).scalar("SELECT COUNT(*) FROM Memory") == 1)
        #expect(try SQL(f.path).scalar("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 1)
    }

    @Test func replayReturnsOriginalReceiptBeforeEmbeddingAndAfterNewService() async throws {
        let f = try fixture()
        defer { f.db.close() }
        let parent = Memory(content: "synthetic parent", topic: "episode")
        try f.db.add(parent)
        let operation = try await request(f, parentID: #require(parent.globalId))
        let first = try await f.tools.applyOperation(operation)
        #expect(first.outcome == .applied)
        #expect(first.memoryIDs.count == 1)
        #expect(first.edgeIDs.count == 1)
        #expect(await f.embedder.calls == 1)
        let originalExpiry = try SQL(f.path).scalar("SELECT expiresAt FROM Memory WHERE topic='episode' AND project='OperationRemember'")
        await f.embedder.disable()
        let second = try await f.tools.applyOperation(operation)
        let reopened = MemoryTools(localRef: f.db.sendableReference, syncedRef: nil, embedder: f.embedder,
                                   identity: StaticIdentityProvider(.anonymous), enableLocalMutationOperations: true)
        let third = try await reopened.applyOperation(operation)
        #expect(first == second && second == third)
        #expect(await f.embedder.calls == 1)
        #expect(try SQL(f.path).scalar("SELECT COUNT(*) FROM Memory") == 2)
        #expect(try SQL(f.path).scalar("SELECT COUNT(*) FROM Edge") == 1)
        #expect(try SQL(f.path).scalar("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 1)
        #expect(try SQL(f.path).scalar("SELECT expiresAt FROM Memory WHERE topic='episode' AND project='OperationRemember'") == originalExpiry)
    }

    @Test func receiptFailureRollsBackMemoryEdgesAndProcessState() async throws {
        let f = try fixture()
        defer { f.db.close() }
        let parent = Memory(content: "synthetic parent", topic: "episode")
        try f.db.add(parent)
        let operation = try await request(f, parentID: #require(parent.globalId))
        try SQL(f.path).execute("CREATE TRIGGER reject_receipt BEFORE INSERT ON EngramOperationReceiptV1 BEGIN SELECT RAISE(ABORT,'fixture'); END")
        await #expect(throws: MemoryOperationError.storageUnavailable) { try await f.tools.applyOperation(operation) }
        #expect(try SQL(f.path).scalar("SELECT COUNT(*) FROM Memory") == 1)
        #expect(try SQL(f.path).scalar("SELECT COUNT(*) FROM Edge") == 0)
        #expect(try SQL(f.path).scalar("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 0)
        #expect(await f.tools.lastRememberedId == nil)
        try SQL(f.path).execute("DROP TRIGGER reject_receipt")
        let recovered = try await f.tools.applyOperation(operation)
        #expect(recovered.outcome == .applied)
        #expect(try SQL(f.path).scalar("SELECT COUNT(*) FROM Memory") == 2)
        #expect(try SQL(f.path).scalar("SELECT COUNT(*) FROM Edge") == 1)
    }

    @Test func nearDuplicateDecisionIsDurableWithoutCountingANewWrite() async throws {
        let f = try fixture()
        defer { f.db.close() }
        let first = try await f.tools.applyOperation(request(f, topic: "general"))
        let duplicateRequest = try await request(f, topic: "general")
        let duplicate = try await f.tools.applyOperation(duplicateRequest)
        #expect(duplicate.outcome == .unchanged)
        #expect(duplicate.memoryIDs == first.memoryIDs)
        await f.embedder.disable()
        #expect(try await f.tools.applyOperation(duplicateRequest) == duplicate)
        #expect(try SQL(f.path).scalar("SELECT COUNT(*) FROM Memory") == 1)
        #expect(try SQL(f.path).scalar("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 2)
    }

    private struct SQL {
        private let path: URL
        init(_ path: URL) { self.path = path }
        private func withDB<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
            var db: OpaquePointer?
            guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  let db else { throw MemoryOperationError.storageUnavailable }
            defer { sqlite3_close(db) }
            return try body(db)
        }
        func execute(_ sql: String) throws {
            try withDB { db in
                guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw MemoryOperationError.storageUnavailable }
            }
        }
        func scalar(_ sql: String) throws -> Double {
            try withDB { db in
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                    throw MemoryOperationError.storageUnavailable
                }
                defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW else { throw MemoryOperationError.storageUnavailable }
                return sqlite3_column_double(statement, 0)
            }
        }
    }
}
