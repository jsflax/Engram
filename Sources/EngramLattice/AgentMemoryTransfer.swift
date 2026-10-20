import Foundation
import Lattice
import EngramModels
import EngramMemoryCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Obtain this descriptor from the current authoritative host, not by selecting
/// an arbitrary cached manifest on the receiver. A prior descriptor proves only
/// its own snapshot and cannot authorize a later assignment's memory state.
public struct AgentMemoryTransferSeal: Sendable, Codable, Equatable {
    public let manifestId: UUID
    public let graphId: UUID
    public let agentId: UUID
    public let formatVersion: Int
    public let schemaVersion: Int
    public let contentDigest: String
    public let tableCounts: [String: Int]
    public init(manifestId: UUID, graphId: UUID, agentId: UUID, formatVersion: Int = 1,
                schemaVersion: Int = AgentMemorySchema.currentVersion, contentDigest: String,
                tableCounts: [String: Int]) {
        self.manifestId = manifestId; self.graphId = graphId; self.agentId = agentId
        self.formatVersion = formatVersion; self.schemaVersion = schemaVersion
        self.contentDigest = contentDigest; self.tableCounts = tableCounts
    }
}

public struct AgentMemoryTransferStatus: Sendable, Codable, Equatable {
    public let isReady: Bool
    public let reason: String
    public let expectedCounts: [String: Int]
    public let actualCounts: [String: Int]
}

public struct AgentMemoryTransferLimits: Sendable {
    public var maximumRecords: Int
    public var maximumContentBytes: Int
    public init(maximumRecords: Int = 100_000, maximumContentBytes: Int = 256 * 1024 * 1024) {
        self.maximumRecords = maximumRecords; self.maximumContentBytes = maximumContentBytes
    }
}

/// Exact snapshot verification covers owner identity, memories (including
/// vectors/pending indexing/tombstones), edges, checkpoints and graph metadata.
/// Extra stale rows are a mismatch too: otherwise a hard deletion still in
/// flight could make old private content appear ready. The sender reseals after
/// subsequent writes; no transport batching/order assumptions are required.
public enum AgentMemoryTransfer {
    public static let formatVersion = 1
    public static let coveredTables = ["AgentMemoryGraph", "Checkpoint", "Edge", "GroupProjectMap", "HookState", "Memory", "SyncConfig"]

    public static func seal(in lattice: Lattice, binding: AgentMemoryBinding,
                            limits: AgentMemoryTransferLimits = .init(),
                            beforeSnapshot: (() throws -> Void)? = nil) throws -> AgentMemoryTransferSeal {
        try lattice.withTransaction {
            let owner = lattice.objects(AgentMemoryGraph.self).snapshot()
            guard owner.count == 1, owner[0].graphId == binding.graphId, owner[0].agentId == binding.agentId else {
                throw MemoryServiceError.invalidArguments("Cannot seal another agent's memory graph")
            }
            try beforeSnapshot?()
            let snapshot = try fingerprint(lattice, limits: limits)
            // Repeated publication of an unchanged graph is cheap in durable
            // storage and returns the same snapshot descriptor.
            if let existing = lattice.objects(AgentMemoryTransferManifest.self).first(where: {
                $0.sourceGraphId == binding.graphId && $0.sourceAgentId == binding.agentId
                    && $0.formatVersion == formatVersion && $0.schemaVersion == AgentMemorySchema.currentVersion
                    && $0.contentDigest == snapshot.digest
            }), let id = existing.globalId {
                return .init(manifestId: id, graphId: binding.graphId, agentId: binding.agentId,
                             contentDigest: snapshot.digest, tableCounts: snapshot.counts)
            }
            let row = AgentMemoryTransferManifest()
            row.sourceGraphId = binding.graphId; row.sourceAgentId = binding.agentId
            row.schemaVersion = AgentMemorySchema.currentVersion; row.contentDigest = snapshot.digest
            row.tableCountsJSON = String(decoding: try JSONEncoder().encode(snapshot.counts), as: UTF8.self)
            let id = UUID(); try lattice.add(row, preservingGlobalId: id)
            return .init(manifestId: id, graphId: binding.graphId, agentId: binding.agentId,
                         contentDigest: snapshot.digest, tableCounts: snapshot.counts)
        }
    }

    public static func verify(in lattice: Lattice, expected: AgentMemoryTransferSeal,
                              limits: AgentMemoryTransferLimits = .init(),
                              onReady: (() throws -> Void)? = nil) throws -> AgentMemoryTransferStatus {
        try lattice.withTransaction {
            let result = try check(in: lattice, expected: expected, requireManifest: true, limits: limits)
            if result.isReady { try onReady?() }
            return result
        }
    }

    /// A coordinator receiving a graph from its owner may accept that owner's
    /// authenticated descriptor only after all matching content has arrived.
    /// The caller MUST authenticate source ownership/graph upload permission
    /// before calling this API. Replicas cannot upload manifest rows directly.
    /// A partial receiving graph can never self-certify by calling seal().
    public static func accept(in lattice: Lattice, expected: AgentMemoryTransferSeal,
                              limits: AgentMemoryTransferLimits = .init(),
                              onReady: (() throws -> Void)? = nil) throws -> AgentMemoryTransferStatus {
        try lattice.withTransaction {
            let result = try check(in: lattice, expected: expected, requireManifest: false, limits: limits)
            guard result.isReady else { return result }
            if let existing = lattice.objects(AgentMemoryTransferManifest.self).first(where: { $0.globalId == expected.manifestId }) {
                guard existing.sourceGraphId == expected.graphId, existing.sourceAgentId == expected.agentId,
                      existing.contentDigest == expected.contentDigest,
                      existing.schemaVersion == expected.schemaVersion, existing.formatVersion == expected.formatVersion,
                      (try? JSONDecoder().decode([String: Int].self, from: Data(existing.tableCountsJSON.utf8))) == expected.tableCounts else {
                    throw MemoryServiceError.invalidArguments("Transfer manifest identity already names another snapshot")
                }
            } else {
                let row = AgentMemoryTransferManifest()
                row.sourceGraphId = expected.graphId; row.sourceAgentId = expected.agentId
                row.contentDigest = expected.contentDigest; row.formatVersion = expected.formatVersion; row.schemaVersion = expected.schemaVersion
                row.tableCountsJSON = String(decoding: try JSONEncoder().encode(expected.tableCounts), as: UTF8.self)
                try lattice.add(row, preservingGlobalId: expected.manifestId)
            }
            try onReady?()
            return result
        }
    }

    private static func check(in lattice: Lattice, expected: AgentMemoryTransferSeal, requireManifest: Bool,
                              limits: AgentMemoryTransferLimits) throws -> AgentMemoryTransferStatus {
        guard expected.formatVersion == formatVersion, expected.schemaVersion == AgentMemorySchema.currentVersion,
              Set(expected.tableCounts.keys) == Set(coveredTables), expected.tableCounts.values.allSatisfy({ $0 >= 0 }),
              expected.contentDigest.count == 64, expected.contentDigest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            return .init(isReady: false, reason: "Unsupported or invalid transfer descriptor", expectedCounts: expected.tableCounts, actualCounts: [:])
        }
        if requireManifest {
              guard let manifest = lattice.objects(AgentMemoryTransferManifest.self).first(where: { $0.globalId == expected.manifestId }),
                  manifest.sourceGraphId == expected.graphId, manifest.sourceAgentId == expected.agentId,
                  manifest.formatVersion == expected.formatVersion, manifest.schemaVersion == expected.schemaVersion,
                  manifest.contentDigest == expected.contentDigest,
                  (try? JSONDecoder().decode([String: Int].self, from: Data(manifest.tableCountsJSON.utf8))) == expected.tableCounts else {
                return .init(isReady: false, reason: "Waiting for the authoritative transfer manifest", expectedCounts: expected.tableCounts, actualCounts: [:])
              }
            }
            let owner = lattice.objects(AgentMemoryGraph.self).snapshot()
            guard owner.count == 1, owner[0].graphId == expected.graphId, owner[0].agentId == expected.agentId else {
                return .init(isReady: false, reason: "Waiting for the matching graph owner", expectedCounts: expected.tableCounts, actualCounts: [:])
            }
            let actual = try fingerprint(lattice, limits: limits)
            let ready = actual.counts == expected.tableCounts && actual.digest == expected.contentDigest
            return .init(isReady: ready, reason: ready ? "Memory snapshot verified" : "Waiting for all memory changes in this snapshot",
                         expectedCounts: expected.tableCounts, actualCounts: actual.counts)
    }

    private struct Fingerprint { let digest: String; let counts: [String: Int] }
    private struct CanonicalHash {
        var hash = SHA256()
        var bytes = 0
        let maximumBytes: Int
        mutating func append(_ fields: [String]) throws {
            for field in fields {
                let data = Data(field.utf8)
                guard data.count <= maximumBytes - bytes else {
                    throw MemoryServiceError.invalidArguments("Memory transfer exceeds its content verification limit")
                }
                bytes += data.count
                // Length prefix avoids delimiter ambiguity, including embedded
                // NUL/newline text. Every scalar has an explicit type marker.
                var length = UInt64(data.count).bigEndian
                withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
                hash.update(data: data)
            }
        }
        mutating func finish() -> String { hash.finalize().map { String(format: "%02x", $0) }.joined() }
    }
    private static func text(_ value: String) -> String { "s" + value }
    private static func id(_ value: UUID?) -> String { value.map { "u" + $0.uuidString.lowercased() } ?? "n" }
    private static func number(_ value: Int) -> String { "i\(value)" }
    private static func boolean(_ value: Bool?) -> String { value.map { $0 ? "b1" : "b0" } ?? "n" }
    private static func date(_ value: Date?) -> String {
        guard let value else { return "n" }
        // Lattice timestamps round-trip through seconds relative to Apple's
        // epoch; Unix microseconds remove the sub-microsecond ULP drift seen
        // when a canonical graph moves through PostgreSQL or another platform.
        return "t\(Int64((value.timeIntervalSince1970 * 1_000_000).rounded()))"
    }

    private static func fingerprint(_ lattice: Lattice, limits: AgentMemoryTransferLimits) throws -> Fingerprint {
        guard limits.maximumRecords > 0, limits.maximumContentBytes > 0 else {
            throw MemoryServiceError.invalidArguments("Memory transfer verification limits must be positive")
        }
        var hasher = CanonicalHash(maximumBytes: limits.maximumContentBytes)
        var counts: [String: Int] = [:]; var total = 0
        try hasher.append(["engram-memory-transfer", number(formatVersion), number(AgentMemorySchema.currentVersion)])
        func table<T: Model>(_ type: T.Type, fields: (T) -> [String]) throws {
            let query = lattice.objects(type)
            guard query.count <= limits.maximumRecords - total else {
                throw MemoryServiceError.invalidArguments("Memory transfer exceeds its record verification limit")
            }
            let rows = query.snapshot()
            total += rows.count; counts[T.entityName] = rows.count
            try hasher.append([T.entityName, number(rows.count)])
            for row in rows.sorted(by: { ($0.globalId?.uuidString ?? "") < ($1.globalId?.uuidString ?? "") }) {
                guard row.globalId != nil else { throw MemoryServiceError.invalidArguments("Memory transfer contains an unpersisted record") }
                try hasher.append([id(row.globalId)] + fields(row))
            }
        }
        try table(AgentMemoryGraph.self) { [id($0.agentId), id($0.graphId)] }
        try table(Checkpoint.self) { [text($0.title), text($0.status), text($0.project), text($0.plan), text($0.progress), text($0.context), date($0.createdAt), date($0.checkpointedAt)] }
        try table(Edge.self) { [id($0.sourceGlobalId), id($0.targetGlobalId), text($0.relation.rawValue), date($0.createdAt), id($0.authorUserId), date($0.deletedAt)] }
        try table(GroupProjectMap.self) { [id($0.memberUserId), text($0.localProject), text($0.groupProject), date($0.updatedAt)] }
        try table(HookState.self) { [text($0.key.rawValue), text($0.value), date($0.updatedAt)] }
        try table(Memory.self) { row in
            [text(row.content), text(row.topic), text(row.project), text(row.source),
             "v" + row.embedding.map { String($0.bitPattern, radix: 16) }.joined(separator: ","),
             boolean(row.embeddingPending), date(row.createdAt), date(row.lastAccessedAt), date(row.expiresAt),
             number(row.accessCount), number(row.importance), boolean(row.isPrivate), id(row.authorUserId),
             date(row.deletedAt), id(row.deletedBy), date(row.modifiedAt)]
        }
        try table(SyncConfig.self) { [text($0.project), text($0.policy.rawValue),
                                    text($0.exposedTeams.sorted().map { "\($0.utf8.count):\($0)" }.joined()), date($0.updatedAt)] }
        return Fingerprint(digest: hasher.finish(), counts: counts)
    }
}
