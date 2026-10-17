@testable import EngramKit
import EngramMemoryCore
import EngramMemoryContract
import EngramModels
import Foundation
import Lattice
import MCP
import SQLite3
import Testing

// The pure cases exercise the released SDK's explicit outcomes; the disposable
// store case exercises the actual vacuum tool without a model or provider.
@Suite("Lattice adoption maintenance", .serialized)
struct LatticeAdoptionMaintenanceTests {
    private func outcome(
        checkpoint: CheckpointResult = .init(busy: false, complete: true, logFrames: 0, checkpointed: 0),
        rows: Int64 = 1,
        vacuum: Bool? = true,
        finalFrames: Int64 = 0
    ) -> MemoryTools.VacuumStoreOutcome {
        .init(label: "fixture", checkpoint: checkpoint, reindexedRows: rows,
              vacuumSucceeded: vacuum, boundedCheckpointFrames: finalFrames)
    }

    @Test func checkpointBusyPartialAndFailureAreNotSuccess() {
        let busy = outcome(checkpoint: .init(busy: true, complete: false, logFrames: 3, checkpointed: 1))
        #expect(busy.failed)
        #expect(busy.checkpointDescription == "busy")
        let partial = outcome(checkpoint: .init(busy: false, complete: false, logFrames: 3, checkpointed: 1))
        #expect(partial.failed)
        #expect(partial.checkpointDescription == "partial")
        let failed = outcome(checkpoint: .init(busy: false, complete: false, logFrames: -1, checkpointed: -1))
        #expect(failed.failed)
        #expect(failed.checkpointDescription == "failed")
    }

    @Test func failedVacuumAndUnavailableMaintenanceCountsAreErrors() {
        #expect(outcome(vacuum: false).failed)
        #expect(outcome(vacuum: false).description.contains("database VACUUM failed"))
        #expect(outcome(rows: -1).failed)
        #expect(outcome(finalFrames: -1).failed)
        #expect(outcome(finalFrames: -1).description.contains("busy or failed"))
    }

    @Test func boundedFrameCountDoesNotClaimTruncation() {
        let result = outcome(finalFrames: 2)
        #expect(!result.failed)
        #expect(result.description.contains("processed 2 frames"))
        #expect(!result.description.contains("WAL truncated"))
        let spoke = outcome(vacuum: nil)
        #expect(!spoke.failed)
        #expect(spoke.description.contains("database VACUUM not requested"))
    }

    private struct UnusedEmbedder: Embedder {
        var dimension: Int { 384 }
        func embed(text: String) async throws -> [Float]? { nil }
    }

    @Test func vacuumToolPreservesMemoryAndReportsObservedOutcomes() async throws {
        let root = ProcessInfo.processInfo.environment["ENGRAM_ADOPTION_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("lattice-maintenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("memory.sqlite")
        let writer = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self,
                                 configuration: .init(fileURL: path, busyTimeoutMs: 100))
        var vector = [Float](repeating: 0, count: 384)
        vector[0] = 1
        let row = Memory(content: "maintenance fixture", topic: "maintenance", project: "Adoption",
                         embedding: Vector<Float>(vector))
        try writer.add(row)
        let id = try #require(row.globalId)
        let tools = MemoryTools(localRef: writer.sendableReference, syncedRef: nil,
                                embedder: UnusedEmbedder(), identity: StaticIdentityProvider(.anonymous))
        let result = try await tools.handle(CallTool.Parameters(name: "vacuum"))
        let text = result.content.compactMap { item -> String? in
            if case .text(let value, _, _) = item { return value }
            return nil
        }.joined(separator: "\n")
        #expect(result.isError == false)
        #expect(text.contains("Vacuum maintenance finished."))
        #expect(text.contains("local: initial checkpoint complete"))
        #expect(text.contains("database VACUUM succeeded"))
        #expect(text.contains("Final WAL truncation is not confirmed"))
        // Reopen independently to check that maintenance preserved committed rows.
        let reader = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self,
                                 configuration: .init(fileURL: path, busyTimeoutMs: 100))
        let saved = reader.objects(Memory.self).where { $0.globalId == id }
        #expect(saved.count == 1)
        #expect(saved.first?.content == "maintenance fixture")
    }

    private struct MaintenanceFixture {
        let directory: URL
        let path: URL
        let writer: Lattice
        let tools: MemoryTools

        func close() {
            writer.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func maintenanceFixture() throws -> MaintenanceFixture {
        let root = ProcessInfo.processInfo.environment["ENGRAM_ADOPTION_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("vacuum-read-marks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("memory.sqlite")
        let writer = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self,
                                 configuration: .init(fileURL: path, busyTimeoutMs: 100))
        let tools = MemoryTools(localRef: writer.sendableReference, syncedRef: nil,
                                embedder: DeterministicEmbedder(), identity: StaticIdentityProvider(.anonymous))
        return MaintenanceFixture(directory: directory, path: path, writer: writer, tools: tools)
    }

    /// Match the capability contract's typed call sequence. Even an empty
    /// filtered cluster snapshot can leave a coordinator-owned read keeper.
    private func prepareTypedMaintenance(_ tools: MemoryTools) async throws {
        let episode = try await tools.beginEpisode(title: "typed maintenance episode", sessionKey: nil)
        #expect(!episode.isError)
        let task = try await tools.checkpoint(title: "typed maintenance task", sessionKey: nil)
        #expect(!task.isError)
        let clusters = try await tools.findClusters(project: "contract-proj")
        #expect(!clusters.isError)
    }

    @Test func typedMaintenanceReleasesOwnCompletedReadSnapshot() async throws {
        let f = try maintenanceFixture()
        defer { f.close() }
        try await prepareTypedMaintenance(f.tools)
        let observer = try SQLiteReader(f.path)
        defer { observer.close() }
        let before = try observer.memories()
        #expect(before.count == 1)
        #expect(before.values.first == "typed maintenance episode")

        let result = try await f.tools.vacuum()

        #expect(!result.isError)
        #expect(result.text.contains("local: initial checkpoint complete"))
        #expect(result.text.contains("database VACUUM succeeded"))
        #expect(result.text.contains("Final WAL truncation is not confirmed"))
        #expect(try observer.memories() == before)
    }

    @Test func vacuumRetainsIndependentReaderFailureUntilExplicitRelease() async throws {
        let f = try maintenanceFixture()
        defer { f.close() }
        try await prepareTypedMaintenance(f.tools)
        let reader = try SQLiteReader(f.path)
        defer { reader.close() }
        try reader.execute("BEGIN")
        let snapshot = try reader.memories()
        try #require(snapshot.count == 1)
        #expect(reader.isInTransaction)

        // Commit after the independent reader's snapshot. That connection
        // must continue seeing its original rows across maintenance, while
        // the new committed row remains visible to a fresh observer.
        var vector = [Float](repeating: 0, count: 384)
        vector[0] = 1
        let newContent = "committed after the independent maintenance reader"
        let added = Memory(content: newContent, project: "Adoption", embedding: Vector<Float>(vector))
        try f.writer.add(added)
        let addedID = try #require(added.globalId)
        var expected = snapshot
        expected[addedID] = newContent
        let observer = try SQLiteReader(f.path)
        defer { observer.close() }
        #expect(try observer.memories() == expected)

        let blocked = try await f.tools.vacuum()

        #expect(blocked.isError)
        #expect(blocked.text.contains("Vacuum incomplete."))
        #expect(blocked.text.contains("local: initial checkpoint busy"))
        #expect(blocked.text.contains("Final WAL truncation is not confirmed"))
        #expect(reader.isInTransaction)
        #expect(try reader.memories() == snapshot)
        #expect(try observer.memories() == expected)
        try reader.execute("ROLLBACK")
        #expect(!reader.isInTransaction)

        let recovered = try await f.tools.vacuum()

        #expect(!recovered.isError)
        #expect(recovered.text.contains("local: initial checkpoint complete"))
        #expect(recovered.text.contains("database VACUUM succeeded"))
        #expect(recovered.text.contains("Final WAL truncation is not confirmed"))
        #expect(try observer.memories() == expected)
    }

    private struct SQLiteFailure: Error { let message: String }

    /// Owns only a separate read-only connection to this test's disposable
    /// store. BEGIN/ROLLBACK affect its read transaction, never stored rows.
    private final class SQLiteReader {
        private var db: OpaquePointer?

        init(_ path: URL) throws {
            var opened: OpaquePointer?
            let result = sqlite3_open_v2(path.path, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
            guard result == SQLITE_OK, let opened else {
                let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Reader open failed"
                if let opened { sqlite3_close(opened) }
                throw SQLiteFailure(message: message)
            }
            db = opened
            sqlite3_busy_timeout(opened, 100)
        }

        deinit { close() }
        func close() {
            if let db { sqlite3_close(db) }
            db = nil
        }
        var isInTransaction: Bool { db.map { sqlite3_get_autocommit($0) == 0 } ?? false }

        func execute(_ sql: String) throws {
            guard let db, sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw SQLiteFailure(message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "Reader closed")
            }
        }

        func memories() throws -> [UUID: String] {
            guard let db else { throw SQLiteFailure(message: "Reader closed") }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT globalId, content FROM Memory", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw SQLiteFailure(message: String(cString: sqlite3_errmsg(db))) }
            defer { sqlite3_finalize(statement) }
            var rows: [UUID: String] = [:]
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                guard let rawID = sqlite3_column_text(statement, 0),
                      let id = UUID(uuidString: String(cString: rawID)),
                      let content = sqlite3_column_text(statement, 1), rows[id] == nil else {
                    throw SQLiteFailure(message: "Invalid or duplicate memory identity")
                }
                rows[id] = String(cString: content)
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw SQLiteFailure(message: String(cString: sqlite3_errmsg(db))) }
            return rows
        }
    }
}
