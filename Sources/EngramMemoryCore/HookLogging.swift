import Foundation

// Hook/process logging shared by every surface (EngramKit tools, hooks —
// local AND remote/Linux): per-session debug logs under
// ~/.claude/memory-logs.

private let memoryLogsDir = NSHomeDirectory() + "/.claude/memory-logs"

/// Optional attribution for a detached learner. This is diagnostic metadata,
/// not a claim that the child wrote or persisted memories.
public struct LearnerLogContext: Sendable {
    public enum Trigger: String, Sendable {
        case stop
        case autoPrecompact = "auto_precompact"
    }

    let sessionId: String
    let trigger: Trigger

    public init?(sessionId: String?, trigger: Trigger) {
        guard let sessionId, !sessionId.isEmpty, sessionId.utf8.count <= 128,
              sessionId.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || $0 == 45 || $0 == 95
              }) else { return nil }
        self.sessionId = sessionId
        self.trigger = trigger
    }
}

func sessionLogPath(sessionId: String, directory: String = memoryLogsDir) -> String {
    directory + "/debug-\(sessionId).log"
}

/// Kept separate from the public context so each actual launch gets a fresh ID.
struct LearnerLifecycleLog {
    let context: LearnerLogContext
    let path: String
    let runId = UUID()

    init(context: LearnerLogContext, directory: String = memoryLogsDir) {
        self.context = context
        path = sessionLogPath(sessionId: context.sessionId, directory: directory)
    }

    func appendCommand(event: String, includeExitCode: Bool = false) -> String {
        let quotedPath = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // Session-end cleanup may remove an earlier start line. Each record is
        // self-contained; a missing pair is not evidence of failure or success.
        let fields = "session_id=\(context.sessionId) trigger=\(context.trigger.rawValue) run_id=\(runId.uuidString)"
        let exitFormat = includeExitCode ? " exit_code=%s" : ""
        let exitArgument = includeExitCode ? " \"$RC\"" : ""
        // Skip malformed existing destinations, including FIFOs, instead of
        // blocking the child watcher. One small append; failure is diagnostic only.
        return " { if [ ! -L \(quotedPath) ] && { [ ! -e \(quotedPath) ] || [ -f \(quotedPath) ]; }; then printf '%s \(event) \(fields) child_pid=%s\(exitFormat)\\n' \"$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)\" \"$CPID\"\(exitArgument) >> \(quotedPath); fi; } 2>/dev/null || :;"
    }
}

/// Global session ID for per-session debug logging in short-lived hook processes.
nonisolated(unsafe) public var currentSessionId: String?

/// Write a timestamped line to ~/.claude/memory-logs/debug-<sessionId>.log.
public func sessionLog(_ message: String, sessionId: String? = nil) {
    let sid = sessionId ?? currentSessionId
    guard let sid, !sid.isEmpty else { return }
    let dir = memoryLogsDir
    let path = sessionLogPath(sessionId: sid, directory: dir)
    let fm = FileManager.default
    if !fm.fileExists(atPath: dir) {
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(timestamp) \(message)\n"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(Data(line.utf8))
        fh.closeFile()
    } else {
        fm.createFile(atPath: path, contents: Data(line.utf8))
    }
}
