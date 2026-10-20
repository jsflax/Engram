#if os(macOS)
import SwiftUI
import AppKit
import RealityKit
import EngramSceneKit

/// Reusable macOS input bridge — installs NSEvent monitor for keyboard/scroll/pinch/rotate
/// and drives CameraController.
///
/// Used by both EngramPreview and EngramVisualizer. On visionOS this class is not used —
/// visionOS input goes through RealityKit gesture components.
@MainActor
public final class RKInputBridge {
    public weak var camera: CameraController?
    public weak var scene: EngramRealityScene?
    private var eventMonitor: Any?
    /// Embedded hosts supply their view; legacy standalone callers keep nil.
    public weak var inputView: NSView?

    public init() {}

    // Caller must call uninstall() before dealloc — deinit can't access @MainActor state.

    // MARK: - NSEvent Monitor

    private static let movementKeys: Set<String> = ["w","a","s","d","i","j","k","l","q","e"]

    /// Install the macOS NSEvent local monitor for keyboard, scroll, pinch, and rotate.
    /// Call once when the view appears.
    public func install() {
        guard eventMonitor == nil else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .magnify, .rotate, .keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            self?.handleEvent(event)
        }
    }

    /// Remove the NSEvent monitor. Call when the view disappears.
    public func uninstall() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        camera?.heldKeys.removeAll()
    }

    private func handleEvent(_ event: NSEvent) -> NSEvent? {
        if let view = inputView {
            guard event.window === view.window, view.window != nil else {
                camera?.heldKeys.removeAll()
                return event
            }
            if [.keyDown, .keyUp, .flagsChanged].contains(event.type) {
                guard let responder = view.window?.firstResponder as? NSView,
                      responder === view || responder.isDescendant(of: view) else { return event }
            } else {
                guard view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return event }
                // Controls above an embedded canvas own their scroll/gestures.
                // A bounding box alone would still move the camera beneath them.
                guard let root = view.window?.contentView else { return event }
                let point = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
                guard let hit = root.hitTest(point), hit === view || hit.isDescendant(of: view) else { return event }
            }
        }
        // If camera is nil, still consume keyboard events to prevent beep
        guard let cam = camera else {
            if inputView != nil { return event }
            if (event.type == .keyDown || event.type == .keyUp),
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.shift).isEmpty {
                return nil
            }
            return event
        }

        // Shift tracking
        if event.type == .flagsChanged {
            if event.modifierFlags.contains(.shift) {
                cam.heldKeys.insert("shift")
            } else {
                cam.heldKeys.remove("shift")
            }
            return event
        }

        // Keyboard
        if event.type == .keyDown || event.type == .keyUp {
            // Don't intercept when typing in text fields
            if let responder = event.window?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                cam.heldKeys.removeAll()
                return event
            }

            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let noMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting(.shift).isEmpty

            if event.type == .keyDown {
                if noMods && Self.movementKeys.contains(key) {
                    cam.heldKeys.insert(key)
                    return nil  // consume
                }
                // Teleport keys — handled via callback
                if key == "t" && noMods, let onTeleport { onTeleport(1); return nil }
                if key == "r" && noMods, let onTeleport { onTeleport(-1); return nil }
                if key == "]" && noMods, let onGalaxyTeleport { onGalaxyTeleport(1); return nil }
                if key == "[" && noMods, let onGalaxyTeleport { onGalaxyTeleport(-1); return nil }
                // Consume all other unmodified keys to suppress system beep
                // only for the legacy standalone monitor. Embedded controls own
                // Escape/Tab/shortcuts which are not camera movement.
                if noMods && inputView == nil { return nil }
            } else {
                if Self.movementKeys.contains(key) {
                    cam.heldKeys.remove(key)
                    if noMods { return nil }
                }
                // Consume all unmodified keyUp to match keyDown consumption
                if noMods && inputView == nil { return nil }
            }
            return event
        }

        // Scroll wheel → pan (strafe)
        if event.type == .scrollWheel {
            let dx = Float(event.scrollingDeltaX) * 0.5
            let dy = Float(event.scrollingDeltaY) * 0.5
            cam.pan(dx: dx, dy: dy)
            return event
        }

        // Pinch → dolly
        if event.type == .magnify {
            let amount = Float(event.magnification) * 500.0
            cam.dolly(amount: amount)
            return event
        }

        // Rotate → look rotate
        if event.type == .rotate {
            let delta = Float(event.rotation) * 0.02
            cam.lookRotate(deltaAz: delta, deltaEl: 0)
            return event
        }

        return event
    }

    // MARK: - Callbacks for app-specific actions

    /// Called when T/R keys are pressed (teleport to next/prev project).
    public var onTeleport: (@MainActor (Int) -> Void)?
    /// Called when [/] keys are pressed (teleport to next/prev galaxy).
    public var onGalaxyTeleport: (@MainActor (Int) -> Void)?

    // MARK: - Per-Frame

    /// Call from the scene's onFrameCallback to poll keyboard + update camera.
    public func tick(dt: Float) {
        camera?.pollKeyboard(dt: dt)
    }
}

#endif
