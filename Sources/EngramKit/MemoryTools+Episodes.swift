import Lattice
import MCP
import Foundation

// MARK: - Episodic Memory
//
// Episodes are hub memories (topic: "episode") with part_of edges linking
// member memories. This reuses the existing memory + knowledge graph
// infrastructure instead of a separate Episode model.

extension MemoryTools {

    // MARK: - begin_episode

    func handleBeginEpisode(_ args: [String: Value]?) async throws -> CallTool.Result {
        let a = try args.decode(BeginEpisodeArgs.self)
        let project = a.project ?? "global"
        let title = a.title ?? "Session: \(Self.isoDateFormatter.string(from: Date()))"

        // End any active episode first
        endActiveEpisode()

        let floats = try await embedder.embed(text: title)
        let embeddingVec = floats.map { Vector<Float>($0) } ?? Vector<Float>([])
        let episode = Memory(content: title, topic: "episode", project: project, embedding: embeddingVec)
        try localLattice.add(episode)

        guard let episodeGid = episode.globalId else {
            throw MCPError.internalError("Failed to persist episode memory — globalId is nil after add()")
        }
        activeEpisodeId = episodeGid
        lastMemoryTime = Date()

        log("Created episode [id:\(episodeGid.uuidString)] \(title)")
        return CallTool.Result(
            content: [.text("Created episode (id:\(episodeGid.uuidString), project: \(project)): \(title)")],
            isError: false
        )
    }

    // MARK: - end_episode

    func handleEndEpisode(_ args: [String: Value]?) throws -> CallTool.Result {
        let a = try args.decode(EndEpisodeArgs.self)

        let episode: Memory
        let episodeLattice: Lattice
        let epGid: UUID
        if let gid = a.episodeId?.value {
            guard let (found, owner) = findMemory(id: gid) else {
                return CallTool.Result(content: [.text("Episode with id \(gid.uuidString) not found.")], isError: true)
            }
            guard found.topic == "episode" else {
                return CallTool.Result(content: [.text("Memory \(gid.uuidString) is not an episode.")], isError: true)
            }
            episode = found
            episodeLattice = owner
            epGid = gid
        } else {
            guard let activeId = activeEpisodeId,
                  let (found, owner) = findMemory(id: activeId) else {
                throw MCPError.invalidParams("No active episode. Provide 'episode_id' or start one with begin_episode.")
            }
            episode = found
            episodeLattice = owner
            epGid = activeId
        }

        // Closing without a summary is session bookkeeping only. Keep it
        // usable even when removed members make a summary unsafe to publish.
        var summarizedMemberCount: Int?
        if let summary = a.summary, !summary.isEmpty {
            do {
                let sources = try episodeSummarySources(epGid)
                guard let captured = sources.targets.first(where: { $0.memory.globalId == epGid }),
                      captured.lattice.configuration.fileURL == episodeLattice.configuration.fileURL,
                      captured.memory.topic == "episode" else {
                    throw DerivationScopeError(message: "The episode changed while reading. Re-read it before summarizing.")
                }
                let initial = try derivationSnapshot(sources: sources, project: captured.memory.project, destinationLattice: episodeLattice)
                _ = try episodeSummaryPrivacy(episode: captured.memory, owner: episodeLattice, sources: sources)

                // Only the destination is write-locked. Other stores are
                // rechecked here, not atomically locked across processes.
                summarizedMemberCount = try LatticeBeginRetry.run(on: episodeLattice, log: { log("[end_episode] \($0)") }) {
                    let episodes = episodeLattice.objects(Memory.self).where({ $0.globalId == epGid }).snapshot(limit: 2)
                    guard episodeLattice.lastQueryError() == nil, episodes.count == 1,
                          let current = episodes.first?.materialize(),
                          current.topic == "episode" else {
                        throw DerivationScopeError(message: "The episode is missing or changed. Re-read it before summarizing.")
                    }
                    let sources = try episodeSummarySources(epGid)
                    let isPrivate = try episodeSummaryPrivacy(episode: current, owner: episodeLattice,
                                                             sources: sources, unchangedFrom: initial)
                    let policy = try derivationRestriction(sources: sources, project: current.project,
                                                          destinationLattice: episodeLattice, unchangedFrom: initial)
                    // These setters share the owning store's checked transaction:
                    // no summary text can commit before its privacy flag does.
                    if current.isPrivate != isPrivate { current.isPrivate = isPrivate }
                    current.derivationPolicy = policy.rawValue
                    current.content += "\n\nSummary: \(summary)"
                    current.modifiedAt = Date()
                    return Set(sources.targets.compactMap { $0.memory.globalId }).count - 1
                }.value
            } catch let refusal as DerivationScopeError {
                return refusal.result
            } catch let contention as LatticeBeginRetry.Contention {
                return Self.busyReceipt(tool: "end_episode", verb: "summarized", contention: contention)
            }
        }

        // Clear activeEpisodeId if it matches
        if activeEpisodeId == epGid {
            activeEpisodeId = nil
        }

        let memoryCount = summarizedMemberCount ?? countEpisodeMembers(epGid)
        let duration = episodeDuration(epGid, startedAt: episode.createdAt)

        log("Ended episode [id:\(epGid.uuidString)]")
        return CallTool.Result(
            content: [.text("Ended episode (id:\(epGid.uuidString)). Duration: \(duration), memories: \(memoryCount)\(a.summary.map { ", summary: \($0)" } ?? "")")],
            isError: false
        )
    }

    // MARK: - recall_episode

    func handleRecallEpisode(_ args: [String: Value]?) throws -> CallTool.Result {
        let a = try args.decode(RecallEpisodeArgs.self)
        let epGid = a.episodeId.value
        let limit = a.limit?.value ?? 200

        guard let (episode, episodeLattice) = findMemory(id: epGid) else {
            return CallTool.Result(content: [.text("Episode with id \(epGid.uuidString) not found.")], isError: true)
        }
        guard episode.topic == "episode" else {
            return CallTool.Result(content: [.text("Memory \(epGid.uuidString) is not an episode.")], isError: true)
        }
        // Maintenance/opt-out guard: a foreign episode is invisible, like a
        // missing one.
        if excludeForeignAuthored, isForeignAuthored(episode) {
            return CallTool.Result(content: [.text("Episode with id \(epGid.uuidString) not found.")], isError: true)
        }

        // Find memories linked via part_of edges to this episode
        let edges = episodeLattice.objects(Edge.self)
            .where { $0.targetGlobalId == epGid && $0.relation == .partOf }

        // Fetch and sort member memories chronologically
        let dropForeign = excludeForeignAuthored
        let me = currentUserId
        var members: [Memory] = []
        for edge in edges {
            if let mem = episodeLattice.objects(Memory.self).where({ $0.globalId == edge.sourceGlobalId && $0.topic != "episode" && $0.deletedAt == nil }).first {
                if dropForeign, let author = mem.authorUserId, author != me { continue }
                members.append(mem)
            }
        }
        members.sort { $0.createdAt < $1.createdAt }

        let totalCount = members.count
        let limited = Array(members.prefix(limit))

        let isActive = activeEpisodeId == epGid
        let duration = episodeDuration(epGid, startedAt: episode.createdAt)

        // Parse title and summary from episode content
        let parts = episode.content.components(separatedBy: "\n\nSummary: ")
        let title = parts[0]
        let summary = parts.count > 1 ? parts[1] : nil

        var output = "## Episode: \(title)\n"
        output += "**ID**: \(epGid.uuidString) | **Project**: \(episode.project) | **Status**: \(isActive ? "active" : "ended") | **Duration**: \(duration)"
        output += "\n**Started**: \(Self.dateFormatter.string(from: episode.createdAt))"

        if let summary {
            output += "\n\n### Summary\n\(summary)"
        }

        if limited.isEmpty {
            output += "\n\nNo memories in this episode."
        } else {
            let truncated = totalCount > limited.count
            let countLabel = truncated ? "\(limited.count) of \(totalCount)" : "\(totalCount)"
            output += "\n\n### Memories (\(countLabel))"

            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm:ss"

            for mem in limited {
                let time = timeFormatter.string(from: mem.createdAt)
                let memGid = mem.globalId?.uuidString ?? "?"
                output += "\n[id:\(memGid)] [\(time)] \(mem.content)"
            }

            if truncated {
                output += "\n\n(Showing \(limited.count) of \(totalCount) memories. Use limit parameter to see more.)"
            }
        }

        return CallTool.Result(content: [.text(output)], isError: false)
    }

    // MARK: - list_episodes

    func handleListEpisodes(_ args: [String: Value]?) throws -> CallTool.Result {
        let a = try args.decode(ListEpisodesArgs.self)
        let limit = a.limit?.value ?? 20

        let db = readLattice(for: a.project)
        var results = db.objects(Memory.self).distinct(by: \.globalId).where { $0.topic == "episode" && $0.deletedAt == nil }

        if excludeForeignAuthored {
            let me = currentUserId
            results = results.where { $0.authorUserId == nil || $0.authorUserId == me }
        }
        if let project = a.project {
            results = results.where { $0.project == project }
        }

        let sorted = results.sortedBy(.init(\.createdAt, order: .reverse))
        let limited = sorted.snapshot(limit: Int64(limit))

        if limited.isEmpty {
            return CallTool.Result(content: [.text("No episodes found.")], isError: false)
        }

        let lines = limited.compactMap { ep -> String? in
            guard let epGid = ep.globalId else { return nil }
            let memCount = countEpisodeMembers(epGid)
            let isActive = activeEpisodeId == epGid
            let startDate = Self.dateFormatter.string(from: ep.createdAt)

            // Parse title from content (before any summary)
            let title = ep.content.components(separatedBy: "\n\nSummary: ")[0]

            return "[id:\(epGid.uuidString)] [\(isActive ? "active" : "ended")] \(title) (\(ep.project), \(startDate), \(memCount) memories)"
        }

        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }

    // MARK: - Episode Helpers

    /// Include every reachable replica and membership edge, not just the
    /// episode's owning store or findMemory's first copy. A private/tombstoned
    /// replica must not be hidden by a public local copy. Removed links are a
    /// conservative refusal: a supplied summary cannot prove it omitted them.
    private func episodeSummarySources(_ episodeId: UUID) throws -> DerivationInputs {
        let stores = try derivationStores()
        var ids: Set<UUID> = [episodeId]
        for (_, store) in stores {
            let edges = store.objects(Edge.self).where({ $0.targetGlobalId == episodeId && $0.relation == .partOf }).snapshot(limit: 4097)
            guard store.lastQueryError() == nil, edges.count <= 4096 else {
                throw DerivationScopeError(message: "Could not read every episode member link within the derivation limit. Restore access or close without a summary.")
            }
            for edge in edges {
                edge.materialize()
                guard edge.deletedAt == nil else {
                    throw DerivationScopeError(message: "The episode contains a removed member link. Close without a summary or prepare a new episode from live sources.")
                }
                ids.insert(edge.sourceGlobalId)
            }
        }
        let inputs = try derivationSources(ids.sorted(by: { $0.uuidString < $1.uuidString }))
        guard inputs.stores == stores.map(\.binding) else {
            throw DerivationScopeError(message: "Episode store bindings changed while reading. Re-read it before summarizing.")
        }
        return inputs
    }

    private func episodeSummaryPrivacy(
        episode: Memory, owner: Lattice, sources: DerivationInputs,
        unchangedFrom initial: DerivationSnapshot? = nil
    ) throws -> Bool {
        let isPrivate = try derivationPrivacy(sources: sources, project: episode.project,
                                             destinationLattice: owner, unchangedFrom: initial)
        if isPrivate {
            // Group/personal cloud spokes are already remote destinations.
            // Marking their row private does not retract a raw spoke write.
            guard owner.configuration.fileURL.standardizedFileURL == localLattice.configuration.fileURL.standardizedFileURL else {
                throw DerivationScopeError(message: "Private-derived summaries cannot be written directly to a synced or group episode. Create a private local summary instead.")
            }
            if !episode.isPrivate, let author = episode.authorUserId, author != currentUserId {
                throw DerivationScopeError(message: "Making this episode private is author-only. Its author must make that change before a private summary can be appended.")
            }
        }
        return isPrivate
    }

    /// Clear the active episode state.
    func endActiveEpisode() {
        guard activeEpisodeId != nil else { return }
        log("Cleared active episode [id:\(activeEpisodeId!)]")
        activeEpisodeId = nil
    }

    /// Count memories linked to an episode via part_of edges.
    private func countEpisodeMembers(_ episodeGid: UUID) -> Int {
        // Check local first, then synced
        let localCount = localLattice.count(Edge.self, where: { $0.targetGlobalId == episodeGid && $0.relation == .partOf })
        if localCount > 0 { return localCount }
        if let syncedLattice {
            return syncedLattice.count(Edge.self, where: { $0.targetGlobalId == episodeGid && $0.relation == .partOf })
        }
        return 0
    }

    /// Compute episode duration from creation to latest member memory (or now if active).
    private func episodeDuration(_ episodeGid: UUID, startedAt: Date) -> String {
        if activeEpisodeId == episodeGid {
            return formatDuration(from: startedAt, to: Date())
        }
        // Find the lattice this episode lives in
        guard let (_, episodeLattice) = findMemory(id: episodeGid) else {
            return formatDuration(from: startedAt, to: startedAt)
        }
        let edges = episodeLattice.objects(Edge.self).where { $0.targetGlobalId == episodeGid && $0.relation == .partOf }
        var latest = startedAt
        for edge in edges {
            if let mem = episodeLattice.objects(Memory.self).where({ $0.globalId == edge.sourceGlobalId && $0.deletedAt == nil }).first {
                if mem.createdAt > latest { latest = mem.createdAt }
            }
        }
        return formatDuration(from: startedAt, to: latest)
    }

    /// Format a duration between two dates as a human-readable string.
    func formatDuration(from start: Date, to end: Date) -> String {
        let seconds = Int(end.timeIntervalSince(start))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return "\(hours)h \(remainingMinutes)m"
    }
}
