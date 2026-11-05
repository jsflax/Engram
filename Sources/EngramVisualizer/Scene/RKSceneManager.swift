import Foundation
import simd
import AppKit
import EngramRealityKit
import EngramSceneKit
import EngramMetalShaders

/// Replaces MetalSceneManager for the RealityKit path.
///
/// Owns EngramRealityScene, bridges GalaxyRegistry data to SceneDataProvider,
/// orchestrates force compute, and drives spatial audio.
@MainActor
final class RKSceneManager {

    let rkScene: EngramRealityScene
    let camera: CameraController
    let dataAdapter: GalaxyRegistryAdapter

    /// Spatial audio is now handled by RKSpatialAudioSystem inside EngramRealityScene.
    /// This property exists for compatibility with Graph3DViewHost sound toggle.
    var soundEnabled: Bool = false {
        didSet { rkScene.spatialAudioSystem.isEnabled = soundEnabled }
    }

    // External references (set by Graph3DView)
    weak var camera3DState: Camera3DState?
    var notificationsEnabled: Bool = false

    /// Galaxy registry — provides all simulation/render data.
    weak var galaxyRegistry: GalaxyRegistry? {
        didSet {
            if let registry = galaxyRegistry {
                dataAdapter.registry = registry
            }
        }
    }

    // Hub expansion controller (shared with Graph3DView for input)
    let hubExpansion = HubExpansionController()

    // Callbacks
    var selectionCallback: ((UUID?) -> Void)?
    var reticleCallback: ((UUID?) -> Void)?
    var teleportCallback: ((String, Int) -> Void)?

    // Per-frame cached state
    var selectedNode: UUID? {
        didSet {
            dataAdapter.selectedNode = selectedNode
        }
    }
    var renderViewSize: CGSize = .zero {
        didSet {
            rkScene.viewportSize = SIMD2(Float(renderViewSize.width), Float(renderViewSize.height))
        }
    }

    // Teleport state
    private(set) var teleportLabel: String?
    private(set) var teleportCounter: Int = 0

    // Data pushed from SwiftUI
    var showMascots: Bool {
        get { rkScene.showMascots }
        set { rkScene.showMascots = newValue }
    }
    var layoutMode: LayoutMode = .forceDirected
    var semanticClusters3D: [SemanticCluster3D] = []

    // Controller polling belongs to the active scene, alongside keyboard input.
    var isGraphInputActive = false {
        didSet {
            if !isGraphInputActive {
                hidInput?.setActive(false)
                inputHandler.reset()
                reticleElapsed = .infinity
                setReticleTarget(nil)
            }
        }
    }
    var controllerConnectionCallback: ((Bool) -> Void)?
    var hidInputStatusCallback: ((HIDGamepadInputStatus) -> Void)?
    private var reportedHIDStatus: HIDGamepadInputStatus = .inactive
    private(set) var hasGamepad = false
    private(set) var reticleTarget: UUID?
    private let inputHandler = InputHandler()
    private let readGamepad: @MainActor (Bool) -> GamepadInputReading
    private let hidInput: HIDGamepadInputProvider?
    private let controllerDiagnostics: GamepadDiagnosticRecorder?
    var graphHostIsVisible = false {
        didSet { if !graphHostIsVisible { hidInput?.setActive(false) } }
    }
    private var graphHostAppearsActive: Bool?
    private var graphHostChatVisible: Bool?
    private let acceptsGamepadInput: @MainActor () -> Bool
    private var reticleElapsed: Float = .infinity

    // Force engine
    private var forceEngine: ForceEngine?

    init?(registry: GalaxyRegistry,
          readGamepad: (@MainActor () -> GamepadInputState?)? = nil,
          controllerDiagnostics: GamepadDiagnosticRecorder? = GamepadDiagnosticRecorder.fromEnvironment(),
          acceptsGamepadInput: @escaping @MainActor () -> Bool = {
              NSApp?.isActive == true && NSApp?.keyWindow?.attachedSheet == nil
                  && !(NSApp?.keyWindow?.firstResponder is NSTextView)
          }) {
        if let readGamepad {
            self.readGamepad = { _ in GamepadInputReading(state: readGamepad(), enumeration: nil) }
            self.hidInput = nil
        } else {
            self.readGamepad = { InputHandler.readGamepad(captureDiagnostics: $0) }
            self.hidInput = HIDGamepadInputProvider()
        }
        self.controllerDiagnostics = controllerDiagnostics
        self.acceptsGamepadInput = acceptsGamepadInput
        self.camera = CameraController()
        self.dataAdapter = GalaxyRegistryAdapter(registry: registry)
        // Hosted isolation supplies an explicit owned directory; Foundation's
        // default temporary directory need not follow the TMPDIR environment.
        let audioDirectory = PerformanceLaunch.isIsolated
            ? ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            : nil
        self.rkScene = EngramRealityScene(
            audioTemporaryDirectory: audioDirectory ?? FileManager.default.temporaryDirectory)

        // Wire scene to data/camera providers
        self.rkScene.dataProvider = dataAdapter
        self.rkScene.cameraProvider = camera

        self.galaxyRegistry = registry
        self.dataAdapter.registry = registry

        // Set up force engine with GPU integration if available
        if let library = try? EngramMetalShaders.makeLibrary(device: rkScene.device),
           let forceCompute = MetalForceCompute(device: rkScene.device, library: library) {
            let simState = GPUSimulationState(device: rkScene.device, library: library)
            self.forceEngine = ForceEngine(forceCompute: forceCompute, simState: simState)
        }

        // Wire per-frame callback so camera/keyboard/forces are driven each frame
        self.rkScene.onFrameCallback = { [weak self] dt in
            self?.renderTick(dt: dt)
        }
        if self.rkScene.isFrameTimingEnabled {
            self.rkScene.onInstrumentedFrameCallback = { [weak self] dt in
                self?.renderTickWithTimings(dt: dt)
            }
        }
    }

    // MARK: - Per-Frame

    /// Perf-harness hooks (mirror EngramPreview): active only when frame-stats
    /// instrumentation is on, so they can't affect normal app behavior.
    /// PREVIEW_AUTO_ORBIT=<deg/s> orbits the camera; PREVIEW_EXIT_AFTER_FRAMES=<n>
    /// flushes the stats CSV and exits — lets the real app run the percentile gate.
    private static let harnessOrbitRate: Float? =
        ProcessInfo.processInfo.environment["ENGRAM_FRAME_STATS"] != nil
            ? ProcessInfo.processInfo.environment["PREVIEW_AUTO_ORBIT"].flatMap(Float.init)
            : nil
    private static let harnessExitAfterFrames: UInt64? =
        ProcessInfo.processInfo.environment["ENGRAM_FRAME_STATS"] != nil
            ? ProcessInfo.processInfo.environment["PREVIEW_EXIT_AFTER_FRAMES"].flatMap(UInt64.init)
            : nil
    private var harnessFramesSeen: UInt64 = 0

    /// Called by EngramRealityScene via SceneEvents.Update — additional per-frame work.
    func renderTick(dt: Float) {
        guard let registry = galaxyRegistry else { return }
        updateCameraForFrame(dt: dt)
        dispatchForces()
        syncCameraPositions(registry)
    }

    /// Measures the synchronous force-dispatch call, including its early exits
    /// or preparation/encoding/submission. Async GPU execution and its later
    /// completion/readback are outside this interval.
    private func renderTickWithTimings(dt: Float) -> UInt64? {
        guard let registry = galaxyRegistry else { return nil }
        updateCameraForFrame(dt: dt)
        let start = DispatchTime.now().uptimeNanoseconds
        dispatchForces()
        let forcePreparation = DispatchTime.now().uptimeNanoseconds - start
        syncCameraPositions(registry)
        return forcePreparation
    }

    @inline(__always)
    private func updateCameraForFrame(dt: Float) {
        // Camera update
        camera.pollKeyboard(dt: dt)
        pollGamepad(dt: dt)
        if let orbitRate = Self.harnessOrbitRate {
            camera.targetAzimuth += orbitRate * dt * .pi / 180
        }
        camera.updateCamera(dt: dt)
        if let exitAfter = Self.harnessExitAfterFrames {
            harnessFramesSeen += 1
            if harnessFramesSeen >= exitAfter {
                rkScene.frameStatsFlush()
                exit(0)
            }
        }
    }

    /// Preserve graph/chat focus rules and suspend input during controller setup.
    /// Retain the host context for explicitly enabled controller diagnostics.
    func updateGraphInputFocus(appearsActive: Bool, mascotChatVisible: Bool,
                              controllerSetupVisible: Bool = false) {
        graphHostAppearsActive = appearsActive
        graphHostChatVisible = mascotChatVisible
        isGraphInputActive = appearsActive && !mascotChatVisible && !controllerSetupVisible
    }

    private func pollGamepad(dt: Float) {
        let recorder = controllerDiagnostics?.isFinished == false ? controllerDiagnostics : nil
        let now = recorder == nil ? 0 : ProcessInfo.processInfo.systemUptime
        let phase = recorder?.nextPhase(now: now, armReady: graphHostIsVisible
            && NSApp?.isActive == true && NSApp?.keyWindow != nil)
        let primary = readGamepad(phase != nil)
        let applicationGate = isGraphInputActive ? acceptsGamepadInput() : nil
        let active = isGraphInputActive && applicationGate == true
        // Hardware discovery and IO live on the provider's serial queue. The
        // frame only changes activation when necessary and reads a value snapshot.
        hidInput?.setActive(active && primary.state == nil && graphHostIsVisible)
        let fallback = hidInput?.snapshot()
        let reading = InputHandler.preferredReading(primary: primary, fallback: fallback, active: active)
        let hidStatus = primary.state == nil ? (fallback?.status ?? .inactive) : .inactive
        if (active || primary.state != nil), reportedHIDStatus != hidStatus {
            reportedHIDStatus = hidStatus
            hidInputStatusCallback?(hidStatus)
        }
        let state = reading.state
        let connected = state != nil
        if hasGamepad != connected {
            hasGamepad = connected
            controllerConnectionCallback?(connected)
        }
        let cameraBefore = recorder.map { _ in (camera.targetCameraPos, camera.targetAzimuth, camera.targetElevation) }
        defer {
            if let recorder, let cameraBefore {
                let gate: GamepadGateDiagnostics?
                if phase != nil {
                    let window = NSApp?.keyWindow
                    let responder = window?.firstResponder
                    gate = GamepadGateDiagnostics(graphHostVisible: graphHostIsVisible,
                        hostAppearsActive: graphHostAppearsActive, mascotChatVisible: graphHostChatVisible,
                        graphInputActive: isGraphInputActive, appActive: NSApp?.isActive == true,
                        keyWindowNumber: window?.windowNumber, attachedSheet: window?.attachedSheet != nil,
                        firstResponderClass: responder.map { NSStringFromClass(type(of: $0)) },
                        firstResponderIsTextView: responder is NSTextView,
                        applicationGateAccepted: applicationGate, inputAccepted: active)
                } else {
                    gate = nil
                }
                recorder.observe(now: now, phase: phase, reading: reading, gate: gate,
                    inputAccepted: active, cameraTargetChanged: cameraBefore.0 != camera.targetCameraPos,
                    cameraLookChanged: cameraBefore.1 != camera.targetAzimuth || cameraBefore.2 != camera.targetElevation)
            }
        }
        let actions = inputHandler.update(state: state, camera: camera, dt: dt, active: active)
        guard connected, active else {
            reticleElapsed = .infinity
            setReticleTarget(nil)
            return
        }
        // Movement needs no graph data. Resolve reticle at most eight times
        // per second; A requests a fresh hit test so selection is never stale.
        if dt.isFinite { reticleElapsed += max(0, dt) }
        if (reticleElapsed >= 0.125 || actions.contains(.select)), renderViewSize.width > 0,
           renderViewSize.height > 0, let registry = galaxyRegistry {
            reticleElapsed = 0
            setReticleTarget(camera.hitTest(
                at: CGPoint(x: renderViewSize.width / 2, y: renderViewSize.height / 2),
                viewSize: renderViewSize, positions: registry.mergedPositions,
                currentTarget: reticleTarget))
        }
        for action in actions {
            switch action {
            case .select:
                if let reticleTarget {
                    selectedNode = reticleTarget
                    selectionCallback?(reticleTarget)
                }
            case .cancel:
                selectedNode = nil
                selectionCallback?(nil)
            case .previousProject: teleportToNextProject(direction: -1)
            case .nextProject: teleportToNextProject(direction: 1)
            case .previousGalaxy: teleportToNextGalaxy(direction: -1)
            case .nextGalaxy: teleportToNextGalaxy(direction: 1)
            }
        }
    }

    private func setReticleTarget(_ target: UUID?) {
        guard reticleTarget != target else { return }
        reticleTarget = target
        reticleCallback?(target)
    }

    @inline(__always)
    private func syncCameraPositions(_ registry: GalaxyRegistry) {
        // Sync camera state (~2fps to avoid cascade)
        if let cam3D = camera3DState, Int.random(in: 0..<30) == 0 {
            cam3D.positions = registry.mergedPositions
        }
    }

    // MARK: - Force Dispatch

    private func dispatchForces() {
        guard let registry = galaxyRegistry,
              let engine = forceEngine else { return }

        let sim = registry.unifiedSimulation
        guard !sim.isSettled, sim.nodeCount > 1, engine.isFullSimAvailable, !engine.isInFlight else { return }

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
        let nodeOrderVersion = sim.nodeOrderVersion

        // Async dispatch — GPU runs force compute while CPU/renderer continue.
        // Submission does not wait for the GPU. The later MainActor completion
        // applies results outside this frame's synchronous preparation timing.
        engine.encodeForcePass(queue: rkScene.commandQueue, snapshot: snapshot) { result in
            sim.applyGPUForces(result, expectedNodeOrderVersion: nodeOrderVersion)
        }
    }

    // MARK: - Input Forwarding

    func captureLookState() -> (azimuth: Float, elevation: Float, camPos: SIMD3<Float>) {
        camera.captureLookState()
    }

    func applyLookDrag(start: (azimuth: Float, elevation: Float, camPos: SIMD3<Float>), dx: Float, dy: Float) {
        camera.applyLookDrag(start: start, dx: dx, dy: dy)
    }

    func endDrag() {
        camera.endDrag()
    }

    func hitTest(at location: CGPoint, viewSize: CGSize) -> UUID? {
        guard let registry = galaxyRegistry else { return nil }
        return camera.hitTest(
            at: location,
            viewSize: viewSize,
            positions: registry.mergedPositions,
            currentTarget: selectedNode
        )
    }

    func hitTestMascot(at location: CGPoint, viewSize: CGSize) -> Bool {
        // Mascot hit testing via RealityKit — check if tap point is near any mascot entity
        // For now, simple distance check on mascot positions
        return false
    }

    func teleportToNextProject(direction: Int = 1) {
        guard let registry = galaxyRegistry else { return }
        camera.teleportToNextProject(
            positions: registry.mergedPositions,
            nodes: dataAdapter.nodes,
            hubs: registry.mergedHubs,
            direction: direction
        )
        teleportCounter += 1
        teleportLabel = camera.teleportLabel
        teleportCallback?(teleportLabel ?? "", teleportCounter)
    }

    func driveToProject(_ project: String) {
        guard let registry = galaxyRegistry else { return }
        camera.driveToProject(project, positions: registry.mergedPositions,
                              nodes: dataAdapter.nodes, hubs: registry.mergedHubs)
    }

    func teleportToNextGalaxy(direction: Int = 1) {
        guard let registry = galaxyRegistry else { return }
        let galaxyNames = Array(registry.galaxies.keys.sorted())
        guard !galaxyNames.isEmpty else { return }

        // Compute galaxy centroid + radius from node positions
        func galaxyBounds(_ name: String) -> (center: SIMD3<Float>, radius: Float) {
            let positions = registry.mergedPositions
            let nodes = registry.mergedNodes
            var pts: [SIMD3<Float>] = []
            for node in nodes {
                if registry.nodeToGalaxy[node.id] == name, let p = positions[node.id] {
                    pts.append(p)
                }
            }
            guard !pts.isEmpty else { return (.zero, 500) }
            var sum = SIMD3<Float>.zero
            for p in pts { sum += p }
            let center = sum / Float(pts.count)
            var maxDist: Float = 0
            for p in pts { maxDist = max(maxDist, simd_length(p - center)) }
            return (center, maxDist + 100)
        }

        // Simple cycling
        if let current = camera.teleportLabel,
           let idx = galaxyNames.firstIndex(of: current) {
            let next = galaxyNames[(idx + direction + galaxyNames.count) % galaxyNames.count]
            let (center, radius) = galaxyBounds(next)
            camera.teleportToGalaxy(center: center, radius: radius, label: next)
        } else if let first = galaxyNames.first {
            let (center, radius) = galaxyBounds(first)
            camera.teleportToGalaxy(center: center, radius: radius, label: first)
        }
        teleportCounter += 1
        teleportLabel = camera.teleportLabel
        teleportCallback?(teleportLabel ?? "", teleportCounter)
    }
}
