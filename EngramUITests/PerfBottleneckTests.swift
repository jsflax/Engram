import XCTest
import EngramKit
import Lattice

/// Comprehensive performance bottleneck test.
/// Exercises every interaction type in labeled phases, captures ALL instrumentation
/// CSVs, and produces a ranked bottleneck analysis.
///
/// Requires the Engram-UITesting scheme (ENGRAM_INSTRUMENTATION flag).
@MainActor
final class PerfBottleneckTests: XCTestCase {
    let app = XCUIApplication()

    private var localDbPath: String!
    private var syncedDbPath: String!
    private var localIds: [UUID] = []
    private var syncedIds: [UUID] = []
    private let testUUID = UUID().uuidString
    private var frameStatsPath: String { NSTemporaryDirectory() + "engram-frames-\(testUUID).csv" }

    // All CSV paths we collect
    private let csvPaths = [
        "/tmp/metal-frame-timing.csv",
        "/tmp/draw-timing.csv",
        "/tmp/flush-timing.csv",
        "/tmp/pack-timing.csv",
        "/tmp/merge-timing.csv",
        "/tmp/atlas-timing.log",
        "/tmp/center-log.csv",
        "/tmp/glow-log.csv",
        "/tmp/galaxy-migration.csv",
        "/tmp/label-diag.csv",
        "/tmp/swiftui-jitter.csv",
        "/tmp/swiftui-body-eval.csv",
        "/tmp/audio-timing.csv",
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false

        let tmpDir = NSTemporaryDirectory() + "perf-test-\(testUUID)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        localDbPath = tmpDir + "memory.sqlite"
        // App derives synced path as <localDbDir>/sync/memory-synced.sqlite
        let syncDir = tmpDir + "sync/"
        try FileManager.default.createDirectory(atPath: syncDir, withIntermediateDirectories: true)
        syncedDbPath = syncDir + "memory-synced.sqlite"

        // Clean ALL previous timing data
        for path in csvPaths { try? FileManager.default.removeItem(atPath: path) }

        // Seed a realistically large multi-project database.
        // Counts mirror the live DB distribution (~3,400 local, ~3,200 synced).
        // Real DB: 61MB local (3,406 memories, 29,104 edges),
        //          52MB synced (3,243 memories, 11,440 edges).
        let projects: [(name: String, count: Int)] = [
            ("Engram", 1000), ("Lattice", 500), ("ClaudeMemory", 200),
            ("engram-server", 120), ("sidescroller", 100), ("global", 200),
            ("LatticeCore", 40), ("SwiftLM", 25),
        ]
        localIds = seedMultiProjectDatabase(
            at: localDbPath,
            projects: projects,
            staleAge: 7200,
            withSyncConfig: ["Engram", "Lattice", "ClaudeMemory", "engram-server", "LatticeCore", "SwiftLM"]
        )

        // Seed synced DB — mirrors real synced DB: nearly everything syncs
        // except global, sidescroller, moscow, LatticeJS.
        syncedIds = seedMultiProjectDatabase(
            at: syncedDbPath,
            projects: [
                ("Engram", 1000), ("Lattice", 500), ("ClaudeMemory", 200),
                ("engram-server", 120), ("LatticeCore", 40), ("SwiftLM", 25),
            ],
            staleAge: 10800
        )

        // Add cross-galaxy edges: link personal-only galaxy nodes to synced galaxy nodes.
        // mergeRenderData() must resolve these across galaxies.
        //
        // localIds layout: Engram[0..999], Lattice[1000..1499], ClaudeMemory[1500..1699],
        //                  engram-server[1700..1819], sidescroller[1820..1919],
        //                  global[1920..2119], LatticeCore[2120..2159], SwiftLM[2160..2184]
        // syncedIds layout: Engram[0..999], Lattice[1000..1499], ClaudeMemory[1500..1699],
        //                  engram-server[1700..1819], LatticeCore[1820..1859], SwiftLM[1860..1884]
        //
        // sidescroller + global are personal-only → cross-galaxy edges to synced projects
        addCrossProjectEdges(
            at: localDbPath,
            sourceIds: Array(localIds[1820..<1840]),
            targetIds: Array(syncedIds[0..<20])
        )
        addCrossProjectEdges(
            at: localDbPath,
            sourceIds: Array(localIds[1920..<1940]),
            targetIds: Array(syncedIds[1000..<1020])
        )

        app.launchEnvironment["CLAUDE_MEMORY_DB"] = localDbPath
        app.launchEnvironment["ENGRAM_PERF_ISOLATED"] = "1"
        app.launchEnvironment["ENGRAM_FRAME_STATS"] = frameStatsPath
        app.launchEnvironment["ENGRAM_FORCE_SOUND"] = "1"
        app.launchEnvironment["ENGRAM_TEST_NO_NOTIFY"] = "1"
        app.launchEnvironment["ENGRAM_TEST_INSERT_DELAY"] = "45"
        app.launchEnvironment["TEST_AUTH_TOKEN"] = "mock-\(testUUID)"
        app.launchEnvironment["TEST_SYNC_CHANNEL"] = "perf-\(testUUID)"
        app.launchArguments += ["-subscription_status", "active"]
        app.launchArguments += ["-subscription_tier", "premium"]
    }

    override func tearDownWithError() throws {
        // Clean entire temp directory (contains local DB + sync/ subdirectory)
        let testDir = (localDbPath! as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: testDir)
    }

    // MARK: - Main Test

    func testPerfBottlenecks() throws {
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "App window not found")
        sleep(15) // simulation settle for ~4,000 merged nodes

        // Defocus search bar
        app.typeKey(.escape, modifierFlags: [])
        usleep(200_000)

        // ── Phase 0: Idle baseline ──
        takeScreenshot(name: "perf-00-idle")
        sleep(3)
        let idleFrameCount = currentFrameCount()

        // ── Phase 1: WASD camera movement ──
        holdKey(VK.w, duration: 1.0)
        holdKey(VK.s, duration: 1.0)
        holdKey(VK.a, duration: 1.0)
        holdKey(VK.d, duration: 1.0)
        sleep(1)
        takeScreenshot(name: "perf-01-wasd")

        // ── Phase 2: Vertical + look ──
        holdKey(VK.e, duration: 0.8)
        holdKey(VK.q, duration: 0.8)
        holdKey(VK.i, duration: 0.6)
        holdKey(VK.k, duration: 0.6)
        holdKey(VK.j, duration: 0.6)
        holdKey(VK.l, duration: 0.6)
        sleep(1)
        takeScreenshot(name: "perf-02-look")

        // ── Phase 3: Sprint ──
        holdKeys([VK.shift, VK.w], duration: 1.5)
        holdKeys([VK.shift, VK.d], duration: 1.0)
        sleep(1)
        takeScreenshot(name: "perf-03-sprint")

        // ── Phase 4: Teleport through all projects ──
        for p in 0..<6 {
            window.typeKey("t", modifierFlags: [])
            sleep(2)
            if p == 0 || p == 3 { takeScreenshot(name: "perf-04-teleport-\(p)") }
        }

        // ── Phase 4b: Sustained in-cluster movement (stress: proximity tones + edge hums) ──
        // Teleport lands inside a cluster. Dolly in close, then orbit around.
        // This puts many nodes within maxDistance=300, stressing ProximityTonePool rescan.
        window.typeKey("t", modifierFlags: [])
        sleep(2)
        holdKey(VK.w, duration: 2.0)   // dolly deep into cluster
        holdKey(VK.j, duration: 1.5)   // orbit left
        holdKey(VK.l, duration: 1.5)   // orbit right
        holdKey(VK.w, duration: 1.0)   // push deeper
        holdKey(VK.i, duration: 0.8)   // look up through nodes
        holdKey(VK.k, duration: 0.8)   // look down
        holdKey(VK.a, duration: 1.0)   // strafe left through cluster
        holdKey(VK.d, duration: 1.0)   // strafe right
        holdKey(VK.s, duration: 1.5)   // pull back out
        sleep(1)
        takeScreenshot(name: "perf-04b-in-cluster")

        // ── Phase 5: Node selection ──
        let center = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()
        sleep(1)
        holdKey(VK.w, duration: 0.8) // move with selection
        holdKey(VK.j, duration: 0.5)
        sleep(1)
        takeScreenshot(name: "perf-05-selection")

        // Deselect
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.05))
        corner.tap()
        sleep(1)

        // ── Phase 6: Recall glow ──
        let recallIds = Array(localIds.prefix(5))
        triggerRecall(at: localDbPath, globalIds: recallIds)
        sleep(3)
        takeScreenshot(name: "perf-06-glow")

        // ── Phase 7: Movement during glow (stress: glow + camera + render) ──
        holdKey(VK.w, duration: 1.0)
        holdKey(VK.j, duration: 0.5)
        sleep(2)

        // ── Phase 7b: Sustained insert/delete churn with camera movement ──
        // Simulates real usage: memories being stored/deleted while user navigates.
        // Every 2s for 10 rounds: insert 3, delete 3 (steady state node count).
        var churnIds: [UUID] = []
        let churnProjects = ["Engram", "Lattice", "canary-sdk-ios", "global"]
        for round in 0..<10 {
            let project = churnProjects[round % churnProjects.count]
            let newIds = insertMemories(at: localDbPath, project: project, count: 3)
            churnIds.append(contentsOf: newIds)
            // Delete the oldest 3 churn IDs if we have enough
            if churnIds.count >= 6 {
                let toDelete = Array(churnIds.prefix(3))
                deleteMemories(at: localDbPath, globalIds: toDelete)
                churnIds.removeFirst(3)
            }
            // Camera movement during churn (~1s of movement + 1s idle = ~2s per round)
            if round % 2 == 0 {
                holdKey(VK.w, duration: 1.0)
            } else {
                holdKey(VK.j, duration: 1.0)
            }
            sleep(1)
        }
        // Clean up remaining churn IDs
        if !churnIds.isEmpty {
            deleteMemories(at: localDbPath, globalIds: churnIds)
        }
        sleep(1)
        takeScreenshot(name: "perf-07b-churn")

        // ── Phase 8: Wait for insert at ~45s from launch ──
        // (ENGRAM_TEST_INSERT_DELAY=45)
        sleep(8)
        takeScreenshot(name: "perf-08-post-insert")

        // ── Phase 9: Live memory insertion (stress: observer + atlas regen + sim wake) ──
        let insertedIds = insertMemories(at: localDbPath, project: "Engram", count: 10)
        sleep(2)
        holdKey(VK.w, duration: 0.5) // camera movement during settle
        sleep(2)
        takeScreenshot(name: "perf-09-live-insert")

        // ── Phase 10: Live memory deletion ──
        deleteMemories(at: localDbPath, globalIds: insertedIds)
        sleep(2)
        takeScreenshot(name: "perf-10-live-delete")

        // ── Phase 11: Sync toggle (project migration) ──
        toggleSyncConfig(at: localDbPath, project: "Lattice", policy: .sync)
        sleep(3)
        takeScreenshot(name: "perf-11a-sync-on")

        // Toggle back to local
        toggleSyncConfig(at: localDbPath, project: "Lattice", policy: .local)
        sleep(3)
        takeScreenshot(name: "perf-11b-sync-off")

        // ── Phase 12: Mutation DURING migration ──
        // Start migration, then immediately insert + delete while it's in progress
        toggleSyncConfig(at: localDbPath, project: "canary-sdk-ios", policy: .sync)
        usleep(200_000)  // 200ms into migration
        insertMemories(at: localDbPath, project: "canary-sdk-ios", count: 5)
        usleep(200_000)
        deleteMemories(at: localDbPath, globalIds: Array(localIds[130..<135])) // delete some canary nodes
        sleep(3)
        takeScreenshot(name: "perf-12a-mutate-during-migration")

        // Toggle back with rapid insert
        toggleSyncConfig(at: localDbPath, project: "canary-sdk-ios", policy: .local)
        usleep(100_000)
        insertMemories(at: localDbPath, project: "Lattice", count: 5)
        sleep(3)
        takeScreenshot(name: "perf-12b-reverse-with-insert")

        // ── Phase 13: Rapid teleport stress ──
        for _ in 0..<5 {
            window.typeKey("t", modifierFlags: [])
            usleep(400_000)
        }
        sleep(2)
        takeScreenshot(name: "perf-13-rapid-teleport")

        // ── Phase 14: Galaxy hop with camera movement ──
        window.typeKey("[", modifierFlags: [])
        sleep(1)
        holdKey(VK.w, duration: 1.0)
        holdKey(VK.j, duration: 0.5)
        window.typeKey("]", modifierFlags: [])
        sleep(1)
        holdKey(VK.w, duration: 1.0)
        takeScreenshot(name: "perf-14-galaxy-hop")

        // ── Phase 15: Final idle ──
        sleep(5)
        takeScreenshot(name: "perf-15-final")

        // ═══════════════════════════════════════
        //   ANALYSIS
        // ═══════════════════════════════════════

        var report = BottleneckReport()

        report.addSection(try RealityFrameReport(path: frameStatsPath).section())
        report.addSection(analyzeDrawPipeline())
        report.addSection(analyzeFlushTiming())
        report.addSection(analyzePackTiming())
        report.addSection(analyzeMergeTiming())
        report.addSection(analyzeAtlasTiming())
        report.addSection(analyzeGlowLog())
        report.addSection(analyzeCenterLog())
        report.addSection(analyzeMigrationTiming())
        report.addSection(analyzeLabelDiag())
        report.addSection(analyzeAudioTiming())
        report.addSection(analyzeSwiftUIJitter())

        report.printSummary()

        // Hard assertion: p95 frame time under budget
        let p95 = try XCTUnwrap(report.metalP95, "Missing RealityKit performance data")
        do {
            XCTAssertLessThan(p95, 33.0,
                "p95 frame time \(String(format: "%.1f", p95))ms exceeds 30fps budget (33ms)")
        }
    }

    // MARK: - Frame Count

    private func currentFrameCount() -> Int {
        let path = frameStatsPath
        guard let data = FileManager.default.contents(atPath: path),
              let csv = String(data: data, encoding: .utf8) else { return 0 }
        return csv.components(separatedBy: "\n").count - 2 // header + trailing newline
    }

    // MARK: - Metal Frame Timing

    private func analyzeMetalFrames() -> BottleneckSection {
        var section = BottleneckSection(title: "METAL FRAME TIMING")
        let path = "/tmp/metal-frame-timing.csv"
        guard let data = FileManager.default.contents(atPath: path),
              let csv = String(data: data, encoding: .utf8) else {
            section.addLine("[No data]")
            return section
        }

        // CSV: frame,dt_ms,wall_dt_ms,total_ms,drain_ms,sim_ms,mascot_ms,nodes_ms,edges_ms,neb_ms,labels_ms,flow_ms,node_count,edge_count,reason,audio_ms
        let lines = csv.components(separatedBy: "\n").dropFirst().filter { !$0.isEmpty }
        guard !lines.isEmpty else { section.addLine("[Empty]"); return section }

        struct Frame {
            let idx: Int, dt: Double, wallDt: Double, total: Double
            let drain: Double, sim: Double, mascot: Double, nodes: Double, edges: Double
            let neb: Double, labels: Double, flow: Double
            let nodeCount: Int, edgeCount: Int, reason: String
            let audio: Double
        }
        var frames: [Frame] = []
        for (i, line) in lines.enumerated() {
            let c = line.components(separatedBy: ",")
            guard c.count >= 15 else { continue }
            frames.append(Frame(
                idx: i, dt: Double(c[1]) ?? 0, wallDt: Double(c[2]) ?? 0,
                total: Double(c[3]) ?? 0, drain: Double(c[4]) ?? 0,
                sim: Double(c[5]) ?? 0, mascot: Double(c[6]) ?? 0,
                nodes: Double(c[7]) ?? 0, edges: Double(c[8]) ?? 0, neb: Double(c[9]) ?? 0,
                labels: Double(c[10]) ?? 0, flow: Double(c[11]) ?? 0,
                nodeCount: Int(c[12]) ?? 0, edgeCount: Int(c[13]) ?? 0,
                reason: c[14].trimmingCharacters(in: .whitespacesAndNewlines),
                audio: c.count > 15 ? (Double(c[15].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) : 0))
        }

        let totals = frames.map(\.total).sorted()
        let wallDts = frames.filter { $0.wallDt > 0 }.map(\.wallDt).sorted()
        let p50 = pct(totals, 0.50), p95 = pct(totals, 0.95), p99 = pct(totals, 0.99)
        let wp50 = pct(wallDts, 0.50), wp95 = pct(wallDts, 0.95), wp99 = pct(wallDts, 0.99)
        section.metalP95 = wp95

        let maxNodeCount = frames.map(\.nodeCount).max() ?? 0
        let maxEdgeCount = frames.map(\.edgeCount).max() ?? 0

        section.addLine("Frames: \(frames.count)  Nodes: \(maxNodeCount)  Edges: \(maxEdgeCount)")
        section.addLine("total_ms:  p50=\(f(p50))  p95=\(f(p95))  p99=\(f(p99))  worst=\(f(totals.last ?? 0))")
        section.addLine("wall_dt:   p50=\(f(wp50))  p95=\(f(wp95))  p99=\(f(wp99))  worst=\(f(wallDts.last ?? 0))")

        // Stalls
        let stalls25 = frames.filter { $0.wallDt > 25 }.count
        let stalls50 = frames.filter { $0.wallDt > 50 }.count
        section.addLine("Stalls: >25ms=\(stalls25)  >50ms=\(stalls50)")

        // Reason breakdown
        var reasons: [String: [Frame]] = [:]
        for fr in frames { reasons[fr.reason, default: []].append(fr) }
        section.addLine("")
        section.addLine("By reason:")
        for (reason, rFrames) in reasons.sorted(by: { $0.value.count > $1.value.count }) {
            let rTotals = rFrames.map(\.total).sorted()
            let rp50 = pct(rTotals, 0.50)
            let rp95 = pct(rTotals, 0.95)
            section.addLine("  \(reason.padding(toLength: 8, withPad: " ", startingAt: 0)) \(String(format: "%5d", rFrames.count)) frames  p50=\(f(rp50))  p95=\(f(rp95))")
        }

        // Per-phase averages (identify which phase is expensive)
        let simFrames = reasons["sim"] ?? []
        if !simFrames.isEmpty {
            section.addLine("")
            section.addLine("Sub-phase averages (sim frames only):")
            let phases: [(String, KeyPath<Frame, Double>)] = [
                ("drain", \.drain), ("sim", \.sim), ("mascot", \.mascot), ("nodes", \.nodes),
                ("edges", \.edges), ("nebulae", \.neb), ("labels", \.labels), ("flow", \.flow),
                ("audio", \.audio)
            ]
            var bottlenecks: [(String, Double)] = []
            for (name, kp) in phases {
                let vals = simFrames.map { $0[keyPath: kp] }
                let avg = vals.reduce(0, +) / Double(vals.count)
                let max = vals.max() ?? 0
                let sorted = vals.sorted()
                let sp95 = pct(sorted, 0.95)
                section.addLine("  \(name.padding(toLength: 10, withPad: " ", startingAt: 0)) avg=\(f(avg))  p95=\(f(sp95))  worst=\(f(max))")
                bottlenecks.append((name, sp95))
            }
            // Rank bottlenecks
            let ranked = bottlenecks.sorted { $0.1 > $1.1 }
            section.addLine("")
            section.addLine("BOTTLENECK RANKING (by p95):")
            for (i, (name, val)) in ranked.enumerated() {
                let bar = String(repeating: "█", count: min(Int(val / 0.1), 40))
                section.addLine("  #\(i+1) \(name.padding(toLength: 10, withPad: " ", startingAt: 0)) \(f(val))ms \(bar)")
            }
        }

        // Worst 10 frames
        let worst = frames.sorted { $0.total > $1.total }.prefix(10)
        section.addLine("")
        section.addLine("Worst 10 frames:")
        section.addLine("  frame  wall_dt  total  drain   sim   nodes edges labels  neb  audio  reason")
        for fr in worst {
            section.addLine(String(format: "  %5d %7.1f %6.1f %5.1f %5.1f %6.1f %5.1f %6.1f %5.1f %5.1f  %@",
                fr.idx, fr.wallDt, fr.total, fr.drain, fr.sim, fr.nodes, fr.edges, fr.labels, fr.neb, fr.audio, fr.reason))
        }

        return section
    }

    // MARK: - Draw Pipeline

    private func analyzeDrawPipeline() -> BottleneckSection {
        var section = BottleneckSection(title: "DRAW PIPELINE")
        let path = "/tmp/draw-timing.csv"
        guard let data = FileManager.default.contents(atPath: path),
              let csv = String(data: data, encoding: .utf8) else {
            section.addLine("[No data]")
            return section
        }

        let lines = csv.components(separatedBy: "\n").dropFirst().filter { !$0.isEmpty }
        guard !lines.isEmpty else { section.addLine("[Empty]"); return section }

        // CSV: frame,total_draw_ms,callback_ms,wait_ms,encode_ms
        var totals: [Double] = [], callbacks: [Double] = []
        var waits: [Double] = [], encodes: [Double] = []
        for line in lines {
            let c = line.components(separatedBy: ",")
            guard c.count >= 5 else { continue }
            totals.append(Double(c[1]) ?? 0)
            callbacks.append(Double(c[2]) ?? 0)
            waits.append(Double(c[3]) ?? 0)
            encodes.append(Double(c[4]) ?? 0)
        }

        let st = totals.sorted(), sc = callbacks.sorted(), sw = waits.sorted(), se = encodes.sorted()
        section.addLine("Draws: \(lines.count)")
        section.addLine("total:    p50=\(f(pct(st, 0.5)))  p95=\(f(pct(st, 0.95)))  worst=\(f(st.last ?? 0))")
        section.addLine("callback: p50=\(f(pct(sc, 0.5)))  p95=\(f(pct(sc, 0.95)))  worst=\(f(sc.last ?? 0))")
        section.addLine("wait:     p50=\(f(pct(sw, 0.5)))  p95=\(f(pct(sw, 0.95)))  worst=\(f(sw.last ?? 0))")
        section.addLine("encode:   p50=\(f(pct(se, 0.5)))  p95=\(f(pct(se, 0.95)))  worst=\(f(se.last ?? 0))")

        let badWaits = waits.filter { $0 > 5 }.count
        if badWaits > 0 { section.addLine("⚠️ GPU wait >5ms: \(badWaits) frames") }
        return section
    }

    // MARK: - Flush Timing

    private func analyzeFlushTiming() -> BottleneckSection {
        var section = BottleneckSection(title: "FLUSH TIMING (main-thread observer batches)")
        let path = "/tmp/flush-timing.csv"
        guard let data = FileManager.default.contents(atPath: path),
              let csv = String(data: data, encoding: .utf8) else {
            section.addLine("[No data — no observer flushes during test]")
            return section
        }

        let lines = csv.components(separatedBy: "\n").dropFirst().filter { !$0.isEmpty }
        guard !lines.isEmpty else { section.addLine("[Empty]"); return section }

        var flushMs: [Double] = []
        var batchSizes: [Int] = []
        for line in lines {
            let c = line.components(separatedBy: ",")
            guard c.count >= 4 else { continue }
            flushMs.append(Double(c[3]) ?? 0)
            batchSizes.append(Int(c[2]) ?? 0)
        }

        let sorted = flushMs.sorted()
        section.addLine("Flush events: \(lines.count)")
        section.addLine("flush_ms:   p50=\(f(pct(sorted, 0.5)))  p95=\(f(pct(sorted, 0.95)))  worst=\(f(sorted.last ?? 0))")
        section.addLine("batch_size: avg=\(String(format: "%.0f", batchSizes.isEmpty ? 0 : Double(batchSizes.reduce(0,+)) / Double(batchSizes.count)))  max=\(batchSizes.max() ?? 0)")

        let heavyFlushes = flushMs.filter { $0 > 5 }
        if !heavyFlushes.isEmpty {
            section.addLine("⚠️ Heavy flushes (>5ms): \(heavyFlushes.count) — worst=\(f(heavyFlushes.max()!))")
        }
        return section
    }

    // MARK: - Pack Timing

    private func analyzePackTiming() -> BottleneckSection {
        var section = BottleneckSection(title: "PACK NODE INSTANCES")
        let path = "/tmp/pack-timing.csv"
        guard let data = FileManager.default.contents(atPath: path),
              let csv = String(data: data, encoding: .utf8) else {
            section.addLine("[No data]")
            return section
        }

        let lines = csv.components(separatedBy: "\n").dropFirst().filter { !$0.isEmpty }
        guard !lines.isEmpty else { section.addLine("[Empty]"); return section }

        // CSV: timestamp,precompute_ms,loop_ms,total_ms,node_count
        var precomputes: [Double] = [], loops: [Double] = [], packTotals: [Double] = []
        for line in lines {
            let c = line.components(separatedBy: ",")
            guard c.count >= 5 else { continue }
            precomputes.append(Double(c[1]) ?? 0)
            loops.append(Double(c[2]) ?? 0)
            packTotals.append(Double(c[3]) ?? 0)
        }

        let sp = precomputes.sorted(), sl = loops.sorted(), st = packTotals.sorted()
        section.addLine("Pack calls: \(lines.count)")
        section.addLine("precompute: p50=\(f(pct(sp, 0.5)))  p95=\(f(pct(sp, 0.95)))  worst=\(f(sp.last ?? 0))")
        section.addLine("loop:       p50=\(f(pct(sl, 0.5)))  p95=\(f(pct(sl, 0.95)))  worst=\(f(sl.last ?? 0))")
        section.addLine("total:      p50=\(f(pct(st, 0.5)))  p95=\(f(pct(st, 0.95)))  worst=\(f(st.last ?? 0))")
        return section
    }

    // MARK: - Merge Timing

    private func analyzeMergeTiming() -> BottleneckSection {
        var section = BottleneckSection(title: "GALAXY REGISTRY MERGE")
        let path = "/tmp/merge-timing.csv"
        guard let data = FileManager.default.contents(atPath: path),
              let csv = String(data: data, encoding: .utf8) else {
            section.addLine("[No data — merge below 0.5ms threshold or single galaxy]")
            return section
        }

        let lines = csv.components(separatedBy: "\n").dropFirst().filter { !$0.isEmpty }
        guard !lines.isEmpty else { section.addLine("[Empty]"); return section }

        section.addLine("Merge events (>0.5ms): \(lines.count)")
        for line in lines.prefix(10) {
            section.addLine("  \(line)")
        }
        if lines.count > 10 { section.addLine("  ... (\(lines.count - 10) more)") }
        return section
    }

    // MARK: - Atlas Timing

    private func analyzeAtlasTiming() -> BottleneckSection {
        var section = BottleneckSection(title: "LABEL ATLAS REGEN")
        let path = "/tmp/atlas-timing.log"
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            section.addLine("[No data — no atlas regens during test]")
            return section
        }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        section.addLine("Atlas regens: \(lines.count)")
        for line in lines { section.addLine("  \(line)") }
        return section
    }

    // MARK: - Glow Log

    private func analyzeGlowLog() -> BottleneckSection {
        var section = BottleneckSection(title: "RECALL GLOW EVENTS")
        let events = parseGlowLog()
        if events.isEmpty {
            section.addLine("[No glow events]")
            return section
        }

        section.addLine("Total: \(events.count)")

        var nodeGlowCounts: [String: Int] = [:]
        var galaxyCounts: [String: Int] = [:]
        for event in events {
            nodeGlowCounts[event.nodeLabel, default: 0] += 1
            galaxyCounts[event.galaxy, default: 0] += 1
        }

        for (galaxy, count) in galaxyCounts.sorted(by: { $0.key < $1.key }) {
            section.addLine("  \(galaxy): \(count)")
        }

        let repeaters = nodeGlowCounts.filter { $0.value > 1 }
        if !repeaters.isEmpty {
            section.addLine("⚠️ Repeated glows: \(repeaters.count) nodes")
            for (label, count) in repeaters.sorted(by: { $0.value > $1.value }).prefix(5) {
                section.addLine("  \(label.prefix(30)): \(count)x")
            }
        }

        let refires = events.filter(\.alreadyGlowing).count
        if refires > 0 { section.addLine("Re-fires: \(refires)") }
        return section
    }

    // MARK: - Center Log

    private func analyzeCenterLog() -> BottleneckSection {
        var section = BottleneckSection(title: "CENTER-ON-GRAPH")
        let path = "/tmp/center-log.csv"
        guard let data = FileManager.default.contents(atPath: path),
              let csv = String(data: data, encoding: .utf8) else {
            section.addLine("[No center events]")
            return section
        }

        let lines = csv.components(separatedBy: "\n").dropFirst().filter { !$0.isEmpty }
        section.addLine("Center events: \(lines.count)")

        let withKeys = lines.filter { line in
            let cols = line.components(separatedBy: ",")
            return cols.count >= 3 && (Int(cols[2]) ?? 0) > 0
        }
        if !withKeys.isEmpty {
            section.addLine("⚠️ Center fired with keys held: \(withKeys.count)")
        }
        return section
    }

    // MARK: - Migration Timing

    private func analyzeMigrationTiming() -> BottleneckSection {
        var section = BottleneckSection(title: "GALAXY MIGRATION (sync toggles)")
        let path = "/tmp/galaxy-migration.csv"
        guard let data = FileManager.default.contents(atPath: path),
              let csv = String(data: data, encoding: .utf8) else {
            section.addLine("[No data — no sync toggles occurred]")
            return section
        }

        let lines = csv.components(separatedBy: "\n").dropFirst().filter { !$0.isEmpty }
        guard !lines.isEmpty else { section.addLine("[Empty]"); return section }

        // CSV: timestamp,action,project,direction,src,dst,node_count,edge_count,position_count,ms
        section.addLine("Migration events: \(lines.count)")
        section.addLine("")
        section.addLine("action              project             direction           nodes edges  pos    ms")

        var totalMigrateMs: Double = 0
        var migrateCount = 0

        for line in lines {
            let c = line.components(separatedBy: ",")
            guard c.count >= 10 else { continue }
            let action = c[1].padding(toLength: 19, withPad: " ", startingAt: 0)
            let project = c[2].padding(toLength: 19, withPad: " ", startingAt: 0)
            let direction = c[3].padding(toLength: 19, withPad: " ", startingAt: 0)
            let nodes = c[6].padding(toLength: 5, withPad: " ", startingAt: 0)
            let edges = c[7].padding(toLength: 5, withPad: " ", startingAt: 0)
            let positions = c[8].padding(toLength: 5, withPad: " ", startingAt: 0)
            let ms = c[9].trimmingCharacters(in: .whitespacesAndNewlines)
            section.addLine("\(action) \(project) \(direction) \(nodes) \(edges) \(positions) \(ms.padding(toLength: 8, withPad: " ", startingAt: 0))")

            if c[1] == "migrate" || c[1] == "migrate_out" || c[1] == "load_into" {
                if let msVal = Double(ms) { totalMigrateMs += msVal; migrateCount += 1 }
            }
        }

        if migrateCount > 0 {
            section.addLine("")
            section.addLine("Total migration work: \(String(format: "%.1f", totalMigrateMs))ms across \(migrateCount) operations")
            let heavyOps = lines.filter { line in
                let c = line.components(separatedBy: ",")
                return c.count >= 10 && (Double(c[9].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 10
            }
            if !heavyOps.isEmpty {
                section.addLine("⚠️ Heavy migrations (>10ms): \(heavyOps.count)")
            }
        }
        return section
    }

    // MARK: - Label Diagnostics

    private func analyzeLabelDiag() -> BottleneckSection {
        var section = BottleneckSection(title: "LABEL FLICKER DIAGNOSTICS")
        let path = "/tmp/label-diag.csv"
        guard let data = FileManager.default.contents(atPath: path),
              let csv = String(data: data, encoding: .utf8) else {
            section.addLine("[No data — label-diag.csv not found]")
            return section
        }

        // frame,positions,atlasRects,missingRects,instances,atlasRegen,depthRange,minDepth,maxDepth,camX,camY,camZ,projLabels,topicLabels,galaxyLabels,pendingRegen,isGenerating
        let lines = csv.components(separatedBy: "\n").dropFirst().filter { !$0.isEmpty }
        guard !lines.isEmpty else { section.addLine("[Empty]"); return section }

        var instanceCounts: [Int] = []
        var missingRectCounts: [Int] = []
        var depthRanges: [Double] = []
        var atlasRegenFrames: [Int] = []
        var pendingRegenFrames: [Int] = []
        var generatingFrames: [Int] = []
        var instanceDrops: [(frame: Int, from: Int, to: Int)] = []
        var prevInstances = -1
        var frames: [Int] = []
        var galaxyLabelCounts: [Int] = []

        for line in lines {
            let c = line.components(separatedBy: ",")
            guard c.count >= 17 else { continue }
            let frame = Int(c[0]) ?? 0
            let missing = Int(c[3]) ?? 0
            let instances = Int(c[4]) ?? 0
            let atlasRegen = Int(c[5]) ?? 0
            let depthRange = Double(c[6]) ?? 0
            let pendingRegen = Int(c[15]) ?? 0
            let isGenerating = Int(c[16]) ?? 0
            let galaxyLabels = Int(c[14]) ?? 0

            frames.append(frame)
            instanceCounts.append(instances)
            missingRectCounts.append(missing)
            depthRanges.append(depthRange)
            galaxyLabelCounts.append(galaxyLabels)
            if atlasRegen == 1 { atlasRegenFrames.append(frame) }
            if pendingRegen == 1 { pendingRegenFrames.append(frame) }
            if isGenerating == 1 { generatingFrames.append(frame) }

            if prevInstances > 0 && instances < prevInstances && (prevInstances - instances) > 2 {
                instanceDrops.append((frame: frame, from: prevInstances, to: instances))
            }
            prevInstances = instances
        }

        let total = Double(lines.count)
        let avgInst = instanceCounts.isEmpty ? 0.0 : Double(instanceCounts.reduce(0, +)) / total
        let minInst = instanceCounts.min() ?? 0
        let maxInst = instanceCounts.max() ?? 0
        let avgMissing = missingRectCounts.isEmpty ? 0.0 : Double(missingRectCounts.reduce(0, +)) / total
        let maxMissing = missingRectCounts.max() ?? 0
        let framesWithMissing = missingRectCounts.filter { $0 > 0 }.count

        section.addLine("Frames: \(lines.count)")
        section.addLine("Instances: avg=\(f(avgInst))  min=\(minInst)  max=\(maxInst)")
        section.addLine("Instance drops (>2): \(instanceDrops.count) frames")
        section.addLine("Missing atlas rects: avg=\(f(avgMissing))  max=\(maxMissing)  frames_with_missing=\(framesWithMissing)")
        let maxGalaxyLabels = galaxyLabelCounts.max() ?? 0
        section.addLine("Galaxy labels: max=\(maxGalaxyLabels)")
        section.addLine("Atlas regens: \(atlasRegenFrames.count)")
        section.addLine("Pending regen frames: \(pendingRegenFrames.count)")
        section.addLine("Atlas generating frames: \(generatingFrames.count)")

        let sortedDepth = depthRanges.sorted()
        let p5 = pct(sortedDepth, 0.05)
        let p50 = pct(sortedDepth, 0.50)
        let p95 = pct(sortedDepth, 0.95)
        section.addLine("Depth range: p5=\(f(p5))  p50=\(f(p50))  p95=\(f(p95))")

        // Jitter: frames where instance count changed from previous
        var jitter = 0
        for i in 1..<instanceCounts.count {
            if instanceCounts[i] != instanceCounts[i - 1] { jitter += 1 }
        }
        let jitterPct = total > 1 ? Double(jitter) / (total - 1) * 100 : 0
        section.addLine("Instance jitter: \(jitter) frames (\(String(format: "%.1f", jitterPct))%)")

        // Correlation: drops near atlas regen
        let regenSet = Set(atlasRegenFrames)
        let dropsNearRegen = instanceDrops.filter { drop in
            regenSet.contains(where: { abs(drop.frame - $0) <= 5 })
        }
        section.addLine("Drops near atlas regen (±5 frames): \(dropsNearRegen.count)/\(instanceDrops.count)")

        if !instanceDrops.isEmpty {
            section.addLine("")
            section.addLine("Instance drops detail:")
            for drop in instanceDrops.prefix(20) {
                section.addLine("  frame=\(drop.frame) \(drop.from)→\(drop.to) (dropped \(drop.from - drop.to))")
            }
        }

        if !atlasRegenFrames.isEmpty {
            section.addLine("")
            section.addLine("Atlas regen at frames: \(atlasRegenFrames)")
        }

        if framesWithMissing > 0 {
            section.addLine("")
            let worstMissing = zip(frames, missingRectCounts)
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
                .prefix(10)
            section.addLine("Worst missing-rect frames:")
            for (fr, cnt) in worstMissing {
                section.addLine("  frame=\(fr) missing=\(cnt)")
            }
        }

        // Flag potential flicker causes
        if instanceDrops.count > 5 {
            section.addLine("⚠️ Frequent instance drops (\(instanceDrops.count)) — likely flicker source")
        }
        if framesWithMissing > Int(total * 0.1) {
            section.addLine("⚠️ >10% frames with missing atlas rects — atlas/position desync")
        }
        if atlasRegenFrames.count > 3 {
            section.addLine("⚠️ Multiple atlas regens (\(atlasRegenFrames.count)) — may cause UV mismatch flicker")
        }

        return section
    }

    // MARK: - SwiftUI Jitter Analysis

    private func analyzeSwiftUIJitter() -> BottleneckSection {
        var section = BottleneckSection(title: "SWIFTUI JITTER")

        // Parse jitter CSV
        let jitterPath = "/tmp/swiftui-jitter.csv"
        guard let jitterData = FileManager.default.contents(atPath: jitterPath),
              let jitterCsv = String(data: jitterData, encoding: .utf8) else {
            section.addLine("[No jitter data]")
            return section
        }

        let jitterLines = jitterCsv.components(separatedBy: "\n").dropFirst().filter { !$0.isEmpty }
        guard jitterLines.count > 1 else { section.addLine("[Empty]"); return section }

        // CSV: frame,wall_dt_ms,total_ms,sim_ms,mascot_ms,nodes_ms,edges_ms,labels_ms,skipped,reason,
        //      selection_cb,reticle_cb,teleport_cb,positions_changed,geometry_changed,camera_moving,mascot_active,body_eval_count
        struct JFrame {
            let frame: Int, wallDt: Double, totalMs: Double
            let skipped: Bool, reason: String
            let selectionCb: Bool, reticleCb: Bool, teleportCb: Bool
            let positionsChanged: Bool, geometryChanged: Bool, cameraMoving: Bool
            let bodyEvalCount: UInt64
        }

        var frames: [JFrame] = []
        for line in jitterLines {
            let c = line.components(separatedBy: ",")
            guard c.count >= 18 else { continue }
            frames.append(JFrame(
                frame: Int(c[0]) ?? 0,
                wallDt: Double(c[1]) ?? 0,
                totalMs: Double(c[2]) ?? 0,
                skipped: (Int(c[8]) ?? 0) != 0,
                reason: c[9],
                selectionCb: (Int(c[10]) ?? 0) != 0,
                reticleCb: (Int(c[11]) ?? 0) != 0,
                teleportCb: (Int(c[12]) ?? 0) != 0,
                positionsChanged: (Int(c[13]) ?? 0) != 0,
                geometryChanged: (Int(c[14]) ?? 0) != 0,
                cameraMoving: (Int(c[15]) ?? 0) != 0,
                bodyEvalCount: UInt64(c[17].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            ))
        }

        section.addLine("Frames: \(frames.count)")

        // Wall dt percentiles (skip first frame which is 0)
        let wallDts = frames.dropFirst().map(\.wallDt).sorted()
        let n = wallDts.count
        if n > 0 {
            section.addLine("wall_dt: p50=\(f(pct(wallDts, 0.5)))  p95=\(f(pct(wallDts, 0.95)))  p99=\(f(pct(wallDts, 0.99)))  worst=\(f(wallDts.last ?? 0))")
        }

        // Jitter counts
        let jitter20 = frames.filter { $0.wallDt > 20 }.count
        let jitter33 = frames.filter { $0.wallDt > 33 }.count
        let jitter50 = frames.filter { $0.wallDt > 50 }.count
        section.addLine("Jitter: >20ms=\(jitter20)  >33ms=\(jitter33)  >50ms=\(jitter50)")

        // Body eval analysis
        let totalBodyEvals: UInt64
        if let last = frames.last, let first = frames.first {
            totalBodyEvals = last.bodyEvalCount - first.bodyEvalCount
        } else {
            totalBodyEvals = 0
        }
        section.addLine("SwiftUI body evals: \(totalBodyEvals) total across \(frames.count) frames")

        // Frames where body re-evaluated
        var evalFrames: [(frame: Int, wallDt: Double, evals: UInt64)] = []
        for i in 1..<frames.count {
            let delta = frames[i].bodyEvalCount - frames[i - 1].bodyEvalCount
            if delta > 0 {
                evalFrames.append((frames[i].frame, frames[i].wallDt, delta))
            }
        }
        if !evalFrames.isEmpty {
            let avgWallWithEval = evalFrames.map(\.wallDt).reduce(0, +) / Double(evalFrames.count)
            let noEvalWalls = (1..<frames.count).compactMap { i -> Double? in
                let delta = frames[i].bodyEvalCount - frames[i - 1].bodyEvalCount
                return delta == 0 ? frames[i].wallDt : nil
            }
            let avgWallNoEval = noEvalWalls.isEmpty ? 0 : noEvalWalls.reduce(0, +) / Double(noEvalWalls.count)
            section.addLine("Body eval frames: \(evalFrames.count)  avg_wall_dt=\(f(avgWallWithEval))ms (vs \(f(avgWallNoEval))ms without)")

            if avgWallWithEval > avgWallNoEval * 1.5 {
                section.addLine("⚠️ Body re-evals correlate with \(String(format: "%.0f", (avgWallWithEval / avgWallNoEval - 1) * 100))% higher wall_dt — SwiftUI layout is a jitter source")
            }
        }

        // Callback fires
        let selCount = frames.filter(\.selectionCb).count
        let retCount = frames.filter(\.reticleCb).count
        let telCount = frames.filter(\.teleportCb).count
        if selCount + retCount + telCount > 0 {
            section.addLine("Callbacks: selection=\(selCount) reticle=\(retCount) teleport=\(telCount)")
        }

        // Worst jitter frames detail
        let worstJitter = frames.filter { $0.wallDt > 33 }.sorted { $0.wallDt > $1.wallDt }
        if !worstJitter.isEmpty {
            section.addLine("")
            section.addLine("Worst jitter frames (>33ms):")
            for fr in worstJitter.prefix(15) {
                let evalDelta: UInt64
                if let idx = frames.firstIndex(where: { $0.frame == fr.frame }), idx > 0 {
                    evalDelta = frames[idx].bodyEvalCount - frames[idx - 1].bodyEvalCount
                } else {
                    evalDelta = 0
                }
                section.addLine(String(format: "  frame %5d: wall_dt=%6.1fms total=%6.1fms eval=%d sel=%d ret=%d tel=%d reason=%@",
                    fr.frame, fr.wallDt, fr.totalMs, evalDelta,
                    fr.selectionCb ? 1 : 0, fr.reticleCb ? 1 : 0, fr.teleportCb ? 1 : 0, fr.reason))
            }
        }

        return section
    }

    // MARK: - Audio Timing

    private func analyzeAudioTiming() -> BottleneckSection {
        var section = BottleneckSection(title: "AUDIO SUBSYSTEM BREAKDOWN")
        let path = "/tmp/audio-timing.csv"
        guard let data = FileManager.default.contents(atPath: path),
              let csv = String(data: data, encoding: .utf8) else {
            section.addLine("[No data — audio not active or instrumentation not enabled]")
            return section
        }

        // CSV: frame,listener_ms,edge_ms,proximity_ms,events_ms,mascot_ms,total_ms
        let lines = csv.components(separatedBy: "\n").dropFirst().filter { !$0.isEmpty }
        guard !lines.isEmpty else { section.addLine("[Empty]"); return section }

        var listeners: [Double] = [], edges: [Double] = [], proximities: [Double] = []
        var events: [Double] = [], mascots: [Double] = [], totals: [Double] = []

        for line in lines {
            let c = line.components(separatedBy: ",")
            guard c.count >= 7 else { continue }
            listeners.append(Double(c[1]) ?? 0)
            edges.append(Double(c[2]) ?? 0)
            proximities.append(Double(c[3]) ?? 0)
            events.append(Double(c[4]) ?? 0)
            mascots.append(Double(c[5]) ?? 0)
            totals.append(Double(c[6]) ?? 0)
        }

        let st = totals.sorted()
        section.addLine("Audio ticks: \(lines.count)")
        section.addLine("total:     p50=\(f(pct(st, 0.5)))  p95=\(f(pct(st, 0.95)))  p99=\(f(pct(st, 0.99)))  worst=\(f(st.last ?? 0))")

        let phases: [(String, [Double])] = [
            ("listener", listeners), ("edge", edges), ("proximity", proximities),
            ("events", events), ("mascot", mascots)
        ]

        section.addLine("")
        var bottlenecks: [(String, Double)] = []
        for (name, vals) in phases {
            let sorted = vals.sorted()
            let avg = vals.reduce(0, +) / Double(max(vals.count, 1))
            let sp95 = pct(sorted, 0.95)
            let worst = sorted.last ?? 0
            section.addLine("  \(name.padding(toLength: 12, withPad: " ", startingAt: 0)) avg=\(f(avg))  p95=\(f(sp95))  worst=\(f(worst))")
            bottlenecks.append((name, sp95))
        }

        let ranked = bottlenecks.sorted { $0.1 > $1.1 }
        section.addLine("")
        section.addLine("AUDIO BOTTLENECK RANKING (by p95):")
        for (i, (name, val)) in ranked.enumerated() {
            let bar = String(repeating: "█", count: min(Int(val / 0.05), 40))
            section.addLine("  #\(i+1) \(name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(f(val))ms \(bar)")
        }

        // Worst 10 audio frames
        let indexed = totals.enumerated().sorted { $0.element > $1.element }.prefix(10)
        section.addLine("")
        section.addLine("Worst 10 audio frames:")
        section.addLine("  frame  total   listener  edge    prox    events  mascot")
        for (i, _) in indexed {
            section.addLine(String(format: "  %5d %7.2f %7.2f %7.2f %7.2f %7.2f %7.2f",
                i, totals[i], listeners[i], edges[i], proximities[i], events[i], mascots[i]))
        }

        return section
    }

    // MARK: - Local Formatting Aliases (delegate to shared helpers)

    private func f(_ v: Double) -> String { fmt(v) }
    private func pct(_ sorted: [Double], _ p: Double) -> Double { percentile(sorted, p) }
}

// MARK: - Sync Config Toggle Helper

/// Opens a separate Lattice connection and sets a project's sync policy.
/// The xproc notification triggers the app's GalaxyRegistry SyncConfig observer.
func toggleSyncConfig(at path: String, project: String, policy: SyncConfig.Policy) {
    let lattice = try! Lattice(
        Memory.self, Edge.self, SyncConfig.self,
        configuration: .init(
            fileURL: URL(fileURLWithPath: path),
            migration: engramMigrations
        )
    )

    let existing = lattice.objects(SyncConfig.self).first(where: { $0.project == project })
    if let existing {
        existing.policy = policy
        existing.updatedAt = Date()
    } else {
        try! lattice.add(SyncConfig(project: project, policy: policy))
    }
}
