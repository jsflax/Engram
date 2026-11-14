import Foundation
import Lattice

/// Bounded retry around a checked write transaction's BEGIN.
///
/// The interactive MCP writer uses a 2 s busy timeout. This helper retains
/// that per-attempt timeout and adds a bounded number of BEGIN attempts:
///
/// - BEGIN is retried ONLY while the transaction body has not been entered,
///   and only for the exact Core contention messages. A body, COMMIT,
///   rollback or notification failure propagates unchanged — nothing is
///   ever replayed after a write may have happened.
/// - The three default attempts use 100/300 ms backoffs plus up to 25 %
///   jitter. Longer attempt bounds use the rest of the supplied schedule,
///   repeating its final entry. Empty schedules and negative entries mean
///   zero delay.
/// - The first attempt always runs. Each retry is admitted only if its
///   configured busy timeout fits inside `totalCapSeconds`, checked both
///   before and after backoff. This is not an execution deadline: scheduling,
///   BEGIN overhead, the body, COMMIT and notifications can exceed the cap.
/// - A lattice whose busy timeout is nonpositive (Core's 30 s fallback) or
///   above 2 s gets exactly one attempt, without an interactive time bound.
///
/// `remember`, `update`, new-edge `connect`, `merge`, `organize` and
/// `consolidate` share this implementation. `MemoryOperationLedger` retains
/// its separate policy: a 6.25 s admission cap, 25/50 ms backoffs, and refusal
/// before the first attempt when the configured timeout is unsupported.
public enum LatticeBeginRetry {

    /// Backoffs in milliseconds; the default three attempts use only 100/300.
    public static let defaultBackoffMs: [Int] = [100, 300, 900]
    /// Default elapsed-time cap for admitting retries, not a body deadline.
    public static let defaultTotalCapSeconds: Double = 6.5
    /// Default attempt bound.
    public static let defaultMaxAttempts = 3
    /// Busy timeouts above this get a single attempt (no retry).
    public static let maximumRetryableBusyTimeoutMs = 2_000

    /// How a run ended when BEGIN never admitted the body.
    public struct Contention: Error, Sendable, CustomStringConvertible {
        /// BEGIN attempts made (>= 1).
        public let attempts: Int
        /// Wall-clock seconds from the first BEGIN to giving up: includes the
        /// busy-timeout waits inside each attempt and the backoff sleeps.
        public let totalWaitSeconds: Double
        /// The SQLite detail from the Core message of the final failed BEGIN.
        public let detail: String

        public var description: String {
            "BEGIN contention after \(attempts) attempt(s), \(String(format: "%.2f", totalWaitSeconds)) s: \(detail)"
        }
    }

    /// Successful run: the value plus how many BEGINs it took.
    public struct Success<T> {
        public let value: T
        public let attempts: Int
        /// Total elapsed time, including the successful body and COMMIT.
        public let totalWaitSeconds: Double
    }

    /// Exact Core contention messages for a failed BEGIN. Unknown failures
    /// fail closed: broad substring matching could retry an indeterminate
    /// error from a later phase. This classifier alone does not prove the
    /// phase: `run` must also establish that the body was never entered.
    public static func isBeginContention(_ error: any Error) -> Bool {
        guard case LatticeError.transactionError(let message) = error else { return false }
        return contentionDetail(message) != nil
    }

    static func contentionDetail(_ message: String) -> String? {
        let prefix = "Failed to begin transaction: "
        guard message.hasPrefix(prefix) else { return nil }
        let detail = String(message.dropFirst(prefix.count))
        let known: Set<String> = [
            "database is locked", "database is busy",
            "database table is locked", "database schema is locked",
        ]
        return known.contains(detail) ? detail : nil
    }

    /// Run `body` inside `lattice.withTransaction`, retrying only a failed
    /// BEGIN. Throws `Contention` when every admitted attempt lost the lock;
    /// every other error (including a failed BEGIN for a non-contention
    /// reason) is rethrown as-is.
    ///
    /// `sleep` and `now` are injectable for tests; production uses
    /// `Thread.sleep` (the actor is already blocked on a synchronous SQLite
    /// write path). The default sleeps are at most 125/375 ms; an explicit
    /// longer schedule is still subject to retry admission.
    @discardableResult
    public static func run<T>(
        isolation: isolated (any Actor)? = #isolation,
        on lattice: Lattice,
        maxAttempts: Int = defaultMaxAttempts,
        backoffMs: [Int] = defaultBackoffMs,
        totalCapSeconds: Double = defaultTotalCapSeconds,
        jitter: Bool = true,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: () -> Double = { ProcessInfo.processInfo.systemUptime },
        log: ((String) -> Void)? = nil,
        body: () throws -> T
    ) throws -> Success<T> {
        let timeoutMs = lattice.configuration.busyTimeoutMs
        let timeoutSeconds = Double(max(timeoutMs, 0)) / 1_000
        // Unset/oversized timeouts already wait longer than any interactive
        // budget; one attempt is all they get.
        let retryable = timeoutMs > 0 && timeoutMs <= maximumRetryableBusyTimeoutMs
        let attemptBound = retryable ? max(1, maxAttempts) : 1

        let started = now()
        var attempt = 0
        while true {
            attempt += 1
            var bodyEntered = false
            do {
                let value = try lattice.withTransaction {
                    bodyEntered = true
                    return try body()
                }
                let waited = now() - started
                if attempt > 1 {
                    log?("BEGIN succeeded on attempt \(attempt) after \(String(format: "%.2f", waited)) s")
                }
                return Success(value: value, attempts: attempt, totalWaitSeconds: waited)
            } catch {
                // Only a failed BEGIN proves nothing was written.
                guard !bodyEntered,
                      case LatticeError.transactionError(let message) = error,
                      let detail = contentionDetail(message) else { throw error }
                let elapsed = now() - started
                guard attempt < attemptBound else {
                    throw Contention(attempts: attempt, totalWaitSeconds: elapsed, detail: detail)
                }
                let backoff = backoffMs.isEmpty ? 0 : backoffMs[min(attempt - 1, backoffMs.count - 1)]
                var delay = Double(max(0, backoff)) / 1_000
                if jitter, delay > 0 {
                    delay += Double.random(in: 0...(delay * 0.25))
                }
                // Admit the next attempt only if its full busy wait still fits.
                guard elapsed + delay + timeoutSeconds <= totalCapSeconds else {
                    log?("BEGIN contention: not admitting attempt \(attempt + 1) "
                        + "(elapsed \(String(format: "%.2f", elapsed)) s + backoff + \(timeoutMs) ms timeout exceeds the \(totalCapSeconds) s cap)")
                    throw Contention(attempts: attempt, totalWaitSeconds: elapsed, detail: detail)
                }
                log?("BEGIN contention on attempt \(attempt) (\(detail)); retrying in \(Int(delay * 1_000)) ms")
                if delay > 0 { sleep(delay) }
                // Sleep and logging can take longer than requested. Recheck
                // immediately before allowing the loop to start another BEGIN.
                let afterBackoff = now() - started
                guard afterBackoff + timeoutSeconds <= totalCapSeconds else {
                    throw Contention(attempts: attempt, totalWaitSeconds: afterBackoff, detail: detail)
                }
            }
        }
    }
}
