@testable import Engram
import Foundation
import Lattice
import os
import XCTest

@MainActor
final class SidebarDatabaseMaintenanceTests: XCTestCase {
    func testBlockedMaintenanceLeavesMainActorResponsiveAndRejectsDuplicateStarts() async throws {
        let lattice = try Lattice(VisualizerConfig.self, configuration: .init(storage: .memory()))
        let reference = lattice.sendableReference
        let started = expectation(description: "Background maintenance entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let worker = SidebarDatabaseMaintenanceWorker { _ in
            calls.withLock { $0 += 1 }
            started.fulfill()
            // A bounded safety exit makes an accidental MainActor execution
            // fail the isRunning assertion instead of hanging the test host.
            _ = release.wait(timeout: .now() + 3)
            return .init(message: "Controlled maintenance finished.", isIncomplete: false, diagnostics: [])
        }
        let controller = SidebarDatabaseMaintenance(worker: worker)
        controller.start(reference)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(controller.isRunning)
        XCTAssertNil(controller.result)
        controller.start(reference)
        XCTAssertEqual(calls.withLock { $0 }, 1)
        // This assertion executes on MainActor while the worker is still
        // blocked, reproducing the UI responsiveness boundary directly.
        XCTAssertTrue(Thread.isMainThread)
        release.signal()
        try await waitUntilFinished(controller)
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertEqual(controller.result?.message, "Controlled maintenance finished.")
    }

    func testSuccessfulPhasesNeverClaimFinalCleanupIsComplete() {
        let result = SidebarDatabaseMaintenanceResult.summarize(
            historyRemoved: 12, historyError: nil, vacuumSucceeded: true, vacuumError: nil,
            checkpointedFrames: 100, checkpointError: nil)
        XCTAssertFalse(result.isIncomplete)
        XCTAssertEqual(result.message, "Database compacted.")
    }

    func testMissingWriterSlotsPreserveHistoryPolicy() {
        let result = SidebarDatabaseMaintenanceResult.summarize(
            historyRemoved: -1, historyError: nil, vacuumSucceeded: true, vacuumError: nil,
            checkpointedFrames: 0, checkpointError: nil)
        XCTAssertFalse(result.isIncomplete)
        XCTAssertTrue(result.message.hasPrefix("History was preserved."))
    }

    func testSealedHistoryAndVacuumErrorsSurviveLaterCheckpointProgress() {
        let result = SidebarDatabaseMaintenanceResult.summarize(
            historyRemoved: 0, historyError: "history busy", vacuumSucceeded: false, vacuumError: "vacuum busy",
            checkpointedFrames: 4, checkpointError: nil)
        XCTAssertTrue(result.isIncomplete)
        XCTAssertTrue(result.message.contains("History cleanup failed."))
        XCTAssertTrue(result.message.contains("Database compaction failed."))
        XCTAssertEqual(result.diagnostics, ["History cleanup: history busy", "Database compaction: vacuum busy"])
    }

    func testDeferredAndFailedCheckpointsRemainVisibleAfterSuccessfulRebuild() {
        let deferred = SidebarDatabaseMaintenanceResult.summarize(
            historyRemoved: 0, historyError: nil, vacuumSucceeded: true, vacuumError: nil,
            checkpointedFrames: -1, checkpointError: nil)
        XCTAssertTrue(deferred.isIncomplete)
        XCTAssertEqual(deferred.message, "Database compacted. Final cleanup was deferred.")
        let failed = SidebarDatabaseMaintenanceResult.summarize(
            historyRemoved: 0, historyError: nil, vacuumSucceeded: true, vacuumError: nil,
            checkpointedFrames: 0, checkpointError: "checkpoint failed")
        XCTAssertTrue(failed.isIncomplete)
        XCTAssertEqual(failed.message, "Database compacted. Final cleanup could not finish.")
    }

    func testIndependentWorkerPreservesFixtureDataAndUIConnection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lattice = try Lattice(VisualizerConfig.self, configuration: .init(fileURL: directory.appendingPathComponent("maintenance.sqlite")))
        defer { lattice.close() }
        let config = VisualizerConfig()
        config.selectedTab = .settings
        try lattice.add(config)
        let originalID = config.globalId

        let result = await SidebarDatabaseMaintenanceWorker().run(lattice.sendableReference)
        XCTAssertTrue(result.message.contains("Database compacted."), result.message)
        XCTAssertTrue(result.message.contains("History was preserved."), result.message)
        XCTAssertEqual(lattice.objects(VisualizerConfig.self).first?.globalId, originalID)
        XCTAssertEqual(config.selectedTab, .settings)
        // Closing the independent worker must not close the UI's connection.
        try lattice.withTransaction { config.selectedTab = .account }
        XCTAssertEqual(config.selectedTab, .account)
    }

    func testMissingStoreIsReportedWithoutRecreatingIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("removed.sqlite")
        let lattice = try Lattice(VisualizerConfig.self, configuration: .init(fileURL: path))
        let reference = lattice.sendableReference
        lattice.close()
        try FileManager.default.removeItem(at: directory)

        let result = await SidebarDatabaseMaintenanceWorker().run(reference)
        XCTAssertTrue(result.isIncomplete)
        XCTAssertEqual(result.message, "The database is no longer available.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    private func waitUntilFinished(_ controller: SidebarDatabaseMaintenance) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while controller.isRunning {
            guard ContinuousClock.now < deadline else {
                XCTFail("Maintenance did not publish its result")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
