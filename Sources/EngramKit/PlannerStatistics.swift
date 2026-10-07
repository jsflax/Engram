import Foundation
import SQLite3

/// Refreshes SQLite's query-planner statistics before Lattice opens a store.
///
/// Every cross-process notification makes each Lattice instance run
/// `SELECT ... FROM AuditLog WHERE id > ? ORDER BY id`. With accurate
/// statistics that is a rowid seek over a handful of new rows. LatticeCore no
/// longer runs ANALYZE at open, and its close-time `PRAGMA optimize` never
/// repairs AuditLog, so a hub whose `sqlite_stat1` was written while AuditLog
/// was tiny keeps claiming it holds 1 row. The planner then picks a full scan:
/// on a 2.77M-row AuditLog every notification cost 4-22 s, and a dozen MCP
/// servers rescanning in turn held ~9 cores (Oct 2026 incident).
///
/// The fix has to run in a separate connection BEFORE Lattice opens its own:
/// an open connection keeps the statistics it loaded at schema load, and an
/// ANALYZE from another connection does not reach it. Only the all-tables
/// form, `PRAGMA optimize=0x10002`, re-analyzes AuditLog here; plain
/// `PRAGMA optimize` leaves the stale row in place. With fresh statistics the
/// call costs ~30 ms; repairing a stale multi-GB hub costs a few seconds once.
public enum PlannerStatistics {

    /// Run the bounded all-tables `PRAGMA optimize` on an existing database.
    ///
    /// Never creates the file (a missing database has no statistics to fix).
    /// A busy writer lock is not an error: the next process start retries.
    /// Returns the SQLite result code; `SQLITE_OK` also when the file is absent.
    @discardableResult
    public static func refresh(dbPath: String, busyTimeoutMs: Int32) -> Int32 {
        guard FileManager.default.fileExists(atPath: dbPath) else { return SQLITE_OK }
        var db: OpaquePointer?
        let openCode = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close_v2(db) }
        guard openCode == SQLITE_OK else { return openCode }
        sqlite3_busy_timeout(db, busyTimeoutMs)
        // analysis_limit matches LatticeCore's own bound: the scan samples at
        // most ~400 rows per index instead of reading the whole table.
        let limitCode = sqlite3_exec(db, "PRAGMA analysis_limit=400", nil, nil, nil)
        guard limitCode == SQLITE_OK else { return limitCode }
        // Take the writer lock first. A bare optimize starts as a reader and
        // upgrades, and SQLite fails a contended upgrade at once without
        // consulting the busy handler; BEGIN IMMEDIATE waits up to the timeout.
        let beginCode = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        guard beginCode == SQLITE_OK else { return beginCode }
        let optimizeCode = sqlite3_exec(db, "PRAGMA optimize=0x10002", nil, nil, nil)
        let endCode = sqlite3_exec(db, optimizeCode == SQLITE_OK ? "COMMIT" : "ROLLBACK", nil, nil, nil)
        return optimizeCode == SQLITE_OK ? endCode : optimizeCode
    }
}
