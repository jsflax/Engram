import EngramKit
import Foundation
import SQLite3
import Testing

// ============================================================================
// Oct 2026 incident: sqlite_stat1 claimed AuditLog held 1 row (it held
// 2.77M), so every cross-process notification's `WHERE id > ?` cursor query
// became a full table scan. These tests pin the startup repair: the
// all-tables PRAGMA optimize must turn the scan back into a rowid seek,
// never create a missing database, and give up quietly when the writer
// lock is held.
// ============================================================================

@Suite("Planner statistics refresh")
struct PlannerStatisticsTests {

    private static let cursorQuery =
        "SELECT id, tableName FROM AuditLog WHERE id > ?1 ORDER BY id ASC"

    /// A database whose AuditLog holds `rows` rows but whose statistics claim 1.
    private func makeStaleDatabase(rows: Int = 20_000) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("planner-stats-\(UUID().uuidString).sqlite").path
        try exec(path, """
            PRAGMA journal_mode = WAL;
            CREATE TABLE AuditLog(id INTEGER PRIMARY KEY AUTOINCREMENT,
                globalId TEXT UNIQUE COLLATE NOCASE, tableName TEXT,
                operation TEXT, rowId INTEGER);
            CREATE INDEX idx_audit_log_change_lookup ON AuditLog(tableName, rowId, operation);
            WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < \(rows))
            INSERT INTO AuditLog(globalId, tableName, operation, rowId)
            SELECT hex(randomblob(8)), 'Memory', 'UPDATE', x FROM c;
            ANALYZE;
            DELETE FROM sqlite_stat1 WHERE tbl = 'AuditLog';
            INSERT INTO sqlite_stat1 VALUES
                ('AuditLog', 'idx_audit_log_change_lookup', '1 1 1 1'),
                ('AuditLog', 'sqlite_autoindex_AuditLog_1', '1 1');
            """)
        return path
    }

    private func exec(_ path: String, _ sql: String) throws {
        var db: OpaquePointer?
        defer { sqlite3_close_v2(db) }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK,
              sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteFailure(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// The access path a FRESH connection picks for the notification query.
    private func plan(_ path: String) throws -> String {
        var db: OpaquePointer?
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt); sqlite3_close_v2(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN " + Self.cursorQuery, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW,
              let detail = sqlite3_column_text(stmt, 3) else {
            throw SQLiteFailure(message: String(cString: sqlite3_errmsg(db)))
        }
        return String(cString: detail)
    }

    private struct SQLiteFailure: Error { let message: String }

    @Test func staleStatistics_scanUntilRefreshed_thenSeek() throws {
        let path = try makeStaleDatabase()
        #expect(try plan(path).hasPrefix("SCAN AuditLog"))

        #expect(PlannerStatistics.refresh(dbPath: path, busyTimeoutMs: 2_000) == SQLITE_OK)

        #expect(try plan(path).hasPrefix("SEARCH AuditLog USING INTEGER PRIMARY KEY"))
    }

    @Test func freshStatistics_refreshIsANoOp() throws {
        let path = try makeStaleDatabase()
        PlannerStatistics.refresh(dbPath: path, busyTimeoutMs: 2_000)
        #expect(PlannerStatistics.refresh(dbPath: path, busyTimeoutMs: 2_000) == SQLITE_OK)
        #expect(try plan(path).hasPrefix("SEARCH AuditLog USING INTEGER PRIMARY KEY"))
    }

    @Test func missingDatabase_isNotCreated() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("planner-stats-missing-\(UUID().uuidString).sqlite").path
        #expect(PlannerStatistics.refresh(dbPath: path, busyTimeoutMs: 100) == SQLITE_OK)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    /// Another process holding the writer lock must cost at most the busy
    /// timeout, never an error that stops the server from starting.
    @Test func heldWriterLock_givesUpWithBusy() throws {
        let path = try makeStaleDatabase()
        var holder: OpaquePointer?
        defer { sqlite3_close_v2(holder) }
        #expect(sqlite3_open_v2(path, &holder, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        #expect(sqlite3_exec(holder, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)

        let started = Date()
        let code = PlannerStatistics.refresh(dbPath: path, busyTimeoutMs: 200)
        let waited = Date().timeIntervalSince(started)
        #expect(code == SQLITE_BUSY)
        // BEGIN IMMEDIATE consults the busy handler; a bare optimize's
        // read-to-write upgrade would have failed at once (0 ms).
        #expect(waited >= 0.15)
        #expect(waited < 5)

        sqlite3_exec(holder, "ROLLBACK", nil, nil, nil)
    }

    /// The live hub always has readers mid-scan (other servers, hooks). A WAL
    /// reader holding a snapshot must not stop the repair.
    @Test func openReader_doesNotBlockRefresh() throws {
        let path = try makeStaleDatabase()
        var reader: OpaquePointer?
        defer { sqlite3_close_v2(reader) }
        #expect(sqlite3_open_v2(path, &reader, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        #expect(sqlite3_exec(reader, "BEGIN; SELECT count(*) FROM AuditLog;", nil, nil, nil) == SQLITE_OK)

        #expect(PlannerStatistics.refresh(dbPath: path, busyTimeoutMs: 2_000) == SQLITE_OK)
        #expect(try plan(path).hasPrefix("SEARCH AuditLog USING INTEGER PRIMARY KEY"))

        sqlite3_exec(reader, "COMMIT", nil, nil, nil)
    }
}
