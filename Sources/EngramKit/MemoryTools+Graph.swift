import Lattice
import MCP
import Foundation

// MARK: - Knowledge Graph

extension MemoryTools {

    // MARK: - connect

    func handleConnect(_ args: [String: Value]?) throws -> CallTool.Result {
        let a = try args.decode(ConnectArgs.self)
        let fromGid = a.from.value
        let toGid = a.to.value
        let relation = a.relation

        // Validate relation
        guard validRelations.contains(relation) else {
            throw MCPError.invalidParams("Invalid relation '\(relation)'. Must be one of: \(validRelations.sorted().joined(separator: ", "))")
        }

        // Parse relation enum
        guard let relationEnum = Edge.Relation(rawValue: relation) else {
            throw MCPError.invalidParams("Invalid relation '\(relation)'.")
        }

        // Validate both memories exist
        guard findMemory(id: fromGid) != nil else {
            return CallTool.Result(content: [.text("Memory with id \(fromGid.uuidString) not found.")], isError: true)
        }
        guard findMemory(id: toGid) != nil else {
            return CallTool.Result(content: [.text("Memory with id \(toGid.uuidString) not found.")], isError: true)
        }

        // Check for duplicate edge. A TOMBSTONED identical edge is revived
        // instead of blocking creation — otherwise a tombstoned edge would
        // squat the (from, to, relation) slot forever ("already exists"
        // without actually linking anything).
        let existing = localLattice.objects(Edge.self)
            .where { $0.sourceGlobalId == fromGid && $0.targetGlobalId == toGid && $0.relation == relationEnum }
        if let edge = existing.first {
            let edgeGid = edge.globalId?.uuidString ?? "?"
            if edge.deletedAt != nil {
                edge.deletedAt = nil
                log("Revived tombstoned edge [id:\(edgeGid)]")
                return CallTool.Result(
                    content: [.text("Revived tombstoned edge (edge id: \(edgeGid), \(fromGid.uuidString) --[\(relation)]--> \(toGid.uuidString)).")],
                    isError: false
                )
            }
            return CallTool.Result(
                content: [.text("Edge already exists (edge id: \(edgeGid), \(fromGid.uuidString) --[\(relation)]--> \(toGid.uuidString)).")],
                isError: false
            )
        }

        // Create edge (always in localLattice), attributed to the writer
        let edge = Edge(sourceGlobalId: fromGid, targetGlobalId: toGid, relation: relationEnum, authorUserId: currentUserId)
        try localLattice.add(edge)

        guard let edgeGid = edge.globalId else {
            throw MCPError.internalError("Failed to persist edge — globalId is nil after add()")
        }

        log("Connected [id:\(fromGid.uuidString)] --[\(relation)]--> [id:\(toGid.uuidString)]")
        return CallTool.Result(
            content: [.text("Connected (edge id: \(edgeGid.uuidString)) [id:\(fromGid.uuidString)] --[\(relation)]--> [id:\(toGid.uuidString)]")],
            isError: false
        )
    }

    // MARK: - disconnect

    func handleDisconnect(_ args: [String: Value]?) throws -> CallTool.Result {
        let a = try args.decode(DisconnectArgs.self)

        // By edge UUID. Edges whose endpoints are group-shared TOMBSTONE
        // (a hard edge delete replicates to every member); purely-local
        // edges keep the hard delete.
        if let edgeGid = a.id?.value {
            guard let (edge, foundLattice) = findEdge(id: edgeGid) else {
                return CallTool.Result(content: [.text("Edge with id \(edgeGid.uuidString) not found.")], isError: true)
            }
            if edgeTouchesGroupSharedMemory(edge) {
                edge.deletedAt = Date()
                log("Tombstoned group-shared edge [id:\(edgeGid.uuidString)]")
                return CallTool.Result(
                    content: [.text("Removed edge (id: \(edgeGid.uuidString)) — tombstoned (its endpoints are group-shared; hidden for all members).")],
                    isError: false
                )
            }
            foundLattice.delete(Edge.self, where: { $0.globalId == edgeGid })
            log("Disconnected edge [id:\(edgeGid.uuidString)]")
            return CallTool.Result(
                content: [.text("Deleted edge (id: \(edgeGid.uuidString)).")],
                isError: false
            )
        }

        // By from + to (memory UUIDs)
        guard let fromGid = a.from?.value, let toGid = a.to?.value else {
            throw MCPError.invalidParams("Provide 'id' or both 'from' and 'to' to target edges.")
        }

        // Validate memories exist
        guard findMemory(id: fromGid) != nil else {
            return CallTool.Result(content: [.text("Memory with id \(fromGid.uuidString) not found.")], isError: true)
        }
        guard findMemory(id: toGid) != nil else {
            return CallTool.Result(content: [.text("Memory with id \(toGid.uuidString) not found.")], isError: true)
        }

        var query = localLattice.objects(Edge.self)
            .where { $0.sourceGlobalId == fromGid && $0.targetGlobalId == toGid }
        if let relation = a.relation, let relationEnum = Edge.Relation(rawValue: relation) {
            query = query.where { $0.relation == relationEnum }
        }

        let edges = query.snapshot()
        if edges.isEmpty {
            return CallTool.Result(content: [.text("No edges found from \(fromGid.uuidString) to \(toGid.uuidString).")], isError: false)
        }

        var tombstoned = 0
        var deleted = 0
        for edge in edges {
            if edgeTouchesGroupSharedMemory(edge) {
                if edge.deletedAt == nil { edge.deletedAt = Date() }
                tombstoned += 1
            } else if let egid = edge.globalId {
                localLattice.delete(Edge.self, where: { $0.globalId == egid })
                deleted += 1
            }
        }

        var parts: [String] = []
        if deleted > 0 { parts.append("\(deleted) deleted") }
        if tombstoned > 0 { parts.append("\(tombstoned) group-shared → tombstoned") }
        log("Disconnected \(edges.count) edge(s) from [id:\(fromGid.uuidString)] to [id:\(toGid.uuidString)]")
        return CallTool.Result(
            content: [.text("Removed \(edges.count) edge(s) from [id:\(fromGid.uuidString)] to [id:\(toGid.uuidString)] (\(parts.joined(separator: "; "))).")],
            isError: false
        )
    }

    /// Whether either endpoint of this edge is a group-shared memory —
    /// drives tombstone-vs-hard-delete for edge removal.
    func edgeTouchesGroupSharedMemory(_ edge: Edge) -> Bool {
        for gid in [edge.sourceGlobalId, edge.targetGlobalId] {
            if let (mem, _) = findMemory(id: gid), isGroupShared(mem) {
                return true
            }
        }
        return false
    }

    // MARK: - graph

    func handleGraph(_ args: [String: Value]?) throws -> CallTool.Result {
        let a = try args.decode(GraphArgs.self)
        let memGid = a.id.value
        let depth = max(min(a.depth?.value ?? 1, 3), 0)

        // Validate memory exists
        guard let (rootMem, rootLattice) = findMemory(id: memGid) else {
            return CallTool.Result(content: [.text("Memory with id \(memGid.uuidString) not found.")], isError: true)
        }
        if rootMem.deletedAt != nil {
            let by = GroupDirectory.badgeName(for: rootMem.deletedBy)
            let when = rootMem.deletedAt.map { Self.dateFormatter.string(from: $0) } ?? "?"
            return CallTool.Result(
                content: [.text("Memory \(memGid.uuidString) is tombstoned by \(by) on \(when) — update(id:, undelete: true) to restore it before exploring its graph.")],
                isError: false
            )
        }
        // Maintenance/opt-out guard: a foreign root is indistinguishable
        // from a missing one.
        if excludeForeignAuthored, isForeignAuthored(rootMem) {
            return CallTool.Result(content: [.text("Memory with id \(memGid.uuidString) not found.")], isError: true)
        }

        // BFS traversal using globalIds on the same lattice the root was found in
        var visited = Set<UUID>([memGid])
        var frontier = Set<UUID>([memGid])
        var allEdges: [(edge: Edge, depth: Int)] = []

        for d in stride(from: 1, through: depth, by: 1) {
            var nextFrontier = Set<UUID>()
            for nodeGlobalId in frontier {
                // Outgoing edges (tombstoned edges excluded — their endpoint
                // memory is tombstoned too)
                let outgoing = rootLattice.objects(Edge.self).where { $0.sourceGlobalId == nodeGlobalId && $0.deletedAt == nil }
                for edge in outgoing {
                    allEdges.append((edge: edge, depth: d))
                    if !visited.contains(edge.targetGlobalId) {
                        visited.insert(edge.targetGlobalId)
                        nextFrontier.insert(edge.targetGlobalId)
                    }
                }
                // Incoming edges
                let incoming = rootLattice.objects(Edge.self).where { $0.targetGlobalId == nodeGlobalId && $0.deletedAt == nil }
                for edge in incoming {
                    allEdges.append((edge: edge, depth: d))
                    if !visited.contains(edge.sourceGlobalId) {
                        visited.insert(edge.sourceGlobalId)
                        nextFrontier.insert(edge.sourceGlobalId)
                    }
                }
            }
            frontier = nextFrontier
            if frontier.isEmpty { break }
        }

        // Deduplicate edges by globalId
        var seenEdgeGids = Set<UUID>()
        var uniqueEdges: [Edge] = []
        for (edge, _) in allEdges {
            guard let edgeGid = edge.globalId else { continue }
            if !seenEdgeGids.contains(edgeGid) {
                seenEdgeGids.insert(edgeGid)
                uniqueEdges.append(edge)
            }
        }

        // Format output — look up memories by globalId for display
        var output = "[id:\(memGid.uuidString)] \(rootMem.content)"

        // Foreign-authored neighbors: badge them ([by:Name] — graph is the
        // tool consulted right before connect/update decisions), or drop
        // them entirely under the maintenance/opt-out guard.
        func excluded(_ m: Memory?) -> Bool {
            guard let m else { return false }
            return excludeForeignAuthored && isForeignAuthored(m)
        }
        func badge(_ m: Memory?) -> String {
            guard let m, isForeignAuthored(m) else { return "" }
            return " [by:\(GroupDirectory.badgeName(for: m.authorUserId))]"
        }

        if uniqueEdges.isEmpty {
            output += "\n\nNo connections."
        } else {
            output += "\n\nConnections:"
            for edge in uniqueEdges {
                if edge.sourceGlobalId == memGid {
                    // Outgoing
                    let targetMem = rootLattice.objects(Memory.self).where { $0.globalId == edge.targetGlobalId }.first
                    if excluded(targetMem) { continue }
                    let targetContent = targetMem?.content ?? "(deleted)"
                    output += "\n  --[\(edge.relation.rawValue)]--> [id:\(edge.targetGlobalId.uuidString)]\(badge(targetMem)) \(targetContent.prefix(80))"
                } else if edge.targetGlobalId == memGid {
                    // Incoming
                    let sourceMem = rootLattice.objects(Memory.self).where { $0.globalId == edge.sourceGlobalId }.first
                    if excluded(sourceMem) { continue }
                    let sourceContent = sourceMem?.content ?? "(deleted)"
                    output += "\n  <--[\(edge.relation.rawValue)]-- [id:\(edge.sourceGlobalId.uuidString)]\(badge(sourceMem)) \(sourceContent.prefix(80))"
                } else {
                    // Edge between two non-root nodes (deeper traversal)
                    let sourceMem = rootLattice.objects(Memory.self).where { $0.globalId == edge.sourceGlobalId }.first
                    let targetMem = rootLattice.objects(Memory.self).where { $0.globalId == edge.targetGlobalId }.first
                    // Keep non-Sendable model references on this actor; Swift 6.4
                    // treats the right side of || as a separately isolated autoclosure.
                    if excluded(sourceMem) { continue }
                    if excluded(targetMem) { continue }
                    let sourceContent = sourceMem?.content ?? "(deleted)"
                    let targetContent = targetMem?.content ?? "(deleted)"
                    output += "\n  [id:\(edge.sourceGlobalId.uuidString)]\(badge(sourceMem)) \(sourceContent.prefix(40))... --[\(edge.relation.rawValue)]--> [id:\(edge.targetGlobalId.uuidString)]\(badge(targetMem)) \(targetContent.prefix(40))..."
                }
            }
        }

        return CallTool.Result(content: [.text(output)], isError: false)
    }

    // MARK: - Graph Helpers

    /// Delete all edges where sourceGlobalId or targetGlobalId is in the given set. Returns count deleted.
    @discardableResult
    func deleteEdgesForMemories(_ globalIds: [UUID]) -> Int {
        var total = 0
        for gid in globalIds {
            let count = localLattice.count(Edge.self, where: { $0.sourceGlobalId == gid || $0.targetGlobalId == gid })
            if count > 0 {
                localLattice.delete(Edge.self, where: { $0.sourceGlobalId == gid || $0.targetGlobalId == gid })
                total += count
            }
        }
        return total
    }

    /// Tombstone (soft-delete) all edges touching the given memories — the
    /// group-shared counterpart of deleteEdgesForMemories: a hard edge
    /// delete would LWW-replicate to every member, and the memory these
    /// edges reference is itself only tombstoned (recoverable).
    ///
    /// Deliberately TRANSACTION-FREE (each setter is its own implicit
    /// transaction): callers include paths already inside a transaction
    /// (merge), and Lattice's beginTransaction does not guard nesting.
    /// Covers both the local and synced lattices — edges for synced-project
    /// rows live in the synced DB too.
    @discardableResult
    func tombstoneEdgesForMemories(_ globalIds: [UUID]) -> Int {
        var total = 0
        let now = Date()
        var lattices: [Lattice] = [localLattice]
        if let syncedLattice { lattices.append(syncedLattice) }
        for lattice in lattices {
            for gid in globalIds {
                let edges = lattice.objects(Edge.self)
                    .where { ($0.sourceGlobalId == gid || $0.targetGlobalId == gid) && $0.deletedAt == nil }
                    .snapshot()
                for edge in edges {
                    edge.deletedAt = now
                }
                total += edges.count
            }
        }
        return total
    }

    /// Reverse of tombstoneEdgesForMemories, run on undelete: revive edges
    /// touching the restored memory whose OTHER endpoint is still live —
    /// edges pointing at still-tombstoned (or hard-deleted) memories stay
    /// tombstoned, so restoring one memory never resurrects links into
    /// removed content.
    @discardableResult
    func reviveEdgesForMemory(_ gid: UUID) throws -> Int {
        var total = 0
        var lattices: [Lattice] = [localLattice]
        if let syncedLattice { lattices.append(syncedLattice) }
        for lattice in lattices {
            let revived = try lattice.withTransaction {
                let edges = lattice.objects(Edge.self)
                    .where { ($0.sourceGlobalId == gid || $0.targetGlobalId == gid) && $0.deletedAt != nil }
                    .snapshot()
                var count = 0
                for edge in edges {
                    let otherGid = edge.sourceGlobalId == gid ? edge.targetGlobalId : edge.sourceGlobalId
                    guard let (other, _) = findMemory(id: otherGid), other.deletedAt == nil else { continue }
                    edge.deletedAt = nil
                    count += 1
                }
                return count
            }
            total += revived
        }
        return total
    }

    /// BFS graph traversal from a set of starting memory globalIds, returning connected memories
    /// annotated with the depth at which they were discovered and the edge that connected them.
    ///
    /// When a `filter` closure is provided, each discovered memory is tested against it.
    /// Memories that fail the filter are excluded from results AND removed from the BFS
    /// frontier — so their neighbors at deeper depths are never reached.
    func traverseGraph(
        from startGlobalIds: Set<UUID>,
        depth: Int,
        excludeGlobalIds: Set<UUID>,
        db: Lattice,
        filter: ((Memory, Edge) -> Bool)? = nil
    ) -> [(memory: Memory, depth: Int, connectingEdge: Edge)] {
        var visited = excludeGlobalIds
        var frontier = startGlobalIds
        var result: [(memory: Memory, depth: Int, connectingEdge: Edge)] = []
        // EVERY edge that reached a discovered node this round — not just
        // the first. Two memories are routinely linked twice (auto-connect
        // writes relates_to, the user then adds part_of), and iteration
        // order put the loose edge first: the cosine gate then judged the
        // node on relates_to and dropped it, silently shadowing the
        // structural edge that should have admitted it unconditionally.
        // Admission is "ANY connecting edge passes the filter".
        var connectingEdges: [UUID: [Edge]] = [:]
        let now = Date()

        for d in stride(from: 1, through: depth, by: 1) {
            var nextFrontier = Set<UUID>()
            for nodeGlobalId in frontier {
                // Outgoing edges. materialize(): the query hydrated each edge
                // row already — the 2-3 field reads here plus the formatting
                // reads in the caller become statement-free.
                for edge in db.objects(Edge.self).where({ $0.sourceGlobalId == nodeGlobalId && $0.deletedAt == nil }) {
                    edge.materialize()
                    if !visited.contains(edge.targetGlobalId) {
                        visited.insert(edge.targetGlobalId)
                        nextFrontier.insert(edge.targetGlobalId)
                    }
                    if nextFrontier.contains(edge.targetGlobalId) {
                        connectingEdges[edge.targetGlobalId, default: []].append(edge)
                    }
                }
                // Incoming edges
                for edge in db.objects(Edge.self).where({ $0.targetGlobalId == nodeGlobalId && $0.deletedAt == nil }) {
                    edge.materialize()
                    if !visited.contains(edge.sourceGlobalId) {
                        visited.insert(edge.sourceGlobalId)
                        nextFrontier.insert(edge.sourceGlobalId)
                    }
                    if nextFrontier.contains(edge.sourceGlobalId) {
                        connectingEdges[edge.sourceGlobalId, default: []].append(edge)
                    }
                }
            }
            // Fetch memories and apply filter; only memories that pass continue in BFS
            var passingFrontier = Set<UUID>()
            for gid in nextFrontier {
                // Tombstone filter INSIDE the BFS hydration — a handler-level
                // filter alone would leak tombstoned memories into recall's
                // Connected section via traversal.
                if let mem = db.objects(Memory.self).where({ $0.globalId == gid && $0.expiresAt > now && $0.deletedAt == nil }).first,
                   let edges = connectingEdges[gid], !edges.isEmpty {
                    // Hydrated by the fetch — the filter's embedding read and
                    // the caller's formatting reads (content up to 4x per
                    // large memory) serve from the snapshot.
                    mem.materialize()
                    // The node is admitted if ANY of its connecting edges
                    // passes; the edge that passed is the one reported (it
                    // is the reason the node is here).
                    guard let admitting = edges.first(where: { filter?(mem, $0) ?? true }) else {
                        continue  // excluded from results and frontier
                    }
                    result.append((memory: mem, depth: d, connectingEdge: admitting))
                    passingFrontier.insert(gid)
                }
            }
            frontier = passingFrontier
            if frontier.isEmpty { break }
        }

        return result
    }
}
