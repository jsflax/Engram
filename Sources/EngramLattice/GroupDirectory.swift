import Foundation

/// Reader for `~/.claude/sync/groups.json` — the daemon-authored group +
/// member directory (the daemon is the SOLE writer; the visualizer only
/// triggers refreshes). Short-lived processes (the MCP server, hooks) need
/// `authorUserId → displayName` and the signed-in user's id WITHOUT network
/// or Keychain access — extending Keychain ACLs to every short-lived hook
/// process is exactly where macOS prompts or silently fails, and the
/// failure mode would be silent nil-author rows.
///
/// File shape (0600, daemon-written):
/// ```json
/// {
///   "selfUserId": "…",
///   "updatedAt": "…",
///   "groups": [{"id": "…", "name": "…", "parentId": null, "myRole": "owner", "root": true}],
///   "members": {"<userId>": "Display Name"}
/// }
/// ```
public enum GroupDirectory {
    public struct GroupInfo: Codable, Sendable, Equatable {
        public let id: UUID
        public let name: String
        public let parentId: UUID?
        public let myRole: String?
        public let root: Bool?
        /// Link-granted graph (no direct/subtree membership). Optional —
        /// legacy groups.json files decode without it.
        public let viaLink: Bool?
        /// The team(s) whose links grant this graph.
        public let linkedFrom: [UUID]?

        public init(id: UUID, name: String, parentId: UUID?, myRole: String?,
                    root: Bool?, viaLink: Bool? = nil, linkedFrom: [UUID]? = nil) {
            self.id = id
            self.name = name
            self.parentId = parentId
            self.myRole = myRole
            self.root = root
            self.viaLink = viaLink
            self.linkedFrom = linkedFrom
        }
    }

    public struct GroupsFile: Codable, Sendable {
        public let selfUserId: UUID?
        public let updatedAt: Date?
        public let groups: [GroupInfo]
        public let members: [String: String]

        public init(selfUserId: UUID?, updatedAt: Date?, groups: [GroupInfo], members: [String: String]) {
            self.selfUserId = selfUserId
            self.updatedAt = updatedAt
            self.groups = groups
            self.members = members
        }
    }

    /// Overridable for tests (point at a fixture file). Defaults to the
    /// daemon-written location.
    nonisolated(unsafe) public static var fileURL: URL = {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return home.appendingPathComponent(".claude/sync/groups.json")
    }()

    private struct Cache {
        var file: GroupsFile?
        var mtime: Date?
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache = Cache()

    /// Direct, non-caching load from an explicit URL — for tests and
    /// diagnostic tooling. Production reads go through `load()`.
    public static func load(from url: URL) -> GroupsFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GroupsFile.self, from: data)
    }

    /// mtime-checked load — cheap enough to call per lookup.
    public static func load() -> GroupsFile? {
        lock.lock()
        defer { lock.unlock() }
        let path = fileURL.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else {
            cache = Cache()
            return nil
        }
        if let cached = cache.file, cache.mtime == mtime {
            return cached
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            cache = Cache()
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(GroupsFile.self, from: data) else {
            cache = Cache()
            return nil
        }
        cache = Cache(file: file, mtime: mtime)
        return file
    }

    /// The signed-in user's id — the source for authorUserId stamping.
    /// Nil when signed out / never signed in / daemon hasn't written yet
    /// (writers stamp nil; the daemon-start backfill sweep repairs later).
    public static func currentUserId() -> UUID? {
        load()?.selfUserId
    }

    /// Display name for an author id, badge-sanitized (a name containing
    /// brackets/parens would corrupt the recall line format that
    /// logRecalledMemories parses). Nil when the directory has no entry.
    public static func displayName(for userId: UUID) -> String? {
        guard let raw = load()?.members[userId.uuidString] else { return nil }
        let sanitized = raw.filter { !"[]()".contains($0) }
            .trimmingCharacters(in: .whitespaces)
        return sanitized.isEmpty ? nil : sanitized
    }

    public static func groupName(for groupId: UUID) -> String? {
        load()?.groups.first { $0.id == groupId }?.name
    }

    /// Badge text for a foreign author: known name, or "teammate" when the
    /// id has no directory entry, or "unknown" for nil authors on
    /// group-resident rows (nil must never masquerade as self).
    public static func badgeName(for userId: UUID?) -> String {
        guard let userId else { return "unknown" }
        return displayName(for: userId) ?? "teammate"
    }
}
