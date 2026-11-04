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
        #expect(element.accessibilityLabel() == node.label, "Hosted detail AX: \(element.diagnostic())")
        #expect(element.accessibilityValue() as? String == (excerpt ? "Excerpt. " : "") + content,
                "Hosted detail AX: \(element.diagnostic())")
        #expect(fixture.session.scene == nil)
    }

    @Test(arguments: ["removed", "hidden", "detached", "revoked"])
    func nativePopupActionsKeepDuplicateLabelsDistinctAndFenceRetainedActions(change: String) async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let nodes = fixture.nodes.map {
            EngramGraphNode(id: $0.id, project: "project", topic: "architecture", label: "Same label",
                            content: $0.content, importance: 1, isHub: false)
        }
        try fixture.publish(nodes, revision: 2)
        let host = fixture.host(GraphMemoryPicker(session: fixture.session))
        // Keep the original semantic AX assertions above. This lookup exercises the actual
        // AppKit action route as well, including two separate items with identical labels.
        _ = try await requireElement("engram.graph.memory-selection", in: host)
        let popup = try #require(nativePopup(in: host))
        #expect(popup.numberOfItems == 3)
        #expect(popup.item(at: 1)?.title == popup.item(at: 2)?.title)
        var saved: [UUID?] = []
        fixture.session.onStateChange = { _, state in saved.append(state.selectedNode) }
        popup.selectItem(at: 2)
        let sent = popup.sendAction(popup.action, to: popup.target)
        #expect(sent)
        #expect(fixture.session.selectedNode == nodes[1].id)
        #expect(saved == [nodes[1].id])
        fixture.session.select(nodes[0].id)
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            settleHost(host)
            await Task.yield()
        } while (popup.selectedItem?.representedObject as? UUID) != nodes[0].id && ContinuousClock.now < deadline
        #expect((popup.selectedItem?.representedObject as? UUID) == nodes[0].id)
        switch change {
        case "removed": try fixture.publish([nodes[1]], revision: 3)
        case "hidden": fixture.session.setVisibility(.hidden)
        case "detached": fixture.session.detachSurface(fixture.token)
        default: fixture.session.invalidate()
        }
        let accepted = fixture.session.selectedNode
        let savedCount = saved.count
        // Do not settle SwiftUI first: the old native menu can still be retained by AppKit.
        popup.selectItem(at: 1)
        _ = popup.sendAction(popup.action, to: popup.target)
        #expect(fixture.session.selectedNode == accepted)
        #expect(fixture.session.data.selectedNode == accepted)
        #expect(saved.count == savedCount)
        #expect(fixture.session.scene == nil)
    }

    @Test(arguments: [120.0, 220.0])
    func memoryReaderScrollsLongContentWithinHostAndResetsSelection(height: Double) async throws {
        let maximumHeight = CGFloat(height)
        let fixture = try Fixture()
        defer { fixture.close() }
        let content = (1...80).map { "Line \($0): authorized memory detail with enough text to scroll." }
            .joined(separator: "\n") + "\nFinal authorized sentence."
        let first = EngramGraphNode(id: UUID(), project: "project", topic: "architecture", label: "Long memory",
                                   content: content, importance: 1, isHub: false)
        try fixture.publish([first, fixture.nodes[1]], revision: 2)
        fixture.session.select(first.id)
        var saved: [UUID?] = []
        fixture.session.onStateChange = { _, state in saved.append(state.selectedNode) }
        let host = fixture.host(SelectedDetailFixture(session: fixture.session, maximumHeight: maximumHeight)
            .frame(width: 320, height: maximumHeight, alignment: .topLeading))
        let toggle = try await requireElement("engram.graph.memory-reading-toggle", in: host)
        #expect(toggle.accessibilityLabel() == "Read memory")
        #expect(nativeScrollView(in: host) == nil)
        #expect(toggle.performPress(), "Read action: \(toggle.diagnostic())")
        let scroll = try await requireScrollView(in: host)
        #expect(scroll.accessibilityRole() == .scrollArea)
        let text = try await requireAccessibleTextNodes([first.label, content], in: scroll, host: host)
        let titleIndex = try #require(text.firstIndex { $0.hasText(first.label) })
        let bodyIndex = try #require(text.firstIndex { $0.accessibilityValue() as? String == content })
        #expect(titleIndex < bodyIndex)
        if #available(macOS 26.0, *) { #expect(text[titleIndex].accessibilityRole()?.rawValue == "AXHeading") }
        #expect(!text.contains { $0.hasText("Excerpt") })
        #expect(text[bodyIndex].accessibilityValue() as? String == content)
        let document = try #require(scroll.documentView)
        #expect(scroll.bounds.height > 0 && scroll.bounds.height <= maximumHeight)
        #expect(document.bounds.height > scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.maxY))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.documentVisibleRect.maxY >= document.bounds.maxY - 1)
        let collapse = try await requireElement("engram.graph.memory-reading-toggle", in: host)
        #expect(collapse.accessibilityLabel() == "Show less")
        #expect(collapse.performPress(), "Collapse action: \(collapse.diagnostic())")
        let deadline = ContinuousClock.now + .seconds(2)
        repeat { settleHost(host); await Task.yield() }
        while nativeScrollView(in: host) != nil && ContinuousClock.now < deadline
        #expect(nativeScrollView(in: host) == nil)
        let reopen = try await requireElement("engram.graph.memory-reading-toggle", in: host)
        #expect(reopen.performPress(), "Reopen action: \(reopen.diagnostic())")
        _ = try await requireScrollView(in: host)
        fixture.session.select(fixture.nodes[1].id)
        let selectionDeadline = ContinuousClock.now + .seconds(2)
        repeat { settleHost(host); await Task.yield() }
        while find("engram.graph.selected-memory", in: host)?.accessibilityLabel() != fixture.nodes[1].label
            && ContinuousClock.now < selectionDeadline
        let next = try await requireElement("engram.graph.selected-memory", in: host)
        #expect(next.accessibilityValue() as? String == fixture.nodes[1].content)
        #expect(nativeScrollView(in: host) == nil)
        #expect(find("engram.graph.memory-reading-toggle", in: host)?.accessibilityLabel() == "Read memory")
        #expect(saved == [fixture.nodes[1].id]) // Expanding/collapsing never changes graph selection/camera.
        #expect(fixture.session.scene == nil)
    }

    @Test
    func expandedExcerptRetainsHeadingQualifierAndAllAuthorizedText() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let content = (1...40).map { "Authorized excerpt line \($0)." }.joined(separator: "\n")
        let memory = EngramGraphNode(id: UUID(), project: "project", topic: "architecture", label: "Excerpt memory",
                                     content: content, contentIsExcerpt: true, importance: 1, isHub: false)
        try fixture.publish([memory], revision: 2)
        fixture.session.select(memory.id)
        let host = fixture.host(SelectedDetailFixture(session: fixture.session, maximumHeight: 220)
            .frame(width: 320, height: 220, alignment: .topLeading))
        let toggle = try await requireElement("engram.graph.memory-reading-toggle", in: host)
        #expect(toggle.accessibilityLabel() == "Read excerpt")
        #expect(toggle.performPress(), "Excerpt action: \(toggle.diagnostic())")
        let scroll = try await requireScrollView(in: host)
        #expect(scroll.accessibilityRole() == .scrollArea)
        let text = try await requireAccessibleTextNodes([memory.label, "Excerpt", content], in: scroll, host: host)
        let titleIndex = try #require(text.firstIndex { $0.hasText(memory.label) })
        let qualifierIndex = try #require(text.firstIndex { $0.hasText("Excerpt") })
        let bodyIndex = try #require(text.firstIndex { $0.accessibilityValue() as? String == content })
        #expect(titleIndex < qualifierIndex && qualifierIndex < bodyIndex)
        if #available(macOS 26.0, *) { #expect(text[titleIndex].accessibilityRole()?.rawValue == "AXHeading") }
        #expect(text[bodyIndex].accessibilityValue() as? String == content)
        #expect(fixture.session.scene == nil)
    }

    private func requireScrollView(in host: NSView) async throws -> NSScrollView {
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            settleHost(host)
            if let scroll = nativeScrollView(in: host) { return scroll }
            await Task.yield()
        } while ContinuousClock.now < deadline
        return try #require(nativeScrollView(in: host), "Expanded native scroll area missing: \(accessibilityDiagnostic(host))")
    }

    private func requireAccessibleTextNodes(_ expected: [String], in scroll: NSScrollView,
                                            host: NSView) async throws -> [AXElementReader] {
        // Native view creation can precede SwiftUI's AX child publication. Use the same bounded
        // AppKit settling boundary as requireElement, then require every exact semantic value.
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            settleHost(host)
            let nodes = accessibleTextNodes(in: scroll)
            if expected.allSatisfy({ value in nodes.contains { $0.hasText(value) } }) { return nodes }
            await Task.yield()
        } while ContinuousClock.now < deadline
        let nodes = accessibleTextNodes(in: scroll)
        let complete = expected.allSatisfy { value in nodes.contains { $0.hasText(value) } }
        let primaryContents = scroll.accessibilityContents() ?? []
        let primaryTrees = primaryContents.prefix(4).compactMap { child -> String? in
            guard let object = child as? NSObject else { return nil }
            return accessibilityDiagnostic(object)
        }.joined(separator: " | ")
        let navigation = scroll.accessibilityChildrenInNavigationOrder() ?? []
        let navigationNodes = navigation.prefix(4).compactMap { child -> String? in
            guard let object = child as? NSObject else { return nil }
            return AXElementReader(object: object).diagnostic()
        }.joined(separator: " | ")
        let documentTree = scroll.documentView.map { accessibilityDiagnostic($0) } ?? "<nil>"
        try #require(complete, "Expanded scoped AX content missing; primaryContents count=\(primaryContents.count): \(primaryTrees); navigation count=\(navigation.count): \(navigationNodes); document: \(documentTree); scroll: \(accessibilityDiagnostic(scroll)); host: \(accessibilityDiagnostic(host))")
        return nodes
    }

    private func accessibleTextNodes(in root: NSObject) -> [AXElementReader] {
        var result: [AXElementReader] = []
        var visited: Set<ObjectIdentifier> = []
        func visit(_ object: NSObject, depth: Int) {
            guard depth < 32, visited.count < 128, visited.insert(ObjectIdentifier(object)).inserted else { return }
            let node = AXElementReader(object: object)
            if node.accessibilityRole() == .staticText || node.accessibilityRole()?.rawValue == "AXHeading" {
                result.append(node)
            }
            for child in node.children {
                if let object = child as? NSObject { visit(object, depth: depth + 1) }
            }
        }
        visit(root, depth: 0)
        return result
    }

    private func nativeScrollView(in view: NSView, depth: Int = 0) -> NSScrollView? {
        guard depth < 32 else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let scroll = nativeScrollView(in: child, depth: depth + 1) { return scroll }
        }
        return nil
    }

    private func nativePopup(in view: NSView, depth: Int = 0) -> NSPopUpButton? {
        guard depth < 32 else { return nil }
        if let popup = view as? NSPopUpButton,
           popup.accessibilityIdentifier() == "engram.graph.memory-selection" { return popup }
        for child in view.subviews {
            if let popup = nativePopup(in: child, depth: depth + 1) { return popup }
        }
        return nil
    }

    private func requireElement(_ identifier: String, in host: NSView) async throws -> AXElementReader {
        // Swift Testing is not NSApplication.run(). Service AppKit's display/run-loop
        // boundary instead of spinning only the Swift concurrency executor.
        #expect(host.window?.isVisible == true)
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            settleHost(host)
            if let element = find(identifier, in: host) { return element }
            await Task.yield()
        } while ContinuousClock.now < deadline
        return try #require(find(identifier, in: host),
            "Hosted AX element missing; window visible: \(host.window?.isVisible == true), tree: \(accessibilityDiagnostic(host))")
    }

    private func settleHost(_ host: NSView) {
        #expect(Thread.isMainThread)
        host.window?.contentView?.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        // Synchronous helper is intentionally bounded; no second timer or task owner.
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }

    private func find(_ identifier: String, in object: NSObject, depth: Int = 0) -> AXElementReader? {
        guard depth < 32 else { return nil }
        let reader = AXElementReader(object: object)
        if reader.accessibilityIdentifier() == identifier { return reader }
        for child in reader.children {
            if let accessible = child as? NSObject,
               let result = find(identifier, in: accessible, depth: depth + 1) { return result }
        }
        return nil
    }

    private func accessibilityDiagnostic(_ root: NSObject) -> String {
        var rows: [String] = []
        func visit(_ object: NSObject, depth: Int) {
            guard depth < 4, rows.count < 24 else { return }
            let reader = AXElementReader(object: object)
            rows.append("\(depth):\(type(of: object)) full=\(object is any NSAccessibilityProtocol) element=\(object is any NSAccessibilityElementProtocol) \(reader.diagnostic())")
            for child in reader.children.prefix(16) {
                if let object = child as? NSObject { visit(object, depth: depth + 1) }
            }
        }
        visit(root, depth: 0)
        return rows.joined(separator: "; ")
    }
}

/// NSHostingView returns [Any] children. A native child need not adopt the full
/// NSAccessibilityProtocol; its public object getters can still be implemented.
@MainActor
private struct AXElementReader {
    let object: NSObject

    private var modern: (any NSAccessibilityProtocol)? { object as? any NSAccessibilityProtocol }

    private func legacyValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        guard object.accessibilityAttributeNames().contains(attribute) else { return nil }
        return object.accessibilityAttributeValue(attribute)
    }

    // Only known zero-argument Objective-C object getters are dispatched this way.
    // Never use perform for scalar AXEnabled, frames, actions, or private selectors.
    private func objectValue(_ selector: Selector) -> Any? {
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    var children: [Any] {
        if let children = modern?.accessibilityChildren() { return children }
        if let children = objectValue(#selector(NSAccessibilityProtocol.accessibilityChildren)) as? [Any] {
            return children
        }
        return legacyValue(.children) as? [Any] ?? []
    }

    func accessibilityIdentifier() -> String? {
        if let identifier = modern?.accessibilityIdentifier(), !identifier.isEmpty { return identifier }
        if let element = object as? any NSAccessibilityElementProtocol,
           let identifier = element.accessibilityIdentifier?(), !identifier.isEmpty { return identifier }
        if let identifier = objectValue(#selector(NSAccessibilityProtocol.accessibilityIdentifier)) as? String,
           !identifier.isEmpty { return identifier }
        guard let identifier = legacyValue(.identifier) as? String, !identifier.isEmpty else { return nil }
        return identifier
    }

    func accessibilityRole() -> NSAccessibility.Role? {
        if let role = modern?.accessibilityRole() { return role }
        if let role = objectValue(#selector(NSAccessibilityProtocol.accessibilityRole)) as? String {
            return NSAccessibility.Role(rawValue: role)
        }
        guard let role = legacyValue(.role) as? String else { return nil }
        return NSAccessibility.Role(rawValue: role)
    }

    func accessibilityLabel() -> String? {
        if let label = modern?.accessibilityLabel() { return label }
        if let label = objectValue(#selector(NSAccessibilityProtocol.accessibilityLabel)) as? String { return label }
        return legacyValue(.description) as? String
    }

    func accessibilityValue() -> Any? {
        if let value = modern?.accessibilityValue() { return value }
        if let value = objectValue(#selector(NSAccessibilityProtocol.accessibilityValue)) { return value }
        return legacyValue(.value)
    }

    func hasText(_ text: String) -> Bool {
        accessibilityLabel() == text || accessibilityValue() as? String == text
    }

    func performPress() -> Bool {
        if let modern { return modern.accessibilityPerformPress() }
        // SwiftUI's AXLink node exposes the public method without adopting the full protocol.
        // AnyObject lookup uses AppKit's imported BOOL signature; never dispatch scalar actions
        // through the object-returning getter helper, or attempt another route after a result.
        if object.responds(to: #selector(NSAccessibilityProtocol.accessibilityPerformPress)) {
            return (object as AnyObject).accessibilityPerformPress?() ?? false
        }
        guard object.accessibilityActionNames().contains(.press) else { return false }
        object.accessibilityPerformAction(.press)
        return true
    }

    func diagnostic() -> String {
        let fields: [(String, Selector, NSAccessibility.Attribute)] = [
            ("id", #selector(NSAccessibilityProtocol.accessibilityIdentifier), .identifier),
            ("role", #selector(NSAccessibilityProtocol.accessibilityRole), .role),
            ("label", #selector(NSAccessibilityProtocol.accessibilityLabel), .description),
            ("value", #selector(NSAccessibilityProtocol.accessibilityValue), .value),
        ]
        func summary(_ value: Any?) -> String {
            guard let value else { return "<nil>" }
            // Fixture text only; cap every value independently inside the existing tree bound.
            return String(String(describing: value).prefix(160))
        }
        let advertised = object.accessibilityAttributeNames()
        let values = fields.map { name, selector, attribute in
            "\(name)[responds=\(object.responds(to: selector)), direct=\(summary(objectValue(selector))), "
                + "advertised=\(advertised.contains(attribute)), legacy=\(summary(legacyValue(attribute)))]"
        }
        let childrenSelector = #selector(NSAccessibilityProtocol.accessibilityChildren)
        let directChildren = objectValue(childrenSelector) as? [Any]
        let pressSelector = #selector(NSAccessibilityProtocol.accessibilityPerformPress)
        let actions = object.accessibilityActionNames().prefix(8).map(\.rawValue)
        return values.joined(separator: " ")
            + " children[responds=\(object.responds(to: childrenSelector)), directCount=\(directChildren?.count.description ?? "<nil>")]"
            + " press[full=\(modern != nil), responds=\(object.responds(to: pressSelector)), legacyActions=\(actions)]"
    }

    func isAccessibilityEnabled() -> Bool? {
        if let modern { return modern.isAccessibilityEnabled() }
        // Missing/wrongly typed AXEnabled must fail even the disabled-control case.
        return legacyValue(.enabled) as? Bool
    }
}

/// The production selected-memory identity resets local reader expansion on selection changes.
@MainActor
private struct SelectedDetailFixture: View {
    @Bindable var session: EngramGraphSession
    let maximumHeight: CGFloat
    var body: some View {
        if let memory = session.selectedMemory {
            GraphMemoryDetail(memory: memory, appearance: .init(), maximumHeight: maximumHeight).id(memory.id)
        }
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
