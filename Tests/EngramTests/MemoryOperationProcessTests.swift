@testable import EngramKit
import Darwin
import EngramMemoryCore
import EngramModels
import Foundation
import Lattice
import SQLite3
import Testing

/// Subprocesses use only synthetic fixture stores. SIGKILL tests the SQLite
/// commit boundary without adding fault-injection hooks to production code.
@Suite("Operation ledger process boundaries", .serialized)
struct MemoryOperationProcessTests {
    private enum Failure: Error { case timeout, childFailed, invalidFixture, sql }
    private struct Fixture {
        let directory: URL
        let request: MemoryOperationRequest
        var database: URL { directory.appendingPathComponent("memory.sqlite") }
    }
    private struct Result: Codable {
        let receipt: MemoryOperationReceipt
        let isReplay: Bool?
    }
    private actor Embed: Embedder {
        nonisolated let dimension = 384
        func embed(text: String) async throws -> [Float]? {
            [1] + [Float](repeating: 0, count: dimension - 1)
        }
    }

    private func fixture(append: Bool = false) throws -> Fixture {
        let root = try #require(ProcessInfo.processInfo.environment["ENGRAM_ADOPTION_TEST_ROOT"])
        let directory = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("operation-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let database = directory.appendingPathComponent("memory.sqlite")
        try MemoryOperationLedger.preflightLocalStore(at: database)
        let db = try Lattice(for: [Memory.self, Edge.self, SyncConfig.self] + MemoryOperationLedger.localModels,
                             configuration: .init(fileURL: database, busyTimeoutMs: 2_000))
        defer { db.close() }
        let ledger = MemoryOperationLedger(lattice: db)
        try ledger.bootstrapStoreID()
        let mutation: MemoryMutation
        if append {
            let memory = Memory(content: "original", topic: "episode", project: "ProcessFixture")
            try db.add(memory)
            mutation = .update(UpdateRequest(id: try #require(memory.globalId), append: "once"))
        } else {
            mutation = .remember(RememberRequest(content: "synthetic process memory", topic: "episode",
                                                project: "ProcessFixture"))
        }
        let request = try MemoryOperationRequest(operationID: UUID(), expectedScope: ledger.scope(principal: .anonymous),
            provenance: MemoryOperationProvenance(host: "fixture", sessionID: "process-session", runID: "process-run",
                source: MemoryOperationSourceInterval(startOffset: 1, endOffset: 2,
                    excerptDigest: MemoryOperationDigest(sha256: String(repeating: "a", count: 64)))),
            mutation: mutation)
        try JSONEncoder().encode(request).write(to: directory.appendingPathComponent("request.json"))
        return Fixture(directory: directory, request: request)
    }

    private func child(_ fixture: Fixture, mode: String, name: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        var arguments: [String] = []
        // On macOS SwiftPM launches a helper that dlopens the test bundle.
        // Re-executing that helper without its bundle argument exits without
        // running tests. Preserve only the bootstrap argument, then select the
        // fixture explicitly so the child never recursively runs this suite.
        if let bundleFlag = CommandLine.arguments.firstIndex(of: "--test-bundle-path") {
            guard CommandLine.arguments.indices.contains(bundleFlag + 1) else { throw Failure.invalidFixture }
            arguments += ["--test-bundle-path", CommandLine.arguments[bundleFlag + 1]]
        } else if process.executableURL?.lastPathComponent == "swiftpm-testing-helper" {
            throw Failure.invalidFixture
        }
        arguments += ["--testing-library", "swift-testing", "--filter",
                      "MemoryOperationProcessTests/fixtureProcess"]
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["ENGRAM_OPERATION_PROCESS_DIRECTORY"] = fixture.directory.path
        environment["ENGRAM_OPERATION_PROCESS_MODE"] = mode
        environment["ENGRAM_OPERATION_PROCESS_NAME"] = name
        process.environment = environment
        let log = fixture.directory.appendingPathComponent("\(name).log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else { throw Failure.invalidFixture }
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        try handle.close()
        return process
    }

    private func waitFor(_ file: URL, process: Process? = nil) throws {
        let end = ProcessInfo.processInfo.systemUptime + 20
        while !FileManager.default.fileExists(atPath: file.path) {
            if let process, !process.isRunning { throw Failure.childFailed }
            guard ProcessInfo.processInfo.systemUptime < end else { throw Failure.timeout }
            usleep(10_000)
        }
    }

    private func finish(_ process: Process) throws {
        let end = ProcessInfo.processInfo.systemUptime + 20
        while process.isRunning {
            guard ProcessInfo.processInfo.systemUptime < end else {
                _ = kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                throw Failure.timeout
            }
            usleep(10_000)
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw Failure.childFailed }
    }

    private func stop(_ process: Process) {
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    private func result(_ fixture: Fixture, _ name: String) throws -> Result {
        try JSONDecoder().decode(Result.self,
            from: Data(contentsOf: fixture.directory.appendingPathComponent("\(name).result.json")))
    }

    @Test(arguments: ["before-dispatch", "inside-transaction", "after-commit"])
    func killedWriterThenRestart(_ mode: String) throws {
        let f = try fixture()
        let writer = try child(f, mode: mode, name: "killed")
        defer { stop(writer) }
        try waitFor(f.directory.appendingPathComponent("killed.boundary"), process: writer)
        stop(writer)
        #expect(writer.terminationReason == .uncaughtSignal)
        #expect(writer.terminationStatus == SIGKILL)
        let committed = mode == "after-commit"
        #expect(try scalar(f.database, "SELECT COUNT(*) FROM Memory") == (committed ? "1" : "0"))
        #expect(try scalar(f.database, "SELECT COUNT(*) FROM EngramOperationReceiptV1") == (committed ? "1" : "0"))
        let originalReceipt = committed ? try scalar(f.database, "SELECT receiptJSON FROM EngramOperationReceiptV1") : nil
        let retry = try child(f, mode: "apply", name: "retry")
        defer { stop(retry) }
        try finish(retry)
        let recovered = try result(f, "retry")
        #expect(recovered.isReplay == committed)
        #expect(recovered.receipt.operationID == f.request.operationID)
        #expect(try scalar(f.database, "SELECT COUNT(*) FROM Memory") == "1")
        #expect(try scalar(f.database, "SELECT COUNT(*) FROM EngramOperationReceiptV1") == "1")
        if let originalReceipt {
            #expect(try scalar(f.database, "SELECT receiptJSON FROM EngramOperationReceiptV1") == originalReceipt)
        }
    }

    @Test func separateWritersWithSameIDCommitOneMutation() throws {
        let f = try fixture()
        let first = try child(f, mode: "concurrent", name: "first")
        defer { stop(first) }
        try waitFor(f.directory.appendingPathComponent("first.ready"), process: first)
        let second = try child(f, mode: "concurrent", name: "second")
        defer { stop(second) }
        try waitFor(f.directory.appendingPathComponent("second.ready"), process: second)
        try Data().write(to: f.directory.appendingPathComponent("release"))
        try finish(first)
        try finish(second)
        let a = try result(f, "first"), b = try result(f, "second")
        #expect(a.receipt == b.receipt)
        #expect(a.isReplay != b.isReplay)
        #expect(try scalar(f.database, "SELECT COUNT(*) FROM Memory") == "1")
        #expect(try scalar(f.database, "SELECT COUNT(*) FROM EngramOperationReceiptV1") == "1")
    }

    @Test func appendAfterLostAcknowledgementAppliesOnceInNewProcess() throws {
        let f = try fixture(append: true)
        let first = try child(f, mode: "append-after-commit", name: "append-killed")
        defer { stop(first) }
        try waitFor(f.directory.appendingPathComponent("append-killed.boundary"), process: first)
        stop(first)
        let prior = try scalar(f.database, "SELECT receiptJSON FROM EngramOperationReceiptV1")
        #expect(try scalar(f.database, "SELECT content FROM Memory") == "original\nonce")
        let retry = try child(f, mode: "append-apply", name: "append-retry")
        defer { stop(retry) }
        try finish(retry)
        #expect(try result(f, "append-retry").receipt.operationID == f.request.operationID)
        #expect(try scalar(f.database, "SELECT content FROM Memory") == "original\nonce")
        #expect(try scalar(f.database, "SELECT receiptJSON FROM EngramOperationReceiptV1") == prior)
        #expect(try scalar(f.database, "SELECT COUNT(*) FROM EngramOperationReceiptV1") == "1")
    }

    /// Invoked alone by the actual test executable in a fresh process. Normal
    /// suite execution returns immediately; all inputs are synthetic fixtures.
    @Test func fixtureProcess() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["ENGRAM_OPERATION_PROCESS_DIRECTORY"] else { return }
        let root = try #require(environment["ENGRAM_ADOPTION_TEST_ROOT"])
        guard directory.hasPrefix(root + "/operation-process-") else { throw Failure.invalidFixture }
        let mode = try #require(environment["ENGRAM_OPERATION_PROCESS_MODE"])
        let name = try #require(environment["ENGRAM_OPERATION_PROCESS_NAME"])
        guard !name.contains("/"), !name.contains("..") else { throw Failure.invalidFixture }
        let base = URL(fileURLWithPath: directory, isDirectory: true)
        let request = try JSONDecoder().decode(MemoryOperationRequest.self,
            from: Data(contentsOf: base.appendingPathComponent("request.json")))
        let database = base.appendingPathComponent("memory.sqlite")
        try MemoryOperationLedger.preflightLocalStore(at: database)
        let db = try Lattice(for: [Memory.self, Edge.self, SyncConfig.self] + MemoryOperationLedger.localModels,
                             configuration: .init(fileURL: database, busyTimeoutMs: 2_000))
        defer { db.close() }
        let ledger = MemoryOperationLedger(lattice: db)
        let prepared = try MemoryOperationCanonicalPayload.prepare(request)
        func boundary() throws {
            try Data().write(to: base.appendingPathComponent("\(name).boundary"))
            // The parent SIGKILLs us; a watchdog prevents an orphaned fixture.
            let end = ProcessInfo.processInfo.systemUptime + 20
            while ProcessInfo.processInfo.systemUptime < end { usleep(10_000) }
            throw Failure.timeout
        }
        if mode == "before-dispatch" { try boundary() }
        if mode == "concurrent" {
            try Data().write(to: base.appendingPathComponent("\(name).ready"))
            try waitFor(base.appendingPathComponent("release"))
        }
        let output: Result
        if mode.hasPrefix("append-") {
            let tools = MemoryTools(localRef: db.sendableReference, syncedRef: nil, embedder: Embed(),
                                    identity: StaticIdentityProvider(.anonymous), enableLocalMutationOperations: true)
            output = try await Result(receipt: tools.applyOperation(request), isReplay: nil)
        } else {
            let commit = try ledger.withOperation(prepared, principal: { .anonymous }) {
                let memory = Memory(content: "synthetic process memory", topic: "episode", project: "ProcessFixture")
                try db.add(memory)
                if mode == "inside-transaction" { try boundary() }
                return .init(outcome: .applied, memoryIDs: [try #require(memory.globalId)])
            }
            output = Result(receipt: commit.receipt, isReplay: commit.isReplay)
        }
        if mode == "after-commit" || mode == "append-after-commit" { try boundary() }
        try JSONEncoder().encode(output).write(to: base.appendingPathComponent("\(name).result.json"))
    }

    private func scalar(_ path: URL, _ sql: String) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else { throw Failure.sql }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw Failure.sql }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw Failure.sql }
        return String(cString: text)
    }
}
