import EngramMemoryCore
import Foundation

// MARK: - Hook Input Models

/// Input for the UserPromptSubmit hook.
struct UserPromptSubmitInput: Decodable {
    let sessionId: String?
    let transcriptPath: String?
    let cwd: String?
    let prompt: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case prompt
    }
}

/// Input for the SessionStart hook.
struct SessionStartInput: Decodable {
    let sessionId: String?
    let cwd: String?
    let source: String?  // "startup", "resume", "clear", "compact"

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case source
    }
}

/// Input for the SessionEnd hook.
struct SessionEndInput: Decodable {
    let sessionId: String?
    let cwd: String?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case reason
    }
}

/// Input for the PostToolUseFailure hook.
struct PostToolUseFailureInput: Decodable {
    let sessionId: String?
    let cwd: String?
    let toolName: String?
    let toolInput: AnyCodable?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case error
    }
}

/// Input for the PreToolUse hook.
struct PreToolUseInput: Decodable {
    let sessionId: String?
    let cwd: String?
    let toolName: String?
    let toolInput: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case toolName = "tool_name"
        case toolInput = "tool_input"
    }
}

/// Input for the Stop hook.
struct StopInput: Decodable {
    let sessionId: String?
    let transcriptPath: String?
    let cwd: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
    }
}

/// Input for the PreCompact hook.
struct PreCompactInput: Decodable {
    let sessionId: String?
    let transcriptPath: String?
    let cwd: String?
    let trigger: String?  // "manual" or "auto"

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd
        case trigger
    }
}

/// Type-erased Codable for tool_input (arbitrary JSON).
struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let str = try? container.decode(String.self) {
            value = str
        } else if let num = try? container.decode(Double.self) {
            value = num
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else {
            value = ""
        }
    }

    /// Try to get the value as a dictionary.
    var dict: [String: Any]? { value as? [String: Any] }

    /// Try to get a string value for a key.
    func string(forKey key: String) -> String? {
        (value as? [String: Any])?[key] as? String
    }
}

// MARK: - Hook Output Models

/// Hook-specific output nested under hookSpecificOutput.
struct HookSpecificOutput: Encodable {
    var hookEventName: String
    var additionalContext: String?
}

/// Output from a hook command.
struct HookOutput: Encodable {
    var decision: String?
    var reason: String?
    var hookSpecificOutput: HookSpecificOutput?
}

// MARK: - Maintenance Constants

/// Trigger maintenance when this many local Memory writes have occurred since
/// the last run. Was 50: with several sessions plus learners writing, that
/// fired a maintenance agent (another `claude` + MCP server + writer) on
/// nearly every cooldown expiry during the 2026-10-21 contention incident.
let maintenanceThreshold = 300

/// Minimum seconds between maintenance runs. Was 900 (15 min); maintenance is
/// hygiene, not a hot path, and the agent itself runs up to 30 min.
let maintenanceCooldownSeconds: TimeInterval = 3600  // 60 minutes

// MARK: - Helpers

/// Read all of stdin as Data.
func readStdin() -> Data {
    var data = Data()
    while let line = readLine(strippingNewline: false) {
        data.append(Data(line.utf8))
    }
    return data
}

/// Write JSON to stdout.
func writeOutput(_ output: HookOutput) throws {
    let encoder = JSONEncoder()
    let data = try encoder.encode(output)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

/// Log to stderr and to a log file for observability.
/// stderr is suppressed in production (2>/dev/null), so the file is the real record.
func hookLog(_ message: String) {
    let line = "[memory-hooks] \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))

    let logPath = NSHomeDirectory() + "/.claude/hooks.log"
    rotateFileIfNeeded(logPath)
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let logLine = "\(timestamp) \(line)"
    if let fh = FileHandle(forWritingAtPath: logPath) {
        fh.seekToEndOfFile()
        fh.write(Data(logLine.utf8))
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: Data(logLine.utf8))
    }
}

/// Derive project name from a working directory path.
func projectName(from cwd: String?) -> String? {
    cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent }
}

/// Standard database path.
var defaultDbPath: String {
    ProcessInfo.processInfo.environment["CLAUDE_MEMORY_DB"]
        ?? NSHomeDirectory() + "/.claude/memory.sqlite"
}
