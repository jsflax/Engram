import Testing
@testable import EngramKit
import EngramMemoryCore
import EngramModels
import Lattice
import MCP
import Foundation
import SQLite3

@Suite("DerivationReplicaPrivacy")
struct DerivationReplicaPrivacyTests {
    private struct FixtureEmbedder: Embedder {
        var dimension: Int { 384 }
        func embed(text: String) async throws -> [Float]? { [1] + Array(repeating: 0, count: 383) }
    }
    private actor PausedEmbedder: Embedder {
        var dimension: Int { 384 }
        private var started = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var release: CheckedContinuation<Void, Never>?
        func embed(text: String) async throws -> [Float]? {
            started = true
            waiters.forEach { $0.resume() }; waiters.removeAll()
            await withCheckedContinuation { release = $0 }
            return [1] + Array(repeating: 0, count: 383)
        }
        func wait() async { if !started { await withCheckedContinuation { waiters.append($0) } } }
        func resume() { release?.resume(); release = nil }
    }
    private struct Fixture {
        let tools: MemoryTools
        let stores: [String: Lattice]
        let me: UUID
        let a: UUID
        let b: UUID
    }
    private func fixture(embedder: any Embedder = FixtureEmbedder(), alias: Bool = false, localOnly: Bool = false) throws -> Fixture {
        let directory = try testFixtureDirectory().appendingPathComponent("replica-privacy-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var stores: [String: Lattice] = [:]
        for name in ["local", "synced", "a", "b"] {
            stores[name] = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self,
                                      SyncConfig.self, GroupProjectMap.self,
                                      configuration: .init(fileURL: directory.appendingPathComponent("\(name).sqlite"), busyTimeoutMs: 100))
        }
        let me = UUID(), a = UUID(), b = UUID()
        let refs = [("a", a), (alias ? "a" : "b", b)].map { name, id in
            MemoryTools.GroupSpokeRef(groupId: id, path: stores[name]!.configuration.fileURL.path, ref: stores[name]!.sendableReference)
        }
        return Fixture(tools: MemoryTools(localRef: stores["local"]!.sendableReference,
                                          syncedRef: localOnly ? nil : stores["synced"]!.sendableReference, groupRefs: localOnly ? [] : refs,
                                          embedder: embedder, identity: StaticIdentityProvider(.init(id: me, kind: .user))),
                       stores: stores, me: me, a: a, b: b)
    }
    @discardableResult private func seed(_ ctx: Fixture, _ store: String = "local", id: UUID = UUID(),
                                        privateValue: Bool = false, deleted: Bool = false,
                                        content: String? = nil, project: String = "p", author: UUID? = nil,
                                        episode: Bool = false) throws -> UUID {
        let memory = Memory(content: content ?? "Synthetic source \(id)", topic: episode ? "episode" : "original",
                            project: project, source: "synthetic", embedding: Vector<Float>([1] + Array(repeating: 0, count: 383)),
                            createdAt: Date(timeIntervalSince1970: 100), importance: 3, isPrivate: privateValue,
                            authorUserId: author ?? ctx.me, deletedAt: deleted ? Date() : nil)
        try ctx.stores[store]!.add(memory, preservingGlobalId: id)
        return id
    }
    private func invoke(_ operation: String, _ ctx: Fixture, ids: [UUID], force: Bool = true) async throws -> CallTool.Result {
        var args: [String: Value] = ["ids": .array(ids.map { .string($0.uuidString) })]
        if operation == "organize" { args["label"] = .string("Derived label"); args["summary"] = .string("Sensitive derived text") }
        else { args["content"] = .string("Sensitive derived text") }
        if operation == "consolidate" { args["force"] = .bool(force) }
        return try await ctx.tools.handle(CallTool.Parameters(name: operation, arguments: args))
    }
    private func unchanged(_ ctx: Fixture, count: Int = 2) throws {
        let db = try RawWriteLock(path: ctx.stores["local"]!.configuration.fileURL.path)
        defer { db.close() }
        #expect(try db.integer("SELECT COUNT(*) FROM Memory") == count)
        #expect(try db.integer("SELECT COUNT(*) FROM Memory WHERE content = 'Sensitive derived text' OR topic = 'Derived label' OR importance = 0 OR deletedAt IS NOT NULL") == 0)
        #expect(try db.integer("SELECT COUNT(*) FROM Edge") == 0)
    }
    private func refused(_ operation: String, _ ctx: Fixture, ids: [UUID]) async throws {
        do { #expect(try await invoke(operation, ctx, ids: ids).isError == true) }
        catch { #expect(!String(describing: error).contains("Sensitive derived text")) }
        try unchanged(ctx)
    }

    @Test(arguments: ["merge", "consolidate", "organize"])
    func privatePersonalReplicaIsNeverPublished(_ operation: String) async throws {
        let ctx = try fixture(), id = try seed(ctx), second = try seed(ctx)
        try seed(ctx, "synced", id: id, privateValue: true)
        let result = try await invoke(operation, ctx, ids: [id, second])
        if operation == "organize" { #expect(result.isError == true); try unchanged(ctx) }
        else {
            #expect(result.isError != true)
            let summary = try #require(ctx.stores["local"]!.objects(Memory.self).where { $0.content == "Sensitive derived text" }.first)
            #expect(summary.isPrivate)
        }
        #expect(ctx.stores["synced"]!.objects(Memory.self).where { $0.globalId == id }.first?.importance == 3)
    }
    @Test(arguments: ["merge", "consolidate", "organize"], [false, true])
    func hiddenGroupPrivateOrTombstoneRefuses(_ operation: String, tombstone: Bool) async throws {
        let ctx = try fixture(), id = try seed(ctx), second = try seed(ctx)
        try ctx.stores["local"]!.add(SyncConfig(project: "p", policy: .local, exposedTeams: [ctx.a.uuidString]))
        try seed(ctx, "a", id: id, privateValue: !tombstone, deleted: tombstone)
        try await refused(operation, ctx, ids: [id, second])
    }
    @Test(arguments: ["merge", "consolidate", "organize"], ["content", "project", "author"])
    func conflictingReplicasCannotUseFirstCopy(_ operation: String, field: String) async throws {
        let ctx = try fixture(), id = try seed(ctx), second = try seed(ctx)
        try seed(ctx, "synced", id: id, content: field == "content" ? "Conflicting input" : nil,
                 project: field == "project" ? "different" : "p", author: field == "author" ? UUID() : ctx.me)
        try await refused(operation, ctx, ids: [id, second])
    }
    @Test(arguments: ["merge", "consolidate", "organize"])
    func identicalReplicasDoNotMultiplyMutationTargets(_ operation: String) async throws {
        let ctx = try fixture(), ids = try [seed(ctx), seed(ctx)]
        for id in ids { try seed(ctx, "synced", id: id) }
        #expect(try await invoke(operation, ctx, ids: ids).isError != true)
        #expect(ctx.stores["local"]!.objects(Memory.self).where { $0.content == "Sensitive derived text" }.count == 1)
        let copies = ctx.stores["synced"]!.objects(Memory.self).snapshot()
        #expect(copies.count == 2)
        #expect(copies.allSatisfy { $0.importance == 3 && $0.topic == "original" && $0.deletedAt == nil })
        if operation != "merge" { #expect(ctx.stores["local"]!.objects(Edge.self).count == 2) }
    }
    @Test(arguments: ["merge", "consolidate", "organize"], [false, true])
    func lateReplicaPrivacyChangeRefuses(_ operation: String, initiallyPrivate: Bool) async throws {
        let pause = PausedEmbedder(), ctx = try fixture(embedder: pause)
        let ids = try [seed(ctx, privateValue: initiallyPrivate), seed(ctx, privateValue: initiallyPrivate)]
        for id in ids { try seed(ctx, "synced", id: id, privateValue: initiallyPrivate) }
        let pending = Task { try await invoke(operation, ctx, ids: ids) }
        await pause.wait()
        ctx.stores["synced"]!.objects(Memory.self).where { $0.globalId == ids[0] }.first?.isPrivate = !initiallyPrivate
        await pause.resume()
        #expect(try await pending.value.isError == true)
        try unchanged(ctx)
    }
    @Test(arguments: ["merge", "consolidate", "organize"], ["appears", "disappears", "revoked-empty-spoke", "replaced-empty-spoke"])
    func lateReplicaOrStoreSetChangeRefuses(_ operation: String, change: String) async throws {
        let pause = PausedEmbedder(), ctx = try fixture(embedder: pause), ids = try [seed(ctx), seed(ctx)]
        if change == "disappears" { try seed(ctx, "synced", id: ids[0]) }
        let pending = Task { try await invoke(operation, ctx, ids: ids) }
        await pause.wait()
        if change == "appears" { try seed(ctx, "synced", id: ids[0], privateValue: true) }
        else if change == "disappears" { ctx.stores["synced"]!.delete(Memory.self, where: { $0.globalId == ids[0] }) }
        else {
            let path = ctx.stores["b"]!.configuration.fileURL
            try FileManager.default.moveItem(at: path, to: path.appendingPathExtension("revoked"))
            if change == "replaced-empty-spoke" { try Data().write(to: path) }
        }
        await pause.resume()
        #expect(try await pending.value.isError == true)
        try unchanged(ctx)
    }
    @Test(arguments: ["merge", "consolidate", "organize"])
    func ambiguousStoreAudienceRefuses(_ operation: String) async throws {
        let ctx = try fixture(alias: true), ids = try [seed(ctx), seed(ctx)]
        try await refused(operation, ctx, ids: ids)
    }
    @Test(arguments: ["merge", "consolidate", "organize"])
    func duplicateInputIDsRefuse(_ operation: String) async throws {
        let ctx = try fixture(), id = try seed(ctx), second = try seed(ctx)
        try await refused(operation, ctx, ids: [id, id, second])
    }
    @Test(arguments: ["merge", "consolidate", "organize"])
    func nonSelectedStoreFailureRefuses(_ operation: String) async throws {
        let ctx = try fixture(), ids = try [seed(ctx), seed(ctx)]
        try await ctx.tools.prepareStorage()
        let path = ctx.stores["synced"]!.configuration.fileURL
        try replicaSQL(path, "ALTER TABLE Memory RENAME TO HeldMemory")
        defer { try? replicaSQL(path, "ALTER TABLE HeldMemory RENAME TO Memory") }
        try await refused(operation, ctx, ids: ids)
    }
    @Test(arguments: ["merge", "consolidate", "organize"])
    func noRemoteStoresConfiguredRemainsUsable(_ operation: String) async throws {
        let ctx = try fixture(localOnly: true), ids = try [seed(ctx), seed(ctx)]
        #expect(try await invoke(operation, ctx, ids: ids).isError != true)
        #expect(ctx.stores["local"]!.objects(Memory.self).where { $0.content == "Sensitive derived text" && !$0.isPrivate }.count == 1)
    }
    @Test(arguments: ["merge", "consolidate", "organize"], ["synced", "a"])
    func missingConfiguredStoreBeforeFirstResolve(_ operation: String, missing: String) async throws {
        for readFirst in [false, true] {
            let ctx = try fixture(), id = try seed(ctx), second = try seed(ctx)
            try seed(ctx, missing, id: id, privateValue: true)
            let path = ctx.stores[missing]!.configuration.fileURL
            try FileManager.default.moveItem(at: path, to: path.appendingPathExtension("revoked"))
            if readFirst {
                // Legacy reads may omit unavailable stores, but caching that
                // partial bundle must not authorize a subsequent derivation.
                #expect(try await ctx.tools.handle(CallTool.Parameters(name: "stats")).isError != true)
            }
            try await refused(operation, ctx, ids: [id, second])
        }
    }
    @Test(arguments: ["synced", "a"])
    func missingConfiguredStoreStillAllowsSummaryFreeEpisodeClose(_ missing: String) async throws {
        let ctx = try fixture(), episode = try seed(ctx, episode: true), member = try seed(ctx)
        try seed(ctx, missing, id: member, privateValue: true)
        try ctx.stores["local"]!.add(Edge(sourceGlobalId: member, targetGlobalId: episode, relation: .partOf))
        let path = ctx.stores[missing]!.configuration.fileURL
        try FileManager.default.moveItem(at: path, to: path.appendingPathExtension("revoked"))
        #expect(try await ctx.tools.handle(CallTool.Parameters(name: "end_episode", arguments: ["episode_id": .string(episode.uuidString)])).isError != true)
        #expect(try await ctx.tools.handle(CallTool.Parameters(name: "end_episode", arguments: ["episode_id": .string(episode.uuidString), "summary": .string("Sensitive derived text")])).isError == true)
        #expect(ctx.stores["local"]!.objects(Memory.self).where { $0.globalId == episode }.first?.content == "Synthetic source \(episode)")
    }
    @Test func capturedInputsKeepOneScalarImageFromEveryStore() async throws {
        let ctx = try fixture(), id = UUID()
        for name in ["local", "synced", "a", "b"] { try seed(ctx, name, id: id) }
        try await ctx.tools.prepareStorage()
        try await inspectCapturedInputs(ctx.tools, id: id, paths: ctx.stores.values.map { $0.configuration.fileURL })
    }
    private func inspectCapturedInputs(_ tools: isolated MemoryTools, id: UUID, paths: [URL]) throws {
        let inputs = try tools.derivationSources([id])
        for path in paths {
            let writer = try Lattice(Memory.self, configuration: .init(fileURL: path))
            let row = try #require(writer.objects(Memory.self).where { $0.globalId == id }.first)
            row.content = "Later source"
            row.isPrivate = true
            row.project = "changed"
        }
        #expect(inputs.targets.count == 1)
        #expect(inputs.copies.count == 4)
        #expect(inputs.copies.allSatisfy {
            $0.memory.content == "Synthetic source \(id)" && !$0.memory.isPrivate && $0.memory.project == "p"
        })
        let fresh = try tools.derivationSources([id])
        #expect(fresh.copies.allSatisfy {
            $0.memory.content == "Later source" && $0.memory.isPrivate && $0.memory.project == "changed"
        })
    }
    @Test func sameGroupForeignConsolidationStillNeedsForce() async throws {
        let ctx = try fixture(), foreign = UUID()
        try ctx.stores["local"]!.add(SyncConfig(project: "p", policy: .local, exposedTeams: [ctx.a.uuidString]))
        let ids = try [seed(ctx, "a", author: foreign), seed(ctx, "a", author: foreign)]
        #expect(try await invoke("consolidate", ctx, ids: ids, force: false).isError == true)
        #expect(try await invoke("consolidate", ctx, ids: ids).isError != true)
        #expect(ctx.stores["local"]!.objects(Memory.self).where { $0.content == "Sensitive derived text" && !$0.isPrivate }.count == 1)
    }
    @Test func episodeConflictingReplicaRefusesButNoSummaryCanClose() async throws {
        let ctx = try fixture(), episode = try seed(ctx, episode: true), member = try seed(ctx)
        try seed(ctx, "synced", id: member, content: "Conflicting member")
        try ctx.stores["local"]!.add(Edge(sourceGlobalId: member, targetGlobalId: episode, relation: .partOf))
        #expect(try await ctx.tools.handle(CallTool.Parameters(name: "end_episode", arguments: ["episode_id": .string(episode.uuidString), "summary": .string("Sensitive derived text")])).isError == true)
        #expect(try await ctx.tools.handle(CallTool.Parameters(name: "end_episode", arguments: ["episode_id": .string(episode.uuidString)])).isError != true)
        #expect(ctx.stores["local"]!.objects(Memory.self).where { $0.globalId == episode }.first?.content == "Synthetic source \(episode)")
    }
}

private func replicaSQL(_ path: URL, _ statement: String) throws {
    var db: OpaquePointer?
    let opened = sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    defer { if let db { sqlite3_close(db) } }
    guard opened == SQLITE_OK, let db, sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "SyntheticSQLite", code: 1)
    }
}
