import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Pure budget-shaping policy for the hooks (the hooks binary is an
/// executable target, so the decisions live here where tests can reach them).
///
/// Introduced for the 2026-10-21 contention incident: the advise hook spent
/// its whole 15 s budget opening the hub, the synced mirror and the group
/// spokes against a locked database, then reported "recall skipped". The
/// policy trades completeness for an answer: when the fixed costs (hub open,
/// embedder load) have already eaten a large share of the budget, the
/// optional attaches and the maintenance check stand down.
public enum HookBudgetPolicy {

    /// Default recall ceiling (seconds) when no override is set.
    public static let defaultCeilingSeconds = 15.0
    /// `ENGRAM_HOOK_RECALL_CEILING_S` is clamped to this range.
    public static let ceilingRange: ClosedRange<Double> = 3.0...60.0
    /// Recall and its watchdog must both finish before the registered host
    /// timeout. A tiny registration takes precedence over the usual 3s floor.
    public static func registeredSeconds(_ value: Double?) -> Double {
        guard let value, value.isFinite, value > 0 else { return 60 }
        return value
    }

    public static func recallSeconds(registeredTimeout: Double?, environment: [String: String]) -> Double {
        let registered = registeredSeconds(registeredTimeout)
        let hostCap = min(registered * 0.6, max(registered * 0.5, registered - 2.5))
        let normal = min(max(registered * 0.6, 3), ceilingSeconds(environment: environment))
        let override = environment["ENGRAM_HOOK_RECALL_BUDGET_MS"].flatMap(Double.init)
        let requested = override.flatMap { $0.isFinite && $0 > 0 ? $0 / 1000 : nil } ?? normal
        return min(requested, ceilingSeconds(environment: environment), hostCap)
    }

    public static func watchdogSeconds(recallBudget: Double, registeredTimeout: Double?) -> Double {
        min(recallBudget + 2, registeredSeconds(registeredTimeout) * 0.9)
    }

    /// Fraction of the budget the hub open + embedder load may consume before
    /// the secondary attaches (synced DB, group spokes) are skipped.
    public static let secondaryAttachFraction = 0.4
    /// The maintenance check re-opens the hub; below this much remaining
    /// budget it cannot finish inside the deadline.
    public static let maintenanceMinimumRemainingSeconds = 2.0
    /// Optional work is skipped when the 1-minute load average exceeds this
    /// multiple of the processor count.
    public static let loadFactor = 2.0

    /// The recall ceiling, overridable without a rebuild through
    /// `ENGRAM_HOOK_RECALL_CEILING_S` (seconds). Unset, empty, unparsable or
    /// non-finite → the default; otherwise clamped to `ceilingRange`.
    public static func ceilingSeconds(environment: [String: String]) -> Double {
        guard let raw = environment["ENGRAM_HOOK_RECALL_CEILING_S"]?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty, let seconds = Double(raw), seconds.isFinite else {
            return defaultCeilingSeconds
        }
        return min(max(seconds, ceilingRange.lowerBound), ceilingRange.upperBound)
    }

    /// Whether to attach the synced DB and group spokes after `elapsed`
    /// seconds of a `budget`-second recall budget have gone to the fixed costs.
    public static func shouldAttachSecondary(elapsed: Double, budget: Double) -> Bool {
        guard budget.isFinite, budget > 0, elapsed.isFinite, elapsed >= 0 else { return false }
        return elapsed <= budget * secondaryAttachFraction
    }

    /// Whether the post-recall maintenance check may run at all.
    public static func shouldRunMaintenanceCheck(remaining: Double, loadAverage: Double?,
                                                 processorCount: Int) -> Bool {
        guard remaining.isFinite, remaining >= maintenanceMinimumRemainingSeconds,
              let loadAverage, loadAverage.isFinite, loadAverage >= 0 else { return false }
        return loadAverage <= loadFactor * Double(max(1, processorCount))
    }

    /// 1-minute load average, nil when the platform cannot report it.
    public static func loadAverage1m() -> Double? {
        var samples = [Double](repeating: 0, count: 3)
        return getloadavg(&samples, 3) >= 1 ? samples[0] : nil
    }
}
