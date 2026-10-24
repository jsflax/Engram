@testable import Engram
import Foundation
import Lattice
import SQLite3
import XCTest

private enum SidebarSaveFailure: Error { case unavailable }

/// Holds actual calls to the production controller's persistence boundary so
/// ordering and failure behavior do not depend on scheduler timing.
private actor ControlledSidebarWriter {
    private(set) var calls: [SidebarTab] = []
    private var completions: [CheckedContinuation<Void, any Error>] = []

    func save(_ tab: SidebarTab) async throws {
        calls.append(tab)
        try await withCheckedThrowingContinuation { completions.append($0) }
    }

    func completeNext(failing: Bool = false) {
        guard !completions.isEmpty else { return }
        let completion = completions.removeFirst()
        if failing { completion.resume(throwing: SidebarSaveFailure.unavailable) }
        else { completion.resume() }
    }
}

@MainActor
final class SidebarSelectionTests: XCTestCase {
    func testRestoresInitialTabWithoutStartingAWrite() throws {
        let lattice = try Lattice(VisualizerConfig.self, configuration: .init(storage: .memory()))
        let config = VisualizerConfig()
        config.selectedTab = .settings
        try lattice.add(config)
        let selection = SidebarSelection(config: config, lattice: lattice)
        XCTAssertEqual(selection.selectedTab, .settings)
        XCTAssertFalse(selection.isPersisting)
        XCTAssertNil(selection.persistenceError)
    }

    func testBlockedWriterKeepsSelectionImmediateAndCoalescesLatest() async throws {
        let writer = ControlledSidebarWriter()
        let selection = SidebarSelection(initialTab: .visualizer) { try await writer.save($0) }
        selection.select(.logs)
        try await waitForCalls(writer, count: 1)
        let statements = Lattice.threadSQLStatementCount
        selection.select(.settings)
        selection.select(.account)
        XCTAssertEqual(selection.selectedTab, .account)
        XCTAssertEqual(Lattice.threadSQLStatementCount, statements)
        let blockedCalls = await writer.calls
        XCTAssertEqual(blockedCalls, [.logs])
        await writer.completeNext()
        try await waitForCalls(writer, count: 2)
        let coalescedCalls = await writer.calls
        XCTAssertEqual(coalescedCalls, [.logs, .account])
        XCTAssertEqual(selection.selectedTab, .account, "An older save must not revert the visible tab")
        await writer.completeNext()
        try await waitUntil { !selection.isPersisting }
        XCTAssertNil(selection.persistenceError)
    }

    func testFailureKeepsSelectionAndExplicitRetrySavesIt() async throws {
        let writer = ControlledSidebarWriter()
        let selection = SidebarSelection(initialTab: .visualizer) { try await writer.save($0) }
        selection.select(.logs)
        try await waitForCalls(writer, count: 1)
        await writer.completeNext(failing: true)
        try await waitUntil { !selection.isPersisting }
        XCTAssertEqual(selection.selectedTab, .logs)
        XCTAssertNotNil(selection.persistenceError)
        selection.retryPersistence()
        try await waitForCalls(writer, count: 2)
        let calls = await writer.calls
        XCTAssertEqual(calls, [.logs, .logs])
        await writer.completeNext()
        try await waitUntil { !selection.isPersisting }
        XCTAssertNil(selection.persistenceError)
        XCTAssertEqual(selection.selectedTab, .logs)
    }

    func testOlderFailureDoesNotDiscardNewerSelection() async throws {
        let writer = ControlledSidebarWriter()
        let selection = SidebarSelection(initialTab: .visualizer) { try await writer.save($0) }
        selection.select(.logs)
        try await waitForCalls(writer, count: 1)
        selection.select(.account)
        await writer.completeNext(failing: true)
        try await waitForCalls(writer, count: 2)
        let calls = await writer.calls
        XCTAssertEqual(calls, [.logs, .account])
        XCTAssertEqual(selection.selectedTab, .account)
        XCTAssertNil(selection.persistenceError, "A stale failure must not replace the newer pending state")
        await writer.completeNext()
        try await waitUntil { !selection.isPersisting }
        XCTAssertNil(selection.persistenceError)
    }

    func testPendingWriterDoesNotRetainSelection() async throws {
        let writer = ControlledSidebarWriter()
        var selection: SidebarSelection? = SidebarSelection(initialTab: .visualizer) { try await writer.save($0) }
        weak var weakSelection = selection
        selection?.select(.logs)
        try await waitForCalls(writer, count: 1)
        selection = nil
        XCTAssertNil(weakSelection, "The drain must not keep the app's presentation state alive across a write")
        await writer.completeNext()
    }

    func testSQLiteWriterContentionDoesNotBlockSelectionAndEventuallySavesLatest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("sidebar.sqlite")
        var configuration = Lattice.Configuration(fileURL: path)
        configuration.busyTimeoutMs = 1_000 // Bound a regression that accidentally blocks the main actor.
        let lattice = try Lattice(VisualizerConfig.self, configuration: configuration)
        let config = VisualizerConfig()
        try lattice.add(config)
        let writer = SidebarPreferenceWriter(lattice: lattice.sendableReference, config: config.sendableReference)
        let selection = SidebarSelection(initialTab: .visualizer) { try await writer.save($0) }

        var lockConnection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path.path, &lockConnection,
                                     SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        let handle = try XCTUnwrap(lockConnection)
        defer {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            sqlite3_close(handle)
        }
        XCTAssertEqual(sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        selection.select(.logs)
        // Give the real actor-owned writer an opportunity to reach the held DB.
        // This is not a frame/time budget: the lock is still held by this test.
        try await Task.sleep(for: .milliseconds(20))
        let statements = Lattice.threadSQLStatementCount
        selection.select(.settings)
        selection.select(.account)
        XCTAssertEqual(selection.selectedTab, .account)
        XCTAssertEqual(Lattice.threadSQLStatementCount, statements)
        XCTAssertTrue(selection.isPersisting)
        XCTAssertNil(selection.persistenceError)
        XCTAssertEqual(config.selectedTab, .visualizer, "The held writer must not have committed a preference yet")

        XCTAssertEqual(sqlite3_exec(handle, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        try await waitUntil("The preference write did not settle after releasing SQLite's writer lock") {
            !selection.isPersisting
        }
        XCTAssertNil(selection.persistenceError)
        XCTAssertEqual(config.selectedTab, .account)
    }

    private func waitForCalls(_ writer: ControlledSidebarWriter, count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while await writer.calls.count < count {
            guard ContinuousClock.now < deadline else {
                XCTFail("Persistence attempt did not start")
                throw SidebarSaveFailure.unavailable
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitUntil(_ message: String = "Sidebar persistence did not settle",
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail(message, file: file, line: line)
                throw SidebarSaveFailure.unavailable
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
