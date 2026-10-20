import RealityKit
import simd
import Foundation
import CoreGraphics

/// Mascot behavioral state machine + entity management.
///
/// Port of behavioral logic from MascotSystem.swift — state transitions,
/// task queue, and joint animation. Uses USDZ skeleton instead of vertex buffers.
@MainActor
public final class RKMascotSystem {
    private var activeMascots: [String: Entity] = [:]
    private var mascotStates: [String: MascotBehavior] = [:]
    private var taskQueues: [String: [MascotTask]] = [:]
    private var idleTimers: [String: Float] = [:]
    private var patrolThresholds: [String: Float] = [:]
    private var animationTimes: [String: Float] = [:]
    private var currentPositions: [String: SIMD3<Float>] = [:]
    private var currentYaws: [String: Float] = [:]
    private var mascotLoadingProjects: Set<String> = []
    private var loadingTasks: [String: Task<Void, Never>] = [:]
    private var inFlightLoads: [UUID: Task<Void, Never>] = [:]
    private let loadMascot: @MainActor (String, SIMD3<Float>) async -> Entity
    private var lifecycleGeneration: UInt64 = 0
    private var isActive = true
    private var isTornDown = false

    public func setActive(_ active: Bool) {
        guard !isTornDown else { return }
        isActive = active
        if !active {
            lifecycleGeneration &+= 1
            for task in loadingTasks.values { task.cancel() }
            loadingTasks.removeAll(); mascotLoadingProjects.removeAll()
        }
    }

    public func teardown() {
        setActive(false); isTornDown = true
        for entity in activeMascots.values { entity.removeFromParent() }
        activeMascots.removeAll(); mascotStates.removeAll(); taskQueues.removeAll()
        idleTimers.removeAll(); patrolThresholds.removeAll(); animationTimes.removeAll()
        currentPositions.removeAll(); currentYaws.removeAll(); cachedActiveProjects.removeAll()
        lastHoloNodeIds.removeAll(); holoOpacities.removeAll()
    }

    /// Priority-comparable task type for mascot behavior.
    public enum MascotTask: Comparable {
        case create(nodeId: UUID, position: SIMD3<Float>)
        case delete(nodeId: UUID, position: SIMD3<Float>)
        case react(nodeId: UUID, type: MascotBehavior.ReactionKind)
        case patrol
        case idle

        private var priority: Int {
            switch self {
            case .create: return 4
            case .delete: return 3
            case .react: return 2
            case .patrol: return 1
            case .idle: return 0
            }
        }

        public static func < (lhs: MascotTask, rhs: MascotTask) -> Bool {
            lhs.priority < rhs.priority
        }
    }

    private let maxTaskQueueDepth = 8
    private let mascotScale: Float = 0.06
    private let patrolHoverDuration: Float = 8.0
    private let patrolSpeed: Float = 0.3

    private var cachedActiveProjects = Set<String>()
    private var cachedProjectsTopologyVersion: UInt64 = .max

    public convenience init() {
        self.init(loadMascot: { project, tint in await MascotEntityFactory.createMascotGroup(project: project, tint: tint) })
    }
    /// Same loading boundary, injectable by owned fixtures to hold a late asset completion.
    init(loadMascot: @escaping @MainActor (String, SIMD3<Float>) async -> Entity) { self.loadMascot = loadMascot }

    public func drainPendingLoads() async {
        while let (id, task) = inFlightLoads.first {
            await task.value
            inFlightLoads.removeValue(forKey: id)
        }
    }

    public func update(
        container: Entity,
        dataProvider: SceneDataProvider,
        dt: Float,
        scaleFactor: Float
    ) {
        guard isActive, !isTornDown else { return }
        let colorMap = dataProvider.projectColorMap
        let positions = dataProvider.positions
        let nodes = dataProvider.nodes

        // Determine which projects need mascots (projects with nodes).
        // Cached on topologyVersion — the inline set-build over every node
        // cost ~33ms/frame at 40k nodes.
        if dataProvider.topologyVersion != cachedProjectsTopologyVersion {
            var projects = Set<String>()
            for node in nodes { projects.insert(node.project) }
            cachedActiveProjects = projects
            cachedProjectsTopologyVersion = dataProvider.topologyVersion
        }
        let activeProjects = cachedActiveProjects

        for project in loadingTasks.keys where !activeProjects.contains(project) {
            loadingTasks.removeValue(forKey: project)?.cancel()
            mascotLoadingProjects.remove(project)
        }

        // Remove mascots for gone projects
        for (project, entity) in activeMascots where !activeProjects.contains(project) {
            entity.removeFromParent()
        }
        for project in activeMascots.keys where !activeProjects.contains(project) {
            activeMascots.removeValue(forKey: project)
            mascotStates.removeValue(forKey: project)
            taskQueues.removeValue(forKey: project)
            idleTimers.removeValue(forKey: project)
            lastHoloNodeIds.removeValue(forKey: project)
        }

        // Create mascots for new projects
        for project in activeProjects where activeMascots[project] == nil && !mascotLoadingProjects.contains(project) {
            let tint = colorMap[project] ?? SIMD3<Float>(0, 0.8, 1.0)
            mascotLoadingProjects.insert(project)
            let proj = project
            let generation = lifecycleGeneration
            let centroid = dataProvider.projectCentroids[proj]
            let load = loadMascot
            let loadID = UUID()
            let task = Task { @MainActor [weak self] in
                defer { self?.inFlightLoads.removeValue(forKey: loadID) }
                guard !Task.isCancelled else { return }
                let entity = await load(proj, tint)
                guard let self, !Task.isCancelled, self.isActive, !self.isTornDown,
                      self.lifecycleGeneration == generation,
                      self.cachedActiveProjects.contains(proj) else { return }
                self.loadingTasks.removeValue(forKey: proj)
                container.addChild(entity)
                self.activeMascots[proj] = entity
                self.mascotStates[proj] = .idle(.awake)
                self.idleTimers[proj] = 0
                self.patrolThresholds[proj] = Float.random(in: 12...30)
                self.animationTimes[proj] = 0
                self.mascotLoadingProjects.remove(proj)

                // Initial position near project centroid
                if let centroid {
                    self.currentPositions[proj] = centroid + SIMD3(0, 50, 0)
                    entity.position = (centroid + SIMD3(0, 50, 0)) * scaleFactor
                }
            }
            loadingTasks[proj] = task; inFlightLoads[loadID] = task
        }

        // Update each active mascot
        for (project, entity) in activeMascots {
            let state = mascotStates[project] ?? .idle(.awake)
            let time = (animationTimes[project] ?? 0) + dt
            animationTimes[project] = time

            // Tick state machine
            let newState = tickStateMachine(
                project: project,
                state: state,
                dt: dt,
                nodes: nodes,
                positions: positions,
                scaleFactor: scaleFactor
            )
            mascotStates[project] = newState

            // Compute joint angles from state
            let angles = computeJointAngles(state: newState, time: time)

            // Update entity transform
            if let pos = currentPositions[project] {
                entity.position = pos * scaleFactor
            }
            let yaw = currentYaws[project] ?? 0
            entity.orientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))

            // Update MascotComponent
            var comp = entity.components[MascotComponent.self] ?? MascotComponent(project: project)
            comp.state = newState
            comp.jointAngles = angles
            comp.animationTime = time
            comp.yaw = yaw
            if let pos = currentPositions[project] { comp.position = pos }
            entity.components.set(comp)

            // Toggle child effects + update holo texture
            updateEffectVisibility(entity: entity, state: newState, dt: dt, project: project, nodes: nodes)
        }
    }

    // MARK: - State Machine

    private func tickStateMachine(
        project: String,
        state: MascotBehavior,
        dt: Float,
        nodes: [RKNodeSnapshot],
        positions: [UUID: SIMD3<Float>],
        scaleFactor: Float
    ) -> MascotBehavior {
        switch state {
        case .idle(let sub):
            let timer = (idleTimers[project] ?? 0) + dt
            idleTimers[project] = timer
            let threshold = patrolThresholds[project] ?? 20

            if timer > threshold {
                // Pick a random node in this project to patrol to
                let projectNodes = nodes.filter { $0.project == project }
                if let target = projectNodes.randomElement(),
                   let pos = positions[target.id] {
                    idleTimers[project] = 0
                    patrolThresholds[project] = Float.random(in: 12...30)
                    return .patrol(targetId: target.id, targetPos: pos)
                }
            }

            // Idle sub-state transitions
            if timer > 60 && sub == .awake {
                return .idle(.drowsy)
            } else if timer > 120 && sub == .drowsy {
                return .idle(.sleeping)
            }

            return state

        case .patrol(let targetId, let targetPos):
            guard let currentPos = currentPositions[project] else { return .idle(.awake) }

            let dir = targetPos - currentPos
            let dist = simd_length(dir)

            let stopDist: Float = 25.0  // hover near, not on top of the node
            if dist < stopDist {
                // Arrived — start hovering, offset from node
                if dist > 1.0 {
                    let offsetDir = simd_normalize(currentPos - targetPos)
                    currentPositions[project] = targetPos + offsetDir * stopDist
                }
                return .hover(nodeId: targetId, timer: 0)
            }

            // Move toward target
            let moveDir = dir / max(dist, 0.001)
            let moveAmount = patrolSpeed * dt * 200  // scale for world units
            currentPositions[project] = currentPos + moveDir * min(moveAmount, dist - stopDist * 0.8)

            // Yaw toward target
            let targetYaw = atan2(moveDir.x, moveDir.z)
            let currentYaw = currentYaws[project] ?? 0
            currentYaws[project] = currentYaw + (targetYaw - currentYaw) * min(1.0, dt * 3.0)

            return state

        case .hover(let nodeId, let timer):
            let newTimer = timer + dt
            if newTimer > patrolHoverDuration {
                return .idle(.awake)
            }
            return .hover(nodeId: nodeId, timer: newTimer)

        case .conjure(let nodeId, let phase):
            let newPhase = phase + dt
            if newPhase > 3.0 { return .idle(.awake) }
            return .conjure(nodeId: nodeId, phase: newPhase)

        case .absorb(let nodeId, let phase):
            let newPhase = phase + dt
            if newPhase > 2.0 { return .idle(.awake) }
            return .absorb(nodeId: nodeId, phase: newPhase)

        case .react(let nodeId, let kind):
            return .idle(.awake)  // Reactions are instant

        case .chatting:
            return state  // Stay chatting until externally changed
        }
    }

    // MARK: - Joint Angles

    private func computeJointAngles(state: MascotBehavior, time: Float) -> MascotJointAngles {
        var angles = MascotJointAngles()

        switch state {
        case .idle(let sub):
            // Gentle bob + yaw oscillation
            angles.bodyBob = sin(time * 1.2) * 0.02
            switch sub {
            case .awake:
                angles.eyePulse = 0.5 + 0.5 * sin(time * 0.8)
            case .drowsy:
                angles.eyePulse = 0.3 + 0.2 * sin(time * 0.4)
                angles.bodyBob *= 0.5
            case .sleeping:
                angles.eyePulse = 0.1
                angles.bodyBob = sin(time * 0.6) * 0.01
            }
            angles.bottomThruster = 0.3 + 0.1 * sin(time * 2.0)

        case .patrol:
            // Arm swing proportional to movement
            angles.leftArmPitch = sin(time * 3.0) * 0.4
            angles.rightArmPitch = -sin(time * 3.0) * 0.4
            angles.bodyBob = sin(time * 2.0) * 0.01
            angles.eyePulse = 0.7
            angles.bottomThruster = 0.8

        case .hover:
            // Arms raise to inspection angle
            angles.leftArmPitch = 0.8
            angles.rightArmPitch = 0.8
            angles.bodyBob = sin(time * 1.5) * 0.015
            angles.eyePulse = 0.9
            angles.bottomThruster = 0.4

        case .conjure(_, let phase):
            // Arms raise higher, eye glow intensifies
            let progress = min(phase / 2.0, 1.0)
            angles.leftArmPitch = 1.0 + progress * 0.3
            angles.rightArmPitch = 1.0 + progress * 0.3
            angles.bodyBob = sin(time * 2.0) * 0.02
            angles.eyePulse = 1.0
            angles.bottomThruster = 0.6 + progress * 0.4

        case .absorb(_, let phase):
            let progress = min(phase / 1.5, 1.0)
            angles.leftArmPitch = 0.5 - progress * 0.5
            angles.rightArmPitch = 0.5 - progress * 0.5
            angles.eyePulse = 1.0 - progress * 0.3
            angles.bottomThruster = 0.5

        case .react:
            angles.leftArmPitch = 0.3
            angles.rightArmPitch = 0.3
            angles.eyePulse = 1.0
            angles.bottomThruster = 0.5

        case .chatting:
            angles.bodyBob = sin(time * 1.0) * 0.02
            angles.leftArmPitch = 0.2 + sin(time * 1.5) * 0.1
            angles.rightArmPitch = 0.2 - sin(time * 1.5) * 0.1
            angles.eyePulse = 0.8
            angles.bottomThruster = 0.3
        }

        return angles
    }

    // MARK: - Effect Visibility

    private func updateEffectVisibility(entity: Entity, state: MascotBehavior, dt: Float, project: String, nodes: [RKNodeSnapshot]) {
        let wantsArcane: Bool
        let wantsOrb: Bool
        let wantsHolo: Bool
        var hoverNodeId: UUID?
        var hoverTimer: Float = 0

        switch state {
        case .hover(let nodeId, let timer):
            wantsArcane = true
            wantsOrb = false
            wantsHolo = true
            hoverNodeId = nodeId
            hoverTimer = timer
        case .chatting:
            wantsArcane = true
            wantsOrb = false
            wantsHolo = true
        case .conjure(let nodeId, _):
            wantsArcane = true
            wantsOrb = true
            wantsHolo = true
            hoverNodeId = nodeId
        default:
            wantsArcane = false
            wantsOrb = false
            wantsHolo = false
        }

        // Holo fade: delay 1.5s, then fade in over 0.4s; fade out over 0.25s
        let holoDelay: Float = 1.5
        let timeUntilDepart = patrolHoverDuration - hoverTimer
        let holoReady = wantsHolo && hoverTimer >= holoDelay && timeUntilDepart > 1.0
        let currentOpacity = holoOpacities[project] ?? 0
        let targetOpacity: Float = holoReady ? 1.0 : 0.0
        let fadeSpeed: Float = holoReady ? 2.5 : 4.0
        let newOpacity = currentOpacity + (targetOpacity - currentOpacity) * min(dt * fadeSpeed, 1.0)
        holoOpacities[project] = newOpacity

        // Find child entities by name
        for child in entity.children {
            switch child.name {
            case "ArcaneCircle": child.isEnabled = wantsArcane
            case "ConjureOrb": child.isEnabled = wantsOrb
            case "HoloScreen":
                let holoVisible = newOpacity > 0.01
                child.isEnabled = holoVisible
                if let modelEntity = child as? ModelEntity {
                    // Render texture when hovering at a new node
                    if let nodeId = hoverNodeId {
                        updateHoloTexture(entity: modelEntity, nodeId: nodeId, nodes: nodes, project: project)
                    }
                    // Apply fade opacity
                    if holoVisible {
                        updateHoloOpacity(entity: modelEntity, opacity: newOpacity)
                    }
                }
            default: break
            }
        }
    }

    // MARK: - Holo Texture

    /// Last node ID the holo texture was rendered for, per project.
    private var lastHoloNodeIds: [String: UUID] = [:]
    /// Current holo screen opacity per project (0–1), for fade in/out.
    private var holoOpacities: [String: Float] = [:]

    private func updateHoloOpacity(entity: ModelEntity, opacity: Float) {
        guard var mat = entity.model?.materials.first as? UnlitMaterial else { return }
        mat.blending = .transparent(opacity: .init(floatLiteral: opacity))
        entity.model?.materials = [mat]
    }

    private func updateHoloTexture(entity: ModelEntity, nodeId: UUID, nodes: [RKNodeSnapshot], project: String) {
        // Only regenerate when visiting a new node
        if lastHoloNodeIds[project] == nodeId { return }
        lastHoloNodeIds[project] = nodeId

        guard let node = nodes.first(where: { $0.id == nodeId }) else { return }

        let info = HoloTextureRenderer.NodeInfo(
            content: node.content,
            project: node.project,
            topic: node.topic,
            importance: node.importance,
            createdAt: node.createdAt,
            lastAccessedAt: node.lastAccessedAt
        )

        guard let cgImage = HoloTextureRenderer.render(info: info) else { return }

        do {
            let texResource = try TextureResource(image: cgImage, options: .init(semantic: .color))
            var mat = UnlitMaterial()
            mat.color = .init(tint: .white, texture: .init(texResource))
            mat.blending = .transparent(opacity: .init(floatLiteral: 1.0))
            mat.faceCulling = .none
            entity.model?.materials = [mat]
        } catch {
            // Texture generation failed — leave existing material
        }
    }

    /// Enqueue a task for a project's mascot.
    public func enqueueTask(_ task: MascotTask, for project: String) {
        var queue = taskQueues[project] ?? []
        queue.append(task)
        queue.sort(by: >)
        if queue.count > maxTaskQueueDepth {
            queue = Array(queue.prefix(maxTaskQueueDepth))
        }
        taskQueues[project] = queue
    }
}

// MARK: - MascotBehavior helpers

extension MascotBehavior {
    var isConjuring: Bool {
        if case .conjure = self { return true }
        return false
    }
}
