@testable import EngramKit
import EngramModels
import EngramMemoryCore
import Foundation
import Lattice
import MCP
import Testing

@Suite("Aggregate read semantics and statement budgets", .serialized)
struct AggregateReadTests {
    private struct NoEmbedding: Embedder {
        var dimension: Int { 384 }
        func embed(text: String) async throws -> [Float]? {
            Issue.record("Aggregate reads must not request embeddings")
            return nil
        }
    }

    private struct Fixture {
        let tools: MemoryTools
        let local: Lattice
        let synced: Lattice
        let group: Lattice
        let me: UUID
        func close() { local.close(); synced.close(); group.close() }
    }

    private func fixture() throws -> Fixture {
        let directory = try testFixtureDirectory().appendingPathComponent("aggregate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let local = try Lattice(Memory.self, Edge.self, SyncConfig.self,
            configuration: .init(fileURL: directory.appendingPathComponent("local.sqlite")))
        let synced = try Lattice(Memory.self, Edge.self,
            configuration: .init(fileURL: directory.appendingPathComponent("synced.sqlite")))
        let groupPath = directory.appendingPathComponent("group.sqlite")
        let group = try Lattice(Memory.self, Edge.self, GroupProjectMap.self,
            configuration: .init(fileURL: groupPath))
        let me = UUID()
        let tools = MemoryTools(localRef: local.sendableReference, syncedRef: synced.sendableReference,
            groupRefs: [.init(groupId: UUID(), path: groupPath.path, ref: group.sendableReference)],
            embedder: NoEmbedding(), identity: StaticIdentityProvider(.init(id: me, kind: .user)))
        return Fixture(tools: tools, local: local, synced: synced, group: group, me: me)
    }

    @Test func exactOutputRetainsExpiredPrivateRowsAndExcludesTombstonesAndForeignRows() async throws {
        let f = try fixture(); defer { f.close() }
        try f.local.add(Memory(content: "private expired fixture", topic: "zeta", project: "p",
            expiresAt: .distantPast, isPrivate: true, authorUserId: f.me))
        try f.local.add(Memory(content: "legacy fixture", topic: "alpha", project: "p"))
        try f.group.add(Memory(content: "foreign fixture", topic: "hidden", project: "p", authorUserId: UUID()))
        try f.local.add(Memory(content: "deleted fixture", topic: "deleted", project: "p", deletedAt: Date()))
        await f.tools.setForeignContentPolicy(fence: true, exclude: true)
        let stats = try await f.tools.handle(.init(name: "stats", arguments: nil))
        #expect(text(from: stats) == "Total memories: 2\n\nBy project:\n  p: 2\n\nBy topic:\n  alpha: 1\n  zeta: 1")
        let topics = try await f.tools.handle(.init(name: "list_topics", arguments: ["project": .string("p")]))
        #expect(text(from: topics) == "Topics for project 'p':\nalpha: 1 memories\nzeta: 1 memories")
    }

    @Test func canonicalProjectUnionAndOverlappingCopiesKeepExistingCounts() async throws {
        let f = try fixture(); defer { f.close() }
        let teammate = UUID(), shared = UUID()
        try f.local.add(SyncConfig(project: "mine", policy: .sync))
        try f.group.add(GroupProjectMap(memberUserId: f.me, localProject: "mine", groupProject: "canonical"))
        try f.group.add(GroupProjectMap(memberUserId: teammate, localProject: "theirs", groupProject: "canonical"))
        try f.local.add(Memory(content: "shared fixture", topic: "alpha", project: "mine"), preservingGlobalId: shared)
        try f.synced.add(Memory(content: "shared fixture", topic: "alpha", project: "mine"), preservingGlobalId: shared)
        try f.group.add(Memory(content: "mapped teammate", topic: "beta", project: "theirs", authorUserId: teammate))
        try f.group.add(Memory(content: "unrelated fixture", topic: "other", project: "other"))
        await f.tools.setForeignContentPolicy(fence: false, exclude: false)
        let stats = try await f.tools.handle(.init(name: "stats", arguments: ["project": .string("mine")]))
        #expect(text(from: stats) == "Total memories: 2\n\nBy topic:\n  alpha: 1\n  beta: 1")
        let topics = try await f.tools.handle(.init(name: "list_topics", arguments: ["project": .string("mine")]))
        #expect(text(from: topics) == "Topics for project 'mine':\nalpha: 1 memories\nbeta: 1 memories")
    }

    @Test func manyGroupsDoNotIntroducePerGroupQueries() async throws {
        let f = try fixture(); defer { f.close() }
        try f.local.transaction {
            for index in 0..<120 {
                try f.local.add(Memory(content: String(repeating: "synthetic payload ", count: 128),
                    topic: "topic-\(index)", project: "project-\(index)"))
            }
        }
        let budget = try await f.tools.aggregateFixtureBudget()
        #expect(budget.stats <= 4, "Stats must not issue one count per project/topic")
        #expect(budget.topics <= 2, "Topics must not issue one count per topic")
        #expect(budget.topicLines == 121)
    }

    @Test func emptyAggregateOutputRemainsExact() async throws {
        let f = try fixture(); defer { f.close() }
        for name in ["stats", "list_topics"] {
            let result = try await f.tools.handle(.init(name: name, arguments: nil))
            #expect(text(from: result) == "No memories stored.")
            #expect(result.isError != true)
        }
    }
}

private extension MemoryTools {
    func aggregateFixtureBudget() throws -> (stats: UInt64, topics: UInt64, topicLines: Int) {
        try prepareStorage()
        _ = try handleStats(nil) // Warm route/schema setup, outside the measured work.
        let before = Lattice.threadSQLStatementCount
        _ = try handleStats(nil)
        let stats = Lattice.threadSQLStatementCount - before
        let topicsBefore = Lattice.threadSQLStatementCount
        let topics = try handleListTopics(nil)
        let topicStatements = Lattice.threadSQLStatementCount - topicsBefore
        return (stats, topicStatements, EngramTests.text(from: topics).split(separator: "\n").count)
    }
}
