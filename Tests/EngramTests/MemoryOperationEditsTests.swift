@testable import EngramKit
import EngramMemoryCore
import EngramModels
import Foundation
import Lattice
import SQLite3
import Testing

/// Synthetic owning stores and controlled embedding suspension. The separate
/// SQLite observer verifies persistence without trusting detached model caches.
@Suite("Durable operation edits", .serialized)
struct MemoryOperationEditsTests {
    private final class Identity: IdentityProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var value: Principal
        init(_ principal: Principal) { value = principal }
        func currentPrincipal() -> Principal { lock.withLock { value } }
        func set(_ principal: Principal) { lock.withLock { value = principal } }
    }

    private actor FixtureEmbedder: Embedder {
        let dimension = 384
        let mode: String
        private var gate: CheckedContinuation<Void, Never>?
        private var observer: CheckedContinuation<Void, Never>?
        private var entered = false
        private var inputs: [String] = []

        init(mode: String = "valid") { self.mode = mode }

        func embed(text: String) async throws -> [Float]? {
            inputs.append(text)
            if mode == "paused", !entered {
                await withCheckedContinuation { continuation in
                    gate = continuation
                    entered = true
                    observer?.resume()
                    observer = nil
                }
            }
            switch mode {
            case "nil": return nil
            case "short": return [1]
            case "nonfinite": return [Float](repeating: .nan, count: dimension)
            default:
                var vector = [Float](repeating: 0, count: dimension)
                vector[0] = 1
                return vector
            }
        }

        func waitUntilEntered() async {
            if !entered { await withCheckedContinuation { observer = $0 } }
        }

        func release() { gate?.resume(); gate = nil }
        func texts() -> [String] { inputs }
    }

    private struct Fixture {
        let local: Lattice
        let foreign: Lattice
        let path: URL
        let tools: MemoryTools
        let identity: Identity
        let embedder: FixtureEmbedder
        let sourceID: UUID
        let targetID: UUID
        let foreignID: UUID
        let principal: Principal

        func request(_ mutation: MemoryMutation, id: UUID = UUID()) throws -> MemoryOperationRequest {
            try MemoryOperationRequest(operationID: id,
                expectedScope: MemoryOperationLedger(lattice: local).scope(principal: principal),
                provenance: MemoryOperationProvenance(host: "synthetic-host", sessionID: "edit-fixture", runID: "edit-run",
                    source: MemoryOperationSourceInterval(startOffset: 1, endOffset: 50,
                        excerptDigest: MemoryOperationDigest(sha256: String(repeating: "c", count: 64)))),
                mutation: mutation)
        }

        func memory() throws -> Memory {
            try #require(local.objects(Memory.self).where { $0.globalId == sourceID }.first)
        }

        func close() { local.close(); foreign.close() }
    }

    private func fixture(content: String = "original", embedder: FixtureEmbedder = .init()) throws -> Fixture {
        let root = ProcessInfo.processInfo.environment["ENGRAM_ADOPTION_TEST_ROOT"]
            ?? ProcessInfo.processInfo.environment["ENGRAM_TEST_ROOT"]
            ?? FileManager.default.temporaryDirectory.path
        let directory = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("operation-edits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("local.sqlite")
        try MemoryOperationLedger.preflightLocalStore(at: path)
        let local = try Lattice(for: [Memory.self, Edge.self] + MemoryOperationLedger.localModels,
                                configuration: .init(fileURL: path, busyTimeoutMs: 100))
        try MemoryOperationLedger(lattice: local).bootstrapStoreID()
        let foreign = try Lattice(Memory.self, Edge.self,
            configuration: .init(fileURL: directory.appendingPathComponent("foreign.sqlite"), busyTimeoutMs: 100))
        let principal = Principal(id: UUID(), kind: .user)
        let identity = Identity(principal)
        let source = Memory(content: content, source: "fixture-source", authorUserId: principal.id)
        let target = Memory(content: "target", authorUserId: principal.id)
        let remote = Memory(content: "foreign owning store", authorUserId: principal.id)
        try local.add(source)
        try local.add(target)
        try foreign.add(remote)
        let tools = MemoryTools(localRef: local.sendableReference, syncedRef: foreign.sendableReference,
                                embedder: embedder, identity: identity, enableLocalMutationOperations: true)
        return Fixture(local: local, foreign: foreign, path: path, tools: tools, identity: identity,
                       embedder: embedder, sourceID: try #require(source.globalId),
                       targetID: try #require(target.globalId), foreignID: try #require(remote.globalId),
                       principal: principal)
    }

    @Test func appendReplayReturnsSameReceiptWithoutRepeatingMutationEmbeddingOrTTL() async throws {
        let f = try fixture()
        defer { f.close() }
        let operation = try f.request(.update(UpdateRequest(id: f.sourceID, append: "tail\r\n\0e\u{0301}", expiresInDays: 2)))
        let receipt = try await f.tools.applyOperation(operation)
        let observer = try SQL(f.path)
        let first = try observer.text("SELECT content FROM Memory WHERE globalId='\(f.sourceID.uuidString)'")
        let expires = try observer.text("SELECT CAST(expiresAt AS TEXT) FROM Memory WHERE globalId='\(f.sourceID.uuidString)'")
        let replay = try await f.tools.applyOperation(operation)
        #expect(replay == receipt)
        #expect(first.utf8.elementsEqual("original\ntail\r\n\0e\u{0301}".utf8))
        #expect(try observer.text("SELECT content FROM Memory WHERE globalId='\(f.sourceID.uuidString)'").utf8.elementsEqual(first.utf8))
        #expect(try observer.text("SELECT CAST(expiresAt AS TEXT) FROM Memory WHERE globalId='\(f.sourceID.uuidString)'") == expires)
        #expect(await f.embedder.texts().count == 1)
        #expect(try observer.integer("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 1)
        #expect(receipt.outcome == .applied && receipt.memoryIDs == [f.sourceID] && receipt.edgeIDs.isEmpty)
    }

    @Test(arguments: ["content", "append", "prepend", "replace"])
    func contentModesEmbedTheExactCommittedContent(_ mode: String) async throws {
        let f = try fixture(content: "old old")
        defer { f.close() }
        let edit: UpdateRequest
        let expected: String
        switch mode {
        case "content": edit = UpdateRequest(id: f.sourceID, content: ""); expected = ""
        case "append": edit = UpdateRequest(id: f.sourceID, append: ""); expected = "old old\n"
        case "prepend": edit = UpdateRequest(id: f.sourceID, prepend: "before"); expected = "before\nold old"
        default: edit = UpdateRequest(id: f.sourceID, find: "old", replace: "new"); expected = "new new"
        }
        _ = try await f.tools.applyOperation(f.request(.update(edit)))
        let content = try SQL(f.path).text("SELECT content FROM Memory WHERE globalId='\(f.sourceID.uuidString)'")
        #expect(content.utf8.elementsEqual(expected.utf8))
        let texts = await f.embedder.texts()
        #expect(texts.count == 1 && texts[0].utf8.elementsEqual(expected.utf8))
    }

    @Test func metadataEditDoesNotEmbedOrChangeAuthorSourceAndContent() async throws {
        let f = try fixture(embedder: FixtureEmbedder(mode: "nil"))
        defer { f.close() }
        _ = try await f.tools.applyOperation(f.request(.update(UpdateRequest(id: f.sourceID,
            topic: "", project: "updated", importance: 5, expiresInDays: -1, isPrivate: true))))
        let sql = try SQL(f.path)
        let target = "WHERE globalId='\(f.sourceID.uuidString)'"
        #expect(try sql.text("SELECT content FROM Memory \(target)") == "original")
        #expect(try sql.text("SELECT source FROM Memory \(target)") == "fixture-source")
        #expect(UUID(uuidString: try sql.text("SELECT authorUserId FROM Memory \(target)")) == f.principal.id)
        #expect(try sql.text("SELECT topic FROM Memory \(target)") == "")
        #expect(try sql.text("SELECT project FROM Memory \(target)") == "updated")
        #expect(try sql.integer("SELECT importance FROM Memory \(target)") == 5)
        #expect(try sql.integer("SELECT isPrivate FROM Memory \(target)") == 1)
        #expect(try sql.integer("SELECT expiresAt < modifiedAt FROM Memory \(target)") == 1)
        #expect(await f.embedder.texts().isEmpty)
    }

    @Test(arguments: ["", "explicit source\r\ne\u{0301}"])
    func sourceOnlyEditPreservesExactMetadataAndReceiptOnReplay(_ source: String) async throws {
        let f = try fixture(embedder: FixtureEmbedder(mode: "nil"))
        defer { f.close() }
        let operation = try f.request(.update(UpdateRequest(id: f.sourceID, source: source)))
        let receipt = try await f.tools.applyOperation(operation)
        let sql = try SQL(f.path)
        let target = "WHERE globalId='\(f.sourceID.uuidString)'"
        let modified = try sql.text("SELECT CAST(modifiedAt AS TEXT) FROM Memory \(target)")
        #expect(try sql.text("SELECT source FROM Memory \(target)").utf8.elementsEqual(source.utf8))
        #expect(try sql.text("SELECT content FROM Memory \(target)") == "original")
        #expect(UUID(uuidString: try sql.text("SELECT authorUserId FROM Memory \(target)")) == f.principal.id)
        #expect(try await f.tools.applyOperation(operation) == receipt)
        #expect(try sql.text("SELECT CAST(modifiedAt AS TEXT) FROM Memory \(target)") == modified)
        #expect(await f.embedder.texts().isEmpty)
        let changed = try f.request(.update(UpdateRequest(id: f.sourceID, source: source + "changed")),
                                    id: operation.operationID)
        await #expect(throws: MemoryOperationError.payloadConflict(operationID: operation.operationID)) {
            try await f.tools.applyOperation(changed)
        }
        #expect(try sql.text("SELECT source FROM Memory \(target)").utf8.elementsEqual(source.utf8))
        #expect(try sql.integer("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 1)
    }

    @Test(arguments: ["", "typed legacy source\r\ne\u{0301}"])
    func typedLegacyUpdateForwardsSourceWithoutEmbedding(_ source: String) async throws {
        let f = try fixture(embedder: FixtureEmbedder(mode: "nil"))
        defer { f.close() }
        _ = try await f.tools.update(UpdateRequest(id: f.sourceID, source: source))
        let sql = try SQL(f.path)
        #expect(try sql.text("SELECT source FROM Memory WHERE globalId='\(f.sourceID.uuidString)'")
            .utf8.elementsEqual(source.utf8))
        #expect(await f.embedder.texts().isEmpty)
        #expect(try sql.integer("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 0)
    }

    @Test func changedPayloadCannotRepeatAnAppend() async throws {
        let f = try fixture()
        defer { f.close() }
        let operation = try f.request(.update(UpdateRequest(id: f.sourceID, append: "once")))
        _ = try await f.tools.applyOperation(operation)
        let changed = try f.request(.update(UpdateRequest(id: f.sourceID, append: "twice")), id: operation.operationID)
        await #expect(throws: MemoryOperationError.payloadConflict(operationID: operation.operationID)) {
            _ = try await f.tools.applyOperation(changed)
        }
        #expect(await f.embedder.texts().count == 1)
        #expect(try SQL(f.path).text("SELECT content FROM Memory WHERE globalId='\(f.sourceID.uuidString)'") == "original\nonce")
    }

    @Test(arguments: ["nil", "short", "nonfinite"])
    func unavailableOrInvalidEmbeddingDoesNotMutateOrPublishReceipt(_ mode: String) async throws {
        let f = try fixture(embedder: FixtureEmbedder(mode: mode))
        defer { f.close() }
        await #expect(throws: (any Error).self) {
            _ = try await f.tools.applyOperation(f.request(.update(UpdateRequest(id: f.sourceID, append: "after"))))
        }
        #expect(try SQL(f.path).text("SELECT content FROM Memory WHERE globalId='\(f.sourceID.uuidString)'") == "original")
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func canonicallyEqualButByteChangedContentDuringEmbeddingIsRejected() async throws {
        let gate = FixtureEmbedder(mode: "paused")
        let f = try fixture(content: "caf\u{00e9}", embedder: gate)
        defer { f.close() }
        let operation = try f.request(.update(UpdateRequest(id: f.sourceID, append: "tail")))
        let tools = f.tools
        let pending = Task { try await tools.applyOperation(operation) }
        await gate.waitUntilEntered()
        let memory = try f.memory()
        try f.local.withTransaction { memory.content = "cafe\u{0301}" }
        await gate.release()
        await #expect(throws: MemoryOperationError.invalidRequest("Memory content changed during operation preparation")) {
            _ = try await pending.value
        }
        let content = try SQL(f.path).text("SELECT content FROM Memory WHERE globalId='\(f.sourceID.uuidString)'")
        #expect(content.utf8.elementsEqual("cafe\u{0301}".utf8))
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func identityChangeDuringEmbeddingIsRejected() async throws {
        let gate = FixtureEmbedder(mode: "paused")
        let f = try fixture(embedder: gate)
        defer { f.close() }
        let operation = try f.request(.update(UpdateRequest(id: f.sourceID, append: "tail")))
        let tools = f.tools
        let pending = Task { try await tools.applyOperation(operation) }
        await gate.waitUntilEntered()
        f.identity.set(Principal(id: UUID(), kind: .user))
        await gate.release()
        await #expect(throws: MemoryOperationError.scopeMismatch) { _ = try await pending.value }
        #expect(try SQL(f.path).text("SELECT content FROM Memory WHERE globalId='\(f.sourceID.uuidString)'") == "original")
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 0)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["tombstone", "author"])
    func targetEligibilityIsRecheckedAfterEmbedding(_ change: String) async throws {
        let gate = FixtureEmbedder(mode: "paused")
        let f = try fixture(embedder: gate)
        defer { f.close() }
        let operation = try f.request(.update(UpdateRequest(id: f.sourceID, append: "tail", isPrivate: true)))
        let tools = f.tools
        let pending = Task { try await tools.applyOperation(operation) }
        await gate.waitUntilEntered()
        let memory = try f.memory()
        try f.local.withTransaction {
            if change == "tombstone" { memory.deletedAt = Date() }
            else { memory.authorUserId = UUID() }
        }
        await gate.release()
        await #expect(throws: MemoryOperationError.unsupportedTarget) { _ = try await pending.value }
        #expect(try SQL(f.path).text("SELECT content FROM Memory WHERE globalId='\(f.sourceID.uuidString)'") == "original")
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 0)
    }

    @Test(arguments: ["update", "connect"])
    func foreignOrMissingTargetsNeverMutateLocalStore(_ tool: String) async throws {
        let f = try fixture()
        defer { f.close() }
        for id in [f.foreignID, UUID()] {
            let mutation: MemoryMutation = tool == "update"
                ? .update(UpdateRequest(id: id, append: "tail"))
                : .connect(ConnectRequest(sourceId: f.sourceID, targetId: id, relation: "relates_to"))
            await #expect(throws: MemoryOperationError.unsupportedTarget) {
                _ = try await f.tools.applyOperation(f.request(mutation))
            }
        }
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM Edge") == 0)
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 0)
        #expect(await f.embedder.texts().isEmpty)
    }

    @Test func connectCreateDuplicateReviveAndReplayAreAtomic() async throws {
        let f = try fixture()
        defer { f.close() }
        let mutation = MemoryMutation.connect(ConnectRequest(sourceId: f.sourceID, targetId: f.targetID, relation: "relates_to"))
        let operation = try f.request(mutation)
        let first = try await f.tools.applyOperation(operation)
        #expect(first.outcome == .applied && first.memoryIDs == [f.sourceID, f.targetID])
        #expect(first.edgeIDs.count == 1)
        #expect(try await f.tools.applyOperation(operation) == first)
        let duplicate = try await f.tools.applyOperation(f.request(mutation))
        #expect(duplicate.outcome == .unchanged && duplicate.edgeIDs == first.edgeIDs)
        let edgeID = try #require(first.edgeIDs.first)
        let edge = try #require(f.local.objects(Edge.self).where { $0.globalId == edgeID }.first)
        try f.local.withTransaction { edge.deletedAt = Date() }
        let restore = try f.request(mutation)
        let revived = try await f.tools.applyOperation(restore)
        #expect(revived.outcome == .applied && revived.edgeIDs == first.edgeIDs)
        #expect(try await f.tools.applyOperation(restore) == revived)
        let sql = try SQL(f.path)
        #expect(try sql.integer("SELECT COUNT(*) FROM Edge") == 1)
        #expect(try sql.integer("SELECT deletedAt IS NULL FROM Edge") == 1)
        #expect(UUID(uuidString: try sql.text("SELECT authorUserId FROM Edge")) == f.principal.id)
        #expect(try sql.integer("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 3)
        #expect(await f.embedder.texts().isEmpty)
    }

    @Test func selfConnectionReceiptDoesNotDuplicateMemoryIDs() async throws {
        let f = try fixture()
        defer { f.close() }
        let result = try await f.tools.applyOperation(f.request(.connect(ConnectRequest(
            sourceId: f.sourceID, targetId: f.sourceID, relation: "relates_to"))))
        #expect(result.memoryIDs == [f.sourceID] && result.edgeIDs.count == 1)
    }

    @Test func duplicateExistingEdgesAreRefusedWithoutPublishingAReceipt() async throws {
        let f = try fixture()
        defer { f.close() }
        for _ in 0..<2 {
            try f.local.add(Edge(sourceGlobalId: f.sourceID, targetGlobalId: f.targetID, relation: .relatesTo))
        }
        await #expect(throws: MemoryOperationError.storageUnavailable) {
            _ = try await f.tools.applyOperation(f.request(.connect(ConnectRequest(
                sourceId: f.sourceID, targetId: f.targetID, relation: "relates_to"))))
        }
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM Edge") == 2)
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 0)
    }

    @Test func tombstonedEndpointCannotCreateOrReviveAnEdge() async throws {
        let f = try fixture()
        defer { f.close() }
        let memory = try f.memory()
        try f.local.withTransaction { memory.deletedAt = Date() }
        try f.local.add(Edge(sourceGlobalId: f.sourceID, targetGlobalId: f.targetID,
                             relation: .relatesTo, deletedAt: Date()))
        await #expect(throws: MemoryOperationError.unsupportedTarget) {
            _ = try await f.tools.applyOperation(f.request(.connect(ConnectRequest(
                sourceId: f.sourceID, targetId: f.targetID, relation: "relates_to"))))
        }
        #expect(try SQL(f.path).integer("SELECT deletedAt IS NOT NULL FROM Edge") == 1)
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 0)
    }

    @Test(arguments: ["update", "connect"])
    func failedReceiptInsertRollsBackMutation(_ tool: String) async throws {
        let f = try fixture()
        defer { f.close() }
        let sql = try SQL(f.path)
        try sql.execute("CREATE TRIGGER reject_edit_receipt BEFORE INSERT ON EngramOperationReceiptV1 BEGIN SELECT RAISE(ABORT, 'synthetic receipt failure'); END")
        let mutation: MemoryMutation = tool == "update"
            ? .update(UpdateRequest(id: f.sourceID, append: "tail", topic: "new"))
            : .connect(ConnectRequest(sourceId: f.sourceID, targetId: f.targetID, relation: "relates_to"))
        await #expect(throws: MemoryOperationError.storageUnavailable) {
            _ = try await f.tools.applyOperation(f.request(mutation))
        }
        #expect(try sql.text("SELECT content FROM Memory WHERE globalId='\(f.sourceID.uuidString)'") == "original")
        #expect(try sql.text("SELECT topic FROM Memory WHERE globalId='\(f.sourceID.uuidString)'") == "general")
        #expect(try sql.integer("SELECT COUNT(*) FROM Edge") == 0)
        #expect(try sql.integer("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 0)
    }

    @Test(arguments: ["memory", "edge"])
    func failedTargetQueryNeverBecomesAbsenceOrCreatesAnEdge(_ table: String) async throws {
        let f = try fixture()
        defer { f.close() }
        // Open before injecting the query failure; schema registration on a
        // fresh connection would recreate the renamed table.
        try await f.tools.prepareStorage()
        let sql = try SQL(f.path)
        let tableName = table == "memory" ? "Memory" : "Edge"
        try sql.execute(table == "memory" ? "ALTER TABLE Memory RENAME TO HeldMemory" : "ALTER TABLE Edge RENAME TO HeldEdge")
        #expect(try sql.integer("SELECT COUNT(*) FROM sqlite_schema WHERE type='table' AND name='\(tableName)'") == 0)
        await #expect(throws: MemoryOperationError.storageUnavailable) {
            _ = try await f.tools.applyOperation(f.request(.connect(ConnectRequest(
                sourceId: f.sourceID, targetId: f.targetID, relation: "relates_to"))))
        }
        #expect(try sql.integer("SELECT COUNT(*) FROM sqlite_schema WHERE type='table' AND name='\(tableName)'") == 0)
        #expect(try sql.integer("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 0)
        #expect(try sql.integer("SELECT COUNT(*) FROM \(table == "edge" ? "HeldEdge" : "Edge")") == 0)
    }

    private final class SQL {
        private let db: OpaquePointer
        init(_ path: URL) throws {
            var handle: OpaquePointer?
            let code = sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
            guard code == SQLITE_OK, let handle else {
                if let handle { sqlite3_close(handle) }
                throw MemoryOperationError.storageUnavailable
            }
            db = handle
            sqlite3_busy_timeout(db, 100)
        }
        deinit { sqlite3_close(db) }
        func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw MemoryOperationError.storageUnavailable
            }
        }
        func text(_ sql: String) throws -> String {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw MemoryOperationError.storageUnavailable
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0),
                  let value = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, 0))),
                                     encoding: .utf8), sqlite3_step(statement) == SQLITE_DONE else {
                throw MemoryOperationError.storageUnavailable
            }
            return value
        }
        func integer(_ sql: String) throws -> Int {
            guard let value = Int(try text(sql)) else { throw MemoryOperationError.storageUnavailable }
            return value
        }
    }
}
