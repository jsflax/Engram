import SwiftUI
import RealityKit

/// The original renderer with an explicit visible/foreground lifetime.
/// The owner calls scene.teardown() when its graph authorization scope ends.
@MainActor public struct EngramRealityView: View {
    let scene: EngramRealityScene
    let isActive: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var frames = FrameSubscription()
    @State private var appeared = false

    public init(scene: EngramRealityScene, isActive: Bool = true) {
        self.scene = scene; self.isActive = isActive
    }
    private var shouldRender: Bool { appeared && isActive && scenePhase == .active && !scene.isTornDown }
    public var body: some View {
        RealityView { content in
            content.camera = .virtual
            let root = scene.setup()
            // Keep the public content handle, never the inout make argument.
            // Entity.removeFromParent does not remove a top-level content entity.
            let contentHandle = content
            frames.configure(scene: scene, add: { contentHandle.add(root) },
                remove: { contentHandle.remove(root) }) { [weak scene] in
                    contentHandle.subscribe(to: SceneEvents.Update.self) { [weak scene] event in
                        scene?.update(dt: Float(event.deltaTime))
                    }
                }
            frames.attach()
            scene.stopFrameSubscription = { [weak frames] in frames?.stop() }
            synchronize()
        }
        .onAppear { appeared = true; EngramRenderLifecycleDiagnostic.record(.realityAppeared, snapshot: scene.renderDiagnosticSnapshot()); synchronize() }
        .onDisappear {
            EngramRenderLifecycleDiagnostic.record(.realityDisappearing, snapshot: scene.renderDiagnosticSnapshot())
            appeared = false; frames.detach(); scene.setActive(false)
        }
        .onChange(of: isActive) { _, _ in synchronize() }
        .onChange(of: scenePhase) { _, _ in synchronize() }
        .transaction { $0.animation = nil }
    }
    private func synchronize() {
        EngramRenderLifecycleDiagnostic.record(.realitySynchronized, snapshot: scene.renderDiagnosticSnapshot(),
            flags: ["appeared": appeared, "hostActive": isActive, "scenePhaseActive": scenePhase == .active, "shouldRender": shouldRender])
        scene.setActive(shouldRender)
        if shouldRender { frames.attach(); frames.start() } else { frames.stop() }
    }
}

@MainActor private final class FrameSubscription {
    private var scene: EngramRealityScene?
    private var add: (() -> Void)?
    private var remove: (() -> Void)?
    private var factory: (() -> EventSubscription)?
    private var subscription: EventSubscription?
    private var attachment: UUID?

    func configure(scene: EngramRealityScene, add: @escaping () -> Void,
                   remove: @escaping () -> Void, factory: @escaping () -> EventSubscription) {
        detach()
        self.scene = scene; self.add = add; self.remove = remove; self.factory = factory
    }
    func attach() {
        guard attachment == nil, let scene, !scene.isTornDown, let remove else { return }
        add?()
        attachment = scene.registerContentHost(detach: remove)
    }
    func detach() {
        stop()
        if let attachment { scene?.removeContentHost(attachment) }
        attachment = nil
        if scene?.isTornDown == true {
            scene = nil; add = nil; remove = nil; factory = nil
        }
    }
    func start() {
        guard let scene, !scene.isTornDown, attachment != nil else { return }
        if subscription == nil { subscription = factory?() }
    }
    func stop() { subscription?.cancel(); subscription = nil }
}
