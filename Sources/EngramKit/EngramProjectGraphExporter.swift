import CryptoKit
import EngramMemoryCore
import EngramModels
import Foundation
import Lattice

/// A Connect-owned exporter for one authenticated MemoryTools/store namespace. The trusted host
/// constructs BOTH tools and authority after authentication; this constructor does not authenticate
/// arbitrary stores from a workspace string. No MCP tool or native bundle is permitted to supply them.
public actor EngramProjectGraphExporter: EngramProjectGraphProviding {
    private let tools: MemoryTools
    private let authority: any EngramGraphReadAuthorizing
    private var revision: UInt64 = 0

    public init(trustedTools: MemoryTools, authority: any EngramGraphReadAuthorizing) {
        self.tools = trustedTools; self.authority = authority
    }

    public func projectGraph(_ scope: EngramGraphScope) async throws -> EngramGraphSnapshot {
        try Task.checkCancellation()
        let grant = try admittedGraphGrant(authority, scope: scope, principal: tools.principal)
        guard revision < EngramGraphLimits.maximumRevision else { throw EngramGraphExportError.revisionExhausted }
        revision += 1 // reserve before suspension; concurrent completions cannot reuse a revision
        let result = try await tools.exportProjectGraph(scope, grant: grant, authority: authority, revision: revision)
        try Task.checkCancellation()
        guard try admittedGraphGrant(authority, scope: scope, principal: tools.principal) == grant else {
            throw EngramGraphExportError.authorizationChanged
        }
        return result
    }
}

private func admittedGraphGrant(_ authority: any EngramGraphReadAuthorizing,
                                scope: EngramGraphScope, principal: Principal) throws -> EngramGraphReadGrant {
    let grant = try authority.authorizeGraphRead(scope: scope, principal: principal)
    guard principal.id != nil, grant.scope == scope,
          grant.principal == MemoryOperationPrincipalBinding(principal),
          grant.approvedGroupIDs.isSubset(of: Set(principal.groupIds)) else {
        throw EngramGraphExportError.notAuthorized
    }
    return grant
}

extension MemoryTools {
    /// Synchronous actor body: no Lattice model or database crosses a suspension. The checked
    /// transaction has a read-only body, retaining one consistent union snapshot; query errors and
    /// route/auth changes fail the entire export, preserving the host's previous good snapshot.
    func exportProjectGraph(_ scope: EngramGraphScope, grant: EngramGraphReadGrant,
                            authority: any EngramGraphReadAuthorizing, revision: UInt64) throws -> EngramGraphSnapshot {
        try Task.checkCancellation()
        try prepareStorage()
        try validateGraphGrant(grant, scope: scope, authority: authority)
        let sources = [localLattice] + (syncedLattice.map { [$0] } ?? []) + groupSpokes.map(\.lattice)
        guard sources.allSatisfy({ $0.configuration.busyTimeoutMs > 0 && $0.configuration.busyTimeoutMs <= 2_000 }) else {
            throw EngramGraphExportError.storageUnavailable
        }
        let route = try prepareOperationReadLattice(for: scope.project)
        let database = try validateOperationReadLattice(route, for: scope.project)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        _ = try database.storedSchemaVersion() // closed/read failures must not masquerade as empty rows
        let snapshot = try database.withTransaction {
            try validateGraphGrant(grant, scope: scope, authority: authority)
            _ = try validateOperationReadLattice(route, for: scope.project)
            let query = graphMemoryPredicate(scope, now: Date(), route: route, principal: grant.principal)
            let selected = database.dynamicObjects(Memory.entityName).where(query)
            let eligible = selected.count
            try graphCheck(database, deadline: deadline)
            let bounded = selected.where(GraphExportBounds.memorySQL)
            let admitted = bounded.count
            try graphCheck(database, deadline: deadline)
            // A pathological source row is a whole-export capacity failure, never a silently missing node.
            guard eligible == admitted else { throw EngramGraphExportError.capacity }
            var nodes: [UUID: GraphExportNode] = [:]
            var order: [UUID] = []
            var textBytes = 0, offset = 0
            var limited = false
            let physicalLimit = (EngramGraphLimits.maximumNodes + 1) * (Self.maxAttachments + 1)
            nodePages: while offset < admitted {
                try graphCheck(database, deadline: deadline)
                guard offset < physicalLimit else { limited = true; break }
                let page = bounded.sortedBy("globalId").sortedBy("id").snapshot(limit: 8, offset: offset)
                try graphCheck(database, deadline: deadline)
                guard !page.isEmpty else { throw EngramGraphExportError.inconsistentRows }
                offset += page.count
                for image in page {
                    try Task.checkCancellation()
                    let row = Memory(image.backend).materialize()
                    let value = try GraphExportNode(row)
                    if var previous = nodes[value.id] {
                        guard previous.sameDisplay(as: value) else { throw EngramGraphExportError.inconsistentRows }
                        previous.lastAccessedAt = max(previous.lastAccessedAt, value.lastAccessedAt)
                        nodes[value.id] = previous
                        continue
                    }
                    guard nodes.count < EngramGraphLimits.maximumNodes,
                          textBytes + value.textBytes <= EngramGraphLimits.maximumTextBytes else {
                        limited = true; break nodePages
                    }
                    nodes[value.id] = value; order.append(value.id); textBytes += value.textBytes
                }
            }
            let edges = try graphEdges(database: database, nodeIDs: order, deadline: deadline,
                                       textBytes: &textBytes, limited: &limited)
            let hubs = Set(edges.filter { $0.relation == "part_of" }.map(\.targetID))
            let values = order.compactMap { nodes[$0]?.value(isHub: hubs.contains($0)) }
            try validateGraphGrant(grant, scope: scope, authority: authority)
            _ = try validateOperationReadLattice(route, for: scope.project)
            try graphCheck(database, deadline: deadline)
            return try EngramGraphSnapshot(scope: scope, revision: revision,
                                           completeness: limited ? .limitReached : .complete,
                                           nodes: values, edges: edges)
        }
        try Task.checkCancellation()
        try validateGraphGrant(grant, scope: scope, authority: authority)
        _ = try validateOperationReadLattice(route, for: scope.project)
        return snapshot
    }

    private func validateGraphGrant(_ expected: EngramGraphReadGrant, scope: EngramGraphScope,
                                    authority: any EngramGraphReadAuthorizing) throws {
        guard try admittedGraphGrant(authority, scope: scope, principal: identity.currentPrincipal()) == expected else {
            throw EngramGraphExportError.authorizationChanged
        }
        let groups = groupSpokes.map(\.groupId)
        guard Set(groups).count == groups.count, Set(groups).isSubset(of: expected.approvedGroupIDs) else {
            throw EngramGraphExportError.notAuthorized
        }
    }

    private func graphMemoryPredicate(_ scope: EngramGraphScope, now: Date, route: OperationReadContext,
                                      principal: MemoryOperationPrincipalBinding) -> String {
        let project = graphSQL(scope.project)
        let topics = scope.topics.map(graphSQL).joined(separator: ",")
        let topicClause = topics.isEmpty ? "1" : "topic IN (\(topics))"
        let deniedTopic = topics.isEmpty ? "0" : "denial.topic NOT IN (\(topics))"
        var predicate = "project = \(project) AND \(topicClause) AND isPrivate = 0 AND deletedAt IS NULL AND expiresAt > \(now.timeIntervalSince1970)"
        // Union duplicates cannot resurrect a retracted/private identity through an older public copy.
        predicate += " AND NOT EXISTS (SELECT 1 FROM Memory AS denial WHERE denial.globalId = Memory.globalId AND (denial.isPrivate != 0 OR denial.deletedAt IS NOT NULL OR denial.expiresAt <= \(now.timeIntervalSince1970) OR denial.project != \(project) OR \(deniedTopic)))"
        if excludeForeignAuthored {
            let own = graphSQL(principal.id!.uuidString.lowercased())
            if let labels = route.ownLegacySourceLabels {
                // Explicit strict-route provenance; unknown/group sources fail closed. Core's
                // attached labels include escaped SQL-identifier quotes around the filename stem.
                let ownLegacy = "_source IN (\(labels.map(graphSQL).joined(separator: ",")))"
                predicate += " AND (authorUserId = \(own) OR (authorUserId IS NULL AND \(ownLegacy)))"
            } else {
                predicate += " AND (authorUserId = \(own) OR authorUserId IS NULL)"
            }
        }
        return predicate
    }

    private func graphEdges(database: Lattice, nodeIDs: [UUID], deadline: Double,
                            textBytes: inout Int, limited: inout Bool) throws -> [EngramGraphEdge] {
        guard !nodeIDs.isEmpty else { return [] }
        let ids = nodeIDs.map { graphSQL($0.uuidString.lowercased()) }.joined(separator: ",")
        let query = database.dynamicObjects(Edge.entityName).where(
            "sourceGlobalId IN (\(ids)) AND targetGlobalId IN (\(ids)) AND deletedAt IS NULL AND NOT EXISTS (SELECT 1 FROM Edge AS denial WHERE denial.globalId = Edge.globalId AND denial.deletedAt IS NOT NULL)")
        let eligible = query.count
        try graphCheck(database, deadline: deadline)
        let bounded = query.where(GraphExportBounds.edgeSQL)
        let admitted = bounded.count
        try graphCheck(database, deadline: deadline)
        guard eligible == admitted else { throw EngramGraphExportError.capacity }
        var values: [UUID: EngramGraphEdge] = [:], order: [UUID] = []
        var offset = 0
        let physicalLimit = (EngramGraphLimits.maximumEdges + 1) * (Self.maxAttachments + 1)
        while offset < admitted {
            try graphCheck(database, deadline: deadline)
            guard offset < physicalLimit else { limited = true; break }
            let page = bounded.sortedBy("globalId").sortedBy("id").snapshot(limit: 8, offset: offset)
            try graphCheck(database, deadline: deadline)
            guard !page.isEmpty else { throw EngramGraphExportError.inconsistentRows }
            offset += page.count
            for image in page {
                let row = Edge(image.backend).materialize()
                guard let id = row.globalId else { throw EngramGraphExportError.inconsistentRows }
                let value = EngramGraphEdge(id: id, sourceID: row.sourceGlobalId,
                                            targetID: row.targetGlobalId, relation: row.relation.rawValue)
                if let previous = values[id] {
                    guard previous == value else { throw EngramGraphExportError.inconsistentRows }
                    continue
                }
                guard values.count < EngramGraphLimits.maximumEdges,
                      textBytes + value.relation.utf8.count <= EngramGraphLimits.maximumTextBytes else {
                    limited = true; return order.compactMap { values[$0] }
                }
                values[id] = value; order.append(id); textBytes += value.relation.utf8.count
            }
        }
        return order.compactMap { values[$0] }
    }
}

private func graphCheck(_ database: Lattice, deadline: Double) throws {
    try Task.checkCancellation()
    guard database.lastQueryError() == nil, ProcessInfo.processInfo.systemUptime <= deadline else {
        throw EngramGraphExportError.storageUnavailable
    }
}
private func graphSQL(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }

/// Source ceilings precede SELECT * in the SAME statement. Eight selected rows contain at most
/// ~9 MiB of variable payload. This bounds bridge payload, not total SQLite/Swift process RSS.
/// Embedding is bounded incidental row hydration; it is never accessed or copied into a DTO.
private enum GraphExportBounds {
    static let memorySQL = [
        text("globalId", 36), text("content", 1024 * 1024), text("topic", 256), text("project", 256), text("source", 4096),
        text("authorUserId", 36, nullable: true), text("deletedBy", 36, nullable: true),
        "(embedding IS NULL OR (typeof(embedding) = 'blob' AND length(embedding) <= 65536))",
        number("createdAt"), number("lastAccessedAt"), number("expiresAt"), number("modifiedAt", nullable: true),
        "typeof(accessCount) = 'integer'", "typeof(importance) = 'integer'", "typeof(isPrivate) = 'integer'"
    ].joined(separator: " AND ")
    static let edgeSQL = [text("globalId", 36), text("sourceGlobalId", 36), text("targetGlobalId", 36),
                          text("relation", 128), text("authorUserId", 36, nullable: true), number("createdAt"),
                          "relation IN ('relates_to', 'contradicts', 'supersedes', 'derived_from', 'part_of', 'summarized_by')"].joined(separator: " AND ")
    static func number(_ column: String, nullable: Bool = false) -> String {
        let check = "typeof(\(column)) IN ('integer', 'real')"
        return nullable ? "(\(column) IS NULL OR \(check))" : check
    }
    static func text(_ column: String, _ maximum: Int, nullable: Bool = false) -> String {
        let check = "(typeof(\(column)) = 'text' AND length(CAST(\(column) AS BLOB)) <= \(maximum))"
        return nullable ? "(\(column) IS NULL OR \(check))" : check
    }
}

private struct GraphExportNode {
    let id: UUID
    let project, topic, label, content, digest: String
    let contentIsExcerpt: Bool
    let importance: Int
    let createdAt: Date
    var lastAccessedAt: Date
    var textBytes: Int { project.utf8.count + topic.utf8.count + label.utf8.count + content.utf8.count }

    init(_ row: Memory) throws {
        guard let id = row.globalId else { throw EngramGraphExportError.inconsistentRows }
        self.id = id; project = row.project; topic = row.topic
        let source = row.content
        content = graphPrefix(source, bytes: 16 * 1024)
        contentIsExcerpt = content.utf8.count < source.utf8.count
        digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        let extracted = EngramGraphLabels.label(content: source, topic: topic)
        label = graphPrefix(extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? topic : extracted, bytes: 512)
        importance = row.importance; createdAt = row.createdAt; lastAccessedAt = row.lastAccessedAt
    }
    func sameDisplay(as other: Self) -> Bool {
        id == other.id && project == other.project && topic == other.topic && label == other.label
            && digest == other.digest && importance == other.importance && createdAt == other.createdAt
    }
    func value(isHub: Bool) -> EngramGraphNode {
        .init(id: id, project: project, topic: topic, label: label, content: content,
              contentIsExcerpt: contentIsExcerpt, importance: importance, isHub: isHub, position: nil,
              createdAt: createdAt, lastAccessedAt: lastAccessedAt)
    }
}

private func graphPrefix(_ value: String, bytes maximum: Int) -> String {
    var used = 0, end = value.unicodeScalars.startIndex
    for scalar in value.unicodeScalars {
        let width = String(scalar).utf8.count
        guard used + width <= maximum else { break }
        used += width
        end = value.unicodeScalars.index(after: end)
    }
    return String(value[..<end])
}
