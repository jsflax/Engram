import Foundation
import Lattice
import EngramMemoryCore

/// A display snapshot of one explicitly selected existing graph. No vectors,
/// hooks, account discovery, access-counter writes, or sync transports are opened.
public struct AgentMemoryBrowserSnapshot: Sendable {
    public let binding: AgentMemoryBinding
    public let memories: [MemoryRecord]
    public let edges: [EdgeRecord]
    public let pendingEmbeddingCount: Int
    public let matchingMemoryCount: Int
    public let hasMoreMemories: Bool
    public let hasMoreEdges: Bool
    public let focusedID: UUID?
    public let capturedAt: Date
}

/// A bounded, local read for Engram's full graph renderer. Existing vectors are
/// optional display inputs; browsing never creates embeddings or runs inference.
public struct AgentMemoryGraphSnapshot: Sendable {
    public let binding: AgentMemoryBinding
    public let memories: [MemoryRecord]
    public let edges: [EdgeRecord]
    public let embeddings: [UUID: [Float]]
    public let totalMemoryCount: Int
    public let totalEdgeCount: Int
    public let omittedEmbeddingCount: Int
    public let invalidEmbeddingCount: Int
    public let oversizedMemoryCount: Int
    public let oversizedEdgeCount: Int
    public let truncation: Set<AgentMemoryGraphLimit>
    public let capturedAt: Date
}

public enum AgentMemoryGraphLimit: String, Sendable, Hashable {
    case memories, edges, contentBytes, embeddingBytes, edgeBytes, oversizedRecords
}

public struct AgentMemoryGraphReadLimits: Sendable {
    public let memories: Int
    public let edges: Int
    public let contentBytes: Int
    public let embeddingBytes: Int
    public let edgeBytes: Int

    public init(memories: Int = 50_000, edges: Int = 200_000,
                contentBytes: Int = 64 * 1_024 * 1_024, embeddingBytes: Int = 96 * 1_024 * 1_024,
                edgeBytes: Int = 32 * 1_024 * 1_024) {
        self.memories = memories; self.edges = edges
        self.contentBytes = contentBytes; self.embeddingBytes = embeddingBytes
        self.edgeBytes = edgeBytes
    }
}

public enum AgentMemoryReader {
    public enum ReadError: Error, LocalizedError, Sendable {
        case unavailable, wrongOwner, incompatible, invalidRequest, oversizedMemory, queryFailed
        public var errorDescription: String? {
            switch self {
            case .unavailable: "This memory graph is not downloaded on this device."
            case .wrongOwner: "The selected memory graph belongs to a different agent."
            case .incompatible: "This memory graph is not compatible with the viewer."
            case .invalidRequest: "Narrow the memory search or return to the first page."
            case .oversizedMemory: "A memory is too large to display in this viewer."
            case .queryFailed: "The memory graph could not be read. Refresh it or reconnect to its companion and try again."
            }
        }
    }

    /// The embedding app must authorize this exact graph before and after an
    /// asynchronous read. Existing local bytes do not confer permission.
    public static func read(fileURL: URL, binding: AgentMemoryBinding, query: String = "",
                            offset: Int = 0, limit: Int = 60, focusedID: UUID? = nil) throws -> AgentMemoryBrowserSnapshot {
        guard query.utf8.count <= 1024, !query.contains("\0"), (0...100_000).contains(offset), (1...120).contains(limit) else {
            throw ReadError.invalidRequest
        }
        let graph = try open(fileURL: fileURL, binding: binding)
        defer { graph.close() }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let match = text.isEmpty ? "deletedAt IS NULL" :
            "deletedAt IS NULL AND (instr(lower(content), \(literal(text))) > 0 OR instr(lower(project), \(literal(text))) > 0 OR instr(lower(topic), \(literal(text))) > 0)"
        let result = graph.dynamicObjects("Memory").where(match)
        let matching = try checkedQuery(graph) { result.count }
        let pending = try checkedQuery(graph) { graph.dynamicObjects("Memory").where("deletedAt IS NULL AND embeddingPending = 1").count }
        var records: [MemoryRecord]
        var more = false
        if let focusedID {
            records = try checkedQuery(graph) {
                graph.dynamicObjects("Memory")
                    .where("deletedAt IS NULL AND lower(globalId) = \(literal(focusedID.uuidString.lowercased()))")
                    .snapshot(limit: 1)
            }.map(memory)
            guard !records.isEmpty else { throw MemoryServiceError.notFound(focusedID) }
        } else {
            let page = try checkedQuery(graph) { result.sortedBy("createdAt", ascending: false).sortedBy("globalId").snapshot(limit: limit + 1, offset: offset) }
            more = page.count > limit
            records = try page.prefix(limit).map(memory)
        }
        try Task.checkCancellation()
        var edges: [EdgeRecord] = []
        var moreEdges = false
        if !records.isEmpty {
            let ids = records.map { literal($0.id.uuidString.lowercased()) }.joined(separator: ",")
            let endpointTest = focusedID == nil
                ? "lower(sourceGlobalId) IN (\(ids)) AND lower(targetGlobalId) IN (\(ids))"
                : "(lower(sourceGlobalId) IN (\(ids)) OR lower(targetGlobalId) IN (\(ids)))"
            let rows = try checkedQuery(graph) {
                graph.dynamicObjects("Edge").where("deletedAt IS NULL AND \(endpointTest)")
                    .sortedBy("createdAt", ascending: false).sortedBy("globalId").snapshot(limit: 401)
            }
            moreEdges = rows.count > 400
            edges = try rows.prefix(400).map(edge)
            if focusedID != nil {
                let neighbors = Set(edges.flatMap { [$0.sourceId, $0.targetId] }).subtracting(records.map(\.id))
                if !neighbors.isEmpty {
                    let keys = neighbors.sorted { $0.uuidString < $1.uuidString }.map { literal($0.uuidString.lowercased()) }.joined(separator: ",")
                    let remaining = max(0, limit - records.count)
                    let linked = try checkedQuery(graph) {
                        graph.dynamicObjects("Memory").where("deletedAt IS NULL AND lower(globalId) IN (\(keys))")
                            .sortedBy("createdAt", ascending: false).sortedBy("globalId").snapshot(limit: remaining + 1)
                    }
                    more = linked.count > remaining
                    records += try linked.prefix(remaining).map(memory)
                }
            }
        }
        let visible = Set(records.map(\.id))
        edges = edges.filter { visible.contains($0.sourceId) && visible.contains($0.targetId) }
        guard records.reduce(0, { $0 + $1.content.utf8.count }) <= 8_388_608 else { throw ReadError.oversizedMemory }
        try Task.checkCancellation()
        try validateOwner(graph, binding: binding)
        return .init(binding: binding, memories: records, edges: edges, pendingEmbeddingCount: pending, matchingMemoryCount: matching,
                     hasMoreMemories: more, hasMoreEdges: moreEdges, focusedID: focusedID, capturedAt: Date())
    }

    /// Read beyond the old 60-node page, using stable global-ID cursors. Each
    /// batch is materialized before the next query; no live model handles escape
    /// this function. Concurrent writes may appear on a subsequent refresh, so
    /// the counts describe the read rather than a database-wide transaction.
    public static func readGraph(fileURL: URL, binding: AgentMemoryBinding,
                                 limits: AgentMemoryGraphReadLimits = .init()) throws -> AgentMemoryGraphSnapshot {
        guard (1...50_000).contains(limits.memories), (1...200_000).contains(limits.edges),
              (1...67_108_864).contains(limits.contentBytes),
              (0...100_663_296).contains(limits.embeddingBytes),
              (1...33_554_432).contains(limits.edgeBytes) else { throw ReadError.invalidRequest }
        let graph = try open(fileURL: fileURL, binding: binding)
        defer { graph.close() }
        let memoryRows = graph.dynamicObjects("Memory").where("deletedAt IS NULL")
        // IN subqueries build a retained-ID set, rather than issuing one
        // correlated lookup per endpoint. Tombstones and dangling links are not
        // counted as undisplayed graph data.
        let retainedIDs = "SELECT lower(globalId) FROM Memory WHERE deletedAt IS NULL"
        let edgeRows = graph.dynamicObjects("Edge").where("deletedAt IS NULL AND lower(sourceGlobalId) IN (\(retainedIDs)) AND lower(targetGlobalId) IN (\(retainedIDs))")
        let totalMemories = try checkedQuery(graph) { memoryRows.count }
        let totalEdges = try checkedQuery(graph) { edgeRows.count }
        // DynamicResults hydrates whole rows. Bound them in SQL BEFORE that
        // hydration, including future scalar fields, then use small batches.
        // These are logical payload limits; bridge copies and allocator overhead
        // can make peak memory use higher than a page's admitted payload.
        // A node page admits at most 18 MiB and an edge page at most 8 MiB of
        // scalar payload above the retained content/vector budgets. These are
        // data-buffer limits, not a bound on RealityKit or process memory.
        let memoryBytePredicate = try payloadPredicate(graph, table: "Memory", maximum: 1_179_648)
            + " AND coalesce(length(CAST(content AS BLOB)), 1048577) <= 1048576"
        let edgeBytePredicate = try payloadPredicate(graph, table: "Edge", maximum: 65_536)
        let boundedMemories = memoryRows.where(memoryBytePredicate)
        let boundedEdges = edgeRows.where(edgeBytePredicate)
        let boundedMemoryCount = try checkedQuery(graph) { boundedMemories.count }
        let boundedEdgeCount = try checkedQuery(graph) { boundedEdges.count }
        let oversizedMemories = max(0, totalMemories - boundedMemoryCount)
        let oversizedEdges = max(0, totalEdges - boundedEdgeCount)
        var memories: [MemoryRecord] = []
        var embeddings: [UUID: [Float]] = [:]
        var truncation: Set<AgentMemoryGraphLimit> = []
        if oversizedMemories > 0 || oversizedEdges > 0 { truncation.insert(.oversizedRecords) }
        var contentBytes = 0, embeddingBytes = 0, omitted = 0, invalid = 0
        var cursor: String?
        var seen: Set<UUID> = []
        nodeBatches: while true {
            try Task.checkCancellation()
            let query = cursor.map { boundedMemories.where("globalId > \(literal($0))") } ?? boundedMemories
            let rows = try checkedQuery(graph) { query.sortedBy("globalId").snapshot(limit: min(16, limits.memories - memories.count + 1)) }
            if rows.isEmpty { break }
            for row in rows {
                try Task.checkCancellation()
                if memories.count == limits.memories { truncation.insert(.memories); break nodeBatches }
                row.backend.enableRowCache()
                guard let key = row.globalId, cursor == nil || key > cursor! else { throw ReadError.incompatible }
                let record = try memory(row)
                guard seen.insert(record.id).inserted else { throw ReadError.incompatible }
                let bytes = record.content.utf8.count + (record.project?.utf8.count ?? 0)
                    + (record.topic?.utf8.count ?? 0) + (record.source?.utf8.count ?? 0)
                guard bytes <= limits.contentBytes - contentBytes else {
                    truncation.insert(.contentBytes); break nodeBatches
                }
                contentBytes += bytes
                memories.append(record)
                cursor = key
                // A pending vector can refer to old content. Only a current,
                // finite, dimension-bounded stored vector is eligible for layout.
                if (row["embeddingPending"] as? Int64 ?? 0) != 0 {
                    omitted += 1
                } else if let data = row["embedding"] as? Data, !data.isEmpty {
                    guard data.count % MemoryLayout<Float>.size == 0,
                          data.count <= 4_096 * MemoryLayout<Float>.size else {
                        invalid += 1; continue
                    }
                    let vector = Vector<Float>(fromData: data).elements
                    guard vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }) else {
                        invalid += 1; continue
                    }
                    if data.count <= limits.embeddingBytes - embeddingBytes {
                        embeddings[record.id] = vector
                        embeddingBytes += data.count
                    } else {
                        omitted += 1; truncation.insert(.embeddingBytes)
                    }
                } else { omitted += 1 }
            }
        }
        let visible = Set(memories.map(\.id))
        var edges: [EdgeRecord] = []
        var edgeCursor: String?
        var examinedEdges = 0
        var edgeBytes = 0
        var seenEdges: Set<UUID> = []
        edgeBatches: while !visible.isEmpty {
            try Task.checkCancellation()
            let query = edgeCursor.map { boundedEdges.where("globalId > \(literal($0))") } ?? boundedEdges
            let rows = try checkedQuery(graph) { query.sortedBy("globalId").snapshot(limit: min(128, limits.edges - examinedEdges + 1)) }
            if rows.isEmpty { break }
            for row in rows {
                try Task.checkCancellation()
                if examinedEdges == limits.edges { truncation.insert(.edges); break edgeBatches }
                row.backend.enableRowCache()
                guard let key = row.globalId, edgeCursor == nil || key > edgeCursor! else { throw ReadError.incompatible }
                let record = try edge(row)
                guard seenEdges.insert(record.id).inserted else { throw ReadError.incompatible }
                examinedEdges += 1; edgeCursor = key
                if visible.contains(record.sourceId), visible.contains(record.targetId) {
                    guard record.relation.utf8.count <= limits.edgeBytes - edgeBytes else {
                        truncation.insert(.edgeBytes); break edgeBatches
                    }
                    edgeBytes += record.relation.utf8.count
                    edges.append(record)
                }
            }
        }
        try Task.checkCancellation()
        try validateOwner(graph, binding: binding)
        return .init(binding: binding, memories: memories, edges: edges, embeddings: embeddings,
                     totalMemoryCount: max(totalMemories, memories.count), totalEdgeCount: max(totalEdges, edges.count),
                     omittedEmbeddingCount: omitted, invalidEmbeddingCount: invalid,
                     oversizedMemoryCount: oversizedMemories, oversizedEdgeCount: oversizedEdges,
                     truncation: truncation, capturedAt: Date())
    }

    /// Core seals query exceptions as empty/zero values. Check the same thread's
    /// error immediately, before another successful query can erase it. The
    /// user-facing error intentionally excludes SQL, paths and stored content.
    private static func checkedQuery<T>(_ graph: Lattice, _ query: () -> T) throws -> T {
        let value = query()
        guard graph.lastQueryError() == nil else { throw ReadError.queryFailed }
        return value
    }

    private static func payloadPredicate(_ graph: Lattice, table: String, maximum: Int) throws -> String {
        guard let schema = graph.dynamicSchema.first(where: { $0.name == table }) else { throw ReadError.incompatible }
        var columns = Set(schema.properties.filter { $0.isScalar || $0.kind == .unionType }.map(\.name))
        columns.insert("globalId")
        let lengths = columns.sorted().map { name in
            let identifier = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return "coalesce(length(CAST(\(identifier) AS BLOB)), 0)"
        }
        return "(" + lengths.joined(separator: " + ") + ") <= \(maximum)"
    }

    private static func open(fileURL: URL, binding: AgentMemoryBinding) throws -> Lattice {
        var isDirectory: ObjCBool = false
        guard fileURL.isFileURL, FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, fileURL.standardizedFileURL.resolvingSymlinksInPath() == fileURL.standardizedFileURL else {
            throw ReadError.unavailable
        }
        try Task.checkCancellation()
        // createDynamic uses SQLITE_OPEN_READONLY and reconstructs the schema;
        // unlike AgentMemoryStore.open this cannot create/migrate owner rows.
        let graph = try Lattice.dynamic(fileURL: fileURL)
        do {
            let schemas = graph.dynamicSchema
            for (name, fields) in [
                ("AgentMemoryGraph", ["agentId", "graphId"]),
                ("Memory", ["content", "project", "topic", "source", "createdAt", "accessCount", "deletedAt", "embeddingPending"]),
                ("Edge", ["sourceGlobalId", "targetGlobalId", "relation", "createdAt", "deletedAt"])
            ] {
                guard let schema = schemas.first(where: { $0.name == name }),
                      fields.allSatisfy({ schema.property(named: $0)?.isScalar == true }) else { throw ReadError.incompatible }
            }
            try validateOwner(graph, binding: binding)
            return graph
        } catch { graph.close(); throw error }
    }

    private static func validateOwner(_ graph: Lattice, binding: AgentMemoryBinding) throws {
        let owners = try checkedQuery(graph) { graph.dynamicObjects("AgentMemoryGraph").snapshot(limit: 2) }
        guard owners.count == 1 else { throw ReadError.wrongOwner }
        owners[0].backend.enableRowCache()
        guard uuid(owners[0]["agentId"]) == binding.agentId,
              uuid(owners[0]["graphId"]) == binding.graphId else { throw ReadError.wrongOwner }
    }

    private static func literal(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
    private static func uuid(_ value: Any?) -> UUID? { (value as? String).flatMap(UUID.init(uuidString:)) }
    private static func date(_ row: DynamicObject, _ key: String) -> Date? {
        guard let value = row[key] as? Double, value.isFinite else { return nil }
        return Date(timeIntervalSince1970: value)
    }
    private static func memory(_ row: DynamicObject) throws -> MemoryRecord {
        row.backend.enableRowCache()
        guard let id = row.globalId.flatMap(UUID.init(uuidString:)), let content = row["content"] as? String,
              let created = date(row, "createdAt") else { throw ReadError.incompatible }
        guard content.utf8.count <= 1_048_576 else { throw ReadError.oversizedMemory }
        return .init(id: id, content: content, topic: row["topic"] as? String, project: row["project"] as? String,
            source: row["source"] as? String, importance: Int(row["importance"] as? Int64 ?? 0),
            accessCount: Int(row["accessCount"] as? Int64 ?? 0), isPrivate: (row["isPrivate"] as? Int64 ?? 0) != 0,
            authorUserId: uuid(row["authorUserId"]), createdAt: created, modifiedAt: date(row, "modifiedAt"),
            lastAccessedAt: date(row, "lastAccessedAt"), expiresAt: date(row, "expiresAt"))
    }
    private static func edge(_ row: DynamicObject) throws -> EdgeRecord {
        row.backend.enableRowCache()
        guard let id = row.globalId.flatMap(UUID.init(uuidString:)), let source = uuid(row["sourceGlobalId"]),
              let target = uuid(row["targetGlobalId"]), let relation = row["relation"] as? String,
              let created = date(row, "createdAt") else { throw ReadError.incompatible }
        return .init(id: id, sourceId: source, targetId: target, relation: relation,
                     authorUserId: uuid(row["authorUserId"]), createdAt: created)
    }
}
