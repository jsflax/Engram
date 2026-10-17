import EngramMemoryCore
import EngramModels
import Foundation
import Lattice
import SQLite3
import Testing
@testable import EngramKit

/// Exercise the production upload filters against real IPC. Registering the
/// ledger on the receiving test handle is intentional: an omitted production
/// model must not make accidental export invisible to the test.
@Suite("Operation ledger sync isolation", .serialized)
struct OperationLedgerSyncIsolationTests {
    enum Route: String, CaseIterable, Sendable {
        case personalHub, groupHub, personalRelay, groupRelay, spokeToHub
        case unfilteredControl

        func filter(from source: Lattice, groupID: UUID, authorID: UUID) -> Lattice.SyncFilter? {
            switch self {
            case .personalHub: SyncService.buildSyncFilter(from: source)
            case .groupHub: SyncService.buildGroupSyncFilter(from: source, groupId: groupID)
            case .personalRelay: SyncService.buildPersonalRelaySyncFilter()
            case .groupRelay: SyncService.buildGroupRelaySyncFilter()
            case .spokeToHub: SyncService.buildSpokeToHubFilter(me: authorID)
            case .unfilteredControl: nil
            }
        }
    }

    private var fixtureModels: [any Model.Type] {
        [Memory.self, Edge.self, SyncConfig.self, GroupProjectMap.self]
            + MemoryOperationLedger.localModels
    }

    private func waitForMemory(_ id: UUID, in lattice: Lattice) async -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if lattice.objects(Memory.self).where({ $0.globalId == id }).first != nil { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return lattice.objects(Memory.self).where({ $0.globalId == id }).first != nil
    }

    private func ledgerCounts(in lattice: Lattice) throws -> (stores: Int, receipts: Int) {
        let stores = lattice.objects(EngramOperationStoreV1.self).count
        try #require(lattice.lastQueryError() == nil, "Store count query failed")
        let receipts = lattice.objects(EngramOperationReceiptV1.self).count
        try #require(lattice.lastQueryError() == nil, "Receipt count query failed")
        return (stores, receipts)
    }

    /// Incoming IPC rows keep their global isSynchronized flag at zero even
    /// after this channel's durable acknowledgement is recorded. A startup
    /// reconcile may also put those rows in the sync set, so the whole-store
    /// pendingSyncEntryCount can stay nonzero after both peers have finished.
    /// Check the exact barrier and preceding shared rows for this channel.
    private func acknowledgedBarrier(_ barrier: UUID, at url: URL, channel: String) throws -> Bool {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        defer { if let database { sqlite3_close(database) } }
        try #require(opened == SQLITE_OK, "Could not open acknowledgement readback")
        let db = try #require(database)
        try #require(sqlite3_busy_timeout(db, 100) == SQLITE_OK)
        let sql = """
            WITH barrier AS (
                SELECT MAX(id) AS last_id, COUNT(*) AS rows
                FROM AuditLog
                WHERE tableName = 'Memory' AND globalRowId = ?1 COLLATE NOCASE
            ), eligible AS (
                SELECT a.id, a.isSynchronized
                FROM AuditLog a
                WHERE a.id <= (SELECT last_id FROM barrier)
                  AND ((a.tableName = 'Memory' AND a.globalRowId = ?1 COLLATE NOCASE)
                       OR EXISTS (SELECT 1 FROM _lattice_sync_set ss
                                  WHERE ss.sync_id = ?2 AND ss.table_name = a.tableName
                                    AND ss.global_row_id = a.globalRowId))
            )
            SELECT (SELECT rows FROM barrier) > 0
              AND EXISTS (SELECT 1 FROM _lattice_replication_slots WHERE sync_id = ?2)
              AND NOT EXISTS (
                  SELECT 1 FROM eligible a
                  WHERE COALESCE((SELECT st.is_synchronized FROM _lattice_sync_state st
                                  WHERE st.audit_entry_id = a.id AND st.sync_id = ?2),
                                 a.isSynchronized) != 1
              )
            """
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                     "Could not prepare acknowledgement readback")
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try #require(sqlite3_bind_text(statement, 1, barrier.uuidString, -1, transient) == SQLITE_OK)
        try #require(sqlite3_bind_text(statement, 2, "ipc:\(channel)", -1, transient) == SQLITE_OK)
        try #require(sqlite3_step(statement) == SQLITE_ROW, "Acknowledgement readback failed")
        return sqlite3_column_int(statement, 0) == 1
    }

    private func waitForAcknowledgements(_ barrier: UUID, source: URL, target: URL,
                                         channel: String) async throws -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if try acknowledgedBarrier(barrier, at: source, channel: channel)
                && acknowledgedBarrier(barrier, at: target, channel: channel) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return try acknowledgedBarrier(barrier, at: source, channel: channel)
            && acknowledgedBarrier(barrier, at: target, channel: channel)
    }

    /// The memory and real receipt commit together, followed by a later audit
    /// row. Observing that later row is the relay's positive progress control.
    private func seedOperation(in source: Lattice, authorID: UUID) throws -> UUID {
        let ledger = MemoryOperationLedger(lattice: source)
        try ledger.bootstrapStoreID()
        let principal = Principal(id: authorID, kind: .user)
        let scope = try ledger.scope(principal: principal)
        let provenance = try MemoryOperationProvenance(
            host: "sync-isolation-test", sessionID: "fixture", runID: UUID().uuidString,
            source: MemoryOperationSourceInterval(
                startOffset: 1, endOffset: 2,
                excerptDigest: MemoryOperationDigest(sha256: String(repeating: "a", count: 64))))
        let prepared = try MemoryOperationCanonicalPayload.prepare(MemoryOperationRequest(
            operationID: UUID(), expectedScope: scope, provenance: provenance,
            mutation: .remember(RememberRequest(content: "shared fixture", topic: "testing", project: "shared"))))
        let memory = Memory(content: "shared fixture", topic: "testing", project: "shared",
                            authorUserId: authorID)
        let commit = try ledger.withOperation(prepared, principal: { principal }) {
            try source.add(memory)
            return .init(outcome: .applied, memoryIDs: [try #require(memory.globalId)])
        }
        #expect(!commit.isReplay)
        let barrier = Memory(content: "after receipt", topic: "testing", project: "shared",
                             authorUserId: authorID)
        try source.add(barrier)
        return try #require(barrier.globalId)
    }

    @Test(.timeLimit(.minutes(1)), arguments: Route.allCases)
    func productionFiltersExcludeEvidenceWhileUnfilteredControlExportsIt(_ route: Route) async throws {
        let directory = try testFixtureDirectory().appending(path: "lsi-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appending(path: "source.sqlite")
        let targetURL = directory.appending(path: "target.sqlite")
        let socket = directory.appending(path: "ipc.sock").path
        // Keep every runtime artifact in the configured fixture directory,
        // including the socket (whose Darwin sockaddr path is bounded).
        try #require(socket.utf8.count < 104, "Choose a shorter ENGRAM_TEST_ROOT for IPC fixtures")
        defer {
            try? Lattice.delete(for: .init(fileURL: sourceURL))
            try? Lattice.delete(for: .init(fileURL: targetURL))
            try? FileManager.default.removeItem(at: directory)
        }

        try MemoryOperationLedger.preflightLocalStore(at: sourceURL)
        try MemoryOperationLedger.preflightLocalStore(at: targetURL)
        let source = try Lattice(for: fixtureModels,
                                 configuration: .init(fileURL: sourceURL, busyTimeoutMs: 100))
        let groupID = UUID(), authorID = UUID()
        try source.add(SyncConfig(project: "shared", policy: .sync,
                                  exposedTeams: [groupID.uuidString]))
        let firstBarrier = try seedOperation(in: source, authorID: authorID)
        let channel = "ledger-\(UUID().uuidString.prefix(8))"
        #expect(try !acknowledgedBarrier(firstBarrier, at: sourceURL, channel: channel),
                "A local barrier without a registered channel must not count as acknowledged")
        var sourceConfig = Lattice.Configuration(fileURL: sourceURL, busyTimeoutMs: 100)
        sourceConfig.ipcTargets = [.init(
            channel: channel,
            syncFilter: route.filter(from: source, groupID: groupID, authorID: authorID),
            socketPath: socket, narrowingEmitsRemovals: false)]
        try MemoryOperationLedger.preflightLocalStore(at: sourceURL)
        let sourceRelay = try Lattice(for: fixtureModels, configuration: sourceConfig)
        var targetConfig = Lattice.Configuration(fileURL: targetURL, busyTimeoutMs: 100)
        targetConfig.ipcTargets = [.init(
            channel: channel, syncFilter: SyncService.buildPersonalRelaySyncFilter(),
            socketPath: socket, narrowingEmitsRemovals: false)]
        let target = try Lattice(for: fixtureModels, configuration: targetConfig)

        try #require(await waitForMemory(firstBarrier, in: target), "Startup relay positive control failed")
        try #require(await waitForAcknowledgements(firstBarrier, source: sourceURL, target: targetURL,
                                                    channel: channel), "Startup relay did not acknowledge the barrier")
        // The unfiltered control must actually export the evidence; otherwise
        // zero rows on the filtered routes could merely mean that this fixture
        // never exercised export of the ledger's tables.
        let expectedStoreCount = route == .unfilteredControl ? 1 : 0
        let firstTargetCounts = try ledgerCounts(in: target)
        #expect(firstTargetCounts.stores == expectedStoreCount)
        #expect(firstTargetCounts.receipts == expectedStoreCount)
        #expect(try ledgerCounts(in: source).receipts == 1)

        sourceRelay.updateSyncFilter(
            route.filter(from: source, groupID: groupID, authorID: authorID), forChannel: channel)
        let secondBarrier = try seedOperation(in: source, authorID: authorID)
        try #require(await waitForMemory(secondBarrier, in: target), "Refreshed relay positive control failed")
        try #require(await waitForAcknowledgements(secondBarrier, source: sourceURL, target: targetURL,
                                                    channel: channel), "Refreshed relay did not acknowledge the barrier")
        let secondTargetCounts = try ledgerCounts(in: target)
        #expect(secondTargetCounts.stores == expectedStoreCount)
        #expect(secondTargetCounts.receipts == expectedStoreCount * 2)
        let sourceCounts = try ledgerCounts(in: source)
        #expect(sourceCounts.stores == 1)
        #expect(sourceCounts.receipts == 2)
    }
}
