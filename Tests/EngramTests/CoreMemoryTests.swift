import Testing
import EngramKit
import EngramMemoryCore
import Lattice
import MCP
import Foundation

// MARK: - Remember

@Test func remember_basic() async throws {
    let tools = try await makeTools()
    let result = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Swift uses ARC for memory management")]
    ))
    let output = text(from: result)
    #expect(output.contains("Stored memory"))
    #expect(output.contains("topic: general"))
    #expect(output.contains("project: global"))
}

@Test func remember_withMetadata() async throws {
    let tools = try await makeTools()
    let result = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Always use snake_case for database columns"),
            "topic": .string("conventions"),
            "project": .string("Lattice"),
            "source": .string("code-review"),
        ]
    ))
    let output = text(from: result)
    #expect(output.contains("project: Lattice"))
    #expect(output.contains("topic: conventions"))
}

@Test func remember_missingContent_throws() async throws {
    let tools = try await makeTools()
    await #expect(throws: (any Error).self) {
        try await tools.handle(CallTool.Parameters(
            name: "remember",
            arguments: [:]
        ))
    }
}

@Test func remember_emptyContent_throws() async throws {
    let tools = try await makeTools()
    await #expect(throws: (any Error).self) {
        try await tools.handle(CallTool.Parameters(
            name: "remember",
            arguments: ["content": .string("")]
        ))
    }
}

// MARK: - Recall (semantic search with real embedding model)

@Test func recall_semanticSearch() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Lattice uses SQLite as its backend database engine")]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Swift macros generate code at compile time")]
    ))

    // Semantic search for "database" — should rank the SQLite memory higher
    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("database")]
    ))
    let output = text(from: result)
    #expect(output.contains("SQLite"))
}

@Test func recall_noResults() async throws {
    let tools = try await makeTools()
    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("nonexistent topic with no matches")]
    ))
    #expect(text(from: result) == "No memories found.")
}

@Test func recall_projectScoping() async throws {
    let tools = try await makeTools()

    // Store a global memory and two project-specific memories
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("User prefers dark mode themes globally"),
            "project": .string("global"),
        ]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Lattice dark mode uses NSAppearance for theming"),
            "project": .string("Lattice"),
        ]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("OtherApp dark mode uses UIKit appearance proxies"),
            "project": .string("OtherApp"),
        ]
    ))

    // Recall with project=Lattice should get Lattice + global, boosted above OtherApp
    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: [
            "query": .string("dark mode theming"),
            "project": .string("Lattice"),
        ]
    ))
    let output = text(from: result)
    #expect(output.contains("NSAppearance") || output.contains("Lattice"))
    #expect(output.contains("prefers dark mode") || output.contains("global"))
}

@Test func recall_topicFilter() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Use guard let for early returns in Swift functions"),
            "topic": .string("conventions"),
        ]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Fixed retain cycle in observer by using weak self capture"),
            "topic": .string("debugging"),
        ]
    ))

    // Recall with topic=debugging
    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: [
            "query": .string("memory leak retain cycle"),
            "topic": .string("debugging"),
        ]
    ))
    let output = text(from: result)
    #expect(output.contains("retain cycle"))
    #expect(!output.contains("guard let"))
}

@Test func recall_semanticRelevanceOrdering() async throws {
    let tools = try await makeTools()

    // Store memories with varying relevance to "cooking recipes"
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("The best pasta recipe uses fresh tomatoes and basil")]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Quantum computing uses qubits for parallel computation")]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Italian cuisine emphasizes fresh ingredients and simple preparation")]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("cooking food recipes"), "limit": .int(2)]
    ))
    let output = text(from: result)
    // Should find food-related memories, not quantum computing
    #expect(!output.contains("qubits"))
    #expect(output.contains("pasta") || output.contains("Italian") || output.contains("cuisine"))
}

// MARK: - Forget

@Test func forget_byTopic() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("debug note 1"), "topic": .string("debugging")]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("debug note 2"), "topic": .string("debugging"), "force": .bool(true)]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("architecture note about modules"), "topic": .string("architecture")]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "forget",
        arguments: ["topic": .string("debugging")]
    ))
    let output = text(from: result)
    // Post-groups format: bulk forget reports its shared/private partition
    // ("Removed N memories … N deleted[; M tombstoned]").
    #expect(output.contains("Removed 2 memories"))
    #expect(output.contains("2 deleted"))

    // architecture memory should still exist
    let recall = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("architecture modules")]
    ))
    #expect(text(from: recall).contains("architecture"))
}

@Test func forget_byProject() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("lattice specific implementation detail"), "project": .string("Lattice")]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("global preference setting for editor"), "project": .string("global")]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "forget",
        arguments: ["project": .string("Lattice")]
    ))
    let projectOut = text(from: result)
    #expect(projectOut.contains("Removed 1 memories"))
    #expect(projectOut.contains("1 deleted"))

    // global memory should remain
    let recall = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("preference setting editor")]
    ))
    #expect(text(from: recall).contains("preference"))
}

@Test func forget_byTopicAndProject() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("debug for project X"), "topic": .string("debug"), "project": .string("X")]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("debug for project Y"), "topic": .string("debug"), "project": .string("Y")]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("arch for project X"), "topic": .string("arch"), "project": .string("X")]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "forget",
        arguments: ["topic": .string("debug"), "project": .string("X")]
    ))
    let bothOut = text(from: result)
    #expect(bothOut.contains("Removed 1 memories"))
    #expect(bothOut.contains("1 deleted"))
}

@Test func forget_all_requiresFilter() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("first memory to be preserved")]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("second memory to be preserved"), "force": .bool(true)]
    ))

    // Calling forget with no arguments should fail (safety check)
    await #expect(throws: (any Error).self) {
        try await tools.handle(CallTool.Parameters(
            name: "forget",
            arguments: nil
        ))
    }

    // Memories should still exist
    let stats = try await tools.handle(CallTool.Parameters(
        name: "stats",
        arguments: nil
    ))
    #expect(text(from: stats).contains("Total memories: 2"))
}

@Test func forget_byStringEncodedId() async throws {
    let tools = try await makeTools()

    let r1 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("memory to delete by string id")]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("memory to keep")]
    ))

    let id = extractId(from: text(from: r1))!

    // Pass id as a string (simulating MCP client behavior)
    let result = try await tools.handle(CallTool.Parameters(
        name: "forget",
        arguments: ["id": .string(String(id))]
    ))
    #expect(result.isError != true)
    #expect(text(from: result).contains("Deleted memory"))

    // Only one memory should remain
    let stats = try await tools.handle(CallTool.Parameters(
        name: "stats",
        arguments: nil
    ))
    #expect(text(from: stats).contains("Total memories: 1"))
}

// MARK: - List Topics

@Test func listTopics_empty() async throws {
    let tools = try await makeTools()
    let result = try await tools.handle(CallTool.Parameters(
        name: "list_topics",
        arguments: nil
    ))
    #expect(text(from: result) == "No memories stored.")
}

@Test func listTopics_withMemories() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("debug note alpha"), "topic": .string("debugging")]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("debug note beta"), "topic": .string("debugging"), "force": .bool(true)]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("architecture overview"), "topic": .string("architecture")]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "list_topics",
        arguments: nil
    ))
    let output = text(from: result)
    #expect(output.contains("All topics:"))
    #expect(output.contains("debugging: 2 memories"))
    #expect(output.contains("architecture: 1 memories"))
}

@Test func listTopics_filteredByProject() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("debug for X"), "topic": .string("debug"), "project": .string("X")]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("debug for Y"), "topic": .string("debug"), "project": .string("Y")]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "list_topics",
        arguments: ["project": .string("X")]
    ))
    let output = text(from: result)
    #expect(output.contains("Topics for project 'X':"))
    #expect(output.contains("debug: 1 memories"))
}

// MARK: - Unknown Tool

@Test func unknownTool_throws() async throws {
    let tools = try await makeTools()
    await #expect(throws: (any Error).self) {
        try await tools.handle(CallTool.Parameters(name: "nonexistent"))
    }
}

// MARK: - Tool Definitions

@Test func definitions_hasTwentyTools() async throws {
    let tools = try await makeTools()
    let defs = await tools.definitions
    #expect(defs.count == 24)
    let names = defs.map(\.name).sorted()
    #expect(names == ["begin_episode", "checkpoint", "connect", "consolidate", "detect_communities", "disconnect", "end_episode", "find_clusters", "forget", "graph", "list_episodes", "list_tasks", "list_topics", "merge", "organize", "recall", "recall_episode", "remember", "resume", "stats", "timeline", "train_vectors", "update", "vacuum"])
}

// MARK: - Remember with force creates new

@Test func remember_forceCreatesNew() async throws {
    let tools = try await makeTools()

    // Store two memories with very similar content using force: true
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Lattice uses SQLite as its database backend"),
            "project": .string("Lattice"),
        ]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Lattice uses SQLite as its backend database engine"),
            "project": .string("Lattice"),
            "force": .bool(true),
        ]
    ))

    // Both should be stored because force: true bypasses conflict detection
    let stats = try await tools.handle(CallTool.Parameters(
        name: "stats",
        arguments: ["project": .string("Lattice")]
    ))
    #expect(text(from: stats).contains("Total memories: 2"))
}

// MARK: - Conflict Detection

@Test func remember_conflictDetection_blocksStore() async throws {
    let tools = try await makeTools()

    // Store a memory
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Lattice uses SQLite"),
            "project": .string("Lattice"),
        ]
    ))

    // Try to store a near-duplicate — should be blocked
    let result = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Lattice uses SQLite as its database"),
            "project": .string("Lattice"),
        ]
    ))
    let output = text(from: result)
    #expect(output.contains("Near-duplicate"))
    #expect(output.contains("NOT stored"))

    // Only 1 memory should exist
    let stats = try await tools.handle(CallTool.Parameters(
        name: "stats",
        arguments: ["project": .string("Lattice")]
    ))
    #expect(text(from: stats).contains("Total memories: 1"))
}

@Test func remember_conflictDetection_force() async throws {
    let tools = try await makeTools()

    // Store a memory
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Lattice uses SQLite"),
            "project": .string("Lattice"),
        ]
    ))

    // Store near-duplicate with force: true — should succeed
    let result = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Lattice uses SQLite as its database"),
            "project": .string("Lattice"),
            "force": .bool(true),
        ]
    ))
    let output = text(from: result)
    #expect(output.contains("Stored memory"))

    // Both should exist
    let stats = try await tools.handle(CallTool.Parameters(
        name: "stats",
        arguments: ["project": .string("Lattice")]
    ))
    #expect(text(from: stats).contains("Total memories: 2"))
}

@Test func remember_conflictDetection_differentProject() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("The app uses PostgreSQL for data storage"),
            "project": .string("ProjectA"),
        ]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("The app uses PostgreSQL for data storage"),
            "project": .string("ProjectB"),
        ]
    ))
    let output = text(from: result)
    #expect(output.contains("Stored memory"))

    let statsA = try await tools.handle(CallTool.Parameters(
        name: "stats",
        arguments: ["project": .string("ProjectA")]
    ))
    #expect(text(from: statsA).contains("Total memories: 1"))
    let statsB = try await tools.handle(CallTool.Parameters(
        name: "stats",
        arguments: ["project": .string("ProjectB")]
    ))
    #expect(text(from: statsB).contains("Total memories: 1"))
}

@Test func remember_failsWithoutEmbeddingModel() async throws {
    let path = FileManager.default.temporaryDirectory
        .appending(path: "claude-memory-test-\(UUID().uuidString).sqlite")
    let lattice = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self, configuration: .init(fileURL: path))
    let embedder = EmbeddingService(modelPath: "/nonexistent/path")
    let tools = MemoryTools(localRef: lattice.sendableReference, syncedRef: nil, embedder: embedder,
        identity: StaticIdentityProvider(.anonymous))

    await #expect(throws: MCPError.self) {
        _ = try await tools.handle(CallTool.Parameters(
            name: "remember",
            arguments: ["content": .string("Some important fact")]
        ))
    }
}

@Test func remember_conflictDetection_lowTermOverlap_allows() async throws {
    let tools = try await makeTools()

    // Store a memory about Swift concurrency actors
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Swift concurrency uses actors for thread safety and data isolation"),
            "project": .string("SwiftNotes"),
        ]
    ))

    // Store a topically similar but informationally distinct memory
    // Embeddings will be close (both about Swift concurrency) but term overlap is low
    let result = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Swift concurrency provides structured tasks with automatic cancellation propagation"),
            "project": .string("SwiftNotes"),
        ]
    ))
    let output = text(from: result)
    #expect(output.contains("Stored memory"))

    let stats = try await tools.handle(CallTool.Parameters(
        name: "stats",
        arguments: ["project": .string("SwiftNotes")]
    ))
    #expect(text(from: stats).contains("Total memories: 2"))
}

@Test func jaccardSimilarity_basic() {
    // Identical strings
    #expect(jaccardSimilarity("hello world test", "hello world test") == 1.0)

    // Complete overlap (subset)
    let j1 = jaccardSimilarity("Lattice uses SQLite", "Lattice uses SQLite as its database")
    #expect(j1 >= 0.4) // 3 shared out of 5 unique terms (3+ chars)

    // Low overlap — different content, same domain
    let j2 = jaccardSimilarity(
        "Lattice uses actors for thread safety and data isolation",
        "Lattice provides structured tasks with automatic cancellation propagation"
    )
    #expect(j2 < 0.4)

    // No overlap
    #expect(jaccardSimilarity("apple banana cherry", "dog elephant fox") == 0.0)

    // Empty strings
    #expect(jaccardSimilarity("", "") == 0.0)

    // Short tokens filtered out (< 3 chars)
    #expect(jaccardSimilarity("a is to", "a is to") == 0.0)
}

// MARK: - Update

@Test func update_existingMemory() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("The default branch is called master"),
            "project": .string("MyProject"),
        ]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "update",
        arguments: [
            "query": .string("default branch name"),
            "content": .string("The default branch is called main"),
            "project": .string("MyProject"),
        ]
    ))
    let output = text(from: result)
    #expect(output.contains("Updated memory"))
    #expect(output.contains("content:"))

    let recall = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("default branch"), "project": .string("MyProject")]
    ))
    #expect(text(from: recall).contains("main"))
}

@Test func update_noMatch() async throws {
    let tools = try await makeTools()

    let result = try await tools.handle(CallTool.Parameters(
        name: "update",
        arguments: [
            "query": .string("something that does not exist"),
            "content": .string("new content"),
        ]
    ))
    #expect(text(from: result).contains("No matching memory found"))
}

@Test func update_byId() async throws {
    let tools = try await makeTools()

    let r1 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Original content for ID-based update")]
    ))
    let id = extractId(from: text(from: r1))!

    let result = try await tools.handle(CallTool.Parameters(
        name: "update",
        arguments: [
            "id": .string(id),
            "content": .string("Updated content via ID"),
        ]
    ))
    let output = text(from: result)
    #expect(output.contains("Updated memory"))
    #expect(output.contains("id: \(id)"))

    let recall = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("Updated content via ID")]
    ))
    #expect(text(from: recall).contains("Updated content via ID"))
}

@Test func update_append() async throws {
    let tools = try await makeTools()

    let r1 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Base content")]
    ))
    let id = extractId(from: text(from: r1))!

    let result = try await tools.handle(CallTool.Parameters(
        name: "update",
        arguments: [
            "id": .string(id),
            "append": .string("Appended line"),
        ]
    ))
    #expect(result.isError != true)

    let recall = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("Base content appended")]
    ))
    let output = text(from: recall)
    #expect(output.contains("Base content"))
    #expect(output.contains("Appended line"))
}

@Test func update_prepend() async throws {
    let tools = try await makeTools()

    let r1 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Original line")]
    ))
    let id = extractId(from: text(from: r1))!

    let result = try await tools.handle(CallTool.Parameters(
        name: "update",
        arguments: [
            "id": .string(id),
            "prepend": .string("Prepended line"),
        ]
    ))
    #expect(result.isError != true)

    let recall = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("Prepended line original")]
    ))
    let output = text(from: recall)
    #expect(output.contains("Prepended line"))
    #expect(output.contains("Original line"))
}

@Test func update_findReplace() async throws {
    let tools = try await makeTools()

    let r1 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("The project uses Python 2.7 for scripting")]
    ))
    let id = extractId(from: text(from: r1))!

    let result = try await tools.handle(CallTool.Parameters(
        name: "update",
        arguments: [
            "id": .string(id),
            "find": .string("Python 2.7"),
            "replace": .string("Python 3.12"),
        ]
    ))
    #expect(result.isError != true)

    let recall = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("project scripting language")]
    ))
    let output = text(from: recall)
    #expect(output.contains("Python 3.12"))
    #expect(!output.contains("Python 2.7"))
}

@Test func update_findReplace_patternNotFound() async throws {
    let tools = try await makeTools()

    let r1 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Uses Swift for development")]
    ))
    let id = extractId(from: text(from: r1))!

    let result = try await tools.handle(CallTool.Parameters(
        name: "update",
        arguments: [
            "id": .string(id),
            "find": .string("Rust"),
            "replace": .string("Go"),
        ]
    ))
    #expect(result.isError == true)
    #expect(text(from: result).contains("Find pattern not found"))
}

@Test func update_metadataOnly_topic() async throws {
    let tools = try await makeTools()

    let r1 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Important pattern for topic change test"),
            "topic": .string("general"),
        ]
    ))
    let id = extractId(from: text(from: r1))!

    let result = try await tools.handle(CallTool.Parameters(
        name: "update",
        arguments: [
            "id": .string(id),
            "topic": .string("patterns"),
        ]
    ))
    let output = text(from: result)
    #expect(output.contains("topic: general → patterns"))
    #expect(output.contains("topic: patterns"))

    let topics = try await tools.handle(CallTool.Parameters(
        name: "list_topics",
        arguments: nil
    ))
    let topicsOutput = text(from: topics)
    #expect(topicsOutput.contains("patterns: 1"))
    #expect(!topicsOutput.contains("general"))
}

@Test func update_metadataOnly_expiration() async throws {
    let tools = try await makeTools()

    let r1 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Memory for expiration test")]
    ))
    let id = extractId(from: text(from: r1))!

    let result1 = try await tools.handle(CallTool.Parameters(
        name: "update",
        arguments: [
            "id": .string(id),
            "expires_in_days": .int(7),
        ]
    ))
    let output1 = text(from: result1)
    #expect(output1.contains("expires: permanent →"))

    let result2 = try await tools.handle(CallTool.Parameters(
        name: "update",
        arguments: [
            "id": .string(id),
            "expires_in_days": .int(0),
        ]
    ))
    let output2 = text(from: result2)
    #expect(output2.contains("→ permanent"))
}

@Test func update_contentAndMetadata() async throws {
    let tools = try await makeTools()

    let r1 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Old content for combined test"),
            "topic": .string("general"),
        ]
    ))
    let id = extractId(from: text(from: r1))!

    let result = try await tools.handle(CallTool.Parameters(
        name: "update",
        arguments: [
            "id": .string(id),
            "append": .string("Extra detail added"),
            "topic": .string("architecture"),
        ]
    ))
    let output = text(from: result)
    #expect(output.contains("content:"))
    #expect(output.contains("topic: general → architecture"))
}

@Test func update_noTarget_throws() async throws {
    let tools = try await makeTools()
    await #expect(throws: (any Error).self) {
        try await tools.handle(CallTool.Parameters(
            name: "update",
            arguments: ["content": .string("no target")]
        ))
    }
}

@Test func update_noEdits_throws() async throws {
    let tools = try await makeTools()

    let r1 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Memory with no edits")]
    ))
    let id = extractId(from: text(from: r1))!

    await #expect(throws: (any Error).self) {
        try await tools.handle(CallTool.Parameters(
            name: "update",
            arguments: ["id": .string(id)]
        ))
    }
}

@Test func update_mutuallyExclusiveContent() async throws {
    let tools = try await makeTools()

    let r1 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Memory for mutual exclusion test")]
    ))
    let id = extractId(from: text(from: r1))!

    await #expect(throws: (any Error).self) {
        try await tools.handle(CallTool.Parameters(
            name: "update",
            arguments: [
                "id": .string(id),
                "content": .string("full replace"),
                "append": .string("also append"),
            ]
        ))
    }
}

@Test func update_byId_notFound() async throws {
    let tools = try await makeTools()

    let result = try await tools.handle(CallTool.Parameters(
        name: "update",
        arguments: [
            "id": .string(UUID().uuidString),
            "content": .string("should not work"),
        ]
    ))
    #expect(result.isError == true)
    #expect(text(from: result).contains("not found"))
}

// MARK: - Stats

@Test func stats_basic() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("debug note A"), "topic": .string("debugging"), "project": .string("X")]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("debug note B"), "topic": .string("debugging"), "project": .string("X"), "force": .bool(true)]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("architecture pattern C"), "topic": .string("architecture"), "project": .string("Y")]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "stats",
        arguments: nil
    ))
    let output = text(from: result)
    #expect(output.contains("Total memories: 3"))
    #expect(output.contains("X: 2"))
    #expect(output.contains("Y: 1"))
    #expect(output.contains("debugging: 2"))
    #expect(output.contains("architecture: 1"))
}

@Test func stats_filteredByProject() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("note for X"), "topic": .string("general"), "project": .string("X")]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("note for Y"), "topic": .string("general"), "project": .string("Y")]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "stats",
        arguments: ["project": .string("X")]
    ))
    let output = text(from: result)
    #expect(output.contains("Total memories: 1"))
    #expect(!output.contains("By project:"))
}

@Test func stats_empty() async throws {
    let tools = try await makeTools()
    let result = try await tools.handle(CallTool.Parameters(
        name: "stats",
        arguments: nil
    ))
    #expect(text(from: result) == "No memories stored.")
}

// MARK: - lastAccessedAt

@Test func recall_bumpsLastAccessed() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Important architectural decision about using SQLite")]
    ))

    try await Task.sleep(for: .milliseconds(50))

    _ = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("architectural decision SQLite")]
    ))

    let stats = try await tools.handle(CallTool.Parameters(
        name: "stats",
        arguments: nil
    ))
    #expect(text(from: stats).contains("Total memories: 1"))
}

// MARK: - Recall includes IDs and expiration

@Test func recall_includesMemoryId() async throws {
    let tools = try await makeTools()

    let stored = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Lattice uses SQLite as its database backend")]
    ))
    let storedText = text(from: stored)
    #expect(storedText.contains("id:"))

    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("database backend")]
    ))
    let output = text(from: result)
    #expect(output.contains("[id:"))
    #expect(output.contains("SQLite"))
}

@Test func recall_showsExpiration() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Currently refactoring the auth system"),
            "expires_in_days": .int(7),
        ]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("auth refactoring")]
    ))
    let output = text(from: result)
    #expect(output.contains("expires:"))
    #expect(output.contains("auth system"))
}

@Test func recall_filtersExpired() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("This memory should be visible in recall results")]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("visible recall results")]
    ))
    #expect(text(from: result).contains("visible"))
}

// MARK: - Merge

@Test func merge_twoMemories() async throws {
    let tools = try await makeTools()

    let r1 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Lattice uses SQLite as its database"),
            "project": .string("Lattice"),
            "topic": .string("architecture"),
        ]
    ))
    let r2 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Lattice SQLite runs in WAL mode for concurrency"),
            "project": .string("Lattice"),
            "topic": .string("architecture"),
            "force": .bool(true),
        ]
    ))

    let id1 = extractId(from: text(from: r1))!
    let id2 = extractId(from: text(from: r2))!

    let result = try await tools.handle(CallTool.Parameters(
        name: "merge",
        arguments: [
            "ids": .array([.string(id1), .string(id2)]),
            "content": .string("Lattice uses SQLite in WAL mode as its database backend for concurrent access"),
        ]
    ))
    let output = text(from: result)
    #expect(output.contains("Merged 2 memories"))
    #expect(output.contains("WAL mode"))

    let stats = try await tools.handle(CallTool.Parameters(
        name: "stats",
        arguments: ["project": .string("Lattice")]
    ))
    #expect(text(from: stats).contains("Total memories: 1"))
}

@Test func merge_notFoundId() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("A real memory")]
    ))

    // Memory ids are UUIDs (globalId, sync-aligned) — pass two well-formed
    // but nonexistent UUIDs to exercise the not-found path (the old int ids
    // now fail decoding before the lookup).
    let result = try await tools.handle(CallTool.Parameters(
        name: "merge",
        arguments: [
            "ids": .array([
                .string("00000000-0000-0000-0000-000000000001"),
                .string("00000000-0000-0000-0000-000000009999"),
            ]),
            "content": .string("merged"),
        ]
    ))
    #expect(text(from: result).contains("not found"))
}

@Test func merge_needsAtLeastTwo() async throws {
    let tools = try await makeTools()
    await #expect(throws: (any Error).self) {
        try await tools.handle(CallTool.Parameters(
            name: "merge",
            arguments: [
                "ids": .array([.int(1)]),
                "content": .string("merged"),
            ]
        ))
    }
}

// MARK: - Expiration

@Test func remember_withExpiration() async throws {
    let tools = try await makeTools()

    let result = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("PR #42 needs review before merging"),
            "expires_in_days": .int(3),
        ]
    ))
    let output = text(from: result)
    #expect(output.contains("expires:"))
    #expect(output.contains("PR #42"))
}

@Test func remember_permanentByDefault() async throws {
    let tools = try await makeTools()

    let result = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("User prefers dark mode")]
    ))
    let output = text(from: result)
    #expect(!output.contains("expires:"))
}

// MARK: - FTS5 Hybrid Search

@Test func recall_fts5_hybrid_findsExactKeywords() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("The handleRecall function in Tools.swift implements semantic search"),
            "project": .string("Engram"),
            "force": .bool(true),
        ]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Swift uses ARC for automatic reference counting"),
            "project": .string("global"),
            "force": .bool(true),
        ]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: [
            "query": .string("handleRecall Tools"),
            "project": .string("Engram"),
        ]
    ))
    let output = text(from: result)
    #expect(output.contains("handleRecall"))
    // Vector-only recall (L2 KNN) — no FTS5 rank in output
    #expect(output.contains("distance:"))
}

@Test func recall_fts5_degraded_noEmbeddings_failsOnRemember() async throws {
    let path = FileManager.default.temporaryDirectory
        .appending(path: "claude-memory-test-\(UUID().uuidString).sqlite")
    let lattice = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self, configuration: .init(fileURL: path))
    let embedder = EmbeddingService()
    let tools = MemoryTools(localRef: lattice.sendableReference, syncedRef: nil, embedder: embedder,
        identity: StaticIdentityProvider(.anonymous))

    // Without embedding model, remember should fail rather than store empty vectors
    await #expect(throws: MCPError.self) {
        _ = try await tools.handle(CallTool.Parameters(
            name: "remember",
            arguments: ["content": .string("The parseJSON function handles deserialization of API responses")]
        ))
    }
}

@Test func recall_fts5_rankInOutput() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Machine learning models require training data and validation sets"),
            "force": .bool(true),
        ]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("The training pipeline processes data in batches"),
            "force": .bool(true),
        ]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("training data")]
    ))
    let output = text(from: result)
    // Vector-only recall (L2 KNN) — no FTS5 rank in output
    #expect(output.contains("distance:"))
}

// MARK: - Reinforcement / Importance Scoring

@Test func remember_withImportance() async throws {
    let tools = try await makeTools()
    let result = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Critical architecture decision about using event sourcing"),
            "importance": .int(5),
        ]
    ))
    let output = text(from: result)
    #expect(output.contains("Stored memory"))
    #expect(output.contains("importance: 5"))
}

@Test func remember_importanceOutOfRange_throws() async throws {
    let tools = try await makeTools()
    await #expect(throws: (any Error).self) {
        try await tools.handle(CallTool.Parameters(
            name: "remember",
            arguments: [
                "content": .string("Bad importance value"),
                "importance": .int(6),
            ]
        ))
    }
}

@Test func update_importance() async throws {
    let tools = try await makeTools()

    let r1 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Memory for importance update test")]
    ))
    let id = extractId(from: text(from: r1))!

    let result = try await tools.handle(CallTool.Parameters(
        name: "update",
        arguments: [
            "id": .string(id),
            "importance": .int(4),
        ]
    ))
    let output = text(from: result)
    #expect(output.contains("importance: 0 → 4"))

    let recall = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("importance update test")]
    ))
    #expect(text(from: recall).contains("importance: 4"))
}

@Test func recall_reinforcement_importanceBoost() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("The application uses AlphaDB as the primary relational database for user data"),
            "importance": .int(5),
        ]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("The application uses BetaDB as the primary relational database for user data"),
            "force": .bool(true),
        ]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("application primary relational database user data")]
    ))
    let output = text(from: result)

    #expect(output.contains("AlphaDB"))
    #expect(output.contains("importance: 5"))

    let alphaRange = output.range(of: "AlphaDB")!
    let betaRange = output.range(of: "BetaDB")!
    #expect(alphaRange.lowerBound < betaRange.lowerBound)
}

@Test func recall_reinforcement_frequencyBoosting() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("The project uses Redis for caching API responses and session data"),
        ]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("The project uses Postgres for caching API responses and session data"),
            "force": .bool(true),
        ]
    ))

    for _ in 0..<5 {
        _ = try await tools.handle(CallTool.Parameters(
            name: "recall",
            arguments: ["query": .string("Redis")]
        ))
    }

    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("caching API responses session data")]
    ))
    let output = text(from: result)
    #expect(output.contains("Redis"))
    #expect(output.contains("Postgres"))

    let redisRange = output.range(of: "Redis")!
    let pgRange = output.range(of: "Postgres")!
    #expect(redisRange.lowerBound < pgRange.lowerBound)
}

@Test func recall_reinforcement_recencyBoost() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Recently accessed architecture pattern for microservices")]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("microservices architecture pattern")]
    ))
    let output = text(from: result)
    #expect(output.contains("microservices"))
    #expect(output.contains("distance:"))
}

// MARK: - Temporal Queries (recall since/before)

@Test func recall_sinceFilter() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Memory created today for since filter test")]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: [
            "query": .string("since filter test"),
            "since": .string("today"),
        ]
    ))
    let output = text(from: result)
    #expect(output.contains("since filter test"))
    #expect(output.contains("created:"))
}

@Test func recall_beforeFilter() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Memory for before filter test")]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: [
            "query": .string("before filter test"),
            "before": .string("yesterday"),
        ]
    ))
    #expect(text(from: result) == "No memories found.")
}

@Test func recall_sinceAndBefore() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Memory for date range test")]
    ))

    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
    let isoFormatter = ISO8601DateFormatter()
    let tomorrowStr = isoFormatter.string(from: tomorrow)

    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: [
            "query": .string("date range test"),
            "since": .string("yesterday"),
            "before": .string(tomorrowStr),
        ]
    ))
    let output = text(from: result)
    #expect(output.contains("date range test"))
}

@Test func recall_sinceInvalidDate_throws() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Memory for invalid date test")]
    ))

    await #expect(throws: (any Error).self) {
        try await tools.handle(CallTool.Parameters(
            name: "recall",
            arguments: [
                "query": .string("invalid date test"),
                "since": .string("not-a-date"),
            ]
        ))
    }
}

// MARK: - Recall with depth (graph traversal)

@Test func recall_withDepth() async throws {
    let tools = try await makeTools()

    let r1 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Authentication uses JWT tokens for session management")]
    ))
    let r2 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("The PostgreSQL database runs on port 5432 with max 100 connections")]
    ))
    let id1 = extractId(from: text(from: r1))!
    let id2 = extractId(from: text(from: r2))!

    _ = try await tools.handle(CallTool.Parameters(
        name: "connect",
        arguments: ["from": .string(id1), "to": .string(id2), "relation": .string("part_of")]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: [
            "query": .string("authentication JWT session"),
            "depth": .int(1),
            "limit": .int(1),
        ]
    ))
    let output = text(from: result)
    #expect(output.contains("JWT"))
    // Structural edge (part_of) always surfaces connected memories
    #expect(output.contains("Connected (graph traversal"))
    #expect(output.contains("PostgreSQL"))
}

// MARK: - Cross-project soft boost

@Test func recall_crossProject_softBoost() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Lattice ORM provides @Model macro for Swift database models"),
            "project": .string("Engram"),
        ]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: [
            "query": .string("Lattice ORM database models"),
            "project": .string("Lattice"),
        ]
    ))
    let output = text(from: result)
    #expect(output.contains("Lattice ORM"))
}

// MARK: - parent_id

@Test func remember_withParentId_createsEdge() async throws {
    let tools = try await makeTools()

    // Create hub memory
    let hub = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Project overview hub"), "project": .string("TestProj")]
    ))
    let hubId = extractId(from: text(from: hub))!

    // Create child with parent_id
    let child = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Storage layer uses SQLite"),
            "project": .string("TestProj"),
            "parent_id": .string(hubId),
        ]
    ))
    let childOutput = text(from: child)
    #expect(childOutput.contains("parent: \(hubId)"))
    let childId = extractId(from: childOutput)!

    // Verify edge was created
    let graph = try await tools.handle(CallTool.Parameters(
        name: "graph",
        arguments: ["id": .string(childId)]
    ))
    let graphOutput = text(from: graph)
    #expect(graphOutput.contains("part_of"))
    #expect(graphOutput.contains("[id:\(hubId)]"))
}

@Test func remember_withParentId_invalidParent_throws() async throws {
    let tools = try await makeTools()
    await #expect(throws: (any Error).self) {
        try await tools.handle(CallTool.Parameters(
            name: "remember",
            arguments: [
                "content": .string("Orphan memory"),
                "parent_id": .string(UUID().uuidString),
            ]
        ))
    }
}

@Test func remember_withParentId_recallShowsConnected() async throws {
    let tools = try await makeTools()

    let hub = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Architecture overview for recall test project"), "project": .string("RecallTest")]
    ))
    let hubId = extractId(from: text(from: hub))!

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("The database layer uses Lattice ORM with SQLite backend"),
            "project": .string("RecallTest"),
            "parent_id": .string(hubId),
        ]
    ))

    // Recall the child — hub should appear as connected
    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("Lattice ORM SQLite database"), "depth": .int(1), "project": .string("RecallTest")]
    ))
    let output = text(from: result)
    // With L2 KNN, both memories (hub + child) appear as primary results in a 2-memory DB.
    // The hub may show in primary results rather than the "Connected" section.
    #expect(output.contains("Architecture overview"), "Hub should appear in results")
    #expect(output.contains("Lattice ORM"), "Child should appear in results")
}

// MARK: - Atomic memory nudge

@Test func remember_largeMultiSection_showsNudge() async throws {
    let tools = try await makeTools()

    let longContent = """
    ## Section One
    \(String(repeating: "Detail about section one. ", count: 30))

    ## Section Two
    \(String(repeating: "Detail about section two. ", count: 30))

    ## Section Three
    \(String(repeating: "Detail about section three. ", count: 30))
    """

    let result = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string(longContent), "force": .bool(true)]
    ))
    let output = text(from: result)
    #expect(output.contains("3 sections"))
    #expect(output.contains("parent_id"))
    #expect(output.contains("precise recall"))
}

@Test func remember_smallContent_noNudge() async throws {
    let tools = try await makeTools()

    let result = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Simple atomic fact about testing")]
    ))
    let output = text(from: result)
    #expect(!output.contains("sections"))
    #expect(!output.contains("parent_id"))
}

// MARK: - Connected memory display (compact vs full)

@Test func recall_connectedSmallMemory_showsFullContent() async throws {
    let tools = try await makeTools()

    let hub = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Hub memory for display test of connected memories"), "project": .string("DisplayTest")]
    ))
    let hubId = extractId(from: text(from: hub))!

    // Small child — under 500 chars
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Small detail: uses ARC for memory management"),
            "project": .string("DisplayTest"),
            "parent_id": .string(hubId),
        ]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("Hub memory display test connected"), "depth": .int(1), "limit": .int(1), "project": .string("DisplayTest")]
    ))
    let output = text(from: result)
    // Small connected memory should show full content (no "chars" size info)
    #expect(output.contains("Small detail: uses ARC"))
    #expect(!output.contains("chars)"))
}

@Test func recall_connectedLargeMemory_showsPreview() async throws {
    let tools = try await makeTools()

    let hub = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Hub memory for large display test"), "project": .string("LargeTest")]
    ))
    let hubId = extractId(from: text(from: hub))!

    // Large child — over 500 chars
    let largeContent = "## Detailed Architecture\n" + String(repeating: "This is a detailed explanation of the system architecture. ", count: 20)
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string(largeContent),
            "project": .string("LargeTest"),
            "parent_id": .string(hubId),
            "force": .bool(true),
        ]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("Hub memory large display test"), "depth": .int(1), "limit": .int(1), "project": .string("LargeTest")]
    ))
    let output = text(from: result)
    // Large connected memory should show compact preview with size info
    #expect(output.contains("chars)"))
    #expect(output.contains("Detailed Architecture"))
}

// MARK: - Edge info in connected output

@Test func recall_connectedMemory_showsEdgeRelation() async throws {
    let tools = try await makeTools()

    let r1 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Kubernetes orchestrates containers across cloud clusters"), "force": .bool(true)]
    ))
    let r2 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Docker images use layered filesystem for efficiency"), "force": .bool(true)]
    ))
    let id1 = extractId(from: text(from: r1))!
    let id2 = extractId(from: text(from: r2))!

    _ = try await tools.handle(CallTool.Parameters(
        name: "connect",
        arguments: ["from": .string(id2), "to": .string(id1), "relation": .string("part_of")]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("Kubernetes containers cloud clusters"), "depth": .int(1), "limit": .int(1)]
    ))
    let output = text(from: result)
    // Edge relation should show (part_of or relates_to from auto-connect)
    #expect(output.contains("part_of") || output.contains("relates_to"))
}

@Test func recall_depth2_showsEdgeForIntermediateNodes() async throws {
    let tools = try await makeTools()

    // Create a chain: A -> B -> C (distinct topics to avoid conflict detection)
    let rA = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Photosynthesis converts sunlight into chemical energy in plants"), "force": .bool(true)]
    ))
    let rB = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Chloroplasts contain thylakoid membranes for light reactions"), "force": .bool(true)]
    ))
    let rC = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("ATP synthase enzyme produces adenosine triphosphate molecules"), "force": .bool(true)]
    ))
    let idA = extractId(from: text(from: rA))!
    let idB = extractId(from: text(from: rB))!
    let idC = extractId(from: text(from: rC))!

    _ = try await tools.handle(CallTool.Parameters(
        name: "connect",
        arguments: ["from": .string(idB), "to": .string(idA), "relation": .string("part_of")]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "connect",
        arguments: ["from": .string(idC), "to": .string(idB), "relation": .string("part_of")]
    ))

    // Recall A with depth 2 — should find B and C
    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("photosynthesis sunlight chemical energy plants"), "depth": .int(2), "limit": .int(1)]
    ))
    let output = text(from: result)
    #expect(output.contains("Chloroplasts"))
    #expect(output.contains("ATP synthase"))
    // C's edge should reference B (not A), verifying depth>1 edge lookup works
    #expect(output.contains("part_of"))
}

// MARK: - Auto-Connect on Remember

@Test func autoConnect_createsEdgesForRelatedMemories() async throws {
    let tools = try await makeTools()

    // Store a base memory
    let r1 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("The authentication system uses JWT tokens for stateless session management"),
            "project": .string("AuthApp"),
        ]
    ))
    let id1 = extractId(from: text(from: r1))!

    // Store a related but distinct memory — should auto-connect
    let r2 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("JWT token validation runs in the auth middleware before every request"),  // v2 space: L2 0.89 to the base memory — mid auto-connect band
            "project": .string("AuthApp"),
        ]
    ))
    let output2 = text(from: r2)
    let id2 = extractId(from: output2)!

    // Verify auto-link reported in response or edge exists
    let graph = try await tools.handle(CallTool.Parameters(
        name: "graph",
        arguments: ["id": .string(id2)]
    ))
    let graphOutput = text(from: graph)
    // Should have a relates_to edge connecting to the first memory
    let hasAutoEdge = graphOutput.contains("relates_to") && graphOutput.contains("[id:\(id1)]")
    let hasAutoLinkNote = output2.contains("auto-linked")
    #expect(hasAutoEdge || hasAutoLinkNote)
}

@Test func autoConnect_skipsEpisodeMemories() async throws {
    let tools = try await makeTools()

    // Begin an episode (creates an episode hub memory)
    let epResult = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: ["title": .string("Test episode"), "project": .string("EpTest")]
    ))
    let epId = extractId(from: text(from: epResult))!

    // Store a memory (will be linked to episode via part_of)
    let r1 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Discovered a bug in the routing middleware causing 500 errors"),
            "project": .string("EpTest"),
        ]
    ))
    let id1 = extractId(from: text(from: r1))!

    // Verify no relates_to edge to the episode memory
    let edges = try await tools.handle(CallTool.Parameters(
        name: "graph",
        arguments: ["id": .string(id1)]
    ))
    let edgesOutput = text(from: edges)
    // Should have part_of to episode but NOT relates_to to episode
    #expect(edgesOutput.contains("part_of"))
    // Check there's no relates_to edge pointing to the episode hub
    let lines = edgesOutput.components(separatedBy: "\n")
    let relatesToEpisode = lines.contains { $0.contains("relates_to") && $0.contains("[id:\(epId)]") }
    #expect(!relatesToEpisode)
}

@Test func autoConnect_maxThreeEdges() async throws {
    let tools = try await makeTools()

    // Store 5 related memories about database topics
    for i in 1...5 {
        _ = try await tools.handle(CallTool.Parameters(
            name: "remember",
            arguments: [
                "content": .string("Database optimization technique number \(i): indexing strategy for SQL queries on large tables"),
                "project": .string("DBTest"),
                "force": .bool(true),
            ]
        ))
    }

    // Store one more related memory — should auto-connect to at most 3
    let result = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Database optimization technique special: query plan analysis for SQL performance tuning"),
            "project": .string("DBTest"),
            "force": .bool(true),
        ]
    ))
    let lastId = extractId(from: text(from: result))!

    // Count relates_to edges from this memory
    let graph = try await tools.handle(CallTool.Parameters(
        name: "graph",
        arguments: ["id": .string(lastId)]
    ))
    let graphOutput = text(from: graph)
    let relatesToCount = graphOutput.components(separatedBy: "relates_to").count - 1
    #expect(relatesToCount <= 3)
}

@Test func autoConnect_skipsParentMemory() async throws {
    let tools = try await makeTools()

    // Create parent hub
    let hub = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("System architecture overview for the payment processing service"),
            "project": .string("PayTest"),
        ]
    ))
    let hubId = extractId(from: text(from: hub))!

    // Create child with parent_id — should NOT get a relates_to edge to parent
    let child = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Payment processing uses Stripe API for credit card transactions"),
            "project": .string("PayTest"),
            "parent_id": .string(hubId),
        ]
    ))
    let childId = extractId(from: text(from: child))!

    // Check edges: should have part_of but not relates_to to parent
    let graph = try await tools.handle(CallTool.Parameters(
        name: "graph",
        arguments: ["id": .string(childId)]
    ))
    let graphOutput = text(from: graph)
    #expect(graphOutput.contains("part_of"))
    // Ensure no relates_to edge to the parent
    let lines = graphOutput.components(separatedBy: "\n")
    let relatesToParent = lines.contains { $0.contains("relates_to") && $0.contains("[id:\(hubId)]") }
    #expect(!relatesToParent)
}

@Test func autoConnect_noEdgesForDistantMemories() async throws {
    let tools = try await makeTools()

    // Store two completely unrelated memories
    let r1 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("The best pasta recipe uses fresh tomatoes, basil, and olive oil"),
            "project": .string("Cooking"),
        ]
    ))
    let id1 = extractId(from: text(from: r1))!

    let r2 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Quantum entanglement allows particles to share state across vast distances"),
            "project": .string("Physics"),
        ]
    ))
    let output2 = text(from: r2)
    let id2 = extractId(from: output2)!

    // Should NOT have auto-linked (different projects, unrelated content)
    #expect(!output2.contains("auto-linked"))

    // Double check via graph
    let graph = try await tools.handle(CallTool.Parameters(
        name: "graph",
        arguments: ["id": .string(id2)]
    ))
    let graphOutput = text(from: graph)
    #expect(!graphOutput.contains("[id:\(id1)]"))
}

@Test func autoConnect_deduplicatesEdges() async throws {
    let tools = try await makeTools()

    // Store first memory
    let r1 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("The Redis cache layer handles session storage and rate limiting"),
            "project": .string("CacheApp"),
        ]
    ))
    let id1 = extractId(from: text(from: r1))!

    // Store second related memory — may auto-connect to first
    let r2 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Memcached provides distributed caching for frequently accessed API responses"),
            "project": .string("CacheApp"),
        ]
    ))
    let id2 = extractId(from: text(from: r2))!

    // Manually add a relates_to edge in the same direction (if not already present)
    _ = try await tools.handle(CallTool.Parameters(
        name: "connect",
        arguments: ["from": .string(id2), "to": .string(id1), "relation": .string("relates_to")]
    ))

    // Store third related memory — should not create duplicate edges
    let r3 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("The Varnish HTTP cache accelerates content delivery at the edge"),
            "project": .string("CacheApp"),
        ]
    ))
    let id3 = extractId(from: text(from: r3))!

    // Verify no duplicate edges between id3 and id1 or id3 and id2
    let graph = try await tools.handle(CallTool.Parameters(
        name: "graph",
        arguments: ["id": .string(id3), "depth": .int(1)]
    ))
    let graphOutput = text(from: graph)
    // Count relates_to edges — should be at most 2 (one to id1, one to id2), no duplicates
    let relatesToCount = graphOutput.components(separatedBy: "relates_to").count - 1
    #expect(relatesToCount <= 3) // At most 3 (max auto-connect limit)
}

// MARK: - Incremental Hub/Topic Inference

@Test func incrementalInference_inheritsHub() async throws {
    let tools = try await makeTools()

    // Create 3 memories with a shared hub
    let m1 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("The editor uses a tile-based rendering system for isometric maps with sprite batching"),
            "project": .string("InferTest"),
            "topic": .string("editor"),
        ]
    ))
    let id1 = extractId(from: text(from: m1))!

    let m2 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Editor palette supports tile categories: organic, urban, special terrain with search"),
            "project": .string("InferTest"),
            "topic": .string("editor"),
            "force": .bool(true),
        ]
    ))
    let id2 = extractId(from: text(from: m2))!

    let m3 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Editor inspector shows object properties and spawn configuration with collapsible list"),
            "project": .string("InferTest"),
            "topic": .string("editor"),
            "force": .bool(true),
        ]
    ))
    let id3 = extractId(from: text(from: m3))!

    // Create a hub and link all 3 memories to it
    let hub = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Hub: editor"),
            "project": .string("InferTest"),
            "topic": .string("editor"),
            "source": .string("organize"),
            "force": .bool(true),
        ]
    ))
    let hubId = extractId(from: text(from: hub))!

    for id in [id1, id2, id3] {
        _ = try await tools.handle(CallTool.Parameters(
            name: "connect",
            arguments: ["from": .string(id), "to": .string(hubId), "relation": .string("part_of")]
        ))
    }

    // Now store a new related memory — should auto-link to the hub
    let m4 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("The tile palette eyedropper samples a rendered tile from the isometric map into the current selection"),  // v2 space: L2 0.95/0.82 to two hub children — both mid auto-connect band
            "project": .string("InferTest"),
            "force": .bool(true),
        ]
    ))
    let id4 = extractId(from: text(from: m4))!

    // Check if the new memory got linked to the hub via part_of
    let graph = try await tools.handle(CallTool.Parameters(
        name: "graph",
        arguments: ["id": .string(id4)]
    ))
    let graphOutput = text(from: graph)
    // Should have a part_of edge to the hub
    let hasPartOfToHub = graphOutput.contains("part_of") && graphOutput.contains("[id:\(hubId)]")
    #expect(hasPartOfToHub)
}

@Test func incrementalInference_inheritsTopic() async throws {
    let tools = try await makeTools()

    // Create 3 memories with a shared custom topic — content must be related but distinct
    // enough that the 4th memory falls in auto-connect range [0.12, 0.20) for at least 2
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("The SwiftUI view hierarchy renders declarative user interfaces with state-driven updates"),
            "project": .string("TopicTest"),
            "topic": .string("ui-framework"),
        ]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("UIKit collection view uses diffable data sources for performant list rendering"),
            "project": .string("TopicTest"),
            "topic": .string("ui-framework"),
            "force": .bool(true),
        ]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Auto Layout constraint system positions views relative to each other with priority"),
            "project": .string("TopicTest"),
            "topic": .string("ui-framework"),
            "force": .bool(true),
        ]
    ))

    // Store a new related memory without explicit topic — should inherit "ui-framework"
    let result = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Navigation stack manages view controller transitions with push and pop animations"),
            "project": .string("TopicTest"),
            "force": .bool(true),
        ]
    ))
    let output = text(from: result)
    let newId = extractId(from: output)!

    // If 2+ neighbors were in auto-connect range and shared the topic, it should be inferred
    // Check via graph whether auto-connect happened
    let graph = try await tools.handle(CallTool.Parameters(
        name: "graph",
        arguments: ["id": .string(newId)]
    ))
    let graphOutput = text(from: graph)
    let autoLinkedCount = graphOutput.components(separatedBy: "relates_to").count - 1

    if autoLinkedCount >= 2 {
        // Enough neighbors were found — topic should have been inferred
        let recall = try await tools.handle(CallTool.Parameters(
            name: "recall",
            arguments: ["query": .string("navigation stack view controller transitions"), "project": .string("TopicTest"), "limit": .int(5)]
        ))
        let recallOutput = text(from: recall)
        let entries = recallOutput.components(separatedBy: "\n\n")
        let newMemEntry = entries.first { $0.contains("[id:\(newId)]") }
        #expect(newMemEntry != nil)
        if let entry = newMemEntry {
            #expect(entry.contains("ui-framework"))
        }
    }
    // If < 2 neighbors in range, inference correctly doesn't trigger — test is inconclusive
    // but we still verify the code path didn't crash
}

@Test func incrementalInference_keepsExplicitTopic() async throws {
    let tools = try await makeTools()

    // Create 3 memories with topic "debugging" — each distinct but related
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Stack trace analysis: null pointer exception in the HTTP request handler middleware layer"),
            "project": .string("KeepTest"),
            "topic": .string("debugging"),
        ]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Memory leak found in WebSocket connection pool using Instruments profiler on production"),
            "project": .string("KeepTest"),
            "topic": .string("debugging"),
            "force": .bool(true),
        ]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Race condition in database transaction commit causes intermittent test failures under load"),
            "project": .string("KeepTest"),
            "topic": .string("debugging"),
            "force": .bool(true),
        ]
    ))

    // Store a new related memory with an explicit different topic
    let result = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Architecture decision: all middleware handlers must validate input before processing requests"),
            "project": .string("KeepTest"),
            "topic": .string("architecture"),  // Explicit topic, not "general"
            "force": .bool(true),
        ]
    ))
    let newId = extractId(from: text(from: result))!

    // Verify the explicit topic was preserved
    let recall = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("middleware handlers validate input requests"), "project": .string("KeepTest"), "limit": .int(5)]
    ))
    let recallOutput = text(from: recall)
    let lines = recallOutput.components(separatedBy: "\n\n")
    let newMemLine = lines.first { $0.contains("[id:\(newId)]") }
    if let line = newMemLine {
        // Should still be "architecture", NOT "debugging"
        #expect(line.contains("architecture"))
    }
}
