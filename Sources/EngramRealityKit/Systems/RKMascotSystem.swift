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
    private struct Effects {
        let arcaneCircle: Entity?
        let conjureOrb: Entity?
        let holoScreen: ModelEntity?
    }
    private var effects: [String: Effects] = [:]
    private let graphIndex = MascotGraphIndex()
    private let holoRequestCache = MascotHoloRequestCache()
    private var holoTasks: [String: Task<Void, Never>] = [:]
    private var preparedHoloImages: [String: (key: MascotHoloKey, image: CGImage)] = [:]
    private var appliedHoloOpacities: [String: Float] = [:]

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

    public init() {}

    public func update(
        container: Entity,
        dataProvider: SceneDataProvider,
        dt: Float,
        scaleFactor: Float
    ) {
        let colorMap = dataProvider.projectColorMap
        let nodes = dataProvider.nodes

        // Determine which projects need mascots (projects with nodes).
        // Cached on topologyVersion — the inline set-build over every node
        // cost ~33ms/frame at 40k nodes.
        graphIndex.update(nodes: nodes, topologyVersion: dataProvider.topologyVersion, provider: dataProvider)
        let activeProjects = graphIndex.projects

        // Remove mascots for gone projects
        for (project, entity) in activeMascots where !activeProjects.contains(project) {
            entity.removeFromParent()
        }
        for project in activeMascots.keys where !activeProjects.contains(project) {
            activeMascots.removeValue(forKey: project)
            mascotStates.removeValue(forKey: project)
            taskQueues.removeValue(forKey: project)
            idleTimers.removeValue(forKey: project)
            patrolThresholds.removeValue(forKey: project)
            animationTimes.removeValue(forKey: project)
            currentPositions.removeValue(forKey: project)
            currentYaws.removeValue(forKey: project)
            effects.removeValue(forKey: project)
            holoTasks.removeValue(forKey: project)?.cancel()
            preparedHoloImages.removeValue(forKey: project)
            holoRequestCache.remove(project)
            holoOpacities.removeValue(forKey: project)
            appliedHoloOpacities.removeValue(forKey: project)
        }

        // Create mascots for new projects
        for project in activeProjects where activeMascots[project] == nil && !mascotLoadingProjects.contains(project) {
            let tint = colorMap[project] ?? SIMD3<Float>(0, 0.8, 1.0)
            mascotLoadingProjects.insert(project)
            let proj = project
            Task { @MainActor [weak self] in
                guard let self else { return }
                let entity = await MascotEntityFactory.createMascotGroup(project: proj, tint: tint)
                self.mascotLoadingProjects.remove(proj)
                guard self.graphIndex.projects.contains(proj), self.activeMascots[proj] == nil else { return }
                container.addChild(entity)
                self.activeMascots[proj] = entity
                self.mascotStates[proj] = .idle(.awake)
                self.idleTimers[proj] = 0
                self.patrolThresholds[proj] = Float.random(in: 12...30)
                self.animationTimes[proj] = 0
                self.effects[proj] = Effects(
                    arcaneCircle: entity.children.first { $0.name == "ArcaneCircle" },
                    conjureOrb: entity.children.first { $0.name == "ConjureOrb" },
                    holoScreen: entity.children.first { $0.name == "HoloScreen" } as? ModelEntity
                )

                // Initial position near project centroid
                if let centroid = dataProvider.projectCentroids[proj] {
                    self.currentPositions[proj] = centroid + SIMD3(0, 50, 0)
                    entity.position = (centroid + SIMD3(0, 50, 0)) * scaleFactor
                }
            }
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
                positionAtIndex: { index in
                    let flat = dataProvider.positionArray
                    if flat.count == nodes.count { return flat[index] }
                    return dataProvider.positions[nodes[index].id]
                }
            )
            mascotStates[project] = newState

            // Compute joint angles from state
            let angles = computeJointAngles(state: newState, time: time)

            // Update entity transform
            if let pos = currentPositions[project] {
                let scaled = pos * scaleFactor
                if entity.position != scaled { entity.position = scaled }
            }
            let yaw = currentYaws[project] ?? 0
            let orientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
            if entity.orientation.vector != orientation.vector { entity.orientation = orientation }

            // Update MascotComponent
            var comp = entity.components[MascotComponent.self] ?? MascotComponent(project: project)
            comp.state = newState
            comp.jointAngles = angles
            comp.animationTime = time
            comp.yaw = yaw
            if let pos = currentPositions[project] { comp.position = pos }
            entity.components.set(comp)

            // Toggle child effects + update holo texture
            // Prewarm during travel, before the existing 1.5-second hover delay.
            // Texture replacement stays asynchronous and does not alter visibility.
            if case .patrol(let nodeId, _) = newState, let holo = effects[project]?.holoScreen {
                updateHoloTexture(entity: holo, nodeId: nodeId, nodes: nodes, project: project)
            }
            updateEffectVisibility(state: newState, dt: dt, project: project, nodes: nodes)
        }
    }

    // MARK: - State Machine

    private func tickStateMachine(
        project: String,
        state: MascotBehavior,
        dt: Float,
        nodes: [RKNodeSnapshot],
        positionAtIndex: (Int) -> SIMD3<Float>?
    ) -> MascotBehavior {
        switch state {
        case .idle(let sub):
            let timer = (idleTimers[project] ?? 0) + dt
            idleTimers[project] = timer
            let threshold = patrolThresholds[project] ?? 20

            if timer > threshold {
                // Pick a random node in this project to patrol to
                if let index = graphIndex.indicesByProject[project]?.randomElement(),
                   let pos = positionAtIndex(index) {
                    idleTimers[project] = 0
                    patrolThresholds[project] = Float.random(in: 12...30)
                    return .patrol(targetId: nodes[index].id, targetPos: pos)
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

    private func updateEffectVisibility(state: MascotBehavior, dt: Float, project: String, nodes: [RKNodeSnapshot]) {
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

        if let nodeId = hoverNodeId, let holo = effects[project]?.holoScreen {
            updateHoloTexture(entity: holo, nodeId: nodeId, nodes: nodes, project: project)
        }
        let textureReady = hoverNodeId.map { holoRequestCache.isReady(nodeID: $0, for: project) } ?? true

        // Holo fade: delay 1.5s, then fade in over 0.4s; fade out over 0.25s
        let holoDelay: Float = 1.5
        let timeUntilDepart = patrolHoverDuration - hoverTimer
        let holoReady = wantsHolo && textureReady && hoverTimer >= holoDelay && timeUntilDepart > 1.0
        let currentOpacity = holoOpacities[project] ?? 0
        let targetOpacity: Float = holoReady ? 1.0 : 0.0
        let fadeSpeed: Float = holoReady ? 2.5 : 4.0
        let newOpacity = currentOpacity + (targetOpacity - currentOpacity) * min(dt * fadeSpeed, 1.0)
        holoOpacities[project] = newOpacity

        if let circle = effects[project]?.arcaneCircle, circle.isEnabled != wantsArcane {
            circle.isEnabled = wantsArcane
        }
        if let orb = effects[project]?.conjureOrb, orb.isEnabled != wantsOrb {
            orb.isEnabled = wantsOrb
        }
        if let holo = effects[project]?.holoScreen {
            // A new target must never display the previous node's retained card
            // while its asynchronous replacement is still being prepared.
            let holoVisible = newOpacity > 0.01 && textureReady
            if holo.isEnabled != holoVisible { holo.isEnabled = holoVisible }
            if holoVisible, appliedHoloOpacities[project] != newOpacity {
                updateHoloOpacity(entity: holo, opacity: newOpacity)
                appliedHoloOpacities[project] = newOpacity
            }
        }
    }

    // MARK: - Holo Texture

    /// Current holo screen opacity per project (0–1), for fade in/out.
    private var holoOpacities: [String: Float] = [:]

    private func updateHoloOpacity(entity: ModelEntity, opacity: Float) {
        guard var mat = entity.model?.materials.first as? UnlitMaterial else { return }
        mat.blending = .transparent(opacity: .init(floatLiteral: opacity))
        entity.model?.materials = [mat]
    }

    private func updateHoloTexture(entity: ModelEntity, nodeId: UUID, nodes: [RKNodeSnapshot], project: String) {
        guard let index = graphIndex.indexByID[nodeId], index < nodes.count else {
            holoTasks.removeValue(forKey: project)?.cancel()
            preparedHoloImages.removeValue(forKey: project)
            holoRequestCache.remove(project)
            return
        }
        let node = nodes[index]

        let info = HoloTextureRenderer.NodeInfo(
            content: node.content,
            project: node.project,
            topic: node.topic,
            importance: node.importance,
            createdAt: node.createdAt,
            lastAccessedAt: node.lastAccessedAt
        )

        let key = MascotHoloKey(nodeID: nodeId, info: info)
        let token: UInt64
        switch holoRequestCache.request(key, for: project) {
        case .none: return
        case .cancel:
            holoTasks.removeValue(forKey: project)?.cancel()
            preparedHoloImages.removeValue(forKey: project)
            return
        case .render(let requestToken):
            token = requestToken
        }
        holoTasks.removeValue(forKey: project)?.cancel()
        let preparedImage = preparedHoloImages[project].flatMap { $0.key == key ? $0.image : nil }
        if preparedImage == nil { preparedHoloImages.removeValue(forKey: project) }
        holoTasks[project] = Task { @MainActor [weak self, weak entity] in
            // One pending task per project; canceled actor-queued requests exit
            // before rasterizing. Keep the last successful texture until ready.
            let raster = if let preparedImage { preparedImage }
                         else { await HoloTextureRenderer.shared.render(info: info) }
            guard let image = raster, !Task.isCancelled else {
                self?.finishFailedHoloRequest(token, project: project)
                return
            }
            guard let entity, self?.holoRequestCache.isCurrent(token, for: project) == true,
                  self?.effects[project]?.holoScreen === entity else { return }
            // Retain at most one prepared bitmap per project across a failed
            // texture upload, so the bounded retry does not rerasterize it.
            self?.preparedHoloImages[project] = (key, image)
            do {
                let texture = try await TextureResource(image: image, options: .init(semantic: .color))
                guard let self, !Task.isCancelled, self.holoRequestCache.isCurrent(token, for: project),
                      self.effects[project]?.holoScreen === entity else { return }
                guard entity.model != nil else {
                    self.finishFailedHoloRequest(token, project: project)
                    return
                }
                let opacity = self.holoOpacities[project] ?? 0
                var material = UnlitMaterial()
                material.color = .init(tint: .white, texture: .init(texture))
                material.blending = .transparent(opacity: .init(floatLiteral: opacity))
                material.faceCulling = .none
                entity.model?.materials = [material]
                self.appliedHoloOpacities[project] = opacity
                self.holoRequestCache.complete(token, for: project)
                self.holoTasks.removeValue(forKey: project)
                self.preparedHoloImages.removeValue(forKey: project)
            } catch {
                self?.finishFailedHoloRequest(token, project: project)
            }
        }
    }

    private func finishFailedHoloRequest(_ token: UInt64, project: String) {
        guard holoRequestCache.isCurrent(token, for: project) else { return }
        holoRequestCache.failed(token, for: project)
        holoTasks.removeValue(forKey: project)
    }

    deinit {
        for task in holoTasks.values { task.cancel() }
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
