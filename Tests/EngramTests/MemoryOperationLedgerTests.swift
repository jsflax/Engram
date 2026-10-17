@testable import EngramKit
import EngramMemoryCore
import EngramModels
import Foundation
import Lattice
import SQLite3
import Testing

/// Real Lattice transactions and a separate SQLite observer. No live store,
/// external provider, embedding model, or capability advertisement is used.
@Suite("Local operation ledger", .serialized)
struct MemoryOperationLedgerTests {
    private struct Fixture {
        let directory: URL
        let path: URL
        let lattice: Lattice
        var ledger: MemoryOperationLedger { .init(lattice: lattice) }
    }

    private func fixture(bootstrap: Bool = true) throws -> Fixture {
        let base = ProcessInfo.processInfo.environment["ENGRAM_ADOPTION_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("operation-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("memory.sqlite")
        try MemoryOperationLedger.preflightLocalStore(at: path)
        let lattice = try Lattice(for: [Memory.self] + MemoryOperationLedger.localModels,
                                  configuration: .init(fileURL: path, busyTimeoutMs: 100))
        if bootstrap { try MemoryOperationLedger(lattice: lattice).bootstrapStoreID() }
        return Fixture(directory: directory, path: path, lattice: lattice)
    }

    private func prepared(_ fixture: Fixture, operationID: UUID = UUID(), content: String = "synthetic durable operation",
                          principal: Principal = .anonymous) throws -> MemoryOperationCanonicalPayload {
        try .prepare(MemoryOperationRequest(operationID: operationID,
            expectedScope: fixture.ledger.scope(principal: principal),
            provenance: MemoryOperationProvenance(host: "synthetic-host", sessionID: "fixture-session", runID: "fixture-run",
                source: MemoryOperationSourceInterval(startOffset: 10, endOffset: 20,
                    excerptDigest: MemoryOperationDigest(sha256: String(repeating: "a", count: 64)))),
            mutation: .remember(RememberRequest(content: content, project: "LedgerFixture"))))
    }

    private func apply(_ fixture: Fixture, _ operation: MemoryOperationCanonicalPayload) throws -> MemoryOperationLedger.Commit {
        try fixture.ledger.withOperation(operation, principal: { .anonymous }) {
            let memory = Memory(content: "synthetic mutation in owning transaction", project: "LedgerFixture")
            try fixture.lattice.add(memory)
            return .init(outcome: .applied, memoryIDs: [try #require(memory.globalId)])
        }
    }

    @Test func firstPreflightDoesNotCreateAFile() throws {
        let path = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ENGRAM_ADOPTION_TEST_ROOT"]
                       ?? FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("absent-ledger-\(UUID().uuidString).sqlite")
        try MemoryOperationLedger.preflightLocalStore(at: path)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test func establishedBootstrapReadsIdentityWhileAnotherWriterRemainsHeld() throws {
        let f = try fixture()
        defer { f.lattice.close() }
        let knownID = try f.ledger.scope(principal: .anonymous).storeID
        let blocker = try SQL(f.path)
        let rowIDs = try blocker.strings("SELECT globalId FROM EngramOperationStoreV1")
        try #require(rowIDs.count == 1)
        try blocker.execute("BEGIN IMMEDIATE")
        defer { try? blocker.execute("ROLLBACK") }
        #expect(blocker.isInTransaction)
        f.lattice.onQueryError { _ in
            Issue.record("Reading an established identity must not attempt writer admission or fail a query")
        }
        defer { f.lattice.onQueryError { _ in } }

        #expect(try f.ledger.bootstrapStoreID() == knownID)

        #expect(blocker.isInTransaction)
        #expect(try blocker.strings("SELECT globalId FROM EngramOperationStoreV1") == rowIDs)
        #expect(try blocker.text("SELECT storeID FROM EngramOperationStoreV1") == knownID.uuidString.lowercased())
    }

    @Test func firstBootstrapRequiresWriterAdmissionBeforeCreatingIdentity() throws {
        let f = try fixture(bootstrap: false)
        defer { f.lattice.close() }
        let blocker = try SQL(f.path)
        #expect(try blocker.integer("SELECT COUNT(*) FROM EngramOperationStoreV1") == 0)
        try blocker.execute("BEGIN IMMEDIATE")
        defer { try? blocker.execute("ROLLBACK") }

        #expect(throws: MemoryOperationError.storageUnavailable) { try f.ledger.bootstrapStoreID() }

        #expect(blocker.isInTransaction)
        #expect(try blocker.integer("SELECT COUNT(*) FROM EngramOperationStoreV1") == 0)
        try blocker.execute("ROLLBACK")
        let createdID = try f.ledger.bootstrapStoreID()
        #expect(try blocker.integer("SELECT COUNT(*) FROM EngramOperationStoreV1") == 1)
        #expect(try blocker.text("SELECT storeID FROM EngramOperationStoreV1") == createdID.uuidString.lowercased())
        #expect(try f.ledger.bootstrapStoreID() == createdID)
    }

    @Test func bootstrapStoreQueryFailureDoesNotAttemptWriterAdmission() throws {
        let f = try fixture()
        defer { f.lattice.close() }
        let blocker = try SQL(f.path)
        let knownID = try blocker.text("SELECT storeID FROM EngramOperationStoreV1")
        try blocker.execute("ALTER TABLE EngramOperationStoreV1 RENAME TO HeldStoreIdentityEvidence")
        try blocker.execute("BEGIN IMMEDIATE")
        defer { try? blocker.execute("ROLLBACK") }
        let errors = QueryErrorRecorder()
        f.lattice.onQueryError { errors.observe($0) }
        defer { f.lattice.onQueryError { _ in } }

        #expect(throws: MemoryOperationError.storageUnavailable) { try f.ledger.bootstrapStoreID() }

        let messages = errors.snapshot()
        #expect(!messages.isEmpty)
        #expect(messages.allSatisfy { $0.contains("no such table: EngramOperationStoreV1") })
        #expect(!messages.contains { $0.contains("Failed to begin transaction") })
        #expect(blocker.isInTransaction)
        #expect(try blocker.integer("SELECT COUNT(*) FROM HeldStoreIdentityEvidence") == 1)
        #expect(try blocker.text("SELECT storeID FROM HeldStoreIdentityEvidence") == knownID)
        #expect(try blocker.integer("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='EngramOperationStoreV1'") == 0)
    }

    @Test func storeScopeReadsOwnUncommittedIdentityAndRollbackRemovesIt() throws {
        let f = try fixture(bootstrap: false)
        defer { f.lattice.close() }
        let observer = try SQL(f.path)
        let storeID = UUID()
        let rollback = MemoryOperationError.invalidRequest("synthetic identity rollback")

        #expect(throws: rollback) {
            try f.lattice.withTransaction {
                try f.lattice.add(EngramOperationStoreV1(storeID: storeID))
                #expect(try f.ledger.scope(principal: .anonymous).storeID == storeID)
                #expect(try observer.integer("SELECT COUNT(*) FROM EngramOperationStoreV1") == 0)
                throw rollback
            }
        }

        #expect(try observer.integer("SELECT COUNT(*) FROM EngramOperationStoreV1") == 0)
    }

    @Test func commitsMutationAndImmutableReceiptThenReplaysAfterReopen() throws {
        let f = try fixture()
        let operation = try prepared(f)
        let commit = try apply(f, operation)
        #expect(!commit.isReplay)
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM Memory") == 1)
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 1)
        let firstJSON = try SQL(f.path).text("SELECT receiptJSON FROM EngramOperationReceiptV1")
        f.lattice.close()
        try MemoryOperationLedger.preflightLocalStore(at: f.path)
        let reopened = try Lattice(for: [Memory.self] + MemoryOperationLedger.localModels,
                                   configuration: .init(fileURL: f.path, busyTimeoutMs: 100))
        defer { reopened.close() }
        let ledger = MemoryOperationLedger(lattice: reopened)
        #expect(try ledger.bootstrapStoreID() == operation.expectedScope.storeID)
        let replay = try ledger.withOperation(operation, principal: { .anonymous }) {
            Issue.record("Replay must never invoke the mutation body")
            throw MemoryOperationError.invalidRequest("unexpected body")
        }
        #expect(replay.isReplay)
        #expect(replay.receipt == commit.receipt)
        #expect(try SQL(f.path).text("SELECT receiptJSON FROM EngramOperationReceiptV1") == firstJSON)
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM Memory") == 1)
        #expect(try ledger.status(operationID: operation.operationID, scope: operation.expectedScope,
                                  principal: .anonymous) == .committed(commit.receipt))
    }

    @Test func generatedEmptyLedgerSchemaPassesPreflight() throws {
        let f = try fixture()
        defer { f.lattice.close() }
        // Validate real pinned model DDL independently of receipt decoding.
        try MemoryOperationLedger.preflightLocalStore(at: f.path)
    }

    @Test func conflictAndWrongPrincipalNeverRunMutation() throws {
        let f = try fixture()
        defer { f.lattice.close() }
        let operation = try prepared(f)
        _ = try apply(f, operation)
        let changed = try prepared(f, operationID: operation.operationID, content: "different payload")
        #expect(throws: MemoryOperationError.payloadConflict(operationID: operation.operationID)) {
            try f.ledger.lookup(changed, principal: .anonymous)
        }
        #expect(throws: MemoryOperationError.payloadConflict(operationID: operation.operationID)) {
            try f.ledger.withOperation(changed, principal: { .anonymous }) {
                Issue.record("Conflicting payload must never mutate")
                return .init(outcome: .unchanged)
            }
        }
        #expect(throws: MemoryOperationError.scopeMismatch) {
            try f.ledger.withOperation(operation, principal: { Principal(id: UUID(), kind: .user) }) {
                Issue.record("Changed principal must never mutate")
                return .init(outcome: .unchanged)
            }
        }
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM Memory") == 1)
    }

    @Test func failedReceiptInsertRollsBackMutation() throws {
        let f = try fixture()
        defer { f.lattice.close() }
        let operation = try prepared(f)
        try SQL(f.path).execute("CREATE TRIGGER reject_ledger BEFORE INSERT ON EngramOperationReceiptV1 BEGIN SELECT RAISE(ABORT, 'synthetic receipt failure'); END")
        #expect(throws: MemoryOperationError.storageUnavailable) { try apply(f, operation) }
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM Memory") == 0)
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 0)
        #expect(try f.ledger.status(operationID: operation.operationID, scope: operation.expectedScope,
                                   principal: .anonymous) == .absent(operationID: operation.operationID, scope: operation.expectedScope))
        try SQL(f.path).execute("DROP TRIGGER reject_ledger")
        #expect(try !apply(f, operation).isReplay)
    }

    @Test func bodyFailureRollsBackAlreadyWrittenMemory() throws {
        let f = try fixture()
        defer { f.lattice.close() }
        let operation = try prepared(f)
        #expect(throws: MemoryOperationError.invalidRequest("synthetic body failure")) {
            try f.ledger.withOperation(operation, principal: { .anonymous }) {
                try f.lattice.add(Memory(content: "must roll back"))
                throw MemoryOperationError.invalidRequest("synthetic body failure")
            }
        }
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM Memory") == 0)
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 0)
    }

    @Test func busyBeginDoesNotInvokeBodyOrPublishReceipt() throws {
        let f = try fixture()
        defer { f.lattice.close() }
        let operation = try prepared(f)
        let blocker = try SQL(f.path)
        try blocker.execute("BEGIN IMMEDIATE")
        defer { try? blocker.execute("ROLLBACK") }
        let started = ProcessInfo.processInfo.systemUptime
        #expect(throws: MemoryOperationError.storageUnavailable) {
            try f.ledger.withOperation(operation, principal: { .anonymous }) {
                Issue.record("Failed BEGIN must never invoke the body")
                return .init(outcome: .unchanged)
            }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        #expect(elapsed >= 0.2) // More than one configured 100ms BEGIN attempt.
        #expect(elapsed < 2.0) // Finite small-fixture budget, including scheduling allowance.
        #expect(try blocker.integer("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 0)
    }

    @Test func retryCanAcquireReleasedWriterWithoutRepeatingBody() throws {
        let f = try fixture()
        defer { f.lattice.close() }
        let operation = try prepared(f)
        let blocker = try SQL(f.path)
        try blocker.execute("BEGIN IMMEDIATE")
        let release = BeginContentionRelease(blocker: blocker)
        f.lattice.onQueryError { release.observe($0) }
        defer {
            f.lattice.onQueryError { _ in }
            try? blocker.execute("ROLLBACK")
        }
        var bodyCalls = 0
        let result = Result {
            try f.ledger.withOperation(operation, principal: { .anonymous }) {
                bodyCalls += 1
                return .init(outcome: .unchanged)
            }
        }
        try release.verify()
        let commit = try result.get()
        #expect(!commit.isReplay)
        #expect(bodyCalls == 1)
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 1)
    }

    @Test func bodyEnteredContentionShapedErrorIsNeverRetried() throws {
        let f = try fixture()
        defer { f.lattice.close() }
        let operation = try prepared(f)
        var calls = 0
        #expect(throws: MemoryOperationError.storageUnavailable) {
            try f.ledger.withOperation(operation, principal: { .anonymous }) {
                calls += 1
                try f.lattice.add(Memory(content: "must roll back once"))
                throw LatticeError.transactionError("Failed to begin transaction: database is locked")
            }
        }
        #expect(calls == 1)
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM Memory") == 0)
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 0)
    }

    @Test(arguments: [false, true])
    func principalChangeDuringBeginWaitRejectsNewWriteAndReplay(_ alreadyCommitted: Bool) throws {
        let f = try fixture()
        defer { f.lattice.close() }
        let operation = try prepared(f)
        if alreadyCommitted { _ = try apply(f, operation) }
        let principal = PrincipalBox()
        let blocker = try SQL(f.path)
        try blocker.execute("BEGIN IMMEDIATE")
        let release = BeginContentionRelease(blocker: blocker) {
            principal.set(Principal(id: UUID(), kind: .user))
        }
        f.lattice.onQueryError { release.observe($0) }
        defer {
            f.lattice.onQueryError { _ in }
            try? blocker.execute("ROLLBACK")
        }
        #expect(throws: MemoryOperationError.scopeMismatch) {
            try f.ledger.withOperation(operation, principal: { principal.get() }) {
                Issue.record("Principal changed while waiting for BEGIN; no body is authorized")
                return .init(outcome: .unchanged)
            }
        }
        try release.verify()
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM Memory") == (alreadyCommitted ? 1 : 0))
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM EngramOperationReceiptV1") == (alreadyCommitted ? 1 : 0))
    }

    @Test func unboundedDefaultBusyTimeoutRefusesBeforeAnyWrite() throws {
        let f = try fixture()
        let operation = try prepared(f)
        f.lattice.close()
        let defaultWriter = try Lattice(for: [Memory.self] + MemoryOperationLedger.localModels,
                                        configuration: .init(fileURL: f.path))
        defer { defaultWriter.close() }
        let ledger = MemoryOperationLedger(lattice: defaultWriter)
        #expect(throws: MemoryOperationError.storageUnavailable) { try ledger.bootstrapStoreID() }
        #expect(throws: MemoryOperationError.storageUnavailable) {
            try ledger.withOperation(operation, principal: { .anonymous }) {
                Issue.record("Unbounded writer configuration must never invoke mutation")
                return .init(outcome: .unchanged)
            }
        }
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM Memory") == 0)
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 0)
        #expect(try ledger.scope(principal: .anonymous) == operation.expectedScope)
    }

    @Test func queryFailureIsNotAbsence() throws {
        let f = try fixture()
        defer { f.lattice.close() }
        let operation = try prepared(f)
        // Actual SQLite schema failure through the pinned Lattice query path.
        try SQL(f.path).execute("ALTER TABLE EngramOperationReceiptV1 RENAME TO HeldReceiptEvidence")
        #expect(throws: MemoryOperationError.storageUnavailable) {
            try f.ledger.status(operationID: operation.operationID, scope: operation.expectedScope,
                                 principal: .anonymous)
        }
        #expect(throws: MemoryOperationError.storageUnavailable) {
            try f.ledger.withOperation(operation, principal: { .anonymous }) {
                Issue.record("Failed lookup must never invoke the body")
                return .init(outcome: .unchanged)
            }
        }
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM Memory") == 0)
    }

    @Test func oldSchemaReopenPreservesReceiptAndStableStoreIdentity() throws {
        let f = try fixture()
        let operation = try prepared(f)
        _ = try apply(f, operation)
        let receipt = try SQL(f.path).text("SELECT receiptJSON FROM EngramOperationReceiptV1")
        f.lattice.close()
        let older = try Lattice(Memory.self, configuration: .init(fileURL: f.path, busyTimeoutMs: 100))
        try older.add(Memory(content: "older writer normal memory"))
        older.close()
        #expect(try SQL(f.path).text("SELECT receiptJSON FROM EngramOperationReceiptV1") == receipt)
        try MemoryOperationLedger.preflightLocalStore(at: f.path)
        let reopened = try Lattice(for: [Memory.self] + MemoryOperationLedger.localModels,
                                   configuration: .init(fileURL: f.path, busyTimeoutMs: 100))
        defer { reopened.close() }
        #expect(try MemoryOperationLedger(lattice: reopened).bootstrapStoreID() == operation.expectedScope.storeID)
        #expect(try SQL(f.path).integer("SELECT COUNT(*) FROM Memory") == 2)
    }

    @Test(arguments: ["missing-index", "wrong-index", "partial-index", "nocase-key-index", "duplicate", "bad-receipt", "null-global-id", "one-table", "wrong-case"])
    func malformedExistingLedgerIsRefusedWithoutRepair(_ fault: String) throws {
        let f = try fixture()
        let operation = try prepared(f)
        _ = try apply(f, operation)
        f.lattice.close()
        let sql = try SQL(f.path)
        // Remove audit triggers for intentional corruption; SQLite's separate
        // connection does not register Lattice audit functions. This is a
        // synthetic fixture only, never a repair implementation.
        for name in try sql.strings("SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='EngramOperationReceiptV1'") {
            try sql.execute("DROP TRIGGER \"\(name.replacingOccurrences(of: "\"", with: "\"\""))\"")
        }
        switch fault {
        case "missing-index": try sql.execute("DROP INDEX unique_EngramOperationReceiptV1_0")
        case "wrong-index":
            try sql.execute("DROP INDEX unique_EngramOperationReceiptV1_0")
            try sql.execute("CREATE UNIQUE INDEX unique_EngramOperationReceiptV1_0 ON EngramOperationReceiptV1(payloadSHA256)")
        case "partial-index":
            try sql.execute("DROP INDEX unique_EngramOperationReceiptV1_0")
            try sql.execute("CREATE UNIQUE INDEX unique_EngramOperationReceiptV1_0 ON EngramOperationReceiptV1(operationID, storeID, principalKey) WHERE formatVersion=1")
        case "nocase-key-index":
            try sql.execute("DROP INDEX unique_EngramOperationReceiptV1_0")
            try sql.execute("CREATE UNIQUE INDEX unique_EngramOperationReceiptV1_0 ON EngramOperationReceiptV1(operationID COLLATE NOCASE, storeID, principalKey)")
        case "duplicate":
            try sql.execute("DROP INDEX unique_EngramOperationReceiptV1_0")
            try sql.execute("INSERT INTO EngramOperationReceiptV1(globalId, operationID, storeID, principalKey, payloadSHA256, receiptJSON, provenanceJSON, formatVersion) SELECT '\(UUID().uuidString)', operationID, storeID, principalKey, payloadSHA256, receiptJSON, provenanceJSON, formatVersion FROM EngramOperationReceiptV1")
        case "bad-receipt": try sql.execute("UPDATE EngramOperationReceiptV1 SET receiptJSON='{}'")
        case "null-global-id": try sql.execute("UPDATE EngramOperationReceiptV1 SET globalId=NULL")
        case "one-table": try sql.execute("DROP TABLE EngramOperationStoreV1")
        case "wrong-case":
            try sql.execute("ALTER TABLE EngramOperationStoreV1 RENAME TO IntermediateName")
            try sql.execute("ALTER TABLE IntermediateName RENAME TO engramoperationstorev1")
        default: Issue.record("Unknown fixture corruption")
        }
        let count = try sql.integer("SELECT COUNT(*) FROM EngramOperationReceiptV1")
        let content = try sql.strings("SELECT receiptJSON FROM EngramOperationReceiptV1 ORDER BY id")
        #expect(throws: MemoryOperationError.storageUnavailable) {
            try MemoryOperationLedger.preflightLocalStore(at: f.path)
        }
        #expect(try sql.integer("SELECT COUNT(*) FROM EngramOperationReceiptV1") == count)
        #expect(try sql.strings("SELECT receiptJSON FROM EngramOperationReceiptV1 ORDER BY id") == content)
    }

    /// Lattice reports a failed checked BEGIN synchronously, before throwing.
    /// Release the independent SQLite writer only after that real contention
    /// has occurred, so the next ledger retry can acquire it. No queue or sleep
    /// races the production BEGIN budget; the callback never touches Lattice.
    private final class BeginContentionRelease: @unchecked Sendable {
        private static let expectedError = "Failed to begin transaction: database is locked"
        private let lock = NSLock()
        private let blocker: SQL
        private let beforeRelease: @Sendable () -> Void
        private var messages: [String] = []
        private var result: Result<Void, any Error>?

        init(blocker: SQL, beforeRelease: @escaping @Sendable () -> Void = {}) {
            self.blocker = blocker
            self.beforeRelease = beforeRelease
        }

        func observe(_ message: String) {
            lock.withLock {
                messages.append(message)
                guard message == Self.expectedError, result == nil else { return }
                result = Result {
                    beforeRelease()
                    try blocker.execute("ROLLBACK")
                }
            }
        }

        func verify() throws {
            let (observedMessages, releaseResult) = lock.withLock { (messages, result) }
            #expect(observedMessages == [Self.expectedError])
            try #require(releaseResult).get()
        }
    }

    private final class QueryErrorRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []
        func observe(_ message: String) { lock.withLock { messages.append(message) } }
        func snapshot() -> [String] { lock.withLock { messages } }
    }

    private final class SQL: @unchecked Sendable {
        private let db: OpaquePointer
        init(_ path: URL) throws {
            var pointer: OpaquePointer?
            let code = sqlite3_open_v2(path.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
            guard code == SQLITE_OK, let pointer else {
                if let pointer { sqlite3_close(pointer) }
                throw MemoryOperationError.storageUnavailable
            }
            db = pointer
            sqlite3_busy_timeout(db, 100)
        }
        deinit { sqlite3_close(db) }
        var isInTransaction: Bool { sqlite3_get_autocommit(db) == 0 }
        func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw MemoryOperationError.invalidRequest(String(cString: sqlite3_errmsg(db)))
            }
        }
        func strings(_ sql: String) throws -> [String] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw MemoryOperationError.invalidRequest(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            var values: [String] = []
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW {
                guard let text = sqlite3_column_text(statement, 0) else { throw MemoryOperationError.storageUnavailable }
                values.append(String(cString: text))
                code = sqlite3_step(statement)
            }
            guard code == SQLITE_DONE else { throw MemoryOperationError.storageUnavailable }
            return values
        }
        func text(_ sql: String) throws -> String { try #require(strings(sql).first) }
        func integer(_ sql: String) throws -> Int { try #require(Int(text(sql))) }
    }

    private final class PrincipalBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Principal.anonymous
        func get() -> Principal { lock.withLock { value } }
        func set(_ next: Principal) { lock.withLock { value = next } }
    }
}
