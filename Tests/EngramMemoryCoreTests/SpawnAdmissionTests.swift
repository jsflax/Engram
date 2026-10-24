import Foundation
import Testing
@testable import EngramMemoryCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Suite("SpawnAdmission")
struct SpawnAdmissionTests {
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
    private func privateState(_ text: String, dir: String) throws {
        let path = dir + "/spawn-state.json"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    @Test func cooldownIsDurableBeforeSpawnAndSurvivesLaunchFailure() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(atPath: dir) }
        struct LaunchFailure: Error {}
        do {
            _ = try gate(dir).admit(kind: .learner) { _ in
                #expect(try gate(dir).readState()?.lastSpawnAt == 10_000)
                throw LaunchFailure()
            }
            Issue.record("launch should throw")
        } catch is LaunchFailure {}
        let verdict = try gate(dir, time: 10_300).admit(kind: .maintenance) { _ in
            Issue.record("cooldown must prevent launch"); return 1
        }
        #expect(verdict == .refusedCooldown(secondsRemaining: 300))
        #expect(try gate(dir, time: 10_601).admit(kind: .learner) { _ in 7 } == .admitted(pid: 7))
    }

    @Test func openDescriptorLifetimeHasNoClockOrPIDExpiry() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var held: Int32 = -1
        defer { if held >= 0 { close(held) } }
        _ = try gate(dir).admit(kind: .learner) { fd in held = dup(fd); return getpid() }
        #expect(held >= 0)
        let refused = try gate(dir, time: 10_000 + 365 * 86400).admit(kind: .maintenance) { _ in
            Issue.record("a year-old live lease must still refuse"); return 1
        }
        #expect(refused == .refusedConcurrent)
        close(held); held = -1
        #expect(try gate(dir, time: 10_601).admit(kind: .learner) { _ in 2 } == .admitted(pid: 2))
    }

    @Test func malformedUnsafeAndUnknownStateNeverLaunches() throws {
        for raw in ["{", "{}", #"{"version":1,"lastSpawnAt":0,"active":[]}"#,
                    #"{"version":2,"lastSpawnAt":0}"#, #"{"version":true,"lastSpawnAt":0}"#,
                    #"{"version":1,"lastSpawnAt":true}"#, #"{"version":1,"lastSpawnAt":-1}"#,
                    #"{"version":1,"lastSpawnAt":0,"lastSpawnAt":1}"#] {
            let dir = try directory(); defer { try? FileManager.default.removeItem(atPath: dir) }
            try privateState(raw, dir: dir)
            let verdict = try gate(dir).admit(kind: .learner) { _ in
                Issue.record("invalid state launched"); return 1
            }
            guard case .refusedUnavailable = verdict else { Issue.record("unexpected \(verdict)"); continue }
            #expect(try String(contentsOfFile: dir + "/spawn-state.json", encoding: .utf8) == raw)
        }
    }

    @Test func stateSymlinkAndPersistenceFailureRefuseBeforeLaunch() throws {
        for kind in ["symlink", "directory", "permissions"] {
            let dir = try directory(); defer { try? FileManager.default.removeItem(atPath: dir) }
            let path = dir + "/spawn-state.json"
            if kind == "symlink" {
                try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: dir + "/absent")
            } else if kind == "directory" {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
            } else {
                try privateState(#"{"version":1,"lastSpawnAt":0}"#, dir: dir)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
            }
            let verdict = try gate(dir).admit(kind: .learner) { _ in Issue.record("unsafe launch"); return 1 }
            guard case .refusedUnavailable = verdict else { Issue.record("unexpected \(verdict)"); continue }
        }
    }

    @Test func failedStatePersistenceDoesNotLaunch() throws {
        // A real permission failure at the durable write boundary; root can
        // bypass directory modes, so this fixture applies to ordinary CI users.
        guard getuid() != 0 else { return }
        let dir = try directory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
            try? FileManager.default.removeItem(atPath: dir)
        }
        let fd = open(dir + "/spawn.lock", O_CREAT | O_RDWR, 0o600)
        #expect(fd >= 0)
        if fd >= 0 { close(fd) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir)
        let verdict = try gate(dir).admit(kind: .learner) { _ in
            Issue.record("failed persistence must precede launch"); return 1
        }
        #expect(verdict == .refusedUnavailable(reason: "cooldown_state"))
        #expect(!FileManager.default.fileExists(atPath: dir + "/spawn-state.json"))
    }

    @Test func unavailableAndSaturatedLoadRefuseWithoutCooldown() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(atPath: dir) }
        for load in [nil, .nan, .infinity, -1] as [Double?] {
            let verdict = try gate(dir, load: load).admit(kind: .learner) { _ in Issue.record("load unavailable"); return 1 }
            #expect(verdict == .refusedUnavailable(reason: "load_unavailable"))
        }
        #expect(try gate(dir, load: 100).admit(kind: .learner) { _ in 1 } == .refusedLoad(loadAverage: 100, limit: 16))
        #expect(!FileManager.default.fileExists(atPath: dir + "/spawn-state.json"))
    }

    /// Exercises Foundation's actual stdio FD mapping plus the production shell
    /// command with a stand-in executable. No provider, store or global env edits.
    @Test func detachedShellOwnsLeaseUntilProviderExitEvenWhenProviderClosesFD() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let fake = dir + "/claude"
        try "#!/bin/sh\n[ -f callback ] || exit 97\nexec 3<&-\nprintf ready > ready\nwhile [ ! -f release ]; do sleep 0.02; done\nexit 7\n"
            .write(toFile: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        process.environment = ["PATH": dir + ":/usr/bin:/bin", "TMPDIR": dir]
        let guardPath = try #require(ProcessInfo.processInfo.environment["ENGRAM_TEST_PROCESS_GUARD"])
        process.arguments = ["-c", claudeSubprocessShellCommand(prompt: "p", systemPrompt: "s", allowedTools: "Read",
            model: "fake", logPath: dir + "/child.log", wallClockSeconds: 10, inheritsAdmissionLease: true,
            guardExecutable: guardPath)]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        defer {
            FileManager.default.createFile(atPath: dir + "/release", contents: Data())
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        let verdict = try gate(dir).admit(kind: .learner) { fd in
            try launchClaudeShell(process, lease: fd, guardExecutable: guardPath) {
                try "before launch".write(toFile: dir + "/callback", atomically: true, encoding: .utf8)
            }
        }
        #expect(verdict.isAdmitted)
        let readyDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: dir + "/ready"), Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(FileManager.default.fileExists(atPath: dir + "/ready"))
        #expect(try gate(dir, time: 99_999).admit(kind: .maintenance) { _ in 2 } == .refusedConcurrent)
        FileManager.default.createFile(atPath: dir + "/release", contents: Data())
        let exitDeadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < exitDeadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(!process.isRunning)
        if !process.isRunning { process.waitUntilExit() }
        #expect(try gate(dir, time: 99_999).admit(kind: .learner) { _ in 2 } == .admitted(pid: 2),
                "the guard must release its lease after provider/wrapper completion")
        #expect(try String(contentsOfFile: dir + "/child.log", encoding: .utf8).contains("exited 7"))
    }

    @Test func envGuardSelectsKindAndCommandPreservesNice() {
        #expect(SpawnOutcome.kind(forEnvGuard: "CLAUDE_MEMORY_LEARNER") == .learner)
        #expect(SpawnOutcome.kind(forEnvGuard: "CLAUDE_MEMORY_MAINTENANCE") == .maintenance)
        #expect(SpawnOutcome.kind(forEnvGuard: "CLAUDE_MEMORY_SYNC_RECONCILIATION") == .reconciliation)
        let command = claudeSubprocessShellCommand(prompt: "p", systemPrompt: "s", allowedTools: "Read",
                                                  model: "fake", logPath: "/fixture.log", guardExecutable: "/fixture/memory-hooks")
        #expect(command.contains("/usr/bin/nice -n 10 claude -p 'p'"))
    }
}
