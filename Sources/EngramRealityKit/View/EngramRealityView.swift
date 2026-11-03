import SwiftUI
import RealityKit

/// SwiftUI view wrapping the RealityKit scene.
///
/// Uses RealityView for setup and SceneEvents.Update for per-frame updates.
/// All rendering logic lives in EngramRealityScene — this view just hosts it.
public struct EngramRealityView: View {
    let scene: EngramRealityScene
    let isActive: Bool
    @State private var isMounted = true

    public init(scene: EngramRealityScene, isActive: Bool = true) {
        self.scene = scene
        self.isActive = isActive
    }

    public var body: some View {
        RealityView { content in
            let root = scene.setup()
            content.add(root)

            scene.setRenderingActive(isActive && isMounted)
            scene.installFrameSubscription {
                content.subscribe(to: SceneEvents.Update.self) { [weak scene] event in
                    scene?.update(dt: Float(event.deltaTime))
                }
            }
        } update: { content in
            scene.setRenderingActive(isActive && isMounted)
            scene.installFrameSubscription {
                content.subscribe(to: SceneEvents.Update.self) { [weak scene] event in
                    scene?.update(dt: Float(event.deltaTime))
                }
            }
        }
        // The graph's white atlas labels and emissive materials belong to Engram's
        // dark canvas, independently of the embedding app's control appearance.
        // RealityView's default environment consumes backgroundStyle; a colored
        // sibling behind the view does not configure its rendered background.
        .backgroundStyle(Color(red: 0.051, green: 0.067, blue: 0.09))
        .onAppear { isMounted = true }
        .onDisappear { isMounted = false; scene.setRenderingActive(false) }
        .transaction { $0.animation = nil }  // Prevent overlay animations from resizing
    }
}
