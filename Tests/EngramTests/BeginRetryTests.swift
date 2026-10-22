@testable import EngramKit
import EngramMemoryCore
import EngramModels
import Foundation
import Lattice
import MCP
import Testing

/// Bounded BEGIN retry for the write tools (2026-10-21 "database was busy
/// before the write transaction started" incident). A second raw SQLite
/// connection plays the other session that holds the hub's write lock.
@Suite("BeginRetry", .serialized)
struct BeginRetryTests {

    private struct FixtureEmbedder: Embedder {
        var dimension: Int { 384 }
        func embed(text: String) async throws -> [Float]? {
            var values = [Float](repeating: 0, count: 384)
            values[0] = 1
            return values
        }
    }

    private struct Fixture {
        let directory: URL
        let path: URL
        let lattice: Lattice
        let tools: MemoryTools

        func close() {
            lattice.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// The actor's independent handle is opened and its FIRST vector query
    /// runs here, BEFORE any test takes the write lock. Observed while
    /// writing these tests: the first `nearest()` on a fresh handle against a
    /// locked file waits the busy timeout and records a sealed query error,
    /// which `rememberNeighbors` (correctly) fails closed on with
    /// `storageUnavailable`. That is a different failure from the one under
    /// test (BEGIN contention), so the fixture mirrors a server that has
    /// already answered one recall — the normal state of a live MCP server.
    private func fixture(busyTimeoutMs: Int) async throws -> Fixture {
        let directory = try testFixtureDirectory()
            .appendingPathComponent("begin-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("memory.sqlite")
        let lattice = try Lattice(
            Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self,
            configuration: .init(fileURL: path, busyTimeoutMs: busyTimeoutMs))
        let tools = MemoryTools(localRef: lattice.sendableReference, syncedRef: nil,
                                embedder: FixtureEmbedder(),
                                identity: StaticIdentityProvider(.anonymous))
        try await tools.prepareStorage()
        _ = try await tools.handle(CallTool.Parameters(name: "recall", arguments: [
            "query": .string("warm the vector query path"), "project": .string("BeginRetry"),
        ]))
        return Fixture(directory: directory, path: path, lattice: lattice, tools: tools)
    }

    private func receipt(_ result: CallTool.Result) throws -> [String: Value] {
        guard case .object(let outer) = try #require(result.structuredContent),
              case .object(let receipt) = outer["engram_write_receipt"] else {
            Issue.record("Missing engram_write_receipt")
            return [:]
        }
        return receipt
    }

    // MARK: - Helper semantics

    @Test func contentionClassificationIsExact() {
        #expect(LatticeBeginRetry.isBeginContention(
            LatticeError.transactionError("Failed to begin transaction: database is locked")))
        #expect(LatticeBeginRetry.isBeginContention(
            LatticeError.transactionError("Failed to begin transaction: database is busy")))
        #expect(LatticeBeginRetry.isBeginContention(
            LatticeError.transactionError("Failed to begin transaction: database table is locked")))
        #expect(LatticeBeginRetry.isBeginContention(
            LatticeError.transactionError("Failed to begin transaction: database schema is locked")))
        // Later-phase failures and foreign errors never qualify.
        #expect(!LatticeBeginRetry.isBeginContention(
            LatticeError.transactionError("Failed to commit transaction: database is locked")))
        #expect(!LatticeBeginRetry.isBeginContention(
            LatticeError.transactionError("Nested checked transactions are not supported")))
        #expect(!LatticeBeginRetry.isBeginContention(LatticeError.addFailed("database is locked")))
        #expect(!LatticeBeginRetry.isBeginContention(MCPError.internalError("database is locked")))
    }

    @Test func heldLockExhaustsTheDefaultThreeAttemptsWithoutEnteringTheBody() async throws {
        let f = try await fixture(busyTimeoutMs: 100)
        defer { f.close() }
        let holder = try RawWriteLock(path: f.path.path)
        defer { holder.close() }
        try holder.acquire()

        var bodyEntered = 0
        var logged: [String] = []
        var sleeps: [TimeInterval] = []
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try LatticeBeginRetry.run(on: f.lattice, jitter: false,
                                          sleep: { sleeps.append($0) },
                                          log: { logged.append($0) }) {
                bodyEntered += 1
                try f.lattice.add(Memory(content: "never", project: "BeginRetry"))
            }
            Issue.record("expected contention")
        } catch let contention as LatticeBeginRetry.Contention {
            #expect(contention.attempts == 3)
            #expect(contention.detail == "database is locked")
            #expect(contention.totalWaitSeconds >= 0.3)
            #expect(contention.totalWaitSeconds <= LatticeBeginRetry.defaultTotalCapSeconds)
        }
        let wall = ProcessInfo.processInfo.systemUptime - started
        #expect(bodyEntered == 0)
        #expect(sleeps == [0.1, 0.3], "backoff schedule between the three attempts")
        #expect(logged.count == 2, "one log line per retried attempt")
        #expect(wall < LatticeBeginRetry.defaultTotalCapSeconds)
        holder.release()
        #expect(f.lattice.count(Memory.self) == 0)
    }

    @Test func capRefusesAnAttemptWhoseBusyWaitCannotFit() async throws {
        let f = try await fixture(busyTimeoutMs: 100)
        defer { f.close() }
        let holder = try RawWriteLock(path: f.path.path)
        defer { holder.close() }
        try holder.acquire()

        var sleeps: [TimeInterval] = []
        do {
            // elapsed (≥0.1) + backoff 0.1 + timeout 0.1 > cap 0.25 → no second attempt.
            _ = try LatticeBeginRetry.run(on: f.lattice, totalCapSeconds: 0.25, jitter: false,
                                          sleep: { sleeps.append($0) }) {
                try f.lattice.add(Memory(content: "never", project: "BeginRetry"))
            }
            Issue.record("expected contention")
        } catch let contention as LatticeBeginRetry.Contention {
            #expect(contention.attempts == 1)
        }
        #expect(sleeps.isEmpty)
        holder.release()
    }

    @Test func bodyFailureIsNeverRetried() async throws {
        let f = try await fixture(busyTimeoutMs: 100)
        defer { f.close() }
        struct BodyFailure: Error {}
        var bodyEntered = 0
        var sleeps: [TimeInterval] = []
        #expect(throws: BodyFailure.self) {
            try LatticeBeginRetry.run(on: f.lattice, sleep: { sleeps.append($0) }) {
                bodyEntered += 1
                try f.lattice.add(Memory(content: "rolled back", project: "BeginRetry"))
                throw BodyFailure()
            }
        }
        #expect(bodyEntered == 1)
        #expect(sleeps.isEmpty)
        #expect(f.lattice.count(Memory.self) == 0, "the checked transaction rolled the add back")
    }

    @Test func releasedLockLetsALaterAttemptSucceed() async throws {
        let f = try await fixture(busyTimeoutMs: 1_000)
        defer { f.close() }
        let holder = try RawWriteLock(path: f.path.path)
        defer { holder.close() }
        try holder.hold(for: 1.5)

        let success = try LatticeBeginRetry.run(on: f.lattice, jitter: false) {
            try f.lattice.add(Memory(content: "landed on a retry", project: "BeginRetry"))
            return true
        }
        #expect(success.value)
        // Attempt 1 spends its full 1 s budget; attempt 2 begins at ~1.1 s and
        // is admitted when the holder lets go at 1.5 s. Under heavy machine
        // load the holder's release can slip past attempt 2, so 3 is tolerated.
        #expect((2...3).contains(success.attempts), "attempts: \(success.attempts)")
        #expect(success.totalWaitSeconds >= 1.0)
        #expect(f.lattice.count(Memory.self) == 1)
    }

    // MARK: - remember / update end to end

    @Test func rememberSucceedsAfterTheLockIsReleased() async throws {
        let f = try await fixture(busyTimeoutMs: 1_000)
        defer { f.close() }
        let holder = try RawWriteLock(path: f.path.path)
        defer { holder.close() }
        try holder.hold(for: 1.5)

        let result = try await f.tools.handle(CallTool.Parameters(name: "remember", arguments: [
            "content": .string("Retry fixture: stored once the other writer let go"),
            "project": .string("BeginRetry"),
        ]))
        #expect(result.isError == false, "\(text(from: result))")
        #expect(text(from: result).hasPrefix("Stored memory"))
        #expect(f.lattice.count(Memory.self) == 1)
    }

    @Test func rememberReturnsTheNotStoredReceiptWhenTheLockOutlastsTheRetries() async throws {
        let f = try await fixture(busyTimeoutMs: 200)
        defer { f.close() }
        let holder = try RawWriteLock(path: f.path.path)
        defer { holder.close() }
        try holder.acquire()   // held for the whole call (a 10 s holder, in effect)

        let started = ProcessInfo.processInfo.systemUptime
        let result = try await f.tools.handle(CallTool.Parameters(name: "remember", arguments: [
            "content": .string("Retry fixture: must not be stored"),
            "project": .string("BeginRetry"),
        ]))
        let wall = ProcessInfo.processInfo.systemUptime - started

        #expect(result.isError == true)
        // Frozen contract (see MemoryTools.busyReceipt): the Codex learner proxy
        // verifies this text and these five keys byte for byte.
        #expect(text(from: result) == "Memory was not stored: the database was busy before the write transaction started. Retry on a later turn.")
        let r = try receipt(result)
        #expect(Set(r.keys) == ["schema_version", "tool", "write_outcome", "reason", "memory_ids"])
        #expect(r["schema_version"] == .int(1))
        #expect(r["tool"] == .string("remember"))
        #expect(r["write_outcome"] == .string("not_stored_transaction_not_started"))
        #expect(r["reason"] == .string("database_busy"))
        #expect(r["memory_ids"] == .array([]))
        // Three 200 ms busy waits plus 100 + 300 ms of backoff, well under the cap.
        #expect(wall >= 0.6, "wall \(wall) s")
        #expect(wall <= LatticeBeginRetry.defaultTotalCapSeconds + 1.0)
        // The body never ran: no row through the still-held writer's view either.
        #expect(try holder.integer("SELECT COUNT(*) FROM Memory") == 0)
        holder.release()
        #expect(f.lattice.count(Memory.self) == 0)
    }

    @Test func updateReturnsTheFrozenNotStoredReceipt() async throws {
        let f = try await fixture(busyTimeoutMs: 100)
        defer { f.close() }
        let stored = try await f.tools.handle(CallTool.Parameters(name: "remember", arguments: [
            "content": .string("Retry fixture: original"), "project": .string("BeginRetry"),
        ]))
        let id = try #require(extractMemoryId(from: text(from: stored)))

        let holder = try RawWriteLock(path: f.path.path)
        defer { holder.close() }
        try holder.acquire()
        let result = try await f.tools.handle(CallTool.Parameters(name: "update", arguments: [
            "id": .string(id), "content": .string("Retry fixture: edited"),
        ]))
        #expect(result.isError == true)
        #expect(text(from: result) == "Memory was not updated: the database was busy before the write transaction started. Retry on a later turn.")
        let r = try receipt(result)
        #expect(Set(r.keys) == ["schema_version", "tool", "write_outcome", "reason", "memory_ids"])
        #expect(r["tool"] == .string("update"))
        #expect(r["write_outcome"] == .string("not_stored_transaction_not_started"))
        holder.release()
        let after = try await f.tools.handle(CallTool.Parameters(name: "recall", arguments: [
            "query": .string("Retry fixture"), "project": .string("BeginRetry"),
        ]))
        #expect(text(from: after).contains("Retry fixture: original"))
        #expect(!text(from: after).contains("Retry fixture: edited"))
    }

    @Test func connectReturnsTheNotStoredReceiptUnderContention() async throws {
        let f = try await fixture(busyTimeoutMs: 100)
        defer { f.close() }
        let a = try await f.tools.handle(CallTool.Parameters(name: "remember", arguments: [
            "content": .string("Retry fixture: node A"), "project": .string("BeginRetry"), "force": .bool(true),
        ]))
        let b = try await f.tools.handle(CallTool.Parameters(name: "remember", arguments: [
            "content": .string("Retry fixture: node B"), "project": .string("BeginRetry"), "force": .bool(true),
        ]))
        let idA = try #require(extractMemoryId(from: text(from: a)))
        let idB = try #require(extractMemoryId(from: text(from: b)))
        let edgesBefore = f.lattice.count(Edge.self)

        let holder = try RawWriteLock(path: f.path.path)
        defer { holder.close() }
        try holder.acquire()
        let result = try await f.tools.handle(CallTool.Parameters(name: "connect", arguments: [
            "from": .string(idA), "to": .string(idB), "relation": .string("relates_to"),
        ]))
        #expect(result.isError == true)
        let r = try receipt(result)
        #expect(r["tool"] == .string("connect"))
        #expect(r["write_outcome"] == .string("not_stored_transaction_not_started"))
        holder.release()
        #expect(f.lattice.count(Edge.self) == edgesBefore)

        // And the same call lands once the lock is gone.
        let retry = try await f.tools.handle(CallTool.Parameters(name: "connect", arguments: [
            "from": .string(idA), "to": .string(idB), "relation": .string("relates_to"),
        ]))
        #expect(retry.isError == false, "\(text(from: retry))")
        #expect(f.lattice.count(Edge.self) == edgesBefore + 1)
    }
}
