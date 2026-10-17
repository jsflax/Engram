@testable import EngramKit
import Darwin
import EngramModels
import Foundation
import Lattice
import SQLite3
import Testing

/// Run in its own serial process, after the unchanged ledger timing gate.
/// These independent stores do not prime that gate or exercise its retry loop.
@Suite("BEGIN contention diagnostics", .serialized)
struct BeginContentionDiagnosticsTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENGRAM_BEGIN_DIAGNOSTICS"] == "1"))
    func beginContentionTimingDiagnostics() throws {
        try measureRawSQLiteBegin()
        try measureCheckedLatticeBegin()
    }

    private func measureRawSQLiteBegin() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let reader = try SQL(fixture.path)
        defer { reader.close() }
        let writer = try SQL(fixture.path)
        defer { writer.close() }
        try #require(try reader.integer("PRAGMA busy_timeout") == 100)
        try writer.execute("BEGIN IMMEDIATE")
        defer { try? writer.execute("ROLLBACK") }
        try #require(writer.isInTransaction && !reader.isInTransaction)

        // CString conversion and result formatting are outside the interval.
        let sample = "BEGIN IMMEDIATE".withCString { statement in
            let started = ClockSample.read()
            let code = sqlite3_exec(reader.handle, statement, nil, nil, nil)
            let ended = ClockSample.read()
            return (started: started, ended: ended, code: code)
        }
        let extendedCode = sqlite3_extended_errcode(reader.handle)
        let delta = sample.ended.delta(since: sample.started)
        print("[BEGIN diagnostic raw] sqlite_version=\(sqlite3_libversion_number()) timeout_ms=100 rc=\(sample.code) extended_rc=\(extendedCode) wall_s=\(delta.wall) thread_cpu_s=\(delta.cpu)")

        #expect(sample.started.valid && sample.ended.valid)
        #expect(delta.wall >= 0 && delta.cpu >= 0)
        #expect(sample.code == SQLITE_BUSY)
        #expect(!reader.isInTransaction)
        #expect(writer.isInTransaction)
        #expect(try reader.integer("PRAGMA busy_timeout") == 100)
        try expectUnchangedRows(writer)
    }

    private func measureCheckedLatticeBegin() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let writer = try SQL(fixture.path)
        defer { writer.close() }
        try #require(fixture.lattice.configuration.busyTimeoutMs == 100)
        try writer.execute("BEGIN IMMEDIATE")
        defer { try? writer.execute("ROLLBACK") }
        try #require(writer.isInTransaction)
        let callback = CallbackTrace()
        fixture.lattice.onQueryError { callback.observe($0) }
        defer { fixture.lattice.onQueryError { _ in } }
        var bodyEntered = false
        var failure: (any Error)?

        let started = ClockSample.read()
        do {
            try fixture.lattice.withTransaction { bodyEntered = true }
        } catch {
            failure = error
        }
        let ended = ClockSample.read()

        let observed = callback.snapshot()
        let total = ended.delta(since: started)
        let toCallback = observed.first?.delta(since: started)
        let afterCallback = observed.first.map { ended.delta(since: $0) }
        var expectedFailure = false
        if let error = failure as? LatticeError,
           case .transactionError(let message) = error {
            expectedFailure = message == Self.expectedContention
        }
        // -1 explicitly means no callback sample; assertions below reject it.
        print("[BEGIN diagnostic checked] timeout_ms=100 expected_error=\(expectedFailure ? 1 : 0) callbacks=\(observed.count) wall_s=\(total.wall) thread_cpu_s=\(total.cpu) callback_wall_s=\(toCallback?.wall ?? -1) callback_thread_cpu_s=\(toCallback?.cpu ?? -1) after_callback_wall_s=\(afterCallback?.wall ?? -1) after_callback_thread_cpu_s=\(afterCallback?.cpu ?? -1)")

        #expect(started.valid && ended.valid && observed.first?.valid == true)
        #expect(total.wall >= 0 && total.cpu >= 0)
        #expect(expectedFailure)
        #expect(observed.count == 1 && observed.onlyExpectedContention)
        #expect(!bodyEntered)
        #expect(writer.isInTransaction)
        try expectUnchangedRows(writer)
    }

    private func expectUnchangedRows(_ sql: SQL) throws {
        #expect(try sql.integer("SELECT COUNT(*) FROM Memory") == 0)
        #expect(try sql.integer("SELECT COUNT(*) FROM EngramOperationReceiptV1") == 0)
        #expect(try sql.integer("SELECT COUNT(*) FROM EngramOperationStoreV1") == 1)
    }

    private static let expectedContention = "Failed to begin transaction: database is locked"

    private struct ClockSample {
        let wall: Double
        let cpu: Double
        let valid: Bool

        static func read() -> Self {
            var wall = timespec()
            var cpu = timespec()
            let wallStatus = clock_gettime(CLOCK_MONOTONIC, &wall)
            let cpuStatus = clock_gettime(CLOCK_THREAD_CPUTIME_ID, &cpu)
            return Self(wall: Double(wall.tv_sec) + Double(wall.tv_nsec) / 1_000_000_000,
                        cpu: Double(cpu.tv_sec) + Double(cpu.tv_nsec) / 1_000_000_000,
                        valid: wallStatus == 0 && cpuStatus == 0)
        }

        func delta(since start: Self) -> (wall: Double, cpu: Double) {
            (wall - start.wall, cpu - start.cpu)
        }
    }

    /// Lattice documents this callback as synchronous on the querying thread.
    /// Capture one fixed-size sample before locking; never print in the callback.
    private final class CallbackTrace: @unchecked Sendable {
        struct Snapshot {
            let count: Int
            let first: ClockSample?
            let onlyExpectedContention: Bool
        }
        private let lock = NSLock()
        private var count = 0
        private var first: ClockSample?
        private var onlyExpectedContention = true

        func observe(_ message: String) {
            let sample = ClockSample.read()
            lock.withLock {
                count += 1
                if first == nil { first = sample }
                onlyExpectedContention = onlyExpectedContention
                    && message == BeginContentionDiagnosticsTests.expectedContention
            }
        }

        func snapshot() -> Snapshot {
            lock.withLock {
                Snapshot(count: count, first: first, onlyExpectedContention: onlyExpectedContention)
            }
        }
    }

    private struct Fixture {
        let directory: URL
        let path: URL
        let lattice: Lattice

        init() throws {
            let root = try #require(ProcessInfo.processInfo.environment["ENGRAM_ADOPTION_TEST_ROOT"],
                                    "The diagnostic requires an explicit disposable fixture root")
            directory = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent("begin-contention-diagnostic-\(UUID().uuidString)", isDirectory: true)
            path = directory.appendingPathComponent("memory.sqlite")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                try MemoryOperationLedger.preflightLocalStore(at: path)
                let opened = try Lattice(for: [Memory.self] + MemoryOperationLedger.localModels,
                                         configuration: .init(fileURL: path, busyTimeoutMs: 100))
                do { try MemoryOperationLedger(lattice: opened).bootstrapStoreID() }
                catch { opened.close(); throw error }
                lattice = opened
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }

        func close() {
            lattice.close()
            do { try FileManager.default.removeItem(at: directory) }
            catch { Issue.record("Failed to remove disposable BEGIN diagnostic fixture: \(error)") }
        }
    }

    private final class SQL {
        let handle: OpaquePointer
        private var closed = false

        init(_ path: URL) throws {
            var pointer: OpaquePointer?
            let code = sqlite3_open_v2(path.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
            guard code == SQLITE_OK, let pointer else {
                if let pointer { sqlite3_close(pointer) }
                throw DiagnosticError.sqlite(code)
            }
            handle = pointer
            let configured = sqlite3_busy_timeout(handle, 100)
            guard configured == SQLITE_OK else {
                close()
                throw DiagnosticError.sqlite(configured)
            }
        }

        deinit { close() }
        func close() {
            if !closed { sqlite3_close(handle); closed = true }
        }
        var isInTransaction: Bool { sqlite3_get_autocommit(handle) == 0 }

        func execute(_ sql: String) throws {
            let code = sqlite3_exec(handle, sql, nil, nil, nil)
            guard code == SQLITE_OK else { throw DiagnosticError.sqlite(code) }
        }

        func integer(_ sql: String) throws -> Int {
            var statement: OpaquePointer?
            let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
            guard prepared == SQLITE_OK, let statement else { throw DiagnosticError.sqlite(prepared) }
            defer { sqlite3_finalize(statement) }
            let stepped = sqlite3_step(statement)
            guard stepped == SQLITE_ROW else { throw DiagnosticError.sqlite(stepped) }
            let value = sqlite3_column_int64(statement, 0)
            let finished = sqlite3_step(statement)
            guard finished == SQLITE_DONE else { throw DiagnosticError.sqlite(finished) }
            return Int(value)
        }
    }

    private enum DiagnosticError: Error { case sqlite(Int32) }
}
