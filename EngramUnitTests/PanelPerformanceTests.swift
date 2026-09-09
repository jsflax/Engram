@testable import Engram
import EngramKit
import Lattice
import SwiftUI
import XCTest

private extension Galaxy {
    /// Prepare the producer's buffer on its owning actor, as the loader does.
    func preparePanelInitialSnapshotForTesting(nodes: [NodeData]) {
        pendingUpdate.withLock {
            $0.bulkNodeBatches = [[(pk: 1, node: nodes[0])], [(pk: 2, node: nodes[1])]]
            $0.finalize = true
        }
    }
}

@MainActor
final class PanelPerformanceTests: XCTestCase {
    func testPanelResponsePhasesPartitionEventToDrawWithoutChangingItsOrigin() throws {
        let phases = PanelResponsePhases(eventTimestamp: 100, beginTimestamp: 100.125,
                                         mutationReturnTimestamp: 100.250, drawTimestamp: 100.500)
        XCTAssertEqual(phases.eventToBeginMilliseconds, 125)
        XCTAssertEqual(try XCTUnwrap(phases.beginToMutationReturnMilliseconds), 125)
        XCTAssertEqual(try XCTUnwrap(phases.mutationReturnToDrawMilliseconds), 250)
        XCTAssertEqual(phases.beginToDrawMilliseconds, 375)
        XCTAssertEqual(phases.eventToBeginMilliseconds + phases.beginToDrawMilliseconds, 500,
                       "The diagnostic split must preserve the original event-to-draw duration")
        XCTAssertEqual(phases.csvValues, "125.000,125.000,250.000,375.000")
    }

    func testPanelResponsePhasesLeaveUnmarkedMutationFieldsEmpty() {
        // Callback-origin measurements begin at the recorder's own timestamp;
        // actions without a selected-tab write must not invent mutation timing.
        let phases = PanelResponsePhases(eventTimestamp: 10, beginTimestamp: 10,
                                         mutationReturnTimestamp: nil, drawTimestamp: 10.5)
        XCTAssertEqual(phases.eventToBeginMilliseconds, 0)
        XCTAssertNil(phases.beginToMutationReturnMilliseconds)
        XCTAssertNil(phases.mutationReturnToDrawMilliseconds)
        XCTAssertEqual(phases.beginToDrawMilliseconds, 500)
        XCTAssertEqual(phases.csvValues, "0.000,,,500.000")
    }

    func testSidebarRenderConfigurationBoundsSQLAndKeepsLiveConfigFresh() throws {
        let lattice = try Lattice(VisualizerConfig.self, configuration: .init(storage: .memory()))
        let config = VisualizerConfig()
        config.hiddenProjects = ["Project 7"]
        config.hiddenRelations = ["part_of"]
        try lattice.add(config)
        let row = try XCTUnwrap(lattice.objects(VisualizerConfig.self).first)
        row.dematerialize()

        let initialStatements = Lattice.threadSQLStatementCount
        let first = SidebarRenderConfiguration(config: row)
        XCTAssertEqual(Lattice.threadSQLStatementCount - initialStatements, 4,
                       "Graph rendering reads the selected tab, hidden sets, and layout exactly once")
        let graph = try XCTUnwrap(first.graph)
        XCTAssertEqual(first.selectedTab, .visualizer)
        XCTAssertEqual(graph.hiddenProjects, ["Project 7"])
        XCTAssertEqual(graph.hiddenRelations, ["part_of"])
        XCTAssertEqual(graph.layoutMode, .forceDirected)
        XCTAssertFalse(row.isMaterialized)

        let rowStatements = Lattice.threadSQLStatementCount
        for index in 0..<256 {
            XCTAssertEqual(graph.hiddenProjects.contains("Project \(index)"), index == 7)
            XCTAssertTrue(graph.hiddenRelations.contains("part_of"))
            XCTAssertEqual(first.selectedTab, .visualizer)
            XCTAssertEqual(graph.layoutMode, .forceDirected)
        }
        XCTAssertEqual(Lattice.threadSQLStatementCount, rowStatements,
                       "Formatting any number of lazy rows must only read captured values")

        // Write through another model handle after the first snapshot. The
        // next parent render must see fresh data without materializing config.
        config.hiddenProjects = ["Project 42"]
        config.hiddenRelations = ["supersedes"]
        config.layoutMode = .embedding
        let updatedStatements = Lattice.threadSQLStatementCount
        let updated = SidebarRenderConfiguration(config: row)
        XCTAssertEqual(Lattice.threadSQLStatementCount - updatedStatements, 4)
        XCTAssertEqual(updated.graph?.hiddenProjects, ["Project 42"])
        XCTAssertEqual(updated.graph?.hiddenRelations, ["supersedes"])
        XCTAssertEqual(updated.graph?.layoutMode, .embedding)
        XCTAssertEqual(graph.hiddenProjects, ["Project 7"], "Already-built rows keep their immutable snapshot")
        XCTAssertFalse(row.isMaterialized)
    }

    func testSidebarNonGraphRenderingOnlyReadsSelectedTab() throws {
        let lattice = try Lattice(VisualizerConfig.self, configuration: .init(storage: .memory()))
        let config = VisualizerConfig()
        try lattice.add(config)
        for tab in [SidebarTab.logs, .settings, .account] {
            config.selectedTab = tab
            let statements = Lattice.threadSQLStatementCount
            let snapshot = SidebarRenderConfiguration(config: config)
            XCTAssertEqual(Lattice.threadSQLStatementCount - statements, 1,
                           "Other tabs must not read unused Graph configuration")
            XCTAssertEqual(snapshot.selectedTab, tab)
            XCTAssertNil(snapshot.graph)
        }
    }

    func testWindowVisibilityTracksReusedPresentationsAndDeduplicatesNotifications() {
        var state = WindowVisibilityState()
        let generation = state.attach()
        XCTAssertNil(state.update(isVisible: false, generation: generation))
        XCTAssertEqual(state.update(isVisible: true, generation: generation), .show)
        XCTAssertNil(state.update(isVisible: true, generation: generation))
        XCTAssertEqual(state.update(isVisible: false, generation: generation), .hide)
        XCTAssertNil(state.update(isVisible: false, generation: generation))
        XCTAssertEqual(state.update(isVisible: true, generation: generation), .show)
        XCTAssertTrue(state.isVisible)
        XCTAssertEqual(state.detach(), .hide)
        XCTAssertNil(state.detach())
    }

    func testWindowVisibilityRejectsCallbacksFromDetachedWindowGeneration() {
        var state = WindowVisibilityState()
        let oldGeneration = state.attach()
        XCTAssertEqual(state.update(isVisible: true, generation: oldGeneration), .show)
        XCTAssertEqual(state.detach(), .hide)
        XCTAssertNil(state.update(isVisible: true, generation: oldGeneration))
        let newGeneration = state.attach()
        XCTAssertNil(state.update(isVisible: true, generation: oldGeneration))
        XCTAssertFalse(state.isVisible)
        XCTAssertEqual(state.update(isVisible: true, generation: newGeneration), .show)
        XCTAssertNil(state.update(isVisible: false, generation: oldGeneration))
        XCTAssertTrue(state.isVisible)
        XCTAssertEqual(state.detach(), .hide)
    }

    func testWindowVisibilityDrivesStoreWithoutClearingRowsWhileClosed() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let memory = Memory(content: "Visible memory")
        try lattice.add(memory)
        let store = MenuBarActivityStore()
        defer { store.stop() }
        var state = WindowVisibilityState()
        let generation = state.attach()
        func apply(_ transition: WindowVisibilityState.Transition?) {
            switch transition {
            case .show: store.start(lattice: lattice)
            case .hide: store.stop()
            case nil: break
            }
        }
        apply(state.update(isVisible: true, generation: generation))
        try await waitUntil { store.rows.first?.label == "Visible memory" }
        let cachedRows = store.rows
        let reads = store.snapshotReadCount
        apply(state.update(isVisible: false, generation: generation))
        memory.content = "Edited while hidden"
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(store.rows, cachedRows)
        XCTAssertEqual(store.snapshotReadCount, reads)
        apply(state.update(isVisible: true, generation: generation))
        XCTAssertEqual(store.rows, cachedRows)
        try await waitUntil { store.rows.first?.label == "Edited while hidden" }
        apply(state.detach())
        let detachedReads = store.snapshotReadCount
        memory.content = "Edited after detach"
        apply(state.update(isVisible: true, generation: generation))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(store.snapshotReadCount, detachedReads)
        XCTAssertEqual(store.rows.first?.label, "Edited while hidden")
    }

    func testMenuSnapshotIsBoundedAndTimestampTicksIssueNoSQL() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        try lattice.transaction {
            for index in 0..<512 {
                try lattice.add(Memory(content: "Memory \(index)", project: "Project \(index % 3)",
                                       createdAt: epoch.addingTimeInterval(Double(index))))
            }
        }
        let store = MenuBarActivityStore()
        store.start(lattice: lattice)
        defer { store.stop() }
        try await waitUntil { store.rows.count == 20 }
        XCTAssertEqual(store.rows.first?.label, "Memory 511")
        XCTAssertEqual(store.rows.last?.label, "Memory 492")
        let reads = store.snapshotReadCount
        let statements = Lattice.threadSQLStatementCount
        for second in 0..<60 {
            for row in store.rows {
                XCTAssertFalse(row.relativeTimestamp(at: epoch.addingTimeInterval(600 + Double(second))).isEmpty)
                XCTAssertNotNil(store.projectColors[row.project])
            }
        }
        XCTAssertEqual(Lattice.threadSQLStatementCount, statements, "Timestamp redraws must not touch SQLite")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(store.snapshotReadCount, reads, "An idle menu must not poll its table")
    }

    func testMenuUpdatesAtSameCountAndRefillsAfterDeletion() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        var memories: [Memory] = []
        try lattice.transaction {
            for index in 0..<30 {
                let memory = Memory(content: "Memory \(index)", createdAt: epoch.addingTimeInterval(Double(index)))
                try lattice.add(memory)
                memories.append(memory)
            }
        }
        let store = MenuBarActivityStore()
        store.start(lattice: lattice)
        defer { store.stop() }
        try await waitUntil { store.rows.count == 20 }
        memories[29].content = "Updated title"
        memories[29].project = "New project"
        try await waitUntil { store.rows.first?.label == "Updated title" && store.rows.first?.project == "New project" }
        XCTAssertEqual(store.rows.count, 20)
        XCTAssertNotNil(store.projectColors["New project"])
        lattice.delete(memories[29])
        try await waitUntil { store.rows.first?.label == "Memory 28" }
        XCTAssertEqual(store.rows.count, 20)
        XCTAssertEqual(store.rows.last?.label, "Memory 9")
        // A replacement preserves both table and displayed counts.
        try lattice.transaction {
            lattice.delete(memories[28])
            try lattice.add(Memory(content: "Replacement", createdAt: epoch.addingTimeInterval(100)))
        }
        try await waitUntil { store.rows.first?.label == "Replacement" }
        XCTAssertEqual(store.rows.count, 20)
    }

    func testMenuCancellationDiscardsOldGeneration() async throws {
        let first = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let second = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        try first.add(Memory(content: "Old database"))
        try second.add(Memory(content: "New database"))
        let store = MenuBarActivityStore()
        store.start(lattice: first)
        store.stop()
        store.start(lattice: second)
        defer { store.stop() }
        try await waitUntil { store.rows.first?.label == "New database" }
        try first.add(Memory(content: "Late old event"))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(store.rows.map(\.label), ["New database"])
        store.stop()
        let reads = store.snapshotReadCount
        try second.add(Memory(content: "After stop"))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(store.snapshotReadCount, reads)
    }

    func testMenuReopeningPreservesCachedRowsUntilFreshSnapshotArrives() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let memory = Memory(content: "Cached memory")
        try lattice.add(memory)
        let store = MenuBarActivityStore()
        store.start(lattice: lattice)
        defer { store.stop() }
        try await waitUntil { store.rows.first?.label == "Cached memory" }
        let cachedRows = store.rows
        store.stop()
        XCTAssertEqual(store.rows, cachedRows, "Closing the feed must retain its visible cache")
        memory.content = "Edited while closed"
        let reads = store.snapshotReadCount
        store.start(lattice: lattice)
        // No suspension: publication cannot run until this main-actor turn ends.
        XCTAssertEqual(store.rows, cachedRows, "Reopening must not flash an empty feed")
        try await waitUntil { store.rows.first?.label == "Edited while closed" }
        XCTAssertGreaterThan(store.snapshotReadCount, reads,
                             "Reopening must read latest state even if an observer missed the closed-period edit")
    }

    func testMenuCoalescesBurstIncludingWritesDuringStartup() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let store = MenuBarActivityStore()
        store.start(lattice: lattice)
        defer { store.stop() }
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        try lattice.transaction {
            for index in 0..<200 {
                try lattice.add(Memory(content: "Burst \(index)", createdAt: epoch.addingTimeInterval(Double(index))))
            }
        }
        try await waitUntil { store.rows.first?.label == "Burst 199" }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(store.rows.count, 20)
        XCTAssertLessThanOrEqual(store.snapshotReadCount, 4,
                                "A committed burst must not issue a snapshot for each row notification")
    }

    func testMenuIgnoresRecallAndEmbeddingOnlyUpdates() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let memory = Memory(content: "Visible memory")
        try lattice.add(memory)
        let store = MenuBarActivityStore()
        store.start(lattice: lattice)
        defer { store.stop() }
        try await waitUntil { store.rows.count == 1 }
        // Let any startup notification drain before measuring the recall burst.
        try await Task.sleep(for: .milliseconds(250))
        let reads = store.snapshotReadCount
        try lattice.transaction {
            memory.lastAccessedAt = Date().addingTimeInterval(1)
            memory.accessCount = 10
            memory.embedding = Vector<Float>([0.1, 0.2, 0.3])
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(store.snapshotReadCount, reads,
                       "Recall and embedding changes do not alter menu membership or displayed fields")
        memory.content = "Visible edit"
        try await waitUntil { store.rows.first?.label == "Visible edit" }
        XCTAssertGreaterThan(store.snapshotReadCount, reads)
    }

    func testMenuAuditFilteringRefreshesOnUnknownAndDisplayedFields() {
        for fields: [String?]? in [nil, [], [nil], ["futureField"], ["content"], ["topic"],
                                   ["project"], ["createdAt"], ["globalId"], ["accessCount", "content"]] {
            XCTAssertTrue(MenuBarActivityStore.affectsRows(operation: .update, changedFields: fields))
        }
        XCTAssertFalse(MenuBarActivityStore.affectsRows(operation: .update,
                                                       changedFields: ["lastAccessedAt", "accessCount", "embedding"]))
        XCTAssertFalse(MenuBarActivityStore.affectsRows(operation: .update,
                                                       changedFields: [nil, "accessCount", nil, "lastAccessedAt", nil]))
        XCTAssertTrue(MenuBarActivityStore.affectsRows(operation: .insert, changedFields: []))
        XCTAssertTrue(MenuBarActivityStore.affectsRows(operation: .delete, changedFields: []))
    }

    func testPanelSnapshotDeduplicatesProjectsAndLimitsRecentVisibleNodes() {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let nodes = (0..<100).map { index in
            NodeData(id: UUID(), project: index % 2 == 0 ? "A" : "B", topic: "general",
                     label: "Node \(index)", content: "", createdAt: epoch.addingTimeInterval(Double(index)),
                     lastAccessedAt: epoch, importance: 0)
        }
        let first = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let duplicate = Dictionary(uniqueKeysWithValues: nodes.prefix(40).map { ($0.id, $0) })
        let snapshot = GalaxyPanelSnapshot.derive(allNodes: [first, duplicate], visible: Array(nodes.prefix(80)))
        XCTAssertEqual(snapshot.totalCount, 100)
        XCTAssertEqual(snapshot.projectCounts, ["A": 50, "B": 50])
        XCTAssertEqual(snapshot.recent.count, 50)
        XCTAssertEqual(snapshot.recent.first?.label, "Node 79")
        XCTAssertEqual(snapshot.recent.last?.label, "Node 30")
    }

    func testPanelRefreshWaitsForInitialDrainThenPublishesPendingRequest() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let nodes = (0..<2).map { index in
            NodeData(id: UUID(), project: "Project", topic: "Topic", label: "Node \(index)", content: "",
                     createdAt: .distantPast, lastAccessedAt: .distantPast, importance: 0)
        }
        await galaxy.preparePanelInitialSnapshotForTesting(nodes: nodes)
        let config = DrainConfig(hiddenProjects: [], hiddenRelations: [], timeFilter: nil,
                                 is3D: true, soundEnabled: false, notificationsEnabled: false)
        // Schedule first, then begin loading before the coalescing delay ends.
        registry.panelSnapshot.refresh(from: registry)
        galaxy.drainPendingUpdate(config: config, workBudget: 0)
        registry.mergeRenderData()
        XCTAssertTrue(galaxy.isDrainingInitialSnapshot)
        XCTAssertEqual(galaxy.renderStore.nodes.count, 1)
        // A direct onAppear-style request during loading must also stay pending.
        registry.panelSnapshot.refresh(from: registry)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(registry.panelSnapshot.totalCount, 0)
        XCTAssertTrue(registry.panelSnapshot.recentNodes.isEmpty)

        galaxy.drainPendingUpdate(config: config, workBudget: 0)
        XCTAssertFalse(galaxy.isDrainingInitialSnapshot)
        // No new refresh call: the existing pending request must resume itself.
        try await waitUntil { registry.panelSnapshot.totalCount == 2 }
        XCTAssertEqual(registry.panelSnapshot.visibleCount, 2)
        XCTAssertEqual(registry.panelSnapshot.projectCounts, ["Project": 2])
    }

    func testLogTailBoundsBytesAndLinesWithoutBreakingUnicode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("engram-log-tail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("hooks.log")
        let prefix = String(repeating: "é", count: LogTailReader.maximumTailBytes)
        let lines = (0..<600).map { "2026-09-08T12:00:00Z [memory-hooks] Line \($0) 🌌" }
        try (prefix + "\n" + lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let tail = LogTailReader.tailLines(path: file.path)
        XCTAssertEqual(tail.count, 500)
        XCTAssertEqual(tail.first, lines[100])
        XCTAssertEqual(tail.last, lines[599])
        let entries = LogTailReader.read(sources: [LogSource(id: "hooks", label: "Hooks", path: file.path, icon: "", color: .cyan)])
        XCTAssertEqual(entries.count, 500)
        XCTAssertEqual(entries.first?.message, "Line 100 🌌")
        XCTAssertNotNil(entries.first?.timestamp)
        XCTAssertTrue(LogTailReader.tailLines(path: directory.appendingPathComponent("absent.log").path).isEmpty)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for a panel snapshot")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
