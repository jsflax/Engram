import EngramKit
import EngramMemoryContract
import EngramMemoryCore
import EngramModels
import Foundation
import Lattice
import Testing

/// The Lattice side of increment 2: `MemoryTools` must pass the executable
/// MemoryService specification. The Postgres conformance (increment 5, in
/// engram-server) runs the IDENTICAL suite through its own harness — one
/// spec, both backends.
@Suite("MemoryService contract (lattice)")
struct MemoryServiceContractLatticeTests {

    @Test func contractHoldsOnLattice() async throws {
        let violations = await MemoryServiceContract.run(LatticeContractHarness())
        for violation in violations {
            Issue.record("\(violation)")
        }
        #expect(violations.isEmpty)
    }

    @Test(arguments: [false, true])
    func projectUpdatePersistsThroughTypedService(withTopicEdit: Bool) async throws {
        let harness = LatticeContractHarness()
        let service = try await harness.makeService(
            principal: .anonymous, embedding: .deterministic, fencing: false)
        let content = "Project move fixture: obsidian falcon riverbed"
        let stored = try await service.remember(RememberRequest(
            content: content, topic: "original-topic", project: "original-project"))

        // Project-only updates must be accepted. With another edit present,
        // a successful response must not silently drop the project change.
        let reply = try await service.update(UpdateRequest(
            id: stored.id, topic: withTopicEdit ? "updated-topic" : nil,
            project: "destination-project"))
        #expect(!reply.isError)

        let peer = try await harness.makePeer(
            of: service, principal: .anonymous, embedding: .deterministic, fencing: false)
        let reader = try #require(peer)
        let graph = try await reader.graph(GraphRequest(id: stored.id, depth: 0))
        #expect(graph.root.id == stored.id)
        #expect(graph.root.project == "destination-project")
        #expect(graph.root.topic == (withTopicEdit ? "updated-topic" : "original-topic"))
        #expect(graph.root.content == content)
    }
}

/// Builds `MemoryTools` over throwaway sqlite files. Peers share the
/// original service's lattice file through a registry keyed by the actor's
/// identity — the harness owns the lattices, so no lattice handle ever
/// crosses the actor boundary.
struct LatticeContractHarness: ContractHarness {

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var refs: [ObjectIdentifier: LatticeThreadSafeReference] = [:]

        func store(_ ref: LatticeThreadSafeReference, for service: AnyObject) {
            lock.lock(); defer { lock.unlock() }
            refs[ObjectIdentifier(service)] = ref
        }

        func ref(for service: AnyObject) -> LatticeThreadSafeReference? {
            lock.lock(); defer { lock.unlock() }
            return refs[ObjectIdentifier(service)]
        }
    }

    private let registry = Registry()

    private func embedder(for mode: ContractEmbedding) -> any Embedder {
        switch mode {
        case .deterministic: DeterministicEmbedder()
        case .unavailable: UnavailableEmbedder()
        }
    }

    func makeService(principal: Principal,
                     embedding: ContractEmbedding,
                     fencing: Bool) async throws -> any MemoryService {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "contract-\(UUID().uuidString).sqlite")
        let lattice = try Lattice(
            Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self,
            configuration: .init(fileURL: path))
        return try await build(ref: lattice.sendableReference,
                               principal: principal,
                               embedding: embedding, fencing: fencing)
    }

    func makePeer(of service: any MemoryService,
                  principal: Principal,
                  embedding: ContractEmbedding,
                  fencing: Bool) async throws -> (any MemoryService)? {
        guard let tools = service as? MemoryTools,
              let ref = registry.ref(for: tools) else { return nil }
        return try await build(ref: ref, principal: principal,
                               embedding: embedding, fencing: fencing)
    }

    private func build(ref: LatticeThreadSafeReference,
                       principal: Principal,
                       embedding: ContractEmbedding,
                       fencing: Bool) async throws -> any MemoryService {
        let tools = MemoryTools(localRef: ref, syncedRef: nil,
                                embedder: embedder(for: embedding),
                                identity: StaticIdentityProvider(principal))
        if fencing {
            await tools.setForeignContentPolicy(fence: true, exclude: false)
        }
        registry.store(ref, for: tools)
        return tools
    }
}
