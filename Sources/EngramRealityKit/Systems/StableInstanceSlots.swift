import Foundation

/// Keeps identity attached to the same GPU slot across LOD and topology changes.
/// Reuses scratch storage and skips rebuilding the mapping when visibility is stable.
struct StableInstanceSlots {
    private var slotByID: [UUID: Int] = [:]
    private var visibleIDs: Set<UUID> = []
    private var removedIDs: [UUID] = []
    private var freeSlots: [Int] = []
    private var occupied: [Bool] = []
    /// Lazily initialized only after topology/capacity settle. Include
    /// overflow inputs, not merely the subset assigned GPU slots.
    private var idByIndex: [UUID?] = []
    private var slotByIndex: [Int] = []
    private var indexVisible: [Bool] = []
    private var activeIndices: [Int] = []
    private var denseCacheReady = false
    private var identityScratch: [UUID] = []
    private var previousIndices: [Int] = []
    private var previousTopology: UInt64 = .max
    private var previousCapacity = -1
    private(set) var highWater = 0
    private(set) var writes: [(slot: Int, index: Int)] = []
    private(set) var holes: [Int] = []
    var cachedSourceIndexCount: Int { activeIndices.count }
    var denseSourceStorageCount: Int { idByIndex.count }

    mutating func update(indices: [Int], topology: UInt64, capacity: Int,
                         idAtIndex: (Int) -> UUID) {
        guard topology != previousTopology || capacity != previousCapacity || indices != previousIndices else { return }
        let canUseIndices = topology == previousTopology && capacity == previousCapacity
        if canUseIndices,
           prepareDenseCache(indices: indices, capacity: capacity),
           updateStableIndices(indices: indices, capacity: capacity, idAtIndex: idAtIndex) {
            previousIndices = indices
            return
        }

        invalidateDenseCache(capacity: capacity)
        updateByIdentity(indices: indices, capacity: capacity, idAtIndex: idAtIndex)
        previousTopology = topology
        previousCapacity = capacity
        previousIndices = indices
    }

    /// Full reconciliation does not build dense index caches while topology
    /// churns. Save the IDs once for the allocation pass and lazy cache setup.
    private mutating func updateByIdentity(indices: [Int], capacity: Int,
                                           idAtIndex: (Int) -> UUID) {
        identityScratch.removeAll(keepingCapacity: true)
        visibleIDs.removeAll(keepingCapacity: true)
        for index in indices {
            let id = idAtIndex(index)
            identityScratch.append(id)
            visibleIDs.insert(id)
        }
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
        for (index, id) in zip(indices, identityScratch) {
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

    /// A sparse provider must remain correct without allocating to its largest
    /// index. The absolute cap also bounds retained peak storage after churn.
    private func denseLimit(capacity: Int) -> Int {
        let (scaled, overflow) = capacity.multipliedReportingOverflow(by: 32)
        return min(1_048_576, max(65_536, overflow ? 65_536 : scaled))
    }

    private mutating func invalidateDenseCache(capacity: Int) {
        for index in activeIndices {
            idByIndex[index] = nil
            slotByIndex[index] = -1
            indexVisible[index] = false
        }
        activeIndices.removeAll(keepingCapacity: true)
        denseCacheReady = false
        if idByIndex.count > denseLimit(capacity: capacity) {
            idByIndex = []
            slotByIndex = []
            indexVisible = []
        }
    }

    private mutating func prepareDenseCache(indices: [Int], capacity: Int) -> Bool {
        let limit = denseLimit(capacity: capacity)
        var required = 0
        for index in indices {
            guard index >= 0, index < limit else { return false }
            required = max(required, index + 1)
        }
        if !denseCacheReady {
            for index in previousIndices {
                guard index >= 0, index < limit else { return false }
                required = max(required, index + 1)
            }
        }
        if required > idByIndex.count {
            let count = min(limit, max(required, max(1024, idByIndex.count * 2)))
            let growth = count - idByIndex.count
            idByIndex.append(contentsOf: repeatElement(nil, count: growth))
            slotByIndex.append(contentsOf: repeatElement(-1, count: growth))
            indexVisible.append(contentsOf: repeatElement(false, count: growth))
        }
        guard !denseCacheReady else { return true }
        for (index, id) in zip(previousIndices, identityScratch) where idByIndex[index] == nil {
            idByIndex[index] = id
            activeIndices.append(index)
        }
        // The full path's UUID set detects different-index aliases without
        // introducing another hashed map. Duplicate occurrences of one index
        // are harmless and still produce complete input-order writes.
        guard activeIndices.count == visibleIDs.count else { return false }
        for write in writes { slotByIndex[write.index] = write.slot }
        denseCacheReady = true
        return true
    }

    /// UUID hashing is proportional to membership churn, not the entire
    /// visible set. Pure reordering needs no identity callbacks or UUID map
    /// lookups, including when the input is larger than the GPU capacity.
    private mutating func updateStableIndices(indices: [Int], capacity: Int,
                                              idAtIndex: (Int) -> UUID) -> Bool {
        for index in indices {
            indexVisible[index] = true
            guard idByIndex[index] == nil else { continue }
            let id = idAtIndex(index)
            // A new index may alias an old (even departing) identity. Do not
            // change slots until validation finishes; the full path preserves
            // UUID identity and duplicate-input behavior in that case.
            guard visibleIDs.insert(id).inserted else {
                indexVisible[index] = false
                return false
            }
            idByIndex[index] = id
            activeIndices.append(index)
        }

        for slot in occupied.indices { occupied[slot] = false }
        var retainedCount = 0
        for readIndex in activeIndices.indices {
            let index = activeIndices[readIndex]
            if indexVisible[index] {
                activeIndices[retainedCount] = index
                retainedCount += 1
                indexVisible[index] = false
                let slot = slotByIndex[index]
                if slot >= 0 { occupied[slot] = true }
            } else {
                visibleIDs.remove(idByIndex[index]!)
                idByIndex[index] = nil
                slotByIndex[index] = -1
            }
        }
        activeIndices.removeLast(activeIndices.count - retainedCount)
        removedIDs.removeAll(keepingCapacity: true)
        // Match the full path's release/reuse order. Iterating UUID entries
        // does not hash their keys; only departed keys need dictionary writes.
        for (id, slot) in slotByID where !occupied[slot] {
            removedIDs.append(id)
            freeSlots.append(slot)
        }
        for id in removedIDs { slotByID.removeValue(forKey: id) }

        writes.removeAll(keepingCapacity: true)
        for index in indices {
            let slot: Int
            if slotByIndex[index] >= 0 { slot = slotByIndex[index] }
            else if let reused = freeSlots.popLast() { slot = reused }
            else if highWater < capacity {
                slot = highWater
                highWater += 1
            } else { continue }
            if slotByIndex[index] < 0 {
                slotByIndex[index] = slot
                slotByID[idByIndex[index]!] = slot
            }
            occupied[slot] = true
            writes.append((slot, index))
        }
        holes.removeAll(keepingCapacity: true)
        for slot in 0..<highWater where !occupied[slot] { holes.append(slot) }
        return true
    }
}

/// Inputs that affect node/edge GPU data. Camera effects enter through visibility;
/// time enters through live glow values, keeping animations active while idle.
struct BatchRenderState: Equatable {
    let topology: UInt64
    let positions: UInt64
    let visibleIndices: [Int]
    let selection: UUID?
    let search: Set<UUID>
    let searchActive: Bool
    let colors: [String: SIMD3<Float>]
    let scale: Float
    var dying: Set<UUID> = []
    var recall: [UUID: Float] = [:]
    var arrival: [UUID: Float] = [:]
}
