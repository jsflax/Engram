import simd
import GameController
import os
import EngramSceneKit

private let cameraLog = Logger(subsystem: "io.engram.app", category: "CameraController")

/// Orbit camera with smooth lerping, keyboard/gamepad input, hit testing, and teleport.
/// Pure state + math — no platform UI dependencies. Input events are fed in by RKInputBridge.
@Observable
@MainActor
public final class CameraController: CameraProvider {

    public init() {}

    public var cameraState: CameraState { state }
    public var isHeadTracked: Bool { false }

    // Target state (written by gestures/events)
    public var targetAzimuth: Float = 0
    public var targetElevation: Float = 0.3
    public var targetCameraPos: SIMD3<Float> = .zero

    // Smoothed state (lerped each frame, used for rendering)
    @ObservationIgnored public private(set) var azimuth: Float = 0
    @ObservationIgnored public private(set) var elevation: Float = 0.3
    @ObservationIgnored public private(set) var cameraTarget: SIMD3<Float> = .zero

    // Spawn WELL outside the universe: centerOnGraph refines this once data
    // loads, but it used to default to 2.0 — and because the one-shot
    // center call ran before any async load, its empty-positions guard left
    // the camera parked ON the origin for the whole session.
    public var orbitRadius: Float = 4800
    private let smoothing: Float = 0.2
    public var isDragging = false

    public let scaleFactor: Float = 1.0 / 200.0
    public let fovDegrees: Float = 60

    // MARK: - CameraState snapshot

    public var state: CameraState {
        CameraState(
            azimuth: azimuth, elevation: elevation,
            cameraTarget: cameraTarget, orbitRadius: orbitRadius,
            scaleFactor: scaleFactor, fovDegrees: fovDegrees
        )
    }

    // MARK: - Computed Properties

    public var cameraPosition: SIMD3<Float> { state.cameraPosition }
    public var forward: SIMD3<Float> { state.forward }
    public var right: SIMD3<Float> { state.right }
    public var up: SIMD3<Float> { state.up }

    // MARK: - View / Projection Matrices

    public func viewMatrix() -> simd_float4x4 { state.viewMatrix() }
    public func projectionMatrix(aspect: Float) -> simd_float4x4 { state.projectionMatrix(aspect: aspect) }

    // MARK: - Camera Movement

    public func pan(dx: Float, dy: Float) {
        let speed: Float = 1.5
        let offset = -right * dx * speed + up * dy * speed
        targetCameraPos += offset
    }

    public func dolly(amount: Float, cursorNX: Float = 0, cursorNY: Float = 0) {
        let fovTan: Float = tan(Float.pi / 6)
        let dir = normalize(forward + right * cursorNX * fovTan + up * cursorNY * fovTan)
        targetCameraPos += dir * amount
    }

    public func lookRotate(deltaAz: Float, deltaEl: Float) {
        // Snap smoothed state so the camera world-position stays fixed during rotation.
        // Without this, independent lerping of angles and position causes a visible pullback.
        let oldOffset = orbitOffset(azimuth: targetAzimuth, elevation: targetElevation)
        let camPos = targetCameraPos + oldOffset

        targetAzimuth += deltaAz
        targetElevation = max(-.pi/2 + 0.1, min(.pi/2 - 0.1, targetElevation + deltaEl))

        let newOffset = orbitOffset(azimuth: targetAzimuth, elevation: targetElevation)
        targetCameraPos = camPos - newOffset

        // Snap smoothed values to target so lerp doesn't fight the coupled update
        azimuth = targetAzimuth
        elevation = targetElevation
        cameraTarget = targetCameraPos
    }

    public func captureLookState() -> (azimuth: Float, elevation: Float, camPos: SIMD3<Float>) {
        isDragging = true
        let az = targetAzimuth
        let el = targetElevation
        let offset = orbitOffset(azimuth: az, elevation: el)
        return (azimuth: az, elevation: el, camPos: targetCameraPos + offset)
    }

    public func endDrag() {
        isDragging = false
    }

    /// Restore one bounded presentation state without a visible interpolation from old values.
    /// Scale/FOV remain owned by this controller, rather than supplied by a saved payload.
    @discardableResult
    public func restore(azimuth: Float, elevation: Float, target: SIMD3<Float>, radius: Float) -> Bool {
        guard azimuth.isFinite, abs(azimuth) <= 1_000_000,
              elevation.isFinite, abs(elevation) <= .pi / 2 - 0.1,
              radius.isFinite, (1...10_000_000).contains(radius),
              [target.x, target.y, target.z].allSatisfy({ $0.isFinite && abs($0) <= 2_000_000 }) else { return false }
        targetAzimuth = azimuth; self.azimuth = azimuth
        targetElevation = elevation; self.elevation = elevation
        targetCameraPos = target; cameraTarget = target; orbitRadius = radius
        heldKeys.removeAll(); isDragging = false
        return true
    }

    public func applyLookDrag(start: (azimuth: Float, elevation: Float, camPos: SIMD3<Float>),
                              dx: Float, dy: Float) {
        let newAz = start.azimuth + dx
        let newEl = max(-.pi/2 + 0.1, min(.pi/2 - 0.1, start.elevation + dy))
        let offset = orbitOffset(azimuth: newAz, elevation: newEl)
        let newTarget = start.camPos - offset
        targetAzimuth = newAz
        targetElevation = newEl
        targetCameraPos = newTarget
    }

    private func orbitOffset(azimuth az: Float, elevation el: Float) -> SIMD3<Float> {
        SIMD3(orbitRadius * cos(el) * sin(az),
              orbitRadius * sin(el),
              orbitRadius * cos(el) * cos(az))
    }

    public func cameraDistance(to point: SIMD3<Float>) -> Float {
        simd_length(point - cameraPosition)
    }

    // MARK: - Camera Update (per frame)

    public func updateCamera(dt: Float) {
        let targetDt: Float = 1.0 / 60.0
        let s: Float = isDragging ? 1.0 : smoothing
        let factor = 1.0 - pow(1.0 - s, dt / targetDt)
        let newAz = azimuth + (targetAzimuth - azimuth) * factor
        let newEl = elevation + (targetElevation - elevation) * factor
        let newTarget = cameraTarget + (targetCameraPos - cameraTarget) * factor
        let threshold: Float = 0.0001
        if abs(newAz - azimuth) > threshold { azimuth = newAz }
        else if azimuth != targetAzimuth { azimuth = targetAzimuth }
        if abs(newEl - elevation) > threshold { elevation = newEl }
        else if elevation != targetElevation { elevation = targetElevation }
        if simd_length(newTarget - cameraTarget) > threshold { cameraTarget = newTarget }
        else if cameraTarget != targetCameraPos { cameraTarget = targetCameraPos }
    }

    public func centerOnGraph(positions: [UUID: SIMD3<Float>]) {
        guard !positions.isEmpty else { return }
        var sum = SIMD3<Float>.zero
        for (_, pos) in positions { sum += pos }
        let centroid = sum / Float(positions.count)

        var maxDist: Float = 0
        for (_, pos) in positions {
            maxDist = max(maxDist, simd_length(pos - centroid))
        }
        // Everything in world space — CameraSystem applies scaleFactor when
        // syncing to RK entity. Floor raised from 800: with group galaxies
        // stacked at levelSpacing=3000 the scene spans thousands of units,
        // and the opening shot should read the whole sky (which also puts
        // every galaxy past the nebula far-LOD threshold — you arrive to
        // single-color masses and fly in to resolve them).
        orbitRadius = max(maxDist * 3.5, 4200)
        targetCameraPos = centroid
        cameraTarget = centroid
    }

    public var isMoving: Bool {
        abs(targetAzimuth - azimuth) > 0.0001
            || abs(targetElevation - elevation) > 0.0001
            || simd_length(targetCameraPos - cameraTarget) > 0.01
    }

    // MARK: - Projection / Hit Testing

    public func project(point3D: SIMD3<Float>, viewSize: CGSize) -> CGPoint? {
        let camPos = cameraPosition * scaleFactor
        let pointScaled = point3D * scaleFactor
        let toPoint = pointScaled - camPos
        let fwd = forward
        let rt = right
        let u = up
        let depth = dot(toPoint, fwd)
        guard depth > 0.01 * scaleFactor else { return nil }
        let projX = dot(toPoint, rt) / depth
        let projY = dot(toPoint, u) / depth
        let fovTan = tan(Float.pi / 6)
        let aspect = Float(viewSize.width / viewSize.height)
        let screenX = CGFloat((projX / (fovTan * aspect) * 0.5 + 0.5)) * viewSize.width
        let screenY = CGFloat((0.5 - projY / fovTan * 0.5)) * viewSize.height
        return CGPoint(x: screenX, y: screenY)
    }

    public func hitTest(at location: CGPoint, viewSize: CGSize, positions: [UUID: SIMD3<Float>],
                        currentTarget: UUID? = nil) -> UUID? {
        var closest: UUID?
        var closestDist: CGFloat = 30
        for (id, pos) in positions {
            guard let screenPos = project(point3D: pos, viewSize: viewSize) else { continue }
            let dist = hypot(location.x - screenPos.x, location.y - screenPos.y)
            if dist < closestDist { closestDist = dist; closest = id }
        }
        if closest == nil, let current = currentTarget,
           let pos = positions[current],
           let screenPos = project(point3D: pos, viewSize: viewSize) {
            if hypot(location.x - screenPos.x, location.y - screenPos.y) < 45 { return current }
        }
        return closest
    }

    // MARK: - Keyboard Input

    public var heldKeys: Set<String> = []

    public func pollKeyboard(dt: Float) {
        guard !heldKeys.isEmpty else { return }
        let sprint: Float = heldKeys.contains("shift") ? 3.0 : 1.0
        let moveSpeed: Float = 200 * dt * sprint
        let strafeSpeed: Float = 300 * dt * sprint
        let vertSpeed: Float = 300 * dt * sprint
        let lookSpeed: Float = 2.0 * dt

        if heldKeys.contains("w") { dolly(amount: moveSpeed) }
        if heldKeys.contains("s") { dolly(amount: -moveSpeed) }
        if heldKeys.contains("a") { pan(dx: strafeSpeed, dy: 0) }
        if heldKeys.contains("d") { pan(dx: -strafeSpeed, dy: 0) }
        if heldKeys.contains("e") { pan(dx: 0, dy: vertSpeed) }
        if heldKeys.contains("q") { pan(dx: 0, dy: -vertSpeed) }
        if heldKeys.contains("i") { lookRotate(deltaAz: 0, deltaEl: lookSpeed) }
        if heldKeys.contains("k") { lookRotate(deltaAz: 0, deltaEl: -lookSpeed) }
        if heldKeys.contains("j") { lookRotate(deltaAz: lookSpeed, deltaEl: 0) }
        if heldKeys.contains("l") { lookRotate(deltaAz: -lookSpeed, deltaEl: 0) }
    }

    // MARK: - Teleport

    public var teleportProjectIndex = 0
    public var teleportCounter: Int = 0
    public var teleportLabel: String?

    public func teleportToNextProject(positions: [UUID: SIMD3<Float>], nodes: [RKNodeSnapshot],
                                      hubs: Set<UUID>, direction: Int = 1) {
        var projectNodeIds: [String: [UUID]] = [:]
        var projectPositions: [String: [SIMD3<Float>]] = [:]
        let nodeById = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for (id, pos) in positions {
            guard let node = nodeById[id] else { continue }
            projectNodeIds[node.project, default: []].append(id)
            projectPositions[node.project, default: []].append(pos)
        }
        let projects = projectPositions.keys.sorted()
        guard !projects.isEmpty else { return }

        teleportProjectIndex = (teleportProjectIndex + direction + projects.count) % projects.count
        let project = projects[teleportProjectIndex]
        let pts = projectPositions[project]!
        let nodeIds = projectNodeIds[project]!
        let hubId = nodeIds.first(where: { hubs.contains($0) })

        let targetPos: SIMD3<Float>
        if let hubId, let pos = positions[hubId] { targetPos = pos }
        else {
            var sum = SIMD3<Float>.zero
            for p in pts { sum += p }
            targetPos = sum / Float(pts.count)
        }

        var maxSpread: Float = 0
        for p in pts { maxSpread = max(maxSpread, simd_length(p - targetPos)) }
        orbitRadius = max(min(maxSpread * 0.4, 250), 60)
        targetCameraPos = targetPos
        cameraTarget = targetPos
        teleportCounter += 1
        teleportLabel = project
    }

    public func driveToProject(_ project: String, positions: [UUID: SIMD3<Float>],
                               nodes: [RKNodeSnapshot], hubs: Set<UUID>) {
        let nodeById = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var pts: [SIMD3<Float>] = []
        var nodeIds: [UUID] = []
        for (id, pos) in positions {
            guard let node = nodeById[id], node.project == project else { continue }
            pts.append(pos)
            nodeIds.append(id)
        }
        guard !pts.isEmpty else { return }

        let hubId = nodeIds.first(where: { hubs.contains($0) })
        let targetPos: SIMD3<Float>
        if let hubId, let pos = positions[hubId] { targetPos = pos }
        else {
            var sum = SIMD3<Float>.zero
            for p in pts { sum += p }
            targetPos = sum / Float(pts.count)
        }

        var maxSpread: Float = 0
        for p in pts { maxSpread = max(maxSpread, simd_length(p - targetPos)) }
        orbitRadius = max(min(maxSpread * 0.4, 250), 60)
        targetCameraPos = targetPos
        teleportCounter += 1
        teleportLabel = project
    }

    public func teleportToGalaxy(center: SIMD3<Float>, radius: Float, label: String) {
        orbitRadius = max(radius, 60)
        targetCameraPos = center
        cameraTarget = center
        teleportCounter += 1
        teleportLabel = label
    }
}
