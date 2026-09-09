/// Separates transform and appearance uploads. Tier traversal order is not a
/// geometry change when stable slots still contain the same source nodes.
@MainActor
final class NodeInstanceUploadCache {
    private var completedState: BatchRenderState?
    private var completedResourceGeneration: UInt64?
    private var sourceIndexBySlot: [Int] = []
    private var previousHighWater = -1

    func update(state: BatchRenderState, resourceGeneration: UInt64,
                capacity: Int, highWater: Int, writes: [(slot: Int, index: Int)], holes: [Int],
                upload: (_ transforms: Bool, _ appearance: Bool) -> Bool) -> Bool {
        var slotsChanged = previousHighWater != highWater
        if sourceIndexBySlot.count != capacity {
            sourceIndexBySlot = Array(repeating: -1, count: capacity)
            slotsChanged = true
        }
        for write in writes {
            if sourceIndexBySlot[write.slot] != write.index {
                sourceIndexBySlot[write.slot] = write.index
                slotsChanged = true
            }
        }
        for slot in holes where sourceIndexBySlot[slot] != -1 {
            sourceIndexBySlot[slot] = -1
            slotsChanged = true
        }
        previousHighWater = highWater

        let reset = slotsChanged || completedResourceGeneration != resourceGeneration
        let previous = completedState
        let transforms = reset || previous == nil || previous?.topology != state.topology
            || previous?.positions != state.positions || previous?.scale != state.scale
        let appearance = reset || previous == nil || previous?.topology != state.topology
            || previous?.selection != state.selection || previous?.search != state.search
            || previous?.searchActive != state.searchActive || previous?.colors != state.colors
            || previous?.dying != state.dying || previous?.recall != state.recall
            || previous?.arrival != state.arrival
        guard transforms || appearance else { return true }
        // A partial upload may already have changed GPU resources. Invalidate
        // both domains so unchanged OR reverted inputs retry safely.
        completedState = nil
        completedResourceGeneration = nil
        guard upload(transforms, appearance) else { return false }
        completedState = state
        completedResourceGeneration = resourceGeneration
        return true
    }
}
