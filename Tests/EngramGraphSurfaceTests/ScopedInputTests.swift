import AppKit
import Testing
import EngramRealityKit

@Suite("Native graph input scope", .serialized) @MainActor
struct ScopedInputTests {
    @Test func separateWindowsAndSiblingViewsCannotStealEachOthersInput() throws {
        _ = NSApplication.shared
        let first = window(), second = window()
        defer { first.close(); second.close() }
        let left = FocusView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let right = FocusView(frame: NSRect(x: 100, y: 0, width: 100, height: 100))
        first.contentView!.addSubview(left); first.contentView!.addSubview(right)
        let pointer = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 20, y: 20),
            modifierFlags: [], timestamp: 0, windowNumber: first.windowNumber, context: nil,
            eventNumber: 1, clickCount: 0, pressure: 0))
        #expect(RKInputBridge.eventBelongsToSurface(pointer, view: left))
        #expect(!RKInputBridge.eventBelongsToSurface(pointer, view: right))
        #expect(!RKInputBridge.eventBelongsToSurface(pointer, view: second.contentView!))
        #expect(first.makeFirstResponder(left))
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: first.windowNumber, context: nil, characters: "w",
            charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        #expect(RKInputBridge.eventBelongsToSurface(key, view: left))
        #expect(!RKInputBridge.eventBelongsToSurface(key, view: right))
        left.removeFromSuperview()
        #expect(!RKInputBridge.eventBelongsToSurface(key, view: left))
    }
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}
@MainActor private final class FocusView: NSView { override var acceptsFirstResponder: Bool { true } }
