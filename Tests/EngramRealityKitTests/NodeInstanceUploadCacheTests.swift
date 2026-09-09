import Foundation
import Testing
@testable import EngramRealityKit

@Suite("Node instance upload domains")
@MainActor
struct NodeInstanceUploadCacheTests {
    private func state(topology: UInt64 = 1, positions: UInt64 = 1, visible: [Int] = [0, 1],
                       scale: Float = 1, selection: UUID? = nil, search: Set<UUID> = [],
                       searchActive: Bool = false, colors: [String: SIMD3<Float>] = [:],
                       dying: Set<UUID> = [], recall: [UUID: Float] = [:], arrival: [UUID: Float] = [:]) -> BatchRenderState {
        BatchRenderState(topology: topology, positions: positions, visibleIndices: visible,
                         selection: selection, search: search, searchActive: searchActive,
                         colors: colors, scale: scale, dying: dying, recall: recall, arrival: arrival)
    }

    @Test("Tier traversal reorder does not replace unchanged stable-slot resources")
    func tierReorder() {
        let cache = NodeInstanceUploadCache()
        let ids = [UUID(), UUID()]
        var slots = StableInstanceSlots()
        var uploads = 0
        for visible in [[0, 1], [1, 0], [0, 1]] {
            slots.update(indices: visible, topology: 1, capacity: 3, idAtIndex: { ids[$0] })
            let updated = cache.update(state: state(visible: visible), resourceGeneration: 1,
                                 capacity: 3, highWater: slots.highWater, writes: slots.writes, holes: slots.holes) {
                transforms, appearance in
                #expect(transforms && appearance)
                uploads += 1
                return true
            }
            #expect(updated)
        }
        #expect(uploads == 1)
    }

    @Test("Position and scale changes upload transforms but preserve appearance")
    func geometryOnly() {
        let cache = NodeInstanceUploadCache()
        let writes = [(slot: 0, index: 0), (slot: 1, index: 1)]
        #expect(cache.update(state: state(), resourceGeneration: 1, capacity: 2, highWater: 2,
                             writes: writes, holes: []) { _, _ in true })
        var uploads = 0
        for input in [state(positions: 2), state(positions: 2, scale: 0.1)] {
            let updated = cache.update(state: input, resourceGeneration: 1, capacity: 2, highWater: 2,
                                 writes: writes, holes: []) { transforms, appearance in
                #expect(transforms)
                #expect(!appearance)
                uploads += 1
                return true
            }
            #expect(updated)
        }
        #expect(uploads == 2)
    }

    @Test("Selection, search, colors, deletion and glow changes preserve geometry")
    func appearanceOnly() {
        let id = UUID()
        let inputs = [state(selection: id), state(search: [id]), state(searchActive: true),
                      state(colors: ["Project": SIMD3<Float>(1, 0, 0)]), state(dying: [id]),
                      state(recall: [id: 0.2]), state(recall: [id: 0.4]),
                      state(arrival: [id: 0.2]), state(arrival: [id: 0.4]), state()]
        let cache = NodeInstanceUploadCache()
        let writes = [(slot: 0, index: 0), (slot: 1, index: 1)]
        #expect(cache.update(state: state(), resourceGeneration: 1, capacity: 2, highWater: 2,
                             writes: writes, holes: []) { _, _ in true })
        var uploads = 0
        for input in inputs {
            let updated = cache.update(state: input, resourceGeneration: 1, capacity: 2, highWater: 2,
                                 writes: writes, holes: []) { transforms, appearance in
                #expect(!transforms)
                #expect(appearance)
                uploads += 1
                return true
            }
            #expect(updated)
        }
        #expect(uploads == inputs.count)
    }

    @Test("Holes, slot reuse and same-count topology edits invalidate both domains")
    func slotAndTopologyChanges() {
        let cache = NodeInstanceUploadCache()
        let ids = [UUID(), UUID(), UUID()]
        var slots = StableInstanceSlots()
        var uploads = 0
        for (version, visible): (UInt64, [Int]) in [(1, [0, 1]), (1, [1]), (1, [2, 1]), (2, [2, 1])] {
            slots.update(indices: visible, topology: version, capacity: 3, idAtIndex: { ids[$0] })
            let updated = cache.update(state: state(topology: version, visible: visible), resourceGeneration: 1,
                                 capacity: 3, highWater: slots.highWater, writes: slots.writes, holes: slots.holes) {
                transforms, appearance in
                #expect(transforms && appearance)
                uploads += 1
                return true
            }
            #expect(updated)
        }
        #expect(uploads == 4)
    }

    @Test("Recreated resources upload even with identical graph inputs")
    func resourceRecreation() {
        let cache = NodeInstanceUploadCache()
        var uploads = 0
        for generation: UInt64 in [1, 2] {
            let updated = cache.update(state: state(), resourceGeneration: generation, capacity: 2, highWater: 2,
                                 writes: [(0, 0), (1, 1)], holes: []) { transforms, appearance in
                #expect(transforms && appearance)
                uploads += 1
                return true
            }
            #expect(updated)
        }
        #expect(uploads == 2)
    }

    @Test("Failed uploads retry unchanged and reverted inputs across both domains")
    func retryAfterFailure() {
        for retryChangedInput in [true, false] {
            let cache = NodeInstanceUploadCache()
            let writes = [(slot: 0, index: 0), (slot: 1, index: 1)]
            #expect(cache.update(state: state(), resourceGeneration: 1, capacity: 2, highWater: 2,
                                 writes: writes, holes: []) { _, _ in true })
            #expect(!cache.update(state: state(positions: 2), resourceGeneration: 1, capacity: 2, highWater: 2,
                                  writes: writes, holes: []) { _, _ in false })
            var retried = false
            let updated = cache.update(state: state(positions: retryChangedInput ? 2 : 1), resourceGeneration: 1,
                                 capacity: 2, highWater: 2, writes: writes, holes: []) { transforms, appearance in
                #expect(transforms && appearance)
                retried = true
                return true
            }
            #expect(updated)
            #expect(retried)
        }
    }
}
