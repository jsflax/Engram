import AppKit
import Foundation
import Observation
import simd
import EngramMemoryCore
import EngramRealityKit
import EngramSceneKit

enum GraphScenePreparationKey: Hashable { case inactive, sceneOnly, forceLayout }

/// One provider-owned view session. The caller authenticates/exports outside this type, then
/// publishes a finished snapshot through an exact request ticket. No tool, database or network API.
@Observable @MainActor
public final class EngramGraphSession {
    public let identity: EngramGraphSessionIdentity
    public private(set) var loadState: EngramGraphLoadState = .idle
    public private(set) var visibility: EngramGraphVisibility = .suspended
    public private(set) var snapshot: EngramGraphSnapshot?
    public private(set) var selectedNode: UUID?
    public private(set) var isMounted = false
    public private(set) var isSurfaceAttached = false
    public private(set) var isRevoked = false
    public private(set) var scene: EngramRealityScene?
    private(set) var requiresForceResources = false
    public let camera = CameraController()
    @ObservationIgnored let data = GraphSceneData()
    @ObservationIgnored private let sessionToken = UUID()
    @ObservationIgnored private var request: EngramGraphLoadTicket?
    @ObservationIgnored private var mountedToken: UUID?
    @ObservationIgnored private weak var inputView: NSView?
    @ObservationIgnored private let inputBridge = RKInputBridge()
    @ObservationIgnored private var inputInstalled = false
    @ObservationIgnored private var forceEngine: ForceEngine?
    @ObservationIgnored private let forcePreparer = GraphForcePreparer()
    @ObservationIgnored private var forcePreparationID: UUID?
    @ObservationIgnored private(set) var activityGeneration = UUID()
    @ObservationIgnored private var pendingSelection: UUID?
    @ObservationIgnored private var hasCameraState = false
    // Initial framing remains provisional while existing force layout can move the graph.
    @ObservationIgnored private var automaticFit: (camera: EngramGraphViewState, positions: UInt64)?
    @ObservationIgnored private var automaticLabelReach: Float = 12
    @ObservationIgnored private var staticFallbackCamera: EngramGraphViewState?
    @ObservationIgnored private var viewportSize: CGSize = .zero
    @ObservationIgnored private var labelLayout: RKLabelLayout?
    @ObservationIgnored private var fitGeneration = UUID()
    @ObservationIgnored private var pendingFit: (generation: UUID, camera: EngramGraphViewState, notify: Bool)?
    @ObservationIgnored private var headerHeight: CGFloat = 0
    @ObservationIgnored private var detailMeasurement: (node: UUID, height: CGFloat)?
    @ObservationIgnored private var lookStart: (azimuth: Float, elevation: Float, camPos: SIMD3<Float>)?

    /// Signals presentation state only. The native host owns lease validation and durable saving.
    @ObservationIgnored public var onStateChange: ((EngramGraphSessionIdentity, EngramGraphViewState) -> Void)?

    public init(identity: EngramGraphSessionIdentity, savedState: EngramGraphViewState? = nil) {
        self.identity = identity
        if let savedState {
            hasCameraState = camera.restore(azimuth: Float(savedState.azimuth), elevation: Float(savedState.elevation),
                target: GraphSceneData.vector(savedState.target), radius: Float(savedState.orbitRadius))
            pendingSelection = savedState.selectedNode
        }
        inputBridge.camera = camera
        inputBridge.onCameraInteraction = { [weak self] in self?.signalStateChange() }
    }

    public var isRenderingActive: Bool { isMounted && isSurfaceAttached && visibility == .visible && !isRevoked }
    var scenePreparationKey: GraphScenePreparationKey {
        !isRenderingActive ? .inactive : requiresForceResources ? .forceLayout : .sceneOnly
    }
    public var selectedMemory: EngramGraphNode? { snapshot?.nodes.first { $0.id == selectedNode } }
    /// Pure focus preference. The host validates subtree/window/lease and owns makeFirstResponder.
    public var preferredContentFocusView: NSView? { isRenderingActive ? inputView : nil }

    public func beginLoading() throws -> EngramGraphLoadTicket {
        guard !isRevoked else { throw EngramGraphSurfaceError.revoked }
        let ticket = EngramGraphLoadTicket(session: sessionToken, request: UUID())
        request = ticket; loadState = .loading
        return ticket
    }

    public func apply(_ value: EngramGraphSnapshot, from source: EngramGraphSessionIdentity,
                      for ticket: EngramGraphLoadTicket) throws {
        try check(ticket, source: source)
        guard value.scope == identity.scope else { throw EngramGraphSurfaceError.identityMismatch }
        if let snapshot, value.revision <= snapshot.revision { throw EngramGraphSurfaceError.staleRevision }
        _ = automaticCameraIsCurrent()
        automaticFit = nil
        if data.publish(value) { activityGeneration = UUID() }
        requiresForceResources = data.needsLayout && value.nodes.count > 1
        if !requiresForceResources { forcePreparationID = nil }
        snapshot = value; request = nil; loadState = .ready
        fitGeneration = UUID(); pendingFit = nil
        if let selectedNode, !value.nodes.contains(where: { $0.id == selectedNode }) {
            self.selectedNode = nil; data.selectedNode = nil
        }
        if let pendingSelection {
            if value.nodes.contains(where: { $0.id == pendingSelection }) {
                selectedNode = pendingSelection; data.selectedNode = pendingSelection
            }
            self.pendingSelection = nil
        }
        if !hasCameraState && !value.nodes.isEmpty { fitGraph(notify: false) }
    }

    public func loadingFailed(for ticket: EngramGraphLoadTicket, from source: EngramGraphSessionIdentity) throws {
        try check(ticket, source: source)
        request = nil; loadState = .failed // Preserve the last authorized graph and camera.
    }

    public func cancelLoading(_ ticket: EngramGraphLoadTicket) {
        guard request == ticket else { return }
        request = nil
        if !isRevoked { loadState = snapshot == nil ? .idle : .ready }
    }

    private func check(_ ticket: EngramGraphLoadTicket, source: EngramGraphSessionIdentity) throws {
        guard !isRevoked else { throw EngramGraphSurfaceError.revoked }
        guard source == identity else { throw EngramGraphSurfaceError.identityMismatch }
        guard ticket.session == sessionToken, request == ticket else { throw EngramGraphSurfaceError.staleRequest }
    }

    public func setVisibility(_ visibility: EngramGraphVisibility) {
        guard !isRevoked, self.visibility != visibility else { return }
        self.visibility = visibility
        updateActivity()
    }

    /// Revocation is terminal for this instance. A newly authenticated connection needs a new
    /// session. Clear content and selection immediately, including any retained GPU entity subtree.
    public func invalidate() {
        guard !isRevoked else { return }
        isRevoked = true; visibility = .suspended; request = nil; loadState = .revoked
        fitGeneration = UUID(); pendingFit = nil; automaticFit = nil; staticFallbackCamera = nil; labelLayout = nil
        updateActivity()
        snapshot = nil; selectedNode = nil; pendingSelection = nil; requiresForceResources = false; data.clear()
        scene?.dataProvider = nil; scene?.cameraProvider = nil; scene?.onFrameCallback = nil
        scene?.labelAtlasGenerator.onLayoutPublished = nil
        scene?.rootEntity.children.removeAll()
        scene = nil; forceEngine = nil; onStateChange = nil
    }

    func attachSurface(_ token: UUID, view: NSView) throws {
        guard !isRevoked else { throw EngramGraphSurfaceError.revoked }
        guard mountedToken == nil || mountedToken == token else { throw EngramGraphSurfaceError.alreadyMounted }
        mountedToken = token; inputView = view; isMounted = true
        isSurfaceAttached = view.window != nil
        updateActivity()
    }
    func detachSurface(_ token: UUID) {
        guard mountedToken == token else { return }
        isMounted = false; isSurfaceAttached = false; mountedToken = nil; inputView = nil
        updateActivity()
    }
    func surfaceWindowChanged(_ token: UUID) {
        guard mountedToken == token else { return }
        isSurfaceAttached = inputView?.window != nil
        updateActivity()
    }

    private func updateActivity() {
        activityGeneration = UUID() // Reject force completions admitted by any previous state.
        let active = isRenderingActive
        if !active { pendingFit = nil } // A hidden/detached lifetime never completes an old Fit.
        data.isActive = active
        scene?.setRenderingActive(active)
        if active, let inputView {
            if !inputInstalled { inputBridge.install(in: inputView); inputInstalled = true }
        } else {
            forcePreparationID = nil
            inputBridge.uninstall(); inputInstalled = false
            lookStart = nil; camera.endDrag()
        }
        if active && !hasCameraState && pendingFit == nil { fitGraph(notify: false) }
    }

    /// Scene/GPU resources are created only when a real native surface is active, never by a data
    /// refresh or the pure session tests. Audio generation and diagnostic file output are disabled.
    func prepareSceneIfNeeded() async {
        guard isRenderingActive, !Task.isCancelled else { return }
        if scene == nil {
            let scene = EngramRealityScene(audioEnabled: false, diagnosticsEnabled: false)
            scene.showMascots = false
            scene.labelBatchSystem.compactGraphLabels = true
            scene.labelAtlasGenerator.onLayoutPublished = { [weak self, weak scene] layout in
                guard let self, self.scene === scene else { return }
                self.acceptLabelLayout(layout)
            }
            scene.dataProvider = data; scene.cameraProvider = camera
            scene.onFrameCallback = { [weak self] delta in self?.frame(delta: delta) }
            self.scene = scene
            updateActivity()
        }
        guard requiresForceResources, forceEngine == nil, let scene else { return }
        let preparationID = UUID()
        forcePreparationID = preparationID
        let prepared = try? await forcePreparer.prepare(device: scene.device)
        guard !Task.isCancelled, isRenderingActive, requiresForceResources, self.scene === scene,
              forcePreparationID == preparationID else { return }
        forcePreparationID = nil
        if let prepared {
            forceEngine = ForceEngine(forceCompute: prepared.compute, simState: prepared.simulation)
            // The existing simulation only starts its settling clock after compute is ready.
            data.isLayoutPrepared = true
            resumeInitialLayoutAfterStaticFallback()
        } else {
            // No engine will move these seeded positions. Finish instead of waiting for settlement.
            finishInitialLayout(staticFallback: true)
        }
    }

    private func frame(delta: Float) {
        guard isRenderingActive, delta.isFinite, delta > 0 else { return }
        let delta = min(delta, 0.1)
        inputBridge.tick(dt: delta); camera.updateCamera(dt: delta)
        refineInitialCamera()
        guard data.needsLayout, let scene, let engine = forceEngine else { return }
        let sim = data.simulation
        guard sim.isActive, !sim.isSettled, sim.nodeCount > 1,
              engine.isFullSimAvailable, !engine.isInFlight else { return }
        let snapshot = ForceEngine.SimulationSnapshot(
            nodeCount: sim.nodeCount, isSettled: sim.isSettled, posX: sim.posX, posY: sim.posY, posZ: sim.posZ,
            projectGroups: sim.projectGroupPublic, topicGroups: sim.topicGroupPublic,
            topicProjectGroup: sim.topicProjectGroupPublic, galaxyGroups: sim.galaxyGroupPublic,
            galaxyCenters: sim.galaxyCentersPublic, edgeIndices: sim.edgeIndicesPublic, topologyDirty: sim.topologyDirtyForGPU,
            chargeStrength: sim.chargeStrength, crossChargeMultiplier: sim.crossChargeMultiplier,
            sameTopicChargeScale: sim.sameTopicChargeScale, sameProjectChargeScale: sim.sameProjectChargeScale,
            springLength: sim.springLength, crossProjectSpringLength: sim.crossProjectSpringLength,
            springStrength: sim.springStrength, cohesionStrength: sim.cohesionStrength,
            centroidRepulsion: sim.centroidRepulsion, topicCohesionStrength: sim.topicCohesionStrength,
            topicCentroidRepulsion: sim.topicCentroidRepulsion, centerStrength: sim.centerStrength,
            alpha: sim.alpha, damping: 0.78, maxSpeed: 12)
        let generation = activityGeneration, nodeOrder = sim.nodeOrderVersion
        if engine.encodeForcePass(queue: scene.commandQueue, snapshot: snapshot, onComplete: { [weak self] result in
            self?.acceptForces(result, generation: generation, nodeOrder: nodeOrder)
        }) != nil { sim.topologyDirtyForGPU = false }
    }

    func acceptForces(_ result: ForceResult, generation: UUID, nodeOrder: UInt64) {
        guard isRenderingActive, activityGeneration == generation, nodeOrder == data.simulation.nodeOrderVersion,
              let values = result.positions, values.count == data.simulation.nodeCount,
              values.allSatisfy({ [$0.x, $0.y, $0.z].allSatisfy { $0.isFinite && abs($0) <= 1_000_000 } }) else { return }
        data.simulation.applyGPUForces(data.preservingSuppliedPositions(in: result), expectedNodeOrderVersion: nodeOrder)
        data.refreshPositions()
    }

    /// Geometry updates never replace a restored or user-adjusted camera. A new session's
    /// first fit waits for its real viewport instead of assuming a square panel.
    func updateViewport(_ size: CGSize) {
        guard !isRevoked, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }
        viewportSize = size
        if !hasCameraState { fitGraph(notify: false) } else { finishPendingFit() }
    }

    func updateHeaderHeight(_ height: CGFloat) {
        guard !isRevoked, height.isFinite, height > 0 else { return }
        headerHeight = height
        if !hasCameraState { fitGraph(notify: false) } else { finishPendingFit() }
    }

    func updateDetailHeight(_ height: CGFloat, for node: UUID) {
        guard !isRevoked, selectedMemory?.id == node, height.isFinite, height > 0 else { return }
        detailMeasurement = (node, height)
        if !hasCameraState { fitGraph(notify: false) } else { finishPendingFit() }
    }

    public func fitGraph() {
        // Explicit Fit owns the camera immediately, including while waiting for label geometry.
        automaticFit = nil; staticFallbackCamera = nil; hasCameraState = true
        fitGraph(notify: true)
    }
    private func fitGraph(notify: Bool) {
        guard !isRevoked, !data.positions.isEmpty, let current = try? captureState() else { return }
        if !notify, !automaticCameraIsCurrent() { return }
        if !notify, pendingFit != nil { finishPendingFit(); return }
        pendingFit = (fitGeneration, current, notify)
        finishPendingFit()
    }

    /// The existing atlas worker publishes numeric extents with its exact text/style identity.
    /// No second text-measurement task or CoreText work runs on the UI actor.
    func acceptLabelLayout(_ layout: RKLabelLayout) {
        guard !isRevoked, layoutMatchesCurrentGraph(layout) else { return }
        labelLayout = layout
        // This work follows the existing atlas publication, never a force frame. The numeric
        // reach encloses all rendered labels around the already-cached position bounds.
        automaticLabelReach = 12
        func include(_ aspect: Float, kind: RKLabelGeometry.Kind, offset: Float) {
            let extent = RKLabelGeometry.halfExtents(for: kind, aspect: aspect, compact: true)
            automaticLabelReach = max(automaticLabelReach, offset + simd_length(extent))
        }
        for (id, aspect) in layout.nodeAspects {
            include(aspect, kind: data.hubs.contains(id) ? .hub : .node, offset: 12)
        }
        for aspect in layout.projectAspects.values { include(aspect, kind: .project, offset: 40) }
        for aspect in layout.topicAspects.values { include(aspect, kind: .topic, offset: 25) }
        finishPendingFit()
    }

    private func layoutMatchesCurrentGraph(_ layout: RKLabelLayout) -> Bool {
        layout.matches(nodes: data.nodes, hubs: data.hubs,
            projects: Set(data.nodes.map(\.project)), topics: Set(data.nodes.map(\.topic)))
    }

    private func finishPendingFit() {
        guard !isRevoked, isRenderingActive, let pendingFit else { return }
        guard pendingFit.generation == fitGeneration else { self.pendingFit = nil; return }
        guard let current = try? captureState(), current == pendingFit.camera else {
            self.pendingFit = nil; automaticFit = nil; staticFallbackCamera = nil
            hasCameraState = true // A camera interaction wins over delayed Fit.
            return
        }
        guard let layout = labelLayout, layoutMatchesCurrentGraph(layout), !data.positions.isEmpty,
              viewportSize.width > 0, viewportSize.height > 0, headerHeight > 0 else { return }
        let detailHeight: CGFloat
        if let selected = selectedMemory {
            guard let detailMeasurement, detailMeasurement.node == selected.id else { return }
            detailHeight = detailMeasurement.height
        } else { detailHeight = 0 }
        // Use the retained target orientation. Neither Fit nor a new viewport rewrites graph
        // coordinates, force-layout state, scope identity or a different scope's camera.
        let direction = CameraState(azimuth: camera.targetAzimuth, elevation: camera.targetElevation,
            orbitRadius: 1, scaleFactor: 1, fovDegrees: camera.fovDegrees)
        let right = direction.right, up = direction.up, back = -direction.forward
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(data.nodes.count * 12 + 8)
        func billboard(_ anchor: SIMD3<Float>, _ aspect: Float?, _ kind: RKLabelGeometry.Kind) {
            guard let aspect else { return } // Atlas capacity omitted this label; it is not rendered.
            let extent = RKLabelGeometry.halfExtents(for: kind, aspect: aspect, compact: true)
            for x in [Float(-1), 1] {
                for y in [Float(-1), 1] { points.append(anchor + right * (x * extent.x) + up * (y * extent.y)) }
            }
        }
        for node in data.nodes {
            guard let position = data.positions[node.id] else { continue }
            let radius: Float = node.isHub ? 12 : 8
            // Conservative camera-aligned cube encloses the actual rendered sphere.
            for x in [Float(-1), 1] {
                for y in [Float(-1), 1] {
                    for z in [Float(-1), 1] {
                        points.append(position + (right * x + up * y + back * z) * radius)
                    }
                }
            }
            billboard(position + SIMD3(0, 12, 0), layout.nodeAspects[node.id], node.isHub ? .hub : .node)
        }
        for (project, centroid) in data.projectCentroids {
            let top = data.nodes.filter { $0.project == project }.compactMap { data.positions[$0.id]?.y }.max() ?? centroid.y
            billboard(SIMD3(centroid.x, top + 40, centroid.z), layout.projectAspects[project], .project)
        }
        for (topic, nodes) in Dictionary(grouping: data.nodes, by: \.topic) {
            let positions = nodes.compactMap { data.positions[$0.id] }
            guard positions.count >= 2 else { continue }
            let centroid = positions.reduce(SIMD3<Float>.zero, +) / Float(positions.count)
            let top = positions.map(\.y).max() ?? centroid.y
            billboard(SIMD3(centroid.x, top + 25, centroid.z), layout.topicAspects[topic], .topic)
        }
        guard let first = points.first else { return }
        func projected(_ value: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(simd_dot(value, right), simd_dot(value, up), simd_dot(value, back))
        }
        var lower = projected(first), upper = lower
        for point in points.dropFirst() {
            let value = projected(point)
            lower = simd_min(lower, value); upper = simd_max(upper, value)
        }
        let center = (lower + upper) / 2
        let tangent = tan(camera.fovDegrees * .pi / 360)
        let aspect = Float(viewportSize.width / viewportSize.height)
        // Reserve both measured overlays plus their 16 pt outer inset and 16 pt clearance.
        // Symmetric padding keeps the retained orientation and centered projection stable.
        let horizontal = 1 - 64 / Float(viewportSize.width)
        let overlayInset = max(headerHeight, detailHeight) + 32
        let vertical = 1 - 2 * Float(overlayInset / viewportSize.height)
        guard horizontal > 0, vertical > 0 else { return } // No unoccluded fit area yet.
        var distance: Float = 80
        for point in points {
            let value = projected(point) - center
            distance = max(distance, value.z + max(abs(value.x) / (tangent * aspect * horizontal),
                                                   abs(value.y) / (tangent * vertical)) + 2)
        }
        let target = right * center.x + up * center.y + back * center.z
        guard distance.isFinite, distance <= 10_000_000 else { return }
        // Snap center/orientation together, retaining the existing bounded camera format.
        guard camera.restore(azimuth: camera.targetAzimuth, elevation: camera.targetElevation,
                             target: target, radius: distance) else { return }
        self.pendingFit = nil
        if hasCameraState || pendingFit.notify || !requiresForceResources {
            hasCameraState = true; automaticFit = nil
        } else if let current = try? captureState() {
            automaticFit = (current, data.positionVersion)
        }
        if staticFallbackCamera != nil { staticFallbackCamera = try? captureState() }
        if pendingFit.notify { signalStateChange() }
    }

    private func automaticCameraIsCurrent() -> Bool {
        guard let automaticFit else { return true }
        guard let current = try? captureState(), current == automaticFit.camera else {
            // Keyboard polling may change its target before the matching key-up notification.
            self.automaticFit = nil; staticFallbackCamera = nil; pendingFit = nil; hasCameraState = true
            return false
        }
        return true
    }

    /// Called by the existing frame before rendering. Position deliveries coalesce by revision;
    /// centroid/radius are already maintained by GraphSceneData, so this is constant-size work.
    func refineInitialCamera() {
        guard isRenderingActive, !hasCameraState, let automaticFit,
              automaticCameraIsCurrent() else { return }
        if data.isLayoutPrepared, data.simulation.isSettled, forceEngine?.isInFlight != true {
            finishInitialLayout()
            return
        }
        guard automaticFit.positions != data.positionVersion,
              let center = data.projectCentroids.values.first,
              viewportSize.width > 0, viewportSize.height > 0, headerHeight > 0 else { return }
        let detailHeight: CGFloat
        if let selectedNode {
            guard let detailMeasurement, detailMeasurement.node == selectedNode else { return }
            detailHeight = detailMeasurement.height
        } else { detailHeight = 0 }
        let horizontal = 1 - 64 / Float(viewportSize.width)
        let vertical = 1 - 2 * Float((max(headerHeight, detailHeight) + 32) / viewportSize.height)
        guard horizontal > 0, vertical > 0 else { return }
        let direction = camera.state
        let tangent = tan(camera.fovDegrees * .pi / 360)
        let xScale = tangent * Float(viewportSize.width / viewportSize.height) * horizontal
        let yScale = tangent * vertical
        // Project/topic anchors combine a centroid with a topmost node. Project the enclosing
        // position cube into camera axes, then expand it by the cached label/anchor reach.
        func extent(on axis: SIMD3<Float>) -> Float {
            data.radius * (abs(axis.x) + abs(axis.y) + abs(axis.z)) + automaticLabelReach
        }
        let bounds = SIMD3(extent(on: direction.right), extent(on: direction.up), extent(on: -direction.forward))
        let offset = center - camera.targetCameraPos
        let x = abs(simd_dot(offset, direction.right)), y = abs(simd_dot(offset, direction.up))
        let z = simd_dot(offset, -direction.forward)
        let depth = camera.orbitRadius - z - bounds.z
        if depth <= 0 || x + bounds.x > depth * xScale || y + bounds.y > depth * yScale {
            // Only grow while layout moves, with slack to avoid repeated tiny camera changes.
            let distance = max(camera.orbitRadius, (bounds.z + max(bounds.x / xScale, bounds.y / yScale) + 2) * 1.1)
            guard camera.restore(azimuth: camera.targetAzimuth, elevation: camera.targetElevation,
                                 target: center, radius: distance) else { return }
        }
        if let current = try? captureState() {
            self.automaticFit = (current, data.positionVersion)
        }
    }

    /// Shared by successful settlement and the known-unavailable force-engine fallback.
    /// Perform one exact fit, then preserve that camera on later resize/data callbacks.
    func finishInitialLayout(staticFallback: Bool = false) {
        guard isRenderingActive, !hasCameraState, automaticCameraIsCurrent() else { return }
        staticFallbackCamera = staticFallback ? (try? captureState()) : nil
        automaticFit = nil; hasCameraState = true
        fitGraph(notify: false)
    }

    /// A later hide/resume may retry existing force preparation. Only the exact untouched
    /// fallback camera can resume automatic framing; user changes permanently win.
    func resumeInitialLayoutAfterStaticFallback() {
        guard let saved = staticFallbackCamera else { return }
        staticFallbackCamera = nil
        guard isRenderingActive, let current = try? captureState(), current == saved else { return }
        hasCameraState = false
        automaticFit = (current, data.positionVersion)
        fitGraph(notify: false)
    }

    func select(at point: CGPoint, size: CGSize) {
        guard isRenderingActive, size.width > 0, size.height > 0 else { return }
        select(camera.hitTest(at: point, viewSize: size, positions: data.positions, currentTarget: selectedNode))
    }
    public func select(_ id: UUID?) {
        guard isRenderingActive, id == nil || snapshot?.nodes.contains(where: { $0.id == id }) == true else { return }
        selectedNode = id; data.selectedNode = id; signalStateChange()
    }
    func drag(dx: CGFloat, dy: CGFloat) {
        guard isRenderingActive, dx.isFinite, dy.isFinite else { return }
        pendingFit = nil; automaticFit = nil; staticFallbackCamera = nil; hasCameraState = true
        if lookStart == nil { lookStart = camera.captureLookState() }
        if let lookStart { camera.applyLookDrag(start: lookStart, dx: Float(dx) * 0.005, dy: Float(dy) * 0.005) }
    }
    func endDrag() {
        guard lookStart != nil else { return }
        lookStart = nil; camera.endDrag(); signalStateChange()
    }
    public func captureState() throws -> EngramGraphViewState {
        guard !isRevoked else { throw EngramGraphSurfaceError.revoked }
        // A host may capture while loading/hidden, before membership can be checked. Preserve the
        // restored selector until the first valid snapshot either accepts it or clears it.
        return try EngramGraphViewState(selectedNode: selectedNode ?? pendingSelection,
            azimuth: Double(camera.targetAzimuth.remainder(dividingBy: .pi * 2)), elevation: Double(camera.targetElevation),
            target: .init(x: Double(camera.targetCameraPos.x), y: Double(camera.targetCameraPos.y), z: Double(camera.targetCameraPos.z)),
            orbitRadius: Double(camera.orbitRadius))
    }
    private func signalStateChange() {
        guard isRenderingActive, let state = try? captureState() else { return }
        pendingFit = nil; automaticFit = nil; staticFallbackCamera = nil
        hasCameraState = true; onStateChange?(identity, state)
    }
}
