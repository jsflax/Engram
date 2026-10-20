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

    /// A world-attached annotation with an upper bound on its screen-space size.
    /// Embedded hosts may include these when fitting; ordinary camera input and
    /// legacy desktop callers never carry or constrain annotation positions.
    public struct FramingBillboard: Sendable {
        public let anchor: SIMD3<Float>
        public let maximumPointSize: CGSize
        public init(anchor: SIMD3<Float>, maximumPointSize: CGSize) {
            self.anchor = anchor; self.maximumPointSize = maximumPointSize
        }
    }

    /// Embedded hosts can relinquish automatic framing before input changes the camera.
    /// Nil preserves the existing desktop input behavior.
    @ObservationIgnored public var onUserInteraction: (() -> Void)?

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
    // Only embedded initial fitting sets this target. Legacy/manual camera moves
    // retain their existing behavior; no additional frame source is created.
    @ObservationIgnored private var automaticFitRadius: Float?
    public var isAutomaticallyFraming: Bool { automaticFitRadius != nil }
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
        onUserInteraction?()
        let speed: Float = 1.5
        let offset = -right * dx * speed + up * dy * speed
        targetCameraPos += offset
    }

    public func dolly(amount: Float, cursorNX: Float = 0, cursorNY: Float = 0) {
        onUserInteraction?()
        let fovTan: Float = tan(Float.pi / 6)
        let dir = normalize(forward + right * cursorNX * fovTan + up * cursorNY * fovTan)
        targetCameraPos += dir * amount
    }

    public func lookRotate(deltaAz: Float, deltaEl: Float) {
        onUserInteraction?()
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
        onUserInteraction?()
        isDragging = true
        let az = targetAzimuth
        let el = targetElevation
        let offset = orbitOffset(azimuth: az, elevation: el)
        return (azimuth: az, elevation: el, camPos: targetCameraPos + offset)
    }

    public func endDrag() {
        isDragging = false
    }

    public func applyLookDrag(start: (azimuth: Float, elevation: Float, camPos: SIMD3<Float>),
                              dx: Float, dy: Float) {
        onUserInteraction?()
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
        // A delayed frame must not turn an automatic transition back into a snap.
        // Clamp only this optional fit; native user/legacy movement is unchanged.
        let fitFactor = automaticFitRadius == nil ? factor : min(factor, 0.36)
        var newTarget = cameraTarget + (targetCameraPos - cameraTarget) * fitFactor
        if let radius = automaticFitRadius {
            let next = orbitRadius + (radius - orbitRadius) * fitFactor
            if abs(next - radius) <= max(0.0001, abs(radius) * 0.000001),
               simd_length(newTarget - targetCameraPos) <= max(0.0001, abs(radius) * 0.000001) {
                orbitRadius = radius
                newTarget = targetCameraPos
                automaticFitRadius = nil
            } else { orbitRadius = next }
        }
        let threshold: Float = 0.0001
        if abs(newAz - azimuth) > threshold { azimuth = newAz }
        else if azimuth != targetAzimuth { azimuth = targetAzimuth }
        if abs(newEl - elevation) > threshold { elevation = newEl }
        else if elevation != targetElevation { elevation = targetElevation }
        if simd_length(newTarget - cameraTarget) > threshold { cameraTarget = newTarget }
        else if cameraTarget != targetCameraPos { cameraTarget = targetCameraPos }
    }

    /// Withdraw only an automatic transition at the currently rendered camera.
    /// Call before applying user intent so no queued fit moves it afterward.
    public func cancelAutomaticFraming() {
        guard automaticFitRadius != nil else { return }
        automaticFitRadius = nil
        targetCameraPos = cameraTarget
    }

    public func centerOnGraph(positions: [UUID: SIMD3<Float>]) {
        // Keep the legacy whole-sky framing for existing desktop callers.
        centerOnGraph(positions: positions, minimumOrbitRadius: 4200, fitViewport: nil)
    }

    /// Fit an explicitly scoped graph to the limiting viewport field of view.
    /// A nil/invalid viewport retains the historical 3.5× bounding-radius fit.
    /// Distances use graph coordinates; CameraSystem applies scaleFactor later.
    public func centerOnGraph(positions: [UUID: SIMD3<Float>],
                              minimumOrbitRadius: Float, fitViewport: CGSize?) {
        guard !positions.isEmpty,
              minimumOrbitRadius.isFinite, minimumOrbitRadius > 0,
              positions.values.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return }
        var sum = SIMD3<Float>.zero
        for (_, pos) in positions { sum += pos }
        let centroid = sum / Float(positions.count)

        var maxDist: Float = 0
        for (_, pos) in positions {
            maxDist = max(maxDist, simd_length(pos - centroid))
        }
        centerOnGraph(center: centroid, radius: maxDist,
            minimumOrbitRadius: minimumOrbitRadius, fitViewport: fitViewport)
    }

    /// Fit existing aggregate bounds without materializing a node-position dictionary.
    /// A measured visible rectangle can exclude overlay controls while projection still
    /// uses the actual full canvas. Existing callers omit it and retain centered framing.
    public func centerOnGraph(center centroid: SIMD3<Float>, radius maxDist: Float,
                              minimumOrbitRadius: Float, fitViewport: CGSize?,
                              visibleRect: CGRect? = nil, animated: Bool = false,
                              billboards: [FramingBillboard] = []) {
        guard centroid.x.isFinite, centroid.y.isFinite, centroid.z.isFinite,
              maxDist.isFinite, maxDist >= 0,
              minimumOrbitRadius.isFinite, minimumOrbitRadius > 0 else { return }
        var fittedDistance = maxDist * 3.5
        var horizontalOffset: Float = 0
        var verticalOffset: Float = 0
        if let viewport = fitViewport,
           viewport.width.isFinite, viewport.height.isFinite,
           viewport.width > 0, viewport.height > 0 {
            let aspect = Float(viewport.width / viewport.height)
            let verticalHalfFOV = fovDegrees * .pi / 360
            let horizontalHalfFOV = atan(tan(verticalHalfFOV) * aspect)
            let limitingHalfFOV = min(verticalHalfFOV, horizontalHalfFOV)
            if limitingHalfFOV.isFinite, limitingHalfFOV > 0 {
                // A bounding sphere fits from this distance in any camera orientation.
                // Leave 20% space for labels and selection highlights around the centers.
                fittedDistance = maxDist / sin(limitingHalfFOV) * 1.2
            }
            if let visibleRect {
                guard visibleRect.origin.x.isFinite, visibleRect.origin.y.isFinite,
                      visibleRect.width.isFinite, visibleRect.height.isFinite,
                      visibleRect.minX >= 0, visibleRect.minY >= 0,
                      visibleRect.maxX <= viewport.width, visibleRect.maxY <= viewport.height,
                      visibleRect.width > 0, visibleRect.height > 0 else { return }
                let verticalTan = tan(verticalHalfFOV), horizontalTan = verticalTan * aspect
                let left = Float(2 * visibleRect.minX / viewport.width - 1) * horizontalTan
                let right = Float(2 * visibleRect.maxX / viewport.width - 1) * horizontalTan
                let bottom = Float(1 - 2 * visibleRect.maxY / viewport.height) * verticalTan
                let top = Float(1 - 2 * visibleRect.minY / viewport.height) * verticalTan
                let halfWidth = (right - left) / 2, halfHeight = (top - bottom) / 2
                guard halfWidth.isFinite, halfHeight.isFinite, halfWidth > 0, halfHeight > 0 else { return }
                // Distance to each off-axis frustum plane, not just the smaller
                // rectangle's FOV: the sphere must clear every measured boundary.
                let horizontalFit = max(sqrt(1 + left * left), sqrt(1 + right * right)) / halfWidth
                let verticalFit = max(sqrt(1 + bottom * bottom), sqrt(1 + top * top)) / halfHeight
                fittedDistance = maxDist * max(horizontalFit, verticalFit) * 1.2
                horizontalOffset = (left + right) / 2
                verticalOffset = (bottom + top) / 2
            }
        }
        if !billboards.isEmpty {
            guard let viewport = fitViewport,
                  viewport.width.isFinite, viewport.height.isFinite,
                  viewport.width > 0, viewport.height > 0 else { return }
            let visible = visibleRect ?? CGRect(origin: .zero, size: viewport)
            let verticalTan = tan(fovDegrees * .pi / 360)
            let horizontalTan = verticalTan * Float(viewport.width / viewport.height)
            fittedDistance = max(fittedDistance, minimumOrbitRadius)
            for billboard in billboards {
                let anchor = billboard.anchor, size = billboard.maximumPointSize
                guard anchor.x.isFinite, anchor.y.isFinite, anchor.z.isFinite,
                      size.width.isFinite, size.height.isFinite,
                      size.width > 0, size.height > 0 else { return }
                // Reserve the bounded glyph rectangle plus a two-point visual gap.
                // The inset uses actual overlay geometry, never a guessed toolbar height.
                let inset = visible.insetBy(dx: size.width / 2 + 2, dy: size.height / 2 + 2)
                guard !inset.isNull, inset.width > 0, inset.height > 0 else { return }
                let left = Float(2 * inset.minX / viewport.width - 1) * horizontalTan
                let rightPlane = Float(2 * inset.maxX / viewport.width - 1) * horizontalTan
                let bottom = Float(1 - 2 * inset.maxY / viewport.height) * verticalTan
                let top = Float(1 - 2 * inset.minY / viewport.height) * verticalTan
                let delta = anchor - centroid
                let x = simd_dot(delta, right), y = simd_dot(delta, up), z = simd_dot(delta, forward)
                // With the existing off-axis target, camera coordinates are
                // (x + horizontalOffset*d, y + verticalOffset*d, z + d).
                // Solve each frustum-plane inequality directly for distance d.
                let constraints: [(Float, Float)] = [
                    (left * z - x, horizontalOffset - left),
                    (x - rightPlane * z, rightPlane - horizontalOffset),
                    (bottom * z - y, verticalOffset - bottom),
                    (y - top * z, top - verticalOffset)
                ]
                for (numerator, denominator) in constraints {
                    guard numerator.isFinite, denominator.isFinite, denominator > 0 else { return }
                    let required = numerator / denominator
                    guard required.isFinite else { return }
                    fittedDistance = max(fittedDistance, required)
                }
                // The projection and glyph-size contracts require a front-facing anchor.
                fittedDistance = max(fittedDistance, 0.02 - z)
            }
        }
        guard centroid.x.isFinite, centroid.y.isFinite, centroid.z.isFinite,
              fittedDistance.isFinite else { return }
        let distance = max(fittedDistance, minimumOrbitRadius)
        let target = centroid - right * (horizontalOffset * distance) - up * (verticalOffset * distance)
        guard target.x.isFinite, target.y.isFinite, target.z.isFinite else { return }
        targetCameraPos = target
        if animated {
            automaticFitRadius = distance
        } else {
            automaticFitRadius = nil
            orbitRadius = distance
            cameraTarget = target
        }
    }

    public var isMoving: Bool {
        automaticFitRadius != nil || abs(targetAzimuth - azimuth) > 0.0001
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
        onUserInteraction?()
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
        onUserInteraction?()
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
        onUserInteraction?()
        orbitRadius = max(radius, 60)
        targetCameraPos = center
        cameraTarget = center
        teleportCounter += 1
        teleportLabel = label
    }
}
