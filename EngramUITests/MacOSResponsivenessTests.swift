import EngramKit
import Lattice
import XCTest

/// Uses an isolated, reproducible graph. App-side event-to-draw samples exclude
/// XCTest's accessibility polling and animation/quiescence overhead.
@MainActor
final class MacOSResponsivenessTests: XCTestCase {
    private let app = XCUIApplication()
    private var directory: URL!
    private var panelCSV: URL { directory.appendingPathComponent("panels.csv") }
    private var frameCSV: URL { directory.appendingPathComponent("frames.csv") }

    override func tearDownWithError() throws {
        defer {
            app.terminate()
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
        // Keep diagnostics even when continueAfterFailure=false aborts an
        // assertion before the method reaches its success-path reporting.
        if directory != nil {
            let phaseCSV = URL(fileURLWithPath: panelCSV.path + ".phases.csv")
            for path in [panelCSV, frameCSV, phaseCSV] where FileManager.default.fileExists(atPath: path.path) {
                let attachment = XCTAttachment(contentsOfFile: path)
                attachment.name = path.lastPathComponent
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        if app.state == .runningForeground {
            let window = app.windows.firstMatch
            if window.exists {
                // App-level snapshots include SwiftUI descendants that can
                // be absent from a lazy window-only debug description. Strip
                // the native menu tree (including unrelated Recent Items).
                let description = app.debugDescription
                let scopedDescription = description.range(of: "\n  MenuBar,").map {
                    String(description[..<$0.lowerBound])
                } ?? window.debugDescription
                let hierarchy = XCTAttachment(string: scopedDescription)
                hierarchy.name = "Final graph window accessibility"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
            }
            attachScreenshot(name: "Final app state")
            let feed = activityFeedDialog
            if feed.exists { attachScreenshot(name: "Final activity feed", element: feed) }
        }
    }

    func testMenusRespondWhileGraphRenders() async throws {
        continueAfterFailure = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("engram-responsiveness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database: URL
        let count: Int
        if let source = ProcessInfo.processInfo.environment["ENGRAM_PERF_DB_SNAPSHOT"] {
            database = URL(fileURLWithPath: try makePerformanceDatabaseCopy(source: source, directory: directory))
            let copiedLattice = try Lattice(Memory.self, Edge.self, SyncConfig.self,
                                           configuration: .init(fileURL: database, migration: engramMigrations))
            count = copiedLattice.objects(Memory.self).count
            XCTAssertGreaterThan(count, 0, "The copied performance database must contain memories")
            guard count > 0 else { throw InvalidSamples() }
        } else {
            count = Int(ProcessInfo.processInfo.environment["ENGRAM_PERF_NODE_COUNT"] ?? "4000") ?? 4000
            XCTAssertTrue([4000, 40000].contains(count), "Use the 4,000 or 40,000 node fixture")
            guard [4000, 40000].contains(count) else { throw InvalidSamples() }
            database = directory.appendingPathComponent("memory.sqlite")
            try seedFixture(at: database, count: count)
        }
        app.launchEnvironment["CLAUDE_MEMORY_DB"] = database.path
        app.launchEnvironment["ENGRAM_PERF_ISOLATED"] = "1"
        app.launchEnvironment["ENGRAM_TEST_NO_NOTIFY"] = "1"
        app.launchEnvironment["ENGRAM_FRAME_STATS"] = frameCSV.path
        app.launchEnvironment["ENGRAM_PANEL_STATS"] = panelCSV.path
        app.launchArguments += ["-subscription_status", "active", "-subscription_tier", "premium"]
        let launchStarted = ProcessInfo.processInfo.systemUptime
        let readinessTask = MacOSResponsivenessTests.trackReadiness(
            path: frameCSV.path, count: count, launchStarted: launchStarted)
        defer { readinessTask.cancel() }
        app.launch()
        try activateGraphWindowIfNeeded()
        let window = app.windows.firstMatch
        try requireExists(window, timeout: 30)
        try await ensureSidebarPinned(true)

        // Begin interacting as soon as controls exist, before waiting for loading.
        try await exerciseTabs()
        guard let graphReadyMilliseconds = await readinessTask.value else {
            XCTFail("Graph did not render its full \(count)-memory fixture within 120 seconds")
            throw InvalidSamples()
        }
        let readiness = XCTAttachment(string: "Graph ready (launch call to observed full rendered count): \(String(format: "%.1f", graphReadyMilliseconds)) ms; memories: \(count). Background sampling every 20 ms; includes frame CSV flush delay and concurrent startup menu interactions.")
        readiness.name = "Graph readiness"
        readiness.lifetime = .keepAlways
        add(readiness)
        attachScreenshot(name: "Ready graph with sidebar")
        try await ensureSidebarPinned(false)
        // Window.hover() chooses an accessibility hit point near the traffic
        // lights, still inside the sidebar's hover-to-peek region. Move into
        // the graph explicitly so the unpinned sidebar can actually close.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        try await waitUntil { !self.app.buttons["sidebar.tab.Graph"].exists }
        attachScreenshot(name: "Ready graph")
        try await ensureSidebarPinned(true)
        for _ in 0..<4 { try await exerciseTabs() }

        let nativeMenu = app.menuBarItems["View"]
        try requireExists(nativeMenu, timeout: 5)
        var nativeTimings: [Double] = []
        for _ in 0..<5 {
            let start = ProcessInfo.processInfo.systemUptime
            nativeMenu.click()
            let visibleItem = nativeMenu.menus.firstMatch.menuItems.firstMatch
            try await waitUntil(timeout: 3) { visibleItem.exists && visibleItem.isHittable }
            nativeTimings.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            app.typeKey(.escape, modifierFlags: [])
        }
        let nativeReport = XCTAttachment(string: "Native View menu input/accessibility round trip ms (includes XCTest overhead): \(nativeTimings)")
        nativeReport.lifetime = .keepAlways
        add(nativeReport)

        let statusItem = app.descendants(matching: .any).matching(identifier: "engram.status-item").firstMatch
        try requireExists(statusItem, timeout: 5, message: "Engram's status item must be accessible")
        for index in 0..<5 {
            statusItem.click()
            let feed = activityFeedDialog
            try requireExists(feed, timeout: 5)
            try await waitUntil { ((try? self.responseSamples().filter { $0.action == "menu.feed" }.count) ?? 0) > index }
            if index == 0 {
                let memoryCount = feed.staticTexts["menu.memory-count"]
                try await waitUntil {
                    guard memoryCount.exists else { return false }
                    let displayedCount = (memoryCount.value as? String) ?? memoryCount.label
                    return displayedCount == "\(min(20, count))"
                }
                attachScreenshot(name: "Status activity feed", element: feed)
            }
            // MenuBarExtra's window need not receive application-level Escape.
            // Use its ordinary status-item toggle and verify dismissal before
            // the next measured opening, rather than alternating open/close.
            statusItem.click()
            try await waitUntil { !feed.exists }
        }

        let samples = try responseSamples()
        let required = ["sidebar.open", "sidebar.Graph", "sidebar.Logs", "sidebar.Settings", "sidebar.Account", "menu.feed"]
        for action in required {
            let actionSamples = samples.filter { $0.action == action }
            XCTAssertTrue(actionSamples.allSatisfy { $0.clockOrigin == "event" },
                          "\(action) has callback-only timing; a real input timestamp is required for the latency gate")
            guard actionSamples.allSatisfy({ $0.clockOrigin == "event" }) else { throw InvalidSamples() }
            let timings = actionSamples.map(\.milliseconds).sorted()
            XCTAssertFalse(timings.isEmpty, "Missing event-to-draw samples for \(action)")
            guard !timings.isEmpty else { throw InvalidSamples() }
            let p95 = timings[min(Int(Double(timings.count) * 0.95), timings.count - 1)]
            XCTAssertLessThanOrEqual(p95, 100, "\(action) first-draw p95 exceeds 100 ms: \(timings)")
            guard p95 <= 100 else { throw InvalidSamples() }
        }
    }

    /// Separate from timing gates: all lazy rows remain reachable by ordinary
    /// scrolling, without clicking project/relation controls or using live data.
    func testGraphSidebarRetainsOffscreenProjectsAndRelations() async throws {
        continueAfterFailure = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("engram-sidebar-scroll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("memory.sqlite")
        try seedSidebarScrollFixture(at: database)
        app.launchEnvironment["CLAUDE_MEMORY_DB"] = database.path
        app.launchEnvironment["ENGRAM_PERF_ISOLATED"] = "1"
        app.launchEnvironment["ENGRAM_TEST_NO_NOTIFY"] = "1"
        app.launchEnvironment["ENGRAM_FRAME_STATS"] = frameCSV.path
        app.launch()
        try activateGraphWindowIfNeeded()
        try requireExists(app.windows.firstMatch, timeout: 30)
        try await waitUntil(timeout: 30) {
            Self.latestRenderedNodeCount(at: self.frameCSV.path) == 256
        }
        try await ensureSidebarPinned(true)
        let graphTab = app.buttons["sidebar.tab.Graph"]
        try requireExists(graphTab, timeout: 5)
        graphTab.click()
        let scroll = app.scrollViews["sidebar.graph-scroll"]
        try requireExists(scroll, timeout: 5)
        let firstProject = scroll.buttons.matching(identifier: "sidebar.project.Sidebar Project 000").firstMatch
        let lastProject = scroll.buttons.matching(identifier: "sidebar.project.Sidebar Project 127").firstMatch
        let lastRelation = scroll.buttons.matching(identifier: "sidebar.relation.supersedes").firstMatch
        try await waitUntil { firstProject.exists && firstProject.isHittable }
        XCTAssertFalse(lastProject.exists && lastProject.isHittable,
                       "The fixture must extend beyond the initial viewport")
        try scrollToVisible(lastProject, in: scroll, deltaY: -400)
        attachScreenshot(name: "Last lazy project row")
        try scrollToVisible(lastRelation, in: scroll, deltaY: -400)
        attachScreenshot(name: "Last lazy relation row")
        try scrollToVisible(firstProject, in: scroll, deltaY: 400)
    }

    private func scrollToVisible(_ row: XCUIElement, in scroll: XCUIElement, deltaY: CGFloat) throws {
        // A 128-row fixture needs approximately ten 400-point scrolls. Keep
        // a strict bound, and never use a row click to force AX materialization.
        for _ in 0..<24 {
            if row.exists && row.isHittable { return }
            scroll.scroll(byDeltaX: 0, deltaY: deltaY)
        }
        let visible = row.exists && row.isHittable
        XCTAssertTrue(visible, "The offscreen sidebar row must remain reachable by scrolling")
        guard visible else { throw InvalidSamples() }
    }

    nonisolated private static func trackReadiness(path: String, count: Int, launchStarted: TimeInterval)
        -> Task<Double?, Never> {
        Task<Double?, Never>.detached(priority: .utility) {
            while !Task.isCancelled && ProcessInfo.processInfo.systemUptime - launchStarted < 120 {
                if MacOSResponsivenessTests.latestRenderedNodeCount(at: path) == count {
                    return (ProcessInfo.processInfo.systemUptime - launchStarted) * 1000
                }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return nil }
            }
            return nil
        }
    }

    private func activateGraphWindowIfNeeded() throws {
        app.activate()
        let window = app.windows.firstMatch
        guard !window.exists else { return }

        // macOS can restore this menu-bar app with no document windows. Use
        // its normal command without changing saved state or production code.
        let fileMenu = app.menuBarItems["File"]
        guard fileMenu.waitForExistence(timeout: 5) else {
            XCTFail("Engram's File menu must be accessible to open its graph window")
            throw InvalidSamples()
        }
        guard !window.exists else { return }
        fileMenu.click()
        let newWindow = app.menuItems["New Engram Window"]
        guard newWindow.waitForExistence(timeout: 5) else {
            app.typeKey(.escape, modifierFlags: [])
            XCTFail("Engram's New Engram Window command must be accessible")
            throw InvalidSamples()
        }
        // Recheck after menu discovery/quiescence: a delayed initial window
        // must not cause the test to create a second graph renderer.
        if window.exists {
            app.typeKey(.escape, modifierFlags: [])
        } else {
            newWindow.click()
        }
    }

    private func attachScreenshot(name: String, element: XCUIElement? = nil) {
        let target = element ?? app.windows.firstMatch
        // App-wide screenshots can include unrelated desktop windows. Keep
        // only this app's graph window or the explicitly requested feed.
        guard target.exists else { return }
        let attachment = XCTAttachment(screenshot: target.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var activityFeedDialog: XCUIElement {
        app.dialogs.containing(.any, identifier: "menu.activity-feed").firstMatch
    }

    private func requireExists(_ element: XCUIElement, timeout: TimeInterval,
                               message: String = "Required Engram control did not appear",
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let exists = element.waitForExistence(timeout: timeout)
        XCTAssertTrue(exists, message, file: file, line: line)
        // continueAfterFailure=false does not reliably unwind async tests.
        guard exists else { throw InvalidSamples() }
    }

    private func sidebarToggleIcon() throws -> XCUICoordinate {
        let toggle = app.buttons["sidebar.toggle"]
        try requireExists(toggle, timeout: 5)
        let frame = toggle.frame
        guard frame.width.isFinite, frame.height.isFinite,
              frame.width >= 28, frame.height >= 28 else {
            XCTFail("Sidebar toggle has no usable accessibility frame: \(frame)")
            throw InvalidSamples()
        }
        if frame.height <= 40 {
            return toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        }
        // SwiftUI can expose the entire sidebar + trailing 44-point toggle
        // strip as this AX button (354 points wide when open). The visible
        // icon is centered in that trailing strip, 38 + 14 points from top.
        guard frame.width >= 44, frame.height >= 66 else {
            XCTFail("Unexpected sidebar toggle strip geometry: \(frame)")
            throw InvalidSamples()
        }
        return toggle.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0))
            .withOffset(CGVector(dx: -22, dy: 38 + 14))
    }

    private func ensureSidebarPinned(_ pinned: Bool) async throws {
        let toggle = app.buttons["sidebar.toggle"]
        try requireExists(toggle, timeout: 5)
        let expectedAction = pinned ? "Unpin sidebar" : "Pin sidebar"
        guard ["Pin sidebar", "Unpin sidebar"].contains(toggle.label) else {
            XCTFail("Sidebar toggle must expose its current pin/unpin action")
            throw InvalidSamples()
        }
        if toggle.label == expectedAction { return }

        if !app.buttons["sidebar.tab.Graph"].exists {
            // Enter the sidebar tracking area from within the graph window.
            // Moving directly from the status bar onto the child button can
            // show its tooltip without entering the parent's hover region.
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
            try sidebarToggleIcon().hover()
            try await waitUntil { self.app.buttons["sidebar.tab.Graph"].exists }
        }
        // Leave the icon's tooltip region while staying within the visible
        // sidebar. Otherwise XCTest can move outside the app to dismiss the
        // tooltip, collapsing peek just before its synthesized click.
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 150, dy: 180)).hover()
        try requireExists(toggle, timeout: 5)
        if toggle.label == expectedAction { return }
        guard ["Pin sidebar", "Unpin sidebar"].contains(toggle.label) else {
            XCTFail("Sidebar toggle lost its pin/unpin action after peeking")
            throw InvalidSamples()
        }
        // Resolve after peek has inserted the sidebar. Make exactly one
        // required click and verify its effect rather than toggling blindly.
        try sidebarToggleIcon().click()
        try await waitUntil { toggle.exists && toggle.label == expectedAction }
    }

    private func exerciseTabs() async throws {
        // A copied fixture may have persisted any selected tab. Establish Graph
        // first so every measured transition below actually changes content.
        let graph = app.buttons["sidebar.tab.Graph"]
        try requireExists(graph, timeout: 5)
        graph.click()
        for tab in ["Logs", "Settings", "Account", "Graph"] {
            let action = "sidebar.\(tab)"
            let previous = (try? responseSamples().filter { $0.action == action }.count) ?? 0
            let button = app.buttons["sidebar.tab.\(tab)"]
            try requireExists(button, timeout: 5)
            button.click()
            try await waitUntil { ((try? self.responseSamples().filter { $0.action == action }.count) ?? 0) > previous }
        }
    }

    nonisolated private static func latestRenderedNodeCount(at path: String) -> Int? {
        guard let csv = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return try? RealityFrameReport.latestCompleteNodeCount(in: csv)
    }

    private func responseSamples() throws -> [(action: String, milliseconds: Double, clockOrigin: String)] {
        let csv = try String(contentsOf: panelCSV, encoding: .utf8)
        let lines = csv.split(separator: "\n")
        guard lines.first == "action,response_ms,clock_origin" else { throw InvalidSamples() }
        return try lines.dropFirst().map { line in
            let values = line.split(separator: ",")
            guard values.count == 3, let value = Double(values[1]), value.isFinite, value >= 0,
                  values[2] == "event" || values[2] == "callback" else {
                throw InvalidSamples()
            }
            return (String(values[0]), value, String(values[2]))
        }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("Timed out waiting for graph/menu instrumentation")
                throw InvalidSamples()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private struct InvalidSamples: Error {}

    private func seedSidebarScrollFixture(at url: URL) throws {
        let lattice = try Lattice(Memory.self, Edge.self, SyncConfig.self,
                                  configuration: .init(fileURL: url, migration: engramMigrations))
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let relations: [Edge.Relation] = [.relatesTo, .contradicts, .supersedes, .derivedFrom, .partOf, .summarizedBy]
        let ids = (0..<256).map { UUID(uuidString: String(format: "00000003-0000-0000-0000-%012llx", Int64($0 + 1)))! }
        try lattice.transaction {
            for index in 0..<256 {
                let memory = Memory(content: "Sidebar scrolling fixture \(index)", topic: "performance",
                                    project: String(format: "Sidebar Project %03d", index % 128),
                                    source: "isolated-sidebar-fixture", createdAt: epoch, lastAccessedAt: epoch)
                try lattice.add(memory, preservingGlobalId: ids[index])
                if index > 0 {
                    try lattice.add(Edge(sourceGlobalId: ids[index], targetGlobalId: ids[index - 1],
                                         relation: relations[index % relations.count], createdAt: epoch))
                }
            }
        }
    }

    private func seedFixture(at url: URL, count: Int) throws {
        let lattice = try Lattice(Memory.self, Edge.self, SyncConfig.self,
                                  configuration: .init(fileURL: url, migration: engramMigrations))
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let topics = ["architecture", "debugging", "patterns", "performance", "rendering"]
        func id(_ index: Int, edge: Bool = false) -> UUID {
            UUID(uuidString: String(format: "%08x-0000-0000-0000-%012llx", edge ? 2 : 1, Int64(index + 1)))!
        }
        try lattice.transaction {
            for index in 0..<count {
                let embedding = (0..<384).map { sin(Float(index * 17 + $0 * 3)) * 0.1 }
                let memory = Memory(content: "Memory \(index): deterministic graph and menu profiling",
                                    topic: topics[index % topics.count], project: "Project \(index % 8)",
                                    source: "isolated-perf-fixture", embedding: Vector<Float>(embedding),
                                    createdAt: epoch.addingTimeInterval(Double(index)), lastAccessedAt: epoch,
                                    importance: index % 5 + 1)
                try lattice.add(memory, preservingGlobalId: id(index))
                if index >= 8 {
                    let edge = Edge(sourceGlobalId: id(index), targetGlobalId: id(index - 8),
                                    relation: .relatesTo, createdAt: epoch)
                    try lattice.add(edge, preservingGlobalId: id(index, edge: true))
                }
            }
        }
    }
}
