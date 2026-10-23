import ArgumentParser
import EngramMemoryCore
import Foundation
#if canImport(EngramKit)
import EngramKit
#endif

/// Stop hook: spawns a fire-and-forget `memory-hooks sample-gate` subprocess that
/// checks transcript novelty before deciding whether to spawn the expensive session-learner.
struct OnStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "on-stop",
        abstract: "Gate session-learner on transcript novelty (Stop hook)"
    )

    func run() async throws {
        // Guard against infinite recursion
        if ProcessInfo.processInfo.environment["CLAUDE_MEMORY_LEARNER"] != nil {
            return
        }
        // Orchestrated mode: the sandbox orchestrator invokes sample-gate
        // itself after the run's artifact posts — a second spawn path here
        // would double-fire the learner.
        if learnerIsOrchestrated() { return }

        let inputData = readStdin()
        guard !inputData.isEmpty else { return }

        let input: StopInput
        do {
            input = try JSONDecoder().decode(StopInput.self, from: inputData)
        } catch {
            hookLog("Failed to parse hook input: \(error)")
            return
        }

        hookLog("Stop hook: sessionId=\(input.sessionId ?? "nil")")

        guard let transcriptPath = input.transcriptPath else { return }

        let project = projectName(from: input.cwd) ?? "unknown"

        // Mark as sent so the Advise hook skips its learning nudge
        updateSessionCounters(sessionId: input.sessionId) { state in
            state.stopNudgeSent = true
        }

        do {
            try spawnSampleGate(
                transcriptPath: transcriptPath,
                project: project,
                cwd: input.cwd ?? FileManager.default.currentDirectoryPath,
                sessionId: input.sessionId
            )
            hookLog("Stop hook: spawned sample-gate for project \(project)")
        } catch {
            hookLog("Stop hook: failed to spawn sample-gate: \(error)")
        }
    }

    // MARK: - Sample Gate Spawning

    /// Spawn `memory-hooks sample-gate` as a detached fire-and-forget subprocess.
    /// The sample-gate will run TranscriptSampler (~1-12s) and only spawn the
    /// session-learner claude subprocess if novel content is found.
    private func spawnSampleGate(transcriptPath: String, project: String, cwd: String, sessionId: String?) throws {
        // Resolve this release's running hooks binary; an older installed copy
        // must not supply the internal shell launch contract.
        let bin = try processGuardExecutable(explicit: nil)
        let logPath = NSHomeDirectory() + "/.claude/sample-gate.log"

        rotateFileIfNeeded(logPath)

        let escapedTranscript = transcriptPath.replacingOccurrences(of: "'", with: "'\\''")
        let escapedProject = project.replacingOccurrences(of: "'", with: "'\\''")
        let escapedCwd = cwd.replacingOccurrences(of: "'", with: "'\\''")
        let sessionArgument: String
        if let sessionId, LearnerLogContext(sessionId: sessionId, trigger: .stop) != nil {
            sessionArgument = " --session-id '" + sessionId.replacingOccurrences(of: "'", with: "'\\''") + "'"
        } else {
            sessionArgument = ""
        }

        let shellCommand = """
        '\(bin)' sample-gate \
          --transcript-path '\(escapedTranscript)' \
          --project '\(escapedProject)' \
          --cwd '\(escapedCwd)'\(sessionArgument) \
          >> '\(logPath)' 2>&1
        """

        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: bin)
        sh.arguments = ["internal-process-guard", "--exec-shell", shellCommand]
        // Pass CLAUDE_MEMORY_LEARNER so the session-learner's claude subprocess
        // inherits it, and when that subprocess's Stop hook fires OnStop,
        // the guard at the top of run() prevents infinite recursion.
        sh.environment = ProcessInfo.processInfo.environment.merging(
            ["CLAUDE_MEMORY_LEARNER": "1"],
            uniquingKeysWith: { _, new in new }
        )
        sh.currentDirectoryURL = URL(fileURLWithPath: cwd)

        // Detach from our process's stdio
        sh.standardOutput = FileHandle.nullDevice
        sh.standardError = FileHandle.nullDevice

        try sh.run()
        // Don't wait — fire and forget
    }
}
