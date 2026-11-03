import AppKit
import SwiftUI
import Testing
import EngramGraphContract
@testable import EngramGraphSurface

@Suite("Native graph memory accessibility", .serialized, .timeLimit(.minutes(1))) @MainActor
struct GraphAccessibilityTests {
    @Test(arguments: ["removed", "hidden", "detached", "revoked"])
    func pickerUsesCurrentSelectionAndFencesRetainedActions(change: String) throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let picker = GraphMemoryPicker(session: fixture.session)
        // Spatial selection and the native control share one state and one persistence callback.
        var saved: [UUID?] = []
        fixture.session.onStateChange = { _, state in saved.append(state.selectedNode) }
        fixture.session.select(fixture.nodes[0].id)
        let retained = picker.selection
        #expect(retained.wrappedValue == fixture.nodes[0].id)
        retained.wrappedValue = fixture.nodes[1].id
        #expect(fixture.session.selectedMemory?.id == fixture.nodes[1].id)
        #expect(saved == [fixture.nodes[0].id, fixture.nodes[1].id])
        switch change {
        case "removed": try fixture.publish([fixture.nodes[1]], revision: 2)
        case "hidden": fixture.session.setVisibility(.hidden)
        case "detached": fixture.session.detachSurface(fixture.token)
        default: fixture.session.invalidate()
        }
        let accepted = fixture.session.selectedNode
        retained.wrappedValue = fixture.nodes[0].id // A menu can outlive its snapshot or surface.
        #expect(fixture.session.selectedNode == accepted)
        #expect(fixture.session.data.selectedNode == accepted)
        #expect(saved.count == 2)
        #expect(fixture.session.scene == nil)
    }

    @Test(arguments: [false, true])
    func nativePickerExposesSelectionAndLifetimeAvailability(active: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.session.select(fixture.nodes[1].id)
        if !active { fixture.session.setVisibility(.hidden) }
        let host = fixture.host(GraphMemoryPicker(session: fixture.session))
        let element = try await requireElement("engram.graph.memory-selection", in: host)
        #expect(element.accessibilityRole() == .popUpButton)
        #expect(element.accessibilityLabel() == "Memory")
        #expect(element.accessibilityValue() as? String == fixture.nodes[1].label)
        #expect(element.isAccessibilityEnabled() == active)
        #expect(fixture.session.scene == nil)
    }

    @Test(arguments: [false, true])
    func selectedDetailExposesAllAuthorizedTextAndMarksExcerpts(excerpt: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        // Distinct end text lies well beyond the four-line visual preview, including Unicode.
        let content = (1...12).map { "Line \($0): a longer memory detail 🧭" }.joined(separator: "\n") + "\nFinal authorized sentence."
        let node = EngramGraphNode(id: UUID(), project: "project", topic: "architecture", label: "Selected memory",
                                   content: content, contentIsExcerpt: excerpt, importance: 1, isHub: false)
        try fixture.publish([node], revision: 2)
        GraphMemoryPicker(session: fixture.session).selection.wrappedValue = node.id
        let selected = try #require(fixture.session.selectedMemory)
        let host = fixture.host(GraphMemoryDetail(memory: selected, appearance: .init()))
        let element = try await requireElement("engram.graph.selected-memory", in: host)
        #expect(element.accessibilityLabel() == node.label)
        #expect(element.accessibilityValue() as? String == (excerpt ? "Excerpt. " : "") + content)
        #expect(fixture.session.scene == nil)
    }

    private func requireElement(_ identifier: String, in host: NSView) async throws -> any NSAccessibilityProtocol {
        // Swift Testing is not NSApplication.run(). Service AppKit's display/run-loop
        // boundary instead of spinning only the Swift concurrency executor.
        #expect(Thread.isMainThread)
        #expect(host.window?.isVisible == true)
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            settleHost(host)
            if let element = find(identifier, in: host) { return element }
            await Task.yield()
        } while ContinuousClock.now < deadline
        return try #require(find(identifier, in: host),
            "Hosted AX element missing; window visible: \(host.window?.isVisible == true), root AX children: \(host.accessibilityChildren()?.count ?? 0)")
    }

    private func settleHost(_ host: NSView) {
        host.window?.contentView?.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        // Synchronous helper is intentionally bounded; no second timer or task owner.
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }

    private func find(_ identifier: String, in object: any NSAccessibilityProtocol, depth: Int = 0)
        -> (any NSAccessibilityProtocol)? {
        guard depth < 32 else { return nil }
        if object.accessibilityIdentifier() == identifier { return object }
        for child in object.accessibilityChildren() ?? [] {
            if let accessible = child as? any NSAccessibilityProtocol,
               let result = find(identifier, in: accessible, depth: depth + 1) { return result }
        }
        return nil
    }
}

/// Visible hosted controls for in-process AX inspection only: no graph scene, Metal, store, credentials or network.
@MainActor
private final class Fixture {
    let session: EngramGraphSession
    let window: NSWindow
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
    let token = UUID()
    let nodes: [EngramGraphNode]

    init() throws {
        _ = NSApplication.shared
        let scope = try EngramGraphScope(workspaceID: "workspace", project: "project", topics: ["architecture"])
        let identity = try EngramGraphSessionIdentity(connectionID: "connection", documentID: "document",
            documentLifetimeID: "lifetime", instanceID: "instance", scope: scope)
        session = EngramGraphSession(identity: identity)
        nodes = ["First memory", "Second memory"].map {
            EngramGraphNode(id: UUID(), project: "project", topic: "architecture", label: $0,
                            content: "Content", importance: 1, isHub: false)
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
                          styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = root
        try session.attachSurface(token, view: root)
        session.setVisibility(.visible)
        try publish(nodes, revision: 1)
    }

    func publish(_ nodes: [EngramGraphNode], revision: UInt64) throws {
        let snapshot = try EngramGraphSnapshot(scope: session.identity.scope, revision: revision,
            completeness: .complete, nodes: nodes, edges: [])
        try session.apply(snapshot, from: session.identity, for: session.beginLoading())
    }

    func host<Content: View>(_ content: Content) -> NSView {
        // CI need not have VoiceOver running. Enable the public SwiftUI accessibility
        // environment for this test root, without changing system or user AX settings.
        let view = NSHostingView(rootView: content.environment(\.accessibilityEnabled, true))
        view.frame = root.bounds; root.addSubview(view)
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        return view
    }

    func close() {
        session.invalidate(); session.detachSurface(token)
        window.orderOut(nil)
        window.contentView = nil; window.close()
    }
}
