@testable import EngramKit
import EngramMemoryCore
import EngramModels
import Foundation
import Lattice
import MCP
import Testing

/// The recall access-stat bump is off the hot path: hooks skip it, the MCP
/// tool does it best-effort on a dedicated short-busy-timeout handle.
@Suite("Recall access-stat bump", .serialized)
struct AccessStatBumpTests {

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
        let memoryId: UUID

        func close() {
            lattice.close()
            try? FileManager.default.removeItem(at: directory)
        }

        func memoryAuditRows() -> Int {
            lattice.objects(AuditLog.self).where { $0.tableName == "Memory" }.count
        }
    }

    /// Main handle at the production MCP busy timeout (2 s): if the bump
    /// still ran on it, a held lock would cost the recall two full seconds.
    private func fixture() throws -> Fixture {
        let directory = try testFixtureDirectory()
            .appendingPathComponent("access-stat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("memory.sqlite")
        let lattice = try Lattice(
            Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self,
            configuration: .init(fileURL: path, busyTimeoutMs: 2_000))
        var vector = [Float](repeating: 0, count: 384)
        vector[0] = 1
        let memory = Memory(content: "Access-stat fixture memory", topic: "stats", project: "AccessStat",
                            embedding: Vector<Float>(vector))
        try lattice.add(memory)
        let tools = MemoryTools(localRef: lattice.sendableReference, syncedRef: nil,
                                embedder: FixtureEmbedder(),
                                identity: StaticIdentityProvider(.anonymous))
        return Fixture(directory: directory, path: path, lattice: lattice, tools: tools,
                       memoryId: try #require(memory.globalId))
    }

    /// Read through a raw connection so no handle's row cache can answer.
    private func storedAccessCount(_ f: Fixture) throws -> Int {
        let raw = try RawWriteLock(path: f.path.path)
        defer { raw.close() }
        return try raw.integer("SELECT accessCount FROM Memory WHERE globalId = '\(f.memoryId.uuidString)' COLLATE NOCASE")
    }

    @Test func directRecallDoesNotBump() async throws {
        let f = try fixture()
        defer { f.close() }
        let auditBefore = f.memoryAuditRows()

        let rendered = try await f.tools.directRecall(query: "access-stat fixture", project: "AccessStat",
                                                      depth: 1, limit: 5)
        #expect(rendered?.contains("Access-stat fixture memory") == true)
        #expect(await f.tools.lastAccessStatBump == .skippedOptOut)
        #expect(try storedAccessCount(f) == 0)
        #expect(f.memoryAuditRows() == auditBefore, "no Memory UPDATE audit row from a hook recall")
    }

    @Test func mcpRecallBumpsOnceWhenTheHubIsFree() async throws {
        let f = try fixture()
        defer { f.close() }
        let auditBefore = f.memoryAuditRows()

        let result = try await f.tools.handle(CallTool.Parameters(name: "recall", arguments: [
            "query": .string("access-stat fixture"), "project": .string("AccessStat"),
        ]))
        #expect(result.isError == false)
        #expect(await f.tools.lastAccessStatBump == .bumped(rows: 1))
        #expect(try storedAccessCount(f) == 1)
        let auditAfter = f.memoryAuditRows()
        #expect(auditAfter > auditBefore && auditAfter <= auditBefore + 2,
                "one bump transaction: at most the setter and the increment as audit rows (\(auditAfter - auditBefore))")
    }

    @Test func mcpRecallUnderAHeldWriteLockReturnsFastAndSkipsTheBump() async throws {
        let f = try fixture()
        defer { f.close() }
        // First recall opens the dedicated handle while the hub is free.
        _ = try await f.tools.handle(CallTool.Parameters(name: "recall", arguments: [
            "query": .string("access-stat fixture"), "project": .string("AccessStat"),
        ]))
        #expect(try storedAccessCount(f) == 1)

        let holder = try RawWriteLock(path: f.path.path)
        defer { holder.close() }
        try holder.acquire()

        let started = ProcessInfo.processInfo.systemUptime
        let result = try await f.tools.handle(CallTool.Parameters(name: "recall", arguments: [
            "query": .string("access-stat fixture"), "project": .string("AccessStat"),
        ]))
        let elapsed = ProcessInfo.processInfo.systemUptime - started

        #expect(result.isError == false)
        #expect(text(from: result).contains("Access-stat fixture memory"), "the composed result is returned unchanged")
        let outcome = await f.tools.lastAccessStatBump
        if case .skippedBusy(let waitedMs) = outcome {
            #expect(waitedMs < 1_000, "waited \(waitedMs) ms")
        } else {
            Issue.record("expected .skippedBusy, got \(outcome)")
        }
        #expect(elapsed < 1.5, "recall took \(elapsed) s with the hub locked (main-handle timeout is 2 s)")
        holder.release()
        #expect(try storedAccessCount(f) == 1, "the skipped bump wrote nothing")
    }
}
