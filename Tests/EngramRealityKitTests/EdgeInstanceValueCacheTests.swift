import Foundation
import simd
import Testing
@testable import EngramRealityKit

@Suite("Cached edge instance values")
struct EdgeInstanceValueCacheTests {
    private func state(topology: UInt64 = 1, positions: UInt64 = 1,
                       visible: [Int] = [0], selection: UUID? = nil,
                       search: Set<UUID> = [], searchActive: Bool = false,
                       colors: [String: SIMD3<Float>] = [:], scale: Float = 1) -> BatchRenderState {
        BatchRenderState(topology: topology, positions: positions, visibleIndices: visible,
                         selection: selection, search: search, searchActive: searchActive,
                         colors: colors, scale: scale)
    }

    @Test("Camera visibility changes reuse existing values and lazily fill newly exposed edges")
    func visibilityChurnReusesValues() {
        var cache = EdgeInstanceValueCache()
        var calculations = 0
        func build() -> EdgeInstanceValueCache.Value {
            calculations += 1
            return .hidden
        }
        cache.prepare(state: state(visible: [1]), count: 4)
        _ = cache.value(at: 1, makeValue: build)
        cache.prepare(state: state(visible: [3, 1]), count: 4)
        _ = cache.value(at: 1, makeValue: build)
        _ = cache.value(at: 3, makeValue: build)
        cache.prepare(state: state(visible: [1]), count: 4)
        _ = cache.value(at: 1, makeValue: build)
        #expect(calculations == 2)
    }

    @Test("Graph revisions, selection, search, colors and scale each invalidate edge values")
    func contentInputsInvalidate() {
        let nodeID = UUID()
        let changes = [
            state(topology: 2), state(positions: 2), state(selection: nodeID),
            state(search: [nodeID]), state(searchActive: true),
            state(colors: ["project": SIMD3(1, 0, 0)]), state(scale: 2),
        ]
        for changed in changes {
            var cache = EdgeInstanceValueCache()
            var calculations = 0
            func build() -> EdgeInstanceValueCache.Value {
                calculations += 1
                return EdgeInstanceValueCache.Value(transform: matrix_identity_float4x4,
                                                    color: SIMD4(repeating: Float16(calculations)))
            }
            cache.prepare(state: state(), count: 1)
            let original = cache.value(at: 0, makeValue: build)
            cache.prepare(state: changed, count: 1)
            let refreshed = cache.value(at: 0, makeValue: build)
            let repeated = cache.value(at: 0, makeValue: build)
            #expect(calculations == 2)
            #expect(original.color != refreshed.color)
            #expect(refreshed.color == repeated.color)
        }
    }

    @Test("Removed indices cannot reuse old values when the edge array grows again")
    func removedIndicesDoNotLeakValues() {
        var cache = EdgeInstanceValueCache()
        var calculations = 0
        cache.prepare(state: state(), count: 3)
        _ = cache.value(at: 2) { calculations += 1; return .hidden }
        cache.prepare(state: state(), count: 1)
        cache.prepare(state: state(), count: 3)
        _ = cache.value(at: 2) { calculations += 1; return .hidden }
        #expect(calculations == 2)
    }
}
