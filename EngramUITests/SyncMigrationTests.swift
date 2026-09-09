import XCTest
import EngramKit
import Lattice

/// Tests galaxy migration when toggling project sync on/off.
/// Seeds a multi-project database, launches the app, then writes SyncConfig
/// rows from the test process (triggering xproc observer in the app).
/// Analyzes /tmp/galaxy-migration.csv to verify nodes migrate correctly.
@MainActor
final class SyncMigrationTests: XCTestCase {
    let app = XCUIApplication()
    private var dbPath: String!
    private let testUUID = UUID().uuidString

    override func setUpWithError() throws {
        continueAfterFailure = false

        let tmpDir = NSTemporaryDirectory()
        dbPath = tmpDir + "sync-mig-\(testUUID).sqlite"

        // Clean previous instrumentation logs
        try? FileManager.default.removeItem(atPath: "/tmp/galaxy-migration.csv")
        try? FileManager.default.removeItem(atPath: "/tmp/metal-frame-timing.csv")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
    }

    /// Open a separate Lattice connection to the test DB (simulates external process).
    private func openExternalLattice() -> Lattice {
        try! Lattice(
            Memory.self, Edge.self, SyncConfig.self,
            configuration: .init(
                fileURL: URL(fileURLWithPath: dbPath),
                migration: engramMigrations
            )
        )
    }

    /// Toggle a project to `.sync` via an external Lattice connection.
    /// The xproc notification triggers the app's SyncConfig observer.
    private func externalToggleSync(project: String, policy: SyncConfig.Policy) {
        let ext = openExternalLattice()
        if let existing = ext.objects(SyncConfig.self).where({ $0.project == project }).first {
            existing.policy = policy
            existing.updatedAt = Date()
        } else {
            try! ext.add(SyncConfig(project: project, policy: policy))
        }
    }

    private func launchApp() {
        app.launchEnvironment["CLAUDE_MEMORY_DB"] = dbPath
        app.launchEnvironment["ENGRAM_TEST_NO_NOTIFY"] = "1"
        app.launch()
    }

    // MARK: - Test: Single Toggle Sync On Then Off

    /// Toggles a project to sync, waits for migration, then toggles back.
    /// Verifies nodes migrate in both directions without orphaning.
    func testSingleToggleSyncOnOff() throws {
        // Seed: 3 projects, no sync config
        let projects: [(name: String, count: Int)] = [
            ("ProjectA", 30), ("ProjectB", 20), ("ProjectC", 15)
        ]
        seedMultiProjectDatabase(at: dbPath, projects: projects, staleAge: 3600)

        launchApp()
        sleep(8) // wait for load + simulation settle

        takeScreenshot(name: "sync-mig-01-initial")

        // Toggle ProjectA to sync
        externalToggleSync(project: "ProjectA", policy: .sync)
        sleep(5) // wait for observer + migration + animation start

        takeScreenshot(name: "sync-mig-02-after-sync-on")

        // Toggle ProjectA back to local
        externalToggleSync(project: "ProjectA", policy: .local)
        sleep(5) // wait for reverse migration

        takeScreenshot(name: "sync-mig-03-after-sync-off")

        // Analyze migration CSV
        let events = parseMigrationCSV()
        printMigrationReport(events)

        // Verify: should have 2 migrate events for ProjectA
        let projectAMigrations = events.filter { $0.event == "migrate" && $0.project == "ProjectA" }
        XCTAssertEqual(projectAMigrations.count, 2, "Expected 2 migrations (on + off) for ProjectA")

        // Verify: first migration personal→synced, second synced→personal
        if projectAMigrations.count >= 2 {
            XCTAssertTrue(projectAMigrations[0].direction.contains("personal→synced"),
                          "First migration should be personal→synced")
            XCTAssertTrue(projectAMigrations[1].direction.contains("synced→personal"),
                          "Second migration should be synced→personal")

            // Node counts should match
            XCTAssertEqual(projectAMigrations[0].nodeCount, projectAMigrations[1].nodeCount,
                           "Same number of nodes should migrate in both directions")
            XCTAssertGreaterThan(projectAMigrations[0].nodeCount, 0, "Should have migrated nodes")
        }

        // Lattice xproc + WAL hooks both fire, so some idempotent skips are normal.
        // The idempotent guards prevent actual double-migration — just log for visibility.
        let skips = events.filter { $0.event == "skip_idempotent" && $0.project == "ProjectA" }
        print("        Idempotent skips: \(skips.count) (expected from multi-source observer firing)")
    }

    // MARK: - Test: Mid-Migration Retoggle

    /// Toggles sync on, then quickly toggles back BEFORE migration animation completes.
    /// This is the known-broken scenario: nodes get orphaned.
    func testMidMigrationRetoggle() throws {
        let projects: [(name: String, count: Int)] = [
            ("ProjectA", 30), ("ProjectB", 20)
        ]
        seedMultiProjectDatabase(at: dbPath, projects: projects, staleAge: 3600)

        launchApp()
        sleep(8)

        takeScreenshot(name: "sync-retoggle-01-initial")

        // Toggle ProjectA to sync
        externalToggleSync(project: "ProjectA", policy: .sync)
        sleep(2) // short wait — migration is still animating

        takeScreenshot(name: "sync-retoggle-02-mid-migration")

        // Retoggle back to local while still animating
        externalToggleSync(project: "ProjectA", policy: .local)
        sleep(5) // wait for second migration to complete

        takeScreenshot(name: "sync-retoggle-03-after-retoggle")

        let events = parseMigrationCSV()
        printMigrationReport(events)

        // Verify: should have migrations in both directions
        let projectAMigrations = events.filter { $0.event == "migrate" && $0.project == "ProjectA" }
        XCTAssertGreaterThanOrEqual(projectAMigrations.count, 2,
            "Expected at least 2 migrations for mid-retoggle scenario")

        // The last migration should bring nodes back to personal
        if let last = projectAMigrations.last {
            XCTAssertTrue(last.direction.contains("synced→personal"),
                          "Last migration should return nodes to personal")
            XCTAssertGreaterThan(last.nodeCount, 0, "Should have migrated nodes back")
        }

        // Verify: load_into events should show nodes actually arriving
        let loadIntos = events.filter { $0.event == "load_into" && $0.project == "ProjectA" }
        for load in loadIntos {
            XCTAssertGreaterThan(load.nodeCount, 0, "load_into should have non-zero node count")
        }
    }

    // MARK: - Test: Multiple Projects Toggle

    /// Toggles multiple projects to sync in sequence.
    /// Verifies each project migrates independently.
    func testMultipleProjectToggle() throws {
        let projects: [(name: String, count: Int)] = [
            ("ProjectA", 25), ("ProjectB", 20), ("ProjectC", 15)
        ]
        seedMultiProjectDatabase(at: dbPath, projects: projects, staleAge: 3600)

        launchApp()
        sleep(8)

        // Toggle ProjectA then ProjectB
        externalToggleSync(project: "ProjectA", policy: .sync)
        sleep(3)
        externalToggleSync(project: "ProjectB", policy: .sync)
        sleep(5)

        takeScreenshot(name: "sync-multi-01-both-synced")

        let events = parseMigrationCSV()
        printMigrationReport(events)

        let projectAMigs = events.filter { $0.event == "migrate" && $0.project == "ProjectA" }
        let projectBMigs = events.filter { $0.event == "migrate" && $0.project == "ProjectB" }

        XCTAssertGreaterThanOrEqual(projectAMigs.count, 1, "ProjectA should have migrated")
        XCTAssertGreaterThanOrEqual(projectBMigs.count, 1, "ProjectB should have migrated")

        // ProjectC should NOT have migrated
        let projectCMigs = events.filter { $0.event == "migrate" && $0.project == "ProjectC" }
        XCTAssertEqual(projectCMigs.count, 0, "ProjectC should not have migrated")
    }

    // MARK: - CSV Parsing

    struct MigrationEvent {
        let timestamp: Double
        let event: String      // migrate, skip_idempotent, migrate_out, load_into, etc.
        let project: String
        let direction: String
        let fromGalaxy: String
        let toGalaxy: String
        let nodeCount: Int
        let edgeCount: Int
        let positionCount: Int
        let elapsedMs: Double
    }

    private func parseMigrationCSV() -> [MigrationEvent] {
        let path = "/tmp/galaxy-migration.csv"
        guard let data = FileManager.default.contents(atPath: path),
              let csv = String(data: data, encoding: .utf8) else { return [] }

        return csv.components(separatedBy: "\n").dropFirst().compactMap { line in
            let cols = line.components(separatedBy: ",")
            guard cols.count >= 10 else { return nil }
            return MigrationEvent(
                timestamp: Double(cols[0]) ?? 0,
                event: cols[1],
                project: cols[2],
                direction: cols[3],
                fromGalaxy: cols[4],
                toGalaxy: cols[5],
                nodeCount: Int(cols[6]) ?? 0,
                edgeCount: Int(cols[7]) ?? 0,
                positionCount: Int(cols[8]) ?? 0,
                elapsedMs: Double(cols[9]) ?? 0
            )
        }
    }

    // MARK: - Report

    private func printMigrationReport(_ events: [MigrationEvent]) {
        print("""

        ╔═══════════════════════════════════════════════════════════════════════╗
        ║               GALAXY MIGRATION PROFILE                              ║
        ╠═══════════════════════════════════════════════════════════════════════╣
        ║ Total events: \(String(format: "%4d", events.count))                                                    ║
        ╠═══════════════════════════════════════════════════════════════════════╣
        """)

        print("        event              project      direction              nodes edges  pos  elapsed_ms")
        for e in events {
            let ev = e.event.padding(toLength: 18, withPad: " ", startingAt: 0)
            let proj = e.project.padding(toLength: 12, withPad: " ", startingAt: 0)
            let dir = e.direction.padding(toLength: 22, withPad: " ", startingAt: 0)
            print("        \(ev) \(proj) \(dir) \(String(format: "%5d %5d %4d %8.2f", e.nodeCount, e.edgeCount, e.positionCount, e.elapsedMs))")
        }

        // Summary by project
        let projects = Set(events.map(\.project))
        print("")
        for project in projects.sorted() {
            let migs = events.filter { $0.event == "migrate" && $0.project == project }
            let skips = events.filter { $0.event == "skip_idempotent" && $0.project == project }
            let outs = events.filter { $0.event == "migrate_out" && $0.project == project }
            let loads = events.filter { $0.event == "load_into" && $0.project == project }
            print("        \(project): \(migs.count) migrate, \(outs.count) out, \(loads.count) load, \(skips.count) skip")
        }

        print("""

        ╚═══════════════════════════════════════════════════════════════════════╝
        """)
    }

}
