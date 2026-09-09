import Testing
@testable import EngramRealityKit

@Suite("Bounded GPU upload leases")
struct BoundedUploadPoolTests {
    @Test("Three in-flight uploads exhaust the pool until completion releases one")
    func pressureRetriesAfterCompletion() throws {
        let pool = BoundedUploadPool<Int>()
        let first = try #require(pool.acquire(minimumCapacity: 32) { $0 })
        let second = try #require(pool.acquire(minimumCapacity: 32) { $0 })
        let third = try #require(pool.acquire(minimumCapacity: 32) { $0 })
        #expect(Set([first.slot, second.slot, third.slot]).count == 3)
        #expect(pool.acquire(minimumCapacity: 32) { _ in Issue.record("Must not allocate a fourth buffer"); return 32 } == nil)
        pool.release(second)
        let retry = try #require(pool.acquire(minimumCapacity: 32) { _ in Issue.record("Must reuse completed storage"); return 32 })
        #expect(retry.slot == second.slot)
        #expect(retry.generation != second.generation)
        pool.release(second) // A late/duplicate completion cannot release a new reader.
        #expect(pool.acquire(minimumCapacity: 32) { $0 } == nil)
        pool.release(retry)
        #expect(pool.acquire(minimumCapacity: 32) { $0 } != nil)
    }

    @Test("Allocation and encoder failures release capacity for unchanged retries")
    func failedUploadsRetryWithoutLeakingSlots() throws {
        let pool = BoundedUploadPool<Int>(capacity: 1)
        #expect(pool.acquire(minimumCapacity: 32) { _ in nil } == nil)
        let failedEncoding = try #require(pool.acquire(minimumCapacity: 32) { $0 })
        // No command buffer owns this lease when encoder creation fails.
        pool.release(failedEncoding)
        let retry = try #require(pool.acquire(minimumCapacity: 32) { _ in Issue.record("Expected reuse"); return 32 })
        #expect(retry.resource == 32)
        pool.release(retry)
        #expect(pool.acquire(minimumCapacity: 64) { _ in nil } == nil)
        // Failed growth must not discard the existing smaller allocation.
        let smaller = try #require(pool.acquire(minimumCapacity: 32) { _ in Issue.record("Expected old storage"); return 32 })
        #expect(smaller.resource == 32)
    }
}
