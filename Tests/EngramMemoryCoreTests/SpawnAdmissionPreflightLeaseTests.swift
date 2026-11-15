import Foundation
import Testing
@testable import EngramMemoryCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Suite("Spawn admission preflight lease ownership")
struct SpawnAdmissionPreflightLeaseTests {
    @Test func preflightReleasesItsLockEvenWhenItsDescriptorWasDuplicated() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let probe = AdmissionLeaseProbe()
        defer { probe.closeOwned() }
        let path = directory + "/spawn.lock"
        var admission = SpawnAdmission(stateDirectory: directory,
            now: { probe.nowRetainingFirstLease(at: path) },
            loadAverage: { 1 }, processorCount: 8)
        admission.resourceMode = .darwin
        admission.sampleResources = { probe.record(.sample); return nil }
        admission.memoryPressure = { probe.record(.pressure); return 1 }
        admission.currentProcessorCount = { 8 }
        admission.monotonicNow = { 101 }

        let verdict = try admission.admit(kind: .learner) { _ in
            probe.record(.launch)
            return 42
        }
        let snapshot = probe.snapshot()
        #expect(snapshot.failures.isEmpty)
        #expect(snapshot.ownsOpenDescriptor)
        #expect(snapshot.closeOnExec)
        #expect(snapshot.clockReads == 2)
        #expect(snapshot.samples == 1)
        #expect(snapshot.pressureReads == 1)
        #expect(snapshot.launches == 0)
        #expect(verdict == .refusedUnavailable(reason: "resource_unavailable"))
        #expect(!FileManager.default.fileExists(atPath: directory + "/spawn-state.json"))
    }

    @Test func finalLeaseRemainsHeldUntilTheLaunchedOwnersDuplicateCloses() throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let probe = AdmissionLeaseProbe()
        defer { probe.closeOwned() }
        var admission = SpawnAdmission(stateDirectory: directory,
            now: { Date(timeIntervalSince1970: 10_000) },
            loadAverage: { 1 }, processorCount: 8)
        admission.resourceMode = .darwin
        admission.sampleResources = {
            probe.record(.sample)
            return .init(startedAt: 100, completedAt: 101,
                first: .init(ticks: [100, 100, 100, 100], processorCount: 8, memoryPressure: 1),
                second: .init(ticks: [180, 100, 120, 100], processorCount: 8, memoryPressure: 1),
                loadAverage: 1)
        }
        admission.memoryPressure = { probe.record(.pressure); return 1 }
        admission.currentProcessorCount = { 8 }
        admission.monotonicNow = { 101 }
        let admitted = try admission.admit(kind: .learner) { fd in
            probe.record(.launch)
            probe.retainDuplicate(of: fd)
            return 42
        }
        #expect(admitted == .admitted(pid: 42))
        let retained = probe.snapshot()
        #expect(retained.failures.isEmpty)
        try #require(retained.ownsOpenDescriptor)
        #expect(retained.closeOnExec)

        // Advance beyond cooldown: only the live final lease may refuse this call.
        admission.now = { Date(timeIntervalSince1970: 11_000) }
        let refused = try admission.admit(kind: .maintenance) { _ in
            probe.record(.launch)
            return 43
        }
        #expect(refused == .refusedConcurrent)
        let held = probe.snapshot()
        #expect(held.ownsOpenDescriptor)
        #expect(held.samples == 1)
        #expect(held.pressureReads == 1)
        #expect(held.launches == 1)

        probe.closeOwned()
        let afterRelease = try admission.admit(kind: .maintenance) { _ in
            probe.record(.launch)
            return 44
        }
        #expect(afterRelease == .admitted(pid: 44))
        let released = probe.snapshot()
        #expect(!released.ownsOpenDescriptor)
        #expect(released.samples == 2)
        #expect(released.pressureReads == 2)
        #expect(released.launches == 2)
    }

    private func fixtureDirectory() throws -> String {
        let base = ProcessInfo.processInfo.environment["ENGRAM_TEST_TMPDIR"]
            ?? FileManager.default.temporaryDirectory.path
        let path = base + "/spawn-preflight-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return path
    }
}

/// Admission callbacks are Sendable; this lock protects every mutable field and
/// the sole owned descriptor. Enumerated descriptors are borrowed, never closed.
private final class AdmissionLeaseProbe: @unchecked Sendable {
    enum Event { case sample, pressure, launch }
    struct Snapshot {
        let failures: [String]
        let ownsOpenDescriptor: Bool
        let closeOnExec: Bool
        let clockReads: Int
        let samples: Int
        let pressureReads: Int
        let launches: Int
    }

    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var failures: [String] = []
    private var clockReads = 0
    private var samples = 0
    private var pressureReads = 0
    private var launches = 0

    deinit { closeOwned() }

    func nowRetainingFirstLease(at path: String) -> Date {
        lock.lock(); defer { lock.unlock() }
        clockReads += 1
        if clockReads == 1 {
            // now() runs after flock. Match this fixture's inode rather than
            // guessing a descriptor number or creating an independent open.
            var expected = stat()
            if lstat(path, &expected) != 0 {
                failures.append("Could not stat the admission lock")
            } else {
                do {
                    let names = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd")
                    let matches = names.compactMap { Int32($0) }.filter { fd in
                        var actual = stat()
                        return fstat(fd, &actual) == 0
                            && actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino
                    }
                    if matches.count == 1, let fd = matches.first {
                        duplicateLocked(fd)
                    } else {
                        failures.append("Expected exactly one descriptor for the admission lock; found \(matches.count)")
                    }
                } catch {
                    failures.append("Could not enumerate open descriptors")
                }
            }
        }
        return Date(timeIntervalSince1970: 10_000)
    }

    func retainDuplicate(of fd: Int32) {
        lock.lock(); defer { lock.unlock() }
        duplicateLocked(fd)
    }

    private func duplicateLocked(_ fd: Int32) {
        guard descriptor < 0 else {
            failures.append("A retained admission descriptor already exists")
            return
        }
        descriptor = fcntl(fd, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        if descriptor < 0 { failures.append("Could not duplicate the admission descriptor") }
    }

    func record(_ event: Event) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .sample: samples += 1
        case .pressure: pressureReads += 1
        case .launch: launches += 1
        }
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let flags = descriptor >= 0 ? fcntl(descriptor, F_GETFD) : -1
        return Snapshot(failures: failures, ownsOpenDescriptor: flags >= 0,
            closeOnExec: flags >= 0 && flags & FD_CLOEXEC != 0, clockReads: clockReads,
            samples: samples, pressureReads: pressureReads, launches: launches)
    }

    func closeOwned() {
        lock.lock(); defer { lock.unlock() }
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
    }
}
