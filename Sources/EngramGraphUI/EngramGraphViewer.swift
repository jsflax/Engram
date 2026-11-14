import SwiftUI
import EngramRealityKit

/// Engram's embedded, exact-graph viewer. This view never discovers stores or accounts.
@MainActor
public struct EngramGraphViewer: View {
    @Bindable private var controller: EngramGraphViewerController
    private let isActive: Bool
    private let onSelection: ((UUID?) -> Void)?
    @Environment(\.scenePhase) private var scenePhase
    @State private var showFilters = false
    #if os(iOS)
    @State private var mobileSheet: MobileSheet?
    @State private var measuredChromeBottom: CGFloat?
    @State private var measuredInspectorTop: CGFloat?
    private enum MobileSheet: String, Identifiable {
        case filters, coverage, results, memory
        var id: String { rawValue }
    }
    #endif
    @Namespace private var viewportCoordinateSpace
    public init(controller: EngramGraphViewerController, isActive: Bool = true,
                onSelection: ((UUID?) -> Void)? = nil) {
        self.controller = controller; self.isActive = isActive; self.onSelection = onSelection
    }
    private var effectiveActive: Bool { isActive && scenePhase == .active }
    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color(red: 0.025, green: 0.035, blue: 0.06)
                if let manager = controller.sceneManager {
                    EngramRealityView(scene: manager.scene, isActive: effectiveActive)
                        .id(ObjectIdentifier(manager.scene))
                        #if os(iOS)
                        .mask { Path(graphInteractionRect(in: geometry.size)).fill(.white) }
                        #endif
                    let interactionRect = graphInteractionRect(in: geometry.size)
                    RKInputSurface(camera: manager.camera, isActive: effectiveActive,
                        onProjectStep: { controller.nextProject(direction: $0) }) { point, _ in
                        controller.tap(at: CGPoint(x: point.x + interactionRect.minX,
                            y: point.y + interactionRect.minY), size: geometry.size)
                    }
                    .frame(width: interactionRect.width, height: interactionRect.height)
                    .offset(x: interactionRect.minX, y: interactionRect.minY)
                    .accessibilityLabel("Memory graph. Drag to look, pan to move, pinch to zoom. Tap a memory to inspect it.")
                    .accessibilityIdentifier("engram.graph.surface")
                }
                if let snapshot = controller.snapshot {
                    #if os(iOS)
                    mobileOverlay(snapshot, size: geometry.size)
                    #else
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 8) {
                            #if os(iOS)
                            searchField
                            layoutControls
                            #else
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .top) { searchField; layoutControls }
                                VStack(alignment: .leading) { searchField; layoutControls }
                            }
                            #endif
                            coverage(snapshot)
                            if !controller.query.isEmpty { searchResults }
                            if showFilters { filters.frame(maxWidth: 340, maxHeight: geometry.size.height * 0.38) }
                        }
                        .background {
                            GeometryReader { overlay in
                                Color.clear.preference(key: EngramGraphOverlayBottomKey.self,
                                    value: overlay.frame(in: .named(viewportCoordinateSpace)).maxY)
                            }
                        }
                        graphContentSpace(snapshot)
                        if let memory = controller.selectedMemory {
                            VStack(alignment: .leading, spacing: 8) {
                                detailActions.font(.caption)
                                EngramGraphMemoryDetailPanel(memory: memory, connectedCount: controller.connectedCount,
                                    projectColor: controller.color(for: memory.project), onClose: { controller.select(nil) })
                            }
                            .frame(maxWidth: 540, maxHeight: max(160, min(400, geometry.size.height * 0.44)))
                        }
                    }
                    .padding(12)
                    #endif
                } else {
                    ContentUnavailableView("No memory graph selected", systemImage: "point.3.connected.trianglepath.dotted")
                }
                if let error = controller.rendererError {
                    Text(error).font(.callout).padding(16)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: 420).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: viewportCoordinateSpace)
            .onPreferenceChange(EngramGraphOverlayBottomKey.self) { bottom in
                if let bottom {
                    #if os(iOS)
                    measuredChromeBottom = bottom
                    #endif
                    controller.setOverlayBottom(bottom)
                    controller.recordLifecycleDiagnostic(.graphChrome, values: ["bottom": Double(bottom)])
                }
            }
            #if os(iOS)
            .onPreferenceChange(EngramGraphInspectorTopKey.self) { top in
                measuredInspectorTop = top
                controller.setInspectorTop(top)
                controller.recordLifecycleDiagnostic(.graphInspector, values: top.map { ["top": Double($0)] } ?? [:], flags: ["present": top != nil])
            }
            #endif
            .foregroundStyle(.white)
            .clipShape(Rectangle())
            .onChange(of: geometry.size, initial: true) { _, size in
                controller.recordLifecycleDiagnostic(.graphGeometry, values: ["width": Double(size.width), "height": Double(size.height)])
                #if os(iOS)
                controller.setViewportSize(size, adaptingToOcclusion: true)
                #else
                controller.setViewportSize(size)
                #endif
            }
        }
        #if os(iOS)
        .onChange(of: controller.snapshot?.scopeID) { _, _ in mobileSheet = nil }
        .onChange(of: mobileSheet) { _, destination in
            controller.recordLifecycleDiagnostic(.mobileSheetChanged, flags: sheetDiagnosticFlags(destination))
        }
        .sheet(item: $mobileSheet) { destination in
            mobileSheetContent(destination)
                .onAppear { controller.recordLifecycleDiagnostic(.mobileSheetAppeared, flags: sheetDiagnosticFlags(destination)) }
                .onDisappear { controller.recordLifecycleDiagnostic(.mobileSheetDisappeared, flags: sheetDiagnosticFlags(destination)) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
        #endif
        .task(id: effectiveActive) {
            guard !Task.isCancelled else { return }
            if effectiveActive { controller.setActive(true) }
            else { await controller.pauseAndDrain() }
        }
        .onAppear { controller.recordLifecycleDiagnostic(.graphAppeared) }
        .onDisappear {
            controller.recordLifecycleDiagnostic(.graphDisappearing)
            let current = controller.sceneManager
            controller.setActive(false)
            Task { @MainActor in
                await current?.drain()
                await controller.drainRetiredWork()
            }
        }
        .onChange(of: controller.selectedMemoryID) { _, id in
            onSelection?(id)
            #if os(iOS)
            if id == nil, mobileSheet == .memory { mobileSheet = nil }
            #endif
        }
        .onKeyPress(.escape) { controller.select(nil); return .handled }
        .onKeyPress(.tab) { controller.cycleConnectedMemory(); return .handled }
        .onKeyPress("=") { controller.zoom(100); return .handled }
        .onKeyPress("-") { controller.zoom(-100); return .handled }
    }

    private func graphInteractionRect(in size: CGSize) -> CGRect {
        #if os(iOS)
        let top = min(max(0, measuredChromeBottom ?? 0), size.height)
        let bottom = min(max(0, measuredInspectorTop ?? size.height), size.height)
        return CGRect(x: 0, y: top, width: size.width, height: max(0, bottom - top))
        #else
        return CGRect(origin: .zero, size: size)
        #endif
    }

    @ViewBuilder private func graphContentSpace(_ snapshot: EngramGraphSnapshot) -> some View {
        if snapshot.memories.isEmpty {
            // The header participates in this stack's layout, so empty content
            // occupies only the space below the controls in embedded viewports.
            ViewThatFits(in: .vertical) {
                ContentUnavailableView("No memories in this graph", systemImage: "point.3.connected.trianglepath.dotted")
                Label("No memories in this graph", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.callout).padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .allowsHitTesting(false)
        } else {
            Spacer(minLength: 4)
        }
    }

    #if os(iOS)
    /// Keep the canvas interactive between its controls and inspector. Short
    /// viewports use native sheets instead of compressing interactive rows.
    private func mobileOverlay(_ snapshot: EngramGraphSnapshot, size: CGSize) -> some View {
        let compact = size.height < 600
        // Keyboard avoidance changes height without making a portrait phone wide.
        // Reserve enough width for editable search, native controls and spacing.
        let horizontalControls = compact && size.width >= 600
        let controlsLayout = horizontalControls
            ? AnyLayout(HStackLayout(spacing: 12))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                // A single child retains its native first responder and local focus
                // state while keyboard/rotation changes the surrounding layout.
                controlsLayout {
                    searchField.frame(minWidth: horizontalControls ? 160 : nil, maxWidth: .infinity)
                    layoutControls.fixedSize(horizontal: horizontalControls, vertical: false)
                }
                if compact {
                    HStack(spacing: 8) {
                        if !controller.query.isEmpty {
                            Button { mobileSheet = .results } label: {
                                Label("Results (\(controller.searchMatches.count))", systemImage: "list.bullet")
                                    .engramGraphTouchTarget(alignment: .leading)
                            }
                        } else {
                            Text(graphCountText(memories: snapshot.memories.count, connections: snapshot.edges.count))
                                .font(.caption2)
                        }
                        Spacer(minLength: 0)
                        if controller.selectedMemory != nil {
                            Button { mobileSheet = .memory } label: {
                                Label("Memory details", systemImage: "doc.text")
                                    .engramGraphTouchTarget()
                            }
                        }
                        if snapshot.coverage.isPartial {
                            Button { mobileSheet = .coverage } label: {
                                Text("Partial").font(.caption2).engramGraphTouchTarget()
                            }.foregroundStyle(.yellow).accessibilityLabel("Partial graph details")
                        }
                    }.font(.system(size: 11, design: .monospaced)).buttonStyle(.plain)
                } else {
                    mobileCoverage(snapshot)
                    if !controller.query.isEmpty, !controller.searchResults.isEmpty {
                        searchResultRows
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: min(108, CGFloat(controller.searchResults.count) * 54))
                            .padding(8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { overlay in
                    Color.clear.preference(key: EngramGraphOverlayBottomKey.self,
                        value: overlay.frame(in: .named(viewportCoordinateSpace)).maxY)
                }
            }
            graphContentSpace(snapshot)
            if !compact, let memory = controller.selectedMemory {
                VStack(alignment: .leading, spacing: 4) {
                    detailActions.font(.caption)
                    EngramGraphMemoryDetailPanel(memory: memory, connectedCount: controller.connectedCount,
                        projectColor: controller.color(for: memory.project), onClose: { controller.select(nil) })
                }
                .frame(maxWidth: 540)
                .frame(height: min(280, size.height * 0.40))
                .background {
                    GeometryReader { inspector in
                        Color.clear.preference(key: EngramGraphInspectorTopKey.self,
                            value: inspector.frame(in: .named(viewportCoordinateSpace)).minY)
                    }
                }
            }
        }
        .padding(12)
        .onChange(of: controller.selectedMemoryID) { _, id in
            if compact, id != nil { mobileSheet = .memory }
        }
    }

    private func mobileCoverage(_ snapshot: EngramGraphSnapshot) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(graphCountText(memories: snapshot.memories.count, connections: snapshot.edges.count))
                if controller.visibleMemoryCount != snapshot.memories.count || controller.visibleEdgeCount != snapshot.edges.count {
                    Text(graphCountText(memories: controller.visibleMemoryCount, connections: controller.visibleEdgeCount) + " visible")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if snapshot.coverage.isPartial { Text("Partial graph").foregroundStyle(.yellow) }
                if let message = controller.projectionMessage {
                    Text(message).font(.caption2).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Button { mobileSheet = .coverage } label: {
                Image(systemName: "info.circle").engramGraphTouchTarget()
            }.buttonStyle(.plain).accessibilityLabel("Graph details")
        }
        .font(.caption)
        .padding(.leading, 10).padding(.trailing, 2)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("engram.graph.coverage")
    }

    private func sheetDiagnosticFlags(_ destination: MobileSheet?) -> [String: Bool] {
        ["presented": destination != nil, "results": destination == .results, "filters": destination == .filters,
         "coverage": destination == .coverage, "memory": destination == .memory, "effectiveActive": effectiveActive]
    }

    private func mobileSheetContent(_ destination: MobileSheet) -> some View {
        NavigationStack {
            Group {
                switch destination {
                case .filters:
                    filters
                case .coverage:
                    ScrollView {
                        if let snapshot = controller.snapshot {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Total: " + graphCountText(memories: snapshot.coverage.totalMemoryCount, connections: snapshot.coverage.totalEdgeCount))
                                Text("Loaded: " + graphCountText(memories: snapshot.memories.count, connections: snapshot.edges.count))
                                if snapshot.coverage.isPartial {
                                    Text("Partial graph: search and layout cover the loaded memories. More data exists in this graph.")
                                        .foregroundStyle(.yellow)
                                }
                                if let message = snapshot.coverage.statusMessage { Text(message) }
                                if snapshot.coverage.omittedEmbeddingCount + snapshot.coverage.invalidEmbeddingCount > 0 {
                                    Text("\(snapshot.coverage.omittedEmbeddingCount) embeddings omitted · \(snapshot.coverage.invalidEmbeddingCount) invalid embeddings excluded")
                                }
                                if let message = controller.projectionMessage { Text(message) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                case .results:
                    searchResultRows
                case .memory:
                    if let memory = controller.selectedMemory {
                        VStack(alignment: .leading, spacing: 8) {
                            detailActions.font(.caption)
                            EngramGraphMemoryDetailPanel(memory: memory, connectedCount: controller.connectedCount,
                                projectColor: controller.color(for: memory.project), onClose: { controller.select(nil) })
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(.white)
            .navigationTitle(destination == .filters ? "Graph filters" : destination == .coverage ? "Graph details" : destination == .results ? "Search results" : "Memory details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { mobileSheet = nil } label: {
                        Text("Done").frame(minWidth: 48, minHeight: 48)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }
    #endif

    private var searchField: some View {
        EngramGraphSearchField(text: Binding(get: { controller.query }, set: { controller.setQuery($0) }),
                               matchCount: controller.searchMatches.count)
            .accessibilityIdentifier("engram.graph.search")
    }
    private var layoutPicker: some View {
        EngramGraphLayoutPicker(mode: controller.layout, progress: controller.projectionProgress,
                               onModeChange: controller.setLayout)
    }
    @ViewBuilder private var layoutControls: some View {
        #if os(iOS)
        HStack(spacing: 4) {
            layoutPicker
            Spacer(minLength: 0)
            Button { mobileSheet = .filters } label: {
                Image(systemName: "line.3.horizontal.decrease.circle").engramGraphTouchTarget()
            }.accessibilityLabel("Project and relation filters")
            Button { controller.centerGraph() } label: {
                Image(systemName: "viewfinder").engramGraphTouchTarget()
            }.accessibilityLabel("Center graph")
            Menu {
                Button("Previous project", systemImage: "chevron.left") { controller.nextProject(direction: -1) }
                Button("Next project", systemImage: "chevron.right") { controller.nextProject() }
                Button(controller.soundEnabled ? "Mute graph sound" : "Enable graph sound",
                       systemImage: controller.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill") {
                    controller.setSoundEnabled(!controller.soundEnabled)
                }
                Button("Graph details", systemImage: "info.circle") { mobileSheet = .coverage }
            } label: {
                Image(systemName: "ellipsis.circle").engramGraphTouchTarget()
            }.accessibilityLabel("More graph controls")
        }
        .buttonStyle(.plain)
        #else
        HStack(spacing: 8) {
            layoutPicker
            toolbarButtons
        }.buttonStyle(.plain)
        #endif
    }
    private var toolbarButtons: some View {
        Group {
            Button { showFilters.toggle() } label: {
                Image(systemName: "line.3.horizontal.decrease.circle").engramGraphTouchTarget()
            }
                .accessibilityLabel("Project and relation filters")
            Button { controller.nextProject(direction: -1) } label: {
                Image(systemName: "chevron.left").engramGraphTouchTarget()
            }
                .accessibilityLabel("Previous project")
            Button { controller.nextProject() } label: {
                Image(systemName: "chevron.right").engramGraphTouchTarget()
            }
                .accessibilityLabel("Next project")
            Button { controller.setSoundEnabled(!controller.soundEnabled) } label: {
                Image(systemName: controller.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .engramGraphTouchTarget()
            }.accessibilityLabel(controller.soundEnabled ? "Mute graph sound" : "Enable graph sound")
            Button { controller.centerGraph() } label: {
                Image(systemName: "viewfinder").engramGraphTouchTarget()
            }
                .accessibilityLabel("Center graph")
        }
    }
    @ViewBuilder private var detailActions: some View {
        #if os(iOS)
        ViewThatFits(in: .horizontal) {
            HStack { detailButtons }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 0) { detailButtons }
        }
        #else
        HStack { detailButtons }
        #endif
    }
    private var detailButtons: some View {
        Group {
            Button { controller.cycleConnectedMemory() } label: {
                Label("Next connection", systemImage: "arrow.triangle.branch")
                    .engramGraphTouchTarget(alignment: .leading)
            }
            .disabled(controller.connectedCount == 0)
            if controller.selectionIsHub {
                Button { controller.toggleSelectedHub() } label: {
                    Label("Expand / collapse hub", systemImage: "point.3.connected.trianglepath.dotted")
                        .engramGraphTouchTarget(alignment: .leading)
                }
            }
        }
    }
    private func coverage(_ snapshot: EngramGraphSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(snapshot.title).font(.headline)
            Text(graphCountText(memories: snapshot.memories.count, connections: snapshot.edges.count))
            if controller.visibleMemoryCount != snapshot.memories.count || controller.visibleEdgeCount != snapshot.edges.count {
                Text(graphCountText(memories: controller.visibleMemoryCount, connections: controller.visibleEdgeCount) + " visible with these filters")
            }
            if snapshot.coverage.isPartial {
                Text("Partial graph: search and layout cover the loaded memories. More data exists in this graph.").foregroundStyle(.yellow)
            }
            if let message = snapshot.coverage.statusMessage { Text(message) }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Total: " + graphCountText(memories: snapshot.coverage.totalMemoryCount, connections: snapshot.coverage.totalEdgeCount))
                    if snapshot.coverage.omittedEmbeddingCount + snapshot.coverage.invalidEmbeddingCount > 0 {
                        Text("\(snapshot.coverage.omittedEmbeddingCount) embeddings omitted · \(snapshot.coverage.invalidEmbeddingCount) invalid embeddings excluded")
                    }
                }.font(.caption2)
            } label: {
                Text("Graph details").engramGraphTouchTarget(alignment: .leading)
            }
            if let message = controller.projectionMessage { Text(message) }
        }
        .font(.caption)
        .padding(8).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("engram.graph.coverage")
    }
    private var filters: some View {
        EngramGraphFilterList(projects: controller.projects, hiddenProjects: controller.hiddenProjects,
            hiddenRelations: controller.hiddenRelations, relationCounts: controller.relationCounts,
            colorMap: Dictionary(uniqueKeysWithValues: controller.projects.map { ($0, controller.color(for: $0)) }),
            toggleProject: controller.toggleProject, toggleRelation: controller.toggleRelation,
            driveToProject: controller.navigateProject)
            #if !os(iOS)
            .padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            #endif
    }
    private var searchResultRows: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(controller.searchResults) { memory in
                    Button {
                        controller.focus(memory.id)
                        #if os(iOS)
                        if mobileSheet == .results { mobileSheet = .memory }
                        #endif
                    } label: {
                        Text("\(memory.project) · \(engramGraphLabel(content: memory.content, topic: memory.topic))")
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            .engramGraphTouchTarget(alignment: .leading)
                    }.buttonStyle(.plain)
                }
                if controller.searchMatches.count > 100 {
                    Text("Showing the first 100 matches. Refine the search to find another memory.").foregroundStyle(.secondary)
                }
            }
        }
    }
    private var searchResults: some View {
        searchResultRows

        .font(.system(size: 11, design: .monospaced))
        .frame(maxWidth: 400, maxHeight: 140)
        .padding(8).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct EngramGraphOverlayBottomKey: PreferenceKey {
    static var defaultValue: CGFloat? { nil }
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = max(value ?? 0, next) }
    }
}

private func graphCountText(memories: Int, connections: Int) -> String {
    let memoryLabel = memories == 1 ? "memory" : "memories"
    let connectionLabel = connections == 1 ? "connection" : "connections"
    return "\(memories) \(memoryLabel) · \(connections) \(connectionLabel)"
}

#if os(iOS)
private struct EngramGraphInspectorTopKey: PreferenceKey {
    static var defaultValue: CGFloat? { nil }
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = min(value ?? next, next) }
    }
}
#endif
