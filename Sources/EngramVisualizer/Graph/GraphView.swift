import SwiftUI
import EngramSceneKit
import Lattice
import EngramSceneKit
import Combine
import EngramKit
import UniformTypeIdentifiers
import AppKit
import simd
import UserNotifications
import os

private let bodyLog = Logger(subsystem: "io.engram.app", category: "GraphViewBody")
typealias MemoryEdge = EngramKit.Edge

// MARK: - Root view (owns data store, simulation, and state)

struct GraphView: View {
    @Environment(\.lattice) var lattice

    // Galaxy registry — manages one or more galaxies (each with its own pipeline)
    @State var galaxyRegistry = GalaxyRegistry()

    // Primary galaxy (convenience accessor — the personal/local galaxy)
    var primaryGalaxy: Galaxy? { galaxyRegistry.galaxies["personal"] }

    // Merged render data — delegated to GalaxyRegistry for multi-galaxy support.
    // MetalSceneManager reads from the registry; GraphView accesses via these for overlays/panels.
    var renderStore: GraphRenderStore { primaryGalaxy?.renderStore ?? _fallbackRenderStore }
    @State private var _fallbackRenderStore = GraphRenderStore()

    var simulation3D: ForceSimulation3D { primaryGalaxy?.simulation3D ?? _fallbackSimulation3D }
    @State private var _fallbackSimulation3D = ForceSimulation3D()

    var embeddingProjection: EmbeddingProjection { primaryGalaxy?.embeddingProjection ?? _fallbackEmbeddingProjection }
    @State private var _fallbackEmbeddingProjection = EmbeddingProjection()

    @State var viewport = ViewportState()
    @Environment(VisualizerConfig.self) var config
    @State var selectedMemoryId: UUID?
    @State var scrollMonitor: Any?

    // Search results (owned by SearchBarView, written via bindings)
    @State var searchMatchIds: Set<UUID> = []
    @State var isSearchActive: Bool = false

    // Time slider (debounced like search)
    @State private var timeSliderDate: Date?
    @State var debouncedTimeSliderDate: Date?
    @State private var isTimelinePlaying: Bool = false

    // Sidebar (hover-to-peek, click-to-pin)
    @State private var sidebarPinned: Bool = false
    @State private var sidebarPeeking: Bool = false
    @State private var sidebarHideTask: Task<Void, Never>?
    @Environment(AccountService.self) private var accountService
    @Environment(GroupService.self) private var groupService
    var syncManager: SyncManager // don't want to observe this
    private var sidebarVisible: Bool { sidebarPinned || sidebarPeeking }

    // Embedding projection / layout mode
    @State var transitionProgress: CGFloat = 0  // 0 = force, 1 = embedding
    @State var forcePositionSnapshot: [UUID: CGPoint] = [:]
    @State var projectionTopologyVersion: UInt64 = 0

    // 3D state
    @State var forcePositionSnapshot3D: [UUID: SIMD3<Float>] = [:]
    @State var camera3DState = Camera3DState()
    @State var cameraProjectTarget: String?

    // Glow cleanup timer (1s interval — removes entries older than 4.3s)
    let glowTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Batched observer coalescing lives on renderStore (no body re-eval on insert queuing)

    // MARK: - Date range for time slider (filtered by visible projects)

    var dateRange: (earliest: Date, latest: Date) {
        var earliest = Date.distantFuture
        var latest = Date.distantPast
        for node in renderStore.nodes {
            if node.createdAt < earliest { earliest = node.createdAt }
            if node.createdAt > latest { latest = node.createdAt }
        }
        if earliest > latest { earliest = Date(); latest = Date() }
        return (earliest, latest)
    }

    // MARK: - Body

    var body: some View {
        #if ENGRAM_INSTRUMENTATION
        let _ = os_log(.fault, log: OSLog(subsystem: "io.engram.app", category: "FrameStall"), "HOTPATH: GraphView.body eval")
        let _ = bodyLog.warning("[BODY-EVAL] GraphView.body evaluated at frame \(CFAbsoluteTimeGetCurrent())")
        #endif
        GeometryReader { geo in
            graphContent(size: geo.size)
                .onAppear {
                    loadData()
                    installScrollMonitor()
                }
                .onReceive(syncManager.didConnect) {
                    handleSyncConnect()
                }
                .onDisappear {
                    removeScrollMonitor()
                }
                .onChange(of: selectedMemoryId) { oldId, newId in
                    // Auto-track focused galaxy based on selection
                    if let id = newId {
                        galaxyRegistry.focusedGalaxyId = galaxyRegistry.nodeToGalaxy[id]
                    }
                    handleSelectionChange(oldId: oldId, newId: newId, viewSize: geo.size)
                }
                .modifier(keyboardShortcuts)
                .task(id: timeSliderDate) {
                    try? await Task.sleep(for: .milliseconds(80))
                    debouncedTimeSliderDate = timeSliderDate
                }
                // Sound is played directly in flush/delete handlers (no @State needed)
                // Push search state to renderStore for Metal renderer
                .onChange(of: searchMatchIds) { _, ids in
                    for galaxy in galaxyRegistry.galaxies.values { galaxy.renderStore.searchMatchIds = ids }
                }
                .onChange(of: isSearchActive) { _, active in
                    for galaxy in galaxyRegistry.galaxies.values { galaxy.renderStore.isSearchActive = active }
                }
                .onChange(of: config.hiddenProjects) { _, _ in
                    syncDrainConfig()
                }
                .onChange(of: config.hiddenRelations) { _, _ in
                    syncDrainConfig()
                    recomputeFilteredData()
                    rebuildSimulationGraph()
                }
                .onChange(of: debouncedTimeSliderDate) { _, _ in
                    syncDrainConfig()
                    recomputeFilteredData()
                    rebuildSimulationGraph()
                }
                .onChange(of: config.soundEnabled) { _, _ in syncDrainConfig() }
                .onChange(of: config.notificationsEnabled) { _, _ in syncDrainConfig() }
                .onReceive(glowTimer) { _ in
                    let now = Date()
                    // Clean up expired glows across ALL galaxies
                    for galaxy in galaxyRegistry.galaxies.values {
                        let store = galaxy.renderStore
                        if !store.glowingNodes.isEmpty {
                            let filtered = store.glowingNodes.filter { now.timeIntervalSince($0.value) < 4.3 }
                            if filtered.count != store.glowingNodes.count {
                                store.glowingNodes = filtered
                            }
                        }
                        if !store.newNodeGlows.isEmpty {
                            let filtered = store.newNodeGlows.filter { now.timeIntervalSince($0.value) < 5.5 }
                            if filtered.count != store.newNodeGlows.count {
                                store.newNodeGlows = filtered
                            }
                        }
                        if !store.dyingNodes.isEmpty {
                            let filtered = store.dyingNodes.filter { now.timeIntervalSince($0.value.startTime) < 3.0 }
                            if filtered.count != store.dyingNodes.count {
                                store.dyingNodes = filtered
                            }
                        }
                    }
                }
        }
    }

    private var keyboardShortcuts: some ViewModifier {
        GraphKeyboardShortcuts(
            selectedMemoryId: $selectedMemoryId,
            viewport: viewport,
            cycleConnectedNode: cycleConnectedNode,
            exportToPNG: exportToPNG
        )
    }

    // MARK: - Body Helpers

    @ViewBuilder
    private func graphContent(size: CGSize) -> some View {
        let colorMap = galaxyRegistry.mergedColorMap
        ZStack {
            Color(red: 0.051, green: 0.067, blue: 0.09).ignoresSafeArea()

            graph3DView(colorMap: colorMap)
            graphOverlays(size: size, colorMap: colorMap)
            detailPanel(size: size, colorMap: colorMap)
            groupPanels(size: size)
            sidebarLayer(colorMap: colorMap)
        }
    }

    // MARK: - Group panels (management UI overlays, same idiom as detailPanel)

    @ViewBuilder
    private func groupPanels(size: CGSize) -> some View {
        // Belt to GroupService.reset()'s suspenders: group panels never
        // render signed out (reset closes them, but sign-out paths outside
        // the sidebar button — e.g. token invalidation — bypass it).
        if accountService.isSignedIn, let groupId = groupService.selectedGroupId {
            GroupDetailPanel(
                groupId: groupId,
                onClose: { groupService.selectedGroupId = nil }
            )
            .id(groupId)
            .frame(maxWidth: min(420, size.width * 0.4), maxHeight: min(560, size.height * 0.75))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(24)
            .compositingGroup()
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .animation(.spring(duration: 0.4, bounce: 0.2), value: groupService.selectedGroupId)
        }
        if accountService.isSignedIn, groupService.showCreateGroup {
            CreateGroupPanel(onClose: { groupService.showCreateGroup = false })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .transition(.opacity)
        }
    }

    // MARK: - Sidebar Layer (hover-to-peek, click-to-pin)

    @ViewBuilder
    private func sidebarLayer(colorMap: [String: Color]) -> some View {
        // Hover zone: only covers the sidebar + toggle button, not the full window
        HStack(alignment: .top, spacing: 0) {
            // Sidebar panel
            if sidebarVisible {
                SidebarView(
                    galaxyRegistry: galaxyRegistry,
                    projectionState: embeddingProjection.state,
                    toggleProject: toggleProject,
                    toggleRelation: toggleRelation,
                    switchLayoutMode: { mode in
                        switchLayoutMode(to: mode, viewSize: NSApp.keyWindow?.frame.size ?? CGSize(width: 800, height: 600))
                    },
                    driveToProject: { cameraProjectTarget = $0 },
                    accountService: accountService
                )
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            // Toggle button
            VStack {
                Button {
                    if !sidebarVisible { PanelResponseRecorder.begin("sidebar.open") }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        sidebarPinned.toggle()
                        if sidebarPinned {
                            sidebarHideTask?.cancel()
                            sidebarPeeking = false
                        }
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(sidebarPinned ? 0.9 : 0.5))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.white.opacity(sidebarPinned ? 0.12 : 0.05))
                        )
                }
                .buttonStyle(.plain)
                .help(sidebarPinned ? "Unpin sidebar" : "Pin sidebar")
                .accessibilityLabel(sidebarPinned ? "Unpin sidebar" : "Pin sidebar")
                .accessibilityIdentifier("sidebar.toggle")
                Spacer()
            }
            .frame(width: 44)
            .padding(.top, 38)
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                sidebarHideTask?.cancel()
                if !sidebarPinned && !sidebarPeeking {
                    PanelResponseRecorder.begin("sidebar.open")
                    withAnimation(.easeInOut(duration: 0.2)) {
                        sidebarPeeking = true
                    }
                }
            } else if !sidebarPinned {
                sidebarHideTask?.cancel()
                sidebarHideTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        sidebarPeeking = false
                    }
                }
            }
        }
        // Push to left edge of the ZStack
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Overlays

    @ViewBuilder
    private func graphOverlays(size: CGSize, colorMap: [String: Color]) -> some View {
        // Right column: activity log + stats overlay
        VStack(alignment: .trailing, spacing: 8) {
            if config.showActivityLog, selectedMemoryId == nil {
                ActivityLogPanel(
                    galaxyRegistry: galaxyRegistry,
                    onSelect: { id in selectedMemoryId = id }
                )
                .transition(.opacity)
            }

            Spacer()

            if config.showStatsOverlay {
                StatsOverlay(
                    galaxyRegistry: galaxyRegistry,
                    hiddenProjects: config.hiddenProjects,
                    hiddenRelations: config.hiddenRelations,
                    toggleProject: toggleProject,
                    toggleRelation: toggleRelation,
                    driveToProject: { cameraProjectTarget = $0 }
                )
                .transition(.opacity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(.easeInOut(duration: 0.25), value: selectedMemoryId == nil)

        // Top bar: search (offset right to clear sidebar toggle + traffic lights)
        VStack {
            HStack {
                Spacer().frame(width: 80) // clear traffic lights + sidebar toggle
                SearchBarView(
                    matchIds: $searchMatchIds,
                    isActive: $isSearchActive,
                    lattice: lattice
                )
                Spacer()
            }
            .padding(.top, 8)
            .padding(.horizontal, 12)
            Spacer()
        }

        // Timeline slider hidden — not useful in current state
        // VStack {
        //     Spacer()
        //     let range = dateRange
        //     TimeSliderBar(
        //         earliestDate: range.earliest,
        //         latestDate: range.latest,
        //         sliderDate: $timeSliderDate,
        //         isPlaying: $isTimelinePlaying
        //     )
        // }
    }

    @ViewBuilder
    private func detailPanel(size: CGSize, colorMap: [String: Color]) -> some View {
        if let memory = selectedMemory {
            let sid = selectedMemoryId!
            let count = galaxyRegistry.galaxyForNode(sid)?.renderStore.edgeCountByNode[sid] ?? 0
            MemoryDetailPanel(
                memory: memory,
                connectedCount: count,
                onClose: { selectedMemoryId = nil },
                colorMap: colorMap
            )
            .id(memory.globalId)
            .frame(maxWidth: min(400, size.width * 0.35), maxHeight: min(500, size.height * 0.7))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(24)
            .compositingGroup()
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .animation(.spring(duration: 0.4, bounce: 0.2), value: selectedMemoryId)
        }
    }

    // MARK: - Selected Memory (routed to correct galaxy's Lattice)

    private var selectedMemory: Memory? {
        guard let id = selectedMemoryId else { return nil }
        // Route to the galaxy that owns this node, fall back to primary lattice
        let targetLattice = galaxyRegistry.galaxyForNode(id)?.latticeRef.resolve() ?? lattice
        return targetLattice.objects(Memory.self).where { $0.globalId == id }.first
    }

    // MARK: - Helpers

    func toggleProject(_ project: String) {
        if config.hiddenProjects.contains(project) {
            config.hiddenProjects.remove(project)
            syncDrainConfig()
            showProject(project)
        } else {
            config.hiddenProjects.insert(project)
            syncDrainConfig()
            hideProject(project)
        }
    }

    /// Surgically remove a project's nodes/edges from filtered data and simulation across all galaxies.
    private func hideProject(_ project: String) {
        for galaxy in galaxyRegistry.galaxies.values {
            let store = galaxy.renderStore
            let removedIds = Set(store.nodes.filter { $0.project == project }.map(\.id))
            guard !removedIds.isEmpty else { continue }
            store.nodes.removeAll { $0.project == project }
            for id in removedIds { store.nodeById.removeValue(forKey: id) }
            let removedEdgeIds2 = Set(store.edges.filter { removedIds.contains($0.sourceId) || removedIds.contains($0.targetId) }.map(\.id))
            store.edges.removeAll { removedIds.contains($0.sourceId) || removedIds.contains($0.targetId) }
            store.filteredEdgeIds.subtract(removedEdgeIds2)
            store.visibleNodeIds.subtract(removedIds)
            store.clusterGroups = store.clusterGroups.compactMap { cluster in
                let filtered = cluster.filter { !removedIds.contains($0) }
                return filtered.count >= 2 ? filtered : nil
            }
            galaxy.recomputeDerivedData()
            store.bumpTopology()
        }
    }

    /// Surgically add a project's nodes/edges back into filtered data and simulation across all galaxies.
    private func showProject(_ project: String) {
        for galaxy in galaxyRegistry.galaxies.values {
            let store = galaxy.renderStore
            let addedNodes = store.allNodes.values.filter {
                $0.project == project &&
                (debouncedTimeSliderDate == nil || $0.createdAt <= debouncedTimeSliderDate!)
            }
            guard !addedNodes.isEmpty else { continue }
            store.nodes.append(contentsOf: addedNodes)
            for node in addedNodes { store.nodeById[node.id] = node }
            let newIds = Set(addedNodes.map(\.id))
            store.visibleNodeIds.formUnion(newIds)

            let allVisibleIds = store.visibleNodeIds
            let newEdges = store.allEdges.values.filter { edge in
                allVisibleIds.contains(edge.sourceId) && allVisibleIds.contains(edge.targetId) &&
                !config.hiddenRelations.contains(edge.relation) &&
                !store.filteredEdgeIds.contains(edge.id)
            }
            store.edges.append(contentsOf: newEdges)
            store.filteredEdgeIds.formUnion(newEdges.map(\.id))

            // Recompute hubs for this galaxy
            var hubs = Set<UUID>()
            for edge in store.allEdges.values where edge.relation == "part_of" {
                hubs.insert(edge.targetId)
            }
            store.hubs = hubs

            galaxy.recomputeDerivedData()
            store.bumpTopology()

            Task.detached {
                guard let lattice = galaxy.latticeRef.resolve() else { preconditionFailure() }
                let projectClusters = findMemoryClusters(in: lattice, project: project, minClusterSize: 2, neighborLimit: 20).clusters
                Task { @MainActor in
                    store.clusterGroups.append(contentsOf: projectClusters)
                }
            }
        }
    }

    func toggleRelation(_ relation: String) {
        if config.hiddenRelations.contains(relation) {
            config.hiddenRelations.remove(relation)
        } else {
            config.hiddenRelations.insert(relation)
        }
    }

    func uniqueProjects() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for galaxy in galaxyRegistry.galaxies.values {
            for node in galaxy.renderStore.allNodes.values {
                if seen.insert(node.project).inserted {
                    result.append(node.project)
                }
            }
        }
        return result.sorted()
    }

    private func cycleConnectedNode() {
        guard let sel = selectedMemoryId else { return }
        // Route to the galaxy that owns this node for edge lookup
        let edges = galaxyRegistry.galaxyForNode(sel)?.renderStore.allEdges ?? primaryGalaxy?.renderStore.allEdges ?? [:]
        var connected: [UUID] = []
        for edge in edges.values {
            if edge.sourceId == sel { connected.append(edge.targetId) }
            if edge.targetId == sel { connected.append(edge.sourceId) }
        }
        guard !connected.isEmpty else { return }
        if let idx = connected.firstIndex(of: sel) {
            selectedMemoryId = connected[(idx + 1) % connected.count]
        } else {
            selectedMemoryId = connected[0]
        }
    }

    private func exportToPNG() {
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView else { return }

        let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
        guard let rep else { return }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)

        guard let pngData = rep.representation(using: .png, properties: [:]) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "memory-graph.png"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? pngData.write(to: url)
            }
        }
    }

    /// Generate a deterministic color for a project at a given index using golden-angle spacing.
    // Cached system sounds — avoids file I/O and AIFF parsing on every node add/remove
    nonisolated(unsafe) static let addSound = NSSound(contentsOf: URL(fileURLWithPath: "/System/Library/Sounds/Funk.aiff"), byReference: true)
    nonisolated(unsafe) static let removeSound = NSSound(contentsOf: URL(fileURLWithPath: "/System/Library/Sounds/Bottle.aiff"), byReference: true)

    private static let goldenAngle = 0.381966011250105
    static func goldenAngleColor(at index: Int) -> Color {
        let hue = Double(index) * goldenAngle
        let h = hue - hue.rounded(.down)
        return Color(hue: h, saturation: 0.65, brightness: 0.9)
    }

    /// Look up a project's color from a pre-built map. Falls back to gray for unknown projects.
    static func projectColor(for project: String, in colorMap: [String: Color]) -> Color {
        colorMap[project] ?? .gray
    }
}
