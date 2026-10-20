import Foundation
import Observation
import SwiftUI
import simd
import EngramRealityKit

public enum EngramGraphViewerError: Error, LocalizedError {
    case invalidSnapshot(String)
    case rendererUnavailable
    public var errorDescription: String? {
        switch self {
        case .invalidSnapshot(let reason): return "The selected graph could not be displayed: \(reason)"
        case .rendererUnavailable: return "Engram's graph renderer is unavailable on this device."
        }
    }
}

/// Own this controller at the authorization boundary. `clear()` synchronously withdraws
/// every displayed row and tears down the scene; `clearAndDrain()` additionally joins work.
@Observable @MainActor
public final class EngramGraphViewerController {
    public private(set) var snapshot: EngramGraphSnapshot?
    public private(set) var selectedMemoryID: UUID?
    public private(set) var searchMatches: Set<UUID> = []
    public private(set) var query = ""
    public private(set) var hiddenProjects: Set<String> = []
    public private(set) var hiddenRelations: Set<String> = []
    public private(set) var layout: EngramGraphLayout = .forceDirected
    public private(set) var projectionProgress: Double?
    public private(set) var projectionMessage: String?
    public private(set) var rendererError: String?
    public private(set) var isActive = false
    public private(set) var soundEnabled = false
    var sceneManager: EngramGraphSceneManager?
    // The renderer adapter is intentionally unobserved: frame updates must not
    // invalidate SwiftUI. Publish only completed topology replacements instead.
    private var topologyRevision: UInt64 = 0
    @ObservationIgnored private(set) var adapter = EngramGraphDataAdapter()
    @ObservationIgnored private var viewportSize: CGSize?
    @ObservationIgnored private var overlayBottom: CGFloat?
    @ObservationIgnored private var inspectorTop: CGFloat?
    @ObservationIgnored private var adaptsFramingToOcclusion = false
    private enum ViewportFraming { case graph, focused(UUID), manual }
    @ObservationIgnored private var viewportFraming: ViewportFraming = .graph
    @ObservationIgnored private var awaitsScopeOverlayMeasurement = true
    @ObservationIgnored private var followsInitialLayout = true
    @ObservationIgnored private var lastFittedRevision: UInt64?
    @ObservationIgnored private var connectionAnchor: UUID?
    @ObservationIgnored private var connectionIndex = 0
    @ObservationIgnored private var memoryByID: [UUID: EngramGraphMemory] = [:]
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var projectionRequest: UUID?
    @ObservationIgnored private var queryEpoch = UUID()
    @ObservationIgnored private var searchWork: Task<Void, Never>?
    @ObservationIgnored private var work: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var retiredManagers: [UUID: EngramGraphSceneManager] = [:]

    public init() {}
    public var selectedMemory: EngramGraphMemory? {
        _ = topologyRevision
        return selectedMemoryID.flatMap { memoryByID[$0] }
    }
    public var visibleMemoryCount: Int { _ = topologyRevision; return adapter.nodes.count }
    public var visibleEdgeCount: Int { _ = topologyRevision; return adapter.edges.count }
    public var projects: [String] { Set(snapshot?.memories.map(\.project) ?? []).sorted() }
    public var relationCounts: [String: Int] {
        Dictionary((snapshot?.edges ?? []).map { ($0.relation, 1) }, uniquingKeysWith: +)
    }
    public var connectedCount: Int {
        _ = topologyRevision
        guard let selectedMemoryID else { return 0 }
        return adapter.edges.filter { $0.sourceId == selectedMemoryID || $0.targetId == selectedMemoryID }.count
    }
    /// Search includes all loaded memories, even those hidden by visual filters.
    public var searchResults: [EngramGraphMemory] {
        Array((snapshot?.memories ?? []).lazy.filter { self.searchMatches.contains($0.id) }.prefix(100))
    }

    public func replaceSnapshot(_ value: EngramGraphSnapshot) throws {
        do { try Self.validate(value) } catch { clear(); throw error }
        let sameScope = snapshot.map { $0.scopeID == value.scopeID && $0.graphID == value.graphID && $0.ownerID == value.ownerID } ?? false
        if !sameScope { clear() }
        else { invalidateWork(); sceneManager?.topologyWillChange() }
        snapshot = value
        memoryByID = Dictionary(uniqueKeysWithValues: value.memories.map { ($0.id, $0) })
        hiddenProjects.formIntersection(Set(value.memories.map(\.project)))
        hiddenRelations.formIntersection(Set(value.edges.map(\.relation)))
        layout = .forceDirected; projectionMessage = nil
        adapter.simulation.isActive = isActive
        adapter.replace(snapshot: value, hiddenProjects: hiddenProjects, hiddenRelations: hiddenRelations)
        if let selectedMemoryID, memoryByID[selectedMemoryID] == nil { select(nil) }
        adapter.selectedNode = selectedMemoryID
        if !query.isEmpty { setQuery(query) }
        topologyRevision &+= 1
        if isActive { activateRenderer() }
    }

    public func clear() {
        recordLifecycleDiagnostic(.controllerClearStarting)
        invalidateWork(); queryEpoch = UUID()
        adapter.onFramingUpdate = nil
        followsInitialLayout = true; lastFittedRevision = nil; awaitsScopeOverlayMeasurement = true
        viewportFraming = .graph; inspectorTop = nil
        snapshot = nil; memoryByID.removeAll(); selectedMemoryID = nil
        connectionAnchor = nil; connectionIndex = 0
        searchMatches.removeAll(); query = ""; hiddenProjects.removeAll(); hiddenRelations.removeAll()
        layout = .forceDirected; projectionMessage = nil; rendererError = nil; soundEnabled = false
        if let sceneManager {
            sceneManager.camera.onUserInteraction = nil
            sceneManager.teardown()
            let drainID = UUID()
            retiredManagers[drainID] = sceneManager
            work[drainID] = Task { [weak self] in
                await sceneManager.drain()
                self?.retiredManagers.removeValue(forKey: drainID)
                self?.work.removeValue(forKey: drainID)
            }
        }
        searchWork = nil
        sceneManager = nil; adapter = EngramGraphDataAdapter()
        topologyRevision &+= 1
        recordLifecycleDiagnostic(.controllerClearFinished)
    }

    public func clearAndDrain() async {
        clear(); await drain()
    }

    /// Pause when the host leaves foreground; callers withdraw authorization with clear().
    public func setActive(_ value: Bool) {
        guard value != isActive else { return }
        isActive = value
        recordLifecycleDiagnostic(.controllerActivity)
        if value {
            activateRenderer()
            if !query.isEmpty { setQuery(query) }
        } else {
            if projectionProgress != nil { layout = .forceDirected; adapter.semanticPositions = nil }
            invalidateWork(); queryEpoch = UUID()
            sceneManager?.setActive(false)
        }
    }

    public func pauseAndDrain() async {
        let current = sceneManager
        setActive(false); await drain()
        await current?.drain()
    }

    func drainRetiredWork() async { await drain() }

    private func drain() async {
        let tasks = Array(work.values)
        let managers = Array(retiredManagers.values)
        retiredManagers.removeAll()
        for task in tasks { await task.value }
        for manager in managers { await manager.drain() }
    }

    private func invalidateWork() {
        epoch = UUID(); projectionProgress = nil; projectionRequest = nil
        for task in work.values { task.cancel() }
    }

    private func activateRenderer() {
        guard isActive, snapshot != nil else { return }
        if sceneManager == nil {
            do {
                sceneManager = try EngramGraphSceneManager(adapter: adapter)
                recordLifecycleDiagnostic(.controllerCreatedRenderer)
                sceneManager?.scene.clusterLabelViewportSize = viewportSize
                sceneManager?.onFailure = { [weak self] message in self?.rendererError = message }
                sceneManager?.camera.onUserInteraction = { [weak self] in
                    self?.viewportFraming = .manual
                    self?.stopInitialFraming()
                }
                if followsInitialLayout {
                    adapter.onFramingUpdate = { [weak self] in self?.followInitialLayout() }
                    followInitialLayout(force: true)
                }
                rendererError = nil
            } catch { rendererError = error.localizedDescription }
        }
        sceneManager?.scene.spatialAudioSystem.isEnabled = soundEnabled
        sceneManager?.setActive(true)
    }

    public func setQuery(_ value: String) {
        if value != query { stopInitialFraming() }
        searchWork?.cancel()
        query = value; queryEpoch = UUID()
        adapter.isSearchActive = !value.isEmpty
        guard !value.isEmpty, let snapshot else {
            searchMatches = []; adapter.searchMatchIds = []; return
        }
        let generation = epoch, request = queryEpoch, taskID = UUID()
        let rows = snapshot.memories
        let tokens = value.split(whereSeparator: \.isWhitespace).map(String.init)
        work[taskID] = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { () -> Set<UUID> in
                var matches: Set<UUID> = []
                for row in rows {
                    if Task.isCancelled { return [] }
                    if tokens.allSatisfy({ row.content.localizedCaseInsensitiveContains($0)
                        || row.project.localizedCaseInsensitiveContains($0) || row.topic.localizedCaseInsensitiveContains($0) }) {
                        matches.insert(row.id)
                    }
                }
                return matches
            }
            let matches = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self else { return }
            defer { self.work.removeValue(forKey: taskID) }
            guard !Task.isCancelled, self.epoch == generation, self.queryEpoch == request else { return }
            self.searchMatches = matches; self.adapter.searchMatchIds = matches
        }
        searchWork = work[taskID]
    }

    public func toggleProject(_ project: String) {
        stopInitialFraming()
        if !hiddenProjects.insert(project).inserted { hiddenProjects.remove(project) }
        applyFilters()
    }
    public func toggleRelation(_ relation: String) {
        stopInitialFraming()
        if !hiddenRelations.insert(relation).inserted { hiddenRelations.remove(relation) }
        applyFilters()
    }
    private func applyFilters() {
        guard let snapshot else { return }
        invalidateWork(); sceneManager?.topologyWillChange()
        layout = .forceDirected; projectionMessage = nil
        adapter.simulation.isActive = isActive
        adapter.replace(snapshot: snapshot, hiddenProjects: hiddenProjects, hiddenRelations: hiddenRelations)
        if let selectedMemoryID, !adapter.nodes.contains(where: { $0.id == selectedMemoryID }) { select(nil) }
        if !query.isEmpty { setQuery(query) }
        topologyRevision &+= 1
        recordLifecycleDiagnostic(.filtersChanged)
    }
    public func select(_ id: UUID?) {
        guard id == nil || memoryByID[id!] != nil else { return }
        stopInitialFraming()
        selectedMemoryID = id; adapter.selectedNode = id
        recordLifecycleDiagnostic(.selectionChanged)
        connectionAnchor = nil; connectionIndex = 0
    }
    public func focus(_ id: UUID) {
        guard let memory = memoryByID[id] else { return }
        if hiddenProjects.remove(memory.project) != nil { applyFilters() }
        select(id)
        if adaptsFramingToOcclusion {
            viewportFraming = .focused(id)
            reframeOwnedViewport()
        } else if let position = adapter.positions[id] {
            sceneManager?.camera.teleportToGalaxy(center: position, radius: 180, label: memory.topic)
        }
    }
    public func cycleConnectedMemory() {
        guard let anchor = connectionAnchor ?? selectedMemoryID else { return }
        let neighbors = Set(adapter.edges.compactMap { edge -> UUID? in
            if edge.sourceId == anchor { return edge.targetId }
            if edge.targetId == anchor { return edge.sourceId }
            return nil
        }).sorted { $0.uuidString < $1.uuidString }
        guard !neighbors.isEmpty else { connectionAnchor = nil; connectionIndex = 0; return }
        let nextIndex = connectionIndex % neighbors.count
        focus(neighbors[nextIndex])
        connectionAnchor = anchor; connectionIndex = nextIndex + 1
    }
    public func toggleSelectedHub() {
        stopInitialFraming()
        if let selectedMemoryID { adapter.toggleHub(selectedMemoryID) }
    }
    public var selectionIsHub: Bool {
        _ = topologyRevision
        return selectedMemoryID.map { adapter.hubs.contains($0) } ?? false
    }
    /// Remember geometry without reloading the graph. Embedded mobile hosts may
    /// adapt automatic/explicit fits to occlusion; direct camera input stays put.
    /// Existing desktop callers retain their camera on all later geometry changes.
    func setViewportSize(_ size: CGSize, adaptingToOcclusion: Bool = false) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        let firstMeasurement = viewportSize == nil
        let changed = viewportSize != size || adaptsFramingToOcclusion != adaptingToOcclusion
        if !firstMeasurement && changed { stopInitialFraming() }
        viewportSize = size
        adaptsFramingToOcclusion = adaptingToOcclusion
        sceneManager?.scene.clusterLabelViewportSize = size
        if firstMeasurement { followInitialLayout(force: true) }
        else if changed && adaptingToOcclusion { reframeOwnedViewport() }
    }

    /// Actual overlay geometry, measured in the full canvas coordinate space.
    /// A later layout/keyboard/disclosure change preserves manual camera placement.
    func setOverlayBottom(_ bottom: CGFloat) {
        guard bottom.isFinite, bottom >= 0 else { return }
        let firstMeasurement = overlayBottom == nil || awaitsScopeOverlayMeasurement
        let changed = overlayBottom != bottom
        if !firstMeasurement && changed { stopInitialFraming() }
        overlayBottom = bottom
        awaitsScopeOverlayMeasurement = false
        if firstMeasurement { followInitialLayout(force: true) }
        else if changed && adaptsFramingToOcclusion { reframeOwnedViewport() }
    }

    /// The inspector is measured in the same canvas coordinates as top chrome.
    /// Nil means no inline inspector; native sheets do not resize the canvas.
    func setInspectorTop(_ top: CGFloat?) {
        if let top, !top.isFinite || top < 0 { return }
        guard inspectorTop != top else { return }
        inspectorTop = top
        if adaptsFramingToOcclusion {
            stopInitialFraming()
            reframeOwnedViewport()
        }
    }

    var visibleFramingRect: CGRect? {
        guard let viewportSize else { return nil }
        let top = min(overlayBottom ?? 0, viewportSize.height)
        let bottom = adaptsFramingToOcclusion ? min(inspectorTop ?? viewportSize.height, viewportSize.height) : viewportSize.height
        return CGRect(x: 0, y: top, width: viewportSize.width, height: max(0, bottom - top))
    }

    /// Geometry may update a camera still owned by automatic/explicit framing.
    /// Direct camera input withdraws this ownership until another explicit fit.
    private func reframeOwnedViewport() {
        guard isActive, let camera = sceneManager?.camera,
              let rect = visibleFramingRect, rect.width > 0, rect.height > 0 else { return }
        switch viewportFraming {
        case .manual: return
        case .graph:
            guard let bounds = adapter.currentFramingBounds() else { return }
            camera.centerOnGraph(center: bounds.center, radius: bounds.radius,
                minimumOrbitRadius: 80, fitViewport: viewportSize, visibleRect: rect,
                billboards: framingBillboards(bounds))
        case .focused(let id):
            guard let position = adapter.positions[id] else { return }
            // Node radius is 8 (12 for hubs); reserve nearby context and its label.
            // Fitting this region uses the actual available height on short screens.
            let radius: Float = adapter.hubs.contains(id) ? 48 : 32
            camera.centerOnGraph(center: position, radius: radius,
                minimumOrbitRadius: 1, fitViewport: viewportSize, visibleRect: rect)
        }
    }

    private func stopInitialFraming(cancelTransition: Bool = true) {
        if cancelTransition { sceneManager?.camera.cancelAutomaticFraming() }
        followsInitialLayout = false
        adapter.onFramingUpdate = nil
    }

    private func followInitialLayout(force: Bool = false) {
        guard followsInitialLayout, isActive, let manager = sceneManager,
              let bounds = adapter.framingBounds else { return }
        if force || lastFittedRevision != bounds.renderedRevision {
            manager.camera.centerOnGraph(center: bounds.center, radius: bounds.radius,
                minimumOrbitRadius: 80, fitViewport: viewportSize, visibleRect: visibleFramingRect,
                animated: !force && lastFittedRevision != nil, billboards: framingBillboards(bounds))
            lastFittedRevision = bounds.renderedRevision
        }
        // The settling tick precedes the last asynchronous GPU delivery. Retire
        // only after that token ended AND its positions reached the aggregate.
        if viewportSize != nil, overlayBottom != nil,
           (adapter.simulation.isSettled || adapter.simulation.nodeCount <= 1), !manager.hasPendingForce,
           bounds.forceRevision == adapter.simulation.positionRevision {
            // The final target still finishes through the existing camera update.
            stopInitialFraming(cancelTransition: false)
        }
    }

    private func framingBillboards(_ bounds: EngramGraphDataAdapter.FramingBounds) -> [CameraController.FramingBillboard] {
        guard sceneManager?.scene.usesViewportBoundedClusterLabels == true,
              let viewportSize else { return [] }
        return bounds.clusterAnchors.map {
            CameraController.FramingBillboard(anchor: $0.position,
                maximumPointSize: $0.kind.maximumPointSize(in: viewportSize))
        }
    }

    public func centerGraph() {
        stopInitialFraming()
        viewportFraming = .graph
        guard let bounds = adapter.currentFramingBounds() else { return }
        sceneManager?.camera.centerOnGraph(center: bounds.center, radius: bounds.radius,
            minimumOrbitRadius: 80, fitViewport: viewportSize, visibleRect: visibleFramingRect,
            billboards: framingBillboards(bounds))
    }
    public func navigateProject(_ project: String) {
        viewportFraming = .manual
        sceneManager?.camera.driveToProject(project, positions: adapter.positions, nodes: adapter.nodes, hubs: adapter.hubs)
    }
    public func nextProject(direction: Int = 1) {
        viewportFraming = .manual
        sceneManager?.camera.teleportToNextProject(positions: adapter.positions, nodes: adapter.nodes, hubs: adapter.hubs, direction: direction)
    }
    public func setSoundEnabled(_ value: Bool) {
        soundEnabled = value; sceneManager?.scene.spatialAudioSystem.isEnabled = value && isActive
    }
    public func zoom(_ amount: Float) { sceneManager?.camera.dolly(amount: amount) }
    func tap(at point: CGPoint, size: CGSize) {
        guard let camera = sceneManager?.camera else { return }
        let id = camera.hitTest(at: point, viewSize: size, positions: adapter.positions, currentTarget: selectedMemoryID)
        if let id, id == selectedMemoryID, adapter.hubs.contains(id) { adapter.toggleHub(id) }
        select(id)
    }
    public func color(for project: String) -> Color {
        let c = adapter.projectColorMap[project] ?? SIMD3<Float>(0.5, 0.5, 0.6)
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    static func validate(_ value: EngramGraphSnapshot) throws {
        func require(_ condition: Bool, _ reason: String) throws {
            if !condition { throw EngramGraphViewerError.invalidSnapshot(reason) }
        }
        try require(!value.scopeID.isEmpty && !value.revisionID.isEmpty, "missing scope or revision")
        try require(value.memories.count <= 50_000 && value.edges.count <= 200_000, "topology exceeds reader limits")
        let ids = Set(value.memories.map(\.id))
        try require(ids.count == value.memories.count && Set(value.edges.map(\.id)).count == value.edges.count, "duplicate identities")
        try require(value.edges.allSatisfy { ids.contains($0.sourceID) && ids.contains($0.targetID) }, "edge endpoint is missing")
        try require(value.coverage.omittedEmbeddingCount >= 0 && value.coverage.invalidEmbeddingCount >= 0, "invalid embedding coverage")
        try require(value.coverage.totalMemoryCount >= value.memories.count && value.coverage.totalEdgeCount >= value.edges.count, "invalid coverage counts")
        try require(value.memories.reduce(0) { $0 + $1.content.utf8.count } <= 64 * 1024 * 1024, "content exceeds reader limit")
        try require(value.memories.reduce(0) { $0 + ($1.embedding?.count ?? 0) } <= 24 * 1024 * 1024, "embeddings exceed reader limit")
    }
}

extension EngramGraphViewerController {
    /// Reuses Engram's t-SNE kernel. Its O(n²) matrix budget is separate from graph/search coverage.
    public func setLayout(_ mode: EngramGraphLayout) {
        stopInitialFraming()
        guard mode != layout || (mode == .embedding && adapter.semanticPositions == nil && projectionProgress == nil) else { return }
        invalidateWork(); sceneManager?.topologyWillChange()
        layout = mode
        if mode == .forceDirected { adapter.simulation.setPositions(adapter.positions); adapter.simulation.wake() }
        adapter.semanticPositions = nil
        adapter.simulation.isActive = isActive && mode == .forceDirected
        if !query.isEmpty { setQuery(query) }
        guard mode == .embedding, let snapshot else { projectionMessage = nil; return }
        let visible = Set(adapter.nodes.map(\.id))
        let selection = Self.semanticSelection(snapshot.memories.filter { visible.contains($0.id) })
        guard selection.rows.count >= 2 else {
            projectionMessage = "Semantic layout needs at least two compatible stored embeddings. Force layout remains visible."
            layout = .forceDirected; adapter.simulation.isActive = isActive; return
        }
        projectionMessage = "Semantic layout uses \(selection.rows.count) memories with \(selection.dimension)-value stored embeddings. \(visible.count - selection.rows.count) retain force positions. Limit: 1,200 projected memories."
        projectionProgress = 0
        let generation = epoch, taskID = UUID()
        projectionRequest = taskID
        let input = EngramGraphTSNEKernel.Input(embeddings: selection.rows.map { $0.embedding! },
            ids: selection.rows.map(\.id), perplexity: min(30, Double(selection.rows.count - 1) / 3),
            maxIterations: 1_000,
            initialPositions: selection.rows.map { row in
                let p = adapter.positions[row.id] ?? .zero
                return (Double(p.x), Double(p.y))
            }, outputDims: 3)
        let spread = max(500, sqrt(Float(visible.count)) * 100)
        // Immutable actor-isolated callbacks preserve weak ownership across the detached kernel.
        let reportProgress: @MainActor @Sendable (Double) -> Void = { [weak self] progress in
            guard let self, self.epoch == generation, self.projectionRequest == taskID, self.layout == .embedding else { return }
            self.projectionProgress = progress
        }
        let reportPositions: @MainActor @Sendable ([(id: UUID, x: Double, y: Double)], [Double]?) -> Void = { [weak self] positions, z in
            guard let self, self.epoch == generation, self.projectionRequest == taskID, self.layout == .embedding else { return }
            self.adapter.semanticPositions = Self.normalized(positions, z: z, spread: spread)
        }
        work[taskID] = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                await EngramGraphTSNEKernel.compute(input, progress: { progress in
                    Task { @MainActor in reportProgress(progress) }
                }, onPositions: { positions, z in
                    Task { @MainActor in reportPositions(positions, z) }
                })
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self else { return }
            defer { self.work.removeValue(forKey: taskID) }
            guard !Task.isCancelled, self.epoch == generation, self.projectionRequest == taskID, self.layout == .embedding else { return }
            self.adapter.semanticPositions = Self.normalized(result.positions, z: result.zValues, spread: spread)
            self.projectionProgress = nil; self.projectionRequest = nil
        }
    }

    static func semanticSelection(_ rows: [EngramGraphMemory]) -> (dimension: Int, rows: [EngramGraphMemory]) {
        let valid = rows.filter { row in
            guard let vector = row.embedding else { return false }
            return !vector.isEmpty && vector.allSatisfy(\.isFinite)
        }
        let counts = Dictionary(valid.map { ($0.embedding!.count, 1) }, uniquingKeysWith: +)
        let dimension = counts.keys.sorted().max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? 0
        return (dimension, Array(valid.filter { $0.embedding!.count == dimension }
            .sorted { $0.id.uuidString < $1.id.uuidString }.prefix(1_200)))
    }

    private static func normalized(_ positions: [(id: UUID, x: Double, y: Double)], z: [Double]?, spread: Float) -> [UUID: SIMD3<Float>] {
        guard !positions.isEmpty, let z, z.count == positions.count else { return [:] }
        var result: [UUID: SIMD3<Float>] = [:]
        var points: [SIMD3<Float>] = []
        for (index, p) in positions.enumerated() {
            let vector = SIMD3(Float(p.x), Float(p.y), Float(z[index]))
            guard vector.x.isFinite, vector.y.isFinite, vector.z.isFinite else { return [:] }
            points.append(vector)
        }
        let center = points.reduce(.zero, +) / Float(points.count)
        let radius = max(0.001, points.map { simd_length($0 - center) }.max() ?? 1)
        for (index, p) in positions.enumerated() { result[p.id] = (points[index] - center) * (spread / radius) }
        return result
    }
}
