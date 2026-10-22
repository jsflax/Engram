import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Admission control for detached `claude` subprocesses (session learners,
/// memory maintenance, sync reconciliation).
///
/// Before this gate every Stop hook that found a "novel" excerpt spawned a
/// learner, and every advise hook past the maintenance threshold spawned a
/// maintenance agent — with no knowledge of each other. On 2026-10-21 the
/// sample-gate log shows learners for the same project spawned four minutes
/// apart while the hub was already refusing writes; each one is a full
/// `claude` process with its own MCP server and its own writes to the same
/// database, on a machine whose load average was 100–300.
///
/// The gate is a tiny file protocol under the hooks state directory, so it
/// works on every surface (macOS hooks, Linux sandboxes) without a database:
///
/// - `spawn.lock` — `flock`ed for the duration of a decision, so two hooks
///   deciding at the same instant cannot both admit.
/// - `spawn-state.json` — `lastSpawnAt` plus the live entries (wrapper pid,
///   kind, start time). Entries whose pid is gone are pruned on every read;
///   entries older than `staleAfterSeconds` are pruned regardless (pid reuse).
///
/// A spawn is refused when any recorded subprocess is still alive, when the
/// last spawn was less than `cooldownSeconds` ago, or when the 1-minute load
/// average exceeds `loadFactor` × processor count. Refusals are a verdict
/// for the caller to log, never an error.
public struct SpawnAdmission: Sendable {

    public enum Kind: String, Codable, Sendable {
        case learner
        case maintenance
        case reconciliation
        case other
    }

    public struct ActiveEntry: Codable, Equatable, Sendable {
        public var pid: Int32
        public var kind: Kind
        public var startedAt: Date
        public init(pid: Int32, kind: Kind, startedAt: Date) {
            self.pid = pid
            self.kind = kind
            self.startedAt = startedAt
        }
    }

    struct State: Codable, Equatable {
        var lastSpawnAt: Date?
        var active: [ActiveEntry] = []
    }

    public enum Verdict: Equatable, Sendable, CustomStringConvertible {
        case admitted(pid: Int32)
        /// Another learner/maintenance/reconciliation process is still live.
        case refusedConcurrent(active: [ActiveEntry])
        /// The last admitted spawn is too recent.
        case refusedCooldown(secondsRemaining: Double)
        /// The machine is already saturated.
        case refusedLoad(loadAverage: Double, limit: Double)
        /// Another hook holds the lock right now; it is about to spawn, so
        /// this one stands down.
        case refusedLockBusy

        public var isAdmitted: Bool {
            if case .admitted = self { return true }
            return false
        }

        public var description: String {
            switch self {
            case .admitted(let pid):
                return "admitted (wrapper pid \(pid))"
            case .refusedConcurrent(let active):
                let summary = active.map { "\($0.kind.rawValue) pid \($0.pid)" }.joined(separator: ", ")
                return "skipped: concurrency (live: \(summary))"
            case .refusedCooldown(let remaining):
                return "skipped: cooldown (\(Int(remaining.rounded(.up))) s remaining)"
            case .refusedLoad(let load, let limit):
                return "skipped: load average \(String(format: "%.1f", load)) > \(String(format: "%.1f", limit))"
            case .refusedLockBusy:
                return "skipped: concurrency (another hook is mid-spawn)"
            }
        }
    }

    public struct Policy: Sendable {
        /// Minimum spacing between admitted spawns of any kind.
        public var cooldownSeconds: TimeInterval = 600
        /// Refuse when the 1-minute load average exceeds this × ncpu.
        public var loadFactor: Double = 2.0
        /// Drop live entries older than this even if the pid still answers
        /// (pid reuse; maintenance is bounded to 1800 s wall clock).
        public var staleAfterSeconds: TimeInterval = 3 * 3600
        public init() {}
    }

    public var stateDirectory: String
    public var policy: Policy
    /// Injectable clocks and probes (tests).
    public var now: @Sendable () -> Date
    public var loadAverage: @Sendable () -> Double?
    public var processorCount: Int
    public var isAlive: @Sendable (Int32) -> Bool

    public init(stateDirectory: String,
                policy: Policy = Policy(),
                now: @escaping @Sendable () -> Date = { Date() },
                loadAverage: @escaping @Sendable () -> Double? = { SpawnAdmission.systemLoadAverage1m() },
                processorCount: Int = ProcessInfo.processInfo.activeProcessorCount,
                isAlive: @escaping @Sendable (Int32) -> Bool = { SpawnAdmission.processIsAlive($0) }) {
        self.stateDirectory = stateDirectory
        self.policy = policy
        self.now = now
        self.loadAverage = loadAverage
        self.processorCount = max(1, processorCount)
        self.isAlive = isAlive
    }

    /// The production gate: `~/.claude/memory-hooks-state`.
    public static var `default`: SpawnAdmission {
        SpawnAdmission(stateDirectory: NSHomeDirectory() + "/.claude/memory-hooks-state")
    }

    public var lockPath: String { stateDirectory + "/spawn.lock" }
    public var statePath: String { stateDirectory + "/spawn-state.json" }

    /// Decide, and if admitted run `spawn` INSIDE the critical section so the
    /// wrapper pid it returns is recorded before the lock is released. A
    /// throwing `spawn` propagates and records nothing.
    public func admit(kind: Kind, spawn: () throws -> Int32) throws -> Verdict {
        try FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true)
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return .refusedLockBusy }
        defer { close(fd) }
        var locked = false
        for _ in 0..<4 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
            if errno != EWOULDBLOCK && errno != EAGAIN { break }
            usleep(25_000)
        }
        guard locked else { return .refusedLockBusy }
        defer { flock(fd, LOCK_UN) }

        let current = now()
        var state = readState()
        state.active = state.active.filter { entry in
            current.timeIntervalSince(entry.startedAt) < policy.staleAfterSeconds && isAlive(entry.pid)
        }

        let verdict: Verdict
        if !state.active.isEmpty {
            verdict = .refusedConcurrent(active: state.active)
        } else if let last = state.lastSpawnAt,
                  current.timeIntervalSince(last) < policy.cooldownSeconds {
            verdict = .refusedCooldown(secondsRemaining: policy.cooldownSeconds - current.timeIntervalSince(last))
        } else if let load = loadAverage(), load > policy.loadFactor * Double(processorCount) {
            verdict = .refusedLoad(loadAverage: load, limit: policy.loadFactor * Double(processorCount))
        } else {
            let pid = try spawn()
            state.lastSpawnAt = current
            state.active.append(ActiveEntry(pid: pid, kind: kind, startedAt: current))
            verdict = .admitted(pid: pid)
        }
        writeState(state)
        return verdict
    }

    /// Current live entries after pruning (diagnostics).
    public func liveEntries() -> [ActiveEntry] {
        let current = now()
        return readState().active.filter {
            current.timeIntervalSince($0.startedAt) < policy.staleAfterSeconds && isAlive($0.pid)
        }
    }

    func readState() -> State {
        guard let data = FileManager.default.contents(atPath: statePath) else { return State() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(State.self, from: data)) ?? State()
    }

    func writeState(_ state: State) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }

    /// `kill(pid, 0)`: 0 means alive; EPERM means alive but not ours.
    public static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// 1-minute load average, or nil when the platform cannot report it.
    public static func systemLoadAverage1m() -> Double? {
        var samples = [Double](repeating: 0, count: 3)
        let count = getloadavg(&samples, 3)
        guard count >= 1 else { return nil }
        return samples[0]
    }
}
