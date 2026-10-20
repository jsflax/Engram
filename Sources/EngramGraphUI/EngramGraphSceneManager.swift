import Foundation
import simd
import EngramRealityKit
import EngramSceneKit
import EngramMetalShaders

/// The same RealityKit scene/camera/force engine used by Engram's desktop host.
@MainActor
final class EngramGraphSceneManager {
    let scene: EngramRealityScene
    let camera = CameraController()
    let adapter: EngramGraphDataAdapter
    private let engine: ForceEngine
    private var generation = UUID()
    var onFailure: ((String) -> Void)?
    private var frameChecks = 0
    var validatedRenderedFrameCount: Int { !invalidResources && !scene.isTornDown && frameChecks >= 3 ? frameChecks : 0 }
    private(set) var completedForcePassCount = 0
    private var invalidResources = false
    private var active = false
    private var forceToken: UUID?
    var hasPendingForce: Bool { forceToken != nil }
    private var forceWaiters: [CheckedContinuation<Void, Never>] = []

    init(adapter: EngramGraphDataAdapter) throws {
        self.adapter = adapter
        scene = try EngramRealityScene.makeValidated()
        scene.showsGalaxyTitles = false
        // Embedded hosts share measured label bounds with initial/explicit fits.
        scene.usesViewportBoundedClusterLabels = true
        scene.spatialAudioSystem.playsStartupDiagnosticTone = false
        scene.spatialAudioSystem.isEnabled = false
        let library = try EngramMetalShaders.makePackagedLibrary(device: scene.device)
        guard let compute = MetalForceCompute(device: scene.device, library: library),
              compute.isFullSimAvailable else {
            scene.teardown()
            throw EngramGraphViewerError.rendererUnavailable
        }
        let state = GPUSimulationState(device: scene.device, library: library)
        guard state.integratePipeline != nil else {
            scene.teardown(); throw EngramGraphViewerError.rendererUnavailable
        }
        engine = ForceEngine(forceCompute: compute, simState: state)
        scene.dataProvider = adapter; scene.cameraProvider = camera
        scene.onFrameCallback = { [weak self] dt in
            guard let self, self.active else { return }
            self.frameChecks += 1
            if self.frameChecks == 2 {
                do { try self.scene.validateResources() }
                catch { self.invalidResources = true; self.teardown(); self.onFailure?(error.localizedDescription); return }
            }
            self.camera.pollKeyboard(dt: dt); self.camera.updateCamera(dt: dt)
            self.dispatchForces()
        }
        scene.setActive(false)
    }

    func setActive(_ value: Bool) {
        guard !value || !invalidResources else { return }
        generation = UUID(); active = value
        camera.heldKeys.removeAll(); camera.endDrag()
        adapter.isActive = value
        adapter.simulation.isActive = value && adapter.semanticPositions == nil
        scene.setActive(value)
    }
    func topologyWillChange() { generation = UUID(); frameChecks = 0; completedForcePassCount = 0 }
    func teardown() {
        setActive(false); scene.teardown()
    }
    func drain() async {
        if forceToken != nil {
            await withCheckedContinuation { continuation in forceWaiters.append(continuation) }
        }
        await scene.drainPendingWork()
    }
    private func settleForce(_ token: UUID) {
        guard forceToken == token else { return }
        forceToken = nil
        let waiters = forceWaiters; forceWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    private func dispatchForces() {
        let sim = adapter.simulation
        guard active, sim.isActive, adapter.semanticPositions == nil, !sim.isSettled,
              sim.nodeCount > 1, engine.isFullSimAvailable, !engine.isInFlight else { return }
        let snapshot = ForceEngine.SimulationSnapshot(
            nodeCount: sim.nodeCount, isSettled: sim.isSettled,
            posX: sim.posX, posY: sim.posY, posZ: sim.posZ,
            projectGroups: sim.projectGroupPublic, topicGroups: sim.topicGroupPublic,
            topicProjectGroup: sim.topicProjectGroupPublic,
            galaxyGroups: sim.galaxyGroupPublic, galaxyCenters: sim.galaxyCentersPublic,
            edgeIndices: sim.edgeIndicesPublic, topologyDirty: sim.topologyDirtyForGPU,
            chargeStrength: sim.chargeStrength, crossChargeMultiplier: sim.crossChargeMultiplier,
            sameTopicChargeScale: sim.sameTopicChargeScale, sameProjectChargeScale: sim.sameProjectChargeScale,
            springLength: sim.springLength, crossProjectSpringLength: sim.crossProjectSpringLength,
            springStrength: sim.springStrength,
            cohesionStrength: sim.cohesionStrength, centroidRepulsion: sim.centroidRepulsion,
            topicCohesionStrength: sim.topicCohesionStrength, topicCentroidRepulsion: sim.topicCentroidRepulsion,
            centerStrength: sim.centerStrength,
            alpha: sim.alpha, damping: 0.78, maxSpeed: 12.0
        )
        sim.topologyDirtyForGPU = false

        // Async dispatch — GPU runs force compute while CPU/renderer continue.
        // Results applied next frame via completion handler. Never blocks main thread.
        let epoch = generation, token = UUID()
        forceToken = token
        let command = engine.encodeForcePass(queue: scene.commandQueue, snapshot: snapshot,
            onSettled: { [weak self] in self?.settleForce(token) }) { [weak self] result in
            guard let self, self.generation == epoch, self.active else { return }
            sim.applyGPUForces(result)
            if let positions = result.positions, positions.count == sim.nodeCount {
                self.completedForcePassCount += 1
            }
        }
        if command == nil { settleForce(token) }
    }
}
