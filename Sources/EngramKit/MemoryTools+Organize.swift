import Lattice
import MCP
import Foundation

// MARK: - Organize & Community Detection

extension MemoryTools {

    // MARK: - detect_communities

    /// Uses label propagation on the knowledge graph to find natural communities.
    /// Read-only — shows detected groups for Claude to review.
    func handleDetectCommunities(_ args: [String: Value]?) async throws -> CallTool.Result {
        let a = try args.decode(DetectCommunitiesArgs.self)
        let project = a.project

        // Fetch all non-expired, non-episode memories for the project
        let db = readLattice(for: project)
        var query = db.objects(Memory.self).where { $0.deletedAt == nil }
            .distinct(by: \.globalId)
            .where { $0.project == project && $0.expiresAt > Date() && $0.topic != "episode" }
        if excludeForeignAuthored {
            // Maintenance guard: community detection is part of the
            // maintenance workflow — foreign rows stay invisible to it.
            let me = currentUserId
            query = query.where { $0.authorUserId == nil || $0.authorUserId == me }
        }
        let allMemories = query.snapshot()

        guard allMemories.count >= 3 else {
            return CallTool.Result(
                content: [.text("Not enough memories in '\(project)' to detect communities (found \(allMemories.count), need at least 3).")],
                isError: false
            )
        }

        // Build memory globalId set and lookup
        let memoryGlobalIds = Set(allMemories.compactMap(\.globalId))
        let memoryMapByGlobalId: [UUID: Memory] = Dictionary(
            uniqueKeysWithValues: allMemories.compactMap { m in
                guard let gid = m.globalId else { return nil }
                return (gid, m)
            }
        )

        // Build undirected adjacency from all edges between these memories (keyed by globalId)
        var adjacency: [UUID: Set<UUID>] = [:]
        for gid in memoryGlobalIds { adjacency[gid] = [] }

        let edges = db.objects(Edge.self).distinct(by: \.globalId).snapshot()
        for edge in edges {
            guard memoryGlobalIds.contains(edge.sourceGlobalId) && memoryGlobalIds.contains(edge.targetGlobalId) else { continue }
            adjacency[edge.sourceGlobalId, default: []].insert(edge.targetGlobalId)
            adjacency[edge.targetGlobalId, default: []].insert(edge.sourceGlobalId)
        }

        // Run label propagation
        let communities = labelPropagation(adjacency: adjacency)

        // Filter to communities with 2+ members
        let minSize = a.minSize?.value ?? 2
        let significantCommunities = communities.filter { $0.count >= minSize }

        guard !significantCommunities.isEmpty else {
            return CallTool.Result(
                content: [.text("No communities with \(minSize)+ members found in '\(project)'. Memories may not be connected — use `connect` to create edges between related memories first.")],
                isError: false
            )
        }

        // Format output
        var output = "Found \(significantCommunities.count) community/communities in '\(project)':\n"

        for (i, community) in significantCommunities.enumerated() {
            let sorted = community.sorted(by: { $0.uuidString < $1.uuidString })
            output += "\n## Community \(i + 1) (\(sorted.count) memories)"
            for memGlobalId in sorted {
                let mem = memoryMapByGlobalId[memGlobalId]
                let topic = mem?.topic ?? "general"
                let content = mem?.content ?? ""
                let preview = String(content.prefix(150))
                output += "\n  [id:\(memGlobalId.uuidString)] [\(topic)] \(preview)"
            }
            output += "\n"
        }

        // Show isolated nodes count
        let isolatedCount = memoryGlobalIds.count - significantCommunities.reduce(0) { $0 + $1.count }
        if isolatedCount > 0 {
            output += "\n(\(isolatedCount) memories not in any community — they have no edges or are in groups smaller than \(minSize))\n"
        }

        return CallTool.Result(content: [.text(output)], isError: false)
    }

    // MARK: - organize

    /// Simple action: takes memory IDs + label, updates their topics, creates hub, links via part_of.
    func handleOrganize(_ args: [String: Value]?) async throws -> CallTool.Result {
        let a = try args.decode(OrganizeArgs.self)
        let ids = a.ids.values
        let label = a.label

        guard !ids.isEmpty else {
            return CallTool.Result(content: [.text("No memory IDs provided.")], isError: true)
        }
        guard !label.isEmpty else {
            return CallTool.Result(content: [.text("Label cannot be empty.")], isError: true)
        }

        // Verify memories exist and determine project
        var memories: [UUID: Memory] = [:]
        for gid in ids {
            guard let (mem, _) = findMemory(id: gid) else {
                return CallTool.Result(content: [.text("Memory [id:\(gid.uuidString)] not found.")], isError: true)
            }
            memories[gid] = mem
        }

        let project = a.project ?? memories[ids[0]]?.project ?? "global"

        // Create hub memory
        let hubContent = a.summary ?? "Hub: \(label)"
        var hubEmbedding = Vector<Float>([])
        if let floats = try await embedder.embed(text: hubContent) {
            hubEmbedding = Vector<Float>(floats)
        }
        let hub = Memory(
            content: hubContent,
            topic: label,
            project: project,
            source: "organize",
            embedding: hubEmbedding
        )
        // Hub, edges and topic updates share one checked transaction with a
        // bounded BEGIN retry (previously an autocommit add followed by an
        // unchecked transaction whose failed BEGIN trapped the process).
        let hubGlobalId: UUID
        do {
            hubGlobalId = try LatticeBeginRetry.run(on: localLattice, log: { log("[organize] \($0)") }) {
                try localLattice.add(hub)
                guard let hubGid = hub.globalId else {
                    throw MCPError.internalError("Failed to get hub globalId.")
                }
                for gid in ids {
                    if let mem = memories[gid] {
                        let edge = Edge(sourceGlobalId: gid, targetGlobalId: hubGid, relation: .partOf, authorUserId: currentUserId)
                        try localLattice.add(edge)
                        mem.topic = label
                    }
                }
                return hubGid
            }.value
        } catch let contention as LatticeBeginRetry.Contention {
            log("[organize] not organized: \(contention)")
            return Self.busyReceipt(tool: "organize", verb: "organized", contention: contention)
        }

        log("Organized \(ids.count) memories under '\(label)' → hub [id:\(hubGlobalId.uuidString)]")

        var output = "Organized \(ids.count) memories under '\(label)':\n"
        output += "  Hub: [id:\(hubGlobalId.uuidString)]\n"
        output += "  Topic updated to '\(label)' on all \(ids.count) memories\n"
        output += "  part_of edges created from each memory → hub"

        return CallTool.Result(content: [.text(output)], isError: false)
    }
}

// MARK: - Label Propagation

/// Detect communities in an undirected graph via label propagation.
/// Each node starts with its own label, then iteratively adopts the most common
/// label among its neighbors. Converges when no labels change.
/// Returns communities as arrays of node globalIds (sorted by size descending).
public func labelPropagation(adjacency: [UUID: Set<UUID>], maxIterations: Int = 10) -> [[UUID]] {
    // Iterate nodes in a stable order. Dictionary key order is non-deterministic
    // across runs, and label propagation is order-sensitive (a node adopts its
    // neighbours' current-majority label), so unstable order made community
    // assignments flap between runs. Sorting the node list makes it reproducible.
    let orderedNodes = adjacency.keys.sorted { $0.uuidString < $1.uuidString }

    // Seed labels with closed-neighborhood minima instead of singletons:
    // each clique starts at (near-)internal consensus, so a bridge label
    // can never win the all-singleton tie that otherwise floods across a
    // single cross-community edge on unlucky orderings.
    var labels: [UUID: UUID] = [:]
    for id in orderedNodes {
        var seed = id
        for neighbor in adjacency[id] ?? [] where neighbor.uuidString < seed.uuidString {
            seed = neighbor
        }
        labels[id] = seed
    }

    for _ in 0..<maxIterations {
        var changed = false

        // Asynchronous (in-place) updates: each node sees the labels its
        // earlier-visited neighbours adopted THIS pass. The previous
        // synchronous double-buffer variant is the textbook label-propagation
        // failure mode — cliques flip wholesale between passes, and on some
        // orderings a single bridge edge merged two 4-cliques into ONE
        // community. In-place updates let each clique reach local consensus
        // before bridge influence propagates.
        for id in orderedNodes {
            guard let neighbors = adjacency[id], !neighbors.isEmpty else { continue }

            var labelCounts: [UUID: Int] = [:]
            for neighbor in neighbors {
                guard let neighborLabel = labels[neighbor] else { continue }
                labelCounts[neighborLabel, default: 0] += 1
            }

            guard let maxCount = labelCounts.values.max() else { continue }
            let tied = labelCounts.filter { $0.value == maxCount }.keys

            // Sticky ties: when the node's current label is among the tied
            // maxima, keep it. Without this, arbitrary tie-breaking lets one
            // label flood across a bridge and merge communities that only
            // share a single edge.
            let current = labels[id]
            let bestLabel: UUID
            if let current, tied.contains(current) {
                bestLabel = current
            } else {
                bestLabel = tied.min { $0.uuidString < $1.uuidString }!
            }

            if labels[id] != bestLabel {
                labels[id] = bestLabel
                changed = true
            }
        }

        if !changed { break }
    }

    var communities: [UUID: [UUID]] = [:]
    for (id, label) in labels {
        communities[label, default: []].append(id)
    }

    return communities.values
        .sorted { $0.count > $1.count }
}
