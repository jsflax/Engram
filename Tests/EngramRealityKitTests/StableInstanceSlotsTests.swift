import Foundation
import Testing
@testable import EngramRealityKit

struct StableInstanceSlotsTests {
    @Test("Retained identities keep slots across visibility churn and topology reorder")
    func stableSlots() {
        var slots = StableInstanceSlots()
        let a = UUID(), b = UUID(), c = UUID()
        var ids = [a, b, c]
        slots.update(indices: [0, 1], topology: 1, capacity: 3, idAtIndex: { ids[$0] })
        let aSlot = slots.writes.first { $0.index == 0 }!.slot
        let bSlot = slots.writes.first { $0.index == 1 }!.slot
        slots.update(indices: [2, 1], topology: 1, capacity: 3, idAtIndex: { ids[$0] })
        #expect(slots.writes.first { $0.index == 1 }?.slot == bSlot)
        #expect(slots.writes.first { $0.index == 2 }?.slot == aSlot)
        ids = [c, b, a]
        slots.update(indices: [1, 0], topology: 2, capacity: 3, idAtIndex: { ids[$0] })
        #expect(slots.writes.first { $0.index == 1 }?.slot == bSlot)
        #expect(slots.writes.first { $0.index == 0 }?.slot == aSlot)
        slots.update(indices: [], topology: 2, capacity: 3, idAtIndex: { ids[$0] })
        #expect(slots.writes.isEmpty)
        #expect(slots.holes.count == 2)
    }

    @Test("Capacity shrink drops out-of-range slots and growth recovers all nodes")
    func capacityChanges() {
        var slots = StableInstanceSlots()
        let ids = [UUID(), UUID(), UUID()]
        slots.update(indices: [0, 1, 2], topology: 1, capacity: 3, idAtIndex: { ids[$0] })
        slots.update(indices: [0, 1, 2], topology: 1, capacity: 1, idAtIndex: { ids[$0] })
        #expect(slots.writes.count == 1)
        #expect(slots.highWater == 1)
        slots.update(indices: [0, 1, 2], topology: 1, capacity: 3, idAtIndex: { ids[$0] })
        #expect(Set(slots.writes.map(\.slot)).count == 3)
    }

    @Test("Stable input and reorder-only overflow never request UUIDs again")
    func indexOnlyReordering() {
        var slots = StableInstanceSlots()
        let ids = (0..<5).map { _ in UUID() }
        var callbacks = 0
        func identity(_ index: Int) -> UUID { callbacks += 1; return ids[index] }
        slots.update(indices: [0, 1, 2, 3, 4], topology: 1, capacity: 2, idAtIndex: identity)
        let original = slots.writes
        callbacks = 0
        slots.update(indices: [0, 1, 2, 3, 4], topology: 1, capacity: 2, idAtIndex: identity)
        #expect(callbacks == 0)
        slots.update(indices: [4, 3, 2, 1, 0], topology: 1, capacity: 2, idAtIndex: identity)
        #expect(callbacks == 0)
        #expect(slots.writes.map(\.index) == [1, 0])
        #expect(slots.writes.first { $0.index == 0 }?.slot == original[0].slot)
        #expect(slots.writes.first { $0.index == 1 }?.slot == original[1].slot)
        #expect(slots.cachedSourceIndexCount == 5)

        // Unassigned inputs still participate in membership. They take a
        // departed slot in input order, without displacing a retained item.
        slots.update(indices: [4, 3, 2, 1], topology: 1, capacity: 2, idAtIndex: identity)
        #expect(callbacks == 0)
        #expect(slots.writes.map(\.index) == [4, 1])
        #expect(slots.writes.first { $0.index == 1 }?.slot == original[1].slot)
        #expect(slots.holes.isEmpty)
    }

    @Test("A topology revision resolves same-count replacements beyond the prefix")
    func replacementInvalidatesIndexIdentity() {
        var slots = StableInstanceSlots()
        var ids = (0..<4).map { _ in UUID() }
        slots.update(indices: [0, 1, 2, 3], topology: 1, capacity: 4, idAtIndex: { ids[$0] })
        let retained = slots.writes.first { $0.index == 1 }!.slot
        let replacementSlot = slots.writes.first { $0.index == 3 }!.slot
        ids[3] = UUID()
        var callbacks = 0
        slots.update(indices: [0, 1, 2, 3], topology: 2, capacity: 4, idAtIndex: {
            callbacks += 1
            return ids[$0]
        })
        #expect(callbacks == 4)
        #expect(slots.writes.first { $0.index == 1 }?.slot == retained)
        #expect(slots.writes.first { $0.index == 3 }?.slot == replacementSlot)
        #expect(slots.cachedSourceIndexCount == 0)
    }

    @Test("Duplicate indices and identity aliases preserve UUID slot behavior")
    func duplicateInputs() {
        var slots = StableInstanceSlots()
        let a = UUID(), b = UUID()
        let ids = [a, a, b]
        slots.update(indices: [0, 0, 2], topology: 1, capacity: 2, idAtIndex: { ids[$0] })
        let aSlot = slots.writes[0].slot
        #expect(slots.writes.map(\.index) == [0, 0, 2])
        #expect(slots.writes[1].slot == aSlot)
        slots.update(indices: [1, 2], topology: 1, capacity: 2, idAtIndex: { ids[$0] })
        #expect(slots.writes[0].slot == aSlot)
        slots.update(indices: [0, 1, 2], topology: 1, capacity: 2, idAtIndex: { ids[$0] })
        #expect(slots.writes.map(\.index) == [0, 1, 2])
        #expect(slots.writes[0].slot == slots.writes[1].slot)
        #expect(slots.holes.isEmpty)
        #expect(slots.cachedSourceIndexCount == 0)
    }

    @Test("Index identity storage stays bounded by current visibility during long churn")
    func boundedIndexCache() {
        var slots = StableInstanceSlots()
        let ids = (0..<6000).map { _ in UUID() }
        for start in stride(from: 0, through: ids.count - 15, by: 3) {
            let indices = Array(start..<(start + 15))
            slots.update(indices: indices, topology: 1, capacity: 7, idAtIndex: { ids[$0] })
            #expect(slots.cachedSourceIndexCount <= 15)
            #expect(slots.denseSourceStorageCount <= 65_536)
            #expect(slots.writes.count == 7)
        }
        slots.update(indices: [], topology: 1, capacity: 7, idAtIndex: { ids[$0] })
        #expect(slots.cachedSourceIndexCount == 0)
        #expect(slots.writes.isEmpty)
        #expect(slots.holes == Array(0..<slots.highWater))
    }

    @Test("Random churn matches the original UUID reconciler's complete output invariants")
    func randomizedReferenceComparison() {
        var slots = StableInstanceSlots()
        var reference = ReferenceInstanceSlots()
        var random = SlotTestRandom()
        var ids = (0..<40).map { _ in UUID() }
        var topology: UInt64 = 1
        var capacity = 12
        var previousSlotByID: [UUID: Int] = [:]
        var previousReferenceSlotByID: [UUID: Int] = [:]
        for step in 0..<1500 {
            if step.isMultiple(of: 17) {
                ids.swapAt(random.next(ids.count), random.next(ids.count))
                topology += 1
            }
            if step.isMultiple(of: 23) {
                ids[random.next(ids.count)] = UUID()
                topology += 1
            }
            if step.isMultiple(of: 29) { ids.append(UUID()); topology += 1 }
            if step.isMultiple(of: 31), ids.count > 16 {
                ids.remove(at: random.next(ids.count))
                topology += 1
            }
            if step.isMultiple(of: 37) {
                let source = random.next(ids.count), destination = random.next(ids.count)
                ids[destination] = ids[source]
                topology += 1
            }
            if step.isMultiple(of: 5) { capacity = random.next(13) }
            let indices = (0..<random.next(27)).map { _ in random.next(ids.count) }
            func expectedIndices(previousSlots: [UUID: Int]) -> [Int] {
                let visibleIDs = Set(indices.map { ids[$0] })
                var assignedIDs = Set(previousSlots.compactMap { id, slot in
                    slot < capacity && visibleIDs.contains(id) ? id : nil
                })
                for index in indices where assignedIDs.count < capacity { assignedIDs.insert(ids[index]) }
                return indices.filter { assignedIDs.contains(ids[$0]) }
            }
            let expected = expectedIndices(previousSlots: previousSlotByID)
            let expectedReference = expectedIndices(previousSlots: previousReferenceSlotByID)
            slots.update(indices: indices, topology: topology, capacity: capacity, idAtIndex: { ids[$0] })
            reference.update(indices: indices, topology: topology, capacity: capacity, idAtIndex: { ids[$0] })

            // Dictionary iteration can choose a different free-slot order in
            // separate instances, affecting which IDs survive a later shrink.
            // Check both against their own prior assignments. Exact traversal
            // must also agree when the old mapping agrees or everything fits.
            #expect(slots.writes.map(\.index) == expected)
            #expect(reference.writes.map(\.index) == expectedReference)
            if previousSlotByID == previousReferenceSlotByID || Set(indices.map { ids[$0] }).count <= capacity {
                #expect(slots.writes.map(\.index) == reference.writes.map(\.index))
            }
            #expect(slots.highWater == reference.highWater)
            #expect(slots.holes.count == reference.holes.count)
            #expect(slots.cachedSourceIndexCount <= Set(indices).count)
            let occupied = Set(slots.writes.map(\.slot))
            #expect(occupied.isDisjoint(with: slots.holes))
            #expect(occupied.union(slots.holes) == Set(0..<slots.highWater))
            #expect(slots.highWater <= capacity)
            var currentSlotByID: [UUID: Int] = [:]
            var currentIDBySlot: [Int: UUID] = [:]
            for write in slots.writes {
                let id = ids[write.index]
                #expect(write.slot >= 0 && write.slot < capacity)
                if let sameSlot = currentSlotByID[id] { #expect(sameSlot == write.slot) }
                if let sameID = currentIDBySlot[write.slot] { #expect(sameID == id) }
                if let retainedSlot = previousSlotByID[id], retainedSlot < capacity {
                    #expect(retainedSlot == write.slot)
                }
                currentSlotByID[id] = write.slot
                currentIDBySlot[write.slot] = id
            }
            previousSlotByID = currentSlotByID
            previousReferenceSlotByID.removeAll(keepingCapacity: true)
            for write in reference.writes { previousReferenceSlotByID[ids[write.index]] = write.slot }
        }
    }

    @Test("Sparse, negative, and extreme indices use UUID fallback without huge storage")
    func sparseFallback() {
        var slots = StableInstanceSlots()
        let ids = [0: UUID(), 1: UUID(), 65_536: UUID(), Int.max: UUID(), -7: UUID()]
        slots.update(indices: [0, Int.max], topology: 1, capacity: 2, idAtIndex: { ids[$0]! })
        let retainedSlot = slots.writes.first { $0.index == 0 }!.slot
        slots.update(indices: [Int.max, 0], topology: 1, capacity: 2, idAtIndex: { ids[$0]! })
        #expect(slots.writes.map(\.index) == [Int.max, 0])
        #expect(slots.writes.first { $0.index == 0 }?.slot == retainedSlot)
        #expect(slots.denseSourceStorageCount == 0)
        slots.update(indices: [0, 1], topology: 1, capacity: 2, idAtIndex: { ids[$0]! })
        slots.update(indices: [1, 0], topology: 1, capacity: 2, idAtIndex: { ids[$0]! })
        #expect(slots.cachedSourceIndexCount == 2)
        for indices in [[65_536, 0], [-7, 0], [Int.max, 0]] {
            slots.update(indices: indices, topology: 1, capacity: 2, idAtIndex: { ids[$0]! })
            #expect(slots.writes.map(\.index) == indices)
            #expect(slots.writes.first { $0.index == 0 }?.slot == retainedSlot)
            #expect(slots.denseSourceStorageCount <= 65_536)
            #expect(slots.cachedSourceIndexCount == 0)
        }
    }
}

private struct SlotTestRandom {
    private var state: UInt64 = 0x5eed
    mutating func next(_ upperBound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 32) % UInt64(upperBound))
    }
}

/// The pre-fast-path implementation, retained as an independent oracle.
private struct ReferenceInstanceSlots {
    private var slotByID: [UUID: Int] = [:]
    private var visibleIDs: Set<UUID> = []
    private var removedIDs: [UUID] = []
    private var freeSlots: [Int] = []
    private var occupied: [Bool] = []
    private var previousIndices: [Int] = []
    private var previousTopology: UInt64 = .max
    private var previousCapacity = -1
    private(set) var highWater = 0
    private(set) var writes: [(slot: Int, index: Int)] = []
    private(set) var holes: [Int] = []

    mutating func update(indices: [Int], topology: UInt64, capacity: Int,
                         idAtIndex: (Int) -> UUID) {
        guard topology != previousTopology || capacity != previousCapacity || indices != previousIndices else { return }
        previousTopology = topology
        previousCapacity = capacity
        previousIndices = indices
        visibleIDs.removeAll(keepingCapacity: true)
        for index in indices { visibleIDs.insert(idAtIndex(index)) }
        removedIDs.removeAll(keepingCapacity: true)
        for (id, slot) in slotByID where !visibleIDs.contains(id) || slot >= capacity {
            removedIDs.append(id)
            if slot < capacity { freeSlots.append(slot) }
        }
        for id in removedIDs { slotByID.removeValue(forKey: id) }
        highWater = min(highWater, capacity)
        freeSlots.removeAll { $0 >= capacity }
        if occupied.count != capacity { occupied = Array(repeating: false, count: capacity) }
        else { for i in occupied.indices { occupied[i] = false } }
        writes.removeAll(keepingCapacity: true)
        for index in indices {
            let id = idAtIndex(index)
            let slot: Int
            if let existing = slotByID[id] { slot = existing }
            else if let reused = freeSlots.popLast() { slot = reused; slotByID[id] = slot }
            else if highWater < capacity {
                slot = highWater
                highWater += 1
                slotByID[id] = slot
            } else { continue }
            occupied[slot] = true
            writes.append((slot, index))
        }
        holes.removeAll(keepingCapacity: true)
        for slot in 0..<highWater where !occupied[slot] { holes.append(slot) }
    }
}
