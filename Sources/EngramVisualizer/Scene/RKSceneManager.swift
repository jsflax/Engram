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
    var renderViewSize: CGSize = .zero

    // Teleport state
    private(set) var teleportLabel: String?
    private(set) var teleportCounter: Int = 0

    // Data pushed from SwiftUI
    var showMascots: Bool = true
    var layoutMode: LayoutMode = .forceDirected
    var semanticClusters3D: [SemanticCluster3D] = []

    // Force engine
    private var forceEngine: ForceEngine?

    init?(registry: GalaxyRegistry) {
        self.camera = CameraController()
        self.dataAdapter = GalaxyRegistryAdapter(registry: registry)
        self.rkScene = EngramRealityScene()

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

        // Camera update
        camera.pollKeyboard(dt: dt)
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

        // Dispatch GPU forces
        dispatchForces()

        // Spatial audio handled by RKSpatialAudioSystem in EngramRealityScene.update()

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
        // Results applied next frame via completion handler. Never blocks main thread.
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
