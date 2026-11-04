import AppKit
import SwiftUI
import EngramRealityKit
import EngramGraphContract

/// Native host tokens for graph controls and detail cards. The intrinsic dark canvas
/// and its geometry/material palette remain Engram's, even inside a light host panel.
/// This is an in-process Swift API, not an ABI.
public struct EngramGraphAppearance {
    public var colorScheme: ColorScheme = .dark
    public var background: Color = .black
    public var primaryText: Color = .primary
    public var secondaryText: Color = .secondary
    public var accent: Color = .accentColor
    public var headline: Font = .headline
    public var caption: Font = .caption
    public var cardRadius: CGFloat = 12
    public init() {}
}

/// Engram's native graph renderer, scoped to one already-authorized session. The embedding host
/// owns authentication, window activation and effects. Use one surface per session instance.
@MainActor
public struct EngramGraphSurface: View {
    private let session: EngramGraphSession
    private let appearance: EngramGraphAppearance
    public init(session: EngramGraphSession, appearance: EngramGraphAppearance = .init()) {
        self.session = session; self.appearance = appearance
    }
    public var body: some View {
        GraphSurfaceBridge(session: session, appearance: appearance).id(ObjectIdentifier(session))
    }
}

@MainActor
private struct GraphSurfaceBridge: NSViewRepresentable {
    let session: EngramGraphSession
    let appearance: EngramGraphAppearance
    final class Coordinator {
        let session: EngramGraphSession
        let token = UUID()
        init(session: EngramGraphSession) { self.session = session }
    }
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeNSView(context: Context) -> GraphContainer {
        let view = GraphContainer(session: session, token: context.coordinator.token, appearance: appearance)
        do { try session.attachSurface(context.coordinator.token, view: view) }
        catch { view.showUnavailable() }
        return view
    }
    func updateNSView(_ view: GraphContainer, context: Context) { view.update(appearance) }
    static func dismantleNSView(_ view: GraphContainer, coordinator: Coordinator) {
        coordinator.session.detachSurface(coordinator.token)
    }
}

@MainActor
private final class GraphContainer: NSView {
    private let hosting: NSHostingView<GraphContent>
    private weak var session: EngramGraphSession?
    private let token: UUID
    override var acceptsFirstResponder: Bool { true }
    init(session: EngramGraphSession, token: UUID, appearance: EngramGraphAppearance) {
        self.session = session; self.token = token
        hosting = NSHostingView(rootView: GraphContent(session: session, appearance: appearance))
        super.init(frame: .zero)
        hosting.frame = bounds; hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }
    required init?(coder: NSCoder) { nil }
    func update(_ appearance: EngramGraphAppearance) {
        guard let session else { return }
        hosting.rootView = GraphContent(session: session, appearance: appearance)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        session?.surfaceWindowChanged(token)
    }
    func showUnavailable() {
        hosting.removeFromSuperview()
        let label = NSTextField(labelWithString: "Graph instance unavailable")
        label.frame = bounds; label.autoresizingMask = [.width, .height]
        addSubview(label)
    }
}

@MainActor
private struct GraphContent: View {
    @Bindable var session: EngramGraphSession
    let appearance: EngramGraphAppearance
    @State private var headerHeight: CGFloat = 0
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                appearance.background
                if let scene = session.scene, !session.isRevoked {
                    EngramRealityView(scene: scene, isActive: session.isRenderingActive)
                        .contentShape(Rectangle())
                        .focusable()
                        .gesture(DragGesture(minimumDistance: 3)
                            .onChanged { session.drag(dx: $0.translation.width, dy: $0.translation.height) }
                            .onEnded { _ in session.endDrag() })
                        .simultaneousGesture(SpatialTapGesture()
                            .onEnded { session.select(at: $0.location, size: geometry.size) })
                } else {
                    ContentUnavailableView(session.isRevoked ? "Connection unavailable" : "Project graph",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text(session.loadState == .loading ? "Loading graph…" : "Your project graph will appear here."))
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.identity.scope.project).font(appearance.headline)
                            status.font(appearance.caption).foregroundStyle(appearance.secondaryText)
                        }
                        Spacer()
                        GraphMemoryPicker(session: session)
                            .frame(maxWidth: 200)
                        Button("Fit", systemImage: "arrow.up.left.and.arrow.down.right") { session.fitGraph() }
                            .disabled(!session.isRenderingActive || session.snapshot?.nodes.isEmpty != false)
                    }
                    .padding(12)
                    .background(appearance.background, in: RoundedRectangle(cornerRadius: appearance.cardRadius))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        headerHeight = height
                        session.updateHeaderHeight(height)
                    }
                    Spacer(minLength: 0)
                    if let memory = session.selectedMemory {
                        GraphMemoryDetail(memory: memory, appearance: appearance,
                            maximumHeight: max(0, geometry.size.height - headerHeight - 80))
                        .padding(12).frame(maxWidth: min(360, max(0, geometry.size.width - 32)), alignment: .leading)
                        .background(appearance.background, in: RoundedRectangle(cornerRadius: appearance.cardRadius))
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            session.updateDetailHeight(height, for: memory.id)
                        }
                        .id(memory.id) // A same-height replacement card still gets its own measurement.
                    }
                }
                .padding(16)
            }
            .clipped()
            .onChange(of: geometry.size, initial: true) { _, size in
                session.updateViewport(size)
            }
        }
        .foregroundStyle(appearance.primaryText)
        .tint(appearance.accent)
        // This is a nested hosting root; honor the host locally, not as a window preference.
        .environment(\.colorScheme, appearance.colorScheme)
        .task(id: session.scenePreparationKey) {
            guard !Task.isCancelled else { return }
            await session.prepareSceneIfNeeded()
        }
    }

    private var status: Text {
        if session.isRevoked { return Text("Access ended") }
        if session.loadState == .loading { return Text(session.snapshot == nil ? "Loading…" : "Updating…") }
        if session.loadState == .failed { return Text(session.snapshot == nil ? "Couldn’t load graph" : "Refresh unavailable · showing saved graph") }
        guard let snapshot = session.snapshot else { return Text("Waiting for project data") }
        let suffix = snapshot.completeness == .limitReached ? " · result limit reached" : ""
        return Text("\(snapshot.nodes.count) memories · \(snapshot.edges.count) connections\(suffix)")
    }
}

/// A native keyboard/VoiceOver path to the same selection as spatial taps. The binding does not
/// capture a snapshot or keep a second selection; the session checks current lifetime/membership.
@MainActor
struct GraphMemoryPicker: View {
    @Bindable var session: EngramGraphSession
    var selection: Binding<UUID?> {
        Binding(get: { session.selectedNode }, set: { session.select($0) })
    }
    var body: some View {
        GraphMemoryPopUp(items: (session.snapshot?.nodes ?? []).map { .init(id: $0.id, label: $0.label) },
                         selectedID: session.selectedNode,
                         enabled: session.isRenderingActive && session.snapshot?.nodes.isEmpty == false,
                         selection: selection)
    }
}

/// Apply metadata to the real popup rather than a combined SwiftUI accessibility element.
/// AppKit supplies its role, selected value, enabled state and keyboard/menu behavior.
@MainActor
private struct GraphMemoryPopUp: NSViewRepresentable {
    struct Item: Equatable {
        let id: UUID
        let label: String
    }
    let items: [Item]
    let selectedID: UUID?
    let enabled: Bool
    let selection: Binding<UUID?>
    @Environment(\.colorScheme) private var colorScheme

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<UUID?>?
        var items: [Item]?

        @objc func choose(_ sender: NSPopUpButton) {
            guard sender.isEnabled, let selection, let item = sender.selectedItem else { return }
            if let id = item.representedObject as? UUID {
                selection.wrappedValue = id
            } else if item === sender.item(at: 0) {
                selection.wrappedValue = nil
            }
            // A retained menu action may be refused by the current session guard.
            select(selection.wrappedValue, in: sender)
        }

        func select(_ id: UUID?, in view: NSPopUpButton) {
            let index = id.flatMap { selected in
                view.itemArray.firstIndex { ($0.representedObject as? UUID) == selected }
            } ?? 0
            view.selectItem(at: index)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSPopUpButton {
        let view = NSPopUpButton(frame: .zero, pullsDown: false)
        view.target = context.coordinator
        view.action = #selector(Coordinator.choose(_:))
        view.setAccessibilityIdentifier("engram.graph.memory-selection")
        view.setAccessibilityLabel("Memory")
        view.setAccessibilityHelp("Choose a memory to read its details.")
        // AppKit exposes the popup cell as the accessibility element.
        view.cell?.setAccessibilityIdentifier("engram.graph.memory-selection")
        view.cell?.setAccessibilityLabel("Memory")
        view.cell?.setAccessibilityHelp("Choose a memory to read its details.")
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        return view
    }
    func updateNSView(_ view: NSPopUpButton, context: Context) {
        context.coordinator.selection = selection
        if context.coordinator.items != items {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(NSMenuItem(title: "No selection", action: nil, keyEquivalent: ""))
            for item in items {
                // Add individual menu items: duplicate memory labels must retain distinct IDs.
                let entry = NSMenuItem(title: item.label, action: nil, keyEquivalent: "")
                entry.representedObject = item.id as NSUUID
                menu.addItem(entry)
            }
            view.menu = menu
            context.coordinator.items = items
        }
        context.coordinator.select(selectedID, in: view)
        view.isEnabled = enabled
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    }
    static func dismantleNSView(_ view: NSPopUpButton, coordinator: Coordinator) {
        coordinator.selection = nil
        coordinator.items = nil
        view.target = nil
        view.action = nil
        view.isEnabled = false
        view.removeAllItems()
    }
}

@MainActor
struct GraphMemoryDetail: View {
    let memory: EngramGraphNode
    let appearance: EngramGraphAppearance
    var maximumHeight: CGFloat = 240
    @State private var expanded = false

    private var boundedHeight: CGFloat {
        maximumHeight.isFinite ? max(0, min(320, maximumHeight)) : 0
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if expanded {
                ScrollView(.vertical) {
                    expandedDetail
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("engram.graph.memory-reader")
            } else {
                detail(lineLimit: 4)
            }
            Button(expanded ? "Show less" : memory.contentIsExcerpt ? "Read excerpt" : "Read memory") {
                expanded.toggle()
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("engram.graph.memory-reading-toggle")
        }
        // Reserve the measured header, outer/card padding and both stack gaps. The expanded
        // reader scrolls inside the existing graph instead of growing beyond its host panel.
        .frame(height: expanded ? boundedHeight : nil, alignment: .topLeading)
        .frame(maxHeight: boundedHeight, alignment: .topLeading)
        .clipped()
        .onChange(of: memory.id) { _, _ in expanded = false }
    }

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(memory.label).font(appearance.headline)
                .accessibilityHidden(true)
                .background(GraphMemoryMetadataAccessibility(text: memory.label, heading: true))
            if memory.contentIsExcerpt {
                Text("Excerpt").font(.caption2).foregroundStyle(appearance.secondaryText)
                    .accessibilityHidden(true)
                    .background(GraphMemoryMetadataAccessibility(text: "Excerpt", heading: false))
            }
            Text(memory.content).font(appearance.caption).lineLimit(nil)
                .textSelection(.enabled)
        }
        // Text selection has a native TextKit accessibility child inside the scroll view.
        // Keep the heading, excerpt qualifier and complete body as ordered children.
        .accessibilityElement(children: .contain)
    }

    private func detail(lineLimit: Int?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(memory.label).font(appearance.headline)
            Text(memory.content).font(appearance.caption).lineLimit(lineLimit)
                .textSelection(.enabled)
            if memory.contentIsExcerpt { Text("Excerpt").font(.caption2).foregroundStyle(appearance.secondaryText) }
        }
        // Expose every authorized character in either presentation. An exported excerpt must
        // never be described as a complete memory; expansion does not fetch or widen its scope.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(memory.label))
        .accessibilityValue(Text(memory.contentIsExcerpt ? "Excerpt. \(memory.content)" : memory.content))
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("engram.graph.selected-memory")
    }
}

/// Keep the visible SwiftUI typography and its exact bounds, while exposing metadata as native
/// scroll-area children beside TextKit's selectable body. The synthetic Text AX node is hidden
/// only for these labels, so there is one semantic element for each visible title/qualifier.
@MainActor
private struct GraphMemoryMetadataAccessibility: NSViewRepresentable {
    let text: String
    let heading: Bool

    final class MetadataView: NSView {
        var text = ""
        var heading = false
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? {
            if heading, #available(macOS 26.0, *) { return NSAccessibility.Role(rawValue: "AXHeading") }
            return .staticText
        }
        override func accessibilityValue() -> Any? { text }
        override func accessibilityChildren() -> [Any]? { [] }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> MetadataView {
        let view = MetadataView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: MetadataView, context: Context) {
        view.text = text
        view.heading = heading
    }
}
