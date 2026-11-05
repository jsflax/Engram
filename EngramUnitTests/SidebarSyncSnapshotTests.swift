@testable import Engram
import AppKit
import EngramModels
import Lattice
import SwiftUI
import XCTest

@MainActor
private final class SidebarSyncRenderRecorder {
    var snapshot: SidebarSyncSnapshot = .empty
    var renders = 0
}

/// Exercise the production query -> parent snapshot -> value-only row boundary,
/// including observation when an independent connection changes a stored
/// setting. This fixture does not establish cross-process delivery.
private struct SidebarSyncObservationHost: View {
    @LatticeQuery<SyncConfig>(sort: \SyncConfig.project) private var configs
    let recorder: SidebarSyncRenderRecorder

    var body: some View {
        let snapshot = SidebarSyncSnapshot(configs)
        let _ = recorder.snapshot = snapshot
        let _ = recorder.renders += 1
        Text(snapshot["engram"].isSyncing ? "Synced" : "Local")
    }
}

@MainActor
final class SidebarSyncSnapshotTests: XCTestCase {
    func testMissingProjectsAndDuplicatesPreserveExistingRowValues() {
        let first = SyncConfig(project: "engram", policy: .local, exposedTeams: ["group-a"])
        let duplicate = SyncConfig(project: "engram", policy: .sync, exposedTeams: ["group-b"])
        let defaultConfig = SyncConfig(project: "_default", policy: .sync)
        let snapshot = SidebarSyncSnapshot([first, duplicate, defaultConfig])

        XCTAssertFalse(snapshot["engram"].isSyncing)
        XCTAssertEqual(snapshot["engram"].exposedGroups, ["group-a"])
        XCTAssertEqual(snapshot["missing"], .missing,
                       "The existing sidebar shows only an exact project override, not _default")
        XCTAssertTrue(snapshot["_default"].isSyncing)
        XCTAssertEqual(SidebarSyncSnapshot.empty["engram"], .missing)
    }

    func testRebuildingReadsUpdatesWithoutChangingPreviouslyCapturedValues() {
        let config = SyncConfig(project: "engram", policy: .local, exposedTeams: ["group-a"])
        let first = SidebarSyncSnapshot([config])
        config.policy = .sync
        config.exposedGroups = ["group-b", "group-c"]
        let updated = SidebarSyncSnapshot([config])

        XCTAssertFalse(first["engram"].isSyncing)
        XCTAssertEqual(first["engram"].exposedGroups, ["group-a"])
        XCTAssertTrue(updated["engram"].isSyncing)
        XCTAssertEqual(updated["engram"].exposedGroups, ["group-b", "group-c"])
        config.project = "orbital"
        let renamed = SidebarSyncSnapshot([config])
        XCTAssertEqual(renamed["engram"], .missing)
        XCTAssertEqual(renamed["orbital"], updated["engram"])
    }

    func testDatabaseReadsScaleWithConfigsAndLazyRowsDoNotReadSQL() throws {
        let lattice = try Lattice(SyncConfig.self, configuration: .init(storage: .memory()))
        for index in 0..<128 {
            try lattice.add(SyncConfig(project: "Project \(index)",
                                       policy: index.isMultiple(of: 2) ? .sync : .local,
                                       exposedTeams: ["group-\(index)"]))
        }
        let configs = Array(lattice.objects(SyncConfig.self))
        for config in configs { config.dematerialize() }
        let before = Lattice.threadSQLStatementCount
        let snapshot = SidebarSyncSnapshot(configs)
        let captureStatements = Int(Lattice.threadSQLStatementCount - before)
        XCTAssertGreaterThan(captureStatements, 0, "Exercise cold database-backed getters")
        XCTAssertLessThanOrEqual(captureStatements, configs.count * 3,
                                "Reads must scale with configs, not with displayed rows; batching may improve this bound")
        let afterCapture = Lattice.threadSQLStatementCount
        for _ in 0..<4 {
            for index in 0..<256 {
                let settings = snapshot["Project \(index)"]
                XCTAssertEqual(settings.isSyncing, index < 128 && index.isMultiple(of: 2))
                XCTAssertEqual(settings.exposedGroups, index < 128 ? ["group-\(index)"] : [])
            }
        }
        XCTAssertEqual(Lattice.threadSQLStatementCount, afterCapture,
                       "Deferred row formatting must not touch database-backed getters")
    }

    func testParentObservationRefreshesPolicyExposureAndQueryMembership() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lattice = try Lattice(SyncConfig.self,
                                  configuration: .init(fileURL: directory.appendingPathComponent("sidebar-sync.sqlite")))
        defer { lattice.close() }
        try lattice.add(SyncConfig(project: "engram", policy: .local, exposedTeams: ["group-a"]))
        let independent = try XCTUnwrap(try lattice.sendableReference.resolveIndependent())
        defer { independent.close() }
        let writer = try XCTUnwrap(independent.objects(SyncConfig.self).first)
        let recorder = SidebarSyncRenderRecorder()
        let host = NSHostingView(rootView: SidebarSyncObservationHost(recorder: recorder)
            .environment(\.lattice, lattice))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return recorder.renders > 0 && recorder.snapshot["engram"].exposedGroups == ["group-a"]
        }
        let first = recorder.snapshot

        // Writes use a distinct native connection to the same file. No explicit
        // host refresh, snapshot cache invalidation or rootView replacement.
        writer.policy = .sync
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return recorder.snapshot["engram"].isSyncing
        }
        XCTAssertEqual(recorder.snapshot["engram"].exposedGroups, ["group-a"])
        writer.exposedGroups = ["group-b"]
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return recorder.snapshot["engram"].exposedGroups == ["group-b"]
        }
        let inserted = SyncConfig(project: "orbital", policy: .sync)
        try independent.add(inserted)
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return recorder.snapshot["orbital"].isSyncing
        }
        independent.delete(inserted)
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return recorder.snapshot["orbital"] == .missing
        }
        XCTAssertFalse(first["engram"].isSyncing)
        XCTAssertEqual(first["engram"].exposedGroups, ["group-a"])
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("The observed sync settings did not refresh")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
