import EngramKit
import Foundation
import SQLite3
import Testing

// ============================================================================
// Oct 2026 incident: sqlite_stat1 claimed AuditLog held 1 row (it held
// 2.77M), so every cross-process notification's `WHERE id > ?` cursor query
// became a full table scan. These tests pin the startup repair: the
// all-tables PRAGMA optimize must turn the scan back into a rowid seek,
// never create a missing database, wait out a held writer lock, and report
// SQLite builds that predate the optimize bit instead of claiming success.
// ============================================================================

/// The 0x10000 optimize bit needs SQLite 3.46; older system libraries take
/// the unsupported path, which has its own test below.
private let supportsAllTablesOptimize =
    sqlite3_libversion_number() >= PlannerStatistics.minimumSQLiteVersion

@Suite("Planner statistics refresh")
struct PlannerStatisticsTests {

    private static let cursorQuery =
        "SELECT id, tableName FROM AuditLog WHERE id > ?1 ORDER BY id ASC"

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("planner-stats-\(UUID().uuidString).sqlite").path
    }

    /// Remove the database and its WAL-mode sidecar files.
    private func removeDatabase(_ path: String) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// A database whose AuditLog holds `rows` rows but whose statistics claim 1.
    private func makeStaleDatabase(rows: Int = 20_000) throws -> String {
        let path = temporaryDatabasePath()
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

    /// First column of the first row, read on a FRESH connection.
    private func scalar(_ path: String, _ sql: String) throws -> String {
        var db: OpaquePointer?
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt); sqlite3_close_v2(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW,
              let text = sqlite3_column_text(stmt, 0) else {
            throw SQLiteFailure(message: String(cString: sqlite3_errmsg(db)))
        }
        return String(cString: text)
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

    private func auditLogStat(_ path: String) throws -> String {
        try scalar(path, "SELECT stat FROM sqlite_stat1 WHERE tbl = 'AuditLog' AND idx = 'sqlite_autoindex_AuditLog_1'")
    }

    private struct SQLiteFailure: Error { let message: String }

    @Test(.enabled(if: supportsAllTablesOptimize))
    func staleStatistics_scanUntilRefreshed_thenSeek() throws {
        let path = try makeStaleDatabase()
        defer { removeDatabase(path) }
        #expect(try plan(path).hasPrefix("SCAN AuditLog"))

        #expect(PlannerStatistics.refresh(dbPath: path, busyTimeoutMs: 2_000) == .refreshed)

        #expect(try plan(path).hasPrefix("SEARCH AuditLog USING INTEGER PRIMARY KEY"))
        #expect(try auditLogStat(path) == "20000 1")
    }

    /// A second refresh on fresh statistics must leave them exactly as they were.
    @Test(.enabled(if: supportsAllTablesOptimize))
    func refreshIsIdempotent() throws {
        let path = try makeStaleDatabase()
        defer { removeDatabase(path) }
        try #require(PlannerStatistics.refresh(dbPath: path, busyTimeoutMs: 2_000) == .refreshed)
        let afterFirst = try auditLogStat(path)

        #expect(PlannerStatistics.refresh(dbPath: path, busyTimeoutMs: 2_000) == .refreshed)

        #expect(try auditLogStat(path) == afterFirst)
        #expect(try plan(path).hasPrefix("SEARCH AuditLog USING INTEGER PRIMARY KEY"))
    }

    @Test func missingDatabase_isNotCreated() {
        let path = temporaryDatabasePath()
        #expect(PlannerStatistics.refresh(dbPath: path, busyTimeoutMs: 100) == .skippedMissingFile)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    /// Below SQLite 3.46 the optimize bit is ignored and nothing would be
    /// analyzed; the refresh must say so and leave the database untouched.
    @Test func olderSQLite_isReportedUnsupported_andChangesNothing() throws {
        let path = try makeStaleDatabase()
        defer { removeDatabase(path) }

        let outcome = PlannerStatistics.refresh(dbPath: path, busyTimeoutMs: 2_000,
                                                minimumVersion: Int32.max)

        guard case .unsupportedSQLite(let version) = outcome else {
            Issue.record("expected unsupportedSQLite, got \(outcome)")
            return
        }
        #expect(version == String(cString: sqlite3_libversion()))
        #expect(try auditLogStat(path) == "1 1")
    }

    /// Another process holding the writer lock must cost at most the busy
    /// timeout, never an error that stops the server from starting.
    @Test func heldWriterLock_waitsThenFailsBusy() throws {
        let path = try makeStaleDatabase()
        defer { removeDatabase(path) }
        var holder: OpaquePointer?
        defer { sqlite3_close_v2(holder) }
        try #require(sqlite3_open_v2(path, &holder, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        try #require(sqlite3_exec(holder, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)

        let started = Date()
        let outcome = PlannerStatistics.refresh(dbPath: path, busyTimeoutMs: 200,
                                                minimumVersion: 0)
        let waited = Date().timeIntervalSince(started)
        guard case .failed(let code, _) = outcome else {
            Issue.record("expected failed(SQLITE_BUSY), got \(outcome)")
            return
        }
        #expect(code == SQLITE_BUSY)
        // BEGIN IMMEDIATE consults the busy handler; a bare optimize's
        // read-to-write upgrade would have failed at once (0 ms).
        #expect(waited >= 0.15)
        #expect(waited < 5)

        sqlite3_exec(holder, "ROLLBACK", nil, nil, nil)
    }

    /// The live hub always has readers mid-scan (other servers, hooks). A WAL
    /// reader holding a snapshot must not stop the repair.
    @Test(.enabled(if: supportsAllTablesOptimize))
    func openReader_doesNotBlockRefresh() throws {
        let path = try makeStaleDatabase()
        defer { removeDatabase(path) }
        var reader: OpaquePointer?
        defer { sqlite3_close_v2(reader) }
        try #require(sqlite3_open_v2(path, &reader, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        try #require(sqlite3_exec(reader, "BEGIN; SELECT count(*) FROM AuditLog;", nil, nil, nil) == SQLITE_OK)

        #expect(PlannerStatistics.refresh(dbPath: path, busyTimeoutMs: 2_000) == .refreshed)
        #expect(try plan(path).hasPrefix("SEARCH AuditLog USING INTEGER PRIMARY KEY"))

        sqlite3_exec(reader, "COMMIT", nil, nil, nil)
    }
}
