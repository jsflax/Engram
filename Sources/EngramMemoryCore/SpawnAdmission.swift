import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One lifetime lease shared by Claude and Codex background work. No PID expiry
/// or active markers: the kernel releases spawn.lock when its last descriptor
/// closes. The global cooldown throttles starts; it does not guarantee fairness
/// between providers. Codex retains its existing queue and fair worker scheduler.
///
/// Shared Python/Swift protocol: private owned regular files under
/// ~/.claude/memory-hooks-state; spawn-state.json contains exactly
/// {"version":1,"lastSpawnAt":<finite Unix seconds>}. Persist before launch.
/// Invalid state, unavailable load, and persistence failures refuse explicitly.
public struct SpawnAdmission: Sendable {
    public enum Kind: String, Codable, Sendable { case learner, maintenance, reconciliation, other }
    struct State: Codable { var version = 1; var lastSpawnAt: Double }
    public enum Verdict: Equatable, Sendable, CustomStringConvertible {
        case admitted(pid: Int32)
        case refusedConcurrent
        case refusedCooldown(secondsRemaining: Double)
        case refusedLoad(loadAverage: Double, limit: Double)
        case refusedUnavailable(reason: String)
        public var isAdmitted: Bool { if case .admitted = self { return true }; return false }
        public var description: String {
            switch self {
            case .admitted(let pid): return "admitted (wrapper pid \(pid))"
            case .refusedConcurrent: return "skipped: concurrency (shared lifetime lease held)"
            case .refusedCooldown(let remaining): return "skipped: cooldown (\(remaining.rounded(.up)) s remaining)"
            case .refusedLoad(let load, let limit): return "skipped: load average \(load) > \(limit)"
            case .refusedUnavailable(let reason): return "skipped: admission unavailable (\(reason))"
            }
        }
    }
    public struct Policy: Sendable {
        public var cooldownSeconds: TimeInterval = 600
        public var loadFactor = 2.0
        public init() {}
    }
    public var stateDirectory: String
    public var policy: Policy
    public var now: @Sendable () -> Date
    public var loadAverage: @Sendable () -> Double?
    public var processorCount: Int
    public init(stateDirectory: String, policy: Policy = Policy(),
                now: @escaping @Sendable () -> Date = { Date() },
                loadAverage: @escaping @Sendable () -> Double? = { systemLoadAverage1m() },
                processorCount: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.stateDirectory = stateDirectory; self.policy = policy
        self.now = now; self.loadAverage = loadAverage
        self.processorCount = max(1, processorCount)
    }
    public static var `default`: SpawnAdmission {
        SpawnAdmission(stateDirectory: NSHomeDirectory() + "/.claude/memory-hooks-state")
    }
    public var lockPath: String { stateDirectory + "/spawn.lock" }
    public var statePath: String { stateDirectory + "/spawn-state.json" }

    /// The actual worker MUST inherit fd, not just a short-lived launcher.
    /// Closing our copy on success/error must not unlock the child's copy.
    public func admit(kind: Kind, spawn: (Int32) throws -> Int32) throws -> Verdict {
        do {
            try FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        } catch { return .refusedUnavailable(reason: "state_directory") }
        var directory = stat()
        guard lstat(stateDirectory, &directory) == 0,
              directory.st_mode & S_IFMT == S_IFDIR, directory.st_uid == getuid(),
              directory.st_mode & 0o022 == 0 else { return .refusedUnavailable(reason: "unsafe_directory") }
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { return .refusedUnavailable(reason: "lock_open") }
        defer { close(fd) } // Never LOCK_UN: child descriptors share this lease.
        guard validFile(fd), sameFile(fd, path: lockPath) else { return .refusedUnavailable(reason: "unsafe_lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            return errno == EWOULDBLOCK || errno == EAGAIN ? .refusedConcurrent : .refusedUnavailable(reason: "lock_error")
        }
        let current = now().timeIntervalSince1970
        guard current.isFinite, current >= 0, policy.cooldownSeconds.isFinite,
              policy.cooldownSeconds >= 0, policy.loadFactor.isFinite, policy.loadFactor > 0 else {
            return .refusedUnavailable(reason: "invalid_policy_or_clock")
        }
        do {
            if let state = try readState(), current - state.lastSpawnAt < policy.cooldownSeconds {
                return .refusedCooldown(secondsRemaining: policy.cooldownSeconds - (current - state.lastSpawnAt))
            }
            guard let load = loadAverage(), load.isFinite, load >= 0 else { return .refusedUnavailable(reason: "load_unavailable") }
            let limit = policy.loadFactor * Double(processorCount)
            if load > limit { return .refusedLoad(loadAverage: load, limit: limit) }
            guard sameFile(fd, path: lockPath) else { throw GateError.unavailable }
            try writeState(State(lastSpawnAt: current))
        } catch { return .refusedUnavailable(reason: "cooldown_state") }
        return .admitted(pid: try spawn(fd))
    }
    enum GateError: Error { case unavailable }
    private func validFile(_ fd: Int32) -> Bool {
        var s = stat()
        return fstat(fd, &s) == 0 && s.st_mode & S_IFMT == S_IFREG && s.st_uid == getuid()
            && s.st_nlink == 1 && s.st_mode & 0o077 == 0
    }
    private func sameFile(_ fd: Int32, path: String) -> Bool {
        var a = stat(), b = stat()
        return fstat(fd, &a) == 0 && lstat(path, &b) == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }
    func readState() throws -> State? {
        let fd = open(statePath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 { if errno == ENOENT { return nil }; throw GateError.unavailable }
        defer { close(fd) }
        var s = stat()
        guard validFile(fd), fstat(fd, &s) == 0, s.st_size <= 4096 else { throw GateError.unavailable }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readData(ofLength: 4097)
        // This deliberately small wire format has two numeric fields only.
        // Validate its complete shape before decoding: Foundation JSON decoders
        // otherwise accept duplicate keys, unlike the shared Python reader.
        let number = #"(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?"#
        let version = #""version"\s*:\s*1"#
        let timestamp = #""lastSpawnAt"\s*:\s*"# + number
        let shape = #"\A\s*\{\s*(?:"# + version + #"\s*,\s*"# + timestamp
            + "|" + timestamp + #"\s*,\s*"# + version + #")\s*\}\s*\z"#
        guard data.count <= 4096, sameFile(fd, path: statePath),
              let raw = String(data: data, encoding: .utf8),
              raw.range(of: shape, options: .regularExpression) != nil,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "lastSpawnAt"] else { throw GateError.unavailable }
        let state = try JSONDecoder().decode(State.self, from: data)
        guard state.version == 1, state.lastSpawnAt.isFinite, state.lastSpawnAt >= 0 else { throw GateError.unavailable }
        return state
    }
    func writeState(_ state: State) throws {
        let data = try JSONEncoder().encode(state)
        let temporary = statePath + "." + UUID().uuidString + ".tmp"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw GateError.unavailable }
        defer { close(fd); unlink(temporary) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw GateError.unavailable }; offset += n
            }
        }
        guard fsync(fd) == 0, rename(temporary, statePath) == 0 else { throw GateError.unavailable }
        let parent = open(stateDirectory, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard parent >= 0 else { throw GateError.unavailable }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw GateError.unavailable }
    }
    public static func systemLoadAverage1m() -> Double? {
        var samples = [Double](repeating: 0, count: 3)
        return getloadavg(&samples, 3) >= 1 ? samples[0] : nil
    }
}
