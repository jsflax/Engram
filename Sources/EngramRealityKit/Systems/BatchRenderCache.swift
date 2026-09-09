/// Records only completed uploads. A failed allocation or encoder acquisition
/// must leave the same frame eligible for retry when the graph is otherwise idle.
@MainActor
final class BatchRenderCache {
    private var completedState: BatchRenderState?

    func update(_ state: BatchRenderState, render: () -> Bool) {
        guard state != completedState else { return }
        // An unsuccessful pass may already have changed transforms before a
        // texture upload failed. Even reverting to the old inputs must redraw.
        completedState = nil
        if render() { completedState = state }
    }
}
