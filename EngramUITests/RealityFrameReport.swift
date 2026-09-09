import Foundation
import XCTest
import EngramKit
import Lattice
import SQLite3

/// Parse by column name so profiling cannot silently pass against obsolete output.
struct RealityFrameReport {
    static let requiredColumns = [
        "frame", "dt_ms", "tick_ms", "lod_ms", "node_ms", "edge_ms", "label_ms",
        "commit_ms", "nebula_ms", "galaxy_titles_ms", "mascot_ms", "flow_ms",
        "lights_ms", "audio_ms", "total_ms", "nodes", "edges", "vis_edges",
        "near", "mid", "far",
    ]
    let columns: [String]
    let rows: [[String: Double]]

    init(path: String) throws {
        try self.init(csv: String(contentsOfFile: path, encoding: .utf8))
    }

    init(csv: String) throws {
        let lines = csv.split(separator: "\n").filter { !$0.hasPrefix("#") }
        guard let header = lines.first else { throw ParseError("Missing frame timing header") }
        let columns = try Self.parseColumns(header)
        self.columns = columns
        var rows: [[String: Double]] = []
        var previousFrame: Double?
        for line in lines.dropFirst() {
            let row = try Self.parseRow(line, columns: columns)
            let frame = row["frame"]!
            guard frame.rounded(.towardZero) == frame,
                  previousFrame.map({ frame > $0 }) ?? true else {
                throw ParseError("Frame IDs must be integers increasing within one run")
            }
            previousFrame = frame
            rows.append(row)
        }
        guard !rows.isEmpty else { throw ParseError("No rendered frame samples") }
        self.rows = rows
    }

    /// Live readiness inspects only the last complete row, keeping polling
    /// cheap. A concurrent flush may leave a valid-looking but incomplete tail.
    static func latestCompleteNodeCount(in csv: String) throws -> Int? {
        guard let newline = csv.lastIndex(of: "\n") else { return nil }
        let lines = csv[...newline].split(separator: "\n").filter { !$0.hasPrefix("#") }
        guard let header = lines.first else { return nil }
        let columns = try parseColumns(header)
        guard lines.count > 1, let last = lines.last else { return nil }
        let row = try parseRow(last, columns: columns)
        guard let count = row["nodes"], let integralCount = Int(exactly: count) else {
            throw ParseError("Node count must be an integer")
        }
        return integralCount
    }

    private static func parseColumns(_ header: Substring) throws -> [String] {
        let columns = header.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard Set(columns).count == columns.count, !columns.contains(""),
              Set(requiredColumns).isSubset(of: Set(columns)) else {
            throw ParseError("Frame timing requires unique column names and all 21 current columns")
        }
        return columns
    }

    private static func parseRow(_ line: Substring, columns: [String]) throws -> [String: Double] {
        let cells = line.split(separator: ",", omittingEmptySubsequences: false)
        guard cells.count == columns.count else { throw ParseError("Malformed frame timing row") }
        let values = try cells.map { cell in
            guard let value = Double(cell), value.isFinite && value >= 0 else {
                throw ParseError("Frame values must be finite, nonnegative numbers")
            }
            return value
        }
        let row = Dictionary(uniqueKeysWithValues: zip(columns, values))
        guard let frame = row["frame"], frame.rounded(.towardZero) == frame else {
            throw ParseError("Frame IDs must be integers")
        }
        return row
    }

    private struct ParseError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    func section(warmupFrames: Int = 120) throws -> BottleneckSection {
        let active = Array(rows.filter { $0["nodes", default: 0] > 0 && $0["dt_ms", default: 0] > 0 }
            .dropFirst(warmupFrames))
        XCTAssertGreaterThanOrEqual(active.count, 100, "Insufficient rendered frames after warmup")
        guard active.count >= 100 else { throw CocoaError(.fileReadCorruptFile) }
        var result = BottleneckSection(title: "REALITYKIT FRAME TIMING")
        result.addLine("Rendered samples: \(active.count)")
        for column in columns where column.hasSuffix("_ms") {
            let values = active.map { $0[column]! }.sorted()
            let p95 = percentile(values, 0.95)
            result.addLine("\(column): p50=\(fmt(percentile(values, 0.5))) p95=\(fmt(p95)) p99=\(fmt(percentile(values, 0.99))) max=\(fmt(values.last!))")
            if column == "dt_ms" { result.metalP95 = p95 }
        }
        return result
    }
}

final class RealityFrameReportParserTests: XCTestCase {
    func testCurrentSchemaAcceptsCommentsAndIncreasingFrames() throws {
        let report = try RealityFrameReport(csv: "# refresh_hz=60\n" + fixture(frames: [1, 3]))
        XCTAssertEqual(report.columns.count, 21)
        XCTAssertEqual(report.rows.map { $0["frame"]! }, [1, 3])
    }

    func testRejectsDuplicateAndMissingColumnNames() {
        let columns = RealityFrameReport.requiredColumns
        XCTAssertThrowsError(try RealityFrameReport(csv: fixture(columns: columns + ["frame"])))
        for missing in columns.indices {
            var incomplete = columns
            incomplete.remove(at: missing)
            XCTAssertThrowsError(try RealityFrameReport(csv: fixture(columns: incomplete)))
        }
    }

    func testRejectsRepeatedReversedAndFractionalFrameIDs() {
        for frames: [Double] in [[1, 1], [2, 1], [1, 1.5]] {
            XCTAssertThrowsError(try RealityFrameReport(csv: fixture(frames: frames)))
        }
    }

    func testReadinessWaitsForCompleteRowsAndRejectsObsoleteSchema() throws {
        let complete = fixture()
        XCTAssertNil(try RealityFrameReport.latestCompleteNodeCount(in: String(complete.dropLast())))
        XCTAssertEqual(try RealityFrameReport.latestCompleteNodeCount(in: complete), 1)
        XCTAssertEqual(try RealityFrameReport.latestCompleteNodeCount(in: complete + "2,16,0,0"), 1)
        XCTAssertThrowsError(try RealityFrameReport.latestCompleteNodeCount(in: "frame,nodes\n1,4000\n"))
        XCTAssertThrowsError(try RealityFrameReport.latestCompleteNodeCount(in: complete + "2,16,0,0\n"))
    }

    func testCopiedConfigurationNormalizationPreservesSourceAndMascots() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("engram-config-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.sqlite")
        let copy = directory.appendingPathComponent("copy.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &database), SQLITE_OK)
        let sql = """
            CREATE TABLE VisualizerConfig(selectedTab TEXT, layoutMode TEXT,
                hiddenProjects TEXT, hiddenRelations TEXT, soundEnabled INTEGER,
                notificationsEnabled INTEGER, showMascots INTEGER);
            INSERT INTO VisualizerConfig VALUES ('Account', 'Semantic', '["Hidden"]', '["part_of"]', 1, 1, 0);
            CREATE TABLE AuditLog(value INTEGER);
            CREATE TRIGGER config_audit AFTER UPDATE ON VisualizerConfig
                WHEN sync_disabled() = 0 BEGIN INSERT INTO AuditLog VALUES (1); END;
            """
        let created = sqlite3_exec(database, sql, nil, nil, nil)
        sqlite3_close(database)
        XCTAssertEqual(created, SQLITE_OK)
        let original = try Data(contentsOf: source)
        try FileManager.default.copyItem(at: source, to: copy)
        try normalizeCopiedVisualizerConfiguration(at: copy.path)
        XCTAssertEqual(try Data(contentsOf: source), original)

        database = nil
        XCTAssertEqual(sqlite3_open_v2(copy.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let query = """
            SELECT selectedTab || '|' || layoutMode || '|' || hiddenProjects || '|' || hiddenRelations || '|' ||
                soundEnabled || '|' || notificationsEnabled || '|' || showMascots || '|' ||
                (SELECT count(*) FROM AuditLog) FROM VisualizerConfig
            """
        XCTAssertEqual(sqlite3_prepare_v2(database, query, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let value = try XCTUnwrap(sqlite3_column_text(statement, 0))
        XCTAssertEqual(String(cString: value), "Graph|Force|[]|[]|0|0|0|0")
    }

    private func fixture(columns: [String] = RealityFrameReport.requiredColumns,
                         frames: [Double] = [1]) -> String {
        let rows = frames.map { frame in
            columns.map { $0 == "frame" ? String(frame) : "1" }.joined(separator: ",")
        }
        return ([columns.joined(separator: ",")] + rows).joined(separator: "\n") + "\n"
    }
}

/// The source is opened read-only; every app launch and mutation uses its own backup.
func makePerformanceDatabaseCopy(source: String, directory: URL) throws -> String {
    let target = directory.appendingPathComponent("memory.sqlite").path
    let backup = Process()
    backup.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    backup.arguments = ["-readonly", source, ".backup '\(target.replacingOccurrences(of: "'", with: "''"))'"]
    try backup.run()
    backup.waitUntilExit()
    XCTAssertEqual(backup.terminationStatus, 0, "SQLite backup failed")
    guard backup.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
    try normalizeCopiedVisualizerConfiguration(at: target)
    // Isolated tests have no synced/group galaxies. Keep every copied row in
    // the personal graph; source sync settings and database stay untouched.
    let fixture = try Lattice(Memory.self, Edge.self, SyncConfig.self,
                              configuration: .init(fileURL: URL(fileURLWithPath: target),
                                                   migration: engramMigrations))
    try fixture.transaction {
        for config in fixture.objects(SyncConfig.self).materializedSnapshot() {
            config.policy = .local
            config.exposedGroups = []
        }
    }
    return target
}

/// Only called with the newly created backup, never the source database.
/// Preserve mascot settings while matching the standalone loading workload.
private func normalizeCopiedVisualizerConfiguration(at path: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
        if let database { sqlite3_close(database) }
        throw CocoaError(.fileWriteUnknown)
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database,
                            "SELECT 1 FROM sqlite_schema WHERE type='table' AND name='VisualizerConfig'",
                            -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
    defer { sqlite3_finalize(statement) }
    let exists = sqlite3_step(statement)
    if exists == SQLITE_DONE { return } // App creates defaults for a CLI-only database.
    guard exists == SQLITE_ROW,
          sqlite3_create_function_v2(database, "sync_disabled", 0, SQLITE_UTF8, nil,
                                     { context, _, _ in sqlite3_result_int(context, 1) },
                                     nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    // Avoid synthetic sync audit events from harness-only configuration edits.
    let sql = """
        UPDATE VisualizerConfig SET selectedTab = 'Graph', layoutMode = 'Force',
            hiddenProjects = '[]', hiddenRelations = '[]',
            soundEnabled = 0, notificationsEnabled = 0
        """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
}
