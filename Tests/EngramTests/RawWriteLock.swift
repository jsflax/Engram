import Foundation
import SQLite3

/// A separate raw SQLite connection that holds the database's write lock
/// (`BEGIN IMMEDIATE` → RESERVED) so a Lattice handle's checked BEGIN fails
/// with SQLite's genuine contention error, exactly as another session's
/// writer would make it fail in production.
final class RawWriteLock: @unchecked Sendable {
    private let handle: OpaquePointer
    private let lock = NSLock()
    private var inTransaction = false
    private var closed = false

    enum Failure: Error { case sqlite(Int32, String) }

    init(path: String, busyTimeoutMs: Int32 = 100) throws {
        var pointer: OpaquePointer?
        let code = sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw Failure.sqlite(code, "open")
        }
        handle = pointer
        sqlite3_busy_timeout(handle, busyTimeoutMs)
    }

    deinit { close() }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        if inTransaction { _ = sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) }
        sqlite3_close(handle)
        closed = true
    }

    /// Take the write lock on the calling thread.
    func acquire() throws {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        inTransaction = true
    }

    /// Release it (rollback: nothing is ever written through this handle).
    func release() {
        lock.lock(); defer { lock.unlock() }
        guard inTransaction else { return }
        _ = sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
        inTransaction = false
    }

    /// Acquire now, release after `seconds` on a background thread. Returns
    /// once the lock is actually held.
    func hold(for seconds: TimeInterval) throws {
        try acquire()
        Thread.detachNewThread { [self] in
            Thread.sleep(forTimeInterval: seconds)
            self.release()
        }
    }

    func integer(_ sql: String) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw Failure.sqlite(prepared, sql) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw Failure.sqlite(SQLITE_ERROR, sql) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func execute(_ sql: String) throws {
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw Failure.sqlite(code, sql) }
    }
}
