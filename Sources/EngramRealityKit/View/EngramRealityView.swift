import SwiftUI
import RealityKit

/// SwiftUI view wrapping the RealityKit scene.
///
/// Uses RealityView for setup and SceneEvents.Update for per-frame updates.
/// All rendering logic lives in EngramRealityScene — this view just hosts it.
public struct EngramRealityView: View {
    let scene: EngramRealityScene

    public init(scene: EngramRealityScene) {
        self.scene = scene
    }

    public var body: some View {
        RealityView { content in
            let root = scene.setup()
            content.add(root)

            // RealityKit supplies this delta. Opt-in scene diagnostics measure
            // callback spacing separately; neither value proves presentation time.
            content.subscribe(to: SceneEvents.Update.self) { event in
                let dt = Float(event.deltaTime)
                scene.update(dt: dt)
            }
        }
        .transaction { $0.animation = nil }  // Prevent overlay animations from resizing
    }
}
