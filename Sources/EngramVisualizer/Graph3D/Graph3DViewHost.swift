import SwiftUI
import EngramSceneKit
import EngramRealityKit
import RealityKit
import GameController
import simd
import os
import Lattice
import EngramModels

private let frameLog = Logger(subsystem: "com.claudememory.visualizer", category: "3DFrameTiming")

// MARK: - Graph3DView (SwiftUI host)

struct Graph3DView: View {
    let layoutMode: LayoutMode
    let showMascots: Bool
    let soundEnabled: Bool
    @Binding var selectedNode: UUID?
    let semanticClusters3D: [SemanticCluster3D]
    /// Direct references for renderTick — avoids closures crossing SwiftUI observation boundary.
    let simulation3D: ForceSimulation3D
    let embeddingProjection: EmbeddingProjection
    let camera3DState: Camera3DState
    let forcePositionSnapshot3D: [UUID: SIMD3<Float>]
    let transitionProgress: CGFloat
    let renderStore: GraphRenderStore
    let galaxyRegistry: GalaxyRegistry
    @Binding var cameraProjectTarget: String?

    @State private var rkSceneManager: RKSceneManager?
    @State private var scrollMonitor: Any?
    @State private var reticleTarget: UUID?
    @State private var teleportLabelText: String?
    @State private var teleportCounterValue: Int = 0

    // Mascot chat state
    @State private var isMascotChatOpen = false
    @State private var mascotChatEngine: AnyObject?  // type-erased for @available gating
    @Environment(\.lattice) private var lattice

    // Maintenance mode observation
    @State private var maintenanceObserver: AnyObject?

    /// Active scene object for input forwarding.
    private var activeSceneForInput: AnyObject? { rkSceneManager }

    #if ENGRAM_INSTRUMENTATION
    static var bodyEvalCount: UInt64 = 0
    static var bodyEvalFile: UnsafeMutablePointer<FILE>? = nil
    #endif

    var body: some View {
        #if ENGRAM_INSTRUMENTATION
        let _ = {
            Self.bodyEvalCount &+= 1
            if Self.bodyEvalFile == nil {
                Self.bodyEvalFile = fopen("/tmp/swiftui-body-eval.csv", "w")
                if let f = Self.bodyEvalFile {
                    fputs("timestamp,body_eval_count\n", f)
                }
            }
            if let f = Self.bodyEvalFile {
                let line = "\(String(format: "%.3f", CFAbsoluteTimeGetCurrent())),\(Self.bodyEvalCount)\n"
                fputs(line, f)
                fflush(f)
            }
        }()
        #endif
        GeometryReader { geo in
            ZStack {
                rkViewContent
                    .gesture(rkOrbitGesture)
                    .simultaneousGesture(rkTapGesture(viewSize: geo.size))
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    viewFrame = frame
                    rkSceneManager?.renderViewSize = frame.size
                }

                // Center reticle (only when gamepad connected)
                if GCController.current != nil {
                    reticleOverlay
                }

                // Teleport project label (fades after 2s)
                if let label = teleportLabelText {
                    let counter = teleportCounterValue
                    Text(label)
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.5), in: .capsule)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .task(id: counter) {
                            let myCounter = counter
                            try? await Task.sleep(for: .seconds(2))
                            if teleportCounterValue == myCounter {
                                teleportLabelText = nil
                            }
                        }
                }

                // Mascot chat panel
                if isMascotChatOpen {
                    // Click-outside-to-dismiss backdrop
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { toggleMascotChat() } }

                    if #available(macOS 26.0, *), let engine = mascotChatEngine as? MascotChatEngine {
                        MascotChatPanel(engine: engine) {
                            toggleMascotChat()
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .padding(.leading, 16)
                        .padding(.top, 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .onKeyPress(.escape) {
                            withAnimation(.easeOut(duration: 0.2)) { toggleMascotChat() }
                            return .handled
                        }
                    }
                }

                // Mode indicator + navigation hints
                VStack {
                    if layoutMode == .embedding {
                        Text("3D SEMANTIC VIEW — proximity = embedding similarity")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.cyan.opacity(0.4))
                            .padding(.top, 12)
                    }
                    Spacer()
                    VStack(spacing: 4) {
                        HStack(spacing: 16) {
                            Label("Drag to look", systemImage: "arrow.triangle.2.circlepath")
                            Label("Scroll to strafe", systemImage: "hand.draw")
                            Label("Pinch to fly", systemImage: "arrow.up.left.and.arrow.down.right")
                            Label("Twist to rotate", systemImage: "rotate.left")
                            Label("Click to select", systemImage: "cursorarrow.click")
                        }
                        HStack(spacing: 16) {
                            Label("WASD move", systemImage: "keyboard")
                            Label("IJKL look", systemImage: "keyboard")
                            Label("QE rise/descend", systemImage: "keyboard")
                            Label("Shift sprint", systemImage: "keyboard")
                            Label("T/R teleport", systemImage: "keyboard")
                            Label("[/] galaxy", systemImage: "keyboard")
                        }
                        if GCController.current != nil {
                            HStack(spacing: 16) {
                                Label("L-Stick move", systemImage: "l.joystick")
                                Label("R-Stick look", systemImage: "r.joystick")
                                Label("Triggers rise/descend", systemImage: "l2.button.roundedtop.horizontal")
                                Label("A select", systemImage: "a.button.roundedtop.horizontal.fill")
                                Label("X prev project", systemImage: "x.button.roundedtop.horizontal.fill")
                                Label("Y next project", systemImage: "y.button.roundedtop.horizontal.fill")
                                Label("Bumpers cycle", systemImage: "l1.button.roundedtop.horizontal")
                                Label("L3/R3 sprint", systemImage: "l.joystick.press.down")
                            }
                        }
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.3), in: .capsule)
                    .padding(.bottom, 10)
                }
            }
        }
        .accessibilityIdentifier("graph-3d-view")
        .onDisappear { removeInputMonitor() }
        .onChange(of: soundEnabled) { _, enabled in
            rkSceneManager?.soundEnabled = enabled
        }
        .onChange(of: selectedNode) { _, newValue in
            if newValue != rkSceneManager?.selectedNode {
                rkSceneManager?.selectedNode = newValue
                if newValue == nil { collapseAllHubs() }
            }
        }
        .onChange(of: cameraProjectTarget) { _, project in
            if let project {
                rkSceneManager?.driveToProject(project)
                cameraProjectTarget = nil
            }
        }
    }

    // MARK: - EngramRealityKit View

    @ViewBuilder
    private var rkViewContent: some View {
        if let rk = rkSceneManager {
            EngramRealityView(scene: rk.rkScene)
                .onChange(of: layoutMode) { _, _ in pushDataToRKScene() }
                .onChange(of: showMascots) { _, _ in pushDataToRKScene() }
        } else {
            Color(red: 0.051, green: 0.067, blue: 0.09)
                .onAppear { setupRKRenderer() }
        }
    }

    private func setupRKRenderer() {
        guard rkSceneManager == nil else { return }
        guard let mgr = RKSceneManager(registry: galaxyRegistry) else { return }
        rkSceneManager = mgr

        mgr.galaxyRegistry = galaxyRegistry
        mgr.soundEnabled = soundEnabled
        mgr.camera3DState = camera3DState
        mgr.selectionCallback = { newSelection in
            selectedNode = newSelection
        }
        mgr.reticleCallback = { newTarget in
            if newTarget != reticleTarget {
                reticleTarget = newTarget
            }
        }
        mgr.teleportCallback = { label, counter in
            if label != teleportLabelText || counter != teleportCounterValue {
                teleportLabelText = label
                teleportCounterValue = counter
            }
        }
        pushDataToRKScene()
        installInputMonitor()

        // Audio is handled by RKSpatialAudioSystem inside EngramRealityScene
        mgr.soundEnabled = soundEnabled

        // Center camera on graph. At setup the async galaxy loads have
        // rarely populated any positions, and centerOnGraph's empty guard
        // silently no-ops — which used to strand the camera at its default
        // orbit ON the origin for the whole session. Keep the immediate
        // call (covers relaunch-with-cache), then retry until data exists
        // so the fit-the-whole-sky framing actually runs.
        mgr.camera.centerOnGraph(positions: galaxyRegistry.mergedPositions)
        if galaxyRegistry.mergedPositions.isEmpty {
            let registry = galaxyRegistry
            Task { @MainActor [weak mgr] in
                for _ in 0..<120 {   // up to ~60s of load time
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let mgr else { return }
                    let positions = registry.mergedPositions
                    if !positions.isEmpty {
                        mgr.camera.centerOnGraph(positions: positions)
                        return
                    }
                }
            }
        }
    }

    private func pushDataToRKScene() {
        guard let rk = rkSceneManager else { return }
        rk.layoutMode = layoutMode
        rk.showMascots = showMascots
        rk.semanticClusters3D = semanticClusters3D
    }

    // MARK: - RK Gestures

    @GestureState private var rkDragStart: (azimuth: Float, elevation: Float, camPos: SIMD3<Float>)?

    private var rkOrbitGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($rkDragStart) { value, state, _ in
                guard let rk = rkSceneManager else { return }
                if state == nil {
                    state = rk.captureLookState()
                }
                guard let start = state else { return }
                let sensitivity: Float = 0.005
                let dw = Float(value.translation.width)
                let dh = Float(value.translation.height)
                rk.applyLookDrag(start: start, dx: dw * sensitivity, dy: -dh * sensitivity)
            }
            .onEnded { _ in
                rkSceneManager?.endDrag()
            }
    }

    private func rkTapGesture(viewSize: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard let rk = rkSceneManager else { return }
                if rk.hitTestMascot(at: value.location, viewSize: viewSize) {
                    toggleMascotChat()
                    return
                }
                if let nodeId = rk.hitTest(at: value.location, viewSize: viewSize) {
                    if renderStore.hubs.contains(nodeId) {
                        if selectedNode == nodeId {
                            selectedNode = nil
                        } else {
                            selectedNode = nodeId
                        }
                    } else {
                        selectedNode = (selectedNode == nodeId) ? nil : nodeId
                    }
                    rk.selectionCallback?(selectedNode)
                } else {
                    selectedNode = nil
                    rk.selectionCallback?(nil)
                }
            }
    }

    // Metal renderer removed — all rendering goes through EngramRealityKit.

    private func toggleMascotChat() {
        if isMascotChatOpen {
            isMascotChatOpen = false
            // Mascot chat exit handled by RKMascotSystem
            // Clear sessions so next open starts fresh — prevents
            // response session context from accumulating across conversations
            if #available(macOS 26.0, *),
               let engine = mascotChatEngine as? MascotChatEngine {
                engine.reset()
            }
            mascotChatEngine = nil
        } else {
            isMascotChatOpen = true
            // Mascot chat enter handled by RKMascotSystem
            if #available(macOS 26.0, *) {
                setupChatEngineIfNeeded()
            }
        }
    }

    private func setupChatEngineIfNeeded() {
        if #available(macOS 26.0, *) {
            if mascotChatEngine == nil {
                let engine = MascotChatEngine()
                mascotChatEngine = engine
                let store = renderStore
                let binding = $selectedNode
                Task {
                    await engine.setup(
                        lattice: lattice,
                        renderStore: store,
                        selectedMemoryId: { binding.wrappedValue }
                    )
                }
            }
        }
    }

    // MARK: - Gestures

    // MARK: - Reticle (gamepad targeting)

    @ViewBuilder
    private var reticleOverlay: some View {
        let reticleTarget = self.reticleTarget
        let hasTarget = reticleTarget != nil
        let targetNode = reticleTarget.flatMap { galaxyRegistry.node(for: $0) }

        ZStack {
            // Crosshair lines
            let size: CGFloat = hasTarget ? 20 : 14
            let color: Color = hasTarget ? .white : .white.opacity(0.4)
            let thickness: CGFloat = hasTarget ? 1.5 : 1

            // Horizontal line with gap
            HStack(spacing: hasTarget ? 8 : 6) {
                Rectangle().frame(width: size, height: thickness)
                Rectangle().frame(width: size, height: thickness)
            }
            .foregroundStyle(color)

            // Vertical line with gap
            VStack(spacing: hasTarget ? 8 : 6) {
                Rectangle().frame(width: thickness, height: size)
                Rectangle().frame(width: thickness, height: size)
            }
            .foregroundStyle(color)

            // Center dot when targeting
            if hasTarget {
                Circle()
                    .frame(width: 4, height: 4)
                    .foregroundStyle(.white)
            }

            // Target label below reticle
            if let node = targetNode {
                Text(node.label)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.5), in: .capsule)
                    .offset(y: 30)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: hasTarget)
    }

    // MARK: - Trackpad input (scroll → strafe, pinch → dolly toward cursor)

    @State private var viewFrame: NSRect = .zero

    /// Keys tracked for continuous WASD/IJKL/QE movement.
    private static let movementKeys: Set<String> = ["w","a","s","d","i","j","k","l","q","e"]

    private func installInputMonitor() {
        // Scene-specific closures — capture the right scene reference once
        let heldKeys: (Bool, String) -> Void   // (insert, key) — insert=true inserts, false removes
        let clearKeys: () -> Void
        let teleport: (Int) -> Void
        let galaxyTeleport: (Int) -> Void
        let lookRotate: (Float, Float) -> Void
        let dolly: (Float) -> Void
        let dollyAt: (Float, Float, Float) -> Void  // (amount, cursorNX, cursorNY)
        let pan: (Float, Float) -> Void

        if let rk = rkSceneManager {
            let cam = rk.camera
            heldKeys = { insert, key in if insert { cam.heldKeys.insert(key) } else { cam.heldKeys.remove(key) } }
            clearKeys = { cam.heldKeys.removeAll() }
            teleport = { direction in rk.teleportToNextProject(direction: direction) }
            galaxyTeleport = { direction in rk.teleportToNextGalaxy(direction: direction) }
            lookRotate = { dAz, dEl in cam.lookRotate(deltaAz: dAz, deltaEl: dEl) }
            dolly = { amount in cam.dolly(amount: amount) }
            dollyAt = { amount, nx, ny in cam.dolly(amount: amount, cursorNX: nx, cursorNY: ny) }
            pan = { dx, dy in cam.pan(dx: dx, dy: dy) }
        } else {
            heldKeys = { _, _ in }
            clearKeys = { }
            teleport = { _ in }
            galaxyTeleport = { _ in }
            lookRotate = { _, _ in }
            dolly = { _ in }
            dollyAt = { _, _, _ in }
            pan = { _, _ in }
        }

        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .rotate, .keyDown, .keyUp, .flagsChanged]) { event in
            // Shift tracking
            if event.type == .flagsChanged {
                heldKeys(event.modifierFlags.contains(.shift), "shift")
                return event
            }

            // Key events
            if event.type == .keyDown || event.type == .keyUp {
                if let responder = event.window?.firstResponder,
                   responder is NSTextView || responder is NSTextField {
                    clearKeys()
                    return event
                }

                let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
                let noMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    .subtracting(.shift).isEmpty

                if event.type == .keyDown {
                    if noMods && Self.movementKeys.contains(key) {
                        heldKeys(true, key)
                        return nil
                    }
                    if key == "t" && noMods { teleport(1); return nil }
                    if key == "r" && noMods { teleport(-1); return nil }
                    if key == "]" && noMods { galaxyTeleport(1); return nil }
                    if key == "[" && noMods { galaxyTeleport(-1); return nil }
                } else {
                    if Self.movementKeys.contains(key) {
                        heldKeys(false, key)
                        return nil
                    }
                }
                return event
            }

            // Let scroll events pass through to overlay ScrollViews
            if let contentView = event.window?.contentView {
                let hitView = contentView.hitTest(event.locationInWindow)
                if hitView is NSScrollView || hitView?.enclosingScrollView != nil {
                    return event
                }
            }

            if event.type == .rotate {
                lookRotate(-Float(event.rotation) * 0.02, 0)
                return nil
            }
            if event.type == .magnify {
                let amount = Float(event.magnification) * 400
                guard event.window != nil else { dolly(amount); return nil }
                let loc = event.locationInWindow
                let nx = Float((loc.x - self.viewFrame.origin.x) / self.viewFrame.width - 0.5) * 2
                let ny = Float((loc.y - self.viewFrame.origin.y) / self.viewFrame.height - 0.5) * 2
                dollyAt(amount, nx, ny)
                return nil
            }

            pan(Float(event.scrollingDeltaX), Float(event.scrollingDeltaY))
            return nil
        }
    }

    private func removeInputMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
        // CameraController handles keyboard state
    }

    private func collapseAllHubs() {
        // Hub expansion handled by RKSceneManager.hubExpansion
    }

    /// Pin/unpin hub children in the force simulation.
    private func pinUnpinHubChildren(hubId: UUID, expanding: Bool) {
        let children = renderStore.edges.filter { $0.relation == "part_of" && $0.targetId == hubId }.map(\.sourceId)
        for childId in children {
            if expanding { simulation3D.pin(childId) } else { simulation3D.unpin(childId) }
        }
    }

}
