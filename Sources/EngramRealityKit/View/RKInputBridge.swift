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
    private weak var scopeView: NSView?
    private var requiresScope = false

    public init() {}

    // Caller must call uninstall() before dealloc — deinit can't access @MainActor state.

    // MARK: - NSEvent Monitor

    private static let movementKeys: Set<String> = ["w","a","s","d","i","j","k","l","q","e"]

    /// Install the macOS NSEvent local monitor for keyboard, scroll, pinch, and rotate.
    /// Call once when the view appears.
    public func install() {
        requiresScope = false
        scopeView = nil
        installMonitor()
    }

    /// Embedded surfaces only receive pointer events inside this view and keyboard events whose
    /// first responder belongs to this exact view subtree. A lost/reparented view fails closed.
    public func install(in view: NSView) {
        uninstall()
        scopeView = view
        requiresScope = true
        installMonitor()
    }

    private func installMonitor() {
        guard eventMonitor == nil else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .magnify, .rotate, .keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleEvent(event)
        }
    }

    /// Remove the NSEvent monitor. Call when the view disappears.
    public func uninstall() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        camera?.heldKeys.removeAll()
        scopeView = nil
        requiresScope = false
    }

    /// Public for a native host's event routing/qualification; this does not mutate camera/focus.
    public static func eventBelongsToSurface(_ event: NSEvent, view: NSView) -> Bool {
        guard let window = view.window, event.window === window else { return false }
        if event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged {
            guard let responder = window.firstResponder as? NSView else { return false }
            return responder === view || responder.isDescendant(of: view)
        }
        return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
    }

    private func handleEvent(_ event: NSEvent) -> NSEvent? {
        if requiresScope {
            guard let scopeView, Self.eventBelongsToSurface(event, view: scopeView) else {
                camera?.heldKeys.removeAll()
                return event
            }
        }
        // If camera is nil, still consume keyboard events to prevent beep
        guard let cam = camera else {
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
                if key == "t" && noMods && (!requiresScope || onTeleport != nil) { onTeleport?(1); return nil }
                if key == "r" && noMods && (!requiresScope || onTeleport != nil) { onTeleport?(-1); return nil }
                if key == "]" && noMods && (!requiresScope || onGalaxyTeleport != nil) { onGalaxyTeleport?(1); return nil }
                if key == "[" && noMods && (!requiresScope || onGalaxyTeleport != nil) { onGalaxyTeleport?(-1); return nil }
                // Consume all other unmodified keys to suppress system beep
                if noMods && !requiresScope { return nil }
            } else {
                if Self.movementKeys.contains(key) {
                    cam.heldKeys.remove(key)
                    onCameraInteraction?()
                }
                // Consume all unmodified keyUp to match keyDown consumption
                if noMods && (!requiresScope || Self.movementKeys.contains(key)) { return nil }
            }
            return event
        }

        // Scroll wheel → pan (strafe)
        if event.type == .scrollWheel {
            let dx = Float(event.scrollingDeltaX) * 0.5
            let dy = Float(event.scrollingDeltaY) * 0.5
            cam.pan(dx: dx, dy: dy)
            onCameraInteraction?()
            return requiresScope ? nil : event
        }

        // Pinch → dolly
        if event.type == .magnify {
            let amount = Float(event.magnification) * 500.0
            cam.dolly(amount: amount)
            onCameraInteraction?()
            return requiresScope ? nil : event
        }

        // Rotate → look rotate
        if event.type == .rotate {
            let delta = Float(event.rotation) * 0.02
            cam.lookRotate(deltaAz: delta, deltaEl: 0)
            onCameraInteraction?()
            return requiresScope ? nil : event
        }

        return event
    }

    // MARK: - Callbacks for app-specific actions

    /// Called when T/R keys are pressed (teleport to next/prev project).
    public var onTeleport: ((Int) -> Void)?
    /// Called when [/] keys are pressed (teleport to next/prev galaxy).
    public var onGalaxyTeleport: ((Int) -> Void)?
    /// A presentation-only state change; the host decides whether/how to save it.
    public var onCameraInteraction: (() -> Void)?

    // MARK: - Per-Frame

    /// Call from the scene's onFrameCallback to poll keyboard + update camera.
    public func tick(dt: Float) {
        if requiresScope {
            guard let scopeView, let window = scopeView.window, window.isKeyWindow,
                  let responder = window.firstResponder as? NSView,
                  responder === scopeView || responder.isDescendant(of: scopeView) else {
                camera?.heldKeys.removeAll()
                return
            }
        }
        camera?.pollKeyboard(dt: dt)
    }
}
