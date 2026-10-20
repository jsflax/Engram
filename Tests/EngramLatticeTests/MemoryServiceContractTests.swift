import EngramLattice
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
struct PortableMemoryServiceContractTests {

    @Test func contractHoldsOnLattice() async throws {
        let violations = await MemoryServiceContract.run(PortableLatticeContractHarness())
        for violation in violations {
            Issue.record("\(violation)")
        }
        #expect(violations.isEmpty)
    }
}

/// Builds `MemoryTools` over throwaway sqlite files. Peers share the
/// original service's lattice file through a registry keyed by the actor's
/// identity — the harness owns the lattices, so no lattice handle ever
/// crosses the actor boundary.
struct PortableLatticeContractHarness: ContractHarness {

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
