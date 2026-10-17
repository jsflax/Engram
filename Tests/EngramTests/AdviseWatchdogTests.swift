import Foundation
import Darwin
import SQLite3
import Testing

// ============================================================================
// H1.6 (Aug 2026 incident): the advise hook must NEVER ride to the harness's
// silent 60s kill. When the memory database is wedged — a C++ frame stuck in
// an uninterruptible lock wait, past every in-process budget — the
// unconditional watchdog thread emits whatever context accumulated, plus a
// one-line degradation notice, and exits 0 at budget+2s.
//
// These are CHILD-PROCESS tests: they spawn the real hook binary (the
// EngramHooks executable `swift test` builds alongside the test bundle), so
// they exercise the actual process-exit contract, not a simulation of it.
// RED-FIRST: with the wedge seam engaged and the watchdog not armed, the
// child hangs and `watchdog_endsAWedgedHook` fails by kill-timeout.
// ============================================================================

/// Anchor class so `Bundle(for:)` finds the test bundle under both
/// `swift test` and Xcode.
private final class TestBundleFinder {}

/// The products directory the test bundle runs from — the hook binary and
/// the EngramKit resource bundle sit next to it.
private let productsDirectory: URL = {
    Bundle(for: TestBundleFinder.self).bundleURL.deletingLastPathComponent()
}()

private let hookBinary = productsDirectory.appendingPathComponent("EngramHooks")

private struct HookRun {
    let terminated: Bool
    let exitCode: Int32
    let stdout: String
    let seconds: Double
}

/// Drain while the child runs: waiting for exit before reading a pipe can
/// deadlock a healthy hook inside its final stdout write. A nonblocking reader
/// keeps the original kill deadline authoritative without a reader thread to
/// strand during cleanup.
private func runHookProcess(_ process: Process, input: Data,
                            killAfter: TimeInterval) throws -> HookRun {
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = FileHandle.nullDevice
    let outputFD = stdoutPipe.fileHandleForReading.fileDescriptor
    let flags = fcntl(outputFD, F_GETFL)
    guard flags >= 0, fcntl(outputFD, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        try? stdinPipe.fileHandleForReading.close()
        try? stdinPipe.fileHandleForWriting.close()
        try? stdoutPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
    }

    var data = Data()
    var reachedEOF = false
    var buffer = [UInt8](repeating: 0, count: 16_384)
    func drainOutput() throws -> Int {
        var drained = 0
        // Bound each pass so even an unexpectedly noisy child cannot prevent
        // the process/deadline check. The fixtures never need 4 MiB of output.
        while drained < 262_144 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(outputFD, $0.baseAddress, $0.count) }
            if count > 0 {
                guard data.count + count <= 4 * 1024 * 1024 else { throw POSIXError(.EFBIG) }
                data.append(contentsOf: buffer.prefix(count))
                drained += count
            } else if count == 0 {
                reachedEOF = true
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        return drained
    }

    let start = Date()
    try process.run()
    try? stdinPipe.fileHandleForReading.close()
    try? stdoutPipe.fileHandleForWriting.close()
    stdinPipe.fileHandleForWriting.write(input)
    stdinPipe.fileHandleForWriting.closeFile()

    while process.isRunning, Date().timeIntervalSince(start) < killAfter {
        _ = try drainOutput()
        var descriptor = pollfd(fd: outputFD, events: Int16(POLLIN | POLLHUP), revents: 0)
        if poll(&descriptor, 1, 50) < 0, errno != EINTR {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
    let terminated = !process.isRunning
    if !terminated { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
    let seconds = Date().timeIntervalSince(start)
    while !reachedEOF {
        let drained = try drainOutput()
        guard drained > 0 || reachedEOF else { throw POSIXError(.EIO) }
    }
    return HookRun(terminated: terminated, exitCode: process.terminationStatus,
                   stdout: String(data: data, encoding: .utf8) ?? "", seconds: seconds)
}

/// Spawn `EngramHooks advise` against an isolated HOME with the given env,
/// feed it a UserPromptSubmit payload, and SIGKILL it past `killAfter` —
/// the test's stand-in for the harness's kill timeout.
private func runAdvise(env extraEnv: [String: String], home: URL,
                       prompt: String, killAfter: TimeInterval) throws -> HookRun {
    let process = Process()
    process.executableURL = hookBinary
    process.arguments = ["advise"]

    var env = ProcessInfo.processInfo.environment
    env["HOME"] = home.path
    // The test environment must not leak a backend or recursion guard in.
    env.removeValue(forKey: "CLAUDE_MEMORY_MAINTENANCE")
    env.removeValue(forKey: "ENGRAM_URL")
    env.removeValue(forKey: "ENGRAM_TOKEN")
    env.removeValue(forKey: "ENGRAM_TEST_ADVISE_WEDGE_MS")
    for (key, value) in extraEnv { env[key] = value }
    process.environment = env

    let payload: [String: Any] = [
        "session_id": "watchdog-test-\(UUID().uuidString.prefix(8))",
        "cwd": "/tmp/engram-watchdog-project",
        "prompt": prompt,
    ]

    return try runHookProcess(process, input: JSONSerialization.data(withJSONObject: payload),
                              killAfter: killAfter)
}

private func makeTempHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("engram-watchdog-home-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    return home
}

/// additionalContext from the hook's JSON envelope, or nil if the output
/// doesn't parse — the output CONTRACT is part of what these tests pin.
private func additionalContext(of stdout: String) -> String? {
    guard let data = stdout.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let hookOutput = obj["hookSpecificOutput"] as? [String: Any],
          hookOutput["hookEventName"] as? String == "UserPromptSubmit" else { return nil }
    return hookOutput["additionalContext"] as? String
}

@Suite("Advise watchdog (child process)", .serialized)
struct AdviseWatchdogTests {

    @Test func largeHookOutputIsDrainedWhileChildIsRunning() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/dd")
        process.arguments = ["if=/dev/zero", "bs=16384", "count=64"]
        let run = try runHookProcess(process, input: Data(), killAfter: 12)
        #expect(run.terminated, "A full stdout pipe must not hold the child until its kill deadline")
        #expect(run.exitCode == 0)
        #expect(run.stdout.utf8.count == 1_048_576)
        #expect(run.stdout.utf8.allSatisfy { $0 == 0 })
    }

    /// The core H1.6 guarantee: a main path wedged in an uninterruptible
    /// blocking wait (the seam models the incident's stuck C++ lock frame)
    /// still produces a valid, degraded envelope and exit 0 at budget+2s —
    /// instead of hanging to the harness kill. RED without the watchdog:
    /// the child is still alive at `killAfter` and this test fails.
    @Test func watchdog_endsAWedgedHook_withDegradedOutput() throws {
        let home = try makeTempHome()
        let run = try runAdvise(
            env: [
                "CLAUDE_MEMORY_DB": home.appendingPathComponent("absent.sqlite").path,
                "ENGRAM_HOOK_RECALL_BUDGET_MS": "300",
                "ENGRAM_TEST_ADVISE_WEDGE_MS": "600000",
            ],
            home: home,
            prompt: "How did we fix the sync daemon deadlock in the engram hub database?",
            killAfter: 12)

        #expect(run.terminated,
                "hook wedged past the watchdog deadline — rode toward the harness kill (killed after \(run.seconds)s with no output)")
        #expect(run.exitCode == 0, "degraded exit must be 0, got \(run.exitCode)")
        // budget 0.3s + 2s watchdog + generous scheduling slack.
        #expect(run.seconds < 8, "watchdog fired late: \(run.seconds)s")
        let context = try #require(additionalContext(of: run.stdout),
                                   "watchdog output broke the envelope: \(run.stdout)")
        #expect(context.contains("watchdog"),
                "degradation notice missing from context: \(context)")
    }

    /// End-to-end degradation under a genuinely locked database (H1.2's
    /// busy timeout + H1.4/H1.5's budgeted tail): a fixture hub held under
    /// an EXCLUSIVE lock by this process must yield a fast exit 0 with a
    /// valid envelope — never a ride to the kill timeout. The watchdog
    /// backstops this path at budget+2s if any of those layers regress.
    @Test func lockedDatabase_degradesFast_withValidEnvelope() throws {
        let home = try makeTempHome()
        let dbURL = home.appendingPathComponent(".claude/memory.sqlite")

        // A minimal fixture file, then an EXCLUSIVE transaction held open
        // for the child's whole lifetime: every read or write the hook
        // attempts — including its open-time WAL/migration pragmas — gets
        // SQLITE_BUSY until its busy timeout gives up.
        var holder: OpaquePointer?
        #expect(sqlite3_open(dbURL.path, &holder) == SQLITE_OK)
        defer { sqlite3_close(holder) }
        #expect(sqlite3_exec(holder, "CREATE TABLE _watchdog_probe(x INTEGER);", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(holder, "BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(holder, "INSERT INTO _watchdog_probe VALUES (1);", nil, nil, nil) == SQLITE_OK)

        let run = try runAdvise(
            env: [
                "CLAUDE_MEMORY_DB": dbURL.path,
                "ENGRAM_HOOK_RECALL_BUDGET_MS": "1500",
            ],
            home: home,
            prompt: "How did we fix the sync daemon deadlock in the engram hub database?",
            killAfter: 15)

        #expect(run.terminated,
                "hook rode the locked database toward the harness kill (killed after \(run.seconds)s)")
        #expect(run.exitCode == 0, "degraded exit must be 0, got \(run.exitCode)")
        let context = try #require(additionalContext(of: run.stdout),
                                   "degraded output broke the envelope: \(run.stdout)")
        // The nudge tail always runs — its presence proves the envelope was
        // built by the normal (or watchdog) emit path, not a partial write.
        #expect(context.contains("## Session learning") || context.contains("watchdog"),
                "context missing both the nudge and a watchdog notice: \(context)")
    }
}
