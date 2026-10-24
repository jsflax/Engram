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
/// Invalid state, unavailable resource probes, and persistence failures refuse.
/// Darwin samples CPU headroom and memory pressure outside the lifetime lease;
/// Linux retains its existing load gate. A sample is not a capacity reservation.
public struct SpawnAdmission: Sendable {
    public enum Kind: String, Codable, Sendable { case learner, maintenance, reconciliation, other }
    struct State: Codable { var version = 1; var lastSpawnAt: Double }
    public enum Verdict: Equatable, Sendable, CustomStringConvertible {
        case admitted(pid: Int32)
        case refusedConcurrent
        case refusedCooldown(secondsRemaining: Double)
        case refusedLoad(loadAverage: Double, limit: Double)
        case refusedCPU(idleFraction: Double, minimum: Double)
        case refusedMemoryPressure(level: Int)
        case refusedUnavailable(reason: String)
        public var isAdmitted: Bool { if case .admitted = self { return true }; return false }
        public var description: String {
            switch self {
            case .admitted(let pid): return "admitted (wrapper pid \(pid))"
            case .refusedConcurrent: return "skipped: concurrency (shared lifetime lease held)"
            case .refusedCooldown(let remaining): return "skipped: cooldown (\(remaining.rounded(.up)) s remaining)"
            case .refusedLoad(let load, let limit): return "skipped: load average \(load) > \(limit)"
            case .refusedCPU(let idle, let minimum): return "skipped: cpu_pressure (idle \(idle) < \(minimum))"
            case .refusedMemoryPressure(let level): return "skipped: memory_pressure (level \(level))"
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
    // Internal injection points keep regression fixtures independent of host load.
    // These are not a user override or an alternative production policy.
    enum ResourceMode: Equatable, Sendable { case darwin, legacyLoad }
    #if os(macOS)
    var resourceMode: ResourceMode = .darwin
    #else
    var resourceMode: ResourceMode = .legacyLoad
    #endif
    struct ResourcePoint: Sendable {
        var ticks: [UInt64] // HOST_CPU_LOAD_INFO: user, system, idle, nice (UInt32).
        var processorCount: Int
        var memoryPressure: Int?
    }
    struct ResourceSample: Sendable {
        var startedAt: Double
        var completedAt: Double
        var first: ResourcePoint
        var second: ResourcePoint
        var loadAverage: Double? // Diagnostic only; never decides Darwin admission.
    }
    static let minimumIdleFraction = 0.20
    static let sampleInterval = 1.0
    static let maximumSampleSeconds = 2.0
    static let maximumSampleAge = 2.0
    var sampleResources: @Sendable () -> ResourceSample? = { systemResourceSample() }
    var memoryPressure: @Sendable () -> Int? = { systemMemoryPressure() }
    var currentProcessorCount: @Sendable () -> Int? = { systemProcessorCount() }
    var monotonicNow: @Sendable () -> Double = { monotonicSeconds() }

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
    /// Eligible Darwin callers add one bounded ~1s synchronous sample; concurrent
    /// or cooling callers return before sampling. There is no native retry loop.
    public func admit(kind: Kind, spawn: (Int32) throws -> Int32) throws -> Verdict {
        var expectedIdentity: LeaseIdentity?
        var sample: ResourceSample?
        if resourceMode == .darwin {
            switch prepareLease() {
            case .refused(let verdict): return verdict
            case .acquired(let lease):
                expectedIdentity = lease.identity
                close(lease.fd) // No execution/admission lease survives sampling.
            }
            sample = sampleResources()
        }
        let lease: Lease
        switch prepareLease(expectedIdentity: expectedIdentity) {
        case .refused(let verdict): return verdict
        case .acquired(let prepared): lease = prepared
        }
        defer { close(lease.fd) } // Never LOCK_UN: child descriptors share this lease.
        if resourceMode == .darwin {
            let pressure = memoryPressure()
            let processors = currentProcessorCount()
            // Read the clock after the final syscalls so a late return is stale.
            if let refused = Self.resourceVerdict(sample, at: monotonicNow(),
                                                  finalPressure: pressure, finalProcessorCount: processors) {
                return refused
            }
        } else {
            guard let load = loadAverage(), load.isFinite, load >= 0 else {
                return .refusedUnavailable(reason: "load_unavailable")
            }
            let limit = policy.loadFactor * Double(processorCount)
            if load > limit { return .refusedLoad(loadAverage: load, limit: limit) }
        }
        do {
            guard currentIdentity(lease.fd) == lease.identity else { throw GateError.unavailable }
            try writeState(State(lastSpawnAt: lease.currentTime))
        } catch { return .refusedUnavailable(reason: "cooldown_state") }
        return .admitted(pid: try spawn(lease.fd))
    }

    private struct LeaseIdentity: Equatable {
        var directoryDevice: UInt64
        var directoryInode: UInt64
        var lockDevice: UInt64
        var lockInode: UInt64
    }
    private struct Lease {
        var fd: Int32
        var currentTime: Double
        var identity: LeaseIdentity
    }
    private enum Preparation { case acquired(Lease), refused(Verdict) }

    /// A read-only preflight and the final pass use exactly the same private
    /// lock/cooldown checks. Neither reserves admission or writes a timestamp.
    private func prepareLease(expectedIdentity: LeaseIdentity? = nil) -> Preparation {
        do {
            try FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        } catch { return .refused(.refusedUnavailable(reason: "state_directory")) }
        var directory = stat()
        guard lstat(stateDirectory, &directory) == 0,
              directory.st_mode & S_IFMT == S_IFDIR, directory.st_uid == getuid(),
              directory.st_mode & 0o022 == 0 else { return .refused(.refusedUnavailable(reason: "unsafe_directory")) }
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { return .refused(.refusedUnavailable(reason: "lock_open")) }
        var retained = false
        defer { if !retained { close(fd) } }
        guard validFile(fd), let identity = currentIdentity(fd) else {
            return .refused(.refusedUnavailable(reason: "unsafe_lock"))
        }
        if let expectedIdentity, identity != expectedIdentity {
            return .refused(.refusedUnavailable(reason: "admission_identity_changed"))
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            return .refused(errno == EWOULDBLOCK || errno == EAGAIN
                ? .refusedConcurrent : .refusedUnavailable(reason: "lock_error"))
        }
        let current = now().timeIntervalSince1970
        guard current.isFinite, current >= 0, policy.cooldownSeconds.isFinite,
              policy.cooldownSeconds >= 0, policy.loadFactor.isFinite, policy.loadFactor > 0 else {
            return .refused(.refusedUnavailable(reason: "invalid_policy_or_clock"))
        }
        do {
            if let state = try readState(), current - state.lastSpawnAt < policy.cooldownSeconds {
                return .refused(.refusedCooldown(secondsRemaining: policy.cooldownSeconds - (current - state.lastSpawnAt)))
            }
        } catch { return .refused(.refusedUnavailable(reason: "cooldown_state")) }
        retained = true
        return .acquired(Lease(fd: fd, currentTime: current, identity: identity))
    }

    private func currentIdentity(_ fd: Int32) -> LeaseIdentity? {
        var directory = stat(), lock = stat()
        guard lstat(stateDirectory, &directory) == 0,
              directory.st_mode & S_IFMT == S_IFDIR, directory.st_uid == getuid(),
              directory.st_mode & 0o022 == 0, fstat(fd, &lock) == 0,
              sameFile(fd, path: lockPath) else { return nil }
        return LeaseIdentity(directoryDevice: UInt64(truncatingIfNeeded: directory.st_dev),
            directoryInode: UInt64(directory.st_ino), lockDevice: UInt64(truncatingIfNeeded: lock.st_dev),
            lockInode: UInt64(lock.st_ino))
    }

    /// Shared Darwin policy vectors: 1–2s interval, <=2s age, >=20% idle,
    /// normal pressure (exported flag 1) at both endpoints and final admission.
    static func resourceVerdict(_ sample: ResourceSample?, at now: Double,
                                finalPressure: Int?, finalProcessorCount: Int?) -> Verdict? {
        let unavailable = Verdict.refusedUnavailable(reason: "resource_unavailable")
        guard let sample, sample.startedAt.isFinite, sample.completedAt.isFinite,
              sample.startedAt >= 0, now.isFinite else { return unavailable }
        let elapsed = sample.completedAt - sample.startedAt
        let age = now - sample.completedAt
        guard elapsed >= sampleInterval, elapsed <= maximumSampleSeconds,
              age >= 0, age <= maximumSampleAge,
              (1...65_536).contains(sample.first.processorCount),
              sample.first.processorCount == sample.second.processorCount,
              sample.second.processorCount == finalProcessorCount,
              sample.first.ticks.count == 4, sample.second.ticks.count == 4 else { return unavailable }
        var deltas = [UInt64]()
        for (first, second) in zip(sample.first.ticks, sample.second.ticks) {
            guard first <= UInt32.max, second <= UInt32.max, second >= first else { return unavailable }
            deltas.append(second - first) // Counter wrap/reset ambiguity refuses.
        }
        let total = deltas.reduce(UInt64(0), +)
        guard total > 0 else { return unavailable }
        let pressures = [sample.first.memoryPressure, sample.second.memoryPressure, finalPressure]
        guard pressures.allSatisfy({ $0 == 1 || $0 == 2 || $0 == 4 }) else { return unavailable }
        if let pressure = pressures.compactMap({ $0 }).max(), pressure != 1 {
            return .refusedMemoryPressure(level: pressure)
        }
        let idle = Double(deltas[2]) / Double(total)
        return idle < minimumIdleFraction ? .refusedCPU(idleFraction: idle, minimum: minimumIdleFraction) : nil
    }

    static func monotonicSeconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

    static func systemResourceSample() -> ResourceSample? {
        #if os(macOS)
        let started = monotonicSeconds()
        guard let first = systemResourcePoint() else { return nil }
        Thread.sleep(forTimeInterval: sampleInterval)
        guard let second = systemResourcePoint() else { return nil }
        // Optional load is retained only for diagnostics. A failed load read
        // does not invalidate CPU/pressure, and its latency counts in freshness.
        let load = systemLoadAverage1m()
        return ResourceSample(startedAt: started, completedAt: monotonicSeconds(),
            first: first, second: second, loadAverage: load)
        #else
        return nil
        #endif
    }

    static func systemMemoryPressure() -> Int? {
        #if os(macOS)
        // Exported Darwin flags are 1/2/4, not XNU's internal enum. This sysctl
        // has no stable high-level availability guarantee on every supported
        // macOS release: missing/unknown data stays explicitly unavailable.
        var value: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0,
              size == MemoryLayout<UInt32>.size else { return nil }
        return Int(value)
        #else
        return nil
        #endif
    }

    static func systemProcessorCount() -> Int? {
        #if os(macOS)
        var value: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        guard sysctlbyname("hw.activecpu", &value, &size, nil, 0) == 0,
              size == MemoryLayout<UInt32>.size else { return nil }
        return Int(value)
        #else
        return nil
        #endif
    }

    private static func systemResourcePoint() -> ResourcePoint? {
        #if os(macOS)
        var info = host_cpu_load_info_data_t()
        let expectedCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var count = expectedCount
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(expectedCount)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS, count == expectedCount,
              let pressure = systemMemoryPressure(), let processors = systemProcessorCount() else { return nil }
        let ticks = info.cpu_ticks
        return ResourcePoint(ticks: [UInt64(ticks.0), UInt64(ticks.1), UInt64(ticks.2), UInt64(ticks.3)],
            processorCount: processors, memoryPressure: pressure)
        #else
        return nil
        #endif
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
