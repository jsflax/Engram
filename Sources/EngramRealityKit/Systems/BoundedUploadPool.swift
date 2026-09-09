import Foundation

/// Reuses upload storage only after its previous GPU reader has completed.
/// The small fixed slot count bounds memory; exhaustion is a retry, never a
/// wait on the render thread. Completion callbacks may release on any thread.
final class BoundedUploadPool<Resource>: @unchecked Sendable {
    struct Lease {
        let resource: Resource
        let slot: Int
        let generation: UInt64
    }

    private struct Slot {
        var resource: Resource?
        var capacity = 0
        var generation: UInt64 = 0
        var leased = false
    }

    private let lock = NSLock()
    private var slots: [Slot]

    init(capacity: Int = 3) {
        precondition(capacity > 0)
        slots = (0..<capacity).map { _ in Slot() }
    }

    func acquire(minimumCapacity: Int, makeResource: (Int) -> Resource?) -> Lease? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = slots.indices.first(where: {
            !slots[$0].leased && slots[$0].resource != nil && slots[$0].capacity >= minimumCapacity
        }) ?? slots.indices.first(where: { !slots[$0].leased }) else { return nil }
        if slots[index].resource == nil || slots[index].capacity < minimumCapacity {
            guard let resource = makeResource(minimumCapacity) else { return nil }
            slots[index].resource = resource
            slots[index].capacity = minimumCapacity
        }
        guard let resource = slots[index].resource else { return nil }
        slots[index].generation &+= 1
        slots[index].leased = true
        return Lease(resource: resource, slot: index, generation: slots[index].generation)
    }

    func release(_ lease: Lease) {
        release(slot: lease.slot, generation: lease.generation)
    }

    func release(slot: Int, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard slots.indices.contains(slot), slots[slot].generation == generation else { return }
        slots[slot].leased = false
    }
}
