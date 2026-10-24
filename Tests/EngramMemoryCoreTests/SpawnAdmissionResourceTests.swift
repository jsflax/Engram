import Foundation
import Testing
@testable import EngramMemoryCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Suite("SpawnAdmissionResources")
struct SpawnAdmissionResourceTests {
    private func directory() throws -> String {
        let base = ProcessInfo.processInfo.environment["ENGRAM_TEST_TMPDIR"]
            ?? FileManager.default.temporaryDirectory.path
        let dir = base + "/spawn-admission-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return dir
    }
    private func gate(_ dir: String, time: Double = 10_000, load: Double? = 1) -> SpawnAdmission {
        var admission = SpawnAdmission(stateDirectory: dir, now: { Date(timeIntervalSince1970: time) },
                                       loadAverage: { load }, processorCount: 8)
        admission.resourceMode = .legacyLoad
        return admission
    }
    private func resourceSample(idle: UInt64 = 20, load: Double? = 100) -> SpawnAdmission.ResourceSample {
        .init(startedAt: 100, completedAt: 101,
              first: .init(ticks: [100, 100, 100, 100], processorCount: 8, memoryPressure: 1),
              second: .init(ticks: [200 - idle, 100, 100 + idle, 100], processorCount: 8, memoryPressure: 1),
              loadAverage: load)
    }

    private func resourceGate(_ dir: String, sample: SpawnAdmission.ResourceSample?,
                              pressure: Int? = 1, at: Double = 101) -> SpawnAdmission {
        var admission = gate(dir)
        admission.resourceMode = .darwin
        admission.sampleResources = { sample }
        admission.memoryPressure = { pressure }
        admission.currentProcessorCount = { 8 }
        admission.monotonicNow = { at }
        return admission
    }

    @Test func darwinCapacityAdmitsHighLoadAndUnavailableDiagnosticAtThresholds() throws {
        for load in [100, nil, .nan, .infinity, -1] as [Double?] {
            let dir = try directory(); defer { try? FileManager.default.removeItem(atPath: dir) }
            // Exact 20% idle and maximum 2s freshness are admissible. Diagnostic
            // load cannot veto this capacity decision, including a failed read.
            let admission = resourceGate(dir, sample: resourceSample(load: load), at: 103)
            let verdict = try admission.admit(kind: .learner) { _ in
                let state = try admission.readState()
                #expect(state?.lastSpawnAt == 10_000)
                return 42
            }
            #expect(verdict == .admitted(pid: 42))
        }
        var sample = resourceSample(); sample.completedAt = 102
        #expect(SpawnAdmission.resourceVerdict(sample, at: 102, finalPressure: 1, finalProcessorCount: 8) == nil)
    }

    @Test func darwinCPUAndMemoryPressureRefuseWithoutTimestampOrLaunch() throws {
        let unavailable = SpawnAdmission.Verdict.refusedUnavailable(reason: "resource_unavailable")
        var cases: [(SpawnAdmission.ResourceSample?, Int?, SpawnAdmission.Verdict)] = [
            (resourceSample(idle: 19, load: 0), 1, .refusedCPU(idleFraction: 0.19, minimum: 0.2)),
            (nil, 1, unavailable), (resourceSample(), nil, unavailable),
            (resourceSample(), 0, unavailable), (resourceSample(), 3, unavailable),
            (resourceSample(), 2, .refusedMemoryPressure(level: 2)),
            (resourceSample(), 4, .refusedMemoryPressure(level: 4)),
        ]
        for pressure in [2, 4, 0, 3] {
            var first = resourceSample(load: 0); first.first.memoryPressure = pressure
            var second = resourceSample(load: 0); second.second.memoryPressure = pressure
            let expected: SpawnAdmission.Verdict = [2, 4].contains(pressure)
                ? .refusedMemoryPressure(level: pressure) : unavailable
            cases.append((first, 1, expected)); cases.append((second, 1, expected))
        }
        var mixed = resourceSample(load: 0)
        mixed.first.memoryPressure = 2; mixed.second.memoryPressure = 4
        cases.append((mixed, 1, .refusedMemoryPressure(level: 4)))
        cases.append((mixed, 2, .refusedMemoryPressure(level: 4)))
        for (sample, finalPressure, expected) in cases {
            let dir = try directory(); defer { try? FileManager.default.removeItem(atPath: dir) }
            let verdict = try resourceGate(dir, sample: sample, pressure: finalPressure).admit(kind: .learner) { _ in
                Issue.record("resource refusal must not launch"); return 1
            }
            #expect(verdict == expected)
            #expect(!FileManager.default.fileExists(atPath: dir + "/spawn-state.json"))
        }
    }

    @Test func darwinTimingAndCounterAmbiguityFailClosed() {
        let unavailable = SpawnAdmission.Verdict.refusedUnavailable(reason: "resource_unavailable")
        var invalid: [SpawnAdmission.ResourceSample] = []
        for start in [-1, .nan, .infinity] {
            var sample = resourceSample(); sample.startedAt = start; invalid.append(sample)
        }
        for end in [100, 100.999, 102.001, .nan, .infinity] {
            var sample = resourceSample(); sample.completedAt = end; invalid.append(sample)
        }
        var reset = resourceSample(); reset.second.ticks[0] = 99; invalid.append(reset)
        var stopped = resourceSample(); stopped.second.ticks = stopped.first.ticks; invalid.append(stopped)
        var changedCPU = resourceSample(); changedCPU.second.processorCount = 4; invalid.append(changedCPU)
        var noCPU = resourceSample(); noCPU.first.processorCount = 0; noCPU.second.processorCount = 0; invalid.append(noCPU)
        var wrongShape = resourceSample(); wrongShape.first.ticks = [100, 100, 100]; invalid.append(wrongShape)
        var overflow = resourceSample(); overflow.second.ticks[0] = UInt64(UInt32.max) + 1; invalid.append(overflow)
        for sample in invalid {
            #expect(SpawnAdmission.resourceVerdict(sample, at: 102, finalPressure: 1, finalProcessorCount: 8) == unavailable)
        }
        for time in [100.999, 103.001, .nan, .infinity] {
            #expect(SpawnAdmission.resourceVerdict(resourceSample(), at: time, finalPressure: 1, finalProcessorCount: 8) == unavailable)
        }
    }

    @Test func darwinCPUSetChangeAfterSamplingRefusesBeforeTimestamp() throws {
        for count in [nil, 0, 4, 65_537] as [Int?] {
            let dir = try directory(); defer { try? FileManager.default.removeItem(atPath: dir) }
            var admission = resourceGate(dir, sample: resourceSample())
            admission.currentProcessorCount = { count }
            #expect(try admission.admit(kind: .learner) { _ in Issue.record("changed CPU set launched"); return 1 }
                    == .refusedUnavailable(reason: "resource_unavailable"))
            #expect(!FileManager.default.fileExists(atPath: dir + "/spawn-state.json"))
        }
        var invalid = resourceSample()
        invalid.first.processorCount = 65_537; invalid.second.processorCount = 65_537
        #expect(SpawnAdmission.resourceVerdict(invalid, at: 101, finalPressure: 1, finalProcessorCount: 65_537)
                == .refusedUnavailable(reason: "resource_unavailable"))
    }

    @Test func darwinSamplingReleasesLeaseAndFinalPressureRunsUnderReacquiredLease() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let sample = resourceSample()
        var admission = resourceGate(dir, sample: sample)
        admission.sampleResources = {
            let fd = open(dir + "/spawn.lock", O_RDWR | O_CLOEXEC)
            #expect(fd >= 0)
            if fd >= 0 {
                #expect(flock(fd, LOCK_EX | LOCK_NB) == 0, "the sampler must hold no shared admission lease")
                close(fd)
            }
            #expect(!FileManager.default.fileExists(atPath: dir + "/spawn-state.json"))
            return sample
        }
        admission.memoryPressure = {
            let fd = open(dir + "/spawn.lock", O_RDWR | O_CLOEXEC)
            #expect(fd >= 0)
            if fd >= 0 {
                #expect(flock(fd, LOCK_EX | LOCK_NB) != 0, "final pressure must be checked under the fresh lease")
                close(fd)
            }
            return 1
        }
        #expect(try admission.admit(kind: .learner) { _ in 8 } == .admitted(pid: 8))
    }

    @Test func darwinConcurrencyAndCooldownSkipResourceSampling() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var admission = resourceGate(dir, sample: nil)
        admission.sampleResources = { Issue.record("refused preflight sampled resources"); return nil }
        admission.memoryPressure = { Issue.record("refused preflight queried pressure"); return nil }
        var held: Int32 = -1
        defer { if held >= 0 { close(held) } }
        _ = try gate(dir).admit(kind: .learner) { fd in held = dup(fd); return 1 }
        #expect(try admission.admit(kind: .learner) { _ in 2 } == .refusedConcurrent)
        close(held); held = -1
        #expect(try admission.admit(kind: .learner) { _ in 2 } == .refusedCooldown(secondsRemaining: 600))
    }

    private final class HeldDescriptor: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int32 = -1
        func store(_ fd: Int32) { lock.lock(); defer { lock.unlock() }; value = fd }
        func closeOwned() { lock.lock(); defer { lock.unlock() }; if value >= 0 { close(value); value = -1 } }
        deinit { closeOwned() }
    }

    @Test func darwinContenderCanWinDuringSampleAndFinalPassRefuses() throws {
        for retainLease in [false, true] {
            let dir = try directory(); defer { try? FileManager.default.removeItem(atPath: dir) }
            let sample = resourceSample(); let contender = gate(dir); let held = HeldDescriptor()
            defer { held.closeOwned() }
            var admission = resourceGate(dir, sample: sample)
            admission.sampleResources = {
                let winner = try? contender.admit(kind: .maintenance) { fd in
                    if retainLease { held.store(dup(fd)) }
                    return 55
                }
                #expect(winner == .admitted(pid: 55))
                return sample
            }
            admission.memoryPressure = { Issue.record("lost final admission queried pressure"); return nil }
            let verdict = try admission.admit(kind: .learner) { _ in Issue.record("losing contender launched"); return 1 }
            #expect(verdict == (retainLease ? .refusedConcurrent : .refusedCooldown(secondsRemaining: 600)))
            #expect(try contender.readState()?.lastSpawnAt == 10_000)
        }
    }

    @Test func darwinLockReplacementDuringSampleRefuses() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let sample = resourceSample()
        var admission = resourceGate(dir, sample: sample)
        admission.sampleResources = {
            // Retain the old inode so the replacement cannot reuse its number.
            let old = open(dir + "/spawn.lock", O_RDONLY | O_CLOEXEC)
            #expect(old >= 0)
            defer { if old >= 0 { close(old) } }
            #expect(unlink(dir + "/spawn.lock") == 0)
            let replacement = open(dir + "/spawn.lock", O_CREAT | O_RDWR | O_EXCL, 0o600)
            #expect(replacement >= 0)
            if replacement >= 0 { close(replacement) }
            return sample
        }
        #expect(try admission.admit(kind: .learner) { _ in Issue.record("replaced lease launched"); return 1 }
                == .refusedUnavailable(reason: "admission_identity_changed"))
        #expect(!FileManager.default.fileExists(atPath: dir + "/spawn-state.json"))
    }

    private final class LockedClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double
        init(_ value: Double) { self.value = value }
        func set(_ value: Double) { lock.lock(); defer { lock.unlock() }; self.value = value }
        func read() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test func darwinStaleAfterFinalPressureReadRefusesWithoutTimestamp() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let clock = LockedClock(101)
        var admission = resourceGate(dir, sample: resourceSample())
        admission.memoryPressure = { clock.set(103.001); return 1 }
        admission.monotonicNow = { clock.read() }
        #expect(try admission.admit(kind: .learner) { _ in Issue.record("stale sample launched"); return 1 }
                == .refusedUnavailable(reason: "resource_unavailable"))
        #expect(!FileManager.default.fileExists(atPath: dir + "/spawn-state.json"))
    }

}
