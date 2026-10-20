import SwiftUI
import simd
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Local input for the existing camera. The embedding host supplies hit testing
/// and selection; this surface never opens a graph or observes global state.
@MainActor public struct RKInputSurface: View {
    let camera: CameraController
    let isActive: Bool
    let onTap: @MainActor (CGPoint, CGSize) -> Void
    let onProjectStep: (@MainActor (Int) -> Void)?
    let onGalaxyStep: (@MainActor (Int) -> Void)?
    @Environment(\.scenePhase) private var scenePhase
    public init(camera: CameraController, isActive: Bool = true,
                onProjectStep: (@MainActor (Int) -> Void)? = nil,
                onGalaxyStep: (@MainActor (Int) -> Void)? = nil,
                onTap: @escaping @MainActor (CGPoint, CGSize) -> Void) {
        self.camera = camera; self.isActive = isActive; self.onTap = onTap
        self.onProjectStep = onProjectStep; self.onGalaxyStep = onGalaxyStep
    }
    public var body: some View {
        PlatformInputSurface(camera: camera, isActive: isActive && scenePhase == .active,
                             onTap: onTap, onProjectStep: onProjectStep, onGalaxyStep: onGalaxyStep)
            .accessibilityHidden(true)
    }
}

#if os(macOS)
@MainActor private struct PlatformInputSurface: NSViewRepresentable {
    let camera: CameraController
    let isActive: Bool
    let onTap: @MainActor (CGPoint, CGSize) -> Void
    let onProjectStep: (@MainActor (Int) -> Void)?
    let onGalaxyStep: (@MainActor (Int) -> Void)?
    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {
        view.camera = camera; view.onTap = onTap; view.active = isActive
        view.bridge.camera = camera; view.bridge.inputView = view
        view.bridge.onTeleport = onProjectStep; view.bridge.onGalaxyTeleport = onGalaxyStep
        if isActive { view.bridge.install() } else { view.bridge.uninstall(); camera.endDrag() }
    }
    static func dismantleNSView(_ view: InputView, coordinator: ()) {
        view.bridge.uninstall(); view.camera?.endDrag(); view.camera = nil; view.onTap = nil
        view.bridge.onTeleport = nil; view.bridge.onGalaxyTeleport = nil
    }
    final class InputView: NSView {
        let bridge = RKInputBridge()
        weak var camera: CameraController?
        var onTap: (@MainActor (CGPoint, CGSize) -> Void)?
        var active = true
        private var origin: CGPoint?
        private var look: (azimuth: Float, elevation: Float, camPos: SIMD3<Float>)?
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { active }
        override func mouseDown(with event: NSEvent) {
            guard active, let camera else { return }
            window?.makeFirstResponder(self)
            origin = convert(event.locationInWindow, from: nil)
            look = camera.captureLookState()
        }
        override func mouseDragged(with event: NSEvent) {
            guard active, let camera, let origin, let look else { return }
            let point = convert(event.locationInWindow, from: nil)
            camera.applyLookDrag(start: look, dx: Float(point.x - origin.x) * 0.005,
                                 dy: -Float(point.y - origin.y) * 0.005)
        }
        override func mouseUp(with event: NSEvent) {
            defer { origin = nil; look = nil; camera?.endDrag() }
            guard active, let origin else { return }
            let point = convert(event.locationInWindow, from: nil)
            if hypot(point.x - origin.x, point.y - origin.y) < 5 { onTap?(point, bounds.size) }
        }
        override func resignFirstResponder() -> Bool { camera?.heldKeys.removeAll(); return true }
    }
}
#else
@MainActor private struct PlatformInputSurface: UIViewRepresentable {
    let camera: CameraController
    let isActive: Bool
    let onTap: @MainActor (CGPoint, CGSize) -> Void
    let onProjectStep: (@MainActor (Int) -> Void)?
    let onGalaxyStep: (@MainActor (Int) -> Void)?
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .clear; view.isMultipleTouchEnabled = true
        let coordinator = context.coordinator
        let orbit = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.orbit(_:)))
        orbit.maximumNumberOfTouches = 1
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.pan(_:)))
        pan.minimumNumberOfTouches = 2; pan.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinch(_:)))
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: orbit)
        let recognizers: [UIGestureRecognizer] = [orbit, pan, pinch, tap]
        for recognizer in recognizers { view.addGestureRecognizer(recognizer) }
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.camera = camera; context.coordinator.onTap = onTap
        view.isUserInteractionEnabled = isActive
        if !isActive { camera.endDrag(); context.coordinator.look = nil }
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        view.gestureRecognizers?.forEach { view.removeGestureRecognizer($0) }
        coordinator.camera?.endDrag(); coordinator.camera = nil; coordinator.onTap = nil
    }
    @MainActor final class Coordinator: NSObject {
        weak var camera: CameraController?
        var onTap: (@MainActor (CGPoint, CGSize) -> Void)?
        var look: (azimuth: Float, elevation: Float, camPos: SIMD3<Float>)?
        @objc func orbit(_ recognizer: UIPanGestureRecognizer) {
            guard let camera else { return }
            if recognizer.state == .began { look = camera.captureLookState() }
            if let look, recognizer.state == .changed {
                let delta = recognizer.translation(in: recognizer.view)
                camera.applyLookDrag(start: look, dx: Float(delta.x) * 0.005, dy: -Float(delta.y) * 0.005)
            }
            if [.ended, .cancelled, .failed].contains(recognizer.state) { look = nil; camera.endDrag() }
        }
        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            guard let camera, recognizer.state == .changed else { return }
            let delta = recognizer.translation(in: recognizer.view)
            camera.pan(dx: Float(delta.x) * 0.5, dy: -Float(delta.y) * 0.5)
            recognizer.setTranslation(.zero, in: recognizer.view)
        }
        @objc func pinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let camera, recognizer.state == .changed else { return }
            camera.dolly(amount: Float(recognizer.scale - 1) * 400)
            recognizer.scale = 1
        }
        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            onTap?(recognizer.location(in: view), view.bounds.size)
        }
    }
}
#endif
