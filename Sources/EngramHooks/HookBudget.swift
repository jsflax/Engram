import EngramMemoryCore
import Foundation

/// Time budgets for hook-side memory operations.
///
/// A hook that waits on a degraded database rides all the way to the
/// harness's kill timeout — the user's prompt stalls, and the harness kill
/// is SILENT (no context, no explanation). The budget keeps the hook's
/// slow path both bounded and visible.
///
/// The budget is DYNAMIC: a fraction of this hook's own registered timeout
/// in ~/.claude/settings.json, so operators tune one number and the budget
/// follows. `ENGRAM_HOOK_RECALL_BUDGET_MS` overrides for tests and repair
/// sessions.
enum HookBudget {

    /// The ceiling, overridable without a rebuild through
    /// `ENGRAM_HOOK_RECALL_CEILING_S` (seconds, clamped to 3...60). Unset,
    /// empty or unparsable → the default 15 s. Policy: HookBudgetPolicy.
    static func ceilingSeconds(environment: [String: String] = ProcessInfo.processInfo.environment) -> Double {
        HookBudgetPolicy.ceilingSeconds(environment: environment)
    }

    /// The recall budget in seconds for `event` (e.g. "UserPromptSubmit").
    static func recallBudget(event: String) -> Double {
        HookBudgetPolicy.recallSeconds(registeredTimeout: registeredTimeout(event: event),
                                       environment: ProcessInfo.processInfo.environment)
    }

    static func watchdogSeconds(event: String, recallBudget: Double) -> Double {
        HookBudgetPolicy.watchdogSeconds(recallBudget: recallBudget,
                                         registeredTimeout: registeredTimeout(event: event))
    }

    // MARK: Budget shaping (2026-10-21 contention incident) — thin wrappers
    // over HookBudgetPolicy (EngramMemoryCore), where the decisions are tested.

    static var secondaryAttachFraction: Double { HookBudgetPolicy.secondaryAttachFraction }
    static var maintenanceMinimumRemainingSeconds: Double { HookBudgetPolicy.maintenanceMinimumRemainingSeconds }
    static var loadFactor: Double { HookBudgetPolicy.loadFactor }

    /// Whether to attach the synced DB and group spokes after `elapsed`
    /// seconds of a `budget`-second recall budget have gone to the hub open
    /// and embedder load. Each attach is another open against a possibly
    /// contended file; past this point they turn "slow" into "exceeded 15 s".
    static func shouldAttachSecondary(elapsed: Double, budget: Double) -> Bool {
        HookBudgetPolicy.shouldAttachSecondary(elapsed: elapsed, budget: budget)
    }

    /// Whether the post-recall maintenance check may run at all.
    static func shouldRunMaintenanceCheck(remaining: Double, loadAverage: Double?,
                                          processorCount: Int) -> Bool {
        HookBudgetPolicy.shouldRunMaintenanceCheck(remaining: remaining, loadAverage: loadAverage,
                                                   processorCount: processorCount)
    }

    /// 1-minute load average, nil when unavailable.
    static func loadAverage1m() -> Double? { HookBudgetPolicy.loadAverage1m() }

    /// This binary's own registered timeout for `event`, from settings.json.
    /// Returns nil when unregistered/unreadable (caller falls back to the
    /// harness default of 60s).
    static func registeredTimeout(event: String) -> Double? {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let matchers = hooks[event] as? [[String: Any]] else { return nil }
        for matcher in matchers {
            guard let entries = matcher["hooks"] as? [[String: Any]] else { continue }
            for entry in entries {
                guard let command = entry["command"] as? String,
                      command.contains("memory-hooks") else { continue }
                if let t = entry["timeout"] as? Double { return t }
                if let t = entry["timeout"] as? Int { return Double(t) }
                return nil  // registered without a timeout → harness default
            }
        }
        return nil
    }

    enum Outcome<T: Sendable>: Sendable {
        case completed(T)
        case failed(any Error)
        case deadlineExceeded
    }

    /// Race `work` against the budget. On deadline, the caller proceeds
    /// (visibly degraded) IMMEDIATELY — deliberately unstructured, because a
    /// task group would await the non-cancellable C++ query to completion
    /// (cancellation is cooperative), re-creating the stall this exists to
    /// prevent. The orphaned work task dies with the short-lived hook
    /// process; SQLite handles a mid-statement process exit safely. The
    /// Lattice query-deadline primitive (planned, 1.3.0) upgrades this from
    /// "stop waiting" to "interrupt the statement".
    /// Resume-once guard for the unstructured race below.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    static func race<T: Sendable>(
        seconds: Double,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> Outcome<T> {
        let once = Once()
        return await withCheckedContinuation { cont in
            let workTask = Task {
                let outcome: Outcome<T>
                do { outcome = .completed(try await work()) }
                catch { outcome = .failed(error) }
                if once.claim() { cont.resume(returning: outcome) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() {
                    workTask.cancel()  // cooperative best-effort; orphan dies with the process
                    cont.resume(returning: Outcome.deadlineExceeded)
                }
            }
        }
    }
}
