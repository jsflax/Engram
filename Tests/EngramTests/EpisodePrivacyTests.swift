import Testing
import EngramKit
import EngramMemoryCore
import EngramModels
import Lattice
import MCP
import Foundation
import SQLite3

@Suite("EpisodePrivacy")
struct EpisodePrivacyTests {
    private struct FixtureEmbedder: Embedder {
        var dimension: Int { 384 }
        func embed(text: String) async throws -> [Float]? {
            [1] + [Float](repeating: 0, count: 383)
        }
    }

    private struct Fixture {
        let tools: MemoryTools
        let stores: [String: Lattice]
        let me: UUID
        let groupA: UUID
        let groupB: UUID
    }

    private func fixture() throws -> Fixture {
        let directory = try testFixtureDirectory().appendingPathComponent("episode-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var stores: [String: Lattice] = [:]
        for name in ["local", "synced", "a", "b"] {
            stores[name] = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self,
                                      SyncConfig.self, GroupProjectMap.self,
                                      configuration: .init(fileURL: directory.appendingPathComponent("\(name).sqlite"), busyTimeoutMs: 100))
        }
        let me = UUID(), a = UUID(), b = UUID()
        let refs = [("a", a), ("b", b)].map { name, id in
            MemoryTools.GroupSpokeRef(groupId: id, path: stores[name]!.configuration.fileURL.path,
                                      ref: stores[name]!.sendableReference)
        }
        return Fixture(tools: MemoryTools(localRef: stores["local"]!.sendableReference,
                                          syncedRef: stores["synced"]!.sendableReference,
                                          groupRefs: refs, embedder: FixtureEmbedder(),
                                          identity: StaticIdentityProvider(.init(id: me, kind: .user))),
                       stores: stores, me: me, groupA: a, groupB: b)
    }

    private func seed(_ store: Lattice, episode: Bool = false, isPrivate: Bool = false,
                      author: UUID? = nil, deleted: Bool = false, id: UUID? = nil) throws -> UUID {
        let memory = Memory(content: episode ? "Synthetic episode" : "Synthetic member",
                            topic: episode ? "episode" : "original", project: "p",
                            isPrivate: isPrivate, authorUserId: author, deletedAt: deleted ? Date() : nil)
        if let id { try store.add(memory, preservingGlobalId: id) } else { try store.add(memory) }
        return try #require(memory.globalId)
    }

    private func link(_ store: Lattice, member: UUID, episode: UUID, deleted: Bool = false) throws {
        try store.add(Edge(sourceGlobalId: member, targetGlobalId: episode, relation: .partOf,
                           deletedAt: deleted ? Date() : nil))
    }

    private func finish(_ ctx: Fixture, episode: UUID?, summary: String? = "Synthetic sensitive summary") async throws -> CallTool.Result {
        var args: [String: Value] = [:]
        if let episode { args["episode_id"] = .string(episode.uuidString) }
        if let summary { args["summary"] = .string(summary) }
        return try await ctx.tools.handle(CallTool.Parameters(name: "end_episode", arguments: args))
    }

    private func row(_ ctx: Fixture, store: String = "local", id: UUID) throws -> Memory {
        try #require(ctx.stores[store]!.objects(Memory.self).where { $0.globalId == id }.first)
    }

    private func expectRefusal(_ result: CallTool.Result, episode: Memory) {
        #expect(result.isError == true)
        #expect(!text(from: result).contains("Synthetic sensitive summary"))
        #expect(episode.content == "Synthetic episode")
        #expect(episode.modifiedAt == nil)
    }

    private struct SQLiteFailure: Error { let code: Int32 }

    private func executeSQL(_ path: URL, _ statement: String) throws {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(path.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        defer { if let database { sqlite3_close(database) } }
        guard opened == SQLITE_OK, let database else { throw SQLiteFailure(code: opened) }
        let result = sqlite3_exec(database, statement, nil, nil, nil)
        guard result == SQLITE_OK else { throw SQLiteFailure(code: result) }
    }

    @Test(arguments: ["local", "synced", "a"], ["local", "synced"])
    func endEpisode_inheritsPrivateMembersAcrossEdgeStores(_ edgeStore: String, memberStore: String) async throws {
        let ctx = try fixture()
        let ep = try seed(ctx.stores["local"]!, episode: true, author: ctx.me)
        let member = try seed(ctx.stores[memberStore]!, isPrivate: true)
        try link(ctx.stores[edgeStore]!, member: member, episode: ep)
        let result = try await finish(ctx, episode: ep)
        #expect(result.isError != true)
        let saved = try row(ctx, id: ep)
        #expect(saved.isPrivate)
        #expect(saved.content.contains("Synthetic sensitive summary"))
        #expect(saved.authorUserId == ctx.me)
        #expect(saved.modifiedAt != nil)
    }

    @Test func endEpisode_privateEpisodeRemainsPrivate() async throws {
        let ctx = try fixture()
        let ep = try seed(ctx.stores["local"]!, episode: true, isPrivate: true)
        let member = try seed(ctx.stores["local"]!)
        try link(ctx.stores["local"]!, member: member, episode: ep)
        #expect(try await finish(ctx, episode: ep).isError != true)
        #expect(try row(ctx, id: ep).isPrivate)
    }

    @Test func endEpisode_mixedSharedRefusalKeepsActiveUntilClosedWithoutSummary() async throws {
        let ctx = try fixture()
        try ctx.stores["local"]!.add(SyncConfig(project: "p", policy: .sync, exposedTeams: [ctx.groupA.uuidString]))
        let begun = try await ctx.tools.handle(CallTool.Parameters(name: "begin_episode", arguments: [
            "project": .string("p"), "title": .string("Synthetic episode"),
        ]))
        let ep = try #require(extractId(from: text(from: begun)).flatMap(UUID.init(uuidString:)))
        let member = try seed(ctx.stores["local"]!, isPrivate: true)
        try link(ctx.stores["local"]!, member: member, episode: ep)
        expectRefusal(try await finish(ctx, episode: nil), episode: try row(ctx, id: ep))
        #expect(try await finish(ctx, episode: nil, summary: nil).isError != true)
        await #expect(throws: (any Error).self) { try await finish(ctx, episode: nil, summary: nil) }
    }

    @Test func endEpisode_groupDestinationUsesOwningSpokeNotLocalProjectExposure() async throws {
        let ctx = try fixture()
        try ctx.stores["local"]!.add(SyncConfig(project: "p", policy: .sync, exposedTeams: [ctx.groupB.uuidString]))
        let ep = try seed(ctx.stores["a"]!, episode: true, author: UUID())
        let member = try seed(ctx.stores["a"]!, author: UUID())
        try link(ctx.stores["a"]!, member: member, episode: ep)
        #expect(try await finish(ctx, episode: ep).isError != true)
        #expect(try row(ctx, store: "a", id: ep).content.contains("Synthetic sensitive summary"))
        #expect(ctx.stores["local"]!.objects(Memory.self).count == 0)
    }

    @Test func endEpisode_crossGroupDestinationRefuses() async throws {
        let ctx = try fixture()
        try ctx.stores["local"]!.add(SyncConfig(project: "p", policy: .sync, exposedTeams: [ctx.groupB.uuidString]))
        let ep = try seed(ctx.stores["a"]!, episode: true)
        let member = try seed(ctx.stores["b"]!)
        try link(ctx.stores["local"]!, member: member, episode: ep)
        expectRefusal(try await finish(ctx, episode: ep), episode: try row(ctx, store: "a", id: ep))
    }

    @Test(arguments: ["synced", "a"])
    func endEpisode_neverWritesPrivateSummaryDirectlyToRemoteStore(_ destination: String) async throws {
        let ctx = try fixture()
        let ep = try seed(ctx.stores[destination]!, episode: true, isPrivate: true, author: ctx.me)
        let member = try seed(ctx.stores["local"]!, isPrivate: true)
        try link(ctx.stores["local"]!, member: member, episode: ep)
        expectRefusal(try await finish(ctx, episode: ep), episode: try row(ctx, store: destination, id: ep))
    }

    @Test func endEpisode_foreignEpisodeCannotBeMadePrivate() async throws {
        let ctx = try fixture()
        let ep = try seed(ctx.stores["local"]!, episode: true, author: UUID())
        let member = try seed(ctx.stores["local"]!, isPrivate: true)
        try link(ctx.stores["local"]!, member: member, episode: ep)
        expectRefusal(try await finish(ctx, episode: ep), episode: try row(ctx, id: ep))
        #expect(try !row(ctx, id: ep).isPrivate)
    }

    @Test func endEpisode_foreignAlreadyPrivateEpisodeDoesNotRequirePrivacyFlip() async throws {
        let ctx = try fixture()
        let author = UUID()
        let ep = try seed(ctx.stores["local"]!, episode: true, isPrivate: true, author: author)
        let member = try seed(ctx.stores["local"]!, isPrivate: true)
        try link(ctx.stores["local"]!, member: member, episode: ep)
        #expect(try await finish(ctx, episode: ep).isError != true)
        #expect(try row(ctx, id: ep).authorUserId == author)
        #expect(try row(ctx, id: ep).isPrivate)
    }

    @Test(arguments: ["missing", "tombstoned-member", "tombstoned-link", "tombstoned-episode"])
    func endEpisode_removedInputsRefuseSummaryButAllowClose(_ damage: String) async throws {
        let ctx = try fixture()
        let ep = try seed(ctx.stores["local"]!, episode: true, deleted: damage == "tombstoned-episode")
        let member = damage == "missing" ? UUID() : try seed(ctx.stores["synced"]!, deleted: damage == "tombstoned-member")
        try link(ctx.stores["a"]!, member: member, episode: ep, deleted: damage == "tombstoned-link")
        expectRefusal(try await finish(ctx, episode: ep), episode: try row(ctx, id: ep))
        #expect(try await finish(ctx, episode: ep, summary: nil).isError != true)
    }

    @Test func endEpisode_privateReplicaCannotBeHiddenByPublicLocalCopy() async throws {
        let ctx = try fixture()
        let ep = try seed(ctx.stores["local"]!, episode: true, author: ctx.me)
        let member = try seed(ctx.stores["local"]!)
        _ = try seed(ctx.stores["synced"]!, isPrivate: true, id: member)
        try link(ctx.stores["local"]!, member: member, episode: ep)
        let result = try await finish(ctx, episode: ep)
        #expect(result.isError != true)
        #expect(try row(ctx, id: ep).isPrivate)
    }

    @Test(arguments: ["local", "synced", "a"])
    func endEpisode_busyDestinationDoesNotAppendSummary(_ destination: String) async throws {
        let ctx = try fixture()
        let ep = try seed(ctx.stores[destination]!, episode: true)
        try await ctx.tools.prepareStorage()
        // Open the owning handle before holding its lock; fixture setup is not
        // the mutation being tested. Closing by ID without text writes nothing.
        _ = try await finish(ctx, episode: ep, summary: nil)
        let path = ctx.stores[destination]!.configuration.fileURL
        let lock = try RawWriteLock(path: path.path)
        defer { lock.close() }
        try lock.acquire()
        let result = try await finish(ctx, episode: ep)
        lock.release()
        expectRefusal(result, episode: try row(ctx, store: destination, id: ep))
        guard case .object(let body) = result.structuredContent,
              case .object(let receipt) = body["engram_write_receipt"] else {
            Issue.record("Missing no-write receipt")
            return
        }
        #expect(receipt["write_outcome"] == .string("not_stored_transaction_not_started"))
        #expect(try await finish(ctx, episode: ep).isError != true)
    }

    @Test func endEpisode_failedSummaryRollsBackPrivacyAndRetainsActiveEpisode() async throws {
        let ctx = try fixture()
        let begun = try await ctx.tools.handle(CallTool.Parameters(name: "begin_episode", arguments: [
            "project": .string("p"), "title": .string("Synthetic episode"),
        ]))
        let ep = try #require(extractId(from: text(from: begun)).flatMap(UUID.init(uuidString:)))
        let member = try seed(ctx.stores["local"]!, isPrivate: true)
        try link(ctx.stores["local"]!, member: member, episode: ep)
        let path = ctx.stores["local"]!.configuration.fileURL
        try executeSQL(path, """
            CREATE TRIGGER fail_episode_summary BEFORE UPDATE OF content ON Memory
            BEGIN SELECT RAISE(ABORT, 'synthetic episode summary failure'); END
            """)
        await #expect(throws: (any Error).self) { try await finish(ctx, episode: nil) }
        // Verify committed bytes through an independent SQLite connection, so
        // cached model fields cannot hide a partial privacy/content update.
        let persisted = try RawWriteLock(path: path.path)
        defer { persisted.close() }
        #expect(try persisted.integer("SELECT COUNT(*) FROM Memory WHERE globalId = '\(ep.uuidString)' COLLATE NOCASE AND isPrivate = 0 AND content = 'Synthetic episode' AND modifiedAt IS NULL") == 1)
        try executeSQL(path, "DROP TRIGGER fail_episode_summary")
        #expect(try await finish(ctx, episode: nil).isError != true)
        #expect(try row(ctx, id: ep).isPrivate)
    }

    @Test(arguments: ["Edge", "Memory"], ["synced", "a"])
    func endEpisode_queryFailureCannotHidePrivateInputs(_ table: String, brokenStore: String) async throws {
        let ctx = try fixture()
        let ep = try seed(ctx.stores["local"]!, episode: true, author: ctx.me)
        if table == "Edge" {
            let member = try seed(ctx.stores["local"]!, isPrivate: true)
            try link(ctx.stores[brokenStore]!, member: member, episode: ep)
        } else {
            let member = try seed(ctx.stores["local"]!)
            _ = try seed(ctx.stores[brokenStore]!, isPrivate: true, id: member)
            try link(ctx.stores["local"]!, member: member, episode: ep)
        }
        try await ctx.tools.prepareStorage()
        let path = ctx.stores[brokenStore]!.configuration.fileURL
        try executeSQL(path, "ALTER TABLE \(table) RENAME TO Held\(table)")
        defer { try? executeSQL(path, "ALTER TABLE Held\(table) RENAME TO \(table)") }
        do {
            expectRefusal(try await finish(ctx, episode: ep), episode: try row(ctx, id: ep))
        } catch {
            // A thrown storage failure is also fail-closed. The checked
            // transaction already catches some secondary-store query errors.
            #expect(!String(describing: error).contains("Synthetic sensitive summary"))
        }
        let persisted = try RawWriteLock(path: ctx.stores["local"]!.configuration.fileURL.path)
        defer { persisted.close() }
        #expect(try persisted.integer("SELECT COUNT(*) FROM Memory WHERE globalId = '\(ep.uuidString)' COLLATE NOCASE AND isPrivate = 0 AND content = 'Synthetic episode' AND modifiedAt IS NULL") == 1)
    }

    @Test func endEpisode_policyReadFailureCannotEraseSharingScopes() async throws {
        let ctx = try fixture()
        try ctx.stores["local"]!.add(SyncConfig(project: "p", policy: .sync, exposedTeams: [ctx.groupA.uuidString]))
        try ctx.stores["local"]!.add(SyncConfig(project: "q", policy: .sync, exposedTeams: [ctx.groupB.uuidString]))
        let ep = try seed(ctx.stores["local"]!, episode: true)
        let member = try seed(ctx.stores["local"]!)
        try row(ctx, id: member).project = "q"
        try link(ctx.stores["local"]!, member: member, episode: ep)
        try await ctx.tools.prepareStorage()
        let path = ctx.stores["local"]!.configuration.fileURL
        try executeSQL(path, "ALTER TABLE SyncConfig RENAME TO HeldSyncConfig")
        defer { try? executeSQL(path, "ALTER TABLE HeldSyncConfig RENAME TO SyncConfig") }
        do {
            expectRefusal(try await finish(ctx, episode: ep), episode: try row(ctx, id: ep))
        } catch {
            #expect(!String(describing: error).contains("Synthetic sensitive summary"))
        }
        let persisted = try RawWriteLock(path: path.path)
        defer { persisted.close() }
        #expect(try persisted.integer("SELECT COUNT(*) FROM Memory WHERE globalId = '\(ep.uuidString)' COLLATE NOCASE AND isPrivate = 0 AND content = 'Synthetic episode' AND modifiedAt IS NULL") == 1)
    }
}
