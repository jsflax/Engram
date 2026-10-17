import EngramMemoryCore
import EngramModels
import Foundation
import Lattice
import SQLite3

/// Local-store operation ledger. Opening/registration must first pass
/// `preflightLocalStore(at:)`; merely constructing this object advertises no
/// capability. The mutation body and immutable receipt use one existing owning
/// Lattice connection and one checked transaction. No second write database,
/// fallback write, or nested transaction is involved.
/// Bootstrap and operation writers require an explicit busyTimeoutMs in
/// 1...2000; larger/default waits cannot meet the bounded BEGIN admission
/// policy and are refused before entering a write transaction.
public struct MemoryOperationLedger {
    public static var localModels: [any Model.Type] {
        [EngramOperationStoreV1.self, EngramOperationReceiptV1.self]
    }

    private let lattice: Lattice
    private static let singletonKey = "local-operation-store"
    private static let maximumJSONBytes = 32_768

    public init(lattice: Lattice) { self.lattice = lattice }

    /// Bootstrap only after safe registration. An existing identity needs only
    /// a checked read; concurrent first writers are serialized by checked
    /// BEGIN IMMEDIATE and re-read before creation. The identity is never replaced.
    @discardableResult public func bootstrapStoreID() throws -> UUID {
        try storageErrors {
            // Preserve the writer-budget contract even when bootstrap can read
            // the immutable identity without competing for SQLite's write lock.
            let timeout = lattice.configuration.busyTimeoutMs
            guard timeout > 0, timeout <= 2_000 else { throw MemoryOperationError.storageUnavailable }
            if let id = try readStoreID() { return id }
            return try withBeginRetry {
                if let id = try readStoreID() { return id }
                let query = lattice.objects(EngramOperationReceiptV1.self)
                query.refresh()
                let receipts = query.snapshot(limit: 1)
                try checkQuery()
                guard receipts.isEmpty else { throw MemoryOperationError.storageUnavailable }
                let id = UUID()
                try lattice.add(EngramOperationStoreV1(storeID: id))
                return id
            }
        }
    }

    public func scope(principal: Principal) throws -> MemoryOperationScope {
        guard let id = try readStoreID() else { throw MemoryOperationError.storageUnavailable }
        return try MemoryOperationScope(storeID: id, principal: .init(principal))
    }

    public func status(operationID: UUID, scope expected: MemoryOperationScope,
                       principal: Principal) throws -> MemoryOperationStatus {
        try validateScope(expected, principal: principal)
        if let receipt = try readReceipt(operationID: operationID, scope: expected) {
            return .committed(receipt)
        }
        return .absent(operationID: operationID, scope: expected)
    }

    /// Read before expensive embedding, then repeat inside the transaction.
    /// Only a successful authoritative query returns nil; query/decode failure
    /// is never interpreted as absence or permission to execute a legacy write.
    func lookup(_ prepared: MemoryOperationCanonicalPayload,
                principal: Principal) throws -> MemoryOperationReceipt? {
        try validateScope(prepared.expectedScope, principal: principal)
        guard let receipt = try readReceipt(operationID: prepared.operationID,
                                            scope: prepared.expectedScope) else { return nil }
        guard receipt.payloadDigest == prepared.digest else {
            throw MemoryOperationError.payloadConflict(operationID: prepared.operationID)
        }
        return receipt
    }

    struct MutationResult {
        let outcome: MemoryOperationReceipt.Outcome
        var memoryIDs: [UUID] = []
        var edgeIDs: [UUID] = []
    }

    struct Commit {
        let receipt: MemoryOperationReceipt
        /// Post-commit effects must not run again for an idempotent replay.
        let isReplay: Bool
    }

    /// Capture the current principal after BEGIN acquires the writer lock,
    /// including on replay: groups.json may change during the lock wait.
    /// `mutationBody` must be synchronous and use this exact owning lattice;
    /// it may not perform another transaction or external side effects.
    func withOperation(_ prepared: MemoryOperationCanonicalPayload, principal: () -> Principal,
                       mutationBody: () throws -> MutationResult) throws -> Commit {
        try storageErrors {
            try withBeginRetry {
                if let prior = try lookup(prepared, principal: principal()) {
                    return Commit(receipt: prior, isReplay: true)
                }
                let result = try mutationBody()
                let kind: MemoryMutation.Kind
                switch prepared.mutation {
                case .remember: kind = .remember
                case .update: kind = .update
                case .connect: kind = .connect
                }
                let receipt = try MemoryOperationReceipt(
                    operationID: prepared.operationID, scope: prepared.expectedScope,
                    payloadDigest: prepared.digest, mutation: kind, outcome: result.outcome,
                    memoryIDs: result.memoryIDs, edgeIDs: result.edgeIDs, committedAt: Date())
                try lattice.add(EngramOperationReceiptV1(
                    operationID: Self.key(prepared.operationID),
                    storeID: Self.key(prepared.expectedScope.storeID),
                    principalKey: try Self.principalKey(prepared.expectedScope.principal),
                    payloadSHA256: prepared.digest.sha256,
                    receiptJSON: try Self.encode(receipt),
                    provenanceJSON: try Self.encode(prepared.provenance)))
                return Commit(receipt: receipt, isReplay: false)
            }
        }
    }

    private func validateScope(_ expected: MemoryOperationScope, principal: Principal) throws {
        guard try scope(principal: principal) == expected else { throw MemoryOperationError.scopeMismatch }
    }

    private func readStoreID() throws -> UUID? {
        // The eager query seals this read's error independently of an earlier
        // failed BEGIN. A generation-backed empty snapshot can retain that
        // earlier thread-local error. The owning Lattice routes this eager
        // read through its writer when the current thread is in a transaction.
        let rows = lattice.dynamicObjects(EngramOperationStoreV1.entityName).snapshot(limit: 2)
        try checkQuery()
        guard rows.count <= 1 else { throw MemoryOperationError.storageUnavailable }
        guard let image = rows.first else { return nil }
        let row = EngramOperationStoreV1(image.backend)
        // snapshot() hydrates every scalar but live model accessors otherwise
        // re-query per field. Read the one checked row image consistently.
        row.materialize()
        guard row.singletonKey == Self.singletonKey, row.formatVersion == 1,
              let id = UUID(uuidString: row.storeID), Self.key(id) == row.storeID else {
            throw MemoryOperationError.storageUnavailable
        }
        return id
    }

    private func readReceipt(operationID: UUID, scope: MemoryOperationScope) throws -> MemoryOperationReceipt? {
        let operationKey = Self.key(operationID)
        let storeKey = Self.key(scope.storeID)
        let principalKey = try Self.principalKey(scope.principal)
        let query = lattice.objects(EngramOperationReceiptV1.self)
            .where { $0.operationID == operationKey && $0.storeID == storeKey && $0.principalKey == principalKey }
        query.refresh()
        let rows = query.snapshot(limit: 2)
        try checkQuery()
        guard rows.count <= 1 else { throw MemoryOperationError.storageUnavailable }
        guard let row = rows.first else { return nil }
        row.materialize()
        let receipt = try Self.decodeReceipt(operationID: row.operationID, storeID: row.storeID,
            principalKey: row.principalKey, payloadSHA256: row.payloadSHA256,
            receiptJSON: row.receiptJSON, provenanceJSON: row.provenanceJSON,
            formatVersion: row.formatVersion)
        guard receipt.operationID == operationID, receipt.scope == scope else {
            throw MemoryOperationError.storageUnavailable
        }
        return receipt
    }

    private func checkQuery() throws {
        guard lattice.lastQueryError() == nil else { throw MemoryOperationError.storageUnavailable }
    }

    private func storageErrors<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as MemoryOperationError { throw error }
        catch { throw MemoryOperationError.storageUnavailable }
    }

    /// The pinned Core gives each BEGIN its configured busy-timeout budget.
    /// Admit another attempt only if that entire budget still fits. Retrying is
    /// allowed solely before the checked transaction invokes its closure, for
    /// known BEGIN lock contention; no mutation, query, or COMMIT is replayed.
    /// Other errors (including nested transactions) propagate immediately.
    private func withBeginRetry<T>(_ body: () throws -> T) throws -> T {
        let timeout = lattice.configuration.busyTimeoutMs
        // Core interprets zero/negative as its 30-second default. A writer
        // configured above this bound cannot provide this interactive budget.
        guard timeout > 0, timeout <= 2_000 else { throw MemoryOperationError.storageUnavailable }
        let started = ProcessInfo.processInfo.systemUptime
        let maximumElapsed = 6.25
        for attempt in 0..<3 {
            guard ProcessInfo.processInfo.systemUptime - started + Double(timeout) / 1_000 <= maximumElapsed else {
                throw MemoryOperationError.storageUnavailable
            }
            var bodyEntered = false
            do {
                return try lattice.withTransaction {
                    bodyEntered = true
                    return try body()
                }
            } catch {
                guard !bodyEntered, attempt < 2, Self.isBeginContention(error) else { throw error }
                let delay = Double(attempt + 1) * 0.025
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                guard elapsed + delay + Double(timeout) / 1_000 <= maximumElapsed else { throw error }
                Thread.sleep(forTimeInterval: delay)
            }
        }
        throw MemoryOperationError.storageUnavailable
    }

    private static func isBeginContention(_ error: any Error) -> Bool {
        guard case LatticeError.transactionError(let message) = error else { return false }
        // Exact messages emitted by pinned LatticeCore 2.0.7. Unknown failures
        // fail closed; broad substring matching could retry an indeterminate
        // error from a later phase.
        return message == "Failed to begin transaction: database is locked"
            || message == "Failed to begin transaction: database table is locked"
            || message == "Failed to begin transaction: database schema is locked"
    }

    private static func key(_ id: UUID) -> String { id.uuidString.lowercased() }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= maximumJSONBytes, let json = String(data: data, encoding: .utf8) else {
            throw MemoryOperationError.invalidRequest("Operation evidence exceeds storage bounds")
        }
        return json
    }

    private static func principalKey(_ principal: MemoryOperationPrincipalBinding) throws -> String {
        try MemoryOperationCanonicalPayload.principalKey(principal)
    }

    private static func decodeReceipt(operationID: String, storeID: String, principalKey: String,
                                      payloadSHA256: String, receiptJSON: String, provenanceJSON: String,
                                      formatVersion: Int) throws -> MemoryOperationReceipt {
        guard formatVersion == 1, receiptJSON.utf8.count <= maximumJSONBytes,
              provenanceJSON.utf8.count <= maximumJSONBytes else { throw MemoryOperationError.storageUnavailable }
        do {
            let decoder = JSONDecoder()
            let receipt = try decoder.decode(MemoryOperationReceipt.self, from: Data(receiptJSON.utf8))
            _ = try decoder.decode(MemoryOperationProvenance.self, from: Data(provenanceJSON.utf8))
            guard key(receipt.operationID) == operationID, key(receipt.scope.storeID) == storeID,
                  try Self.principalKey(receipt.scope.principal) == principalKey,
                  receipt.payloadDigest.sha256 == payloadSHA256 else {
                throw MemoryOperationError.storageUnavailable
            }
            return receipt
        } catch { throw MemoryOperationError.storageUnavailable }
    }
}

extension MemoryOperationLedger {
    /// Fail closed BEFORE registering the versioned ledger models with Lattice.
    /// LatticeCore 2.0.7 repairs failed unique-index creation by deleting rows;
    /// this check must never be replaced by opening first and checking later.
    /// The read-only connection uses a consistent snapshot and executes no DDL.
    /// Normal ledger writers retain the validated unique indexes thereafter.
    public static func preflightLocalStore(at url: URL) throws {
        guard url.isFileURL else { throw MemoryOperationError.storageUnavailable }
        var directory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { return }
        guard !directory.boolValue else { throw MemoryOperationError.storageUnavailable }
        let reader = try LedgerPreflightReader(url: url)
        try reader.execute("BEGIN")
        defer { try? reader.execute("ROLLBACK") }

        let storeTable = "EngramOperationStoreV1"
        let receiptTable = "EngramOperationReceiptV1"
        let found = try reader.rows("SELECT name, type FROM sqlite_master WHERE name COLLATE NOCASE IN ('\(storeTable)', '\(receiptTable)')")
        guard !found.isEmpty else { return }
        guard found.count == 2, Set(found.compactMap { $0[0] }) == Set([storeTable, receiptTable]),
              found.allSatisfy({ $0[1] == "table" }) else { throw MemoryOperationError.storageUnavailable }

        try reader.validateTable(storeTable, columns: [
            "id": "INTEGER", "globalId": "TEXT", "singletonKey": "TEXT", "storeID": "TEXT", "formatVersion": "INTEGER"
        ], uniqueColumns: ["singletonKey"])
        try reader.validateTable(receiptTable, columns: [
            "id": "INTEGER", "globalId": "TEXT", "operationID": "TEXT", "storeID": "TEXT",
            "principalKey": "TEXT", "payloadSHA256": "TEXT", "receiptJSON": "TEXT",
            "provenanceJSON": "TEXT", "formatVersion": "INTEGER"
        ], uniqueColumns: ["operationID", "storeID", "principalKey"])

        let stores = try reader.rows("SELECT singletonKey, storeID, formatVersion, globalId FROM \(storeTable) LIMIT 2")
        guard stores.count <= 1 else { throw MemoryOperationError.storageUnavailable }
        var storeID: String?
        if let row = stores.first {
            guard row[0] == singletonKey, let value = row[1], let id = UUID(uuidString: value),
                  key(id) == value, row[2] == "1", let global = row[3], UUID(uuidString: global) != nil else {
                throw MemoryOperationError.storageUnavailable
            }
            storeID = value
        }
        // Stream rather than retain every historical receipt. Decode validates
        // bounded evidence and its redundant key/digest columns, without ever
        // reading memory content or returning receipt JSON to a diagnostic.
        try reader.forEachRow("SELECT operationID, storeID, principalKey, payloadSHA256, receiptJSON, provenanceJSON, formatVersion, globalId FROM \(receiptTable)") { row in
            guard row.count == 8, let operationID = row[0], let receiptStore = row[1],
                  let principal = row[2], let digest = row[3], let receiptJSON = row[4],
                  let provenanceJSON = row[5], row[6] == "1", let global = row[7],
                  UUID(uuidString: global) != nil, receiptStore == storeID else {
                throw MemoryOperationError.storageUnavailable
            }
            _ = try decodeReceipt(operationID: operationID, storeID: receiptStore,
                                  principalKey: principal, payloadSHA256: digest,
                                  receiptJSON: receiptJSON, provenanceJSON: provenanceJSON, formatVersion: 1)
        }
    }
}

/// SQLite is used solely for pre-registration read-only inspection. Mutations
/// always use the owning Lattice checked transaction above.
private final class LedgerPreflightReader {
    private let db: OpaquePointer

    init(url: URL) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw MemoryOperationError.storageUnavailable
        }
        db = handle
        sqlite3_busy_timeout(db, 250)
    }

    deinit { sqlite3_close(db) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw MemoryOperationError.storageUnavailable
        }
    }

    func rows(_ sql: String) throws -> [[String?]] {
        var rows: [[String?]] = []
        try forEachRow(sql) { rows.append($0) }
        return rows
    }

    func forEachRow(_ sql: String, body: ([String?]) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw MemoryOperationError.storageUnavailable
        }
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw MemoryOperationError.storageUnavailable }
            var values: [String?] = []
            for column in 0..<sqlite3_column_count(statement) {
                if sqlite3_column_type(statement, column) == SQLITE_NULL { values.append(nil); continue }
                let count = Int(sqlite3_column_bytes(statement, column))
                guard count <= 32_768, let bytes = sqlite3_column_text(statement, column),
                      let text = String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8) else {
                    throw MemoryOperationError.storageUnavailable
                }
                values.append(text)
            }
            try body(values)
        }
    }

    func validateTable(_ table: String, columns: [String: String], uniqueColumns: [String]) throws {
        // Names come exclusively from the fixed schema above, never user data.
        let info = try rows("PRAGMA table_xinfo('\(table)')")
        guard info.count == columns.count else { throw MemoryOperationError.storageUnavailable }
        var seen: Set<String> = []
        for row in info {
            guard row.count == 7, let name = row[1], seen.insert(name).inserted,
                  // Pinned Core create_model_table uses a nullable globalId
                  // with a SQL UUID default, not database::create_table's
                  // separate NOT NULL form. Validate the actual model schema;
                  // the data checks below still reject every NULL globalId.
                  columns[name] == row[2], row[3] == (["id", "globalId"].contains(name) ? "0" : "1"),
                  row[5] == (name == "id" ? "1" : "0"), row[6] == "0" else {
                throw MemoryOperationError.storageUnavailable
            }
        }
        let expectedName = "unique_\(table)_0"
        let indexes = try rows("PRAGMA index_list('\(table)')")
        var foundConstraint = false
        var foundGlobalID = false
        for row in indexes where row.count >= 5 && row[2] == "1" {
            guard let name = row[1], row[4] == "0", name.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95
            }) else { throw MemoryOperationError.storageUnavailable }
            let fields = try rows("PRAGMA index_xinfo('\(name)')").filter { $0.count >= 6 && $0[5] == "1" }
            let names = fields.compactMap { $0[2] }
            let expectedCollation = names == ["globalId"] ? "NOCASE" : "BINARY"
            guard fields.allSatisfy({ $0[3] == "0" && $0[4] == expectedCollation }) else {
                throw MemoryOperationError.storageUnavailable
            }
            if name == expectedName && names == uniqueColumns { foundConstraint = true }
            else if names == ["globalId"] { foundGlobalID = true }
            else { throw MemoryOperationError.storageUnavailable }
        }
        guard foundConstraint, foundGlobalID else { throw MemoryOperationError.storageUnavailable }
        let group = uniqueColumns.joined(separator: ", ")
        guard try rows("SELECT 1 FROM \(table) GROUP BY \(group) HAVING COUNT(*) > 1 LIMIT 1").isEmpty else {
            throw MemoryOperationError.storageUnavailable
        }
        // SQLite affinity alone does not reject a wrong dynamic storage type.
        let badTypes = columns.filter { $0.key != "id" }.map { name, type in
            "typeof(\(name)) != '\(type == "INTEGER" ? "integer" : "text")'"
        }.joined(separator: " OR ")
        guard try rows("SELECT 1 FROM \(table) WHERE \(badTypes) LIMIT 1").isEmpty else {
            throw MemoryOperationError.storageUnavailable
        }
    }
}
