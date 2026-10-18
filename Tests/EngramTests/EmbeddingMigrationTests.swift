import Testing
import EngramKit
import EngramModels
@testable import Lattice
import Foundation

private final class MigrationSweepClock: @unchecked Sendable {
    private let lock = NSLock()
    private let lattice: Lattice
    private var started: ContinuousClock.Instant?
    private var readGenerations: Int?

    init(lattice: Lattice) { self.lattice = lattice }

    func record(_ message: String) {
        guard message.hasPrefix("Embedding migration: 0 rows ") else { return }
        let outstanding = lattice.backend.localReadGenerationsOutstanding()
        lock.lock()
        defer { lock.unlock() }
        started = ContinuousClock.now
        readGenerations = outstanding
    }

    func elapsed() -> Duration? {
        lock.lock()
        defer { lock.unlock() }
        return started?.duration(to: .now)
    }

    func readGenerationsAtSweepStart() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return readGenerations
    }
}

// ============================================================================
// EmbeddingMigration — the v2 space sweep every 0.14.0 machine runs.
//
// This is release-path code with three automatic triggers (daemon sync path,
// daemon free-tier idle path, MCP-startup backstop) plus the manual CLI.
// The mechanism must hold regardless of which trigger fires: stale rows get
// the current model's vectors, the in-database marker advances only after a
// complete pass, current databases are a cheap no-op, spoke (markerless)
// mode never touches HookState, and a missing model fails loudly without
// stranding the marker.
// ============================================================================

@Suite("Embedding space migration")
struct EmbeddingMigrationTests {

    private func makeLattice(withHookState: Bool = true) throws -> (Lattice, URL) {
        let dir = try testFixtureDirectory()
            .appending(path: "embed-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "db.sqlite")
        let lattice = withHookState
            ? try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self,
                          SyncConfig.self, configuration: .init(fileURL: url))
            : try Lattice(Memory.self, Edge.self, GroupProjectMap.self,
                          configuration: .init(fileURL: url))
        return (lattice, url)
    }

    /// A deliberately wrong stored vector — what a v1 (or corrupted) row
    /// looks like to the sweep.
    private func staleVector() -> Vector<Float> {
        var v = [Float](repeating: 0, count: 384)
        v[0] = 1.0
        return Vector<Float>(v)
    }

    @Test func emptySweepBoundsFinalCheckpointWithAnIndependentReadSnapshot() async throws {
        await sharedEmbedder.load()
        #expect(await sharedEmbedder.isLoaded)

        let directory = try testFixtureDirectory()
            .appending(path: "embed-migration-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = Lattice.Configuration(fileURL: directory.appending(path: "db.sqlite"))
        configuration.busyTimeoutMs = 2_000
        let migration = try Lattice(Memory.self, Edge.self, Checkpoint.self,
                                    HookState.self, SyncConfig.self, configuration: configuration)
        defer { migration.close() }
        let snapshotReference = try migration.sendableReference.resolveIndependent()
        let reader = try #require(snapshotReference)
        defer { reader.close() }
        let queryReference = try migration.sendableReference.resolveIndependent()
        let request = try #require(queryReference)
        defer { request.close() }
        #expect(Set([migration.backend.identityHash, reader.backend.identityHash,
                     request.backend.identityHash]).count == 3)

        // Even an empty snapshot pins a real WAL generation. Keep this
        // independent handle alive across the marker write and checkpoint.
        #expect(reader.objects(Memory.self).snapshot().isEmpty)
        #expect(reader.lastQueryError() == nil)
        #expect(reader.backend.localReadGenerationsOutstanding() > 0)
        let clock = MigrationSweepClock(lattice: migration)
        let report = try await EmbeddingMigration.runIfNeeded(
            on: migration, embedder: sharedEmbedder, log: clock.record)
        // runIfNeeded calls load() again. Its first sweep log is emitted after
        // that await, so model loading cannot consume this storage budget.
        let elapsed = try #require(clock.elapsed())
        #expect(elapsed < .seconds(2), "Empty migration held the writer gate for \(elapsed)")
        #expect(clock.readGenerationsAtSweepStart() == 0,
                "Migration must release its snapshot before any embedding awaits")
        #expect(migration.backend.localReadGenerationsOutstanding() == 0)
        #expect(reader.backend.localReadGenerationsOutstanding() > 0)
        #expect(!report.skipped)
        #expect(report.reembedded == 0)
        #expect(report.failed == 0)
        #expect(EmbeddingMigration.storedVersion(in: migration) == EmbeddingSpace.currentVersion)
        #expect(migration.objects(Memory.self).snapshot().isEmpty)
        #expect(migration.backend.localReadGenerationsOutstanding() == 0,
                "Later migration reads must remain unpinned after retirement")

        // The first foreground vector query must still be able to lazily
        // create its index on a separate connection after the empty sweep.
        let neighbors = request.objects(Memory.self)
            .nearest(to: staleVector(), on: \.embedding, limit: 8, distance: .l2)
            .snapshot()
        #expect(request.lastQueryError() == nil)
        #expect(neighbors.isEmpty)
    }

    @Test func sweepReembedsStaleRowsAndAdvancesMarker() async throws {
        let (lattice, _) = try makeLattice()
        let contents = ["the quick brown fox jumps over the lazy dog",
                        "sqlite write-ahead logging keeps readers unblocked"]
        for c in contents {
            try lattice.add(Memory(content: c, topic: "general", project: "demo",
                                   embedding: staleVector()))
        }
        #expect(EmbeddingMigration.storedVersion(in: lattice) == 1)

        let report = try await EmbeddingMigration.runIfNeeded(
            on: lattice, embedder: sharedEmbedder)

        #expect(report.reembedded == 2)
        #expect(report.failed == 0)
        #expect(!report.skipped)
        #expect(lattice.backend.localReadGenerationsOutstanding() == 0)
        #expect(EmbeddingMigration.storedVersion(in: lattice) == EmbeddingSpace.currentVersion)

        // Rows carry the CURRENT model's vector for their own content.
        for mem in lattice.objects(Memory.self).snapshot() {
            let expected = try await sharedEmbedder.embed(text: mem.content)!
            let got = Array(mem.embedding)
            #expect(got.count == expected.count)
            let dot = zip(got, expected).map(*).reduce(0, +)
            #expect(dot > 0.999, "row not re-embedded with the current model (dot=\(dot))")
        }
    }

    @Test func sweepIsANoOpWhenMarkerCurrent() async throws {
        let (lattice, _) = try makeLattice()
        try lattice.add(Memory(content: "already migrated row", topic: "general",
                               project: "demo", embedding: staleVector()))
        try EmbeddingMigration.setStoredVersion(EmbeddingSpace.currentVersion, in: lattice)

        let report = try await EmbeddingMigration.runIfNeeded(
            on: lattice, embedder: sharedEmbedder)

        #expect(report.skipped)
        #expect(report.reembedded == 0)
        #expect(lattice.backend.localReadGenerationsOutstanding() == 0,
                "An already-current marker must not leave an idle read generation")
        // The stale vector proves no work happened.
        let mem = lattice.objects(Memory.self).first!
        #expect(Array(mem.embedding)[0] == 1.0, "no-op run must not touch rows")
        #expect(lattice.backend.localReadGenerationsOutstanding() == 0)
    }

    /// Spoke schema is [Memory, Edge, GroupProjectMap] — the markerless mode
    /// must sweep every run WITHOUT creating HookState (the group relay's
    /// write-policy denies unlisted tables; see f7705f9).
    @Test func markerlessModeSweepsWithoutTouchingHookState() async throws {
        let (lattice, url) = try makeLattice(withHookState: false)
        try lattice.add(Memory(content: "spoke resident row", topic: "general",
                               project: "demo", embedding: staleVector()))

        let report = try await EmbeddingMigration.runIfNeeded(
            on: lattice, embedder: sharedEmbedder, useMarker: false)

        #expect(report.reembedded == 1)
        #expect(lattice.backend.localReadGenerationsOutstanding() == 0,
                "Markerless sweeps must retire their own snapshot too")
        // No HookState table may exist in the file.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [url.path,
                       "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='HookState';"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let count = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                           encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(count == "0", "markerless sweep created HookState in a spoke-schema file")
    }

    @Test func missingModelFailsLoudlyAndLeavesMarkerUnset() async throws {
        let (lattice, _) = try makeLattice()
        try lattice.add(Memory(content: "row that must not be stranded",
                               topic: "general", project: "demo",
                               embedding: staleVector()))

        let broken = EmbeddingService(modelPath: "/nonexistent/model/path")
        await #expect(throws: EmbeddingMigration.MigrationError.self) {
            try await EmbeddingMigration.runIfNeeded(on: lattice, embedder: broken)
        }
        #expect(lattice.backend.localReadGenerationsOutstanding() == 0,
                "A model-load failure must not strand the marker lookup's keeper")
        #expect(EmbeddingMigration.storedVersion(in: lattice) == 1,
                "a failed sweep must never advance the marker")
        #expect(lattice.backend.localReadGenerationsOutstanding() == 0)
    }
}
