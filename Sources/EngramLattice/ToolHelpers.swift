import Lattice
import MCP
import Foundation

private let logFilePath = NSHomeDirectory() + "/.claude/memory.log"
private let memoryLogsDir = NSHomeDirectory() + "/.claude/memory-logs"

/// Append a "saved" entry to the session recall log so the statusline shows it.
public func appendSessionSaveLog(sessionId: String?, globalId: String, project: String, topic: String, preview: String) {
    guard let sid = sessionId, !sid.isEmpty else { return }
    let dir = memoryLogsDir
    let path = dir + "/recall-\(sid).log"
    let fm = FileManager.default
    if !fm.fileExists(atPath: dir) {
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    let cyan = "\u{1B}[36m"
    let green = "\u{1B}[32m"
    let magenta = "\u{1B}[35m"
    let dim = "\u{1B}[2m"
    let rst = "\u{1B}[0m"
    let shortId = String(globalId.prefix(8))
    let line = "  \(green)+\(rst) \(cyan)\(shortId)\(rst) \(magenta)[\(project)/\(topic)]\(rst) \(dim)\(preview)\(rst)\n"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(Data(line.utf8))
        fh.closeFile()
    } else {
        // No recall log yet — create one with just the save line
        let content = "\(dim)no recall yet\(rst)\n\(line)"
        fm.createFile(atPath: path, contents: Data(content.utf8))
    }
}

private let logMaxBytes = 256 * 1024

private func rotateLogIfNeeded() {
    let fm = FileManager.default
    guard let attrs = try? fm.attributesOfItem(atPath: logFilePath),
          let size = attrs[.size] as? Int,
          size > logMaxBytes else { return }
    let backup = logFilePath + ".1"
    try? fm.removeItem(atPath: backup)
    try? fm.moveItem(atPath: logFilePath, toPath: backup)
}

public func log(_ message: String) {
    let line = "[claude-memory] \(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    // Feed the crash reporter ring buffer
    CrashReporter.shared.log(message)
    // Always write to stderr for immediate visibility
    FileHandle.standardError.write(Data(line.utf8))
    // Also append to rotating log file
    rotateLogIfNeeded()
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFilePath) {
            if let fh = FileHandle(forWritingAtPath: logFilePath) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: logFilePath, contents: data)
        }
    }
}

// MARK: - Codable Argument Decoding

extension Optional where Wrapped == [String: MCP.Value] {
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self ?? [:])
        return try JSONDecoder().decode(type, from: data)
    }
}

struct FlexibleInt: Decodable {
    let value: Int
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let string = try? container.decode(String.self), let int = Int(string) {
            value = int
        } else {
            throw DecodingError.typeMismatch(
                Int.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected an integer or string-encoded integer")
            )
        }
    }
}

/// Decodes an array of integers from either a JSON array or a comma-separated string.
/// Handles MCP clients that pass `[1, 2, 3]` as `"1, 2, 3"`.
struct FlexibleIntArray: Decodable {
    let values: [Int]
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let array = try? container.decode([FlexibleInt].self) {
            values = array.map(\.value)
        } else if let string = try? container.decode(String.self) {
            // Strip surrounding brackets for clients that JSON-stringify arrays: "[155, 156]"
            var trimmed = string.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                trimmed = String(trimmed.dropFirst().dropLast())
            }
            let parsed = trimmed.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !parsed.isEmpty else {
                throw DecodingError.typeMismatch(
                    [Int].self,
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected an array of integers or comma-separated string of integers")
                )
            }
            values = parsed
        } else {
            throw DecodingError.typeMismatch(
                [Int].self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected an array of integers or comma-separated string of integers")
            )
        }
    }
}

/// Decodes a UUID from a string. Accepts standard UUID format.
struct FlexibleUUID: Decodable {
    let value: UUID
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let uuid = UUID(uuidString: string) else {
            throw DecodingError.typeMismatch(
                UUID.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected a valid UUID string, got '\(string)'")
            )
        }
        value = uuid
    }
}

/// Decodes an array of UUIDs from either a JSON array of strings or a comma-separated string.
struct FlexibleUUIDArray: Decodable {
    let values: [UUID]
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let array = try? container.decode([String].self) {
            values = try array.map { str in
                guard let uuid = UUID(uuidString: str) else {
                    throw DecodingError.typeMismatch(
                        UUID.self,
                        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected a valid UUID string, got '\(str)'")
                    )
                }
                return uuid
            }
        } else if let string = try? container.decode(String.self) {
            var trimmed = string.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                trimmed = String(trimmed.dropFirst().dropLast())
            }
            let parsed = try trimmed.split(separator: ",").map { part -> UUID in
                let str = part.trimmingCharacters(in: .whitespaces)
                guard let uuid = UUID(uuidString: str) else {
                    throw DecodingError.typeMismatch(
                        UUID.self,
                        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected a valid UUID string, got '\(str)'")
                    )
                }
                return uuid
            }
            guard !parsed.isEmpty else {
                throw DecodingError.typeMismatch(
                    [UUID].self,
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected an array of UUID strings")
                )
            }
            values = parsed
        } else {
            throw DecodingError.typeMismatch(
                [UUID].self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected an array of UUID strings or comma-separated UUID strings")
            )
        }
    }
}

func parseTemporalDate(_ input: String) -> Date? {
    let now = Date()
    let cal = Calendar.current

    // ISO 8601 with time
    let isoFull = ISO8601DateFormatter()
    if let date = isoFull.date(from: input) { return date }

    // ISO 8601 date only: "2024-01-15"
    let isoDate = ISO8601DateFormatter()
    isoDate.formatOptions = [.withFullDate, .withDashSeparatorInDate]
    if let date = isoDate.date(from: input) { return date }

    let lower = input.lowercased().trimmingCharacters(in: .whitespaces)

    // Natural language
    switch lower {
    case "today": return cal.startOfDay(for: now)
    case "yesterday": return cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))
    case "last week": return cal.date(byAdding: .weekOfYear, value: -1, to: now)
    case "last month": return cal.date(byAdding: .month, value: -1, to: now)
    case "last year": return cal.date(byAdding: .year, value: -1, to: now)
    default: break
    }

    // Compact shorthand: "7d", "2w", "3m", "1y"
    let shortPattern = /^(\d+)([dwmy])$/
    if let match = lower.wholeMatch(of: shortPattern) {
        let n = Int(match.1)!
        let component: Calendar.Component = switch String(match.2) {
        case "d": .day
        case "w": .weekOfYear
        case "m": .month
        case "y": .year
        default: .day
        }
        return cal.date(byAdding: component, value: -n, to: now)
    }

    // Relative phrase: "7 days ago", "2 weeks ago"
    let phrasePattern = /^(\d+)\s+(day|week|month|year)s?\s+ago$/
    if let match = lower.wholeMatch(of: phrasePattern) {
        let n = Int(match.1)!
        let component: Calendar.Component = switch String(match.2) {
        case "day": .day
        case "week": .weekOfYear
        case "month": .month
        case "year": .year
        default: .day
        }
        return cal.date(byAdding: component, value: -n, to: now)
    }

    return nil
}

// MARK: - Args Structs

struct RememberArgs: Decodable {
    let content: String
    let topic: String?
    let project: String?
    let source: String?
    let expiresInDays: FlexibleInt?
    let force: Bool?
    let importance: FlexibleInt?
    let parentId: FlexibleUUID?
    let isPrivate: Bool?

    enum CodingKeys: String, CodingKey {
        case content, topic, project, source, force, importance
        case expiresInDays = "expires_in_days"
        case parentId = "parent_id"
        case isPrivate = "is_private"
    }
}

struct RecallArgs: Decodable {
    let query: String
    let project: String?
    let topic: String?
    let limit: FlexibleInt?
    let depth: FlexibleInt?
    let since: String?
    let before: String?
}

struct ForgetArgs: Decodable {
    let id: FlexibleUUID?
    let topic: String?
    let project: String?
}

struct UpdateArgs: Decodable {
    // Targeting (one required)
    let id: FlexibleUUID?
    let query: String?
    let project: String?

    // Content editing (all optional, mutually exclusive)
    let content: String?
    let append: String?
    let prepend: String?
    let find: String?
    let replace: String?

    // Field-level metadata updates (all optional)
    let setProject: String?
    let topic: String?
    let source: String?
    let expiresInDays: FlexibleInt?
    let importance: FlexibleInt?
    let isPrivate: Bool?

    /// Clears a tombstone (deletedAt/deletedBy) — restores a soft-deleted
    /// group-shared memory for every member.
    let undelete: Bool?

    enum CodingKeys: String, CodingKey {
        case id, query, project, content, append, prepend, find, replace, topic, source, importance, undelete
        case setProject = "set_project"
        case expiresInDays = "expires_in_days"
        case isPrivate = "is_private"
    }
}

struct MergeArgs: Decodable {
    let ids: FlexibleUUIDArray
    let content: String
    let topic: String?
    let project: String?
}

struct StatsArgs: Decodable {
    let project: String?
}

struct ListTopicsArgs: Decodable {
    let project: String?
}

struct ConnectArgs: Decodable {
    let from: FlexibleUUID
    let to: FlexibleUUID
    let relation: String
}

struct DisconnectArgs: Decodable {
    let id: FlexibleUUID?      // Edge globalId
    let from: FlexibleUUID?    // Memory globalId
    let to: FlexibleUUID?      // Memory globalId
    let relation: String?
}

struct GraphArgs: Decodable {
    let id: FlexibleUUID
    let depth: FlexibleInt?
}

struct TimelineArgs: Decodable {
    let project: String?
    let topic: String?
    let since: String?
    let before: String?
    let groupBy: String?
    let limit: FlexibleInt?

    enum CodingKeys: String, CodingKey {
        case project, topic, since, before, limit
        case groupBy = "group_by"
    }
}

/// Compute Jaccard similarity between two strings based on unique lowercased terms (3+ chars).
/// Returns a value between 0.0 (no overlap) and 1.0 (identical term sets).
public func jaccardSimilarity(_ a: String, _ b: String) -> Double {
    func tokenize(_ s: String) -> Set<String> {
        Set(
            s.lowercased()
                .components(separatedBy: .alphanumerics.inverted)
                .filter { $0.count >= 3 }
        )
    }
    let setA = tokenize(a)
    let setB = tokenize(b)
    guard !setA.isEmpty || !setB.isEmpty else { return 0.0 }
    return Double(setA.intersection(setB).count) / Double(setA.union(setB).count)
}

/// Valid relation types for knowledge graph edges.
let validRelations: Set<String> = [
    "relates_to", "contradicts", "supersedes", "derived_from", "part_of", "summarized_by",
]

/// Valid statuses for task checkpoints.
let validStatuses: Set<String> = ["active", "paused", "completed"]


struct CheckpointArgs: Decodable {
    let taskId: FlexibleInt?
    let title: String?
    let status: String?
    let project: String?
    let plan: String?
    let progress: String?
    let context: String?
    enum CodingKeys: String, CodingKey {
        case title, status, project, plan, progress, context
        case taskId = "task_id"
    }
}

struct ResumeArgs: Decodable {
    let taskId: FlexibleInt
    enum CodingKeys: String, CodingKey { case taskId = "task_id" }
}

struct ListTasksArgs: Decodable {
    let project: String?
    let status: String?
    let limit: FlexibleInt?
}

struct BeginEpisodeArgs: Decodable {
    let title: String?
    let project: String?
}

struct EndEpisodeArgs: Decodable {
    let episodeId: FlexibleUUID?
    let summary: String?
    enum CodingKeys: String, CodingKey {
        case summary
        case episodeId = "episode_id"
    }
}

struct RecallEpisodeArgs: Decodable {
    let episodeId: FlexibleUUID
    let limit: FlexibleInt?
    enum CodingKeys: String, CodingKey {
        case episodeId = "episode_id"
        case limit
    }
}

struct ListEpisodesArgs: Decodable {
    let project: String?
    let limit: FlexibleInt?
}

struct FindClustersArgs: Decodable {
    let project: String?
    let topic: String?
    let minClusterSize: FlexibleInt?
    let distanceThreshold: FlexibleInt?
    let maxClusters: FlexibleInt?

    enum CodingKeys: String, CodingKey {
        case project, topic
        case minClusterSize = "min_cluster_size"
        case distanceThreshold = "distance_threshold"
        case maxClusters = "max_clusters"
    }
}

struct DetectCommunitiesArgs: Decodable {
    let project: String
    let minSize: FlexibleInt?
    enum CodingKeys: String, CodingKey {
        case project
        case minSize = "min_size"
    }
}

struct OrganizeArgs: Decodable {
    let ids: FlexibleUUIDArray
    let label: String
    let project: String?
    let summary: String?
}

struct ConsolidateArgs: Decodable {
    let ids: FlexibleUUIDArray
    let content: String
    let topic: String?
    let project: String?
    let importance: FlexibleInt?
    /// Required to consolidate clusters containing FOREIGN-authored (group)
    /// memories — the demotion mutates teammates' rows group-wide.
    let force: Bool?
}
