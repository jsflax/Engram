import XCTest
import EngramKit
import Lattice

/// Profiles an isolated SQLite backup of ENGRAM_PERF_DB_SNAPSHOT at real scale.
/// The source is read-only; insertion tests never touch the user's live database.
///
/// Requires the Engram-UITesting scheme (ENGRAM_INSTRUMENTATION flag).
@MainActor
final class RealDBPerfTests: XCTestCase {
    let app = XCUIApplication()
    private var testDirectory: URL!
    private var databasePath: String!
    private var frameStatsPath: String { testDirectory.appendingPathComponent("frames.csv").path }

    private let csvPaths = [
        "/tmp/metal-frame-timing.csv",
        "/tmp/draw-timing.csv",
        "/tmp/pack-timing.csv",
        "/tmp/label-diag.csv",
        "/tmp/swiftui-jitter.csv",
        "/tmp/merge-timing.csv",
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let source = ProcessInfo.processInfo.environment["ENGRAM_PERF_DB_SNAPSHOT"] else {
            throw XCTSkip("Set ENGRAM_PERF_DB_SNAPSHOT to profile an isolated backup")
        }
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-real-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        databasePath = try makePerformanceDatabaseCopy(source: source, directory: testDirectory)
        app.launchEnvironment["CLAUDE_MEMORY_DB"] = databasePath
        app.launchEnvironment["ENGRAM_PERF_ISOLATED"] = "1"
        app.launchEnvironment["ENGRAM_FRAME_STATS"] = frameStatsPath
        for path in csvPaths { try? FileManager.default.removeItem(atPath: path) }
    }

    override func tearDownWithError() throws {
        app.terminate()
        if let testDirectory { try? FileManager.default.removeItem(at: testDirectory) }
    }

    // MARK: - Main Test

    func testRealDBPerf() throws {
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "App window not found")

        // Wait for initial data load + simulation settle
        sleep(20)

        // Defocus search bar
        app.typeKey(.escape, modifierFlags: [])
        usleep(200_000)

        // ── Phase 0: Idle baseline (simulation settled) ──
        takeScreenshot(name: "realdb-00-idle")
        sleep(3)

        // ── Phase 1: Camera movement (triggers full render pipeline) ──
        holdKey(VK.w, duration: 2.0)
        holdKey(VK.a, duration: 1.0)
        holdKey(VK.d, duration: 1.0)
        holdKey(VK.s, duration: 2.0)
        sleep(1)
        takeScreenshot(name: "realdb-01-wasd")

        // ── Phase 2: Look around (triggers label repacking) ──
        holdKey(VK.i, duration: 1.0)
        holdKey(VK.k, duration: 1.0)
        holdKey(VK.j, duration: 1.0)
        holdKey(VK.l, duration: 1.0)
        sleep(1)
        takeScreenshot(name: "realdb-02-look")

        // ── Phase 3: Sprint (maximum camera speed = max label/node work) ──
        holdKeys([VK.shift, VK.w], duration: 2.0)
        holdKeys([VK.shift, VK.d], duration: 1.5)
        sleep(1)
        takeScreenshot(name: "realdb-03-sprint")

        // ── Phase 4: Teleport through projects ──
        for p in 0..<8 {
            window.typeKey("t", modifierFlags: [])
            sleep(2)
            if p == 0 || p == 4 { takeScreenshot(name: "realdb-04-teleport-\(p)") }
        }

        // ── Phase 5: Node selection ──
        let center = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()
        sleep(1)
        holdKey(VK.w, duration: 1.0)
        sleep(1)
        takeScreenshot(name: "realdb-05-selection")

        // Deselect
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.05))
        corner.tap()
        sleep(1)

        // ── Phase 6: Galaxy hop ──
        window.typeKey("[", modifierFlags: [])
        sleep(2)
        holdKey(VK.w, duration: 1.5)
        window.typeKey("]", modifierFlags: [])
        sleep(2)
        holdKey(VK.w, duration: 1.5)
        takeScreenshot(name: "realdb-06-galaxy")

        // ── Phase 7: Sustained movement (10s of continuous camera) ──
        holdKeys([VK.shift, VK.w], duration: 3.0)
        holdKey(VK.j, duration: 2.0)
        holdKeys([VK.shift, VK.a], duration: 3.0)
        holdKey(VK.l, duration: 2.0)
        sleep(1)
        takeScreenshot(name: "realdb-07-sustained")

        // ── Phase 8: Final idle ──
        sleep(5)
        takeScreenshot(name: "realdb-08-final")

        // ═══════════════════════════════════════
        //   ANALYSIS
        // ═══════════════════════════════════════

        let report = try buildReport()
        report.printSummary()

        // Hard assertion: p95 wall_dt under 30fps budget
        let p95 = try XCTUnwrap(report.metalP95, "Missing RealityKit performance data")
        do {
            XCTAssertLessThan(p95, 33.0,
                "p95 wall_dt \(String(format: "%.1f", p95))ms exceeds 30fps budget (33ms)")
        }
    }

    // MARK: - Insert Burst Test

    /// Tests insert performance against the real database at full scale.
    /// Inserts into non-synced projects so the personal galaxy's nodeFilter accepts them.
    /// All test-inserted memories are cleaned up at the end via globalId.
    func testRealDBInsertBurst() throws {
        Lattice.setLogLevel(.debug)
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "App window not found")
        sleep(20) // let full data load + simulation settle

        // Defocus search bar
        app.typeKey(.escape, modifierFlags: [])
        usleep(200_000)

        // Real DB path — the app launched without CLAUDE_MEMORY_DB override
        let dbPath = databasePath!

        let baselineFrames = frameCountFromCSV()

        // ── Teleport into a cluster ──
        window.typeKey("t", modifierFlags: [])
        sleep(2)

        // ── Idle baseline (3s) ──
        sleep(3)
        let preInsertFrames = frameCountFromCSV()
        takeScreenshot(name: "realdb-insert-00-pre")

        // Track all inserted IDs for cleanup
        var allInserted: [UUID] = []

        // ── Burst 1: Insert 10 memories ──
        allInserted.append(contentsOf: insertMemories(at: dbPath, project: "sidescroller", count: 10))
        sleep(3)
        let postBurst1Frames = frameCountFromCSV()
        takeScreenshot(name: "realdb-insert-01-burst10")

        // ── Burst 2: Insert 25 memories ──
        allInserted.append(contentsOf: insertMemories(at: dbPath, project: "global", count: 25))
        sleep(4)
        let postBurst2Frames = frameCountFromCSV()
        takeScreenshot(name: "realdb-insert-02-burst25")

        // ── Burst 3: Insert 50 memories ──
        allInserted.append(contentsOf: insertMemories(at: dbPath, project: "sidescroller", count: 50))
        sleep(5)
        let postBurst3Frames = frameCountFromCSV()
        takeScreenshot(name: "realdb-insert-03-burst50")

        // ── Burst 4: Rapid small inserts (simulates real MCP usage) ──
        for _ in 0..<10 {
            allInserted.append(contentsOf: insertMemories(at: dbPath, project: "global", count: 3))
            usleep(300_000)
        }
        sleep(3)
        let postBurst4Frames = frameCountFromCSV()
        takeScreenshot(name: "realdb-insert-04-rapid")

        // ── Cleanup: delete ONLY the test-inserted memories by globalId ──
        deleteMemories(at: dbPath, globalIds: allInserted)
        sleep(2)

        // ═══════════════════════════════════════
        //   ANALYSIS
        // ═══════════════════════════════════════

        print("\n" + String(repeating: "═", count: 80))
        print("  REAL DB INSERT STRESS TEST RESULTS")
        print(String(repeating: "═", count: 80))

        print("\nFrame counts:")
        print("  Baseline→PreInsert: \(preInsertFrames - baselineFrames) frames in ~5s")
        print("  Burst 1 (10 nodes):  \(postBurst1Frames - preInsertFrames) frames in ~3s")
        print("  Burst 2 (25 nodes):  \(postBurst2Frames - postBurst1Frames) frames in ~4s")
        print("  Burst 3 (50 nodes):  \(postBurst3Frames - postBurst2Frames) frames in ~5s")
        print("  Burst 4 (30 rapid):  \(postBurst4Frames - postBurst3Frames) frames in ~6s")

        let report = try buildReport()
        report.printSummary()
    }

    private func frameCountFromCSV() -> Int {
        let path = frameStatsPath
        guard let data = FileManager.default.contents(atPath: path),
              let csv = String(data: data, encoding: .utf8) else { return 0 }
        return csv.components(separatedBy: "\n").count - 2
    }

    // MARK: - Report

    private func buildReport() throws -> BottleneckReport {
        var report = BottleneckReport()
        report.addSection(try RealityFrameReport(path: frameStatsPath).section())
        report.addSection(analyzePackTiming())
        report.addSection(analyzeLabelDiag())
        report.addSection(analyzeDrawPipeline())
        report.addSection(analyzeJitter())
        return report
    }

    // MARK: - Metal Frame Timing

    private func analyzeMetalFrames() -> BottleneckSection {
        var section = BottleneckSection(title: "METAL FRAME TIMING")
        let frames = parseMetalFrames()
        guard !frames.isEmpty else {
            section.addLine("[No data — is ENGRAM_INSTRUMENTATION enabled?]")
            return section
        }

        let maxNodes = frames.map(\.nodeCount).max() ?? 0
        let maxEdges = frames.map(\.edgeCount).max() ?? 0
        let wallDts = frames.filter { $0.wallDt > 0 }.map(\.wallDt).sorted()
        let totals = frames.map(\.total).sorted()

        let wp95 = percentile(wallDts, 0.95)
        section.metalP95 = wp95

        section.addLine("Frames: \(frames.count)  Max nodes: \(maxNodes)  Max edges: \(maxEdges)")
        section.addLine("wall_dt:  p50=\(fmt(percentile(wallDts, 0.50)))  p95=\(fmt(wp95))  p99=\(fmt(percentile(wallDts, 0.99)))  worst=\(fmt(wallDts.last ?? 0))")
        section.addLine("total_ms: p50=\(fmt(percentile(totals, 0.5)))  p95=\(fmt(percentile(totals, 0.95)))  worst=\(fmt(totals.last ?? 0))")

        // Stall counts
        let stalls33 = wallDts.filter { $0 > 33 }.count
        let stalls50 = wallDts.filter { $0 > 50 }.count
        section.addLine("Stalls: >33ms(dropped)=\(stalls33)  >50ms=\(stalls50)")

        // FPS estimate
        let activeFrames = frames.filter { $0.wallDt > 0 && $0.reason != "idle" && $0.reason != "idle_skip" }
        if !activeFrames.isEmpty {
            let activeWalls = activeFrames.map(\.wallDt)
            let avgWall = activeWalls.reduce(0, +) / Double(activeWalls.count)
            section.addLine("Active FPS: ~\(String(format: "%.0f", avgWall > 0 ? 1000.0 / avgWall : 0)) (\(activeFrames.count) frames, avg wall_dt=\(fmt(avgWall))ms)")
        }

        // By reason
        var reasons: [String: [MetalFrame]] = [:]
        for fr in frames { reasons[fr.reason, default: []].append(fr) }
        section.addLine("")
        section.addLine("By reason:")
        for (reason, rFrames) in reasons.sorted(by: { $0.value.count > $1.value.count }) {
            let rTotals = rFrames.map(\.total).sorted()
            section.addLine("  \(reason.padding(toLength: 12, withPad: " ", startingAt: 0)) \(String(format: "%5d", rFrames.count)) frames  p50=\(fmt(percentile(rTotals, 0.50)))  p95=\(fmt(percentile(rTotals, 0.95)))")
        }

        // Sub-phase breakdown for sim frames
        let simFrames = reasons["sim"] ?? []
        if !simFrames.isEmpty {
            section.addLine("")
            section.addLine("Sub-phase breakdown (sim frames, n=\(simFrames.count)):")
            let phases: [(String, KeyPath<MetalFrame, Double>)] = [
                ("sim", \.sim), ("mascot", \.mascot), ("nodes", \.nodes),
                ("edges", \.edges), ("nebulae", \.neb), ("labels", \.labels), ("flow", \.flow)
            ]
            var bottlenecks: [(String, Double, Double)] = []
            for (name, kp) in phases {
                let vals = simFrames.map { $0[keyPath: kp] }.sorted()
                let avg = vals.reduce(0, +) / Double(vals.count)
                let sp95 = percentile(vals, 0.95)
                section.addLine("  \(name.padding(toLength: 10, withPad: " ", startingAt: 0)) avg=\(fmt(avg))  p95=\(fmt(sp95))  worst=\(fmt(vals.last ?? 0))")
                bottlenecks.append((name, avg, sp95))
            }

            let ranked = bottlenecks.sorted { $0.2 > $1.2 }
            section.addLine("")
            section.addLine("BOTTLENECK RANKING (by p95):")
            for (i, (name, avg, p95)) in ranked.enumerated() {
                let bar = String(repeating: "█", count: min(Int(p95 / 0.5), 40))
                section.addLine("  #\(i+1) \(name.padding(toLength: 10, withPad: " ", startingAt: 0)) avg=\(fmt(avg))  p95=\(fmt(p95))ms  \(bar)")
            }
        }

        // Camera-only frames
        let camFrames = reasons["camera"] ?? []
        if !camFrames.isEmpty {
            section.addLine("")
            section.addLine("Camera-only frames (n=\(camFrames.count)):")
            let labelVals = camFrames.map(\.labels).sorted()
            let totalVals = camFrames.map(\.total).sorted()
            section.addLine("  labels: avg=\(fmt(labelVals.reduce(0,+)/Double(labelVals.count)))  p95=\(fmt(percentile(labelVals, 0.95)))")
            section.addLine("  total:  avg=\(fmt(totalVals.reduce(0,+)/Double(totalVals.count)))  p95=\(fmt(percentile(totalVals, 0.95)))")
        }

        // Worst 15 frames
        let worst = frames.sorted { $0.wallDt > $1.wallDt }.prefix(15)
        section.addLine("")
        section.addLine("Worst 15 frames (by wall_dt):")
        section.addLine("  frame  wall_dt  total   sim   nodes edges labels  neb  mascot reason")
        for fr in worst {
            section.addLine(String(format: "  %5d %7.1f %6.1f %5.1f %6.1f %5.1f %6.1f %5.1f %6.1f  %@",
                fr.idx, fr.wallDt, fr.total, fr.sim, fr.nodes, fr.edges, fr.labels, fr.neb, fr.mascot, fr.reason))
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

        var precomputes: [Double] = [], loops: [Double] = [], totals: [Double] = [], counts: [Int] = []
        for line in lines {
            let c = line.components(separatedBy: ",")
            guard c.count >= 5 else { continue }
            precomputes.append(Double(c[1]) ?? 0)
            loops.append(Double(c[2]) ?? 0)
            totals.append(Double(c[3]) ?? 0)
            counts.append(Int(c[4]) ?? 0)
        }

        let maxCount = counts.max() ?? 0
        let sp = precomputes.sorted(), sl = loops.sorted(), st = totals.sorted()
        section.addLine("Calls: \(lines.count)  Max nodes packed: \(maxCount)")
        section.addLine("precompute: p50=\(fmt(percentile(sp, 0.5)))  p95=\(fmt(percentile(sp, 0.95)))  worst=\(fmt(sp.last ?? 0))")
        section.addLine("loop:       p50=\(fmt(percentile(sl, 0.5)))  p95=\(fmt(percentile(sl, 0.95)))  worst=\(fmt(sl.last ?? 0))")
        section.addLine("total:      p50=\(fmt(percentile(st, 0.5)))  p95=\(fmt(percentile(st, 0.95)))  worst=\(fmt(st.last ?? 0))")

        if maxCount > 0 {
            let avgTotal = totals.reduce(0, +) / Double(totals.count)
            section.addLine("Cost: ~\(String(format: "%.1f", avgTotal * 1000.0 / Double(maxCount)))µs/node")
        }

        return section
    }

    // MARK: - Label Diagnostics

    private func analyzeLabelDiag() -> BottleneckSection {
        var section = BottleneckSection(title: "LABEL DIAGNOSTICS")
        let path = "/tmp/label-diag.csv"
        guard let data = FileManager.default.contents(atPath: path),
              let csv = String(data: data, encoding: .utf8) else {
            section.addLine("[No data]")
            return section
        }

        let lines = csv.components(separatedBy: "\n").dropFirst().filter { !$0.isEmpty }
        guard !lines.isEmpty else { section.addLine("[Empty]"); return section }

        var instanceCounts: [Int] = [], missingCounts: [Int] = []
        for line in lines {
            let c = line.components(separatedBy: ",")
            guard c.count >= 5 else { continue }
            instanceCounts.append(Int(c[4]) ?? 0)
            missingCounts.append(Int(c[3]) ?? 0)
        }

        let avgInst = instanceCounts.isEmpty ? 0.0 : Double(instanceCounts.reduce(0, +)) / Double(instanceCounts.count)
        section.addLine("Frames: \(lines.count)  Avg instances: \(String(format: "%.0f", avgInst))  Max: \(instanceCounts.max() ?? 0)")
        section.addLine("Max missing atlas rects: \(missingCounts.max() ?? 0)")

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

        var totals: [Double] = [], callbacks: [Double] = [], waits: [Double] = [], encodes: [Double] = []
        var interFrames: [Double] = [], canaryDelays: [Double] = []
        for line in lines {
            let c = line.components(separatedBy: ",")
            guard c.count >= 5 else { continue }
            totals.append(Double(c[1]) ?? 0)
            callbacks.append(Double(c[2]) ?? 0)
            waits.append(Double(c[3]) ?? 0)
            encodes.append(Double(c[4]) ?? 0)
            if c.count >= 7 {
                interFrames.append(Double(c[5]) ?? 0)
                canaryDelays.append(Double(c[6]) ?? 0)
            }
        }

        let st = totals.sorted(), sc = callbacks.sorted(), sw = waits.sorted(), se = encodes.sorted()
        section.addLine("Draws: \(lines.count)")
        section.addLine("total:    p50=\(fmt(percentile(st, 0.5)))  p95=\(fmt(percentile(st, 0.95)))  worst=\(fmt(st.last ?? 0))")
        section.addLine("callback: p50=\(fmt(percentile(sc, 0.5)))  p95=\(fmt(percentile(sc, 0.95)))  worst=\(fmt(sc.last ?? 0))")
        section.addLine("wait:     p50=\(fmt(percentile(sw, 0.5)))  p95=\(fmt(percentile(sw, 0.95)))  worst=\(fmt(sw.last ?? 0))")
        section.addLine("encode:   p50=\(fmt(percentile(se, 0.5)))  p95=\(fmt(percentile(se, 0.95)))  worst=\(fmt(se.last ?? 0))")

        if !interFrames.isEmpty {
            let si = interFrames.sorted(), sd = canaryDelays.sorted()
            section.addLine("inter_frame: p50=\(fmt(percentile(si, 0.5)))  p95=\(fmt(percentile(si, 0.95)))  worst=\(fmt(si.last ?? 0))")
            section.addLine("canary_delay: p50=\(fmt(percentile(sd, 0.5)))  p95=\(fmt(percentile(sd, 0.95)))  worst=\(fmt(sd.last ?? 0))")
            let bigStalls = zip(interFrames, canaryDelays).enumerated().filter { $0.element.1 > 1000 }
            if !bigStalls.isEmpty {
                section.addLine("")
                section.addLine("Main thread stalls >1s (canary_delay_ms):")
                for (i, (inter, canary)) in bigStalls.prefix(20) {
                    section.addLine("  draw \(i): inter_frame=\(fmt(inter))ms  canary=\(fmt(canary))ms")
                }
            }
        }

        let badWaits = waits.filter { $0 > 5 }.count
        if badWaits > 0 { section.addLine("⚠️ GPU wait >5ms: \(badWaits) frames") }
        return section
    }

    // MARK: - Jitter

    private func analyzeJitter() -> BottleneckSection {
        var section = BottleneckSection(title: "SWIFTUI JITTER")
        let path = "/tmp/swiftui-jitter.csv"
        guard let data = FileManager.default.contents(atPath: path),
              let csv = String(data: data, encoding: .utf8) else {
            section.addLine("[No data]")
            return section
        }

        let lines = csv.components(separatedBy: "\n").dropFirst().filter { !$0.isEmpty }
        guard !lines.isEmpty else { section.addLine("[Empty]"); return section }

        struct JFrame {
            let wallDt: Double, skipped: Bool
        }
        var frames: [JFrame] = []
        for line in lines {
            let c = line.components(separatedBy: ",")
            guard c.count >= 10 else { continue }
            frames.append(JFrame(wallDt: Double(c[1]) ?? 0, skipped: (Int(c[8]) ?? 0) != 0))
        }

        let active = frames.filter { !$0.skipped && $0.wallDt > 0 }
        let wallDts = active.map(\.wallDt).sorted()
        section.addLine("Frames: \(frames.count) total, \(active.count) active")
        if !wallDts.isEmpty {
            let avgWall = wallDts.reduce(0, +) / Double(wallDts.count)
            section.addLine("Active wall_dt: p50=\(fmt(percentile(wallDts, 0.5)))  p95=\(fmt(percentile(wallDts, 0.95)))  p99=\(fmt(percentile(wallDts, 0.99)))")
            section.addLine("Active FPS: ~\(String(format: "%.0f", avgWall > 0 ? 1000.0 / avgWall : 0))")
        }
        section.addLine("Dropped frames (>33ms): \(wallDts.filter { $0 > 33 }.count)")

        return section
    }
}
