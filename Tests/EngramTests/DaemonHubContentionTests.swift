@testable import EngramKit
import EngramModels
import Foundation
import Lattice
import SQLite3
import Testing

/// This fixture captures Lattice's process-global log sink. Run it alone in a
/// dedicated test process; the ordinary parallel suite must leave it disabled.
/// The path-tagged native BEGIN errors distinguish real acquisition failure
/// from a slow callback, a cold vector query, or the pre-apply initialization.
@Suite("Daemon hub BEGIN contention", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ENGRAM_DAEMON_CONTENTION_ISOLATED"] == "1"))
struct DaemonHubContentionTests {
    private struct Readback {
        let memoryRows: Int
        let auditRows: Int
        let totalAuditRows: Int
        let receipts: Int
        let receiveCursor: String?
        let acknowledged: Bool
    }

    /// Raw reads are restricted to this test's newly-created SQLite fixtures.
    /// They must not queue behind the Lattice handle whose sync callback is
    /// deliberately waiting in BEGIN, nor take that callback's store gate.
    private final class Reader {
        let database: OpaquePointer
        let readsApplyReceipts: Bool

        init(_ url: URL, readsApplyReceipts: Bool = true) throws {
            self.readsApplyReceipts = readsApplyReceipts
            var pointer: OpaquePointer?
            let result = sqlite3_open_v2(url.path, &pointer,
                                        SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
            guard result == SQLITE_OK, let pointer else {
                if let pointer { sqlite3_close(pointer) }
                throw FixtureError.sqlite("open readback", result)
            }
            database = pointer
            sqlite3_busy_timeout(database, 100)
        }

        deinit { sqlite3_close(database) }

        func row(_ sql: String, bindings: [String] = []) throws -> [String?] {
            var pointer: OpaquePointer?
            let prepared = sqlite3_prepare_v2(database, sql, -1, &pointer, nil)
            guard prepared == SQLITE_OK, let statement = pointer else {
                throw FixtureError.sqlite("prepare readback: \(sql)", prepared)
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (index, value) in bindings.enumerated() {
                let bound = sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
                guard bound == SQLITE_OK else { throw FixtureError.sqlite("bind readback", bound) }
            }
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW else { throw FixtureError.sqlite("step readback: \(sql)", result) }
            return (0..<sqlite3_column_count(statement)).map { index in
                guard let text = sqlite3_column_text(statement, index) else { return nil }
                return String(cString: text)
            }
        }

        func snapshot(_ id: UUID, channel: String) throws -> Readback {
            // One SELECT keeps the row, audit, receipt and cursor observations
            // in the same SQLite read snapshot. ACKs are channel-specific;
            // the global isSynchronized field alone is insufficient for IPC.
            let values = try row("""
                SELECT
                  (SELECT COUNT(*) FROM Memory WHERE globalId = ?1 COLLATE NOCASE),
                  (SELECT COUNT(*) FROM AuditLog
                   WHERE tableName = 'Memory' AND globalRowId = ?1 COLLATE NOCASE),
                  (SELECT COUNT(*) FROM AuditLog),
                  \(readsApplyReceipts ? "(SELECT COUNT(*) FROM _lattice_applied_receipts)" : "0"),
                  (SELECT last_received_event_id FROM _lattice_replication_slots WHERE sync_id = ?2),
                  EXISTS (SELECT 1 FROM AuditLog
                          WHERE tableName = 'Memory' AND globalRowId = ?1 COLLATE NOCASE)
                    AND EXISTS (SELECT 1 FROM _lattice_replication_slots WHERE sync_id = ?2)
                    AND NOT EXISTS (
                      SELECT 1 FROM AuditLog a
                      WHERE a.tableName = 'Memory' AND a.globalRowId = ?1 COLLATE NOCASE
                        AND COALESCE((SELECT s.is_synchronized FROM _lattice_sync_state s
                                     WHERE s.audit_entry_id = a.id AND s.sync_id = ?2),
                                     a.isSynchronized) != 1)
                """, bindings: [id.uuidString, "ipc:\(channel)"])
            return Readback(memoryRows: try integer(values[0]), auditRows: try integer(values[1]),
                            totalAuditRows: try integer(values[2]), receipts: try integer(values[3]),
                            receiveCursor: values[4], acknowledged: try integer(values[5]) == 1)
        }

        func auditEventIDs(_ id: UUID) throws -> Set<String> {
            let values = try row("""
                SELECT GROUP_CONCAT(globalId, ',') FROM AuditLog
                WHERE tableName = 'Memory' AND globalRowId = ?1 COLLATE NOCASE
                """, bindings: [id.uuidString])
            return Set((values[0] ?? "").split(separator: ",").map(String.init))
        }

        private func integer(_ value: String?) throws -> Int {
            guard let value, let number = Int(value) else { throw FixtureError.invalidReadback }
            return number
        }
    }

    private enum FixtureError: Error {
        case sqlite(String, Int32)
        case invalidReadback
    }

    private func waitUntil(seconds: TimeInterval, _ ready: () throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        repeat {
            if try ready() { return true }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        return try ready()
    }

    private func matchingRow(_ memory: Memory, in lattice: Lattice) throws -> Bool {
        let id = try #require(memory.globalId)
        let row = lattice.objects(Memory.self).where { $0.globalId == id }.first
        try #require(lattice.lastQueryError() == nil, "Exact memory read failed")
        return row?.content == memory.content && row?.project == memory.project
            && row?.topic == memory.topic && row?.embedding == memory.embedding
    }

    /// Require the actual hub apply span, two genuine path-tagged BEGIN
    /// failures, the chunk retry, and the zero-entry return. Reject a span if
    /// another apply begins inside it: the untagged chunk warnings would then
    /// be ambiguous. This is deliberately stricter than an elapsed-time check.
    private func failedHubDelivery(in log: String, hub: URL) -> String? {
        let path = "db=\(hub.path))"
        let beginPath = "path=\(hub.path)): database is locked"
        var span: [String] = []
        var active = false
        var ambiguous = false
        for line in log.components(separatedBy: .newlines) {
            if line.contains("scheduler lambda: applying ") {
                if active { ambiguous = true }
                if line.hasSuffix(path) && !active {
                    active = true
                    ambiguous = false
                    span = []
                }
            }
            guard active else { continue }
            span.append(line)
            if line.contains("apply_remote_changes returned ") && line.hasSuffix(path) {
                let errors = span.filter {
                    $0.contains("[db] Failed to begin transaction (") && $0.hasSuffix(beginPath)
                }
                let retried = span.contains {
                    $0.contains("[apply_remote] chunk ")
                        && $0.contains("failed (Failed to begin transaction: database is locked) — retrying once")
                }
                let stopped = span.contains {
                    $0.contains("[apply_remote] chunk ")
                        && $0.contains("failed twice (Failed to begin transaction: database is locked)")
                        && $0.contains("0 already-committed entries will be acked")
                }
                let zeroReturned = line.contains("apply_remote_changes returned 0/")
                    && !line.contains("returned 0/0 ")
                if !ambiguous && errors.count == 2 && retried && stopped && zeroReturned {
                    return span.joined(separator: "\n")
                }
                active = false
                span = []
            }
        }
        return nil
    }

    @Test(.timeLimit(.minutes(3)))
    func realHubBeginContentionPreservesUnacknowledgedWorkAndRecovers() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixtureRoot = try #require(environment["ENGRAM_TEST_ROOT"], "Provide an explicit short fixture root")
        try #require(fixtureRoot.hasPrefix("/"), "The fixture root must be absolute")
        try #require(environment["LATTICE_LOG_LEVEL"] == "3", "Run the isolated process with native info logs")
        let logPath = try #require(environment["ENGRAM_DAEMON_CONTENTION_LOG"],
                                   "Provide a retained fixture log path")
        try #require(logPath.hasPrefix("/"), "The fixture log path must be absolute")
        let logURL = URL(fileURLWithPath: logPath)
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let logFile = try #require(fopen(logPath, "w"), "Could not open fixture log")
        Lattice.setLogFile(logFile)
        defer {
            // All database close defers run first. The FILE pointer remains
            // valid until the sink is disconnected, including error exits.
            Lattice.setLogFile(nil as UnsafeMutablePointer<FILE>?)
            fclose(logFile)
        }

        let directory = try testFixtureDirectory().appending(path: "dh-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appending(path: "source.sqlite")
        let hubURL = directory.appending(path: "hub.sqlite")
        let socket = directory.appending(path: "ipc.sock").path
        try #require(socket.utf8.count < 104, "Use a short ENGRAM_TEST_ROOT for the Darwin socket limit")
        let channel = "hub-busy-\(UUID().uuidString.prefix(8))"
        let models: [any Model.Type] = [Memory.self, Edge.self, SyncConfig.self]
        let target = Lattice.IPCSyncTarget(channel: channel,
                                           syncFilter: SyncService.buildPersonalRelaySyncFilter(),
                                           socketPath: socket, narrowingEmitsRemovals: false)
        var sourceConfig = Lattice.Configuration(fileURL: sourceURL, busyTimeoutMs: 2_000)
        sourceConfig.ipcTargets = [target]
        let source = try Lattice(for: models, configuration: sourceConfig)
        defer { source.close() }
        let hubConfig = SyncService.daemonHubConfiguration(dbPath: hubURL.path, ipcTargets: [target])
        try #require(hubConfig.busyTimeoutMs == 2_000 && hubConfig.busyTimeoutMsWasCustomized)
        let hub = try Lattice(for: models, configuration: hubConfig)
        defer { hub.close() }
        let vector = Vector<Float>([1, 0, 0, 0])
        let warm = Memory(content: "warm daemon hub barrier", topic: "contention", project: "daemon-fixture",
                          embedding: vector)
        try source.add(warm)
        let warmID = try #require(warm.globalId)
        try #require(await waitUntil(seconds: 30) { try matchingRow(warm, in: hub) },
                     "Initial real IPC delivery did not reach the hub")
        // A sender with no inbound delivery need not have an apply-receipt
        // table. Its readback checks the committed row/audit and exact ACKs.
        let sourceReader = try Reader(sourceURL, readsApplyReceipts: false)
        let hubReader = try Reader(hubURL)
        try #require(await waitUntil(seconds: 30) {
            try sourceReader.snapshot(warmID, channel: channel).acknowledged
                && hubReader.snapshot(warmID, channel: channel).acknowledged
        }, "Warm barrier was not acknowledged on both sides of this IPC channel")
        let nearest = hub.objects(Memory.self).nearest(to: vector, on: \.embedding, limit: 1, distance: .cosine)
        try #require(nearest.first?.globalId == warmID, "The first vector query must complete before locking")
        try #require(hub.lastQueryError() == nil, "Warm vector query failed")
        let baseline = try hubReader.snapshot(warmID, channel: channel)
        try #require(baseline.memoryRows == 1 && baseline.auditRows > 0 && baseline.acknowledged)
        try #require(baseline.receiveCursor?.isEmpty == false, "Warm receive cursor is missing")
        let logStart = try Data(contentsOf: logURL).count

        let holder = try RawWriteLock(path: hubURL.path)
        defer { holder.close() }
        try holder.acquire()
        let acquiredAt = ContinuousClock.now
        let pending = Memory(content: "delivery blocked at genuine BEGIN", topic: "contention",
                             project: "daemon-fixture", embedding: vector)
        try source.add(pending)
        let pendingID = try #require(pending.globalId)
        let sourcePending = try sourceReader.snapshot(pendingID, channel: channel)
        try #require(sourcePending.memoryRows == 1 && sourcePending.auditRows > 0 && !sourcePending.acknowledged,
                     "The pending delivery must be a committed, unacknowledged source write")
        let pendingEventIDs = try sourceReader.auditEventIDs(pendingID)
        try #require(!pendingEventIDs.isEmpty)
        var failedSpan: String?
        let observedFailure = try await waitUntil(seconds: 20) {
            let bytes = try Data(contentsOf: logURL)
            let log = String(decoding: bytes.dropFirst(logStart), as: UTF8.self)
            failedSpan = failedHubDelivery(in: log, hub: hubURL)
            return failedSpan != nil && acquiredAt.duration(to: .now) >= .seconds(5)
        }
        try #require(observedFailure,
                     "No unambiguous path-tagged two-BEGIN failure/zero-ACK delivery; inspect \(logPath)")
        let held = try hubReader.snapshot(pendingID, channel: channel)
        try #require(held.memoryRows == 0 && held.auditRows == 0 && !held.acknowledged)
        try #require(held.totalAuditRows == baseline.totalAuditRows)
        try #require(held.receipts == baseline.receipts, "Failed chunk must not mint idempotency receipts")
        try #require(held.receiveCursor == baseline.receiveCursor, "Failed chunk must not advance the download cursor")
        try #require(!sourceReader.snapshot(pendingID, channel: channel).acknowledged)
        try #require(sourceReader.snapshot(warmID, channel: channel).acknowledged)
        try #require(hubReader.snapshot(warmID, channel: channel).acknowledged)
        holder.release()

        // No reconnect, explicit resend, filter refresh, mutation replay, or
        // process restart: the existing sender must retry its unacked work.
        try #require(await waitUntil(seconds: 45) {
            try matchingRow(pending, in: hub)
                && sourceReader.snapshot(pendingID, channel: channel).acknowledged
                && hubReader.snapshot(pendingID, channel: channel).acknowledged
        }, "The same IPC connection did not recover the unacknowledged delivery")
        let recovered = try hubReader.snapshot(pendingID, channel: channel)
        try #require(recovered.memoryRows == 1 && recovered.auditRows > 0)
        let recoveredCursor = try #require(recovered.receiveCursor)
        try #require(pendingEventIDs.contains(recoveredCursor), "Recovery cursor must name this delivery's actual event")
        try #require(recoveredCursor != baseline.receiveCursor)
        let third = Memory(content: "continued traffic after contention", topic: "contention",
                           project: "daemon-fixture", embedding: vector)
        try source.add(third)
        let thirdID = try #require(third.globalId)
        let thirdEventIDs = try sourceReader.auditEventIDs(thirdID)
        try #require(!thirdEventIDs.isEmpty)
        try #require(await waitUntil(seconds: 30) {
            try matchingRow(third, in: hub)
                && sourceReader.snapshot(thirdID, channel: channel).acknowledged
                && hubReader.snapshot(thirdID, channel: channel).acknowledged
        }, "The connection did not carry the post-recovery barrier")
        let continued = try hubReader.snapshot(thirdID, channel: channel)
        let continuedCursor = try #require(continued.receiveCursor)
        try #require(thirdEventIDs.contains(continuedCursor), "Continued-traffic cursor must name the third barrier's event")
        try #require(continuedCursor != recoveredCursor)
        try #require(try matchingRow(warm, in: hub))
        try #require(try matchingRow(pending, in: hub))
        print("Daemon hub contention: real two-BEGIN failure, zero returned entries, unchanged ACK/cursor/receipts, automatic recovery and third barrier verified. Native log: \(logPath)")
        print(try #require(failedSpan))
    }
}
