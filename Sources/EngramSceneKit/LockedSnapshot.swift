import os

/// A replaceable value that can be copied out under a lock and used after unlocking.
public final class LockedSnapshot<Value: Sendable>: Sendable {
    // Keep the value inside a nominal state type. When an optional function is
    // the lock's direct generic State, Swift can reabstract it through the inout
    // argument to withLock and write another wrapper back on every read. Those
    // wrappers accumulate until invoking the callback overflows the stack.
    private struct State: Sendable {
        var value: Value
    }

    private let lock: OSAllocatedUnfairLock<State>

    public init(_ value: Value) {
        lock = OSAllocatedUnfairLock(initialState: State(value: value))
    }

    public func read() -> Value {
        lock.withLock { $0.value }
    }

    public func set(_ value: Value) {
        lock.withLock { $0.value = value }
    }
}
