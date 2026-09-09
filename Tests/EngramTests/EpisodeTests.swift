import Testing
import EngramKit
import Lattice
import MCP
import Foundation

// MARK: - Begin Episode

@Test func beginEpisode_basic() async throws {
    let tools = try await makeTools()
    let result = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: [
            "title": .string("Debugging race condition"),
            "project": .string("MyApp"),
        ]
    ))
    let output = text(from: result)
    #expect(output.contains("Created episode"))
    #expect(output.contains("Debugging race condition"))
    #expect(output.contains("project: MyApp"))
}

@Test func beginEpisode_autoTitle() async throws {
    let tools = try await makeTools()
    let result = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: nil
    ))
    let output = text(from: result)
    #expect(output.contains("Created episode"))
    #expect(output.contains("Session:"))
}

@Test func beginEpisode_closesActiveEpisode() async throws {
    let tools = try await makeTools()

    // Begin first episode
    _ = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: ["title": .string("First episode")]
    ))

    // Begin second — should close the first
    _ = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: ["title": .string("Second episode")]
    ))

    let list = try await tools.handle(CallTool.Parameters(
        name: "list_episodes",
        arguments: nil
    ))
    let output = text(from: list)
    #expect(output.contains("[ended]"))
    #expect(output.contains("[active]"))
    #expect(output.contains("First episode"))
    #expect(output.contains("Second episode"))
}

@Test func beginEpisode_isMemoryWithTopicEpisode() async throws {
    let tools = try await makeTools()
    let result = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: ["title": .string("Test episode"), "project": .string("TestProj")]
    ))
    let output = text(from: result)
    let id = extractEpisodeId(from: output)!

    // Episode should be discoverable through list_episodes (it's a Memory with topic "episode")
    let list = try await tools.handle(CallTool.Parameters(
        name: "list_episodes",
        arguments: ["project": .string("TestProj")]
    ))
    let listOutput = text(from: list)
    #expect(listOutput.contains("[id:\(id)]"))
    #expect(listOutput.contains("Test episode"))

    // Episode should be deletable via forget (it's just a Memory)
    _ = try await tools.handle(CallTool.Parameters(
        name: "forget",
        arguments: ["id": .string(id)]
    ))
    let listAfter = try await tools.handle(CallTool.Parameters(
        name: "list_episodes",
        arguments: nil
    ))
    #expect(text(from: listAfter) == "No episodes found.")
}

// MARK: - End Episode

@Test func endEpisode_basic() async throws {
    let tools = try await makeTools()
    _ = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: ["title": .string("Session to end")]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "end_episode",
        arguments: nil
    ))
    let output = text(from: result)
    #expect(output.contains("Ended episode"))
}

@Test func endEpisode_withSummary() async throws {
    let tools = try await makeTools()
    _ = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: ["title": .string("Summarized session")]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Found the bug in auth module")]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "end_episode",
        arguments: ["summary": .string("Fixed auth bug by correcting token expiry")]
    ))
    let output = text(from: result)
    #expect(output.contains("Ended episode"))
    #expect(output.contains("summary: Fixed auth bug"))
}

@Test func endEpisode_byId() async throws {
    let tools = try await makeTools()
    let r1 = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: ["title": .string("Episode to end by ID")]
    ))
    let epId = extractEpisodeId(from: text(from: r1))!

    let result = try await tools.handle(CallTool.Parameters(
        name: "end_episode",
        arguments: ["episode_id": .string(epId)]
    ))
    #expect(text(from: result).contains("Ended episode"))
}

@Test func endEpisode_noActive_throws() async throws {
    let tools = try await makeTools()
    await #expect(throws: (any Error).self) {
        try await tools.handle(CallTool.Parameters(
            name: "end_episode",
            arguments: nil
        ))
    }
}

@Test func endEpisode_notFound() async throws {
    let tools = try await makeTools()
    let result = try await tools.handle(CallTool.Parameters(
        name: "end_episode",
        arguments: ["episode_id": .string(UUID().uuidString)]
    ))
    #expect(result.isError == true)
    #expect(text(from: result).contains("not found"))
}

// MARK: - Episode Linking (part_of edges)

@Test func remember_withEpisode_createsPartOfEdge() async throws {
    let tools = try await makeTools()

    let r1 = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: ["title": .string("Edge test")]
    ))
    let epId = extractEpisodeId(from: text(from: r1))!

    let r2 = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Memory linked to episode")]
    ))
    let memOutput = text(from: r2)

    // Extract memory ID from "Stored memory (id: N, ..."
    let memId = extractMemoryId(from: memOutput)!

    // Check graph — memory should have part_of edge to episode
    let graph = try await tools.handle(CallTool.Parameters(
        name: "graph",
        arguments: ["id": .string(memId)]
    ))
    let graphOutput = text(from: graph)
    #expect(graphOutput.contains("part_of"))
    #expect(graphOutput.contains("[id:\(epId)]"))
}

@Test func remember_withoutEpisode_noEdge() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Memory without episode")]
    ))

    let list = try await tools.handle(CallTool.Parameters(
        name: "list_episodes",
        arguments: nil
    ))
    #expect(text(from: list) == "No episodes found.")
}

@Test func remember_afterEpisodeEnded_noEdge() async throws {
    let tools = try await makeTools()

    let r1 = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: ["title": .string("Ended episode")]
    ))
    let epId = extractEpisodeId(from: text(from: r1))!

    _ = try await tools.handle(CallTool.Parameters(
        name: "end_episode",
        arguments: ["summary": .string("Done")]
    ))

    // Remember after episode ended — should not link
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Post-episode memory")]
    ))

    // Episode should have 0 members
    let recall = try await tools.handle(CallTool.Parameters(
        name: "recall_episode",
        arguments: ["episode_id": .string(epId)]
    ))
    #expect(text(from: recall).contains("No memories in this episode"))
}

// This test controls time through a DEBUG-only MemoryTools seam.
#if DEBUG
@Test func explicitEpisode_gapClearsActive() async throws {
    let tools = try await makeTools()

    let r1 = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: ["title": .string("Gap test episode")]
    ))
    let epId = extractEpisodeId(from: text(from: r1))!

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Memory before gap")]
    ))

    // Simulate >30 min gap
    await tools.setLastMemoryTime(Date().addingTimeInterval(-3600))

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Memory after gap"), "force": .bool(true)]
    ))

    // Episode should have only 1 member (before gap)
    let recall = try await tools.handle(CallTool.Parameters(
        name: "recall_episode",
        arguments: ["episode_id": .string(epId)]
    ))
    #expect(text(from: recall).contains("Memories (1)"))
    #expect(text(from: recall).contains("Memory before gap"))
    #expect(!text(from: recall).contains("Memory after gap"))
}

#endif

// MARK: - Recall Episode

@Test func recallEpisode_basic() async throws {
    let tools = try await makeTools()
    let r1 = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: ["title": .string("Recall test episode")]
    ))
    let epId = extractEpisodeId(from: text(from: r1))!

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("First recall test memory")]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Second recall test memory"), "force": .bool(true)]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Third recall test memory"), "force": .bool(true)]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "recall_episode",
        arguments: ["episode_id": .string(epId)]
    ))
    let output = text(from: result)
    #expect(output.contains("## Episode: Recall test episode"))
    #expect(output.contains("Memories (3)"))
    #expect(output.contains("First recall test memory"))
    #expect(output.contains("Second recall test memory"))
    #expect(output.contains("Third recall test memory"))

    // Verify chronological order
    let firstRange = output.range(of: "First recall test")!
    let secondRange = output.range(of: "Second recall test")!
    let thirdRange = output.range(of: "Third recall test")!
    #expect(firstRange.lowerBound < secondRange.lowerBound)
    #expect(secondRange.lowerBound < thirdRange.lowerBound)
}

@Test func recallEpisode_withSummary() async throws {
    let tools = try await makeTools()
    let r1 = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: ["title": .string("Summary recall test")]
    ))
    let epId = extractEpisodeId(from: text(from: r1))!

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Memory in summarized episode")]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "end_episode",
        arguments: ["summary": .string("We did important things")]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "recall_episode",
        arguments: ["episode_id": .string(epId)]
    ))
    let output = text(from: result)
    #expect(output.contains("### Summary"))
    #expect(output.contains("We did important things"))
}

@Test func recallEpisode_empty() async throws {
    let tools = try await makeTools()
    let r1 = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: ["title": .string("Empty episode")]
    ))
    let epId = extractEpisodeId(from: text(from: r1))!

    let result = try await tools.handle(CallTool.Parameters(
        name: "recall_episode",
        arguments: ["episode_id": .string(epId)]
    ))
    let output = text(from: result)
    #expect(output.contains("No memories in this episode"))
}

@Test func recallEpisode_notFound() async throws {
    let tools = try await makeTools()
    let result = try await tools.handle(CallTool.Parameters(
        name: "recall_episode",
        arguments: ["episode_id": .string(UUID().uuidString)]
    ))
    #expect(result.isError == true)
    #expect(text(from: result).contains("not found"))
}

@Test func recallEpisode_withLimit() async throws {
    let tools = try await makeTools()

    let r1 = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: ["title": .string("Limited recall test")]
    ))
    let epId = extractEpisodeId(from: text(from: r1))!

    // Add 5 memories
    for i in 1...5 {
        _ = try await tools.handle(CallTool.Parameters(
            name: "remember",
            arguments: ["content": .string("Memory number \(i) for limit test"), "force": .bool(true)]
        ))
    }

    // Recall with limit=2 — should show 2 of 5 with truncation notice
    let result = try await tools.handle(CallTool.Parameters(
        name: "recall_episode",
        arguments: ["episode_id": .string(epId), "limit": .int(2)]
    ))
    let output = text(from: result)
    #expect(output.contains("2 of 5"))
    #expect(output.contains("Showing 2 of 5"))
    #expect(output.contains("Memory number 1"))
    #expect(output.contains("Memory number 2"))
    #expect(!output.contains("Memory number 3"))
}

// MARK: - List Episodes

@Test func listEpisodes_basic() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: ["title": .string("Episode Alpha")]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "end_episode",
        arguments: nil
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: ["title": .string("Episode Beta")]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "list_episodes",
        arguments: nil
    ))
    let output = text(from: result)
    #expect(output.contains("Episode Alpha"))
    #expect(output.contains("Episode Beta"))
}

@Test func listEpisodes_filterByProject() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: ["title": .string("ProjectA episode"), "project": .string("ProjectA")]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "end_episode",
        arguments: nil
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: ["title": .string("ProjectB episode"), "project": .string("ProjectB")]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "list_episodes",
        arguments: ["project": .string("ProjectA")]
    ))
    let output = text(from: result)
    #expect(output.contains("ProjectA episode"))
    #expect(!output.contains("ProjectB episode"))
}

@Test func listEpisodes_empty() async throws {
    let tools = try await makeTools()
    let result = try await tools.handle(CallTool.Parameters(
        name: "list_episodes",
        arguments: nil
    ))
    #expect(text(from: result) == "No episodes found.")
}

@Test func listEpisodes_showsMemoryCount() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: ["title": .string("Counted episode")]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Memory one in counted episode")]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Memory two in counted episode"), "force": .bool(true)]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "list_episodes",
        arguments: nil
    ))
    #expect(text(from: result).contains("2 memories"))
}

@Test func listEpisodes_orderByMostRecent() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: ["title": .string("Older episode")]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "end_episode",
        arguments: nil
    ))

    try await Task.sleep(for: .milliseconds(50))

    _ = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: ["title": .string("Newer episode")]
    ))

    let result = try await tools.handle(CallTool.Parameters(
        name: "list_episodes",
        arguments: nil
    ))
    let output = text(from: result)
    let newerRange = output.range(of: "Newer episode")!
    let olderRange = output.range(of: "Older episode")!
    #expect(newerRange.lowerBound < olderRange.lowerBound)
}

// MARK: - Cross-Project Episodes

@Test func explicitEpisode_crossProject_doesNotSplit() async throws {
    let tools = try await makeTools()

    _ = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: ["title": .string("Multi-project session"), "project": .string("X")]
    ))

    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("X memory"), "project": .string("X")]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Y memory"), "project": .string("Y"), "force": .bool(true)]
    ))
    _ = try await tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: ["content": .string("Z memory"), "project": .string("Z"), "force": .bool(true)]
    ))

    // Should still be one episode with all 3 memories
    let list = try await tools.handle(CallTool.Parameters(
        name: "list_episodes",
        arguments: nil
    ))
    let output = text(from: list)
    let lines = output.split(separator: "\n")
    #expect(lines.count == 1)
    #expect(output.contains("3 memories"))
    #expect(output.contains("Multi-project session"))
}

// MARK: - Deletion via forget

@Test func episode_deletableViaForget() async throws {
    let tools = try await makeTools()

    let r1 = try await tools.handle(CallTool.Parameters(
        name: "begin_episode",
        arguments: ["title": .string("Deletable episode")]
    ))
    let epId = extractEpisodeId(from: text(from: r1))!

    _ = try await tools.handle(CallTool.Parameters(
        name: "end_episode",
        arguments: nil
    ))

    // Delete the episode via forget — it's just a memory
    _ = try await tools.handle(CallTool.Parameters(
        name: "forget",
        arguments: ["id": .string(epId)]
    ))

    // Should be gone
    let list = try await tools.handle(CallTool.Parameters(
        name: "list_episodes",
        arguments: nil
    ))
    #expect(text(from: list) == "No episodes found.")
}
