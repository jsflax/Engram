import Testing
@testable import EngramKit
import EngramMemoryCore
import EngramModels
import Lattice
import MCP
import Foundation
import SQLite3

@Suite("DerivationRestrictions")
struct DerivationRestrictionTests {
    private struct FixtureEmbedder: Embedder {
        var dimension: Int { 384 }
        func embed(text: String) async throws -> [Float]? {
            [1] + [Float](repeating: 0, count: 383)
        }
    }

    private actor SuspendedEmbedder: Embedder {
        var dimension: Int { 384 }
        private var started = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var release: CheckedContinuation<Void, Never>?

        func embed(text: String) async throws -> [Float]? {
            started = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { release = $0 }
            return [1] + [Float](repeating: 0, count: 383)
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func resume() {
            release?.resume()
            release = nil
        }
    }

    private struct Fixture {
        let tools: MemoryTools
        let local: Lattice
        let groups: [UUID: Lattice]
    }

    private func fixture(exposures: [String: Set<String>] = [:], groups: [UUID] = [],
                         embedder: any Embedder = FixtureEmbedder()) throws -> Fixture {
        let directory = try testFixtureDirectory().appendingPathComponent("derivation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let localPath = directory.appendingPathComponent("local.sqlite")
        try MemoryOperationLedger.preflightLocalStore(at: localPath)
        let local = try Lattice(for: [Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self] + MemoryOperationLedger.localModels,
                                configuration: .init(fileURL: localPath, busyTimeoutMs: 100))
        try MemoryOperationLedger(lattice: local).bootstrapStoreID()
        for (project, audiences) in exposures {
            try local.add(SyncConfig(project: project, policy: .sync, exposedTeams: audiences))
        }
        var groupLattices: [UUID: Lattice] = [:]
        var refs: [MemoryTools.GroupSpokeRef] = []
        for group in groups {
            let path = directory.appendingPathComponent("group-\(group.uuidString).sqlite")
            let lattice = try Lattice(Memory.self, Edge.self, GroupProjectMap.self, configuration: .init(fileURL: path))
            groupLattices[group] = lattice
            refs.append(.init(groupId: group, path: path.path, ref: lattice.sendableReference))
        }
        return Fixture(tools: MemoryTools(localRef: local.sendableReference, syncedRef: nil,
                                           groupRefs: refs, embedder: embedder,
                                           identity: StaticIdentityProvider(.anonymous), enableLocalMutationOperations: true),
                       local: local, groups: groupLattices)
    }

    private func seed(_ lattice: Lattice, project: String = "p", isPrivate: Bool = false,
                      author: UUID? = nil) throws -> UUID {
        let memory = Memory(content: "Synthetic evidence \(UUID().uuidString)", topic: "original",
                            project: project, embedding: Vector<Float>([1] + [Float](repeating: 0, count: 383)),
                            importance: 3, isPrivate: isPrivate, authorUserId: author)
        try lattice.add(memory)
        return try #require(memory.globalId)
    }

    private func derive(_ operation: String, tools: MemoryTools, ids: [UUID], project: String? = nil) async throws -> CallTool.Result {
        var args: [String: Value] = ["ids": .array(ids.map { .string($0.uuidString) })]
        if operation == "organize" {
            args["label"] = .string("Synthetic derived label")
            args["summary"] = .string("Synthetic derived summary")
        } else {
            args["content"] = .string("Synthetic derived summary")
            if operation == "consolidate" { args["force"] = .bool(true) }
        }
        if let project { args["project"] = .string(project) }
        return try await tools.handle(CallTool.Parameters(name: operation, arguments: args))
    }


    @Test func reviewerDerivedPrivateFloorCanBeRemoved() async throws {
        let group = UUID()
        let ctx = try fixture(exposures: ["p": [group.uuidString]])
        let ids = try [seed(ctx.local, isPrivate: true), seed(ctx.local, isPrivate: true)]
        let result = try await derive("merge", tools: ctx.tools, ids: ids)
        #expect(result.isError != true)
        let id = try #require(extractId(from: text(from: result)).flatMap(UUID.init(uuidString:)))
        #expect(ctx.local.objects(Memory.self).where { $0.globalId == id }.first?.isPrivate == true)
        let update = try await ctx.tools.handle(CallTool.Parameters(name: "update", arguments: [
            "id": .string(id.uuidString), "is_private": .bool(false),
        ]))
        let current = try #require(ctx.local.objects(Memory.self).where { $0.globalId == id }.first)
        print("REVIEW_PRIVATE_FLOOR updateRejected=\(update.isError == true) outputPrivate=\(current.isPrivate)")
        #expect(update.isError == true, "inherited private floor must survive later author edits")
        #expect(current.isPrivate)
    }

    @Test func reviewerGroupDerivativeLeaksOnLaterProjectExposure() async throws {
        let groupA = UUID(), groupB = UUID()
        let ctx = try fixture(exposures: ["p": [groupA.uuidString]], groups: [groupA])
        let a = try #require(ctx.groups[groupA])
        let ids = try [seed(a), seed(a)]
        let result = try await derive("merge", tools: ctx.tools, ids: ids)
        #expect(result.isError != true)
        let id = try #require(extractId(from: text(from: result)).flatMap(UUID.init(uuidString:)))
        let derived = try #require(ctx.local.objects(Memory.self).where { $0.globalId == id }.first)
        #expect(!derived.isPrivate)
        let policy = try #require(ctx.local.objects(SyncConfig.self).where { $0.project == "p" }.first)
        policy.exposedGroups = [groupA.uuidString, groupB.uuidString]
        try ctx.local.add(Memory(content: "reviewer-public-control", project: "p"))

        var hubConfig = Lattice.Configuration(fileURL: ctx.local.configuration.fileURL, migration: engramMigrations)
        let socketPath = try testFixtureDirectory().appendingPathComponent("r-\(groupB.uuidString.suffix(12)).sock").path
        #expect(socketPath.utf8.count < 104)
        hubConfig.ipcTargets = [.init(channel: SyncService.groupChannel(groupB),
            syncFilter: SyncService.buildGroupSyncFilter(from: ctx.local, groupId: groupB),
            socketPath: socketPath, narrowingEmitsRemovals: false)]
        let hub = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self,
                              configuration: hubConfig)
        var targetConfig = Lattice.Configuration(fileURL: ctx.local.configuration.fileURL.deletingLastPathComponent().appendingPathComponent("new-group.sqlite"), migration: engramMigrations)
        targetConfig.ipcTargets = [.init(channel: SyncService.groupChannel(groupB), socketPath: socketPath)]
        let target = try Lattice(Memory.self, Edge.self, GroupProjectMap.self, configuration: targetConfig)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline && !target.objects(Memory.self).contains(where: { $0.content == "reviewer-public-control" }) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(target.objects(Memory.self).contains(where: { $0.content == "reviewer-public-control" }))
        try await Task.sleep(nanoseconds: 500_000_000)
        let leaked = target.objects(Memory.self).contains(where: { $0.globalId == id })
        print("REVIEW_AUDIENCE_FLOOR controlArrived=true derivedFromAReachedB=\(leaked)")
        #expect(!leaked, "group A derivation must not broaden when project is later exposed to group B")
        withExtendedLifetime(hub) {}
    }

    private func resultID(_ result: CallTool.Result) throws -> UUID {
        #expect(result.isError != true)
        return try #require(extractId(from: text(from: result)).flatMap(UUID.init(uuidString:)))
    }
    private func output(_ ctx: Fixture, _ id: UUID) throws -> Memory {
        try #require(ctx.local.objects(Memory.self).where { $0.globalId == id }.first)
    }
    private func produce(_ operation: String, ctx: Fixture, ids: [UUID], privateValue: Bool = false) async throws -> UUID {
        if operation != "episode" { return try resultID(await derive(operation, tools: ctx.tools, ids: ids)) }
        let episode = Memory(content: "Synthetic episode", topic: "episode", project: "p", isPrivate: privateValue)
        try ctx.local.add(episode)
        let id = try #require(episode.globalId)
        for member in ids { try ctx.local.add(Edge(sourceGlobalId: member, targetGlobalId: id, relation: .partOf)) }
        #expect(try await ctx.tools.handle(CallTool.Parameters(name: "end_episode", arguments: [
            "episode_id": .string(id.uuidString), "summary": .string("Derived episode summary")])).isError != true)
        return id
    }
    private func operation(_ ctx: Fixture, update: UpdateRequest, id: UUID = UUID()) async throws -> MemoryOperationRequest {
        try await MemoryOperationRequest(operationID: id, expectedScope: ctx.tools.operationScope(),
            provenance: MemoryOperationProvenance(host: "synthetic-host", sessionID: "restriction-session", runID: "restriction-run",
                source: MemoryOperationSourceInterval(startOffset: 1, endOffset: 2,
                    excerptDigest: MemoryOperationDigest(sha256: String(repeating: "a", count: 64)))), mutation: .update(update))
    }

    @Test(arguments: ["merge", "consolidate", "organize", "episode"])
    func everyDerivedFieldKeepsPrivacyFloorAcrossMetadataEdits(_ kind: String) async throws {
        let a = UUID(), ctx = try fixture(exposures: ["p": [a.uuidString]])
        let ids = try [seed(ctx.local, isPrivate: true), seed(ctx.local, isPrivate: true)]
        let id = try await produce(kind, ctx: ctx, ids: ids, privateValue: true)
        let expected = try #require(MemoryDerivationPolicy.derived(privateFloor: true, groupCeiling: []))
        #expect(try output(ctx, id).derivationPolicy == expected.rawValue)
        if kind == "organize" {
            for source in ids { #expect(try output(ctx, source).derivationPolicy == expected.rawValue) }
        }
        let changed = try await ctx.tools.handle(CallTool.Parameters(name: "update", arguments: [
            "id": .string(id.uuidString), "source": .string("conversation"), "set_project": .string("renamed"),
            "content": .string("Replacement still inherits the floor")]))
        #expect(changed.isError != true)
        let refused = try await ctx.tools.handle(CallTool.Parameters(name: "update", arguments: [
            "id": .string(id.uuidString), "is_private": .bool(false)]))
        #expect(refused.isError == true)
        #expect(try output(ctx, id).derivationPolicy == expected.rawValue)
        #expect(try output(ctx, id).effectiveIsPrivate)
        #expect(try await ctx.tools.handle(CallTool.Parameters(name: "forget", arguments: ["id": .string(id.uuidString)])).isError != true)
        // Group-exposed original project is not retained by the metadata rename;
        // merge may hard delete here. Descendant coverage below does not rely on edges.
    }

    @Test(arguments: ["merge", "consolidate", "organize", "episode"])
    func descendantsAndRelabeledOriginalsKeepAudienceCeiling(_ kind: String) async throws {
        let a = UUID(), b = UUID(), ctx = try fixture(exposures: ["p": [a.uuidString], "broad": [a.uuidString, b.uuidString]])
        let ids = try [seed(ctx.local), seed(ctx.local)]
        let id = try await produce(kind, ctx: ctx, ids: ids)
        let expected = try #require(MemoryDerivationPolicy.derived(privateFloor: false, groupCeiling: [a.uuidString]))
        #expect(try output(ctx, id).derivationPolicy == expected.rawValue)
        if kind == "organize" {
            for source in ids { #expect(try output(ctx, source).derivationPolicy == expected.rawValue) }
        }
        #expect(try await ctx.tools.handle(CallTool.Parameters(name: "update", arguments: [
            "id": .string(id.uuidString), "set_project": .string("broad")])).isError == true)
        let next = try seed(ctx.local)
        let descendant = try resultID(await derive("consolidate", tools: ctx.tools, ids: [id, next]))
        #expect(try output(ctx, descendant).derivationPolicy == expected.rawValue)
        #expect(try output(ctx, descendant).project == "p")
    }

    @Test(arguments: ["merge", "consolidate", "organize"])
    func aRestrictionOnAnotherCopyConstrainsDerivation(_ kind: String) async throws {
        let a = UUID(), ctx = try fixture(exposures: ["p": [a.uuidString]], groups: [a])
        let ids = try [seed(ctx.local), seed(ctx.local)]
        let spoke = try #require(ctx.groups[a])
        let privatePolicy = try #require(MemoryDerivationPolicy.derived(privateFloor: true, groupCeiling: []))
        for id in ids {
            let source = try output(ctx, id)
            try spoke.add(Memory(content: source.content, topic: source.topic, project: source.project,
                source: source.source, derivationPolicy: privatePolicy.rawValue), preservingGlobalId: id)
        }
        // Effective private copies combine with ordinary exposed local copies:
        // this remains a mixed-scope refusal, not a public output.
        #expect(try await derive(kind, tools: ctx.tools, ids: ids).isError == true)
        #expect(try await ctx.tools.handle(CallTool.Parameters(name: "update", arguments: [
            "id": .string(ids[0].uuidString), "is_private": .bool(false)])).isError == true)
        #expect(ctx.local.objects(Memory.self).count == 2)
    }

    @Test(arguments: ["legacy", "malformed", "unknown"])
    func unclassifiedPolicyCannotBecomeAQualifiedDerivative(_ damage: String) async throws {
        let ctx = try fixture(), ids = try [seed(ctx.local), seed(ctx.local)]
        let row = try output(ctx, ids[0])
        row.derivationPolicy = damage == "legacy" ? nil : (damage == "malformed" ? "engram-policy:1:derived:0:garbage" : "engram-policy:2:direct")
        #expect(row.effectiveIsPrivate)
        #expect(try await derive("merge", tools: ctx.tools, ids: ids).isError == true)
        #expect(try await ctx.tools.handle(CallTool.Parameters(name: "update", arguments: [
            "id": .string(ids[0].uuidString), "source": .string("conversation")])).isError == true)
        #expect(ctx.local.objects(Memory.self).count == 2)
    }

    @Test(arguments: [false, true])
    func policyTighteningWhileEmbeddingRefusesBothUpdateAPIs(_ durable: Bool) async throws {
        let gate = SuspendedEmbedder(), ctx = try fixture(embedder: gate)
        let id = try seed(ctx.local), before = try output(ctx, id).content
        let request = try await operation(ctx, update: UpdateRequest(id: id, content: "Must not commit"))
        let pending = Task { () -> Bool in
            if durable {
                do { _ = try await ctx.tools.applyOperation(request); return false } catch { return true }
            }
            return try await ctx.tools.handle(CallTool.Parameters(name: "update", arguments: [
                "id": .string(id.uuidString), "content": .string("Must not commit")])).isError == true
        }
        await gate.waitUntilStarted()
        let restriction = try #require(MemoryDerivationPolicy.derived(privateFloor: true, groupCeiling: []))
        let writer = try Lattice(Memory.self, configuration: .init(fileURL: ctx.local.configuration.fileURL))
        try #require(writer.objects(Memory.self).where { $0.globalId == id }.first).derivationPolicy = restriction.rawValue
        await gate.resume()
        #expect(try await pending.value)
        #expect(try output(ctx, id).content == before)
        #expect(try output(ctx, id).derivationPolicy == restriction.rawValue)
    }

    @Test func durableOperationCannotWeakenPolicyAndReplayDoesNotRewriteIt() async throws {
        let a = UUID(), b = UUID(), ctx = try fixture(exposures: ["p": [a.uuidString], "broad": [b.uuidString]])
        let id = try seed(ctx.local)
        let row = try output(ctx, id)
        let receiptRequest = try await operation(ctx, update: UpdateRequest(id: id, source: "before-policy"))
        let receipt = try await ctx.tools.applyOperation(receiptRequest)
        let scoped = try #require(MemoryDerivationPolicy.derived(privateFloor: false, groupCeiling: [a.uuidString]))
        row.derivationPolicy = scoped.rawValue
        let broaden = try await operation(ctx, update: UpdateRequest(id: id, project: "broad"))
        await #expect(throws: (any Error).self) { try await ctx.tools.applyOperation(broaden) }
        let privatePolicy = try #require(MemoryDerivationPolicy.derived(privateFloor: true, groupCeiling: []))
        row.derivationPolicy = privatePolicy.rawValue; row.isPrivate = true
        let unprivate = try await operation(ctx, update: UpdateRequest(id: id, isPrivate: false))
        await #expect(throws: (any Error).self) { try await ctx.tools.applyOperation(unprivate) }
        #expect(try await ctx.tools.applyOperation(receiptRequest) == receipt)
        #expect(try output(ctx, id).derivationPolicy == privatePolicy.rawValue)
        #expect(try output(ctx, id).isPrivate)
        #expect(try output(ctx, id).project == "p")
        #expect(ctx.local.objects(EngramOperationReceiptV1.self).count == 1)
    }

    private final class SQLWriter: @unchecked Sendable {
        private let db: OpaquePointer
        init(_ path: URL) throws {
            var pointer: OpaquePointer?
            let code = sqlite3_open_v2(path.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
            guard code == SQLITE_OK, let pointer else { throw RawWriteLock.Failure.sqlite(code, "open synthetic fixture") }
            db = pointer
        }
        deinit { sqlite3_close(db) }
        func run(_ sql: String) throws {
            let code = sqlite3_exec(db, sql, nil, nil, nil)
            guard code == SQLITE_OK else { throw RawWriteLock.Failure.sqlite(code, String(cString: sqlite3_errmsg(db))) }
        }
    }
    @Test(arguments: [false, true])
    func finalMutationFenceSeesPolicyCommittedWhileWaitingForBEGIN(_ durable: Bool) async throws {
        let gate = SuspendedEmbedder(), ctx = try fixture(embedder: gate), id = try seed(ctx.local)
        let before = try output(ctx, id).content
        let request = try await operation(ctx, update: UpdateRequest(id: id, content: "Uncommitted replacement"))
        let pending = Task { () -> Bool in
            if durable {
                do { _ = try await ctx.tools.applyOperation(request); return false }
                catch { return String(describing: error).contains("policy") }
            }
            let result = try await ctx.tools.handle(CallTool.Parameters(name: "update", arguments: [
                "id": .string(id.uuidString), "content": .string("Uncommitted replacement")]))
            return result.isError == true && text(from: result).contains("policy")
        }
        await gate.waitUntilStarted()
        let policy = try #require(MemoryDerivationPolicy.derived(privateFloor: true, groupCeiling: []))
        let writer = TransactionGateWriter(path: ctx.local.configuration.fileURL, id: id, policy: policy.rawValue)
        let writing = Task.detached { writer.run() }
        let entered = await Task.detached { writer.waitForEntry() }.value
        await gate.resume()
        #expect(entered)
        #expect(try await pending.value)
        #expect(try output(ctx, id).content == before)
        #expect(try output(ctx, id).derivationPolicy == policy.rawValue)
        #expect(await writing.value)
    }

    private final class TransactionGateWriter: @unchecked Sendable {
        let path: URL, id: UUID, policy: String
        private let entered = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var began = false
        init(path: URL, id: UUID, policy: String) { self.path = path; self.id = id; self.policy = policy }
        func waitForEntry() -> Bool {
            guard entered.wait(timeout: .now() + 5) == .success else { return false }
            return lock.withLock { began }
        }
        func run() -> Bool {
            var signaled = false
            defer { if !signaled { entered.signal() } }
            do {
                let writer = try Lattice(Memory.self, configuration: .init(fileURL: path, busyTimeoutMs: 100))
                try LatticeBeginRetry.run(on: writer) {
                    guard let row = writer.objects(Memory.self).where({ $0.globalId == id }).first else { throw RawWriteLock.Failure.sqlite(1, "missing synthetic row") }
                    row.derivationPolicy = policy
                    lock.withLock { began = true }
                    signaled = true; entered.signal()
                    Thread.sleep(forTimeInterval: 0.2)
                }
                return true
            } catch { return false }
        }
    }

    @Test(arguments: ["local", "group", "episode"])
    func derivedFieldWriteRollsBackOrRefusesUnsupportedStore(_ location: String) async throws {
        let a = UUID(), ctx = try fixture(exposures: ["p": [a.uuidString]], groups: location == "group" ? [a] : [])
        let owner = location == "group" ? try #require(ctx.groups[a]) : ctx.local
        let ids = try [seed(owner), seed(owner)]
        if location == "group" {
            let result = try await derive("organize", tools: ctx.tools, ids: ids)
            #expect(result.isError == true && text(from: result).contains("cross-store"))
            #expect(ctx.local.objects(Memory.self).count == 0)
            #expect(ctx.local.objects(Edge.self).count == 0)
            #expect(owner.objects(Memory.self).allSatisfy { $0.topic == "original" && $0.derivationPolicy == MemoryDerivationPolicy.direct.rawValue })
            return
        }
        let writer = try SQLWriter(owner.configuration.fileURL)
        if location == "episode" {
            let episode = Memory(content: "Original episode", topic: "episode", project: "p")
            try owner.add(episode)
            let eid = try #require(episode.globalId)
            for id in ids { try owner.add(Edge(sourceGlobalId: id, targetGlobalId: eid, relation: .partOf)) }
            try writer.run("CREATE TRIGGER fail_summary BEFORE UPDATE OF content ON Memory BEGIN SELECT RAISE(ABORT,'synthetic'); END")
            do {
                _ = try await ctx.tools.handle(CallTool.Parameters(name: "end_episode", arguments: [
                    "episode_id": .string(eid.uuidString), "summary": .string("Must roll back")]))
                Issue.record("Expected checked transaction failure")
            } catch {}
            #expect(try output(ctx, eid).derivationPolicy == MemoryDerivationPolicy.direct.rawValue)
            #expect(try output(ctx, eid).content == "Original episode")
        } else {
            try writer.run("CREATE TRIGGER fail_topic BEFORE UPDATE OF topic ON Memory BEGIN SELECT RAISE(ABORT,'synthetic'); END")
            do { _ = try await derive("organize", tools: ctx.tools, ids: ids); Issue.record("Expected checked transaction failure") } catch {}
            let raw = try RawWriteLock(path: owner.configuration.fileURL.path)
            #expect(try raw.integer("SELECT COUNT(*) FROM Memory WHERE derivationPolicy != 'engram-policy:1:direct'") == 0)
            #expect(try raw.integer("SELECT COUNT(*) FROM Memory WHERE topic != 'original'") == 0)
            #expect(ctx.local.objects(Memory.self).where { $0.source == "organize" }.count == 0)
        }
    }

    @Test(arguments: [false, true], ["private", "narrow", "compatible", "explicit"])
    func automaticTopicInferenceCannotLaunderNeighborRestrictions(_ durable: Bool, scope: String) async throws {
        let a = UUID(), ctx = try fixture(exposures: ["p": [a.uuidString]])
        let restriction = try #require(MemoryDerivationPolicy.derived(privateFloor: false,
            groupCeiling: scope == "narrow" ? [] : [a.uuidString]))
        for index in 0..<2 {
            let row = Memory(content: "Distinct neighbor \(index) \(UUID())", topic: "SENSITIVE_TOPIC", project: "p",
                embedding: Vector<Float>([0.2] + Array(repeating: 0, count: 383)), isPrivate: scope == "private",
                derivationPolicy: restriction.rawValue)
            try ctx.local.add(row)
        }
        let providedTopic = scope == "explicit" ? "user-topic" : "general"
        let content = "User supplied independent direct content"
        let id: UUID
        if durable {
            let request = try await MemoryOperationRequest(operationID: UUID(), expectedScope: ctx.tools.operationScope(),
                provenance: MemoryOperationProvenance(host: "synthetic-host", sessionID: "restriction-session", runID: "remember-run",
                    source: MemoryOperationSourceInterval(startOffset: 1, endOffset: 2,
                        excerptDigest: MemoryOperationDigest(sha256: String(repeating: "b", count: 64)))),
                mutation: .remember(RememberRequest(content: content, topic: providedTopic, project: "p", isPrivate: false)))
            id = try #require(await ctx.tools.applyOperation(request).memoryIDs.first)
        } else {
            id = try resultID(await ctx.tools.handle(CallTool.Parameters(name: "remember", arguments: [
                "content": .string(content), "project": .string("p"), "topic": .string(providedTopic), "is_private": .bool(false)])))
        }
        let current = try output(ctx, id)
        #expect(current.content == content)
        #expect(current.topic == (scope == "compatible" ? "SENSITIVE_TOPIC" : providedTopic))
        #expect(current.derivationPolicy == (scope == "compatible" ? restriction.rawValue : MemoryDerivationPolicy.direct.rawValue))
        #expect(!current.isPrivate)
    }
}
