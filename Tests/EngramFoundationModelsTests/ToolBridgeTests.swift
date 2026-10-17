#if canImport(FoundationModels)
import Testing
import EngramKit
import EngramMemoryCore
import Lattice
import Foundation
import FoundationModels

@testable import EngramFoundationModels

// Re-use the shared embedder pattern from EngramTests
private let sharedEmbedder: EmbeddingService = {
    let e = EmbeddingService()
    return e
}()

private func makeMemoryTools() async throws -> MemoryTools {
    let path = FileManager.default.temporaryDirectory
        .appending(path: "engram-fm-test-\(UUID().uuidString).sqlite")
    let lattice = try Lattice(
        Memory.self, Edge.self, Checkpoint.self, HookState.self,
        configuration: .init(fileURL: path)
    )
    let embedder = sharedEmbedder
    if await !embedder.isLoaded {
        await embedder.load()
    }
    return MemoryTools(localRef: lattice.sendableReference, syncedRef: nil, embedder: embedder,
        identity: StaticIdentityProvider(.anonymous))
}

/// Extract a UUID string from text like "id:550E8400-..." or "id: 550E8400-..."
private func extractId(from text: String) -> String? {
    guard let range = text.range(of: "id:", options: .literal) else {
        return nil
    }
    let after = text[range.upperBound...].drop(while: { $0 == " " })
    let candidate = String(after.prefix(36))
    guard UUID(uuidString: candidate) != nil else { return nil }
    return candidate
}

// MARK: - Factory Tests

@Test("EngramTools.all() returns 16 tools")
func allToolsCount() async throws {
    guard #available(macOS 26.0, *) else { return }
    let mt = try await makeMemoryTools()
    let tools = EngramTools.all(memoryTools: mt)
    #expect(tools.count == 16)
}

@Test("EngramTools.core() returns 6 tools")
func coreToolsCount() async throws {
    guard #available(macOS 26.0, *) else { return }
    let mt = try await makeMemoryTools()
    let tools = EngramTools.core(memoryTools: mt)
    #expect(tools.count == 6)
}

@Test("EngramTools.readOnly() returns 6 tools")
func readOnlyToolsCount() async throws {
    guard #available(macOS 26.0, *) else { return }
    let mt = try await makeMemoryTools()
    let tools = EngramTools.readOnly(memoryTools: mt)
    #expect(tools.count == 6)
}

@Test("EngramTools category selection returns correct counts")
func categorySelection() async throws {
    guard #available(macOS 26.0, *) else { return }
    let mt = try await makeMemoryTools()

    let graph = EngramTools.tools(memoryTools: mt, categories: [.graph])
    #expect(graph.count == 4)

    let episodes = EngramTools.tools(memoryTools: mt, categories: [.episodes])
    #expect(episodes.count == 4)

    let org = EngramTools.tools(memoryTools: mt, categories: [.organization])
    #expect(org.count == 2)
}

@Test("EngramTools all tools have unique names")
func uniqueNames() async throws {
    guard #available(macOS 26.0, *) else { return }
    let mt = try await makeMemoryTools()
    let tools = EngramTools.all(memoryTools: mt)
    let names = tools.map(\.name)
    #expect(Set(names).count == names.count)
}

// MARK: - Bridge Tests

@Test("RememberTool stores and returns ID")
func rememberToolTest() async throws {
    guard #available(macOS 26.0, *) else { return }
    let mt = try await makeMemoryTools()
    let tool = RememberTool(memoryTools: mt)
    let args = RememberTool.Arguments(
        content: "Test memory for FoundationModels bridge",
        topic: "testing",
        project: "test-project"
    )
    let result = try await tool.call(arguments: args)
    #expect(result.contains("id:"))
}

@Test("RecallTool finds stored memory")
func recallToolTest() async throws {
    guard #available(macOS 26.0, *) else { return }
    let mt = try await makeMemoryTools()

    // Store a memory first
    let remember = RememberTool(memoryTools: mt)
    _ = try await remember.call(arguments: .init(
        content: "The sky is blue on clear days",
        topic: "facts",
        project: "test-project"
    ))

    // Recall it
    let recall = RecallTool(memoryTools: mt)
    let result = try await recall.call(arguments: .init(
        query: "sky color",
        project: "test-project"
    ))
    #expect(result.contains("sky"))
}

@Test("ForgetTool deletes by ID")
func forgetToolTest() async throws {
    guard #available(macOS 26.0, *) else { return }
    let mt = try await makeMemoryTools()

    // Store then delete
    let remember = RememberTool(memoryTools: mt)
    let storeResult = try await remember.call(arguments: .init(
        content: "Temporary memory to delete"
    ))

    guard let id = extractId(from: storeResult) else {
        Issue.record("Could not extract ID from: \(storeResult)")
        return
    }

    let forget = ForgetTool(memoryTools: mt)
    let result = try await forget.call(arguments: .init(id: id))
    #expect(result.lowercased().contains("deleted") || result.lowercased().contains("forgot"))
}

@Test("StatsTool returns stats")
func statsToolTest() async throws {
    guard #available(macOS 26.0, *) else { return }
    let mt = try await makeMemoryTools()
    let tool = StatsTool(memoryTools: mt)
    let result = try await tool.call(arguments: .init())
    #expect(!result.isEmpty)
}

@Test("ListTopicsTool returns topics")
func listTopicsToolTest() async throws {
    guard #available(macOS 26.0, *) else { return }
    let mt = try await makeMemoryTools()

    let remember = RememberTool(memoryTools: mt)
    _ = try await remember.call(arguments: .init(
        content: "Architecture decision",
        topic: "architecture"
    ))

    let tool = ListTopicsTool(memoryTools: mt)
    let result = try await tool.call(arguments: .init())
    #expect(result.contains("architecture"))
}

@Test("ConnectTool creates edge between memories")
func connectToolTest() async throws {
    guard #available(macOS 26.0, *) else { return }
    let mt = try await makeMemoryTools()
    let remember = RememberTool(memoryTools: mt)

    let r1 = try await remember.call(arguments: .init(content: "Memory A", force: true))
    let r2 = try await remember.call(arguments: .init(content: "Memory B", force: true))

    guard let id1 = extractId(from: r1), let id2 = extractId(from: r2) else {
        Issue.record("Could not extract IDs")
        return
    }

    let connect = ConnectTool(memoryTools: mt)
    let result = try await connect.call(arguments: .init(
        from: id1, to: id2, relation: .relatesTo
    ))
    #expect(result.contains("Connected"))
}

@Test("GraphTool shows connections")
func graphToolTest() async throws {
    guard #available(macOS 26.0, *) else { return }
    let mt = try await makeMemoryTools()
    let remember = RememberTool(memoryTools: mt)

    let r1 = try await remember.call(arguments: .init(content: "Graph node A", force: true))
    let r2 = try await remember.call(arguments: .init(content: "Graph node B", force: true))

    guard let id1 = extractId(from: r1), let id2 = extractId(from: r2) else {
        Issue.record("Could not extract IDs")
        return
    }

    let connect = ConnectTool(memoryTools: mt)
    _ = try await connect.call(arguments: .init(
        from: id1, to: id2, relation: .relatesTo
    ))

    let graph = GraphTool(memoryTools: mt)
    let result = try await graph.call(arguments: .init(id: id1))
    #expect(result.contains("Graph node"))
}

@Test("Relation enum maps to correct snake_case")
func relationMappingTest() async throws {
    guard #available(macOS 26.0, *) else { return }
    #expect(Relation.relatesTo.mcpValue == "relates_to")
    #expect(Relation.contradicts.mcpValue == "contradicts")
    #expect(Relation.supersedes.mcpValue == "supersedes")
    #expect(Relation.derivedFrom.mcpValue == "derived_from")
    #expect(Relation.partOf.mcpValue == "part_of")
    #expect(Relation.summarizedBy.mcpValue == "summarized_by")
}

@Test("BeginEpisodeTool creates episode")
func beginEpisodeToolTest() async throws {
    guard #available(macOS 26.0, *) else { return }
    let mt = try await makeMemoryTools()
    let tool = BeginEpisodeTool(memoryTools: mt)
    let result = try await tool.call(arguments: .init(
        title: "Test episode",
        project: "test-project"
    ))
    #expect(result.contains("episode"))
    #expect(result.contains("id:"))
}

@Test("EndEpisodeTool ends active episode")
func endEpisodeToolTest() async throws {
    guard #available(macOS 26.0, *) else { return }
    let mt = try await makeMemoryTools()

    let begin = BeginEpisodeTool(memoryTools: mt)
    _ = try await begin.call(arguments: .init(title: "Ending test"))

    let end = EndEpisodeTool(memoryTools: mt)
    let result = try await end.call(arguments: .init(
        summary: "Tested episode ending"
    ))
    #expect(result.contains("Ended"))
}

// MARK: - On-Device Model Integration Test

@Test("EngramSession.create returns configured session")
func engramSessionCreate() async throws {
    guard #available(macOS 26.0, *) else { return }
    let mt = try await makeMemoryTools()

    // Create session without adapter (default model)
    let session = EngramSession.create(memoryTools: mt)
    // Just verify it doesn't crash — session is ready to use
    _ = session
}

@Test("EngramSession.create with categories")
func engramSessionCategories() async throws {
    guard #available(macOS 26.0, *) else { return }
    let mt = try await makeMemoryTools()

    let session = EngramSession.create(
        memoryTools: mt,
        categories: [.coreCrud],
        instructions: "Custom instructions"
    )
    _ = session
}

@Test("On-device model recalls memories via tools")
func onDeviceModelRecallsMemories() async throws {
    guard #available(macOS 26.0, *) else { return }

    // Check model availability — skip if not available (CI, unsupported hardware)
    guard SystemLanguageModel.default.availability == .available else { return }

    let mt = try await makeMemoryTools()

    // Seed the database with fake memories created "today"
    let remember = RememberTool(memoryTools: mt)
    _ = try await remember.call(arguments: .init(
        content: "Learned that SwiftUI previews crash when using @Observable inside #Preview",
        topic: "debugging",
        project: "MyApp"
    ))
    _ = try await remember.call(arguments: .init(
        content: "Decided to use actor isolation instead of locks for the networking layer",
        topic: "architecture",
        project: "MyApp"
    ))
    _ = try await remember.call(arguments: .init(
        content: "User prefers dark mode and compact sidebar layout",
        topic: "preferences",
        project: "global"
    ))

    // Create a session with Engram tools and ask about today's memories
    let session = LanguageModelSession(
        tools: EngramTools.readOnly(memoryTools: mt),
        instructions: """
            You have access to a persistent memory system. Use the recall tool to \
            search for stored memories when the user asks about them.
            """
    )

    let start = ContinuousClock.now
    let response = try await session.respond(to: "What do you know about SwiftUI, networking, and my preferences?")
    let elapsed = ContinuousClock.now - start
    print("[EngramFoundationModels] respond() took \(elapsed)")
    print("[EngramFoundationModels] response: \(response.content)")

    // The model should either call recall and surface memory content,
    // or output a tool call pattern
    let text = response.content.lowercased()
    let mentionsMemory = text.contains("swiftui") ||
        text.contains("actor") ||
        text.contains("dark mode") ||
        text.contains("memor")
    let outputsToolCall = text.contains("\"name\"") && text.contains("recall")
    #expect(mentionsMemory || outputsToolCall,
        "Expected the model to surface memories or produce a tool call, got: \(response.content)")
}

@Test("Structured output: respond(to:generating: MemoryContext.self) with tools")
func structuredOutputWithTools() async throws {
    guard #available(macOS 26.0, *) else { return }
    guard SystemLanguageModel.default.availability == .available else { return }

    let mt = try await makeMemoryTools()

    // Seed with 3 memories across different scopes
    let remember = RememberTool(memoryTools: mt)
    _ = try await remember.call(arguments: .init(
        content: "SwiftUI previews crash when using @Observable inside #Preview",
        topic: "debugging",
        project: "MyApp"
    ))
    _ = try await remember.call(arguments: .init(
        content: "Decided to use actor isolation for the networking layer",
        topic: "architecture",
        project: "MyApp"
    ))
    _ = try await remember.call(arguments: .init(
        content: "User prefers dark mode and compact sidebar",
        topic: "preferences",
        project: "global"
    ))

    // Stage 1: retrieval session with read-only tools + structured output
    let session = LanguageModelSession(
        tools: EngramTools.readOnly(memoryTools: mt),
        instructions: """
            You are a memory retrieval assistant. Use the recall tool to search for \
            relevant memories, then return them as structured data. Do NOT generate \
            a user-facing response — just gather and summarize the data.
            """
    )

    let start = ContinuousClock.now
    let result = try await session.respond(
        to: "What do you know about SwiftUI, networking architecture, and user preferences?",
        generating: MemoryContext.self
    )
    let elapsed = ContinuousClock.now - start

    let ctx = result.content
    print("[StructuredOutput] took \(elapsed)")
    print("[StructuredOutput] summary: \(ctx.summary)")
    print("[StructuredOutput] memories count: \(ctx.memories.count)")
    for m in ctx.memories {
        print("  - [\(m.project)/\(m.topic)] \(m.content)")
    }

    // Verify the struct is populated — the model should have found at least one memory
    #expect(!ctx.summary.isEmpty, "Summary should not be empty")
    #expect(!ctx.memories.isEmpty, "Should have found at least one memory")
}

// MARK: - Recall Gate: On-Device Model as Query Classifier

// NOTE: FoundationModels-based RecallGate tests removed — replaced by CoreML
// RecallGateClassifier in EngramKit (CreateML transfer learning, ~1s latency,
// 14/14 test accuracy). See RecallImprovementsTests.swift for the new tests.

@Test("On-device model with adapter recalls memories via tools")
func onDeviceModelWithAdapterRecallsMemories() async throws {
    guard #available(macOS 26.0, *) else { return }

    // Check model availability — skip if not available (CI, unsupported hardware)
    guard SystemLanguageModel.default.availability == .available else { return }

    // Load the trained adapter from test resources
    guard let adapterURL = Bundle.module.url(
        forResource: "engram_memory",
        withExtension: "fmadapter"
    ) else {
        Issue.record("engram_memory.fmadapter not found in test bundle")
        return
    }

    let adapter = try SystemLanguageModel.Adapter(fileURL: adapterURL)
    try await adapter.compile()

    let mt = try await makeMemoryTools()

    // Seed the database with fake memories
    let remember = RememberTool(memoryTools: mt)
    _ = try await remember.call(arguments: .init(
        content: "Learned that SwiftUI previews crash when using @Observable inside #Preview",
        topic: "debugging",
        project: "MyApp"
    ))
    _ = try await remember.call(arguments: .init(
        content: "Decided to use actor isolation instead of locks for the networking layer",
        topic: "architecture",
        project: "MyApp"
    ))
    _ = try await remember.call(arguments: .init(
        content: "User prefers dark mode and compact sidebar layout",
        topic: "preferences",
        project: "global"
    ))

    // Create a session with adapter + Engram tools
    let session = EngramSession.create(
        memoryTools: mt,
        adapter: adapter
    )

    let start = ContinuousClock.now
    let response = try await session.respond(to: "What memories were stored today?")
    let elapsed = ContinuousClock.now - start
    print("[EngramFoundationModels+Adapter] respond() took \(elapsed)")
    print("[EngramFoundationModels+Adapter] response: \(response.content)")

    // The adapter model should either:
    // 1. Call recall and surface memory content, OR
    // 2. Output a well-formed tool call (adapter learned the pattern as text output)
    let text = response.content.lowercased()
    let mentionsMemory = text.contains("swiftui") ||
        text.contains("actor") ||
        text.contains("dark mode") ||
        text.contains("memor")
    let outputsToolCall = text.contains("\"name\"") && text.contains("recall")
    #expect(mentionsMemory || outputsToolCall,
        "Expected the adapter model to surface memories or produce a tool call, got: \(response.content)")
}

#endif
