import AppKit
import SwiftUI

/// Pure transition gate: occlusion notifications can repeat, and callbacks
/// belonging to a detached window must not restart its observation work.
struct WindowVisibilityState {
    enum Transition: Equatable { case show, hide }

    private(set) var generation: UInt64 = 0
    private(set) var isAttached = false
    private(set) var isVisible = false

    mutating func attach() -> UInt64 {
        precondition(!isAttached)
        generation &+= 1
        isAttached = true
        return generation
    }

    mutating func update(isVisible visible: Bool, generation observedGeneration: UInt64) -> Transition? {
        guard isAttached, observedGeneration == generation, visible != isVisible else { return nil }
        isVisible = visible
        return visible ? .show : .hide
    }

    mutating func detach() -> Transition? {
        let wasVisible = isVisible
        generation &+= 1
        isAttached = false
        isVisible = false
        return wasVisible ? .hide : nil
    }
}

/// MenuBarExtra reuses its hosting view between presentations, so SwiftUI
/// onAppear/onDisappear are not a reliable start/stop boundary. This bridge
/// follows the owning AppKit window even when SwiftUI retains the content.
struct WindowVisibilityLifecycle: NSViewRepresentable {
    let responseName: String
    let onShow: @MainActor () -> Void
    let onHide: @MainActor () -> Void

    func makeNSView(context: Context) -> VisibilityView {
        VisibilityView(responseName: responseName, onShow: onShow, onHide: onHide)
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onShow = onShow
        view.onHide = onHide
        view.refreshVisibility()
    }

    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) {
        view.detach()
        view.onShow = {}
        view.onHide = {}
    }

    final class VisibilityView: NSView {
        private let responseName: String
        var onShow: @MainActor () -> Void
        var onHide: @MainActor () -> Void
        private weak var observedWindow: NSWindow?
        private var observation: WindowVisibilityObservation?
        private var state = WindowVisibilityState()

        init(responseName: String, onShow: @escaping @MainActor () -> Void,
             onHide: @escaping @MainActor () -> Void) {
            self.responseName = responseName
            self.onShow = onShow
            self.onHide = onHide
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else {
                detach()
                return
            }
            if observedWindow === window {
                refreshVisibility()
                return
            }
            detach()
            observedWindow = window
            let generation = state.attach()
            // Subscribe before the initial read so an opening/closing between
            // attachment and delivery cannot be missed. Main-queue delivery
            // stays synchronous on AppKit's event turn; do not defer begin().
            let token = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshVisibility(generation: generation)
                }
            }
            observation = WindowVisibilityObservation(token: token)
            refreshVisibility(generation: generation)
        }

        func refreshVisibility() {
            refreshVisibility(generation: state.generation)
        }

        private func refreshVisibility(generation: UInt64) {
            guard let observedWindow, observedWindow === window else { return }
            // isVisible means ordered on screen. Being covered by another
            // window must not create a second presentation or reset its clock.
            apply(state.update(isVisible: observedWindow.isVisible, generation: generation))
        }

        func detach() {
            observation = nil
            observedWindow = nil
            apply(state.detach())
        }

        private func apply(_ transition: WindowVisibilityState.Transition?) {
            switch transition {
            case .show:
                PanelResponseRecorder.begin(responseName)
                onShow()
                // Reused hosting views can keep their backing content. Force
                // this real NSView draw for each presentation, never rebase
                // the input timestamp at draw time or synthesize completion.
                needsDisplay = true
            case .hide:
                PanelResponseRecorder.cancel(responseName)
                onHide()
            case nil:
                break
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            guard state.isVisible else { return }
            PanelResponseRecorder.didDraw(responseName)
        }
    }
}

/// NotificationCenter retains the token, but its callback retains the view
/// only weakly. Releasing this owner removes the observer even if a view is
/// deallocated without a normal SwiftUI dismantle callback.
private final class WindowVisibilityObservation {
    let token: NSObjectProtocol
    init(token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}
