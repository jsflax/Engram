import Foundation
import Testing
@testable import EngramMemoryCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite("OwnedProcessGuard")
struct OwnedProcessGuardTests {
    @Test func shellLaunchClearsChildMaskWithoutChangingPendingCallerSignals() throws {
        let fixture = try GuardFixture()
        defer { fixture.remove() }
        var blocked = sigset_t(), original = sigset_t()
        sigemptyset(&blocked)
        for value in [SIGCHLD, SIGTERM, SIGINT, SIGHUP, SIGUSR2] { sigaddset(&blocked, value) }
        try #require(pthread_sigmask(SIG_BLOCK, &blocked, &original) == 0)
        var queuedOwnSignal = false
        defer {
            var pending = sigset_t(); sigpending(&pending)
            if queuedOwnSignal, sigismember(&pending, SIGUSR2) == 1 {
                var selected = sigset_t(); sigemptyset(&selected); sigaddset(&selected, SIGUSR2)
                var consumed: Int32 = 0
                #expect(sigwait(&selected, &consumed) == 0)
                #expect(consumed == SIGUSR2)
            }
            #expect(pthread_sigmask(SIG_SETMASK, &original, nil) == 0)
        }
        var expectedMask = sigset_t(), beforePending = sigset_t()
        #expect(pthread_sigmask(SIG_SETMASK, nil, &expectedMask) == 0)
        #expect(sigpending(&beforePending) == 0)
        try #require(sigismember(&beforePending, SIGUSR2) == 0)
        let queued = pthread_kill(pthread_self(), SIGUSR2)
        queuedOwnSignal = queued == 0
        try #require(queued == 0)
        func callerUnchanged() {
            var actual = sigset_t(), pending = sigset_t()
            #expect(pthread_sigmask(SIG_SETMASK, nil, &actual) == 0)
            for value: Int32 in 1...31 {
                #expect(sigismember(&actual, value) == sigismember(&expectedMask, value))
            }
            #expect(sigpending(&pending) == 0)
            #expect(sigismember(&pending, SIGUSR2) == 1)
        }
        func shell(_ body: String) -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", body]
            process.currentDirectoryURL = fixture.root
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            return process
        }
        let process = shell("printf '%s' \"$$\" > shell.pid; /bin/sleep 0.01 & wait $!; exit 7")
        _ = try launchClaudeShell(process, lease: nil, guardExecutable: fixture.guardPath)
        defer { fixture.finish(process) }
        callerUnchanged()
        try fixture.wait(process)
        #expect(process.terminationStatus == 7)
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("shell.pid"), encoding: .utf8) == String(process.processIdentifier))
        #if os(Linux)
        // Linux Foundation inherits the blocked mask. Deliberately bypass
        // exec-shell and carry pending TERM across exec: handlers must be installed
        // before unblocking, and cancellation must prevent provider creation.
        let quote = { (value: String) in "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let pendingGuard = shell("kill -TERM $$; exec " + quote(fixture.guardPath)
            + " internal-process-guard --wall-seconds 2 -- /usr/bin/touch "
            + quote(fixture.root.appendingPathComponent("must-not-launch").path))
        try pendingGuard.run()
        defer { fixture.finish(pendingGuard) }
        try fixture.wait(pendingGuard)
        #expect(pendingGuard.terminationReason == .exit)
        #expect(pendingGuard.terminationStatus == 143)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("must-not-launch").path))
        #endif
        callerUnchanged()
        #expect(throws: OwnedProcessGuard.Failure.self) {
            try launchClaudeShell(shell("exit 0"), lease: nil, guardExecutable: fixture.guardPath + "\0")
        }
        callerUnchanged()
        let failed = shell("exit 0")
        failed.currentDirectoryURL = fixture.root.appendingPathComponent("missing-directory")
        #expect(throws: (any Error).self) {
            try launchClaudeShell(failed, lease: nil, guardExecutable: fixture.guardPath)
        }
        callerUnchanged()
        for arguments in [["--exec-shell"], ["--exec-shell", ""], ["--exec-shell", "exit 0", "extra"],
                          ["--exec-shell", "exit\0 0"], ["--exec-shell", "exit 0", "--wall-seconds", "2"],
                          ["--wall-seconds", "-1", "--", "/bin/sh"],
                          ["--wall-seconds", "2", "--lease-fd", "0", "--", "/bin/sh"]] {
            #expect(throws: OwnedProcessGuard.Failure.self) { try OwnedProcessGuard.runCommand(arguments: arguments) }
            callerUnchanged()
        }
    }

    @Test func queuedCancellationDoesNotCreateProvider() throws {
        let fixture = try GuardFixture()
        defer { fixture.remove() }
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        defer { close(descriptors[0]); close(descriptors[1]) }
        #expect(fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0)
        var cancellation = SIGTERM
        #expect(write(descriptors[1], &cancellation, MemoryLayout<Int32>.size) == MemoryLayout<Int32>.size)
        let marker = fixture.root.appendingPathComponent("must-not-launch").path
        let quote = "'" + marker.replacingOccurrences(of: "'", with: "'\\''") + "'"
        #expect(try OwnedProcessGuard.run(command: ["/bin/sh", "-c", "touch \(quote)"],
            wallSeconds: 2, cancellationFD: descriptors[0]) == 143)
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test func exactReapedNormalAndSignalStatuses() throws {
        #expect(try OwnedProcessGuard.run(command: ["/bin/sh", "-c", "exit 7"], wallSeconds: 2) == 7)
        #expect(try OwnedProcessGuard.run(command: ["/bin/sh", "-c", "kill -TERM $$"], wallSeconds: 2) == 143)
        #expect(throws: OwnedProcessGuard.Failure.self) {
            try OwnedProcessGuard.run(command: ["/engram-fixture-absent/executable"], wallSeconds: 2)
        }
    }

    @Test func timeoutReapsTermIgnoringProviderBeforeReleasingLease() throws {
        let fixture = try GuardFixture()
        defer { fixture.remove() }
        let process = try fixture.start(wallSeconds: 1)
        defer { fixture.finish(process) }
        let provider = try fixture.waitForProvider()
        #expect(try fixture.attempt() == .refusedConcurrent)
        try fixture.wait(process)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 137)
        #expect(kill(provider, 0) == -1 && errno == ESRCH)
        #expect(try fixture.attempt() == .admitted(pid: 99))
    }

    @Test func cancellationEscalatesWithoutDroppingProviderLease() throws {
        let fixture = try GuardFixture()
        defer { fixture.remove() }
        let process = try fixture.start(wallSeconds: 30)
        defer { fixture.finish(process) }
        let provider = try fixture.waitForProvider()
        process.terminate()
        Thread.sleep(forTimeInterval: 0.1)
        #expect(process.isRunning, "TERM-ignoring provider must still have a guard during its grace period")
        #expect(try fixture.attempt() == .refusedConcurrent)
        try fixture.wait(process)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 137)
        #expect(kill(provider, 0) == -1 && errno == ESRCH)
        #expect(try fixture.attempt() == .admitted(pid: 99))
    }

    @Test func deadlineReapsProviderAfterItMovesProcessGroup() throws {
        let fixture = try GuardFixture()
        defer { fixture.remove() }
        let process = try fixture.start(wallSeconds: 1, movedGroup: true)
        defer { fixture.finish(process) }
        let provider = try fixture.waitForProvider()
        #expect(getpgid(provider) == getpgid(process.processIdentifier))
        #expect(getpgid(provider) != provider, "stand-in must have left its original provider group")
        #expect(try fixture.attempt() == .refusedConcurrent)
        try fixture.wait(process)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 137)
        #expect(kill(provider, 0) == -1 && errno == ESRCH)
        #expect(try fixture.attempt() == .admitted(pid: 99))
    }

    @Test func wrapperDeathAndProviderFDClosureDoNotReleaseGuardLease() throws {
        let fixture = try GuardFixture()
        defer { fixture.remove() }
        let process = try fixture.start(wallSeconds: 1, detachedWrapper: true)
        defer { fixture.finish(process) }
        let provider = try fixture.waitForProvider()
        process.terminate()
        try fixture.waitForWrapperExit(process)
        #expect(try fixture.attempt() == .refusedConcurrent)
        #expect(kill(provider, 0) == 0)
        let deadline = Date().addingTimeInterval(8)
        while kill(provider, 0) == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(kill(provider, 0) == -1 && errno == ESRCH)
        // Guard closes its descriptor immediately after reaping. Wait for that
        // close without admitting a second real provider in the test.
        var verdict = try fixture.attempt()
        while verdict == .refusedConcurrent, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            verdict = try fixture.attempt()
        }
        #expect(verdict == .admitted(pid: 99))
        try fixture.wait(process)
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGTERM)
    }
}

private struct GuardFixture {
    let root: URL
    let guardPath: String

    init() throws {
        guardPath = try #require(ProcessInfo.processInfo.environment["ENGRAM_TEST_PROCESS_GUARD"])
        let base = ProcessInfo.processInfo.environment["ENGRAM_TEST_TMPDIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        root = base.appendingPathComponent("owned-process-guard-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // The real stand-in deliberately closes fd 3 and ignores TERM before
        // publishing readiness. exec preserves its PID and ignored disposition.
        let script = "#!/bin/sh\ntrap '' TERM\nexec 3<&-\nprintf '%s' \"$$\" > provider.pid\nexec /bin/sleep 30\n"
        try script.write(to: root.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("claude").path)
    }

    func gate() -> SpawnAdmission {
        var policy = SpawnAdmission.Policy(); policy.cooldownSeconds = 0
        return SpawnAdmission(stateDirectory: root.path, policy: policy,
            now: { Date(timeIntervalSince1970: 10_000) }, loadAverage: { 0 }, processorCount: 2)
    }

    func attempt() throws -> SpawnAdmission.Verdict { try gate().admit(kind: .learner) { _ in 99 } }

    func start(wallSeconds: Int, detachedWrapper: Bool = false, movedGroup: Bool = false) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.currentDirectoryURL = root
        process.environment = ["PATH": root.path + ":/usr/bin:/bin", "TMPDIR": root.path]
        let quote = { (value: String) in "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        if detachedWrapper {
            process.arguments = ["-c", claudeSubprocessShellCommand(prompt: "p", systemPrompt: "s", allowedTools: "Read",
                model: "fake", logPath: root.appendingPathComponent("child.log").path, wallClockSeconds: wallSeconds,
                inheritsAdmissionLease: true, guardExecutable: guardPath)]
        } else {
            // exec makes Foundation's owned child the guard itself, so the
            // cancellation test targets the actual production signal handler.
            let provider = movedGroup
                ? "\(quote(guardPath)) provider-join-guard-group \(quote(root.appendingPathComponent("provider.pid").path))"
                : quote(root.appendingPathComponent("claude").path)
            process.arguments = ["-c", "exec 3<&0; exec </dev/null; exec \(quote(guardPath)) internal-process-guard --wall-seconds \(wallSeconds) --lease-fd 3 -- \(provider)"]
        }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let verdict = try gate().admit(kind: .learner) { fd in try launchClaudeShell(process, lease: fd, guardExecutable: guardPath) }
        guard verdict.isAdmitted else { throw FixtureError.notAdmitted }
        return process
    }

    func waitForProvider() throws -> pid_t {
        let marker = root.appendingPathComponent("provider.pid")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let text = try? String(contentsOf: marker, encoding: .utf8), let pid = pid_t(text), pid > 1 { return pid }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw FixtureError.timedOut
    }

    func waitForWrapperExit(_ process: Process) throws {
        #if os(Linux)
        // Detached descendants retain Foundation's notification socket. Observe
        // the exact wrapper's kernel exit, leaving Foundation its eventual reap.
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning, Date() < deadline {
            var info = siginfo_t()
            let result = waitid(P_PID, id_t(process.processIdentifier), &info, WEXITED | WNOWAIT | WNOHANG)
            if result == 0, info.si_signo == SIGCHLD {
                #expect(info.si_code == CLD_KILLED)
                return
            }
            if result < 0, errno != EINTR, errno != ECHILD { throw POSIXError(.EIO) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard !process.isRunning else { throw FixtureError.timedOut }
        #else
        try wait(process)
        #endif
    }

    func wait(_ process: Process) throws {
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard !process.isRunning else { throw FixtureError.timedOut }
        process.waitUntilExit()
    }

    func finish(_ process: Process) {
        // Cleanup cancellation goes to the guard, never an unowned provider PID.
        // Detached-wrapper tests use a one-second deadline for the orphan guard.
        if process.isRunning { process.terminate(); process.waitUntilExit() }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    private enum FixtureError: Error { case timedOut, notAdmitted }
}
