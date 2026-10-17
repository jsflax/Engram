import Testing
import EngramKit
import EngramMemoryCore
import EngramModels
import Lattice
import MCP
import Foundation

// MARK: - Recall benchmark suite (opt-in)
//
// Measures the costs the advise hook re-pays on every prompt: warm
// directRecall latency, recall SQL statement count, and the full cold
// advise process (embedder load + gate + DB opens + union attach + recall)
// end to end.
//
// Gating — every test returns immediately unless one of these is set:
//   ENGRAM_RECALL_BENCH_FIXTURE=<dir>  A claude-dir-shaped fixture:
//       memory.sqlite [+ sync/memory-synced.sqlite + sync/group-*.sqlite].
//       The fixture is CLONED to a temp dir (cheap APFS clonefile via
//       FileManager.copyItem) before any open, so access-bump writes never
//       mutate it. Pointing this at the live ~/.claude is refused — NEVER
//       open (or even clone) live production databases.
//   ENGRAM_RECALL_BENCH_SMOKE=1        Build a tiny synthetic fixture in
//       temp instead — mechanics smoke test; the numbers are meaningless.
//
// Optional knobs:
//   ENGRAM_RECALL_BENCH_PROJECT  project filter for recall (default "Engram")
//   ENGRAM_RECALL_BENCH_QUERY    recall query (default: 8-term query below)
//   ENGRAM_HOOKS_BINARY          release memory-hooks binary for the cold
//                                test (default .build/release/EngramHooks)
//
// The SQL statement counter is process-global, so the suite is serialized;
// run it alone (`swift test --filter RecallBench`) for clean counts.

@Suite("RecallBench", .serialized)
struct RecallBench {

    /// Realistic 8-term recall query (content words, the shape Advise builds
    /// via extractContentWords before calling directRecall).
    private static let defaultQuery =
        "recall latency sqlite embedding hook startup performance regression"

    private var benchProject: String {
        ProcessInfo.processInfo.environment["ENGRAM_RECALL_BENCH_PROJECT"] ?? "Engram"
    }

    private var benchQuery: String {
        ProcessInfo.processInfo.environment["ENGRAM_RECALL_BENCH_QUERY"] ?? Self.defaultQuery
    }

    // MARK: Fixture plumbing

    private struct Fixture {
        let dir: URL
        /// True for the synthetic smoke fixture — remove it after the test.
        let ephemeral: Bool
    }

    /// Resolve the fixture directory to benchmark, or nil to skip the test.
    /// A real fixture (ENGRAM_RECALL_BENCH_FIXTURE) wins over smoke mode.
    private func resolveFixture() async throws -> Fixture? {
        let env = ProcessInfo.processInfo.environment
        if let path = env["ENGRAM_RECALL_BENCH_FIXTURE"] {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let liveClaude = URL(fileURLWithPath: NSHomeDirectory() + "/.claude")
                .standardizedFileURL
            // NEVER the live claude dir: even though all opens happen on a
            // clone, cloning databases mid-write is not a consistent snapshot,
            // and the point of the fixture indirection is that production data
            // is copied deliberately, offline, by the operator.
            if url.path == liveClaude.path {
                Issue.record("""
                    ENGRAM_RECALL_BENCH_FIXTURE points at the live ~/.claude — refusing. \
                    Copy it first (with the daemon quiet), e.g.: \
                    cp -c -R ~/.claude/memory.sqlite* ~/.claude/sync /tmp/engram-fixture/
                    """)
                return nil
            }
            guard FileManager.default.fileExists(
                atPath: url.appending(path: "memory.sqlite").path) else {
                Issue.record("fixture has no memory.sqlite: \(url.path)")
                return nil
            }
            return Fixture(dir: url, ephemeral: false)
        }
        if env["ENGRAM_RECALL_BENCH_SMOKE"] == "1" {
            return Fixture(dir: try await buildSmokeFixture(), ephemeral: true)
        }
        print("RecallBench: skipped — set ENGRAM_RECALL_BENCH_FIXTURE=<dir> "
            + "or ENGRAM_RECALL_BENCH_SMOKE=1")
        return nil
    }

    /// Tiny synthetic claude-dir-shaped fixture: ~20 memories + a few edges,
    /// written through the real remember/connect path so embeddings and graph
    /// rows are genuine. Content overlaps the default query so recall hits.
    private func buildSmokeFixture() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "recall-bench-smoke-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appending(path: "sync"),
                               withIntermediateDirectories: true)

        let lattice = try Lattice(
            Memory.self, Edge.self, Checkpoint.self, HookState.self,
            SessionState.self, SyncConfig.self,
            configuration: .init(fileURL: dir.appending(path: "memory.sqlite")))
        let embedder = sharedEmbedder
        if await !embedder.isLoaded { await embedder.load() }
        let tools = MemoryTools(localRef: lattice.sendableReference,
                                syncedRef: nil, embedder: embedder,
                                identity: StaticIdentityProvider(.anonymous))

        let topics = ["hook startup cost", "sqlite recall latency",
                      "embedding model load", "regression triage notes"]
        var ids: [String] = []
        for i in 0..<20 {
            let result = try await tools.handle(CallTool.Parameters(
                name: "remember",
                arguments: [
                    "content": .string(
                        "Smoke memory \(i) — \(topics[i % topics.count]): recall latency "
                        + "sqlite embedding hook startup performance regression detail \(i)"),
                    "project": .string(benchProject),
                    "force": .bool(true),
                ]))
            if let id = extractId(from: text(from: result)) { ids.append(id) }
        }
        #expect(ids.count == 20, "smoke fixture: expected 20 remembered ids, got \(ids.count)")
        for i in 1..<min(6, ids.count) {
            _ = try await tools.handle(CallTool.Parameters(
                name: "connect",
                arguments: [
                    "from": .string(ids[i]),
                    "to": .string(ids[0]),
                    "relation": .string("part_of"),
                ]))
        }
        return dir
    }

    /// Clone the fixture dir into temp (APFS clonefile via copyItem) so
    /// recall's access-stat bumps write to a throwaway copy — the fixture
    /// stays byte-identical across runs. Copies WAL/SHM sidecars and the
    /// sync/ subtree along with the directory.
    private func cloneFixture(_ fixture: Fixture) throws -> URL {
        let dst = FileManager.default.temporaryDirectory
            .appending(path: "recall-bench-run-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixture.dir, to: dst)
        return dst
    }

    private func cleanup(_ fixture: Fixture, clone: URL) {
        try? FileManager.default.removeItem(at: clone)
        if fixture.ephemeral { try? FileManager.default.removeItem(at: fixture.dir) }
    }

    /// Open MemoryTools against a (cloned) fixture hub the way production
    /// does — same schema and migration as the MCP server (main.swift) and
    /// the hooks' initMemoryTools (LatticeHelpers.swift): hub + optional
    /// synced mirror + group spokes discovered under sync/.
    private func openBenchTools(hub: URL) async throws -> MemoryTools {
        let lattice = try Lattice(
            Memory.self, Edge.self, Checkpoint.self, HookState.self,
            SessionState.self, SyncConfig.self,
            configuration: .init(fileURL: hub.appending(path: "memory.sqlite"),
                                 migration: engramMigrations))

        var syncedRef: LatticeThreadSafeReference?
        let syncedDbPath = SyncService.syncedDbPath(claudeDir: hub.path)
        if FileManager.default.fileExists(atPath: syncedDbPath) {
            let synced = try Lattice(
                Memory.self, Edge.self, SyncConfig.self,
                configuration: .init(fileURL: URL(fileURLWithPath: syncedDbPath),
                                     migration: engramMigrations))
            syncedRef = synced.sendableReference
        }

        var groupRefs: [MemoryTools.GroupSpokeRef] = []
        for spoke in SyncService.discoverGroupSpokes(claudeDir: hub.path) {
            guard let spokeLattice = try? Lattice(
                Memory.self, Edge.self, GroupProjectMap.self,
                configuration: .init(fileURL: URL(fileURLWithPath: spoke.path),
                                     migration: engramMigrations)) else { continue }
            groupRefs.append(.init(groupId: spoke.groupId, path: spoke.path,
                                   ref: spokeLattice.sendableReference))
        }

        let embedder = sharedEmbedder
        if await !embedder.isLoaded { await embedder.load() }
        // Preserve the same live attribution as the cold advise benchmark.
        return MemoryTools(localRef: lattice.sendableReference, syncedRef: syncedRef,
                           groupRefs: groupRefs, embedder: embedder,
                           identity: GroupDirectoryIdentityProvider())
    }

    // MARK: Measurement helpers

    private func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1_000
            + Double(d.components.attoseconds) / 1e15
    }

    /// Nearest-rank percentile over an ascending-sorted sample.
    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[max(0, min(sorted.count - 1, rank))]
    }

    /// Count rendered memory blocks (direct + connected) in a directRecall
    /// result — blocks start with "[id:", same framing logRecalledMemories
    /// parses.
    private func hitCount(in result: String?) -> Int {
        guard let result else { return 0 }
        return result.components(separatedBy: "\n\n")
            .filter {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[id:")
            }
            .count
    }

    // MARK: Tests

    /// Warm recall latency: what a prompt would cost if the advise process
    /// were resident (no model load, no DB opens). 3 warmups, 20 measured.
    @Test func warmRecallLatency() async throws {
        guard let fixture = try await resolveFixture() else { return }
        let hub = try cloneFixture(fixture)
        defer { cleanup(fixture, clone: hub) }
        let tools = try await openBenchTools(hub: hub)

        for _ in 0..<3 {
            _ = try await tools.directRecall(
                query: benchQuery, project: benchProject, depth: 1, limit: 5)
        }

        var samples: [Double] = []
        var lastResult: String?
        for _ in 0..<20 {
            let start = ContinuousClock.now
            lastResult = try await tools.directRecall(
                query: benchQuery, project: benchProject, depth: 1, limit: 5)
            samples.append(ms(ContinuousClock.now - start))
        }

        let sorted = samples.sorted()
        let hits = hitCount(in: lastResult)
        let p50 = String(format: "%.2f", percentile(sorted, 0.50))
        let p95 = String(format: "%.2f", percentile(sorted, 0.95))
        print("BENCH RecallWarm: p50_ms=\(p50) p95_ms=\(p95) hits=\(hits)")
        #expect(hits > 0, """
            warm recall returned no hits — the benchmark exercised KNN but skipped \
            traversal/bump/render. Check ENGRAM_RECALL_BENCH_PROJECT/_QUERY against \
            the fixture's contents.
            """)
    }

    /// SQL statements per warm recall — the Lattice.totalSQLStatementCount
    /// delta pattern from RecallPerfRegressionTests. The counter is
    /// process-global; min-of-3 guards against incidental noise, and clean
    /// numbers require running this suite alone (--filter RecallBench).
    @Test func warmRecallStatementCount() async throws {
        guard let fixture = try await resolveFixture() else { return }
        let hub = try cloneFixture(fixture)
        defer { cleanup(fixture, clone: hub) }
        let tools = try await openBenchTools(hub: hub)

        var used = UInt64.max
        var lastResult: String?
        for _ in 0..<3 {
            let base = Lattice.totalSQLStatementCount
            lastResult = try await tools.directRecall(
                query: benchQuery, project: benchProject, depth: 1, limit: 5)
            used = min(used, Lattice.totalSQLStatementCount - base)
        }

        print("BENCH RecallStatements: count=\(used)")
        #expect(hitCount(in: lastResult) > 0,
                "recall returned no hits — statement count reflects an empty recall")
    }

    /// Cold end-to-end: spawn the RELEASE memory-hooks binary as `advise`
    /// with a JSON prompt on stdin — the exact per-prompt tax the hook pays
    /// (process boot, 43MB embedder, gate classifier, 4-6 DB opens, union
    /// attach, recall). Wall time process-spawn → exit, 5 iterations.
    @Test func coldAdviseEndToEnd() async throws {
        guard let fixture = try await resolveFixture() else { return }

        let env = ProcessInfo.processInfo.environment
        let binRaw = env["ENGRAM_HOOKS_BINARY"] ?? ".build/release/EngramHooks"
        let binPath = binRaw.hasPrefix("/")
            ? binRaw
            : FileManager.default.currentDirectoryPath + "/" + binRaw
        guard FileManager.default.isExecutableFile(atPath: binPath) else {
            print("BENCH AdviseCold: SKIPPED — hooks binary not found at \(binPath) "
                + "(swift build -c release, or set ENGRAM_HOOKS_BINARY)")
            return
        }

        let hub = try cloneFixture(fixture)
        defer { cleanup(fixture, clone: hub) }
        try suppressMaintenance(hub: hub)

        // cwd whose lastPathComponent is the bench project, so the hook
        // derives the same project filter the warm tests use.
        let cwd = hub.appending(path: "bench-cwd/\(benchProject)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        // Topical prompt (must pass the recall gate) built around the bench
        // query terms; UserPromptSubmitInput shape from HookModels.swift.
        let input: [String: Any] = [
            "cwd": cwd.path,
            "prompt": "Why did \(benchQuery) get worse after the last release? "
                + "Walk me through what the advise hook pays per prompt.",
        ]
        let inputData = try JSONSerialization.data(withJSONObject: input)

        var childEnv = env
        childEnv["CLAUDE_MEMORY_DB"] = hub.appending(path: "memory.sqlite").path
        // HOME stays unchanged (hooks.log etc.), but strip anything that
        // would divert or no-op the local advise path:
        childEnv.removeValue(forKey: "CLAUDE_MEMORY_MAINTENANCE")  // recursion guard no-ops advise
        childEnv.removeValue(forKey: "ENGRAM_URL")     // remote backend bypasses local recall
        childEnv.removeValue(forKey: "ENGRAM_TOKEN")
        childEnv.removeValue(forKey: "CLAUDE_SESSION_ID")  // no per-session log spam in HOME

        var samples: [Double] = []
        for i in 0..<5 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binPath)
            process.arguments = ["advise"]
            process.environment = childEnv
            let stdin = Pipe()
            process.standardInput = stdin
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            let start = ContinuousClock.now
            try process.run()
            stdin.fileHandleForWriting.write(inputData)
            try? stdin.fileHandleForWriting.close()
            process.waitUntilExit()
            samples.append(ms(ContinuousClock.now - start))

            #expect(process.terminationStatus == 0,
                    "advise iteration \(i) exited \(process.terminationStatus)")
        }

        let sorted = samples.sorted()
        let p50 = String(format: "%.1f", percentile(sorted, 0.50))
        let maxMs = String(format: "%.1f", sorted.last ?? 0)
        print("BENCH AdviseCold: p50_ms=\(p50) max_ms=\(maxMs)")
    }

    /// The advise hook spawns a headless-claude maintenance subprocess when
    /// enough Memory writes accumulated since the last run — a benchmark
    /// must never do that. Stamping lastRunTimestamp=now on the CLONE puts
    /// every iteration inside the 15-minute cooldown (and clears any stale
    /// active flag the fixture carried).
    private func suppressMaintenance(hub: URL) throws {
        let lattice = try Lattice(
            Memory.self, Edge.self, Checkpoint.self, HookState.self,
            SessionState.self, SyncConfig.self,
            configuration: .init(fileURL: hub.appending(path: "memory.sqlite"),
                                 migration: engramMigrations))
        let stamps: [(HookState.Key, String)] = [
            (.maintenanceLastRunTimestamp, String(Date().timeIntervalSince1970)),
            (.maintenanceActive, "0"),
        ]
        for (key, value) in stamps {
            if let row = lattice.objects(HookState.self).where({ $0.key == key }).first {
                row.value = value
                row.updatedAt = Date()
            } else {
                try lattice.add(HookState(key: key, value: value))
            }
        }
    }
}
