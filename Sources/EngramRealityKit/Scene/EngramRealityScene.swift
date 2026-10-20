import RealityKit
import Metal
import simd
import CoreGraphics
import EngramSceneKit
import Foundation

/// Core RealityKit scene manager — owns entity hierarchy and wires systems to data.
///
/// Entity hierarchy:
/// ```
/// RootEntity [SceneRootComponent]
/// ├── PerspectiveCamera
/// ├── NodeBatchEntity [ModelEntity + LowLevelMesh + CustomMaterial]
/// ├── EdgeBatchEntity [ModelEntity + LowLevelMesh + CustomMaterial]
/// ├── LabelBatchEntity [ModelEntity + LowLevelMesh + CustomMaterial]
/// ├── NebulaContainer
/// │   └── per-project NebulaEntity [ParticleEmitterComponent]
/// ├── MascotContainer
/// │   └── per-project MascotEntity [mascot.usdz + MascotComponent]
/// ├── FlowParticleEntity [ModelEntity + LowLevelMesh]
/// └── LightContainer
///     └── up to 16 PointLight entities
/// ```
@MainActor
public final class EngramRealityScene {
    // MARK: - Public Interface

    public let rootEntity: Entity
    public weak var dataProvider: SceneDataProvider?
    public weak var cameraProvider: CameraProvider?

    // MARK: - Entity References

    public let cameraEntity: PerspectiveCamera
    public var nodeBatchEntity: ModelEntity?
    public var edgeBatchEntity: ModelEntity?
    public var labelBatchEntity: ModelEntity?
    public let nebulaContainer: Entity
    public let galaxyTitleContainer: Entity
    public let mascotContainer: Entity
    public var flowParticleEntity: ModelEntity?
    public let lightContainer: Entity

    // MARK: - Metal Resources

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let library: MTLLibrary?

    // MARK: - Batch Mesh State

    var nodeBatchMesh: LowLevelMesh?
    var edgeBatchMesh: LowLevelMesh?
    var labelBatchMesh: LowLevelMesh?
    var flowParticleMesh: LowLevelMesh?

    var nodeBatchCapacity: Int = 0
    var edgeBatchCapacity: Int = 0
    var labelBatchCapacity: Int = 0

    // MARK: - macOS 26+ Instance Resources
    // Stored as Any? to avoid availability constraints on stored properties.
    // Cast back to concrete types in @available(macOS 26, iOS 26, *) methods.

    /// Sphere template entity for MeshInstancesComponent (macOS 26+).
    var nodeTemplateEntity: ModelEntity?
    /// Cylinder template entity for MeshInstancesComponent (macOS 26+).
    var edgeTemplateEntity: ModelEntity?
    /// Per-instance transform data for nodes — `LowLevelInstanceData` (macOS 26+).
    var _nodeInstanceData: Any?
    /// Per-instance transform data for edges — `LowLevelInstanceData` (macOS 26+).
    var _edgeInstanceData: Any?
    /// Per-instance visual data texture for nodes — `LowLevelTexture` (macOS 15+). N×1 rgba16Float.
    var nodeInstanceTexture: LowLevelTexture?
    /// Per-instance visual data texture for edges — row-packed rgba16Float.
    var edgeInstanceTexture: LowLevelTexture?
    /// Current texture row widths; edge capacity can span multiple rows.
    var nodeInstanceTextureWidth: Int = 0
    var edgeInstanceTextureWidth: Int = 0
    /// Set when instance data is replaced (capacity resize) — signals batch systems
    /// to re-create MeshInstancesComponent with the new data reference.
    var nodeInstanceDataChanged: Bool = false
    var edgeInstanceDataChanged: Bool = false

    /// Type-safe accessor for `_nodeInstanceData` (macOS 26+).
    @available(macOS 26, iOS 26, *)
    var nodeInstanceData: LowLevelInstanceData? {
        get { _nodeInstanceData as? LowLevelInstanceData }
        set { _nodeInstanceData = newValue; nodeInstanceDataChanged = true }
    }

    /// Type-safe accessor for `_edgeInstanceData` (macOS 26+).
    @available(macOS 26, iOS 26, *)
    var edgeInstanceData: LowLevelInstanceData? {
        get { _edgeInstanceData as? LowLevelInstanceData }
        set { _edgeInstanceData = newValue; edgeInstanceDataChanged = true }
    }

    // MARK: - Sphere Template

    var sphereTemplateVertices: [(pos: SIMD3<Float>, norm: SIMD3<Float>)] = []
    var sphereTemplateIndices: [UInt32] = []
    var vertsPerSphere: Int = 0
    var indicesPerSphere: Int = 0

    // MARK: - Systems

    public private(set) var lodSystem: LODSystem
    public private(set) var nodeBatchSystem: NodeBatchSystem
    public private(set) var edgeBatchSystem: EdgeBatchSystem
    public private(set) var labelBatchSystem: LabelBatchSystem
    public private(set) var cameraSystem: CameraSystem
    public private(set) var nebulaBatchSystem: NebulaBatchSystem
    public private(set) var galaxyTitleSystem: GalaxyTitleSystem
    /// Embedded single-graph hosts already present the graph title in their UI.
    /// The desktop multi-galaxy renderer keeps its world-space titles by default.
    public var showsGalaxyTitles = true {
        didSet { galaxyTitleContainer.isEnabled = showsGalaxyTitles }
    }
    /// Optional point-size caps for project/topic billboards in a small embedded viewport.
    /// Desktop hosts retain their original world-space sizes unless they opt in.
    public var usesViewportBoundedClusterLabels = false
    public var clusterLabelViewportSize: CGSize?
    public private(set) var mascotSystem: RKMascotSystem
    public private(set) var flowParticleSystem: RKFlowParticleSystem
    public let spatialAudioSystem: RKSpatialAudioSystem

    // MARK: - Label Atlas

    public private(set) var labelAtlasGenerator: RKLabelAtlasGenerator

    // MARK: - Frame State

    var lastTopologyVersion: UInt64 = 0
    var animationTime: Float = 0
    var frameCount: UInt64 = 0
    var visibleSet: VisibleSet = .init()

    /// Per-frame callback for the app layer (RKSceneManager) to poll keyboard,
    /// update camera smoothing, dispatch forces, etc. Called at the start of each frame.
    public var onFrameCallback: ((Float) -> Void)?
    public private(set) var isActive = true
    public private(set) var isTornDown = false
    private var setupCompleted = false
    let diagnosticGeneration = UUID().uuidString.lowercased()
    private var diagnosticResourceVersion: [UInt64] = []
    public private(set) var materialFallbacks = Set<String>()
    func recordMaterialFallback(_ name: String) { materialFallbacks.insert(name) }
    var stopFrameSubscription: (() -> Void)?
    private var pendingFrameSubmissions = Set<UUID>()
    private var frameDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var contentHostDetachers: [UUID: () -> Void] = [:]
    private var retirementTask: Task<Void, Never>?
    private(set) var resourcesReleased = false
    var pendingFrameSubmissionCount: Int { pendingFrameSubmissions.count }
    var attachedContentHostCount: Int { contentHostDetachers.count }

    /// The owner has added this root to actual view content. The callback must
    /// remove that exact root through the host's public content API. Returning
    /// from it acknowledges content removal, not CoreRE/GPU presentation completion.
    func registerContentHost(detach: @escaping () -> Void) -> UUID? {
        guard !isTornDown else { detach(); return nil }
        let token = UUID()
        contentHostDetachers[token] = detach
        EngramRenderLifecycleDiagnostic.record(.contentAttached, snapshot: renderDiagnosticSnapshot())
        return token
    }

    func removeContentHost(_ token: UUID) {
        guard let detach = contentHostDetachers.removeValue(forKey: token) else { return }
        EngramRenderLifecycleDiagnostic.record(.contentDetaching, snapshot: renderDiagnosticSnapshot())
        detach()
        EngramRenderLifecycleDiagnostic.record(.contentDetached, snapshot: renderDiagnosticSnapshot())
    }

    /// Call after pause/teardown. Join native asset loads and submitted mesh
    /// writes; cancellation withdraws visibility immediately but does not pretend
    /// that a native operation has already returned.
    public func drainPendingWork() async {
        await drainSubmittedWork()
        if let retirementTask { await retirementTask.value }
    }

    private func drainSubmittedWork() async {
        await mascotSystem.drainPendingLoads()
        if !pendingFrameSubmissions.isEmpty {
            await withCheckedContinuation { frameDrainWaiters.append($0) }
        }
    }

    private func finishFrameSubmission(_ id: UUID) {
        pendingFrameSubmissions.remove(id)
        if pendingFrameSubmissions.isEmpty {
            let waiters = frameDrainWaiters; frameDrainWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    /// Reversible visibility/background pause. Data remains owned by the host.
    public func setActive(_ active: Bool) {
        guard !isTornDown else { return }
        let changed = isActive != active
        isActive = active
        rootEntity.isEnabled = active
        mascotSystem.setActive(active)
        if !active { stopFrameSubscription?(); spatialAudioSystem.stopAll() }
        if changed { EngramRenderLifecycleDiagnostic.record(.sceneActivity, snapshot: renderDiagnosticSnapshot()) }
    }

    /// Terminal stop for graph replacement/revocation. Visibility, callbacks and
    /// data authority are withdrawn synchronously. Exact host content is detached
    /// before a completion-owned task releases resources used by submitted work.
    /// Call drainPendingWork() to join that retirement; cancellation cannot skip it.
    public func teardown() {
        guard !isTornDown else { return }
        EngramRenderLifecycleDiagnostic.record(.teardownStarting, snapshot: renderDiagnosticSnapshot())
        setActive(false)
        isTornDown = true
        stopFrameSubscription = nil
        onFrameCallback = nil; dataProvider = nil; cameraProvider = nil
        for token in Array(contentHostDetachers.keys) { removeContentHost(token) }
        // Also support callers that attached the root below an ordinary Entity.
        rootEntity.removeFromParent()
        retirementTask = Task { @MainActor [self] in
            EngramRenderLifecycleDiagnostic.record(.retirementWaiting, snapshot: renderDiagnosticSnapshot())
            await drainSubmittedWork()
            releaseRetiredResources()
            retirementTask = nil
        }
    }

    private func releaseRetiredResources() {
        guard isTornDown, !resourcesReleased else { return }
        precondition(contentHostDetachers.isEmpty && pendingFrameSubmissions.isEmpty)
        EngramRenderLifecycleDiagnostic.record(.resourcesReleasing, snapshot: renderDiagnosticSnapshot())
        mascotSystem.teardown(); spatialAudioSystem.teardown()
        rootEntity.children.removeAll()
        nebulaContainer.children.removeAll(); galaxyTitleContainer.children.removeAll()
        mascotContainer.children.removeAll(); lightContainer.children.removeAll()
        nodeBatchEntity = nil; edgeBatchEntity = nil; labelBatchEntity = nil; flowParticleEntity = nil
        nodeTemplateEntity = nil; edgeTemplateEntity = nil
        nodeBatchMesh = nil; edgeBatchMesh = nil; labelBatchMesh = nil; flowParticleMesh = nil
        _nodeInstanceData = nil; _edgeInstanceData = nil
        nodeInstanceTexture = nil; edgeInstanceTexture = nil
        pointLightPool.removeAll(); visibleSet = .init()
        lodSystem = LODSystem(); nodeBatchSystem = NodeBatchSystem(); edgeBatchSystem = EdgeBatchSystem()
        labelBatchSystem = LabelBatchSystem(); cameraSystem = CameraSystem()
        nebulaBatchSystem = NebulaBatchSystem(); galaxyTitleSystem = GalaxyTitleSystem()
        flowParticleSystem = RKFlowParticleSystem()
        labelAtlasGenerator = RKLabelAtlasGenerator(device: device)
        frameStatsFlush()
        resourcesReleased = true
        EngramRenderLifecycleDiagnostic.record(.resourcesReleased, snapshot: renderDiagnosticSnapshot())
    }

    // Point light pool (max 16)
    var pointLightPool: [Entity] = []
    let maxPointLights = 16
    private var activePointLightCount = 0
    private(set) var diagnosticPointLightWrites: UInt64 = 0

    // MARK: - Scale Factor

    /// World-to-RealityKit scale. RealityKit works in meters — graph positions
    /// are in arbitrary units (~100-1000 range). Scale of 1.0 means 1 graph unit = 1 meter.
    public let scaleFactor: Float = 1.0

    // MARK: - Init

    public convenience init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal is required for EngramRealityKit")
        }
        self.init(device: device, commandQueue: queue)
    }

    /// Embedded hosts use this instead of the legacy fatal initializer.
    public static func makeValidated(requireMascot: Bool = true) throws -> EngramRealityScene {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RendererResourceError.metalUnavailable
        }
        let scene = EngramRealityScene(device: device, commandQueue: queue)
        do { try scene.validateResources(requireMascot: requireMascot); return scene }
        catch { scene.teardown(); throw error }
    }

    private init(device: MTLDevice, commandQueue: MTLCommandQueue) {
        self.device = device
        self.commandQueue = commandQueue
        self.library = try? device.makeDefaultLibrary(bundle: .module)

        // Create entity hierarchy
        self.rootEntity = Entity()
        rootEntity.name = "EngramRoot"
        rootEntity.components.set(SceneRootComponent())

        self.cameraEntity = PerspectiveCamera()
        cameraEntity.name = "Camera"

        self.nebulaContainer = Entity()
        nebulaContainer.name = "NebulaContainer"

        self.galaxyTitleContainer = Entity()
        galaxyTitleContainer.name = "GalaxyTitleContainer"

        self.mascotContainer = Entity()
        mascotContainer.name = "MascotContainer"

        self.lightContainer = Entity()
        lightContainer.name = "LightContainer"

        // Initialize systems
        self.lodSystem = LODSystem()
        self.nodeBatchSystem = NodeBatchSystem()
        self.edgeBatchSystem = EdgeBatchSystem()
        self.labelBatchSystem = LabelBatchSystem()
        self.cameraSystem = CameraSystem()
        self.nebulaBatchSystem = NebulaBatchSystem()
        self.galaxyTitleSystem = GalaxyTitleSystem()
        self.mascotSystem = RKMascotSystem()
        self.flowParticleSystem = RKFlowParticleSystem()
        self.spatialAudioSystem = RKSpatialAudioSystem()
        self.labelAtlasGenerator = RKLabelAtlasGenerator(device: device)

        // Generate sphere template (after all stored properties initialized)
        generateSphereTemplate(segments: 8, rings: 6)

        // Build entity hierarchy
        rootEntity.addChild(cameraEntity)
        rootEntity.addChild(nebulaContainer)
        rootEntity.addChild(galaxyTitleContainer)
        rootEntity.addChild(mascotContainer)
        rootEntity.addChild(lightContainer)

        // Create point light pool
        for i in 0..<maxPointLights {
            let light = Entity()
            light.name = "PointLight_\(i)"
            light.components.set(PointLightComponent(color: .white, intensity: 0, attenuationRadius: 100))
            light.components.set(GlowLightComponent(nodeId: UUID()))
            lightContainer.addChild(light)
            pointLightPool.append(light)
        }
        EngramRenderLifecycleDiagnostic.record(.sceneCreated, snapshot: renderDiagnosticSnapshot())
    }

    // MARK: - Setup

    /// Creates and returns the root entity ready for RealityView. Call once.
    public func setup() -> Entity {
        guard !isTornDown, !setupCompleted else { return rootEntity }
        setupCompleted = true
        // Create batch entities with initial materials
        setupNodeBatch()
        setupEdgeBatch()
        setupLabelBatch()
        setupFlowParticles()
        EngramRenderLifecycleDiagnostic.record(.sceneSetupCompleted, snapshot: renderDiagnosticSnapshot())
        return rootEntity
    }

    // MARK: - Frame Stats (V0 instrumentation)

    /// Per-phase frame timing CSV, enabled by ENGRAM_FRAME_STATS. The env
    /// value is the output path ("1" → /tmp/engram-frame-stats.csv). Lines
    /// are buffered and flushed every 120 frames so the harness itself
    /// doesn't add a per-frame write syscall to the measurement.
    private lazy var frameStatsPath: String? = {
        guard let v = ProcessInfo.processInfo.environment["ENGRAM_FRAME_STATS"], !v.isEmpty else { return nil }
        return v == "1" ? "/tmp/engram-frame-stats.csv" : v
    }()
    private var frameStatsBuffer: [String] = []
    private var frameStatsHeaderWritten = false

    @inline(__always)
    private func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private func frameStatsAppend(_ line: String) {
        frameStatsBuffer.append(line)
        if frameStatsBuffer.count >= 120 { frameStatsFlush() }
    }

    public func frameStatsFlush() {
        guard let path = frameStatsPath, !frameStatsBuffer.isEmpty else { return }
        if !frameStatsHeaderWritten {
            let refresh = RKPlatform.maximumFramesPerSecond
            let header = "# refresh_hz=\(refresh) date=\(Date())\n"
                + "frame,dt_ms,tick_ms,lod_ms,node_ms,edge_ms,label_ms,commit_ms,nebula_ms,mascot_ms,flow_ms,lights_ms,audio_ms,total_ms,nodes,edges,vis_edges,near,mid,far\n"
            FileManager.default.createFile(atPath: path, contents: header.data(using: .utf8))
            frameStatsHeaderWritten = true
        }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(frameStatsBuffer.joined().data(using: .utf8)!)
            try? h.close()
        }
        frameStatsBuffer.removeAll(keepingCapacity: true)
    }

    // MARK: - Per-Frame Update

    /// Called from SceneEvents.Update — drives all systems.
    public func update(dt: Float) {
        guard isActive, !isTornDown, let dataProvider else { return }
        if frameStatsPath != nil { return updateInstrumented(dt: dt, dataProvider: dataProvider) }
        updateBody(dt: dt, dataProvider: dataProvider)
    }

    /// Instrumented wrapper: phase timings are captured inside updateBody via
    /// the phaseMarks array; this keeps the un-instrumented path branch-free.
    private var phaseMarks: [UInt64] = []
    private func updateInstrumented(dt: Float, dataProvider: SceneDataProvider) {
        phaseMarks.removeAll(keepingCapacity: true)
        let t0 = nowNs()
        phaseMarks.append(t0)
        updateBody(dt: dt, dataProvider: dataProvider)
        let tEnd = nowNs()
        // phaseMarks: [start, afterTick, afterLOD, afterNode, afterEdge,
        //              afterLabel, afterCommit, afterNebula, afterMascot,
        //              afterFlow, afterLights, afterAudio]
        func ms(_ i: Int, _ j: Int) -> Double {
            guard i < phaseMarks.count, j < phaseMarks.count else { return 0 }
            return Double(phaseMarks[j] &- phaseMarks[i]) / 1_000_000
        }
        let totalMs = Double(tEnd &- t0) / 1_000_000
        let line = String(
            format: "%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%d,%d,%d,%d,%d\n",
            frameCount, Double(dt) * 1000,
            ms(0, 1), ms(1, 2), ms(2, 3), ms(3, 4), ms(4, 5), ms(5, 6),
            ms(6, 7), ms(7, 8), ms(8, 9), ms(9, 10), ms(10, 11), totalMs,
            dataProvider.nodes.count, dataProvider.edges.count,
            visibleSet.visibleEdgeIndices.count, visibleSet.nearNodes.count,
            visibleSet.midNodes.count, visibleSet.farNodes.count)
        frameStatsAppend(line)
    }

    @inline(__always)
    private func phaseMark() {
        if frameStatsPath != nil { phaseMarks.append(nowNs()) }
    }

    private func updateBody(dt: Float, dataProvider: SceneDataProvider) {
        // 0. App-layer per-frame callback (keyboard, camera smoothing, force dispatch)
        onFrameCallback?(dt)
        guard isActive, !isTornDown else { return }

        animationTime += dt
        frameCount += 1

        // 1. Tick data provider (drain + simulate)
        dataProvider.tick(dt: dt)
        guard isActive, !isTornDown else { return }
        phaseMark()

        // 2. Update scene root component
        var rootComp = rootEntity.components[SceneRootComponent.self] ?? SceneRootComponent()
        rootComp.animationTime = animationTime
        let topologyChanged = dataProvider.topologyVersion != lastTopologyVersion
        if topologyChanged {
            rootComp.topologyVersion = dataProvider.topologyVersion
            lastTopologyVersion = dataProvider.topologyVersion
        }
        rootEntity.components.set(rootComp)

        // 3. Camera sync
        if let cameraProvider {
            cameraSystem.update(camera: cameraEntity, state: cameraProvider.cameraState, scaleFactor: scaleFactor)
        }

        // 4. LOD culling
        let cameraPos = cameraProvider?.cameraState.cameraPosition ?? .zero
        visibleSet = lodSystem.computeVisibleSet(
            nodes: dataProvider.nodes,
            edges: dataProvider.edges,
            positions: dataProvider.positions,
            positionArray: dataProvider.positionArray,
            cameraPosition: cameraPos,
            selectedNode: dataProvider.selectedNode,
            glowingNodes: dataProvider.glowingNodes,
            hubs: dataProvider.hubs,
            topologyVersion: dataProvider.topologyVersion,
            positionRevision: dataProvider.positionRevision
        )
        phaseMark()

        if frameCount % 120 == 1 {
            print("[scene] frame=\(frameCount) nodes=\(dataProvider.nodes.count) edges=\(dataProvider.edges.count) near=\(visibleSet.nearNodes.count) mid=\(visibleSet.midNodes.count) far=\(visibleSet.farNodes.count) visEdges=\(visibleSet.visibleEdgeIndices.count) cam=\(cameraPos)")
        }

        // Shared command buffer for all batch system GPU writes — one commit instead of 3-4.
        guard let sharedCmdBuf = commandQueue.makeCommandBuffer() else { return }

        // 5. Node batch update
        nodeBatchSystem.update(
            scene: self,
            dataProvider: dataProvider,
            visibleSet: visibleSet,
            topologyChanged: topologyChanged,
            animationTime: animationTime,
            scaleFactor: scaleFactor,
            commandBuffer: sharedCmdBuf
        )
        phaseMark()

        // 6. Edge batch update

        edgeBatchSystem.update(
            scene: self,
            dataProvider: dataProvider,
            visibleSet: visibleSet,
            topologyChanged: topologyChanged,
            scaleFactor: scaleFactor,
            commandBuffer: sharedCmdBuf
        )
        phaseMark()

        // 7. Label batch update

        labelBatchSystem.update(
            scene: self,
            dataProvider: dataProvider,
            visibleSet: visibleSet,
            topologyChanged: topologyChanged,
            cameraPosition: cameraPos,
            scaleFactor: scaleFactor,
            frameCount: frameCount,
            commandBuffer: sharedCmdBuf
        )
        phaseMark()

        // Single GPU commit for all batch system writes. No CPU wait: color
        // and transform stay associated per NODE via stable instance slots
        // (see NodeBatchSystem) — a one-frame skew between the color-texture
        // blit and RealityKit's transform pickup then pairs a node's own
        // color with its own transform, so no flashing. (A waitUntilCompleted
        // here was tried: it cost measurable frame time and still couldn't
        // order OUR blit against RealityKit's internal instance-data upload.)
        let submission = UUID()
        pendingFrameSubmissions.insert(submission)
        sharedCmdBuf.addCompletedHandler { [weak self] _ in
            Task { @MainActor [weak self] in self?.finishFrameSubmission(submission) }
        }
        sharedCmdBuf.commit()
        if EngramRenderLifecycleDiagnostic.isEnabled {
            // Small scalar signature only. No snapshots/logging on unchanged
            // frames except one pulse every 120 actual hosted frame callbacks.
            let version = [UInt64(nodeBatchCapacity), UInt64(edgeBatchCapacity), UInt64(labelBatchCapacity),
                labelAtlasGenerator.diagnosticAtlasCreations, labelBatchSystem.diagnosticMaterialAssignments,
                _nodeInstanceData == nil ? 0 : 1, _edgeInstanceData == nil ? 0 : 1]
            if version != diagnosticResourceVersion {
                diagnosticResourceVersion = version
                EngramRenderLifecycleDiagnostic.record(.resourceGenerationChanged, snapshot: renderDiagnosticSnapshot())
            } else if frameCount % 120 == 0 {
                EngramRenderLifecycleDiagnostic.record(.framePulse, snapshot: renderDiagnosticSnapshot())
            }
        }
        phaseMark()

        // 8. Nebula update — cameraPos drives the far-LOD crossfade
        // (per-project gas near, one galaxy-colored mass far).
        nebulaBatchSystem.update(
            container: nebulaContainer,
            dataProvider: dataProvider,
            topologyChanged: topologyChanged,
            scaleFactor: scaleFactor,
            cameraPosition: cameraPos
        )
        phaseMark()

        // 8b. Galaxy titles — glowing displayName above each galaxy.
        if showsGalaxyTitles {
            galaxyTitleSystem.update(
                container: galaxyTitleContainer,
                dataProvider: dataProvider,
                scaleFactor: scaleFactor
            )
        }
        phaseMark()

        // 9. Mascot update

        mascotSystem.update(
            container: mascotContainer,
            dataProvider: dataProvider,
            dt: dt,
            scaleFactor: scaleFactor
        )
        phaseMark()

        // 10. Flow particles

        flowParticleSystem.update(
            scene: self,
            dataProvider: dataProvider,
            dt: dt,
            scaleFactor: scaleFactor
        )
        phaseMark()

        // 11. Point lights

        updatePointLights(dataProvider: dataProvider)
        phaseMark()

        // 12. Spatial audio
        spatialAudioSystem.update(
            scene: self,
            dataProvider: dataProvider,
            visibleSet: visibleSet,
            dt: dt
        )
        phaseMark()
    }

    // MARK: - Sphere Template

    private func generateSphereTemplate(segments: Int, rings: Int) {
        var verts: [(pos: SIMD3<Float>, norm: SIMD3<Float>)] = []
        var indices: [UInt32] = []

        for ring in 0...rings {
            let phi = Float.pi * Float(ring) / Float(rings)
            let y = cos(phi)
            let sinPhi = sin(phi)

            for seg in 0...segments {
                let theta = 2.0 * Float.pi * Float(seg) / Float(segments)
                let x = sinPhi * cos(theta)
                let z = sinPhi * sin(theta)
                let normal = SIMD3<Float>(x, y, z)
                verts.append((pos: normal, norm: normal))
            }
        }

        let stride = segments + 1
        for ring in 0..<rings {
            for seg in 0..<segments {
                let tl = UInt32(ring * stride + seg)
                let tr = tl + 1
                let bl = tl + UInt32(stride)
                let br = bl + 1
                indices.append(contentsOf: [tl, bl, tr, tr, bl, br])
            }
        }

        sphereTemplateVertices = verts
        sphereTemplateIndices = indices
        vertsPerSphere = verts.count
        indicesPerSphere = indices.count
    }

    /// Build a MeshResource from the existing low-poly sphere template.
    private func makeLowPolySphereResource() -> MeshResource? {
        guard !sphereTemplateVertices.isEmpty else { return nil }
        var desc = MeshDescriptor(name: "low_poly_sphere")
        desc.positions = MeshBuffers.Positions(
            sphereTemplateVertices.map { $0.pos }
        )
        desc.normals = MeshBuffers.Normals(
            sphereTemplateVertices.map { $0.norm }
        )
        desc.primitives = .triangles(sphereTemplateIndices)
        return try? MeshResource.generate(from: [desc])
    }

    /// 6-sided cylinder: 12 verts, 36 indices. Matches EdgeBatchSystem.sides=6.
    /// Unit cylinder spanning Y = -0.5 to Y = +0.5, radius = 1.0.
    private static func makeLowPolyCylinderResource() -> MeshResource? {
        let sides = 6
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(sides * 2)
        normals.reserveCapacity(sides * 2)
        indices.reserveCapacity(sides * 6)

        for i in 0..<sides {
            let angle = Float(i) / Float(sides) * 2 * .pi
            let nx = cos(angle), nz = sin(angle)
            // Bottom ring (y = -0.5), then top ring (y = +0.5)
            positions.append(SIMD3<Float>(nx, -0.5, nz))
            normals.append(SIMD3<Float>(nx, 0, nz))
            positions.append(SIMD3<Float>(nx, 0.5, nz))
            normals.append(SIMD3<Float>(nx, 0, nz))
        }
        for i in 0..<sides {
            let b0 = UInt32(i * 2)      // bottom
            let t0 = UInt32(i * 2 + 1)  // top
            let b1 = UInt32(((i + 1) % sides) * 2)
            let t1 = UInt32(((i + 1) % sides) * 2 + 1)
            indices.append(contentsOf: [b0, b1, t0, t0, b1, t1])
        }
        var desc = MeshDescriptor(name: "low_poly_cylinder")
        desc.positions = MeshBuffers.Positions(positions)
        desc.normals = MeshBuffers.Normals(normals)
        desc.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [desc])
    }

    // MARK: - Batch Setup

    private func setupNodeBatch() {
        // Initial empty — will be populated on first update with data
    }

    private func setupEdgeBatch() {
        // Initial empty — will be populated on first update with data
    }

    private func setupLabelBatch() {
        // Initial empty — will be populated on first update with data
    }

    private func setupFlowParticles() {
        // Initial empty — will be populated when a node is selected
    }

    // MARK: - macOS 26+ Instance Resource Setup

    /// Ensure sphere template entity and instance data/texture exist with sufficient capacity.
    @available(macOS 26, iOS 26, *)
    func ensureNodeInstanceResources(capacity: Int) {
        guard nodeInstanceData == nil else { return }
        // Allocate once at LOD max — instanceCount starts at 0, capacity is fixed.
        let maxCap = lodSystem.maxNodeInstances
        guard maxCap > 0 else { return }
        print("[NODE-INST] ensureNodeInstanceResources allocating capacity=\(maxCap)")

        guard let instData = try? LowLevelInstanceData(instanceCount: 0, instanceCapacity: maxCap) else {
            print("[NODE-INST] ERROR: failed to create LowLevelInstanceData")
            return
        }
        print("[NODE-INST] LowLevelInstanceData created: true, capacity=\(instData.instanceCapacity)")

        // Create visual data texture (maxCap×1, rgba16Float)
        let texDesc = LowLevelTexture.Descriptor(
            textureType: .type2D,
            pixelFormat: .rgba16Float,
            width: maxCap, height: 1,
            textureUsage: [.shaderRead]
        )
        // Keep every resource local until the entity is completely configured.
        // A failed allocation must not latch the once-only admission guard.
        guard let tex = try? LowLevelTexture(descriptor: texDesc),
              let texResource = try? TextureResource(from: tex) else {
            print("[NODE-INST] ERROR: failed to create TextureResource")
            return
        }

        // Create low-poly sphere from existing template (63 verts, 288 indices).
        // Default generateSphere has ~14,700 indices → 680 instances hits
        // the 10M vertex/index limit. 8000 × 288 = 2.3M — well under 10M.
        guard let sphereMesh = makeLowPolySphereResource() else {
            print("[NODE-INST] ERROR: failed to create low-poly sphere MeshResource")
            return
        }
        let material = MaterialFactory.makeNodeMaterial(
            device: device,
            instanceTexture: texResource,
            textureWidth: Float(maxCap),
            mode: 1.0,
            onFallback: { [weak self] in self?.recordMaterialFallback("node") }
        )
        print("[NODE-INST] Creating node_instanced entity")
        let entity = ModelEntity(mesh: sphereMesh, materials: [material])
        entity.name = "node_instanced"
        guard let instances = try? MeshInstancesComponent(
            mesh: sphereMesh, instances: instData, bounds: LowLevelMeshFactory.batchMeshBounds
        ) else {
            print("[NODE-INST] ERROR: failed to create MeshInstancesComponent")
            return
        }
        entity.components.set(NodeBatchComponent())
        entity.components.set(instances)

        // Publish one complete zero-instance group before attaching it. Later
        // updates change this same data object, never replace the component.
        nodeInstanceTexture = tex
        nodeInstanceTextureWidth = maxCap
        nodeTemplateEntity = entity
        nodeInstanceData = instData
        rootEntity.addChild(entity)
    }

    /// Ensure cylinder template entity and instance data/texture exist with sufficient capacity.
    @available(macOS 26, iOS 26, *)
    func ensureEdgeInstanceResources(capacity: Int) {
        guard edgeInstanceData == nil else { return }
        let maxCap = min(lodSystem.maxEdgeInstances, 16384)
        guard maxCap > 0 else { return }
        // The iOS simulator accepts at most 8192 texels per dimension. Keep
        // every existing edge slot by packing across rows on every platform.
        // A Metal descriptor validation abort cannot be caught by `try?`.
        let textureWidth = min(maxCap, 8192)
        let textureHeight = (maxCap + textureWidth - 1) / textureWidth
        print("[EDGE-INST] ensureEdgeInstanceResources allocating capacity=\(maxCap)")

        guard let instData = try? LowLevelInstanceData(instanceCount: 0, instanceCapacity: maxCap) else {
            print("[EDGE-INST] ERROR: failed to create LowLevelInstanceData")
            return
        }
        print("[EDGE-INST] LowLevelInstanceData created: true, capacity=\(instData.instanceCapacity)")

        let texDesc = LowLevelTexture.Descriptor(
            textureType: .type2D,
            pixelFormat: .rgba16Float,
            width: textureWidth, height: textureHeight,
            textureUsage: [.shaderRead]
        )
        guard let tex = try? LowLevelTexture(descriptor: texDesc),
              let texResource = try? TextureResource(from: tex) else {
            print("[EDGE-INST] ERROR: failed to create TextureResource")
            return
        }

        // Use a low-poly 6-sided cylinder (12 verts, 36 indices) instead of
        // generateCylinder() which creates ~8K verts. With 16K instances,
        // the high-poly mesh exceeds RealityKit's 10M vertex/index limit.
        let cylinderMesh = Self.makeLowPolyCylinderResource() ?? MeshResource.generateCylinder(height: 1.0, radius: 1.0)
        let material = MaterialFactory.makeEdgeMaterial(
            device: device,
            instanceTexture: texResource,
            textureWidth: Float(textureWidth),
            useGeometryModifier: true,
            onFallback: { [weak self] in self?.recordMaterialFallback("edge") }
        )
        print("[EDGE-INST] Creating edge_instanced entity")
        let entity = ModelEntity(mesh: cylinderMesh, materials: [material])
        entity.name = "edge_instanced"
        guard let instances = try? MeshInstancesComponent(
            mesh: cylinderMesh, instances: instData, bounds: LowLevelMeshFactory.batchMeshBounds
        ) else {
            print("[EDGE-INST] ERROR: failed to create MeshInstancesComponent")
            return
        }
        entity.components.set(EdgeBatchComponent())
        entity.components.set(instances)

        // Match node initialization: no visible default ModelEntity and no
        // partially published resource set if any required creation fails.
        edgeInstanceTexture = tex
        edgeInstanceTextureWidth = textureWidth
        edgeTemplateEntity = entity
        edgeInstanceData = instData
        rootEntity.addChild(entity)
    }

    // MARK: - Point Lights

    func updatePointLights(dataProvider: SceneDataProvider) {
        // Collect all nodes that need lights: glowing + new node glow + search matches
        var lightTargets: [(id: UUID, color: SIMD3<Float>, intensity: Float)] = []

        for (nodeId, elapsed) in dataProvider.glowingNodes {
            let intensity = recallGlowIntensity(elapsed: elapsed)
            guard intensity > 0.01 else { continue }
            let color = projectColor(for: nodeId, dataProvider: dataProvider)
            lightTargets.append((nodeId, color, intensity * 500))
        }

        for (nodeId, elapsed) in dataProvider.newNodeGlows {
            let intensity = arrivalGlowIntensity(elapsed: elapsed)
            guard intensity > 0.01 else { continue }
            let color = projectColor(for: nodeId, dataProvider: dataProvider)
            lightTargets.append((nodeId, color * 1.5, intensity * 300))
        }

        // Sort by intensity (brightest first) and cap at pool size
        lightTargets.sort { $0.intensity > $1.intensity }
        let activeCount = min(lightTargets.count, maxPointLights)

        // The pool begins disabled. Touch active lights each frame for their
        // animated intensity/position, and disable departed slots exactly once.
        // A static graph with no glow needs no component writes.
        for i in 0..<max(activeCount, activePointLightCount) {
            let light = pointLightPool[i]
            if i < activeCount {
                let target = lightTargets[i]
                if let pos = dataProvider.positions[target.id] {
                    light.position = pos * scaleFactor
                    light.components.set(PointLightComponent(
                        color: .init(
                            red: CGFloat(target.color.x),
                            green: CGFloat(target.color.y),
                            blue: CGFloat(target.color.z),
                            alpha: 1
                        ),
                        intensity: target.intensity,
                        attenuationRadius: 100
                    ))
                    diagnosticPointLightWrites &+= 1
                }
            } else {
                // Deactivate — set intensity to 0 instead of removing from scene graph
                light.components.set(PointLightComponent(color: .white, intensity: 0, attenuationRadius: 10))
                diagnosticPointLightWrites &+= 1
            }
        }
        activePointLightCount = activeCount
    }

    func projectColor(for nodeId: UUID, dataProvider: SceneDataProvider) -> SIMD3<Float> {
        if let node = dataProvider.nodes.first(where: { $0.id == nodeId }) {
            return dataProvider.projectColorMap[node.project] ?? SIMD3<Float>(0.5, 0.5, 0.5)
        }
        return SIMD3<Float>(0.5, 0.5, 0.5)
    }
}
