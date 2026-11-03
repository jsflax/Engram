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
                        session.updateHeaderHeight(height)
                    }
                    Spacer()
                    if let memory = session.selectedMemory {
                        GraphMemoryDetail(memory: memory, appearance: appearance)
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
        Picker("Memory", selection: selection) {
            Text("No selection").tag(nil as UUID?)
            ForEach(session.snapshot?.nodes ?? []) { memory in
                Text(memory.label).tag(Optional(memory.id))
            }
        }
        .pickerStyle(.menu)
        .disabled(!session.isRenderingActive || session.snapshot?.nodes.isEmpty != false)
        .accessibilityHint("Choose a memory to read its details.")
        .accessibilityIdentifier("engram.graph.memory-selection")
    }
}

@MainActor
struct GraphMemoryDetail: View {
    let memory: EngramGraphNode
    let appearance: EngramGraphAppearance
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(memory.label).font(appearance.headline)
            Text(memory.content).font(appearance.caption).lineLimit(4)
            if memory.contentIsExcerpt { Text("Excerpt").font(.caption2).foregroundStyle(appearance.secondaryText) }
        }
        // Keep the compact visual card, but expose every authorized character to assistive
        // technology. An exported excerpt must never be described as a complete memory.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(memory.label))
        .accessibilityValue(Text(memory.contentIsExcerpt ? "Excerpt. \(memory.content)" : memory.content))
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("engram.graph.selected-memory")
    }
}
