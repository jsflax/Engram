import Darwin
import Foundation
import Testing
import os
import EngramSceneKit

@Suite("Locked callback snapshots")
struct LockedSnapshotTests {
    private final class Input: @unchecked Sendable {}
    private typealias Filter = @Sendable (Input) -> Bool
    private typealias Resolver = @Sendable (UUID?, String) -> String

    @inline(never) private static func stackDepth() -> Int {
        let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 4096)
        defer { frames.deallocate() }
        return Int(backtrace(frames, 4096))
    }

    @Test("Reading a stored node filter does not deepen its invocation stack")
    func filterReadsKeepConstantStackDepth() {
        let depths = OSAllocatedUnfairLock<[Int]>(initialState: [])
        let callbacks = LockedSnapshot<Filter?>(nil)
        let input = Input()
        callbacks.set { _ in
            let depth = Self.stackDepth()
            depths.withLock { $0.append(depth) }
            return true
        }
        for reads in [1, 32, 512] {
            for _ in 0..<reads { _ = callbacks.read() }
            #expect(callbacks.read()?(input) == true)
        }
        let observed = depths.withLock { $0 }
        #expect(observed.count == 3)
        #expect((observed.max() ?? 0) - (observed.min() ?? 0) < 8)
    }

    @Test("Reading a stored project resolver does not deepen its invocation stack")
    func resolverReadsKeepConstantStackDepth() {
        let callbacks = LockedSnapshot<Resolver?> { _, _ in String(Self.stackDepth()) }
        var observed: [Int] = []
        for reads in [1, 32, 512] {
            for _ in 0..<reads { _ = callbacks.read() }
            if let result = callbacks.read()?(nil, "project"), let depth = Int(result) {
                observed.append(depth)
            }
        }
        #expect(observed.count == 3)
        #expect((observed.max() ?? 0) - (observed.min() ?? 0) < 8)
    }

    @Test("Snapshots preserve old callbacks when the current callback is replaced or cleared")
    func replacingAndClearingCallbacks() {
        let callbacks = LockedSnapshot<Filter?>(nil)
        let input = Input()
        #expect(callbacks.read() == nil)
        callbacks.set { _ in true }
        let previous = callbacks.read()
        callbacks.set { _ in false }
        #expect(previous?(input) == true)
        #expect(callbacks.read()?(input) == false)
        callbacks.set(nil)
        #expect(callbacks.read() == nil)
        #expect(previous?(input) == true)
    }
}
