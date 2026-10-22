import Foundation
import Lattice

/// Bounded retry around a checked write transaction's BEGIN.
///
/// Every interactive writer (MCP server, hooks) opens its Lattice with a short
/// statement-level busy timeout (2 s) so a locked hub fails fast instead of
/// riding the MCP handshake or a hook budget. The cost of that choice showed
/// up on 2026-10-21: with many sessions, learners and the sync daemon writing
/// to one hub, a single 2 s BEGIN attempt lost often enough that `remember`
/// failed for whole afternoons ("database was busy before the write
/// transaction started").
///
/// This helper keeps the fail-fast open-time contract and adds a small,
/// bounded number of BEGIN attempts per tool call:
///
/// - BEGIN is retried ONLY while the transaction body has not been entered,
///   and only for the exact Core contention messages. A body, COMMIT,
///   rollback or notification failure propagates unchanged — nothing is
///   ever replayed after a write may have happened.
/// - Backoff is `backoffMs[attempt]` plus up to 25 % jitter, so colliding
///   sessions desynchronize instead of re-colliding on the next BEGIN.
/// - No attempt starts unless the configured busy timeout still fits inside
///   `totalCapSeconds`; worst case with the 2 s MCP timeout and the default
///   schedule is three attempts, ~6.5 s wall.
/// - A lattice whose busy timeout is unset (Core's 30 s default) or above
///   2 s gets exactly one attempt: each attempt already waits far longer
///   than any interactive budget allows.
///
/// The same policy lived privately in `MemoryOperationLedger`; it is lifted
/// here so `remember`, `update`, `connect`, `merge`, `organize` and
/// `consolidate` share one implementation.
public enum LatticeBeginRetry {

    /// Default backoff schedule between attempts (milliseconds).
    public static let defaultBackoffMs: [Int] = [100, 300, 900]
    /// Default admission cap for the whole retry loop (seconds).
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
        /// The Core message of the final failed BEGIN.
        public let detail: String

        public var description: String {
            "BEGIN contention after \(attempts) attempt(s), \(String(format: "%.2f", totalWaitSeconds)) s: \(detail)"
        }
    }

    /// Successful run: the value plus how many BEGINs it took.
    public struct Success<T> {
        public let value: T
        public let attempts: Int
        public let totalWaitSeconds: Double
    }

    /// Exact Core contention messages for a failed BEGIN. Unknown failures
    /// fail closed: broad substring matching could retry an indeterminate
    /// error from a later phase.
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
    /// write path, and the sleeps are at most ~1.1 s).
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
                var delay = Double(backoffMs[min(attempt - 1, max(backoffMs.count - 1, 0))]) / 1_000
                if backoffMs.isEmpty { delay = 0 }
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
            }
        }
    }
}
