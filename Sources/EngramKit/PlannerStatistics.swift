import Foundation
import SQLite3

/// Refreshes SQLite's query-planner statistics before Lattice opens a store.
///
/// Every cross-process notification makes each Lattice instance run
/// `SELECT ... FROM AuditLog WHERE id > ? ORDER BY id`. With accurate
/// statistics that is a rowid seek over a handful of new rows. LatticeCore no
/// longer runs ANALYZE at open, and in practice its close-time
/// `PRAGMA optimize` does not repair AuditLog (servers usually leave through
/// `_exit`, and the cursor query uses no index, so plain optimize never picks
/// the table). A hub whose `sqlite_stat1` was written while AuditLog was tiny
/// keeps claiming it holds 1 row, and the planner picks a full scan: on a
/// 2.77M-row AuditLog every notification cost 4-22 s, and a dozen MCP servers
/// rescanning in turn held ~9 cores (Oct 2026 incident).
///
/// The fix has to run in a separate connection BEFORE Lattice opens its own:
/// an open connection keeps the statistics it loaded at schema load, and an
/// ANALYZE from another connection does not reach it. It needs the all-tables
/// form, `PRAGMA optimize=0x10002`, whose 0x10000 bit SQLite 3.46 introduced;
/// older libraries ignore the bit and analyze nothing, so they are reported as
/// unsupported instead of as a silent success. With fresh statistics the call
/// costs ~20-30 ms; repairing a stale multi-GB hub costs a few seconds once,
/// and holds the writer lock for that time (concurrent writers with short busy
/// timeouts may get SQLITE_BUSY once; a server starting in the same window
/// gives up and keeps the stale statistics until its next start).
public enum PlannerStatistics {

    /// First SQLite release whose `PRAGMA optimize` honors the 0x10000 bit.
    public static let minimumSQLiteVersion: Int32 = 3_046_000

    public enum Outcome: Equatable, Sendable {
        /// The bounded optimize ran and committed (a no-op when stats are fresh).
        case refreshed
        /// No database file yet, so nothing to repair. Nothing was created.
        case skippedMissingFile
        /// The linked SQLite predates the 0x10000 optimize bit; nothing ran.
        case unsupportedSQLite(version: String)
        /// SQLite returned an error, e.g. SQLITE_BUSY when the writer lock
        /// stayed held past the timeout. The store is left unchanged.
        case failed(code: Int32, message: String)
    }

    /// Run the bounded all-tables `PRAGMA optimize` on an existing database.
    ///
    /// `minimumVersion` exists so tests can exercise the unsupported path.
    public static func refresh(dbPath: String, busyTimeoutMs: Int32,
                               minimumVersion: Int32 = minimumSQLiteVersion) -> Outcome {
        guard sqlite3_libversion_number() >= minimumVersion else {
            return .unsupportedSQLite(version: String(cString: sqlite3_libversion()))
        }
        guard FileManager.default.fileExists(atPath: dbPath) else { return .skippedMissingFile }
        var db: OpaquePointer?
        defer { sqlite3_close_v2(db) }
        func failure(_ code: Int32) -> Outcome {
            .failed(code: code, message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
        }
        let openCode = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil)
        guard openCode == SQLITE_OK else { return failure(openCode) }
        sqlite3_busy_timeout(db, busyTimeoutMs)
        // analysis_limit matches LatticeCore's own bound: the scan samples at
        // most ~400 rows per index instead of reading the whole table.
        let limitCode = sqlite3_exec(db, "PRAGMA analysis_limit=400", nil, nil, nil)
        guard limitCode == SQLITE_OK else { return failure(limitCode) }
        // Take the writer lock first. A bare optimize starts as a reader and
        // upgrades, and SQLite fails a contended upgrade at once without
        // consulting the busy handler; BEGIN IMMEDIATE waits up to the timeout.
        let beginCode = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        guard beginCode == SQLITE_OK else { return failure(beginCode) }
        let optimizeCode = sqlite3_exec(db, "PRAGMA optimize=0x10002", nil, nil, nil)
        guard optimizeCode == SQLITE_OK else {
            let outcome = failure(optimizeCode)
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return outcome
        }
        let commitCode = sqlite3_exec(db, "COMMIT", nil, nil, nil)
        return commitCode == SQLITE_OK ? .refreshed : failure(commitCode)
    }
}
