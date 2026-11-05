import Testing
import EngramKit
import EngramMemoryCore
import EngramModels
import Lattice
import MCP
import Foundation

@Suite("DerivationPrivacy")
struct DerivationPrivacyTests {
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
        let local = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self,
                                configuration: .init(fileURL: directory.appendingPathComponent("local.sqlite")))
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
                                           identity: StaticIdentityProvider(.anonymous)),
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

    @Test(arguments: ["merge", "consolidate", "organize"])
    func derivation_allPrivate_staysPrivateInExposedProject(_ operation: String) async throws {
        let ctx = try fixture(exposures: ["p": [UUID().uuidString]])
        let ids = try [seed(ctx.local, isPrivate: true), seed(ctx.local, isPrivate: true)]
        let result = try await derive(operation, tools: ctx.tools, ids: ids)
        #expect(result.isError != true)
        let id = try #require(extractId(from: text(from: result)).flatMap(UUID.init(uuidString:)))
        let summary = try #require(ctx.local.objects(Memory.self).where { $0.globalId == id }.first)
        #expect(summary.isPrivate)
        #expect(summary.project == "p")
    }

    @Test(arguments: ["merge", "consolidate", "organize"])
    func derivation_mixedPrivateShared_refusesWithoutMutation(_ operation: String) async throws {
        let ctx = try fixture(exposures: ["p": [UUID().uuidString]])
        let ids = try [seed(ctx.local, isPrivate: true), seed(ctx.local)]
        let result = try await derive(operation, tools: ctx.tools, ids: ids)
        #expect(result.isError == true)
        #expect(text(from: result).contains("scope"))
        #expect(ctx.local.objects(Memory.self).count == 2)
        #expect(ctx.local.objects(Edge.self).count == 0)
        for id in ids {
            let source = try #require(ctx.local.objects(Memory.self).where { $0.globalId == id }.first)
            #expect(source.deletedAt == nil)
            #expect(source.importance == 3)
            #expect(source.topic == "original")
        }
    }

    @Test(arguments: ["merge", "consolidate", "organize"])
    func derivation_mixedGroupExposure_refuses(_ operation: String) async throws {
        let a = UUID().uuidString, b = UUID().uuidString
        let ctx = try fixture(exposures: ["a": [a], "b": [b]])
        let ids = try [seed(ctx.local, project: "a"), seed(ctx.local, project: "b")]
        let result = try await derive(operation, tools: ctx.tools, ids: ids, project: "a")
        #expect(result.isError == true)
        #expect(ctx.local.objects(Memory.self).count == 2)
        #expect(ctx.local.objects(Memory.self).where { $0.deletedAt != nil || $0.importance == 0 }.count == 0)
        #expect(ctx.local.objects(Edge.self).count == 0)
    }

    @Test(arguments: ["merge", "consolidate", "organize"])
    func derivation_explicitProjectCannotWidenSpokeAudience(_ operation: String) async throws {
        let sourceGroup = UUID(), destinationGroup = UUID()
        let ctx = try fixture(exposures: ["destination": [destinationGroup.uuidString]], groups: [sourceGroup])
        let spoke = try #require(ctx.groups[sourceGroup])
        let ids = try [seed(spoke, project: "teammate-name", author: UUID()),
                       seed(spoke, project: "teammate-name", author: UUID())]
        let result = try await derive(operation, tools: ctx.tools, ids: ids, project: "destination")
        #expect(result.isError == true)
        #expect(ctx.local.objects(Memory.self).count == 0)
        #expect(spoke.objects(Memory.self).where { $0.deletedAt != nil || $0.importance == 0 }.count == 0)
        #expect(ctx.local.objects(Edge.self).count == 0)
    }

    @Test(arguments: ["merge", "consolidate", "organize"])
    func derivation_sameGroupForeignAuthors_preservesFlatTrust(_ operation: String) async throws {
        let group = UUID()
        let ctx = try fixture(exposures: ["destination": [group.uuidString]], groups: [group])
        let spoke = try #require(ctx.groups[group])
        let ids = try [seed(spoke, project: "teammate-name", author: UUID()),
                       seed(spoke, project: "teammate-name", author: UUID())]
        let result = try await derive(operation, tools: ctx.tools, ids: ids, project: "destination")
        #expect(result.isError != true)
        let id = try #require(extractId(from: text(from: result)).flatMap(UUID.init(uuidString:)))
        let summary = try #require(ctx.local.objects(Memory.self).where { $0.globalId == id }.first)
        #expect(!summary.isPrivate)
        #expect(summary.project == "destination")
    }

    @Test(arguments: ["merge", "consolidate", "organize"])
    func derivation_sameAudienceAcrossLocalProjects_succeeds(_ operation: String) async throws {
        let group = UUID()
        let ctx = try fixture(exposures: ["a": [group.uuidString.lowercased()], "b": [group.uuidString]])
        let ids = try [seed(ctx.local, project: "a"), seed(ctx.local, project: "b")]
        let result = try await derive(operation, tools: ctx.tools, ids: ids, project: "b")
        #expect(result.isError != true)
        let id = try #require(extractId(from: text(from: result)).flatMap(UUID.init(uuidString:)))
        #expect(ctx.local.objects(Memory.self).where { $0.globalId == id }.first?.isPrivate == false)
    }

    @Test(arguments: ["merge", "consolidate", "organize"], [false, true])
    func derivation_rechecksPrivacyAfterEmbedding(_ operation: String, initiallyPrivate: Bool) async throws {
        let embedder = SuspendedEmbedder()
        let ctx = try fixture(exposures: ["p": [UUID().uuidString]], embedder: embedder)
        let ids = try [seed(ctx.local, isPrivate: initiallyPrivate), seed(ctx.local, isPrivate: initiallyPrivate)]
        let pending = Task { try await derive(operation, tools: ctx.tools, ids: ids) }
        await embedder.waitUntilStarted()

        // Change the source through the same actor while derivation is awaiting
        // its embedder. An initial-only policy check would still publish it.
        var updates: [CallTool.Result] = []
        for id in ids {
            updates.append(try await ctx.tools.handle(CallTool.Parameters(name: "update", arguments: [
                "id": .string(id.uuidString), "is_private": .bool(!initiallyPrivate),
            ])))
        }
        await embedder.resume()
        let result = try await pending.value
        #expect(updates.allSatisfy { $0.isError != true })
        #expect(result.isError == true)
        #expect(ctx.local.objects(Memory.self).count == 2)
        #expect(ctx.local.objects(Edge.self).count == 0)
        for id in ids {
            let source = try #require(ctx.local.objects(Memory.self).where { $0.globalId == id }.first)
            #expect(source.deletedAt == nil)
            #expect(source.importance == 3)
            #expect(source.topic == "original")
        }
    }

    @Test(arguments: ["merge", "consolidate"])
    func derivation_localMixedPrivacy_usesPrivacyOR(_ operation: String) async throws {
        let ctx = try fixture()
        let ids = try [seed(ctx.local, isPrivate: true), seed(ctx.local)]
        let result = try await derive(operation, tools: ctx.tools, ids: ids)
        #expect(result.isError != true)
        let id = try #require(extractId(from: text(from: result)).flatMap(UUID.init(uuidString:)))
        #expect(ctx.local.objects(Memory.self).where { $0.globalId == id }.first?.isPrivate == true)
    }

    @Test func organize_mixedLocalPrivacy_cannotPublishPrivateLabelOnPublicSource() async throws {
        let ctx = try fixture()
        let ids = try [seed(ctx.local, isPrivate: true), seed(ctx.local)]
        let result = try await derive("organize", tools: ctx.tools, ids: ids)
        #expect(result.isError == true)
        #expect(ctx.local.objects(Memory.self).count == 2)
        #expect(ctx.local.objects(Memory.self).where { $0.topic != "original" }.count == 0)
    }
}
