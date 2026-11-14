import Testing
import Foundation
import simd
@testable import EngramRealityKit
import EngramSceneKit

@Suite("Camera Transform Tests")
struct CameraTransformTests {

    @Test("CameraState default values")
    func defaultValues() {
        let state = CameraState()
        #expect(state.azimuth == 0)
        #expect(abs(state.elevation - 0.3) < 0.001)
        #expect(state.cameraTarget == .zero)
        #expect(state.orbitRadius == 2.0)
        #expect(abs(state.scaleFactor - 0.005) < 0.0001)
        #expect(state.fovDegrees == 60)
    }

    @Test("CameraState camera position at azimuth 0")
    func cameraPositionAzimuth0() {
        let state = CameraState(azimuth: 0, elevation: 0, orbitRadius: 100)
        let pos = state.cameraPosition
        // At azimuth=0, elevation=0: camera is at (0, 0, 100)
        #expect(abs(pos.x) < 0.01)
        #expect(abs(pos.y) < 0.01)
        #expect(abs(pos.z - 100) < 0.01)
    }

    @Test("CameraState camera position at azimuth pi/2")
    func cameraPositionAzimuthHalfPi() {
        let state = CameraState(azimuth: Float.pi / 2, elevation: 0, orbitRadius: 100)
        let pos = state.cameraPosition
        // At azimuth=pi/2, elevation=0: camera is at (100, 0, 0)
        #expect(abs(pos.x - 100) < 0.1)
        #expect(abs(pos.y) < 0.01)
        #expect(abs(pos.z) < 0.1)
    }

    @Test("CameraState elevation moves camera up")
    func elevationMovesUp() {
        let state = CameraState(azimuth: 0, elevation: Float.pi / 4, orbitRadius: 100)
        let pos = state.cameraPosition
        #expect(pos.y > 50)  // elevation ~45° should have significant Y
    }

    @Test("CameraState forward direction points at target")
    func forwardPointsAtTarget() {
        let state = CameraState(
            azimuth: 0.5,
            elevation: 0.3,
            cameraTarget: SIMD3<Float>(10, 20, 30),
            orbitRadius: 200
        )
        let forward = state.forward
        // Forward should point from camera to target
        let expectedDir = normalize(state.cameraTarget - state.cameraPosition)
        #expect(abs(forward.x - expectedDir.x) < 0.01)
        #expect(abs(forward.y - expectedDir.y) < 0.01)
        #expect(abs(forward.z - expectedDir.z) < 0.01)
    }

    @Test("CameraState view matrix is valid")
    func viewMatrixValid() {
        let state = CameraState()
        let view = state.viewMatrix()
        // View matrix should not be identity (camera is offset)
        #expect(view[3][0] != 0 || view[3][1] != 0 || view[3][2] != 0)
    }

    @Test("CameraState projection matrix has correct FOV")
    func projectionMatrix() {
        let state = CameraState(fovDegrees: 60)
        let proj = state.projectionMatrix(aspect: 1.0)
        // Y scale should be 1/tan(30°) ≈ 1.732
        let expectedYScale = 1.0 / tan(Float.pi / 6)
        #expect(abs(proj[1][1] - expectedYScale) < 0.01)
    }
}

@Suite("Embedded Camera Framing Tests") @MainActor
struct EmbeddedCameraFramingTests {
    private func ring() -> [UUID: SIMD3<Float>] {
        var result: [UUID: SIMD3<Float>] = [:]
        for index in 0..<32 {
            let angle = Float(index) * 2 * Float.pi / 32
            let id = UUID(uuidString: String(format: "71000000-0000-0000-0000-%012d", index + 1))!
            result[id] = SIMD3<Float>(100 * cos(angle), 100 * sin(angle), 0)
        }
        return result
    }

    @Test("Embedded fit uses the limiting viewport FOV and preserves the desktop floor",
          arguments: [CGSize(width: 900, height: 450), CGSize(width: 393, height: 852)])
    func projectedBounds(viewport: CGSize) throws {
        let positions = ring()
        let camera = CameraController()
        camera.centerOnGraph(positions: positions)
        #expect(camera.orbitRadius == 4200)
        let oldPoints = try positions.values.map { try #require(camera.project(point3D: $0, viewSize: viewport)) }
        let oldWidth = try #require(oldPoints.map(\.x).max()) - #require(oldPoints.map(\.x).min())
        camera.centerOnGraph(positions: positions, minimumOrbitRadius: 80, fitViewport: viewport)
        #expect(camera.orbitRadius >= 80 && camera.orbitRadius < 4200)
        let points = try positions.values.map { try #require(camera.project(point3D: $0, viewSize: viewport)) }
        let minX = try #require(points.map(\.x).min()), maxX = try #require(points.map(\.x).max())
        let minY = try #require(points.map(\.y).min()), maxY = try #require(points.map(\.y).max())
        #expect(minX >= viewport.width * 0.05 && maxX <= viewport.width * 0.95)
        #expect(minY >= viewport.height * 0.05 && maxY <= viewport.height * 0.95)
        #expect(max((maxX - minX) / viewport.width, (maxY - minY) / viewport.height) >= 0.5)
        #expect(maxX - minX > oldWidth * 5)
        print("EMBEDDED_CAMERA_BOUNDS width=\(viewport.width) height=\(viewport.height) orbit=\(camera.orbitRadius) minX=\(minX) maxX=\(maxX) minY=\(minY) maxY=\(maxY) legacyWidth=\(oldWidth)")
    }

    @Test("Invalid viewport falls back safely and empty graphs preserve camera state")
    func invalidAndEmptyInputs() {
        let camera = CameraController(), positions = ring()
        camera.centerOnGraph(positions: positions, minimumOrbitRadius: 80, fitViewport: .zero)
        #expect(abs(camera.orbitRadius - 350) < 0.01)
        let radius = camera.orbitRadius, target = camera.cameraTarget
        camera.centerOnGraph(positions: [:], minimumOrbitRadius: 80, fitViewport: CGSize(width: 393, height: 852))
        camera.centerOnGraph(positions: positions, minimumOrbitRadius: .nan, fitViewport: CGSize(width: 393, height: 852))
        #expect(camera.orbitRadius == radius && camera.cameraTarget == target)
    }
}


extension EmbeddedCameraFramingTests {
    @Test("Measured overlay fit clears all four off-axis projection planes",
          arguments: [CGSize(width: 900, height: 418), CGSize(width: 393, height: 852)])
    func measuredOverlayBounds(viewport: CGSize) throws {
        let camera = CameraController()
        camera.lookRotate(deltaAz: 0.7, deltaEl: -0.15)
        let center = SIMD3<Float>(83, -17, 29)
        let top: CGFloat = viewport.width > viewport.height ? 128 : 228
        let visible = CGRect(x: 0, y: top, width: viewport.width, height: viewport.height - top)
        camera.centerOnGraph(center: center, radius: 100, minimumOrbitRadius: 80,
                             fitViewport: viewport, visibleRect: visible)
        let projectedCenter = try #require(camera.project(point3D: center, viewSize: viewport))
        #expect(abs(projectedCenter.x - visible.midX) < 0.01)
        #expect(abs(projectedCenter.y - visible.midY) < 0.01)
        for latitude in -8...8 {
            for longitude in 0..<32 {
                let elevation = Float(latitude) * Float.pi / 16
                let azimuth = Float(longitude) * 2 * Float.pi / 32
                let point = center + SIMD3<Float>(100 * cos(elevation) * cos(azimuth),
                                                 100 * sin(elevation),
                                                 100 * cos(elevation) * sin(azimuth))
                let projected = try #require(camera.project(point3D: point, viewSize: viewport))
                #expect(projected.x >= visible.minX && projected.x <= visible.maxX)
                #expect(projected.y >= visible.minY && projected.y <= visible.maxY)
            }
        }
        let radius = camera.orbitRadius, target = camera.targetCameraPos
        for invalid in [CGRect.zero, CGRect(x: 0, y: -1, width: 20, height: 20),
                        CGRect(x: 0, y: 0, width: viewport.width + 1, height: viewport.height)] {
            camera.centerOnGraph(center: center, radius: 100, minimumOrbitRadius: 80,
                                 fitViewport: viewport, visibleRect: invalid)
            #expect(camera.orbitRadius == radius && camera.targetCameraPos == target)
        }
    }

    @Test("Native input reports intent before changing camera state")
    func userIntentPrecedesMovement() {
        let camera = CameraController()
        let original = camera.targetCameraPos
        var notified = false
        camera.onUserInteraction = {
            #expect(camera.targetCameraPos == original)
            notified = true
        }
        camera.pan(dx: 20, dy: 10)
        #expect(notified)
        #expect(camera.targetCameraPos != original)
        camera.onUserInteraction = nil
        camera.dolly(amount: 10) // Existing desktop callers need no observer.
    }
}


extension EmbeddedCameraFramingTests {
    @Test("Automatic fitting transitions through existing updates and cancels at the rendered camera")
    func smoothAutomaticFitAndInputCancellation() throws {
        let camera = CameraController(), viewport = CGSize(width: 900, height: 418)
        let rect = CGRect(x: 0, y: 120, width: 900, height: 298)
        camera.centerOnGraph(center: .zero, radius: 100, minimumOrbitRadius: 80,
                             fitViewport: viewport, visibleRect: rect)
        let first = camera.orbitRadius, firstTarget = camera.cameraTarget
        camera.centerOnGraph(center: SIMD3(10, 20, 30), radius: 120, minimumOrbitRadius: 80,
                             fitViewport: viewport, visibleRect: rect, animated: true)
        #expect(camera.orbitRadius == first && camera.cameraTarget == firstTarget)
        #expect(camera.isAutomaticallyFraming && camera.isMoving)
        camera.updateCamera(dt: 1.0 / 60.0)
        #expect(camera.orbitRadius > first && camera.orbitRadius < first * 1.05)
        // Even a delayed update cannot apply the remaining target at once.
        let beforeDelay = camera.orbitRadius
        camera.updateCamera(dt: 2)
        #expect(camera.orbitRadius > beforeDelay && camera.orbitRadius < first * 1.2)
        camera.onUserInteraction = { camera.cancelAutomaticFraming() }
        let current = camera.cameraTarget, radius = camera.orbitRadius
        _ = camera.captureLookState()
        #expect(camera.targetCameraPos == current && !camera.isAutomaticallyFraming)
        camera.endDrag()
        for _ in 0..<120 { camera.updateCamera(dt: 1.0 / 60.0) }
        #expect(camera.cameraTarget == current && camera.orbitRadius == radius)
        camera.centerOnGraph(center: .zero, radius: 180, minimumOrbitRadius: 80,
                             fitViewport: viewport, visibleRect: rect, animated: true)
        for _ in 0..<120 { camera.updateCamera(dt: 1.0 / 60.0) }
        #expect(!camera.isAutomaticallyFraming)
        let result = try #require(camera.project(point3D: .zero, viewSize: viewport))
        #expect(abs(result.x - rect.midX) < 0.01 && abs(result.y - rect.midY) < 0.01)
        // Manual Center remains immediate, including cancellation of queued fitting.
        camera.centerOnGraph(center: .zero, radius: 900, minimumOrbitRadius: 80,
                             fitViewport: viewport, visibleRect: rect, animated: true)
        camera.centerOnGraph(positions: ring())
        #expect(camera.orbitRadius == 4200 && !camera.isAutomaticallyFraming)
        camera.onUserInteraction = nil
    }
}

@Suite("Embedded cluster label sizing")
struct EmbeddedClusterLabelSizingTests {
    @Test("Project and topic quads stay within mobile point bounds", arguments: [Float(3), 18, 60])
    func projectedBounds(aspect: Float) {
        for viewport in [CGSize(width: 390, height: 650), CGSize(width: 650, height: 300)] {
            for depth: Float in [5, 80, 4200] {
                for (legacy, maximumHeight, widthFraction): (Float, Float, Float) in [(14, 18, 0.6), (8, 12, 0.5)] {
                    let half = ClusterLabelSizing.halfHeight(legacy: legacy, bounded: true,
                        aspect: aspect, depth: depth, fovDegrees: 60, viewport: viewport,
                        maximumHeight: maximumHeight, maximumWidthFraction: widthFraction)
                    #expect(half > 0 && half <= legacy)
                    let camera = CameraState(azimuth: 0, elevation: 0, orbitRadius: depth, scaleFactor: 1)
                    let matrix = camera.projectionMatrix(aspect: Float(viewport.width / viewport.height)) * camera.viewMatrix()
                    let topRight = matrix * SIMD4<Float>(half * aspect, half, 0, 1)
                    let bottomLeft = matrix * SIMD4<Float>(-half * aspect, -half, 0, 1)
                    let projectedHeight = (topRight.y / topRight.w - bottomLeft.y / bottomLeft.w) * Float(viewport.height) / 2
                    let projectedWidth = (topRight.x / topRight.w - bottomLeft.x / bottomLeft.w) * Float(viewport.width) / 2
                    #expect(projectedHeight <= maximumHeight + 0.001)
                    #expect(projectedWidth <= Float(viewport.width) * widthFraction + 0.001)
                }
            }
        }
    }

    @Test("Unmeasured, behind-camera and invalid geometry cannot create large quads")
    func invalidGeometry() {
        func size(depth: Float = 80, fov: Float = 60, aspect: Float = 18,
                  viewport: CGSize? = CGSize(width: 390, height: 650)) -> Float {
            ClusterLabelSizing.halfHeight(legacy: 14, bounded: true, aspect: aspect,
                depth: depth, fovDegrees: fov, viewport: viewport,
                maximumHeight: 18, maximumWidthFraction: 0.6)
        }
        #expect(size(viewport: nil) == 0)
        #expect(size(viewport: .zero) == 0)
        #expect(size(viewport: CGSize(width: CGFloat.infinity, height: 650)) == 0)
        #expect(size(depth: 0) == 0)
        #expect(size(depth: -1) == 0)
        #expect(size(depth: .infinity) == 0)
        #expect(size(fov: .nan) == 0)
        #expect(size(fov: 180) == 0)
        #expect(size(aspect: 0) == 0)
        #expect(size(aspect: .infinity) == 0)
    }

    @Test("Default desktop label world sizes are unchanged")
    func legacySizes() {
        for size: Float in [14, 8] {
            #expect(ClusterLabelSizing.halfHeight(legacy: size, bounded: false,
                aspect: .nan, depth: 0, fovDegrees: 0, viewport: nil,
                maximumHeight: 0, maximumWidthFraction: 0) == size)
        }
    }
}


@Suite("Embedded label-aware camera framing") @MainActor
struct EmbeddedLabelAwareFramingTests {
    @Test("Actual cluster quads fit below measured chrome at small and expanded graph sizes",
          arguments: [CGSize(width: 393, height: 650), CGSize(width: 852, height: 270)])
    func includesClusterQuads(viewport: CGSize) throws {
        let visible = CGRect(x: 0, y: viewport.width > viewport.height ? 92 : 176,
                             width: viewport.width, height: viewport.height - (viewport.width > viewport.height ? 92 : 176))
        let camera = CameraController()
        for radius: Float in [10, 80, 260] {
            let anchors: [(SIMD3<Float>, ClusterLabelKind)] = [
                (SIMD3(0, ClusterLabelKind.project.graphVerticalOffset, 0), .project),
                (SIMD3(0, ClusterLabelKind.topic.graphVerticalOffset, 0), .topic),
                (SIMD3(radius, radius / 2 + ClusterLabelKind.project.graphVerticalOffset, 0), .project),
                (SIMD3(-radius, -radius / 2 + ClusterLabelKind.topic.graphVerticalOffset, 0), .topic)
            ]
            let billboards = anchors.map { CameraController.FramingBillboard(anchor: $0.0,
                maximumPointSize: $0.1.maximumPointSize(in: viewport)) }
            camera.centerOnGraph(center: .zero, radius: radius, minimumOrbitRadius: 80,
                fitViewport: viewport, visibleRect: visible, billboards: billboards)
            for (anchor, kind) in anchors {
                // Exercise the actual render sizing and billboard axes, including
                // long labels that reach the width cap and ordinary short names.
                for aspect: Float in [3, 60] {
                    let depth = simd_dot(anchor - camera.cameraPosition, camera.forward) * camera.scaleFactor
                    let half = ClusterLabelSizing.halfHeight(legacy: kind == .project ? 14 : 8,
                        bounded: true, aspect: aspect, depth: depth, fovDegrees: camera.fovDegrees,
                        viewport: viewport, maximumHeight: Float(kind.maximumPointHeight),
                        maximumWidthFraction: Float(kind.maximumViewportWidthFraction)) / camera.scaleFactor
                    #expect(half > 0)
                    for x: Float in [-1, 1] {
                        for y: Float in [-1, 1] {
                            let corner = anchor + camera.right * (half * aspect * x) + camera.up * (half * y)
                            let point = try #require(camera.project(point3D: corner, viewSize: viewport))
                            #expect(point.x >= visible.minX && point.x <= visible.maxX)
                            #expect(point.y >= visible.minY && point.y <= visible.maxY)
                        }
                    }
                }
            }
        }
    }

    @Test("The two-node overlap is reproduced without annotation bounds; invalid bounds preserve the camera")
    func overlapAndInvalidInputs() throws {
        let camera = CameraController(), viewport = CGSize(width: 393, height: 650)
        let visible = CGRect(x: 0, y: 176, width: 393, height: 474)
        let anchor = SIMD3<Float>(0, ClusterLabelKind.project.graphVerticalOffset, 0)
        camera.centerOnGraph(center: .zero, radius: 10, minimumOrbitRadius: 80,
            fitViewport: viewport, visibleRect: visible)
        let clipped = try #require(camera.project(point3D: anchor, viewSize: viewport))
        #expect(clipped.y < visible.minY)
        let priorRadius = camera.orbitRadius, priorTarget = camera.cameraTarget
        for billboard in [
            CameraController.FramingBillboard(anchor: SIMD3(.nan, 0, 0), maximumPointSize: CGSize(width: 40, height: 18)),
            CameraController.FramingBillboard(anchor: anchor, maximumPointSize: CGSize(width: 393, height: 18)),
            CameraController.FramingBillboard(anchor: anchor, maximumPointSize: CGSize(width: 40, height: CGFloat.infinity))
        ] {
            camera.centerOnGraph(center: SIMD3(50, 60, 70), radius: 200, minimumOrbitRadius: 80,
                fitViewport: viewport, visibleRect: visible, billboards: [billboard])
            #expect(camera.orbitRadius == priorRadius && camera.cameraTarget == priorTarget)
        }
        camera.centerOnGraph(positions: [UUID(): SIMD3(-10, 0, 0), UUID(): SIMD3(10, 0, 0)])
        #expect(camera.orbitRadius == 4200 && camera.cameraTarget == .zero)
    }
}
