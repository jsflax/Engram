@testable import EngramKit
import EngramMemoryCore
import EngramModels
import Foundation
@testable import Lattice
import MCP
import Testing

private struct AccessStatHandleSnapshot: Equatable, Sendable {
    let identity: Int64
    let mainIdentity: Int64
    let timeout: Int
    let hasScheduler: Bool
    let hasSyncConfiguration: Bool
}

private final class AccessStatLifetimeProbe: @unchecked Sendable {
    weak var tools: MemoryTools?
    weak var backend: (any LatticeBackend)?
    init(tools: MemoryTools, handle: Lattice?) {
        self.tools = tools
        self.backend = handle?.backend
    }
}

private extension MemoryTools {
    func accessStatSnapshot() -> AccessStatHandleSnapshot? {
        guard let handle = accessStatLattice else { return nil }
        let config = handle.configuration
        return AccessStatHandleSnapshot(identity: handle.backend.identityHash,
            mainIdentity: localLattice.backend.identityHash, timeout: config.busyTimeoutMs,
            hasScheduler: handle.isolation != nil,
            hasSyncConfiguration: config.wssEndpoint != nil || config.authorizationToken != nil
                || !(config.ipcTargets ?? []).isEmpty)
    }

    func accessStatLifetimeProbe() -> AccessStatLifetimeProbe {
        AccessStatLifetimeProbe(tools: self, handle: accessStatLattice)
    }

    func bumpFixtureRowsWithDuplicates() {
        let rows = localLattice.objects(Memory.self).snapshot()
        // Isolate the stats handle's lifecycle from this fixture's own read.
        localLattice.retireAllGenerations()
        bumpAccessStatsBestEffort(rows + rows, now: Date())
    }
}

/// The recall access-stat bump is optional: hooks skip it, the MCP
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
        #expect(await f.tools.accessStatSnapshot() == nil, "hook recall must not even open a stats handle")
    }

    @Test func serviceAdviceDoesNotBump() async throws {
        let f = try fixture()
        defer { f.close() }
        let before = f.memoryAuditRows()
        let advice = try await f.tools.advise(AdviseRequest(prompt: "access-stat fixture", project: "AccessStat"))
        #expect(advice.block?.contains("Access-stat fixture memory") == true)
        #expect(await f.tools.lastAccessStatBump == .skippedOptOut)
        #expect(await f.tools.accessStatSnapshot() == nil)
        #expect(try storedAccessCount(f) == 0)
        #expect(f.memoryAuditRows() == before)
    }

    @Test func emptyRecallDoesNotReportAnEarlierBump() async throws {
        let f = try fixture()
        defer { f.close() }
        _ = try await f.tools.handle(CallTool.Parameters(name: "recall", arguments: ["query": .string("fixture")]))
        #expect(await f.tools.lastAccessStatBump == .bumped(rows: 1))
        _ = try await f.tools.handle(CallTool.Parameters(name: "recall", arguments: [
            "query": .string("fixture"), "topic": .string("absent-topic"),
        ]))
        #expect(await f.tools.lastAccessStatBump == .skippedNothing)
    }

    @Test func accessStatTargetsAreUniqueAndBounded() {
        let ids = (0..<(MemoryTools.accessStatTargetLimit + 20)).map { _ in UUID() }
        let duplicated = ids.flatMap { [$0, $0] }
        #expect(MemoryTools.accessStatTargetIDs(duplicated) == Array(ids.prefix(MemoryTools.accessStatTargetLimit)))
        #expect(MemoryTools.accessStatTargetIDs([]) == [])
    }

    @Test func largeBumpIsBounded() async throws {
        let f = try fixture()
        defer { f.close() }
        try f.lattice.withTransaction {
            for _ in 0..<MemoryTools.accessStatTargetLimit {
                try f.lattice.add(Memory(content: "bounded stats fixture"))
            }
        }
        let raw = try RawWriteLock(path: f.path.path)
        defer { raw.close() }
        // Prove the raw checkpoint observes a real pinned reader before
        // checking that the separate stats connection releases its own one.
        let pinned = f.lattice.objects(Memory.self).snapshot()
        #expect(pinned.count == MemoryTools.accessStatTargetLimit + 1)
        #expect(try raw.integer("PRAGMA wal_checkpoint(TRUNCATE)") == 1)
        f.lattice.retireAllGenerations()
        #expect(try raw.integer("PRAGMA wal_checkpoint(TRUNCATE)") == 0)
        await f.tools.bumpFixtureRowsWithDuplicates()
        #expect(try raw.integer("PRAGMA wal_checkpoint(TRUNCATE)") == 0,
                "a completed direct bump must not leave its dedicated reader pinned")
        let bumped = try raw.integer("SELECT COUNT(*) FROM Memory WHERE accessCount = 1")
        #expect(bumped == MemoryTools.accessStatTargetLimit)
        #expect(try raw.integer("SELECT COUNT(*) FROM Memory WHERE accessCount > 1") == 0)
    }

    @Test func statsCapDoesNotLimitRecallResults() async throws {
        let f = try fixture()
        defer { f.close() }
        let rowCount = MemoryTools.accessStatTargetLimit + 1
        var vector = [Float](repeating: 0, count: 384)
        vector[0] = 1
        try f.lattice.withTransaction {
            for index in 1..<rowCount {
                try f.lattice.add(Memory(content: "Recall fixture row \(index)",
                    embedding: Vector<Float>(vector)))
            }
        }
        let result = try await f.tools.handle(CallTool.Parameters(name: "recall", arguments: [
            "query": .string("fixture"), "limit": .int(rowCount),
        ]))
        #expect(result.isError == false)
        guard case .object(let outer) = try #require(result.structuredContent),
              case .object(let envelope) = outer["engram_recall"],
              case .array(let rows) = envelope["rows"] else {
            Issue.record("Missing native recall rows")
            return
        }
        #expect(rows.count == rowCount, "only approximate statistics may be capped")
        for index in 1..<rowCount {
            #expect(text(from: result).contains("Recall fixture row \(index)"))
        }
        #expect(text(from: result).contains("Access-stat fixture memory"))
        #expect(await f.tools.lastAccessStatBump == .bumped(rows: MemoryTools.accessStatTargetLimit))
        let raw = try RawWriteLock(path: f.path.path)
        defer { raw.close() }
        #expect(try raw.integer("SELECT COUNT(*) FROM Memory WHERE accessCount = 1") == MemoryTools.accessStatTargetLimit)
        #expect(try raw.integer("SELECT COUNT(*) FROM Memory WHERE accessCount = 0") == 1)
    }

    @Test func mirrorOnlyResultsStayVisibleWithoutWritingTheMirror() async throws {
        let f = try fixture()
        defer { f.close() }
        let mirrorPath = f.directory.appendingPathComponent("mirror.sqlite")
        let mirror = try Lattice(Memory.self, Edge.self, SyncConfig.self,
            configuration: .init(fileURL: mirrorPath))
        defer { mirror.close() }
        try f.lattice.add(SyncConfig(project: "AccessStat", policy: .sync))
        var vector = [Float](repeating: 0, count: 384)
        vector[0] = 1
        try mirror.add(Memory(content: "Mirror-only fixture memory", project: "AccessStat",
            embedding: Vector<Float>(vector)))
        let mirrorAuditBefore = mirror.objects(AuditLog.self).where { $0.tableName == "Memory" }.count
        let tools = MemoryTools(localRef: f.lattice.sendableReference,
            syncedRef: mirror.sendableReference, embedder: FixtureEmbedder(),
            identity: StaticIdentityProvider(.anonymous))
        let result = try await tools.handle(CallTool.Parameters(name: "recall", arguments: [
            "query": .string("fixture"), "project": .string("AccessStat"),
        ]))
        #expect(result.isError == false)
        #expect(text(from: result).contains("Mirror-only fixture memory"))
        #expect(text(from: result).contains("Access-stat fixture memory"))
        #expect(await tools.lastAccessStatBump == .bumped(rows: 1))
        #expect(try storedAccessCount(f) == 1)
        let raw = try RawWriteLock(path: mirrorPath.path)
        defer { raw.close() }
        #expect(try raw.integer("SELECT SUM(accessCount) FROM Memory") == 0)
        #expect(mirror.objects(AuditLog.self).where { $0.tableName == "Memory" }.count == mirrorAuditBefore)
    }

    @Test func bumpIgnoresDeletedOrExpiredRows() async throws {
        let f = try fixture()
        defer { f.close() }
        try f.lattice.add(Memory(content: "expired stats fixture", expiresAt: .distantPast))
        try f.lattice.add(Memory(content: "deleted stats fixture", deletedAt: Date()))
        await f.tools.bumpFixtureRowsWithDuplicates()
        #expect(await f.tools.lastAccessStatBump == .bumped(rows: 1))
        let raw = try RawWriteLock(path: f.path.path)
        defer { raw.close() }
        #expect(try raw.integer("SELECT SUM(accessCount) FROM Memory WHERE content IN ('expired stats fixture', 'deleted stats fixture')") == 0)
    }

    @Test func dedicatedHandlesAreIndependentCachedAndReleaseWithTheirActor() async throws {
        let f = try fixture()
        defer { f.close() }
        func openAndRelease() async throws -> [AccessStatLifetimeProbe] {
            let tools = MemoryTools(localRef: f.lattice.sendableReference, syncedRef: nil,
                embedder: FixtureEmbedder(), identity: StaticIdentityProvider(.anonymous))
            let other = MemoryTools(localRef: f.lattice.sendableReference, syncedRef: nil,
                embedder: FixtureEmbedder(), identity: StaticIdentityProvider(.anonymous))
            _ = try await tools.handle(CallTool.Parameters(name: "recall", arguments: ["query": .string("fixture")]))
            let snapshot = try #require(await tools.accessStatSnapshot())
            #expect(snapshot.timeout == 75 && !snapshot.hasScheduler && !snapshot.hasSyncConfiguration)
            #expect(snapshot.identity != snapshot.mainIdentity)
            _ = try await tools.handle(CallTool.Parameters(name: "recall", arguments: ["query": .string("fixture")]))
            #expect(await tools.accessStatSnapshot()?.identity == snapshot.identity)
            _ = try await other.handle(CallTool.Parameters(name: "recall", arguments: ["query": .string("fixture")]))
            let otherSnapshot = try #require(await other.accessStatSnapshot())
            #expect(otherSnapshot.identity != snapshot.identity, "separate actors cannot join each other's bump transaction")
            return [await tools.accessStatLifetimeProbe(), await other.accessStatLifetimeProbe()]
        }
        let probes = try await openAndRelease()
        #expect(probes.allSatisfy { $0.tools == nil }, "the stats scheduler must not retain MemoryTools")
        #expect(probes.allSatisfy { $0.backend == nil }, "the dedicated backend must release with its owner")
    }

    @Test func mcpRecallBumpsOnceWhenTheHubIsFree() async throws {
        let f = try fixture()
        defer { f.close() }
        let auditBefore = f.memoryAuditRows()
        // The test's audit read must not keep a separate reader pinned while
        // checking the MCP request's cleanup.
        f.lattice.retireAllGenerations()

        let result = try await f.tools.handle(CallTool.Parameters(name: "recall", arguments: [
            "query": .string("access-stat fixture"), "project": .string("AccessStat"),
        ]))
        #expect(result.isError == false)
        #expect(await f.tools.lastAccessStatBump == .bumped(rows: 1))
        #expect(try storedAccessCount(f) == 1)
        let auditAfter = f.memoryAuditRows()
        #expect(auditAfter > auditBefore && auditAfter <= auditBefore + 2,
                "one bump transaction: at most the setter and the increment as audit rows (\(auditAfter - auditBefore))")
        let raw = try RawWriteLock(path: f.path.path)
        defer { raw.close() }
        #expect(try raw.integer("PRAGMA wal_checkpoint(TRUNCATE)") == 0,
                "an idle MCP request must release read marks from the stats handle too")
    }

    @Test func firstStatsOpenUnderAWriteLockKeepsTheRecallResult() async throws {
        let f = try fixture()
        defer { f.close() }
        // Prime recall's read path without opening the stats connection. A
        // cold nearest() has its own startup work, outside the bump contract.
        _ = try await f.tools.directRecall(query: "access-stat fixture", project: "AccessStat")
        #expect(await f.tools.accessStatSnapshot() == nil)
        let holder = try RawWriteLock(path: f.path.path)
        defer { holder.close() }
        try holder.acquire()
        let result = try await f.tools.handle(CallTool.Parameters(name: "recall", arguments: [
            "query": .string("access-stat fixture"), "project": .string("AccessStat"),
        ]))
        #expect(result.isError == false)
        #expect(text(from: result).contains("Access-stat fixture memory"))
        switch await f.tools.lastAccessStatBump {
        case .skippedBusy, .skippedNoHandle: break
        default: Issue.record("a busy stats open or BEGIN must drop the optional bump")
        }
        if let snapshot = await f.tools.accessStatSnapshot() {
            #expect(snapshot.timeout == 75)
        }
        holder.release()
        #expect(try storedAccessCount(f) == 0)
    }

    @Test func mcpRecallUnderAHeldWriteLockKeepsTheResultAndSkipsTheBump() async throws {
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

        let result = try await f.tools.handle(CallTool.Parameters(name: "recall", arguments: [
            "query": .string("access-stat fixture"), "project": .string("AccessStat"),
        ]))

        #expect(result.isError == false)
        #expect(text(from: result).contains("Access-stat fixture memory"), "the composed result is returned unchanged")
        let outcome = await f.tools.lastAccessStatBump
        if case .skippedBusy(let waitedMs) = outcome {
            #expect(waitedMs >= 0)
        } else {
            Issue.record("expected .skippedBusy, got \(outcome)")
        }
        let snapshot = try #require(await f.tools.accessStatSnapshot())
        #expect(snapshot.timeout == 75, "the real contended BEGIN uses the dedicated lock-wait budget")
        // This is a busy-timeout contract, not an end-to-end deadline; a
        // loaded runner can deschedule the task after SQLite returns.
        holder.release()
        #expect(try storedAccessCount(f) == 1, "the skipped bump wrote nothing")
    }
}
