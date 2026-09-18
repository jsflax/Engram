import EngramMemoryCore
import Foundation
import MCP

// MARK: - The MemoryService conformance (increment 1b)
//
// MemoryTools IS the lattice conformance of the memory contract. The MCP
// stdio server and the FoundationModels tools keep calling the Value-typed
// handlers directly (byte-identical behavior); this surface is what the
// HTTP transport, the contract suite, and future embedders program against.
//
// Adapter strategy: typed requests translate to the existing handlers'
// Value arguments; structured results come from the actor-isolated capture
// properties handleRecall/handleRemember populate at their return sites
// (safe: no suspension between their final write and the read here).

extension MemoryTools: MemoryService {

    nonisolated public var principal: Principal { identity.currentPrincipal() }

    nonisolated public var capabilities: Set<MemoryCapability> {
        [.fileMaintenance, .episodes, .tasks, .clustering]
    }

    // MARK: Core reads

    public func recall(_ request: RecallRequest) async throws -> RecallResult {
        var args: [String: Value] = [
            "query": .string(request.query),
            "depth": .int(request.depth),
            "limit": .int(request.limit),
        ]
        if let project = request.project { args["project"] = .string(project) }
        let result = try await handleRecall(args)
        return RecallResult(hits: lastRecallHits,
                            mode: lastRecallMode,
                            renderedText: Self.text(from: result))
    }

    public func advise(_ request: AdviseRequest) async throws -> AdviseResult {
        // The hook pipeline, server-side: distill content words, recall,
        // wrap as the injection-ready section. Gate-less v1 — the server
        // runs once per agent event, not per keystroke-prompt; the
        // analytics loop is the tuner (plan §advise).
        let words = MemoryTools.extractContentWords(from: request.prompt)
        let query = words.isEmpty ? request.prompt : words.joined(separator: " ")
        let recallResult = try await recall(RecallRequest(
            query: query, project: request.project, depth: 1, limit: 5))
        guard !recallResult.hits.isEmpty,
              recallResult.renderedText != "No memories found." else {
            return AdviseResult(block: nil, memoryIds: [], mode: recallResult.mode)
        }
        var rendered = recallResult.renderedText
        if rendered.count > request.budget {
            rendered = String(rendered.prefix(request.budget)) + "\n… (truncated)"
        }
        return AdviseResult(
            block: AdviseAssembly.memorySection(renderedRecall: rendered, query: query),
            memoryIds: recallResult.hits.map(\.memory.id),
            mode: recallResult.mode)
    }

    public func graph(_ request: GraphRequest) async throws -> GraphResult {
        // Resolve BEFORE rendering: a missing/hard-deleted id is a typed
        // notFound, not whatever prose the handler renders for it.
        guard let (root, _) = findMemory(id: request.id) else {
            throw MemoryServiceError.notFound(request.id)
        }
        let result = try handleGraph([
            "id": .string(request.id.uuidString),
            "depth": .int(request.depth),
        ])
        // v1: rendered text + root record; typed node/edge sets firm up as
        // handleGraph is decomposed (the transport only needs the text).
        return GraphResult(root: record(from: root), nodes: [], edges: [],
                           renderedText: Self.text(from: result))
    }

    // MARK: Core writes

    public func remember(_ request: RememberRequest) async throws -> RememberResult {
        var args: [String: Value] = [
            "content": .string(request.content),
            "is_private": .bool(request.isPrivate),
        ]
        if let topic = request.topic { args["topic"] = .string(topic) }
        if let project = request.project { args["project"] = .string(project) }
        if let source = request.source { args["source"] = .string(source) }
        if let importance = request.importance { args["importance"] = .int(importance) }
        if let parent = request.parentId { args["parent_id"] = .string(parent.uuidString) }
        if let days = request.expiresInDays { args["expires_in_days"] = .int(days) }
        lastRememberedId = nil
        let result = try await handleRemember(args)
        guard let id = lastRememberedId else {
            // Conflict-warning path: the handler declined to store.
            throw MemoryServiceError.invalidArguments(Self.text(from: result))
        }
        return RememberResult(id: id, message: Self.text(from: result))
    }

    public func update(_ request: UpdateRequest) async throws -> ToolReply {
        var args: [String: Value] = ["id": .string(request.id.uuidString)]
        if let v = request.content { args["content"] = .string(v) }
        if let v = request.append { args["append"] = .string(v) }
        if let v = request.prepend { args["prepend"] = .string(v) }
        if let v = request.find { args["find"] = .string(v) }
        if let v = request.replace { args["replace"] = .string(v) }
        if let v = request.topic { args["topic"] = .string(v) }
        if let v = request.project { args["project"] = .string(v) }
        if let v = request.importance { args["importance"] = .int(v) }
        if let v = request.expiresInDays { args["expires_in_days"] = .int(v) }
        if let v = request.isPrivate { args["is_private"] = .bool(v) }
        if request.undelete { args["undelete"] = .bool(true) }
        return Self.reply(try await handleUpdate(args))
    }

    public func forget(_ request: ForgetRequest) async throws -> ToolReply {
        var args: [String: Value] = [:]
        if let id = request.id { args["id"] = .string(id.uuidString) }
        if let topic = request.topic { args["topic"] = .string(topic) }
        if let project = request.project { args["project"] = .string(project) }
        return Self.reply(try handleForget(args))
    }

    public func connect(_ request: ConnectRequest) async throws -> ToolReply {
        Self.reply(try handleConnect([
            "from": .string(request.sourceId.uuidString),
            "to": .string(request.targetId.uuidString),
            "relation": .string(request.relation),
        ]))
    }

    public func disconnect(_ request: ConnectRequest) async throws -> ToolReply {
        Self.reply(try handleDisconnect([
            "from": .string(request.sourceId.uuidString),
            "to": .string(request.targetId.uuidString),
            "relation": .string(request.relation),
        ]))
    }

    public func merge(ids: [UUID], content: String, topic: String?, project: String?) async throws -> ToolReply {
        var args: [String: Value] = [
            "ids": .array(ids.map { .string($0.uuidString) }),
            "content": .string(content),
        ]
        if let topic { args["topic"] = .string(topic) }
        if let project { args["project"] = .string(project) }
        return Self.reply(try await handleMerge(args))
    }

    // MARK: Rendered-text surface

    public func stats(project: String?) async throws -> ToolReply {
        Self.reply(try handleStats(project.map { ["project": .string($0)] }))
    }

    public func listTopics(project: String?) async throws -> ToolReply {
        Self.reply(try handleListTopics(project.map { ["project": .string($0)] }))
    }

    public func timeline(project: String?, groupBy: String?) async throws -> ToolReply {
        var args: [String: Value] = [:]
        if let project { args["project"] = .string(project) }
        if let groupBy { args["group_by"] = .string(groupBy) }
        return Self.reply(try handleTimeline(args.isEmpty ? nil : args))
    }

    public func beginEpisode(title: String, sessionKey: String?) async throws -> ToolReply {
        _ = sessionKey  // lattice conformance: one session per process (CLI)
        return Self.reply(try await handleBeginEpisode(["title": .string(title)]))
    }

    public func endEpisode(summary: String?, sessionKey: String?) async throws -> ToolReply {
        _ = sessionKey
        var args: [String: Value] = [:]
        if let summary { args["summary"] = .string(summary) }
        return Self.reply(try handleEndEpisode(args.isEmpty ? nil : args))
    }

    public func recallEpisode(id: UUID, limit: Int?) async throws -> ToolReply {
        var args: [String: Value] = ["episode_id": .string(id.uuidString)]
        if let limit { args["limit"] = .int(limit) }
        return Self.reply(try handleRecallEpisode(args))
    }

    public func listEpisodes(limit: Int?) async throws -> ToolReply {
        Self.reply(try handleListEpisodes(limit.map { ["limit": .int($0)] }))
    }

    public func checkpoint(title: String, sessionKey: String?) async throws -> ToolReply {
        _ = sessionKey
        return Self.reply(try handleCheckpoint(["title": .string(title)]))
    }

    public func resume(taskId: Int) async throws -> ToolReply {
        Self.reply(try handleResume(["task_id": .int(taskId)]))
    }

    public func listTasks() async throws -> ToolReply {
        Self.reply(try handleListTasks(nil))
    }

    public func findClusters(project: String?) async throws -> ToolReply {
        Self.reply(try await handleFindClusters(project.map { ["project": .string($0)] }))
    }

    public func detectCommunities(project: String) async throws -> ToolReply {
        Self.reply(try await handleDetectCommunities(["project": .string(project)]))
    }

    public func organize(ids: [UUID], label: String, project: String?, summary: String?) async throws -> ToolReply {
        var args: [String: Value] = [
            "ids": .array(ids.map { .string($0.uuidString) }),
            "label": .string(label),
        ]
        if let project { args["project"] = .string(project) }
        if let summary { args["summary"] = .string(summary) }
        return Self.reply(try await handleOrganize(args))
    }

    public func consolidate(ids: [UUID], content: String, topic: String?, project: String?, force: Bool) async throws -> ToolReply {
        var args: [String: Value] = [
            "ids": .array(ids.map { .string($0.uuidString) }),
            "content": .string(content),
        ]
        if let topic { args["topic"] = .string(topic) }
        if let project { args["project"] = .string(project) }
        if force { args["force"] = .bool(true) }
        return Self.reply(try await handleConsolidate(args))
    }

    public func vacuum() async throws -> ToolReply {
        Self.reply(try handleVacuum())
    }

    public func trainVectors() async throws -> ToolReply {
        Self.reply(try handleTrainVectors())
    }

    // MARK: Result mapping

    static func text(from result: CallTool.Result) -> String {
        result.content.compactMap { block -> String? in
            if case .text(let text, _, _) = block { return text }
            return nil
        }.joined(separator: "\n")
    }

    static func reply(_ result: CallTool.Result) -> ToolReply {
        ToolReply(text: text(from: result), isError: result.isError ?? false)
    }
}
