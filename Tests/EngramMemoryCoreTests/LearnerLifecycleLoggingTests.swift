import Foundation
import Testing
@testable import EngramMemoryCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Suite("LearnerLifecycleLogging")
struct LearnerLifecycleLoggingTests {
    @Test func sessionIdentityIsOptionalBoundedAndFilenameSafe() {
        for value in [nil, "", "../other", "a/b", "a\nb", "'$(touch unsafe)'", "💡", String(repeating: "a", count: 129)] as [String?] {
            #expect(LearnerLogContext(sessionId: value, trigger: .stop) == nil)
        }
        #expect(LearnerLogContext(sessionId: String(repeating: "a", count: 128), trigger: .stop) != nil)
        #expect(LearnerLogContext(sessionId: "01a0-session_A", trigger: .autoPrecompact) != nil)
    }

    @Test func eachLaunchGetsFreshIdentityAtTheExistingSessionPath() throws {
        let context = try #require(LearnerLogContext(sessionId: "selected-session", trigger: .stop))
        let first = LearnerLifecycleLog(context: context, directory: "/example/logs")
        let second = LearnerLifecycleLog(context: context, directory: "/example/logs")
        #expect(first.path == sessionLogPath(sessionId: "selected-session", directory: "/example/logs"))
        #expect(first.path == "/example/logs/debug-selected-session.log")
        #expect(first.runId != second.runId)
    }

    @Test func defaultNilKeepsOrdinaryChildOutputAndPostCommand() throws {
        let f = try LifecycleFixture()
        defer { f.remove() }
        let process = try f.start(log: nil, code: 7)
        try f.wait(process)
        #expect(try f.text("shared.log").contains("spawned claude exited 7"))
        #expect(try f.text("shared.log").contains("private-fake-output"))
        #expect(f.exists("post-command"))
        #expect(!f.command(log: nil).contains("learner_child_"))
        #expect(!f.command(log: nil).contains("/bin/date"))
        #expect(f.command(log: nil).contains("--no-session-persistence"))
        #expect(f.command(log: nil).contains("--max-turns 15"))
    }

    @Test func pairedExitCodesAreSelfContainedWithoutChildOutput() throws {
        for code in [0, 7] {
            let f = try LifecycleFixture()
            defer { f.remove() }
            let log = try f.log(trigger: code == 0 ? .stop : .autoPrecompact)
            let process = try f.start(log: log, code: code)
            try f.wait(process)
            let lines = try String(contentsOfFile: log.path, encoding: .utf8).split(separator: "\n")
            #expect(lines.count == 2)
            #expect(lines[0].contains("learner_child_started"))
            #expect(lines[1].contains("learner_child_exited"))
            #expect(lines[1].contains("exit_code=\(code)"))
            for line in lines {
                #expect(line.contains("session_id=selected-session"))
                #expect(line.contains("trigger=\(log.context.trigger.rawValue)"))
                #expect(line.contains("run_id=\(log.runId.uuidString)"))
                #expect(line.contains("child_pid="))
                #expect(ISO8601DateFormatter().date(from: String(line.prefix(20))) != nil)
                #expect(!line.contains("private-fake-output"))
            }
            #expect(f.exists("post-command"))
            #expect(try f.text("shared.log").contains("private-fake-output"))
        }
    }

    @Test func quotedPathCannotExecuteShellSyntax() throws {
        let f = try LifecycleFixture()
        defer { f.remove() }
        let directory = f.root.appendingPathComponent("quote'$(touch INJECTED)-%s").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let context = try #require(LearnerLogContext(sessionId: "selected-session", trigger: .stop))
        let log = LearnerLifecycleLog(context: context, directory: directory)
        let process = try f.start(log: log, code: 0)
        try f.wait(process)
        #expect(try String(contentsOfFile: log.path, encoding: .utf8).contains("exit_code=0"))
        #expect(!f.exists("INJECTED"))
    }

    @Test func unusableDestinationsDoNotChangeExitOrCleanup() throws {
        for kind in ["directory", "fifo", "symlink", "missing-parent", "unwritable"] {
            let f = try LifecycleFixture()
            defer { f.remove() }
            let log = try f.log()
            switch kind {
            case "directory":
                try FileManager.default.createDirectory(atPath: log.path, withIntermediateDirectories: true)
            case "fifo":
                #expect(mkfifo(log.path, 0o600) == 0)
            case "symlink":
                try FileManager.default.createSymbolicLink(atPath: log.path, withDestinationPath: f.root.appendingPathComponent("absent-target").path)
            case "missing-parent":
                try FileManager.default.removeItem(atPath: URL(fileURLWithPath: log.path).deletingLastPathComponent().path)
            default:
                FileManager.default.createFile(atPath: log.path, contents: Data())
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: log.path)
            }
            let process = try f.start(log: log, code: 7)
            try f.wait(process)
            #expect(try f.text("shared.log").contains("spawned claude exited 7"))
            #expect(f.exists("post-command"))
            #expect(!f.exists("absent-target"))
            #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("tmp").path).isEmpty)
        }
    }

    @Test func watchdogStillTerminatesChildAndRetainsObservedStatus() throws {
        let f = try LifecycleFixture()
        defer { f.remove() }
        let log = try f.log()
        let process = try f.start(log: log, code: 0, sleep: 10, wallClockSeconds: 1)
        try f.wait(process)
        let terminal = try String(contentsOfFile: log.path, encoding: .utf8)
        #expect(terminal.contains("exit_code=143"))
        #expect(try f.text("shared.log").contains("spawned claude exited 143"))
        #expect(f.exists("post-command"))
    }

    @Test func detachedChildFinishesAfterLaunchingParentExits() throws {
        let f = try LifecycleFixture()
        defer { f.remove() }
        let log = try f.log()
        let parent = try f.start(log: log, code: 7, sleep: 1, detach: true)
        try f.wait(parent)
        #expect(!f.exists("post-command"))
        let deadline = Date().addingTimeInterval(5)
        while !f.exists("post-command"), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(f.exists("post-command"))
        let lines = try String(contentsOfFile: log.path, encoding: .utf8)
        #expect(lines.contains("learner_child_started"))
        #expect(lines.contains("learner_child_exited"))
        #expect(lines.contains("exit_code=7"))
    }
}

private struct LifecycleFixture {
    let root: URL

    init() throws {
        let base = ProcessInfo.processInfo.environment["ENGRAM_TEST_TMPDIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        root = base.appendingPathComponent("learner-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        let script = "#!/bin/sh\nprintf '%s\\n' private-fake-output\nif [ \"$FAKE_SLEEP\" -gt 5 ]; then exec /bin/sleep \"$FAKE_SLEEP\"; fi\nif [ \"$FAKE_SLEEP\" -gt 0 ]; then exec /bin/sh -c 'sleep \"$FAKE_SLEEP\"; exit \"$FAKE_CODE\"'; fi\nexit \"$FAKE_CODE\"\n"
        try script.write(to: root.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("claude").path)
    }

    func log(trigger: LearnerLogContext.Trigger = .stop) throws -> LearnerLifecycleLog {
        let directory = root.appendingPathComponent("session-logs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let context = try #require(LearnerLogContext(sessionId: "selected-session", trigger: trigger))
        return LearnerLifecycleLog(context: context, directory: directory.path)
    }

    func command(log: LearnerLifecycleLog?, wallClockSeconds: Int = 5) -> String {
        claudeSubprocessShellCommand(
            prompt: "fake prompt", systemPrompt: "fake system", allowedTools: "Read", model: "fake",
            logPath: root.appendingPathComponent("shared.log").path,
            postCommand: "touch '\(root.appendingPathComponent("post-command").path)'",
            wallClockSeconds: wallClockSeconds, lifecycleLog: log)
    }

    func start(log: LearnerLifecycleLog?, code: Int, sleep: Int = 0,
               wallClockSeconds: Int = 5, detach: Bool = false) throws -> Process {
        let p = Process()
        let body = command(log: log, wallClockSeconds: wallClockSeconds)
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", detach ? "/bin/sh -c '" + body.replacingOccurrences(of: "'", with: "'\\''") + "' >/dev/null 2>&1 &" : body]
        p.environment = ["PATH": root.path + ":/usr/bin:/bin", "TMPDIR": root.appendingPathComponent("tmp").path,
                         "FAKE_CODE": String(code), "FAKE_SLEEP": String(sleep)]
        p.currentDirectoryURL = root
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    func wait(_ process: Process) throws {
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate(); throw FixtureError.timedOut }
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    func text(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }
    func remove() { try? FileManager.default.removeItem(at: root) }
    private enum FixtureError: Error { case timedOut }
}
