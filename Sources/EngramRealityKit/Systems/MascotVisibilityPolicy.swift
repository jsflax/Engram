import simd

/// The rendered camera in scene coordinates. Viewport dimensions are logical
/// points, matching the app's view geometry rather than its backing pixels.
public struct MascotVisibilityCamera: Sendable {
    public enum FieldOfViewOrientation: Sendable { case vertical, horizontal }
    public let position: SIMD3<Float>
    public let right: SIMD3<Float>
    public let up: SIMD3<Float>
    public let forward: SIMD3<Float>
    public let fieldOfViewInDegrees: Float
    public let fieldOfViewOrientation: FieldOfViewOrientation
    public let viewportSize: SIMD2<Float>
    public let near: Float
    public let far: Float

    public init(position: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                forward: SIMD3<Float>, fieldOfViewInDegrees: Float,
                fieldOfViewOrientation: FieldOfViewOrientation = .vertical,
                viewportSize: SIMD2<Float>, near: Float = 0.01, far: Float = .infinity) {
        self.position = position; self.right = right; self.up = up; self.forward = forward
        self.fieldOfViewInDegrees = fieldOfViewInDegrees
        self.fieldOfViewOrientation = fieldOfViewOrientation
        self.viewportSize = viewportSize; self.near = near; self.far = far
    }
}

/// Render eligibility only: behavioral simulation and task ownership continue.
enum MascotVisibilityPolicy {
    // Retain subpixel-scale detail through small camera changes. These are
    // visibility thresholds, not a measured performance budget or count cap.
    static let enterDiameter: Float = 2
    static let leaveDiameter: Float = 1

    static func isVisible(center: SIMD3<Float>, radius: Float,
                          camera: MascotVisibilityCamera?, wasVisible: Bool) -> Bool {
        guard let camera else { return true }
        func finite(_ value: SIMD3<Float>) -> Bool {
            value.x.isFinite && value.y.isFinite && value.z.isFinite
        }
        guard finite(center), radius.isFinite, radius >= 0,
              finite(camera.position), finite(camera.right), finite(camera.up), finite(camera.forward),
              camera.viewportSize.x.isFinite, camera.viewportSize.y.isFinite,
              camera.viewportSize.x > 0, camera.viewportSize.y > 0,
              camera.fieldOfViewInDegrees.isFinite,
              camera.fieldOfViewInDegrees > 0, camera.fieldOfViewInDegrees < 180,
              camera.near.isFinite, camera.near >= 0,
              !camera.far.isNaN, camera.far > camera.near,
              abs(simd_length_squared(camera.right) - 1) < 0.001,
              abs(simd_length_squared(camera.up) - 1) < 0.001,
              abs(simd_length_squared(camera.forward) - 1) < 0.001,
              abs(simd_dot(camera.right, camera.up)) < 0.001,
              abs(simd_dot(camera.right, camera.forward)) < 0.001,
              abs(simd_dot(camera.up, camera.forward)) < 0.001 else { return true }

        let offset = center - camera.position
        let depth = simd_dot(offset, camera.forward)
        let horizontal = simd_dot(offset, camera.right)
        let vertical = simd_dot(offset, camera.up)
        guard depth.isFinite, horizontal.isFinite, vertical.isFinite else { return true }
        if simd_length(offset) <= radius { return true }
        if depth + radius < camera.near || depth - radius > camera.far { return false }

        let aspect = camera.viewportSize.x / camera.viewportSize.y
        let tangent = tan(camera.fieldOfViewInDegrees * .pi / 360)
        let tanV: Float
        let tanH: Float
        switch camera.fieldOfViewOrientation {
        case .vertical: tanV = tangent; tanH = tangent * aspect
        case .horizontal: tanH = tangent; tanV = tangent / aspect
        }
        guard tanV.isFinite, tanH.isFinite, tanV > 0, tanH > 0 else { return true }
        // Plane support includes the entire sphere, even when its center is
        // outside the viewport or behind the near plane.
        if abs(horizontal) > depth * tanH + radius * sqrt(1 + tanH * tanH)
            || abs(vertical) > depth * tanV + radius * sqrt(1 + tanV * tanV) { return false }

        // A sphere crossing the eye plane can have arbitrarily large projected
        // extent. For other spheres, include perspective magnification away
        // from the optical axis as well as the nearest surface. The added
        // factor bounds the projected enclosing box on each screen axis.
        if depth <= radius { return true }
        let distance = max(depth - radius, max(camera.near, 0.0001))
        let width = radius * camera.viewportSize.x / (tanH * distance)
            * (1 + abs(horizontal) / depth)
        let height = radius * camera.viewportSize.y / (tanV * distance)
            * (1 + abs(vertical) / depth)
        let diameter = max(width, height)
        guard diameter.isFinite else { return true }
        return diameter >= (wasVisible ? leaveDiameter : enterDiameter)
    }
}
