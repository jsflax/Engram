import Foundation
import simd

/// Geometry/appearance depend on graph state, not which camera-visible edges
/// happen to occupy GPU slots this frame. Keep values indexed by the current
/// edge ordering and lazily refresh only the edges that become visible.
struct EdgeInstanceValueCache {
    struct Value {
        let transform: simd_float4x4
        let color: SIMD4<Float16>
        static let hidden = Value(transform: matrix_identity_float4x4 * 0, color: .zero)
    }

    private struct Inputs: Equatable {
        let topology: UInt64
        let positions: UInt64
        let selection: UUID?
        let search: Set<UUID>
        let searchActive: Bool
        let colors: [String: SIMD3<Float>]
        let scale: Float

        init(_ state: BatchRenderState) {
            topology = state.topology
            positions = state.positions
            selection = state.selection
            search = state.search
            searchActive = state.searchActive
            colors = state.colors
            scale = state.scale
        }
    }

    private var inputs: Inputs?
    private var generation: UInt64 = 0
    private var generations: [UInt64] = []
    private var values: [Value] = []

    mutating func prepare(state: BatchRenderState, count: Int) {
        let next = Inputs(state)
        if next != inputs {
            generation &+= 1
            if generation == 0 {
                generation = 1
                generations = Array(repeating: 0, count: generations.count)
            }
            inputs = next
        }
        if count > values.count {
            values.append(contentsOf: repeatElement(.hidden, count: count - values.count))
            generations.append(contentsOf: repeatElement(0, count: count - generations.count))
        } else if count < values.count {
            values.removeLast(values.count - count)
            generations.removeLast(generations.count - count)
        }
    }

    mutating func value(at index: Int, makeValue: () -> Value) -> Value {
        if generations[index] != generation {
            values[index] = makeValue()
            generations[index] = generation
        }
        return values[index]
    }
}
