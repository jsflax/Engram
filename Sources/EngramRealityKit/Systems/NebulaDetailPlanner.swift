import Foundation

/// Bounds project-detail VFX across all galaxies. Aggregate galaxy gas and
/// hierarchy bridges have separate costs and are not included in this budget.
struct NebulaDetailPlanner {
    struct Budget: Sendable {
        // Provisional tuning values, not measured device-performance guarantees.
        var maxEmitters: Int = 24
        var maxBirthRate: Float = 240
        var fadeDuration: Float = 0.25
    }

    struct Candidate: Sendable {
        let key: String
        let galaxyId: String
        let desiredOpacity: Float
        /// Lower values mean closer relative to the cluster's own extent.
        let priority: Float
        let birthRate: Float
    }

    struct Allocation: Equatable, Sendable {
        let opacity: Float
        /// The configured rate, not an opacity-discounted particle estimate.
        let birthRate: Float
    }

    private struct Entry {
        var admission: Float
        var birthRate: Float
    }

    let budget: Budget
    private var entries: [String: Entry] = [:]
    private var previousTargets: Set<String> = []

    init(budget: Budget = Budget()) { self.budget = budget }

    mutating func update(candidates: [Candidate], deltaTime: Float) -> [String: Allocation] {
        let limit = max(0, budget.maxEmitters)
        let rateLimit = budget.maxBirthRate.isFinite ? max(0, budget.maxBirthRate) : 0
        let step: Float
        if budget.fadeDuration.isFinite, budget.fadeDuration > 0 {
            step = deltaTime.isFinite ? min(1, max(0, deltaTime) / budget.fadeDuration) : 0
        } else { step = 1 }

        var byKey: [String: Candidate] = [:]
        for candidate in candidates where candidate.desiredOpacity.isFinite
            && candidate.priority.isFinite && candidate.birthRate.isFinite
            && candidate.birthRate >= 0 {
            byKey[candidate.key] = candidate
        }
        let desired = byKey.values.filter { $0.desiredOpacity > 0 }.sorted {
            // Retain a previous choice through small camera/ranking jitter.
            let lhs = max(0, $0.priority) * (previousTargets.contains($0.key) ? 0.9 : 1)
            let rhs = max(0, $1.priority) * (previousTargets.contains($1.key) ? 0.9 : 1)
            return lhs == rhs ? $0.key < $1.key : lhs < rhs
        }
        var targets: Set<String> = []
        var requestedRate: Float = 0
        for candidate in desired where targets.count < limit {
            guard candidate.birthRate <= rateLimit - requestedRate else { continue }
            targets.insert(candidate.key)
            requestedRate += candidate.birthRate
        }

        // Spatial endpoints remain immediate. Only membership under resource
        // pressure fades; a far/removed cluster must not remain enabled.
        for key in Array(entries.keys) {
            guard let candidate = byKey[key], candidate.desiredOpacity > 0 else {
                entries.removeValue(forKey: key); continue
            }
            var entry = entries[key]!
            entry.birthRate = min(entry.birthRate, candidate.birthRate)
            if !targets.contains(key) { entry.admission = max(0, entry.admission - step) }
            if entry.admission > 0 { entries[key] = entry }
            else { entries.removeValue(forKey: key) }
        }

        var usedRate = entries.values.reduce(Float(0)) { $0 + $1.birthRate }
        let unconstrained = targets.count == desired.count
        for candidate in desired where targets.contains(candidate.key) {
            if var entry = entries[candidate.key] {
                let increase = candidate.birthRate - entry.birthRate
                if increase <= rateLimit - usedRate {
                    entry.birthRate = candidate.birthRate
                    usedRate += increase
                }
                entry.admission = unconstrained ? 1 : min(1, entry.admission + step)
                entries[candidate.key] = entry
            } else if entries.count < limit, candidate.birthRate <= rateLimit - usedRate {
                // Small scenes retain their immediate existing appearance.
                let admission: Float = unconstrained ? 1 : step
                guard admission > 0 else { continue }
                entries[candidate.key] = Entry(admission: admission, birthRate: candidate.birthRate)
                usedRate += candidate.birthRate
            }
        }
        previousTargets = targets

        return byKey.mapValues { candidate in
            let entry = entries[candidate.key]
            return Allocation(opacity: min(1, max(0, candidate.desiredOpacity)) * (entry?.admission ?? 0),
                              birthRate: entry?.birthRate ?? candidate.birthRate)
        }
    }
}
