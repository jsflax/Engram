import EngramLattice
import EngramModels
import EngramTestSupport
import Foundation
import Lattice
import Testing
#if canImport(SQLite3)
import SQLite3
#else
import CEngramLedgerSQLite
#endif

@Suite("Interactive write contention admission")
struct InteractiveBusyBudgetTests {
    @Test(arguments: [2_000, 100])
    func defaultBudgetLeavesRoomForABusyResponse(timeoutMs: Int) throws {
        let directory = try EngramTestFixtureRoot.directory()
            .appending(path: "interactive-busy-budget-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "memory.sqlite")
        let lattice = try Lattice(Memory.self, configuration: .init(fileURL: file, busyTimeoutMs: timeoutMs))
        defer { lattice.close() }
        let blocker = try InteractiveBudgetWriterLock(file: file)
        defer { blocker.close() }
        try blocker.acquire()

        let clock = InteractiveBudgetClock(attemptSeconds: Double(timeoutMs) / 1_000)
        lattice.onQueryError { clock.observe($0) }
        defer { lattice.onQueryError { _ in } }
        var bodyEntries = 0
        let contention: LatticeBeginRetry.Contention
        do {
            // Keep the production cap, attempt bound, and backoff schedule.
            // Real failed BEGINs advance logical time by their configured wait;
            // scheduling delays are deliberately not part of this policy oracle.
            _ = try LatticeBeginRetry.run(on: lattice, jitter: false,
                sleep: { clock.sleep($0) }, now: { clock.now() }) {
                bodyEntries += 1
                try lattice.add(Memory(content: "A held writer must prevent this row"))
            }
            Issue.record("Expected BEGIN contention while the independent writer remains held")
            return
        } catch let failure as LatticeBeginRetry.Contention {
            contention = failure
        }

        let observed = clock.snapshot()
        let expectedAttempts = timeoutMs == 2_000 ? 2 : 3
        let expectedSleeps: [TimeInterval] = timeoutMs == 2_000 ? [0.1] : [0.1, 0.3]
        let expectedElapsed = timeoutMs == 2_000 ? 4.1 : 0.7
        #expect(contention.attempts == expectedAttempts)
        #expect(contention.detail == "database is locked")
        #expect(observed.failures == expectedAttempts)
        #expect(observed.unexpectedErrors.isEmpty)
        #expect(observed.sleeps == expectedSleeps)
        // Tolerance is only for floating-point addition, never wall-clock time.
        #expect(abs(contention.totalWaitSeconds - expectedElapsed) < 0.000_001)
        #expect(abs(observed.elapsed - expectedElapsed) < 0.000_001)
        #expect(bodyEntries == 0)
        #expect(blocker.isHeld)
        let rowsWhileHeld = try blocker.memoryCount()
        #expect(rowsWhileHeld == 0)
        #expect(lattice.configuration.busyTimeoutMs == timeoutMs)

        try blocker.release()
        var recoveryEntries = 0
        try lattice.withTransaction {
            recoveryEntries += 1
            try lattice.add(Memory(content: "The same connection writes after the lock is released"))
        }
        #expect(recoveryEntries == 1)
        let rowsAfterRelease = try blocker.memoryCount()
        #expect(rowsAfterRelease == 1)
        #expect(lattice.configuration.busyTimeoutMs == timeoutMs)
    }
}

/// The callback can be invoked through a Sendable library handler. Every read
/// and write of mutable timing/attempt state is protected by this one lock.
private final class InteractiveBudgetClock: @unchecked Sendable {
    struct Snapshot {
        let elapsed: Double
        let failures: Int
        let sleeps: [TimeInterval]
        let unexpectedErrors: [String]
    }

    private let lock = NSLock()
    private let attemptSeconds: Double
    private var elapsed = 0.0
    private var failures = 0
    private var sleeps: [TimeInterval] = []
    private var unexpectedErrors: [String] = []

    init(attemptSeconds: Double) { self.attemptSeconds = attemptSeconds }

    func observe(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        guard message == "Failed to begin transaction: database is locked" else {
            unexpectedErrors.append(message)
            return
        }
        failures += 1
        elapsed += attemptSeconds
    }

    func sleep(_ delay: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        sleeps.append(delay)
        elapsed += delay
    }

    func now() -> Double {
        lock.lock(); defer { lock.unlock() }
        return elapsed
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(elapsed: elapsed, failures: failures, sleeps: sleeps,
                        unexpectedErrors: unexpectedErrors)
    }
}

/// Holds a transaction without writing rows or registering any writer function.
/// Used synchronously on the test thread; statements are finalized before close.
private final class InteractiveBudgetWriterLock {
    private enum Failure: Error {
        case closed
        case sqlite(operation: String, code: Int32)
    }

    private var database: OpaquePointer?

    init(file: URL) throws {
        var opened: OpaquePointer?
        let code = sqlite3_open_v2(file.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw Failure.sqlite(operation: "open independent writer", code: code)
        }
        database = opened
    }

    deinit { close() }

    var isHeld: Bool {
        guard let database else { return false }
        return sqlite3_get_autocommit(database) == 0
    }

    func acquire() throws { try execute("BEGIN IMMEDIATE") }
    func release() throws { try execute("ROLLBACK") }

    func memoryCount() throws -> Int {
        guard let database else { throw Failure.closed }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM Memory", -1, &statement, nil)
        guard prepared == SQLITE_OK else {
            if let statement { sqlite3_finalize(statement) }
            throw Failure.sqlite(operation: "prepare memory count", code: prepared)
        }
        defer { sqlite3_finalize(statement) }
        let stepped = sqlite3_step(statement)
        guard stepped == SQLITE_ROW else {
            throw Failure.sqlite(operation: "read memory count", code: stepped)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func close() {
        guard let database else { return }
        if sqlite3_get_autocommit(database) == 0 {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
        }
        sqlite3_close(database)
        self.database = nil
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw Failure.closed }
        let code = sqlite3_exec(database, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw Failure.sqlite(operation: sql, code: code) }
    }
}
