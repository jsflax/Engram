import EngramMemoryCore
import Lattice
import MCP
import Foundation
import NaturalLanguage

// MARK: - Direct Access (for hooks)

extension MemoryTools {
    /// Perform a recall and return the text result directly, without MCP framing.
    /// Used by the hooks binary to inject recalled memories as context.
    public func directRecall(query: String, project: String?, depth: Int = 1, limit: Int = 5) async throws -> String? {
        var args: [String: Value] = ["query": .string(query)]
        if let project {
            args["project"] = .string(project)
        }
        args["depth"] = .int(depth)
        args["limit"] = .int(limit)
        let result = try await handleRecall(args)
        // Extract text from the CallTool.Result
        guard let textContent = result.content.first else { return nil }
        switch textContent {
        case .text(let text, _, _):
            return text == "No memories found." ? nil : text
        default:
            return nil
        }
    }
}

// MARK: - Content Word Extraction

extension MemoryTools {
    /// POS tags to drop from queries — function words that add noise to FTS5 search.
    /// Language-agnostic: NLTagger assigns these tags regardless of input language.
    private static let dropTags: Set<NLTag> = [
        .determiner, .pronoun, .preposition, .conjunction, .particle,
    ]

    /// Function words that NLTagger's lexical class KEEPS (copulas/auxiliaries
    /// are tagged `.verb`; interrogatives are tagged `.adverb`) but which carry
    /// no recall signal. Dropped by an explicit lowercase match after POS
    /// filtering so recall queries aren't diluted by "is"/"how"/etc.
    private static let dropWords: Set<String> = [
        "is", "are", "was", "were", "be", "been", "being", "am",  // copulas
        "have", "has", "had", "do", "does", "did",                // auxiliaries
        "how", "what", "when", "where", "why", "who", "which",    // interrogatives
    ]

    /// Extract content words from a query using NLTagger POS tagging.
    /// Drops determiners, pronouns, prepositions, conjunctions, particles (by
    /// POS tag), plus copulas/auxiliaries and interrogatives (by explicit word,
    /// since NLTagger tags those as verbs/adverbs and would otherwise keep them).
    /// Keeps nouns, content verbs, adjectives, adverbs, and unknown/technical terms.
    ///
    /// Falls back to all whitespace-split words if no content words survive.
    public static func extractContentWords(from query: String) -> [String] {
        guard !query.isEmpty else { return [] }

        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = query

        var contentWords: [String] = []
        tagger.enumerateTags(
            in: query.startIndex..<query.endIndex,
            unit: .word,
            scheme: .lexicalClass
        ) { tag, range in
            // Skip tokens with no tag (whitespace, punctuation)
            guard let tag else { return true }
            // Drop known function-word POS tags
            if Self.dropTags.contains(tag) { return true }
            // Drop copulas/auxiliaries/interrogatives POS filtering keeps
            let lowered = String(query[range]).trimmingCharacters(in: .whitespaces).lowercased()
            if Self.dropWords.contains(lowered) { return true }
            // Keep everything else: nouns, verbs, adjectives, adverbs, unknown terms
            let word = String(query[range]).trimmingCharacters(in: .whitespaces)
            if !word.isEmpty { contentWords.append(word) }
            return true
        }

        // Fall back to raw split if NLTagger stripped everything
        if contentWords.isEmpty {
            return query.split(separator: " ").map(String.init)
        }
        return contentWords
    }
}


// MARK: - CRUD + Search + Timeline

extension MemoryTools {

    // MARK: - remember

    func handleRemember(_ args: [String: Value]?) async throws -> CallTool.Result {
        log("[remember] START")
        let a = try args.decode(RememberArgs.self)
        log("[remember] decoded args, content length: \(a.content.count)")
        guard !a.content.isEmpty else {
            throw MCPError.invalidParams("'content' is required")
        }
        let content = a.content
        let topic = a.topic ?? "general"
        let project = a.project ?? "global"
        let source = a.source ?? ""
        let expiresAt: Date
        if let days = a.expiresInDays?.value, days > 0 {
            expiresAt = Date().addingTimeInterval(Double(days) * 86400)
        } else {
            expiresAt = .distantFuture
        }
        let importance: Int
        if let imp = a.importance?.value {
            guard (1...5).contains(imp) else {
                throw MCPError.invalidParams("'importance' must be between 1 and 5, got \(imp)")
            }
            importance = imp
        } else {
            importance = 0
        }

        log("[remember] calling embedder.embed()")
        guard let floats = try await embedder.embed(text: content) else {
            throw MCPError.internalError("Embedding model unavailable — cannot store memory without a vector. Check that the CoreML model is bundled correctly.")
        }
        let embeddingVec = Vector<Float>(floats)
        log("[remember] embedding done, \(floats.count) dims")

        // Conflict detection + auto-connect candidate gathering
        // Search is done outside the force guard so auto-connect candidates survive force=true
        var autoConnectCandidates: [(object: Memory, distance: Double)] = []

        if !embeddingVec.isEmpty && topic != "episode" {
            log("[remember] starting conflict detection query")
            log("[remember] readLattice for project: \(project)")
            let latticeRef = readLattice(for: project)
            log("[remember] got lattice ref, building query")
            let baseQuery = latticeRef.objects(Memory.self)
                .distinct(by: \.globalId)
                .where { $0.expiresAt > Date() && $0.topic != "episode" && $0.deletedAt == nil }
                .where { $0.project == project || $0.project == "global" }
            log("[remember] query built, calling nearest() with embedding dim=\(embeddingVec.count)")
            // snapshot() materializes atomically — see the recall nearest()
            // comment.
            let candidates = baseQuery
                .nearest(to: embeddingVec, on: \.embedding, limit: 8, distance: .l2)
                .snapshot()
            log("[remember] nearest() returned")
            log("[remember] nearest query returned \(candidates.count) candidates")

            // Conflict detection (unchanged behavior, just nested under force guard)
            if a.force != true {
                let conflicts = candidates.filter { match in
                    let sameProject = match.object.project == project
                    let threshold = sameProject ? 0.55 : 0.45  // v2 space (Aug 2026): near-dupe band from 27k-row calibration — same-project NN p50 0.37, paraphrases 0.53–0.69
                    guard match.distance < threshold else { return false }
                    return jaccardSimilarity(content, match.object.content) >= 0.4
                }
                if !conflicts.isEmpty {
                    var warning = "⚠️ Near-duplicate memory detected. The new memory was NOT stored.\n\nExisting similar memories:"
                    for match in conflicts {
                        let m = match.object
                        guard let mGid = m.globalId else { continue }
                        let dist = String(format: "%.3f", match.distance)
                        let jaccard = String(format: "%.0f%%", jaccardSimilarity(content, m.content) * 100)
                        warning += "\n  [id:\(mGid.uuidString)] (distance: \(dist), term overlap: \(jaccard)) \(m.content)"
                    }
                    warning += "\n\nTo resolve:"
                    warning += "\n  - Use `update(id: \"UUID\", ...)` to modify the existing memory"
                    warning += "\n  - Use `remember(..., force: true)` to keep both"
                    warning += "\n  - Use `forget(id: \"UUID\")` to remove the old one, then `remember` the new one"
                    log("Conflict detected for: \(content.prefix(80))")
                    return CallTool.Result(content: [.text(warning)], isError: false)
                }
            }

            // Gather auto-connect candidates (beyond conflict zone, within relatedness threshold)
            autoConnectCandidates = candidates.compactMap { match in
                let sameProject = match.object.project == project
                let conflictThreshold = sameProject ? 0.55 : 0.45  // v2 space: see remember-time comment
                guard match.distance >= conflictThreshold && match.distance < 1.00 else { return nil }  // v2: related band upper = cosine 0.5; top-3 cap contains noise
                return (object: match.object, distance: match.distance)
            }
            autoConnectCandidates.sort { $0.distance < $1.distance }
            autoConnectCandidates = Array(autoConnectCandidates.prefix(3))
        }

        let parentGidValue: UUID? = a.parentId?.value
        if let parentGid = parentGidValue {
            guard findMemory(id: parentGid) != nil else {
                throw MCPError.invalidParams("parent_id \(parentGid.uuidString) not found")
            }
        }

        // Prepare episode bookkeeping without publishing it on a failed write.
        // There is no suspension between this snapshot and the checked commit.
        let rememberedAt = Date()
        let episodeExpired = activeEpisodeId != nil && rememberedAt.timeIntervalSince(lastMemoryTime) > 1800
        let episodeId = episodeExpired ? nil : activeEpisodeId
        let isPrivate = a.isPrivate ?? false
        let memory = Memory(content: content, topic: topic, project: project, source: source, embedding: embeddingVec, expiresAt: expiresAt, importance: importance, isPrivate: isPrivate, authorUserId: currentUserId, modifiedAt: rememberedAt)
        var parentNote = ""
        var autoLinkedGids: [UUID] = []
        var committedLogs: [String] = []

        // The Memory and its required graph/topic effects share one checked
        // transaction. A failed BEGIN cannot execute the body in autocommit.
        // Other errors still propagate without claiming that rollback settled.
        var transactionBodyEntered = false
        let memoryGlobalId: UUID
        do {
            memoryGlobalId = try localLattice.withTransaction { () throws -> UUID in
                transactionBodyEntered = true
                if let parentGid = parentGidValue {
                    guard findMemory(id: parentGid) != nil else {
                        throw MCPError.invalidParams("parent_id \(parentGid.uuidString) not found")
                    }
                }
                try localLattice.add(memory)
                guard let memoryGlobalId = memory.globalId else {
                    throw MCPError.internalError("Failed to persist memory — globalId is nil after add()")
                }
                // Auto-create part_of edge when parent_id is provided
                if let parentGid = parentGidValue {
                    let edge = Edge(sourceGlobalId: memoryGlobalId, targetGlobalId: parentGid, relation: .partOf, authorUserId: currentUserId)
                    try localLattice.add(edge)
                    parentNote = ", parent: \(parentGid.uuidString)"
                    committedLogs.append("Auto-created part_of edge: \(memoryGlobalId.uuidString) -> \(parentGid.uuidString)")
                }

                // Link to active episode via part_of edge
                if let epGid = episodeId,
                   localLattice.objects(Memory.self).where({ $0.globalId == epGid }).first != nil {
                    let edge = Edge(sourceGlobalId: memoryGlobalId, targetGlobalId: epGid, relation: .partOf, authorUserId: currentUserId)
                    try localLattice.add(edge)
                    committedLogs.append("Linked memory \(memoryGlobalId.uuidString) to episode \(epGid.uuidString)")
                }

                // Auto-connect: create relates_to edges to semantically similar memories
                for candidate in autoConnectCandidates {
                    guard let candidateGlobalId = candidate.object.globalId else { continue }
                    if let pgid = parentGidValue, candidateGlobalId == pgid { continue }
                    if let epGid = episodeId, candidateGlobalId == epGid { continue }
                    let forwardEdge = localLattice.objects(Edge.self)
                        .where { $0.sourceGlobalId == memoryGlobalId && $0.targetGlobalId == candidateGlobalId && $0.relation == .relatesTo }
                        .first != nil
                    let reverseEdge = localLattice.objects(Edge.self)
                        .where { $0.sourceGlobalId == candidateGlobalId && $0.targetGlobalId == memoryGlobalId && $0.relation == .relatesTo }
                        .first != nil
                    guard !(forwardEdge || reverseEdge) else { continue }

                    let edge = Edge(sourceGlobalId: memoryGlobalId, targetGlobalId: candidateGlobalId, relation: .relatesTo, authorUserId: currentUserId)
                    try localLattice.add(edge)
                    autoLinkedGids.append(candidateGlobalId)
                    committedLogs.append("Auto-connected [\(memoryGlobalId.uuidString)] --[relates_to]--> [\(candidateGlobalId.uuidString)] (distance: \(String(format: "%.3f", candidate.distance)))")
                }

                // Cross-project hub linking
                if topic != "episode" {
                    let allProjects = Set(
                        localLattice.objects(Memory.self)
                            .snapshot()
                            .map(\.project)
                    ).subtracting([project, "global"])

                    for otherProject in allProjects {
                        guard otherProject.count >= 3 else { continue }

                        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: otherProject))\\b"
                        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                              regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) != nil
                        else { continue }

                        let projectMemories = localLattice.objects(Memory.self)
                            .where { $0.project == otherProject && $0.topic != "episode" }
                            .snapshot()

                        var bestHub: (mem: Memory, count: Int)? = nil
                        for mem in projectMemories {
                            let incomingCount = localLattice.objects(Edge.self)
                                .where { $0.targetGlobalId == mem.globalId && $0.relation == .partOf }
                                .count
                            if incomingCount > 0 && (bestHub == nil || incomingCount > bestHub!.count) {
                                bestHub = (mem: mem, count: incomingCount)
                            }
                        }

                        guard let hub = bestHub, let hubGlobalId = hub.mem.globalId else { continue }

                        let forwardLinked = localLattice.objects(Edge.self)
                            .where { $0.sourceGlobalId == memoryGlobalId && $0.targetGlobalId == hubGlobalId && $0.relation == .relatesTo }
                            .first != nil
                        let reverseLinked = localLattice.objects(Edge.self)
                            .where { $0.sourceGlobalId == hubGlobalId && $0.targetGlobalId == memoryGlobalId && $0.relation == .relatesTo }
                            .first != nil
                        guard !(forwardLinked || reverseLinked) else { continue }

                        let edge = Edge(sourceGlobalId: memoryGlobalId, targetGlobalId: hubGlobalId, relation: .relatesTo, authorUserId: currentUserId)
                        try localLattice.add(edge)
                        autoLinkedGids.append(hubGlobalId)
                        committedLogs.append("Cross-project link [\(memoryGlobalId.uuidString)] --[relates_to]--> [\(hubGlobalId.uuidString)] (project '\(otherProject)' mentioned in content)")
                    }
                }

                // Incremental topic/hub inference from auto-connect neighbors
                if !autoConnectCandidates.isEmpty {
                    var hubCounts: [UUID: Int] = [:]
                    var topicCounts: [String: Int] = [:]

                    for candidate in autoConnectCandidates {
                        guard let candidateGlobalId = candidate.object.globalId else { continue }
                        for edge in localLattice.objects(Edge.self)
                            .where({ $0.sourceGlobalId == candidateGlobalId && $0.relation == .partOf }) {
                            if localLattice.objects(Memory.self)
                                .where({ $0.globalId == edge.targetGlobalId && $0.topic != "episode" }).first != nil {
                                hubCounts[edge.targetGlobalId, default: 0] += 1
                            }
                        }
                        if candidate.object.topic != "episode" {
                            let hasIncoming = localLattice.objects(Edge.self)
                                .where { $0.targetGlobalId == candidateGlobalId && $0.relation == .partOf }
                                .first != nil
                            if hasIncoming {
                                hubCounts[candidateGlobalId, default: 0] += 1
                            }
                        }
                        let t = candidate.object.topic
                        if t != "general" && t != "episode" {
                            topicCounts[t, default: 0] += 1
                        }
                    }

                    if let (hubGlobalId, count) = hubCounts.max(by: { $0.value < $1.value }),
                       count >= 2 {
                        let skipHub = parentGidValue.map { $0 == hubGlobalId } ?? false
                        if !skipHub {
                            let alreadyLinked = localLattice.objects(Edge.self)
                                .where { $0.sourceGlobalId == memoryGlobalId && $0.targetGlobalId == hubGlobalId && $0.relation == .partOf }
                                .first != nil
                            if !alreadyLinked {
                                let edge = Edge(sourceGlobalId: memoryGlobalId, targetGlobalId: hubGlobalId, relation: .partOf, authorUserId: currentUserId)
                                try localLattice.add(edge)
                                committedLogs.append("Auto-organized [\(memoryGlobalId.uuidString)] into hub [\(hubGlobalId.uuidString)]")
                            }
                        }
                    }

                    if topic == "general",
                       let (consensusTopic, count) = topicCounts.max(by: { $0.value < $1.value }),
                       count >= 2 {
                        memory.topic = consensusTopic
                        committedLogs.append("Auto-inferred topic '\(consensusTopic)' for [\(memoryGlobalId.uuidString)]")
                    }
                }
                return memoryGlobalId
            }
        } catch {
            // Only a failed BEGIN proves this attempt did not run any write.
            // Identical text from a body, COMMIT, rollback, or notification
            // failure must retain its unknown persistence outcome.
            guard !transactionBodyEntered,
                  case LatticeError.transactionError(let detail) = error,
                  ["database is locked", "database is busy", "database table is locked",
                   "database schema is locked"].contains(where: {
                      detail == "Failed to begin transaction: " + $0
                  }) else { throw error }
            return CallTool.Result(
                content: [.text("Memory was not stored: the database was busy before the write transaction started. Retry on a later turn.")],
                structuredContent: .object([
                    "engram_write_receipt": .object([
                        "schema_version": .int(1),
                        "tool": .string("remember"),
                        "write_outcome": .string("not_stored_transaction_not_started"),
                        "reason": .string("database_busy"),
                        "memory_ids": .array([]),
                    ]),
                ]),
                isError: true
            )
        }

        // Publish process-local state and success logs only after checked commit
        // returns. A body/commit/notification failure leaves these untouched.
        if episodeExpired { endActiveEpisode() }
        lastMemoryTime = rememberedAt
        lastRememberedId = memoryGlobalId
        for message in committedLogs { log(message) }

        let expiresNote = expiresAt == .distantFuture ? "" : ", expires: \(Self.dateFormatter.string(from: expiresAt))"
        let importanceNote = importance > 0 ? ", importance: \(importance)" : ""
        let privateNote = isPrivate ? ", private: true" : ""
        let autoLinkNote = autoLinkedGids.isEmpty ? "" : ", auto-linked to \(autoLinkedGids.map { "[id:\($0.uuidString)]" }.joined(separator: ", "))"
        log("Stored memory [\(project)/\(topic)]: \(content.prefix(80))")
        appendSessionSaveLog(
            sessionId: currentSessionId,
            globalId: memoryGlobalId.uuidString,
            project: project,
            topic: topic,
            preview: String(content.prefix(50))
        )

        var response = "Stored memory (id: \(memoryGlobalId.uuidString), project: \(project), topic: \(topic)\(parentNote)\(expiresNote)\(importanceNote)\(privateNote)\(autoLinkNote)): \(content.prefix(100))\(content.count > 100 ? "..." : "")"

        // Nudge toward atomic memories when content is complex
        let lines = content.components(separatedBy: "\n")
        let headers = lines.filter { $0.hasPrefix("## ") || $0.hasPrefix("### ") }
        if content.count > 1000 && headers.count >= 2 {
            let names = headers.map {
                $0.drop(while: { $0 == "#" || $0 == " " })
            }
            response += "\n\n💡 This memory has \(headers.count) sections (\(names.joined(separator: ", "))). "
            response += "Consider storing each section as a child memory with `parent_id: \"\(memoryGlobalId.uuidString)\"` for more precise recall."
        }

        log("[remember] SUCCESS, returning response")
        return CallTool.Result(
            content: [.text(response)],
            isError: false
        )
    }

    // MARK: - recall

    /// Capture provenance while rendering, never by parsing recalled content.
    nonisolated static func appendRecallRowMarker(_ id: UUID, to output: inout String,
                                                  rows: inout [RecallRowBoundary]) {
        output += "[id:\(id.uuidString)] "
        rows.append(RecallRowBoundary(id: id, markerEnd: output.count))
    }

    func handleRecall(_ args: [String: Value]?) async throws -> CallTool.Result {
        lastRecallHits = []
        lastRecallMode = .vector
        lastRecallRows = []
        var recalledHits: [RecallHit] = []
        var recalledMode: RecallMode = .vector
        var renderedRows: [RecallRowBoundary] = []
        // Keep capture local across embedding awaits, then publish it with
        // this invocation's result, including empty/error returns.
        defer {
            lastRecallHits = recalledHits
            lastRecallMode = recalledMode
            lastRecallRows = renderedRows
        }
        let a = try args.decode(RecallArgs.self)
        guard !a.query.isEmpty else {
            throw MCPError.invalidParams("'query' is required")
        }
        let query = a.query
        let projectFilter = a.project
        let topicFilter = a.topic
        let limit = a.limit?.value ?? 10
        let depth = min(a.depth?.value ?? 0, 3)
        let hasTemporalFilter = a.since != nil || a.before != nil

        log("[recall] START query=\"\(query.prefix(80))\", project=\(projectFilter ?? "nil"), topic=\(topicFilter ?? "nil"), limit=\(limit), depth=\(depth)")
        sessionLog("[recall] START query=\"\(query.prefix(60))\"")

        // Build base query — route reads to the right DB based on project sync policy
        sessionLog("[recall] readLattice...")
        let db = readLattice(for: projectFilter)
        log("[recall] DB selected")
        sessionLog("[recall] DB selected")
        var results = db.objects(Memory.self)
            .distinct(by: \.globalId)
            .where { $0.expiresAt > Date() && $0.deletedAt == nil }  // tombstone filter
        log("[recall] Base query built")
        sessionLog("[recall] Base query built")

        // Topic is still a hard filter (it's a narrow constraint)
        if let topicFilter {
            results = results.where { $0.topic == topicFilter }
        }

        // Temporal filters on createdAt
        if let sinceStr = a.since {
            guard let sinceDate = parseTemporalDate(sinceStr) else {
                throw MCPError.invalidParams("Could not parse 'since' date: \(sinceStr)")
            }
            results = results.where { $0.createdAt >= sinceDate }
        }
        if let beforeStr = a.before {
            guard let beforeDate = parseTemporalDate(beforeStr) else {
                throw MCPError.invalidParams("Could not parse 'before' date: \(beforeStr)")
            }
            results = results.where { $0.createdAt <= beforeDate }
        }

        // Vector-first recall: L2 KNN uses the native vec0 index (O(log n)).
        // Embeddings are normalized so L2 and cosine give equivalent rankings.
        // FTS5 is only used as a degraded fallback when the embedding model is unavailable.
        log("[recall] Embedding query text...")
        sessionLog("[recall] Embedding query text...")
        if let queryEmbedding = try await embedder.embed(text: query) {
            log("[recall] Embedding complete, dims=\(queryEmbedding.count)")
            sessionLog("[recall] Embedding complete")
            // Soft project boost: fetch wider net, then re-rank
            let fetchLimit = projectFilter != nil ? limit * 3 : limit
            let embedding = Vector<Float>(queryEmbedding)

            log("[recall] Running nearest() with fetchLimit=\(fetchLimit)")
            sessionLog("[recall] Running nearest() fetchLimit=\(fetchLimit)")
            // snapshot() executes the KNN query ONCE and builds the array
            // from that single result set. Collection operations (.map,
            // .filter) on live Results go through the re-querying subscript:
            // if a concurrent writer (daemon relay, another session) shrinks
            // the result set mid-iteration, the subscript traps "Index out of
            // bounds" — the production MCP recall crash (crash-99579.log,
            // Apr 9). `Array.init` has the mirror-image trap: it reserves
            // from `count` and dies with "more than 'count' elements" when a
            // concurrent writer GROWS the set between the count and the copy
            // (test-runner signal-5 crashes, Aug 5–6).
            let nearest = results
                .nearest(to: embedding, on: \.embedding, limit: fetchLimit, distance: .l2)
                .snapshot()
            log("[recall] nearest() returned \(nearest.count) results")
            sessionLog("[recall] nearest() returned \(nearest.count) results")

            // Materialize every match: the KNN hydration already fetched each
            // full row, so the boosting + formatting reads below become
            // statement-free. Without this, every property access is its own
            // `SELECT col WHERE id=?`, and recall issued ~300 statements per
            // call — each scanning the WAL the sync daemon churns (observed
            // 228s for a single depth-1 recall on a bloated WAL).
            for match in nearest { match.object.materialize() }

            if nearest.isEmpty {
                log("[recall] No results, returning empty")
                sessionLog("[recall] No results")
                return CallTool.Result(content: [.text("No memories found.")], isError: false)
            }

            // Apply soft project boosting and reinforcement scoring on distances
            sessionLog("[recall] Starting boosting loop (\(nearest.count) items)")
            let now = Date()
            // Teammates derive `project` from their own folder names, so the
            // same codebase arrives under a different string. Boost every
            // local name that maps to the same group project (decision 13),
            // or the teammate's memory about this very repo ranks as if it
            // were from an unrelated one.
            let queryProjects = projectFilter.map { resolveQueryProjects($0) }
            let boosted: [(object: Memory, distance: Double)] = nearest.map { match in
                let m = match.object
                let l2Dist = match.distances["embedding"] ?? match.distance

                // Project boost
                let projectBoost: Double
                if let queryProjects {
                    if queryProjects.contains(m.project) {
                        projectBoost = 0.7   // same-project: strong boost
                    } else if m.project == "global" {
                        projectBoost = 0.85  // global: moderate boost
                    } else {
                        projectBoost = 1.0   // other-project: no boost
                    }
                } else {
                    projectBoost = 1.0       // no project filter: no boost
                }

                // Frequency boost — log-scaled accessCount (caps at 15% reduction)
                let frequencyBoost = 1.0 - min(log2(1.0 + Double(m.accessCount)) * 0.04, 0.15)

                // Importance boost — explicit 1-5 rating (caps at 20% reduction)
                let importanceBoost = m.importance > 0 ? 1.0 - Double(m.importance - 1) * 0.05 : 1.0

                // Recency boost — exponential decay from lastAccessedAt (10% max for just-accessed)
                let daysSinceAccess = now.timeIntervalSince(m.lastAccessedAt) / 86400.0
                let recencyBoost = 1.0 - 0.1 * exp(-daysSinceAccess / 30.0)

                // Staleness penalty — never-accessed memories older than 14 days rank lower (up to 20%)
                let daysSinceCreation = now.timeIntervalSince(m.createdAt) / 86400.0
                let stalenessPenalty: Double = (m.accessCount == 0 && daysSinceCreation > 14.0)
                    ? 1.0 + min((daysSinceCreation - 14.0) / 180.0 * 0.20, 0.20)
                    : 1.0

                let distance = l2Dist * projectBoost * frequencyBoost * importanceBoost * recencyBoost * stalenessPenalty
                return (object: m, distance: distance)
            }

            log("[recall] Boosting complete for \(boosted.count) results")
            sessionLog("[recall] Boosting complete for \(boosted.count) results")
            // Foreign exclusion (advise opt-out / maintenance guard) happens
            // BEFORE the limit so it never under-fills the result set.
            let candidates = excludeForeignAuthored
                ? boosted.filter { !isForeignAuthored($0.object) }
                : boosted
            // Re-sort by boosted distance and take top `limit`
            let sorted = candidates.sorted { $0.distance < $1.distance }
            let topResults = Array(sorted.prefix(limit))

            if topResults.isEmpty {
                return CallTool.Result(content: [.text("No memories found.")], isError: false)
            }

            // Filter out outliers: adaptive threshold anchored to best result.
            // Keeps tight clusters tight, but allows broader queries to return
            // legitimately distant results without a brittle hard cutoff.
            let bestDistance = topResults.first!.distance
            let distances = topResults.map(\.distance)
            let p75 = distances[distances.count * 3 / 4]
            let threshold = max(min(p75 * 1.2, bestDistance * 3.0), 1e-9)
            let filtered = topResults.filter { $0.distance <= threshold }
            log("[recall] After outlier filter: \(filtered.count) results (threshold=\(String(format: "%.3f", threshold)))")
            sessionLog("[recall] Outlier filter: \(filtered.count) results")

            // Structured capture: direct hits in boosted order, BEFORE the
            // access-stat bump — the bump's writes invalidate the row caches,
            // so a post-bump read would re-issue one SELECT per field.
            // Traversal hits append below.
            recalledHits = filtered.compactMap { hit in
                guard hit.object.globalId != nil else { return nil }
                return RecallHit(memory: record(from: hit.object),
                                 distance: hit.distance,
                                 depth: 0,
                                 isForeign: isForeignAuthored(hit.object))
            }

            // Access-stat bumps are DEFERRED to one batched transaction after
            // the output is composed (see below) — the old per-loop
            // `localLattice.transaction` was a silent no-op for synced
            // projects: the recalled objects live on the attaching lattice's
            // connection, so the txn wrapped nothing and every bump
            // autocommitted individually.
            //
            // Spoke-resident rows are EXCLUDED: bumping one writes into the
            // group DB, which the daemon relays over WSS to every member —
            // an O(members) write fan-out per recall, and those remote
            // entries would perpetually re-trip the reconciliation trigger.
            // Access stats are personal ranking metadata, so only the copies
            // that live in the hub or the personal mirror get bumped.
            var bumpTargets: [Memory] = filtered.map(\.object).filter { m in
                guard !groupSpokes.isEmpty else { return true }
                guard let gid = m.globalId else { return false }
                return isHubResident(gid)
            }

            let lines = filtered.compactMap { match -> (id: UUID, body: String)? in
                let m = match.object
                guard let mGid = m.globalId else { return nil }
                let dist = String(format: "%.3f", match.distance)
                let impInfo = m.importance > 0 ? ", importance: \(m.importance)" : ""
                let expires = m.expiresAt == .distantFuture ? "" : ", expires: \(Self.dateFormatter.string(from: m.expiresAt))"
                let created = hasTemporalFilter ? ", created: \(Self.dateFormatter.string(from: m.createdAt))" : ""
                // Author badge for FOREIGN-authored (group) memories only —
                // own + legacy rows stay clean. Placement after
                // [project/topic] is load-bearing: logRecalledMemories
                // anchors on [id: and the FIRST bracket pair after it.
                // Goes through isForeignAuthored so a nil-author row that
                // exists only in a spoke is caught: an unstamped teammate
                // memory must not render unlabelled and unfenced.
                let isForeign = isForeignAuthored(m)
                let badge = isForeign
                    ? " [by:\(GroupDirectory.badgeName(for: m.authorUserId))]" : ""
                // Graph provenance: spoke-resident rows carry the group's
                // name — "which of my graphs did this come from" is part of
                // proving multi-graph recall works. After [by:] so the
                // recall-log parser's first-bracket anchor is untouched.
                let via = viaMarker(for: mGid)
                // Advise-injection path: foreign content renders inside the
                // escape-hardened indentation fence.
                let body = (isForeign && fenceForeignContent)
                    ? Self.fencedForeignContent(m.content) : m.content
                return (mGid, "[\(m.project)/\(m.topic)]\(badge)\(via) (distance: \(dist)\(impInfo)\(expires)\(created)) \(body)")
            }

            var output = ""

            // Knowledge gap detection — signal when recall results are weak
            let avgDistance = filtered.map(\.distance).reduce(0, +) / Double(max(filtered.count, 1))
            if avgDistance > 1.05 {  // v2: relevant query→memory hits measure 0.86–1.05; beyond = weak
                output = "⚠️ Weak recall (avg distance: \(String(format: "%.3f", avgDistance)), count: \(filtered.count)). Results may not be closely related to the query.\n\n"
            }
            for (index, line) in lines.enumerated() {
                if index > 0 { output += "\n\n" }
                Self.appendRecallRowMarker(line.id, to: &output, rows: &renderedRows)
                output += line.body
            }

            log("[recall] Output formatted, \(lines.count) lines")
            sessionLog("[recall] Output formatted, \(lines.count) lines")

            // Graph traversal when depth > 0
            if depth > 0 {
                log("[recall] Starting graph traversal, depth=\(depth)")
                sessionLog("[recall] Starting graph traversal, depth=\(depth)")
                let recalledGlobalIds = Set(filtered.compactMap { $0.object.globalId })
                // Filter during traversal so filtered-out nodes don't propagate to deeper depths.
                // Structural edges (part_of, derived_from, supersedes) always pass through.
                // Loose edges (relates_to, contradicts) require semantic proximity to the query.
                let queryVec = Vector<Float>(queryEmbedding)
                let structuralRelations: Set<Edge.Relation> = [.partOf, .derivedFrom, .supersedes, .summarizedBy]
                // Value-captured so the filter closure doesn't reference
                // actor state.
                let dropForeign = excludeForeignAuthored
                let traversalSelfId = currentUserId
                let traversed = traverseGraph(
                    from: recalledGlobalIds,
                    depth: depth,
                    excludeGlobalIds: recalledGlobalIds,
                    db: db,
                    filter: { mem, connectingEdge in
                        // Foreign exclusion applies to traversal too — the
                        // Connected section injects content just like the
                        // direct results do.
                        if dropForeign, let author = mem.authorUserId,
                           author != traversalSelfId { return false }
                        // The connecting edge is the specific edge that reached this memory
                        if structuralRelations.contains(connectingEdge.relation) { return true }
                        // Loose edges: filter by cosine distance to query.
                        // Bind the embedding ONCE — each read used to be its
                        // own full 384-float BLOB SELECT per candidate.
                        let emb = mem.embedding
                        guard emb.dimensions > 0 else { return false }
                        return Double(emb.cosineDistance(to: queryVec)) <= 0.55  // v2: query-relevance envelope (L2 ≈ 1.05)
                    }
                )
                // The in-traversal filter is @Sendable and can't consult
                // residency, so nil-author spoke rows slip through it. Re-run
                // the exclusion here, back inside the actor, where
                // isForeignAuthored sees the whole picture.
                let connected = dropForeign
                    ? traversed.filter { !isForeignAuthored($0.memory) }
                    : traversed
                log("[recall] Graph traversal returned \(connected.count) connected memories")
                sessionLog("[recall] Graph traversal returned \(connected.count) connected")
                if !connected.isEmpty {
                    output += "\n\n--- Connected (graph traversal, depth: \(depth)) ---"
                    // Same spoke-resident exclusion as the direct results:
                    // a bump on a group row is a write to every member.
                    bumpTargets.append(contentsOf: connected.map(\.memory).filter { m in
                        guard !groupSpokes.isEmpty else { return true }
                        guard let gid = m.globalId else { return false }
                        return isHubResident(gid)
                    })
                    for mem in connected {
                        let m = mem.memory
                        guard let memGlobalId = m.globalId else { continue }
                        recalledHits.append(RecallHit(memory: record(from: m),
                                                        distance: 0,
                                                        depth: mem.depth,
                                                        isForeign: isForeignAuthored(m)))

                        let expires = m.expiresAt == .distantFuture ? "" : ", expires: \(Self.dateFormatter.string(from: m.expiresAt))"

                        // Use the connecting edge directly from traversal
                        let edge = mem.connectingEdge
                        let edgeInfo: String
                        if edge.targetGlobalId == memGlobalId {
                            edgeInfo = " <--[\(edge.relation.rawValue)]-- [id:\(edge.sourceGlobalId.uuidString)]"
                        } else {
                            edgeInfo = " --[\(edge.relation.rawValue)]--> [id:\(edge.targetGlobalId.uuidString)]"
                        }

                        let connBadge = isForeignAuthored(m)
                            ? " [by:\(GroupDirectory.badgeName(for: m.authorUserId))]" : ""
                        let connVia = viaMarker(for: memGlobalId)
                        // Small memories shown in full; large ones get a compact preview
                        output += "\n\n"
                        Self.appendRecallRowMarker(memGlobalId, to: &output, rows: &renderedRows)
                        if isForeignAuthored(m) && fenceForeignContent {
                            output += "[\(m.project)/\(m.topic)]\(connBadge)\(connVia)\(expires)\(edgeInfo) \(Self.fencedForeignContent(m.content))"
                        } else if m.content.count <= 500 {
                            output += "[\(m.project)/\(m.topic)]\(connBadge)\(connVia)\(expires)\(edgeInfo) \(m.content)"
                        } else {
                            let firstLine = m.content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? m.content
                            let preview = String(firstLine.prefix(120))
                            let charCount = m.content.count
                            let sectionCount = m.content.components(separatedBy: "\n").filter { $0.hasPrefix("## ") || $0.hasPrefix("### ") }.count
                            let sizeInfo = sectionCount > 0 ? "\(sectionCount) sections, \(charCount) chars" : "\(charCount) chars"
                            output += "[\(m.project)/\(m.topic)]\(connBadge)\(connVia) (\(sizeInfo)\(expires))\(edgeInfo) \(preview)\(charCount > 120 ? "..." : "")"
                        }
                    }
                }
            }

            // Access-stat bumps: best-effort ranking metadata, batched into
            // ONE transaction on `db` — the handle the recalled objects
            // actually belong to (for synced projects that's the attaching
            // lattice; a localLattice txn silently wrapped nothing).
            // `increment` is a SQL-side atomic `SET c = c + 1` (no
            // read-modify-write race, no stale-snapshot hazard). Non-fatal:
            // a busy synced DB must not throw away a composed recall result.
            sessionLog("[recall] Bumping access stats (\(bumpTargets.count) memories)")
            let accessNow = Date()
            do {
                try db.withTransaction {
                    for m in bumpTargets {
                        m.lastAccessedAt = accessNow
                        m.increment("accessCount")
                    }
                }
            } catch {
                log("[recall] access-stat bump skipped: \(error)")
                sessionLog("[recall] access-stat bump skipped (non-fatal)")
            }

            log("[recall] DONE, returning \(output.count) chars")
            sessionLog("[recall] DONE, returning \(output.count) chars")
            return CallTool.Result(content: [.text(output)], isError: false)
        } else {
            recalledMode = .fullText
            log("[recall] No embedding available, falling back to FTS5")
            // Degraded mode: FTS5 full-text search (no embedding model loaded)
            let contentWords = Self.extractContentWords(from: query)
            let ftsTerms = contentWords.isEmpty ? query.split(separator: " ").map(String.init) : contentWords
            let ftsQuery: TextQuery = ._anyOf(ftsTerms)
            if let projectFilter {
                // IN-list over every local name that maps to the same group
                // project, so the degraded path scopes the same way the
                // vector path boosts.
                let names = Array(resolveQueryProjects(projectFilter)) + ["global"]
                results = results.where { $0.project.in(names) }
            }
            // Exclusion BEFORE the limit (verification finding): otherwise
            // foreign rows consume limit slots and then get dropped in the
            // render loop, under-filling — or emptying — the result set
            // while the user's own matches sit just past the cap.
            if excludeForeignAuthored {
                let me = currentUserId
                results = results.where { $0.authorUserId == nil || $0.authorUserId == me }
            }
            let ftsResults = results.matching(ftsQuery, on: \.content, limit: limit)

            var output = ""
            for match in ftsResults {
                let m = match.object
                m.materialize()  // hydrated by the FTS query — format for free
                let isForeign = isForeignAuthored(m)
                if excludeForeignAuthored && isForeign { continue }
                let ftsInfo = match.distances["content"].map { " (fts5: \(String(format: "%.3f", $0)))" } ?? ""
                let expires = m.expiresAt == .distantFuture ? "" : ", expires: \(Self.dateFormatter.string(from: m.expiresAt))"
                let created = hasTemporalFilter ? ", created: \(Self.dateFormatter.string(from: m.createdAt))" : ""
                guard let mGid = m.globalId else { continue }
                recalledHits.append(RecallHit(memory: record(from: m),
                                                distance: 0,
                                                depth: 0,
                                                isForeign: isForeign))
                let badge = isForeign
                    ? " [by:\(GroupDirectory.badgeName(for: m.authorUserId))]" : ""
                let via = viaMarker(for: mGid)
                let body = (isForeign && fenceForeignContent)
                    ? Self.fencedForeignContent(m.content) : m.content
                if !output.isEmpty { output += "\n\n" }
                Self.appendRecallRowMarker(mGid, to: &output, rows: &renderedRows)
                output += "[\(m.project)/\(m.topic)]\(badge)\(via)\(ftsInfo)\(expires)\(created) \(body)"
            }
            if output.isEmpty {
                return CallTool.Result(content: [.text("No memories found.")], isError: false)
            }
            return CallTool.Result(content: [.text(output)], isError: false)
        }
    }

    // MARK: - forget

    /// Per-row forget partition (decisions 4/9): group-shared rows are
    /// TOMBSTONED (soft delete — a hard delete would LWW-replicate to every
    /// member; tombstones are recoverable and converge everywhere), while
    /// never-shared rows keep the hard delete + edge cascade.
    private func forgetPartitioned(
        _ memories: [(memory: Memory, lattice: Lattice)]
    ) -> (tombstoned: Int, deleted: Int, edgesRemoved: Int) {
        var tombstoned = 0
        var hardDeleteGids: [UUID] = []
        var hardDeleteByLattice: [(lattice: Lattice, gid: UUID)] = []

        for entry in memories {
            let mem = entry.memory
            let lattice = entry.lattice
            guard let gid = mem.globalId else { continue }
            if isGroupShared(mem) {
                tombstone(mem, in: lattice)
                tombstoneEdgesForMemories([gid])
                tombstoned += 1
            } else {
                hardDeleteGids.append(gid)
                hardDeleteByLattice.append((lattice, gid))
            }
        }
        let edgesRemoved = deleteEdgesForMemories(hardDeleteGids)
        for (lattice, gid) in hardDeleteByLattice {
            lattice.delete(Memory.self, where: { $0.globalId == gid })
        }
        return (tombstoned, hardDeleteByLattice.count, edgesRemoved)
    }

    private func forgetResultNote(tombstoned: Int, deleted: Int, edgesRemoved: Int) -> String {
        var parts: [String] = []
        if deleted > 0 { parts.append("\(deleted) deleted") }
        if tombstoned > 0 {
            parts.append("\(tombstoned) group-shared → tombstoned (hidden for all members, recoverable via update with undelete: true)")
        }
        if edgesRemoved > 0 { parts.append("\(edgesRemoved) edge(s) removed") }
        return parts.joined(separator: "; ")
    }

    func handleForget(_ args: [String: Value]?) throws -> CallTool.Result {
        let a = try args.decode(ForgetArgs.self)

        // Delete by UUID takes priority
        if let gid = a.id?.value {
            guard let (mem, foundLattice) = findMemory(id: gid) else {
                return CallTool.Result(content: [.text("Memory with id \(gid.uuidString) not found.")], isError: true)
            }
            let summary = mem.content.prefix(80)
            let project = mem.project
            let topic = mem.topic

            if isGroupShared(mem) {
                tombstone(mem, in: foundLattice)
                let edgeCount = tombstoneEdgesForMemories([gid])
                let edgeNote = edgeCount > 0 ? " Tombstoned \(edgeCount) edge(s)." : ""
                log("Tombstoned group-shared memory [id:\(gid.uuidString)]: \(summary)")
                return CallTool.Result(
                    content: [.text("Removed memory (id: \(gid.uuidString), project: \(project), topic: \(topic)): \(summary)\nThis memory is shared with a group — it is tombstoned (hidden for all members, attributed to you) rather than hard-deleted. Restore with update(id:, undelete: true).\(edgeNote)")],
                    isError: false
                )
            }

            // Never-shared: hard delete + edge cascade (unchanged semantics).
            let edgeCount = deleteEdgesForMemories([gid])
            foundLattice.delete(Memory.self, where: { $0.globalId == gid })
            let edgeNote = edgeCount > 0 ? " Removed \(edgeCount) edge(s)." : ""
            log("Deleted memory [id:\(gid.uuidString)]: \(summary)")
            return CallTool.Result(
                content: [.text("Deleted memory (id: \(gid.uuidString), project: \(project), topic: \(topic)): \(summary)\(edgeNote)")],
                isError: false
            )
        }

        // Bulk paths: iterate a snapshot and partition per row — a blanket
        // db.delete over the union would emit hard DELETEs for group-shared
        // rows (exactly the propagation the tombstone design exists to stop).
        switch (a.topic, a.project) {
        case let (topic?, project?):
            let db = readLattice(for: project)
            let memories = db.objects(Memory.self)
                .where { $0.topic == topic && $0.project == project && $0.deletedAt == nil }
                .distinct(by: \.globalId).snapshot()
            let r = forgetPartitioned(memories.map { (memory: $0, lattice: db) })
            return CallTool.Result(
                content: [.text("Removed \(memories.count) memories (project: \(project), topic: \(topic)). \(forgetResultNote(tombstoned: r.tombstoned, deleted: r.deleted, edgesRemoved: r.edgesRemoved))")],
                isError: false
            )
        case let (topic?, nil):
            // No project → localLattice only (rows there can still be
            // group-shared via their project's exposure — partition anyway).
            let memories = localLattice.objects(Memory.self)
                .where { $0.topic == topic && $0.deletedAt == nil }.snapshot()
            let r = forgetPartitioned(memories.map { (memory: $0, lattice: localLattice) })
            return CallTool.Result(
                content: [.text("Removed \(memories.count) memories with topic '\(topic)'. \(forgetResultNote(tombstoned: r.tombstoned, deleted: r.deleted, edgesRemoved: r.edgesRemoved))")],
                isError: false
            )
        case let (nil, project?):
            let db = readLattice(for: project)
            let memories = db.objects(Memory.self)
                .where { $0.project == project && $0.deletedAt == nil }
                .distinct(by: \.globalId).snapshot()
            let r = forgetPartitioned(memories.map { (memory: $0, lattice: db) })
            return CallTool.Result(
                content: [.text("Removed \(memories.count) memories for project '\(project)'. \(forgetResultNote(tombstoned: r.tombstoned, deleted: r.deleted, edgesRemoved: r.edgesRemoved))")],
                isError: false
            )
        case (nil, nil):
            throw MCPError.invalidParams("Specify 'id', 'topic', or 'project'. Refusing to delete all memories without an explicit filter.")
        }
    }

    // MARK: - update

    func handleUpdate(_ args: [String: Value]?) async throws -> CallTool.Result {
        let a = try args.decode(UpdateArgs.self)

        // 1. Validate targeting — at least id or query required
        guard a.id != nil || (a.query != nil && !a.query!.isEmpty) else {
            throw MCPError.invalidParams("Provide 'id' or 'query' to target a memory.")
        }

        // 2. Validate at least one edit field
        let hasContentEdit = a.content != nil || a.append != nil || a.prepend != nil || a.find != nil
        let hasMetadataEdit = a.setProject != nil || a.topic != nil || a.source != nil || a.expiresInDays != nil || a.importance != nil || a.isPrivate != nil || a.undelete == true
        guard hasContentEdit || hasMetadataEdit else {
            throw MCPError.invalidParams("Provide at least one edit: content, append, prepend, find+replace, set_project, topic, source, expires_in_days, or undelete.")
        }

        // 3. Validate content edit modes are mutually exclusive
        let contentModes = [a.content != nil, a.append != nil, a.prepend != nil, a.find != nil]
        if contentModes.filter({ $0 }).count > 1 {
            throw MCPError.invalidParams("Content edit modes are mutually exclusive: use only one of content, append, prepend, or find+replace.")
        }

        // 4. find requires replace (replace can be empty string)
        if a.find != nil && a.replace == nil {
            throw MCPError.invalidParams("'find' requires 'replace' (can be empty string to delete matched text).")
        }

        // 5. Locate memory
        let mem: Memory
        let writeLattice: Lattice
        if let gid = a.id?.value {
            guard let found = findMemory(id: gid) else {
                return CallTool.Result(content: [.text("Memory with id \(gid.uuidString) not found.")], isError: true)
            }
            mem = found.memory
            writeLattice = found.lattice
        } else {
            let query = a.query!
            let db = readLattice(for: a.project)
            var results = db.objects(Memory.self).distinct(by: \.globalId).where { $0.deletedAt == nil }
            if let projectFilter = a.project {
                results = results.where { $0.project == projectFilter }
            }
            guard let queryEmbedding = try await embedder.embed(text: query) else {
                throw MCPError.internalError("Failed to generate embedding for query")
            }
            let nearest = results
                .nearest(to: Vector<Float>(queryEmbedding), on: \.embedding, limit: 1, distance: .l2)
            guard let match = nearest.first else {
                return CallTool.Result(content: [.text("No matching memory found to update.")], isError: false)
            }
            mem = match.object
            // Keep the connection that hydrated the selected row. A union
            // query can return an attached-store row whose setters must be
            // covered by this same connection's checked transaction.
            writeLattice = db
        }

        // 5b. Tombstone gate: a soft-deleted memory only accepts undelete —
        // otherwise its author gets zero signal that edits are landing on an
        // invisible row (e.g. an offline edit arriving after a teammate's
        // tombstone).
        if mem.deletedAt != nil && a.undelete != true {
            let by = GroupDirectory.badgeName(for: mem.deletedBy)
            let when = mem.deletedAt.map { Self.dateFormatter.string(from: $0) } ?? "?"
            return CallTool.Result(
                content: [.text("Memory \(mem.globalId?.uuidString ?? "?") is tombstoned by \(by) on \(when) — restore it first with update(id:, undelete: true).")],
                isError: true
            )
        }

        // 5c. `is_private` flips are AUTHOR-ONLY (decision 12): flipping it
        // on a group-shared row hard-retracts THAT AUTHOR's memory from the
        // group DB (row-level filter unmatch emits a real DELETE, removing
        // the group's copy including teammates' edits). Only its author may
        // trigger that.
        if a.isPrivate != nil, let author = mem.authorUserId,
           author != currentUserId {
            return CallTool.Result(
                content: [.text("is_private is author-only: this memory was written by \(GroupDirectory.badgeName(for: author)), and flipping privacy retracts THEIR memory from the group. Use forget (tombstone) or connect(contradicts) instead.")],
                isError: true
            )
        }

        // 6. Apply content edits + metadata in a single transaction
        let oldContent = mem.content
        var contentChanged = false
        var didUndelete = false
        var changes: [String] = []

        // Pre-compute embedding if content will change
        var newEmbedding: [Float]? = nil
        if let content = a.content {
            newEmbedding = try await embedder.embed(text: content)
        } else if a.append != nil || a.prepend != nil {
            let projected = a.append.map { oldContent + "\n" + $0 } ?? a.prepend.map { $0 + "\n" + oldContent }
            if let projected { newEmbedding = try await embedder.embed(text: projected) }
        } else if let find = a.find {
            let replace = a.replace!
            guard mem.content.contains(find) else {
                return CallTool.Result(
                    content: [.text("Find pattern not found in memory content.\nPattern: \(find)\nContent: \(mem.content)")],
                    isError: true
                )
            }
            newEmbedding = try await embedder.embed(text: oldContent.replacingOccurrences(of: find, with: replace))
        }

        if let imp = a.importance?.value {
            guard (0...5).contains(imp) else {
                throw MCPError.invalidParams("'importance' must be between 0 and 5, got \(imp)")
            }
        }

        var transactionBodyEntered = false
        do {
            try writeLattice.withTransaction {
                transactionBodyEntered = true
                if let content = a.content {
                    mem.content = content
                    contentChanged = true
                } else if let append = a.append {
                    mem.content += "\n" + append
                    contentChanged = true
                } else if let prepend = a.prepend {
                    mem.content = prepend + "\n" + mem.content
                    contentChanged = true
                } else if let find = a.find {
                    let replace = a.replace!
                    mem.content = mem.content.replacingOccurrences(of: find, with: replace)
                    contentChanged = true
                }

                if contentChanged {
                    changes.append("content: \(oldContent.prefix(60))... → \(mem.content.prefix(60))...")
                }

                if let project = a.setProject {
                    let old = mem.project
                    mem.project = project
                    changes.append("project: \(old) → \(project)")
                }
                if let topic = a.topic {
                    let old = mem.topic
                    mem.topic = topic
                    changes.append("topic: \(old) → \(topic)")
                }
                if let source = a.source {
                    let old = mem.source
                    mem.source = source
                    changes.append("source: \(old) → \(source)")
                }
                if let days = a.expiresInDays?.value {
                    let oldExpires = mem.expiresAt == .distantFuture ? "permanent" : Self.dateFormatter.string(from: mem.expiresAt)
                    if days == 0 {
                        mem.expiresAt = .distantFuture
                        changes.append("expires: \(oldExpires) → permanent")
                    } else {
                        mem.expiresAt = Date().addingTimeInterval(Double(days) * 86400)
                        changes.append("expires: \(oldExpires) → \(Self.dateFormatter.string(from: mem.expiresAt))")
                    }
                }
                if let imp = a.importance?.value {
                    let old = mem.importance
                    mem.importance = imp
                    changes.append("importance: \(old) → \(imp)")
                }
                if let priv = a.isPrivate {
                    let old = mem.isPrivate
                    mem.isPrivate = priv
                    changes.append("private: \(old) → \(priv)")
                    if priv && !old && isGroupShared(mem) {
                        changes.append("⚠️ retracted from the group: the group's copy (including any teammate edits) is removed for all members")
                    }
                }
                if a.undelete == true, mem.deletedAt != nil {
                    mem.deletedAt = nil
                    mem.deletedBy = nil
                    didUndelete = true
                    changes.append("undeleted (restored for all members)")
                }

                if contentChanged, let emb = newEmbedding {
                    mem.embedding = Vector<Float>(emb)
                }

                mem.lastAccessedAt = Date()
                // authorUserId is NEVER touched by edits — attribution follows
                // the original author, and the sync firewall keys on it.
                mem.modifiedAt = Date()
            }
        } catch {
            // Only a failed BEGIN proves that this attempt wrote nothing.
            // Setter, COMMIT, rollback and notification failures retain an
            // unknown outcome; never turn those into a safe-retry receipt.
            guard !transactionBodyEntered,
                  case LatticeError.transactionError(let detail) = error,
                  ["database is locked", "database is busy", "database table is locked",
                   "database schema is locked"].contains(where: {
                      detail == "Failed to begin transaction: " + $0
                  }) else { throw error }
            return CallTool.Result(
                content: [.text("Memory was not updated: the database was busy before the write transaction started. Retry on a later turn.")],
                structuredContent: .object([
                    "engram_write_receipt": .object([
                        "schema_version": .int(1),
                        "tool": .string("update"),
                        "write_outcome": .string("not_stored_transaction_not_started"),
                        "reason": .string("database_busy"),
                        "memory_ids": .array([]),
                    ]),
                ]),
                isError: true
            )
        }

        // Restore graph connectivity alongside the memory: edges tombstoned
        // with it revive when their other endpoint is live (edges into
        // still-removed content stay tombstoned).
        // (didUndelete, not a mem.deletedAt re-read — the materialized
        // snapshot can serve the stale pre-transaction value.)
        if didUndelete, let gid = mem.globalId {
            // The memory is already committed. A later graph failure must
            // propagate as an uncertain partial outcome, never as no write.
            let revived = try reviveEdgesForMemory(gid)
            if revived > 0 { changes.append("revived \(revived) edge(s)") }
        }

        let memGidStr = mem.globalId?.uuidString ?? "unknown"
        // Foreign-authored (group) rows: say so — the model should know it
        // just edited shared state written by someone else.
        var foreignNote = ""
        if let author = mem.authorUserId, author != currentUserId {
            foreignNote = "\nNote: this memory is group-shared, originally by \(GroupDirectory.badgeName(for: author)) — your edit syncs to all members. Prefer connect(relation: \"contradicts\") over destructive edits when you merely disagree."
        }
        log("Updated memory [id:\(memGidStr)] [\(mem.project)/\(mem.topic)]: \(changes.joined(separator: ", "))")
        return CallTool.Result(
            content: [.text("Updated memory (id: \(memGidStr), project: \(mem.project), topic: \(mem.topic)).\nChanges:\n\(changes.joined(separator: "\n"))\(foreignNote)")],
            isError: false
        )
    }

    // MARK: - merge

    func handleMerge(_ args: [String: Value]?) async throws -> CallTool.Result {
        let a = try args.decode(MergeArgs.self)
        guard !a.content.isEmpty else {
            throw MCPError.invalidParams("'content' is required")
        }
        let gids = a.ids.values
        guard gids.count >= 2 else {
            throw MCPError.invalidParams("'ids' must contain at least 2 memory IDs to merge")
        }
        let content = a.content

        // Fetch the source memories (may span both DBs)
        var sources: [(memory: Memory, lattice: Lattice)] = []
        for gid in gids {
            guard let found = findMemory(id: gid) else {
                return CallTool.Result(content: [.text("Memory with id \(gid.uuidString) not found.")], isError: true)
            }
            sources.append(found)
        }

        // Tombstoned sources are refused (like consolidate): merging one
        // would bake removed content into a fresh live row (a tombstone
        // bypass) and clobber the original tombstone attribution.
        if let dead = sources.first(where: { $0.memory.deletedAt != nil }) {
            let gidStr = dead.memory.globalId?.uuidString ?? "?"
            return CallTool.Result(
                content: [.text("Memory \(gidStr) is tombstoned (by \(GroupDirectory.badgeName(for: dead.memory.deletedBy))) — undelete it first or drop it from the merge.")],
                isError: true
            )
        }

        // Use first source for defaults
        let topic = a.topic ?? sources[0].memory.topic
        let project = a.project ?? sources[0].memory.project

        // Embed the merged content
        guard let floats = try await embedder.embed(text: content) else {
            throw MCPError.internalError("Embedding model unavailable — cannot merge memories without a vector. Check that the CoreML model is bundled correctly.")
        }
        let embeddingVec = Vector<Float>(floats)

        // Create merged memory, clean up edges, remove originals — all in one
        // transaction. Group-shared and FOREIGN-AUTHORED sources are
        // TOMBSTONED (never hard-deleted): a hard delete would replicate to
        // every member, and destroying a teammate's original is not merge's
        // call to make. The merged summary is authored by the runner.
        let merged = Memory(content: content, topic: topic, project: project, source: "merged", embedding: embeddingVec, authorUserId: currentUserId, modifiedAt: Date())
        let oldSummaries = sources.map { "[id:\($0.memory.globalId?.uuidString ?? "?")] \($0.memory.content.prefix(60))" }

        var mergedGid: UUID!
        var hardDeleted = 0
        var tombstonedCount = 0
        var edgeCount = 0
        let selfId = currentUserId
        try localLattice.transaction {
            try localLattice.add(merged)

            guard let gid = merged.globalId else {
                throw MCPError.internalError("Failed to persist merged memory — globalId is nil after add()")
            }
            mergedGid = gid

            for source in sources {
                guard let gid = source.memory.globalId else { continue }
                let foreign = source.memory.authorUserId != nil && source.memory.authorUserId != selfId
                if foreign || isGroupShared(source.memory) {
                    source.memory.deletedAt = Date()
                    source.memory.deletedBy = selfId
                    source.memory.modifiedAt = Date()
                    edgeCount += tombstoneEdgesForMemories([gid])
                    tombstonedCount += 1
                } else {
                    edgeCount += deleteEdgesForMemories([gid])
                    source.lattice.delete(Memory.self, where: { $0.globalId == gid })
                    hardDeleted += 1
                }
            }
        }

        var notes: [String] = []
        if hardDeleted > 0 { notes.append("\(hardDeleted) source(s) deleted") }
        if tombstonedCount > 0 { notes.append("\(tombstonedCount) group-shared/foreign source(s) tombstoned (recoverable)") }
        if edgeCount > 0 { notes.append("\(edgeCount) edge(s) removed") }
        log("Merged \(gids.count) memories into [id:\(mergedGid.uuidString)]")
        return CallTool.Result(
            content: [.text("Merged \(gids.count) memories into new memory (id: \(mergedGid.uuidString), project: \(project), topic: \(topic)). \(notes.joined(separator: "; ")).\n\nSources:\n\(oldSummaries.joined(separator: "\n"))\n\nNew:\n\(content)")],
            isError: false
        )
    }

    // MARK: - stats

    func handleStats(_ args: [String: Value]?) throws -> CallTool.Result {
        let a = try args.decode(StatsArgs.self)
        let projectFilter = a.project
        let db = readLattice(for: projectFilter)

        // decision 13: a project rollup must count teammates' rows for the
        // SAME canonical group project even when their local folder name
        // differs — resolve through the GroupProjectMap like recall does.
        let resolvedProjects = projectFilter.map { resolveQueryProjects($0).sorted() }

        var base = db.objects(Memory.self).distinct(by: \.globalId).where { $0.deletedAt == nil }  // tombstone filter
        if let resolvedProjects {
            base = base.where { $0.project.in(resolvedProjects) }
        }
        // Maintenance/opt-out guard: even counts and topic/project NAMES of
        // foreign rows stay invisible (a hostile topic string is a short
        // injection surface).
        let me = currentUserId
        if excludeForeignAuthored {
            base = base.where { $0.authorUserId == nil || $0.authorUserId == me }
        }

        let total = base.count
        if total == 0 {
            return CallTool.Result(content: [.text("No memories stored.")], isError: false)
        }

        var lines: [String] = []
        lines.append("Total memories: \(total)")

        // Per-project breakdown
        if projectFilter == nil {
            lines.append("\nBy project:")
            let grouped = base.group(by: \.project)
            var projectLines: [String] = []
            for mem in grouped {
                var countQuery = db.objects(Memory.self).distinct(by: \.globalId).where { $0.project == mem.project && $0.deletedAt == nil }
                if excludeForeignAuthored {
                    countQuery = countQuery.where { $0.authorUserId == nil || $0.authorUserId == me }
                }
                projectLines.append("  \(mem.project): \(countQuery.count)")
            }
            projectLines.sort()
            lines.append(contentsOf: projectLines)
        }

        // Per-topic breakdown
        lines.append("\nBy topic:")
        let topicGrouped = base.group(by: \.topic)
        var topicLines: [String] = []
        for mem in topicGrouped {
            var countQuery = db.objects(Memory.self).distinct(by: \.globalId).where { $0.topic == mem.topic && $0.deletedAt == nil }
            if let resolvedProjects {
                countQuery = countQuery.where { $0.project.in(resolvedProjects) }
            }
            if excludeForeignAuthored {
                countQuery = countQuery.where { $0.authorUserId == nil || $0.authorUserId == me }
            }
            topicLines.append("  \(mem.topic): \(countQuery.count)")
        }
        topicLines.sort()
        lines.append(contentsOf: topicLines)

        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    // MARK: - vacuum

    struct VacuumStoreOutcome {
        let label: String
        let checkpoint: CheckpointResult
        let reindexedRows: Int64
        let vacuumSucceeded: Bool?
        let boundedCheckpointFrames: Int64

        var checkpointDescription: String {
            if checkpoint.busy { return "busy" }
            if checkpoint.complete { return "complete" }
            if checkpoint.logFrames >= 0 && checkpoint.checkpointed >= 0 { return "partial" }
            return "failed"
        }

        var failed: Bool {
            checkpoint.busy || !checkpoint.complete || reindexedRows < 0
                || vacuumSucceeded == false || boundedCheckpointFrames < 0
        }

        var description: String {
            let initial = "initial checkpoint \(checkpointDescription) (\(checkpoint.checkpointed)/\(checkpoint.logFrames) frames)"
            let index = reindexedRows >= 0 ? "vector index rebuilt (\(reindexedRows) rows)" : "vector index rebuild failed"
            let vacuum = vacuumSucceeded.map { $0 ? "database VACUUM succeeded" : "database VACUUM failed" }
                ?? "database VACUUM not requested"
            let final = boundedCheckpointFrames >= 0
                ? "final bounded checkpoint processed \(boundedCheckpointFrames) frames"
                : "final bounded checkpoint busy or failed (no frame count available)"
            return "\(label): \(initial); \(index); \(vacuum); \(final)."
        }
    }

    func handleVacuum() throws -> CallTool.Result {
        // Checkpoint AFTER the VACUUM as well as before. SQLite's VACUUM
        // rewrites the entire database through the WAL, so a vacuum on an
        // 800MB database appends ~800MB of WAL — and without a trailing
        // checkpoint it STAYS there, making every subsequent read pay the
        // O(WAL) page-lookup penalty. Measured: repeat `vacuum` calls grew
        // a freshly repaired hub's WAL to 5.77GB, undoing the repair's
        // benefit. Bounded variant on the trailing call: other readers
        // (hooks, the visualizer) may hold snapshots, and a 30s writer-gate
        // stall inside an MCP tool call is worse than a large-but-shrinking
        // WAL.
        func maintain(_ db: Lattice, label: String, compact: Bool) -> VacuumStoreOutcome {
            let checkpoint = db.checkpoint()
            let rows = db._vacuumVec0(Memory(), for: \.embedding)
            let vacuum: Bool? = compact ? db.vacuum() : nil
            let frames = db.checkpointBounded()
            return VacuumStoreOutcome(label: label, checkpoint: checkpoint, reindexedRows: rows,
                                      vacuumSucceeded: vacuum, boundedCheckpointFrames: frames)
        }
        var outcomes = [maintain(localLattice, label: "local", compact: true)]
        if let synced = syncedLattice {
            outcomes.append(maintain(synced, label: "synced", compact: true))
        }
        // Group spokes too (increment-4 contract): a spoke populated purely
        // by sync-apply has NO vec sidecar — the apply path inserts rows
        // without indexing them, and recall's multi-arm KNN silently skips
        // arms with no vec table. Checkpoint + index rebuild only; never
        // tombstone GC (that's server/admin-owned).
        var spokeCount = 0
        for spoke in liveGroupSpokes() {
            let outcome = maintain(spoke.lattice, label: "group \(spoke.groupId.uuidString)", compact: false)
            outcomes.append(outcome)
            if outcome.reindexedRows >= 0 { spokeCount += 1 }
        }
        let spokeNote = spokeCount > 0 ? " \(spokeCount) group spoke(s) reindexed." : ""
        let failed = outcomes.contains { $0.failed }
        let heading = failed ? "Vacuum incomplete." : "Vacuum maintenance finished."
        // checkpointBounded can fall back to PASSIVE. Its frame count does
        // not prove that every WAL frame was folded back or the WAL truncated.
        let text = ([heading + spokeNote] + outcomes.map(\.description)
                    + ["Final WAL truncation is not confirmed by bounded checkpoint frame counts."])
            .joined(separator: "\n")
        return CallTool.Result(content: [.text(text)], isError: failed)
    }

    // MARK: - train_vectors

    func handleTrainVectors() throws -> CallTool.Result {
        localLattice._vacuumVec0(Memory(), for: \.embedding)
        localLattice.checkpoint()
        let localCount = localLattice.objects(Memory.self).count
        var syncedCount = 0
        if let synced = syncedLattice {
            synced._vacuumVec0(Memory(), for: \.embedding)
            synced.checkpoint()
            syncedCount = synced.objects(Memory.self).count
        }
        var spokeTotal = 0
        for spoke in liveGroupSpokes() {
            spoke.lattice._vacuumVec0(Memory(), for: \.embedding)
            spoke.lattice.checkpoint()
            spokeTotal += spoke.lattice.objects(Memory.self).count
        }
        var parts = ["local: \(localCount)"]
        if syncedCount > 0 { parts.append("synced: \(syncedCount)") }
        if spokeTotal > 0 { parts.append("group spokes: \(spokeTotal)") }
        return CallTool.Result(content: [.text("Vector index trained (\(parts.joined(separator: ", "))).")], isError: false)
    }

    // MARK: - list_topics

    func handleListTopics(_ args: [String: Value]?) throws -> CallTool.Result {
        let a = try args.decode(ListTopicsArgs.self)
        let projectFilter = a.project
        let db = readLattice(for: projectFilter)

        // decision 13: resolve the filter through the group project map
        // (same contract as stats — teammates' local names count too).
        let resolvedProjects = projectFilter.map { resolveQueryProjects($0).sorted() }

        var base = db.objects(Memory.self).distinct(by: \.globalId).where { $0.deletedAt == nil }  // tombstone filter
        if let resolvedProjects {
            base = base.where { $0.project.in(resolvedProjects) }
        }
        let me = currentUserId
        if excludeForeignAuthored {
            base = base.where { $0.authorUserId == nil || $0.authorUserId == me }
        }

        let grouped = base.group(by: \.topic)
        if grouped.endIndex == 0 {
            return CallTool.Result(content: [.text("No memories stored.")], isError: false)
        }

        var lines: [String] = []
        for memory in grouped {
            var countQuery = db.objects(Memory.self).distinct(by: \.globalId).where { $0.topic == memory.topic && $0.deletedAt == nil }
            if let resolvedProjects {
                countQuery = countQuery.where { $0.project.in(resolvedProjects) }
            }
            if excludeForeignAuthored {
                countQuery = countQuery.where { $0.authorUserId == nil || $0.authorUserId == me }
            }
            let count = countQuery.count
            lines.append("\(memory.topic): \(count) memories")
        }
        lines.sort()

        let header = projectFilter.map { "Topics for project '\($0)':" } ?? "All topics:"
        return CallTool.Result(
            content: [.text(header + "\n" + lines.joined(separator: "\n"))],
            isError: false
        )
    }

    // MARK: - timeline

    func handleTimeline(_ args: [String: Value]?) throws -> CallTool.Result {
        let a = try args.decode(TimelineArgs.self)
        let groupBy = a.groupBy ?? "day"
        let limit = a.limit?.value ?? 50

        guard ["day", "week", "month"].contains(groupBy) else {
            throw MCPError.invalidParams("'group_by' must be 'day', 'week', or 'month', got '\(groupBy)'")
        }

        // Build query with filters — route to right DB based on project
        var results = readLattice(for: a.project).objects(Memory.self)
            .distinct(by: \.globalId)
            .where { $0.expiresAt > Date() && $0.deletedAt == nil }  // tombstone filter

        if excludeForeignAuthored {
            let me = currentUserId
            results = results.where { $0.authorUserId == nil || $0.authorUserId == me }
        }
        if let project = a.project {
            results = results.where { $0.project == project }
        }
        if let topic = a.topic {
            results = results.where { $0.topic == topic }
        }
        if let sinceStr = a.since {
            guard let sinceDate = parseTemporalDate(sinceStr) else {
                throw MCPError.invalidParams("Could not parse 'since' date: \(sinceStr)")
            }
            results = results.where { $0.createdAt >= sinceDate }
        }
        if let beforeStr = a.before {
            guard let beforeDate = parseTemporalDate(beforeStr) else {
                throw MCPError.invalidParams("Could not parse 'before' date: \(beforeStr)")
            }
            results = results.where { $0.createdAt <= beforeDate }
        }

        // Sort by createdAt descending in SQL, apply limit
        let limited = results
            .sortedBy(.init(\.createdAt, order: .reverse))
            .snapshot(limit: Int64(limit))

        if limited.isEmpty {
            return CallTool.Result(content: [.text("No memories found.")], isError: false)
        }

        // Group by calendar period
        let cal = Calendar.current
        var groups: [(key: Date, memories: [Memory])] = []
        var currentGroupDate: Date?
        var currentGroup: [Memory] = []

        for mem in limited {
            let periodStart: Date
            switch groupBy {
            case "week":
                periodStart = cal.dateInterval(of: .weekOfYear, for: mem.createdAt)?.start ?? cal.startOfDay(for: mem.createdAt)
            case "month":
                periodStart = cal.dateInterval(of: .month, for: mem.createdAt)?.start ?? cal.startOfDay(for: mem.createdAt)
            default: // "day"
                periodStart = cal.startOfDay(for: mem.createdAt)
            }

            if periodStart == currentGroupDate {
                currentGroup.append(mem)
            } else {
                if let key = currentGroupDate, !currentGroup.isEmpty {
                    groups.append((key: key, memories: currentGroup))
                }
                currentGroupDate = periodStart
                currentGroup = [mem]
            }
        }
        if let key = currentGroupDate, !currentGroup.isEmpty {
            groups.append((key: key, memories: currentGroup))
        }

        // Format output with date headers
        let headerFormatter = DateFormatter()
        switch groupBy {
        case "week":
            headerFormatter.dateFormat = "'Week of' MMM d, yyyy"
        case "month":
            headerFormatter.dateFormat = "MMMM yyyy"
        default:
            headerFormatter.dateFormat = "MMM d, yyyy"
        }

        var output = ""
        for (i, group) in groups.enumerated() {
            if i > 0 { output += "\n\n" }
            let countLabel = group.memories.count == 1 ? "1 memory" : "\(group.memories.count) memories"
            output += "## \(headerFormatter.string(from: group.key)) (\(countLabel))"
            for mem in group.memories {
                let impInfo = mem.importance > 0 ? " [importance: \(mem.importance)]" : ""
                let memGid = mem.globalId?.uuidString ?? "?"
                output += "\n[id:\(memGid)] [\(mem.project)/\(mem.topic)]\(impInfo) \(mem.content)"
            }
        }

        return CallTool.Result(content: [.text(output)], isError: false)
    }
}
