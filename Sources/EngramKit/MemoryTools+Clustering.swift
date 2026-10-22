import Lattice
import MCP
import Foundation

// MARK: - Clustering Algorithm

/// Term-overlap tokenizer — must stay IDENTICAL to `jaccardSimilarity`'s
/// (lowercased, split on non-alphanumerics, tokens ≥ 3 chars). Clustering
/// tokenizes each memory ONCE instead of re-tokenizing both sides of every
/// candidate pair.
private func clusterTokens(_ s: String) -> Set<String> {
    Set(
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
    )
}

/// `jaccardSimilarity` over pre-tokenized term sets.
private func clusterJaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
    guard !a.isEmpty || !b.isEmpty else { return 0.0 }
    return Double(a.intersection(b).count) / Double(a.union(b).count)
}

/// Compute semantic clusters from memories using embedding similarity + Jaccard term overlap.
/// Runs an in-process k-NN pass over the candidate snapshot, then greedy
/// seed-based clustering. Returns clusters (arrays of memory global ids) and
/// a pairwise distance cache.
///
/// The neighbour pass used to issue one Lattice `.nearest()` (vec0 KNN) call
/// per memory. That cost one multi-KB prepared statement per memory — the
/// bridge inlines the query vector as a hex blob literal, once per attached
/// schema arm — plus a live `SELECT col WHERE id = ?` per field per candidate
/// row: 20,802 statements for a 200-memory fixture, and the visualizer runs
/// this once per project on every graph load (28K memories ⇒ ~28K KNN queries,
/// each MATCHing the WHOLE vector table). It was also WRONG at scale: vec0
/// takes the global top-2k and post-filters by the project predicate, so a
/// busy neighbouring project could evict a memory's real same-project
/// neighbours (pinned by `clusters_neighborsAreProjectScoped`).
///
/// The candidate set is already in hand — `baseQuery` gets snapshotted either
/// way — so the k-NN runs over that array: ONE materialized snapshot, zero
/// further SQL. Distances are accumulated directly rather than through the
/// |a|²+|b|²−2a·b Gram identity (which cancels catastrophically in Float32
/// exactly where this code cares most — near-duplicate pairs), with an
/// early-out as soon as the running sum passes the distance threshold, and
/// each pair visited once and offered to both endpoints.
///
/// Equivalence: `{b ∈ topK(a) : d(a,b) ≤ T}` is precisely "the K closest
/// b with d(a,b) ≤ T", so bounding the search by T up front and keeping the
/// K best yields the same neighbour set the truncate-then-threshold shape did.
public func findMemoryClusters(
    in lattice: Lattice,
    project: String? = nil,
    topic: String? = nil,
    distanceThreshold: Double = 0.775,  // v2: L2 of cosine-similarity 0.70 — topical-cluster band
    jaccardThreshold: Double = 0.2,
    minClusterSize: Int = 2,
    maxClusters: Int = 10,
    neighborLimit: Int? = nil,
    excludeForeign: Bool = false,
    selfUserId: UUID? = nil
) -> (clusters: [[UUID]], distances: [UUID: [UUID: Double]]) {
    let now = Date()
    var baseQuery = lattice.objects(Memory.self).distinct(by: \.globalId).where { $0.expiresAt > now && $0.deletedAt == nil }
    if let project { baseQuery = baseQuery.where { $0.project == project } }
    if let topic { baseQuery = baseQuery.where { $0.topic == topic } }
    // ONE materialized snapshot: the query already hydrated every row, so the
    // embedding / content / author reads below cost no further SQL (a live
    // model handle serves each property read with its own SELECT).
    var memories = baseQuery.materializedSnapshot()
    // Maintenance guard: the maintenance subprocess must never receive
    // foreign-authored content in cluster listings (its prompts are a
    // Bash-capable injection target). Handlers pass their exclusion policy
    // through; nil-author rows are the user's own legacy rows.
    if excludeForeign {
        memories = memories.filter { $0.authorUserId == nil || $0.authorUserId == selfUserId }
    }

    guard memories.count >= minClusterSize else { return ([], [:]) }

    // Flatten the candidate set into parallel arrays: ids, term sets, and one
    // contiguous embedding matrix. `embedding` is read exactly once per row.
    var ids: [UUID] = []
    var terms: [Set<String>] = []
    var flat: [Float] = []
    var dims = -1
    var seen = Set<UUID>()
    ids.reserveCapacity(memories.count)
    terms.reserveCapacity(memories.count)
    for mem in memories {
        guard let gid = mem.globalId else { continue }
        let vec = mem.embedding.elements
        guard !vec.isEmpty else { continue }
        if dims < 0 {
            dims = vec.count
            flat.reserveCapacity(memories.count * dims)
        }
        // A vec0 table carries ONE dimension, so rows left behind by an
        // embedding-space migration were never comparable to the current
        // space under the old KNN either — skip rather than mis-measure.
        guard vec.count == dims else { continue }
        // `distinct(by: globalId)` should already guarantee this; a set
        // insert is cheaper than the trap `Dictionary(uniqueKeysWithValues:)`
        // took on a duplicate.
        guard seen.insert(gid).inserted else { continue }
        ids.append(gid)
        terms.append(clusterTokens(mem.content))
        flat.append(contentsOf: vec)
    }

    // Named to avoid shadowing the `n` the greedy loop below binds.
    let candidateCount = ids.count
    let validIds = seen
    guard candidateCount >= minClusterSize else { return ([], [:]) }

    // Build the neighbor map: for each memory, the k nearest others within
    // the distance threshold AND with Jaccard term overlap >= threshold. The
    // term test keeps same-project memories about different subsystems from
    // clustering together just because they share project vocabulary.
    let k = Swift.max(1, Swift.min(neighborLimit ?? candidateCount, candidateCount))
    let threshold2 = Float(distanceThreshold * distanceThreshold)

    // Per-row k-best, kept ascending by distance. Sized by what actually
    // falls within the threshold, so an unbounded `neighborLimit` (nil) does
    // not pre-allocate an n×n matrix.
    var best = [[(idx: Int, dist: Float)]](repeating: [], count: candidateCount)

    func offer(_ row: Int, _ other: Int, _ dist: Float) {
        let existing = best[row].count
        if existing == k, dist >= best[row][existing - 1].dist { return }
        var pos = existing
        while pos > 0, best[row][pos - 1].dist > dist { pos -= 1 }
        best[row].insert((idx: other, dist: dist), at: pos)
        if best[row].count > k { best[row].removeLast() }
    }

    if dims > 0 {
        flat.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for i in 0..<candidateCount {
                let a = base + i * dims
                for j in (i + 1)..<candidateCount {
                    let b = base + j * dims
                    // Squared L2 with an early-out: the partial sum is
                    // monotonic, so once it passes the threshold the pair
                    // can never qualify. Checked every 32 lanes to keep the
                    // inner loop tight.
                    var sum: Float = 0
                    var d = 0
                    var rejected = false
                    while d < dims {
                        let end = Swift.min(d + 32, dims)
                        var lane: Float = 0
                        while d < end {
                            let delta = a[d] - b[d]
                            lane += delta * delta
                            d += 1
                        }
                        sum += lane
                        if sum > threshold2 { rejected = true; break }
                    }
                    guard !rejected else { continue }
                    let dist = sum.squareRoot()
                    offer(i, j, dist)
                    offer(j, i, dist)
                }
            }
        }
    }

    var neighborMap: [UUID: [UUID]] = [:]
    var distanceCache: [UUID: [UUID: Double]] = [:]
    neighborMap.reserveCapacity(candidateCount)
    distanceCache.reserveCapacity(candidateCount)
    for i in 0..<candidateCount {
        var neighbors: [UUID] = []
        var dists: [UUID: Double] = [:]
        for candidate in best[i] {
            guard clusterJaccard(terms[i], terms[candidate.idx]) >= jaccardThreshold else { continue }
            let nId = ids[candidate.idx]
            neighbors.append(nId)
            dists[nId] = Double(candidate.dist)
        }
        neighborMap[ids[i]] = neighbors
        distanceCache[ids[i]] = dists
    }

    // Greedy clustering: pick memory with most unassigned neighbors as seed
    var assigned = Set<UUID>()
    var clusters: [[UUID]] = []

    while clusters.count < maxClusters {
        var bestSeed: UUID? = nil
        var bestCount = 0
        for memId in validIds where !assigned.contains(memId) {
            let unassigned = (neighborMap[memId] ?? []).filter { !assigned.contains($0) }.count
            if unassigned > bestCount {
                bestCount = unassigned
                bestSeed = memId
            }
        }
        guard let seed = bestSeed else { break }

        var cluster = [seed]
        assigned.insert(seed)
        let neighbors = (neighborMap[seed] ?? []).filter { !assigned.contains($0) }
        let sorted = neighbors.sorted { a, b in
            (distanceCache[seed]?[a] ?? 1.0) < (distanceCache[seed]?[b] ?? 1.0)
        }
        for n in sorted where !assigned.contains(n) {
            cluster.append(n)
            assigned.insert(n)
        }

        if cluster.count >= minClusterSize {
            clusters.append(cluster)
        } else {
            for id in cluster where id != seed {
                assigned.remove(id)
            }
        }
    }

    return (clusters, distanceCache)
}

// MARK: - MCP Tool Handlers

extension MemoryTools {

    // MARK: - find_clusters

    func handleFindClusters(_ args: [String: Value]?) async throws -> CallTool.Result {
        let a = try args.decode(FindClustersArgs.self)
        let minSize = a.minClusterSize?.value ?? 3
        // Convert user-facing cosine percentage to L2 distance: L2 = sqrt(2 * cosine)
        let cosineThreshold = Double(a.distanceThreshold?.value ?? 30) / 100.0
        let threshold = sqrt(2.0 * cosineThreshold)
        let maxClusters = a.maxClusters?.value ?? 10

        let db = readLattice(for: a.project)
        let result = findMemoryClusters(
            in: db,
            project: a.project,
            topic: a.topic,
            distanceThreshold: threshold,
            jaccardThreshold: 0.2,
            minClusterSize: minSize,
            maxClusters: maxClusters,
            neighborLimit: 50,
            excludeForeign: excludeForeignAuthored,
            selfUserId: currentUserId
        )

        guard !result.clusters.isEmpty else {
            return CallTool.Result(content: [.text("No clusters found. Memories are too dissimilar at distance threshold \(Int(threshold * 100)) (try increasing distance_threshold).")], isError: false)
        }

        // Fetch memory data for formatting. materialize(): the lookup query
        // already hydrated the row, so the topic/content/author reads in the
        // formatting loop below cost no further SQL.
        var memoryMap: [UUID: Memory] = [:]
        for gid in Set(result.clusters.flatMap({ $0 })) {
            if let mem = db.objects(Memory.self).where({ $0.globalId == gid }).first {
                memoryMap[gid] = mem.materialize()
            }
        }

        // Format output
        var output = "Found \(result.clusters.count) cluster(s):\n"
        for (i, cluster) in result.clusters.enumerated() {
            // Compute average pairwise similarity from cached distances
            var totalSim: Double = 0
            var pairCount = 0
            var distances: [Double] = []
            for (ai, a) in cluster.enumerated() {
                for b in cluster[(ai + 1)...] {
                    if let dist = result.distances[a]?[b] ?? result.distances[b]?[a] {
                        // Convert L2 distance to cosine similarity for normalized vectors
                        totalSim += 1.0 - (dist * dist) / 2.0
                        pairCount += 1
                        distances.append(dist)
                    }
                }
            }
            let avgSim = pairCount > 0 ? totalSim / Double(pairCount) : 0

            let meanDist = distances.isEmpty ? 0.0 : distances.reduce(0, +) / Double(distances.count)
            let variance = distances.isEmpty ? 0.0 : distances.map { ($0 - meanDist) * ($0 - meanDist) }.reduce(0, +) / Double(distances.count)
            let stdev = sqrt(variance)

            let topics = cluster.compactMap { memoryMap[$0]?.topic }
            let uniqueTopics = Set(topics)
            let majorityTopic = Dictionary(grouping: topics, by: { $0 })
                .max(by: { $0.value.count < $1.value.count })?.key ?? "general"

            // Redundancy assessment
            let assessment: String
            if avgSim >= 0.95 && stdev <= 0.03 {
                assessment = "⚠️ Likely redundant — good candidates for consolidation"
            } else {
                assessment = "ℹ️ Topically similar but may cover distinct aspects — review content carefully before consolidating"
            }

            output += "\n## Cluster \(i + 1): \(majorityTopic) (\(cluster.count) memories, \(uniqueTopics.count) topic(s))\n"
            output += "Avg. similarity: \(String(format: "%.2f", avgSim)) | Distance stdev: \(String(format: "%.4f", stdev))\n"
            output += "\(assessment)\n\n"
            let selfId = currentUserId
            for memGid in cluster {
                let mem = memoryMap[memGid]
                let content = mem?.content ?? ""
                let preview = String(content.prefix(120))
                // Foreign-author label — the consolidation decision needs to
                // know whose memories a cluster contains (demoting them is
                // group-wide; the consolidate handler enforces force: true).
                let badge = (mem?.authorUserId != nil && mem?.authorUserId != selfId)
                    ? " [by:\(GroupDirectory.badgeName(for: mem?.authorUserId))]" : ""
                output += "[id:\(memGid.uuidString)]\(badge) \(preview)\n"
            }
            let idList = cluster.map { $0.uuidString }.joined(separator: ",")
            output += "\nIDs: \(idList)\n"
        }

        return CallTool.Result(content: [.text(output)], isError: false)
    }

    // MARK: - consolidate

    func handleConsolidate(_ args: [String: Value]?) async throws -> CallTool.Result {
        let a = try args.decode(ConsolidateArgs.self)
        guard !a.content.isEmpty else {
            throw MCPError.invalidParams("'content' is required")
        }
        let ids = a.ids.values
        guard ids.count >= 2 else {
            throw MCPError.invalidParams("'ids' must contain at least 2 memory IDs to consolidate")
        }
        let importance = min(max(a.importance?.value ?? 3, 1), 5)

        // Fetch all memories by globalId
        var sources: [(memory: Memory, lattice: Lattice)] = []
        for gid in ids {
            guard let found = findMemory(id: gid) else {
                return CallTool.Result(content: [.text("Memory with id \(gid.uuidString) not found.")], isError: true)
            }
            sources.append(found)
        }

        // Hard backstop (not just agent-prompt guidance): consolidating a
        // cluster with FOREIGN-authored members demotes teammates' memories
        // group-wide. Require an explicit force acknowledgment. Tombstoned
        // members are never consolidated.
        if sources.contains(where: { $0.memory.deletedAt != nil }) {
            return CallTool.Result(
                content: [.text("One or more memories are tombstoned — undelete them first or drop them from the cluster.")],
                isError: true
            )
        }
        let selfId = currentUserId
        let foreignMembers = sources.filter { $0.memory.authorUserId != nil && $0.memory.authorUserId != selfId }
        if !foreignMembers.isEmpty && a.force != true {
            let names = foreignMembers
                .map { GroupDirectory.badgeName(for: $0.memory.authorUserId) }
            let uniqueNames = Array(Set(names)).sorted().joined(separator: ", ")
            return CallTool.Result(
                content: [.text("This cluster contains \(foreignMembers.count) memory(ies) written by teammates (\(uniqueNames)) — consolidating demotes THEIR memories for the whole group. Prefer connect(relation: \"relates_to\") to link without demoting, or pass force: true to proceed deliberately.")],
                isError: true
            )
        }

        // Determine project and topic
        let project = a.project ?? sources[0].memory.project
        let topic = a.topic ?? {
            let grouped = Dictionary(grouping: sources, by: { $0.memory.topic })
            return grouped.max(by: { $0.value.count < $1.value.count })?.key ?? sources[0].memory.topic
        }()

        // Generate embedding for summary
        guard let floats = try await embedder.embed(text: a.content) else {
            throw MCPError.internalError("Embedding model unavailable — cannot consolidate memories without a vector. Check that the CoreML model is bundled correctly.")
        }
        let embeddingVec = Vector<Float>(floats)

        // Create summary memory (authored by the runner)
        let summary = Memory(
            content: a.content,
            topic: topic,
            project: project,
            source: "consolidation",
            embedding: embeddingVec,
            importance: importance,
            authorUserId: currentUserId,
            modifiedAt: Date()
        )
        // Summary, deprioritized originals (importance → 0) and summarized_by
        // edges share one checked transaction with a bounded BEGIN retry.
        nonisolated(unsafe) let sourceMemories = sources.map(\.memory)
        let sourceGlobalIds = sourceMemories.compactMap(\.globalId)
        let summaryGlobalId: UUID
        do {
            summaryGlobalId = try LatticeBeginRetry.run(on: localLattice, log: { log("[consolidate] \($0)") }) {
                try localLattice.add(summary)
                guard let summaryGid = summary.globalId else {
                    throw MCPError.internalError("Failed to get summary globalId after persist")
                }
                for mem in sourceMemories {
                    mem.importance = 0
                }
                for sourceGlobalId in sourceGlobalIds {
                    let edge = Edge(sourceGlobalId: sourceGlobalId, targetGlobalId: summaryGid, relation: .summarizedBy, authorUserId: currentUserId)
                    try localLattice.add(edge)
                }
                return summaryGid
            }.value
        } catch let contention as LatticeBeginRetry.Contention {
            log("[consolidate] not consolidated: \(contention)")
            return Self.busyReceipt(tool: "consolidate", verb: "consolidated", contention: contention)
        }

        let preview = String(a.content.prefix(120))
        log("Consolidated \(ids.count) memories into [id:\(summaryGlobalId.uuidString)]")
        return CallTool.Result(
            content: [.text("""
                Created summary [id:\(summaryGlobalId.uuidString)] (project: \(project), topic: \(topic), importance: \(importance))
                Deprioritized \(sources.count) original memories (importance → 0)
                Created \(sources.count) 'summarized_by' edges

                Summary: \(preview)
                """)],
            isError: false
        )
    }
}
