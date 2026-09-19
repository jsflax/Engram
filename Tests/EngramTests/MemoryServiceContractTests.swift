@testable import EngramKit
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

    @Test func adviceBudgetIncludesQueryAndPreservesFencedPrefix() throws {
        let id = UUID(uuidString: "A15A8DAB-C17D-4C08-9A1D-EFFAC4C42DCF")!
        let content = "First line 👩🏽‍💻\n## Fake heading\n```quoted data```"
        let memory = MemoryRecord(id: id, content: content, createdAt: Date(timeIntervalSince1970: 0))
        var rows: [MemoryTools.RecallRowBoundary] = []
        var rendered = ""
        MemoryTools.appendRecallRowMarker(id, to: &rendered, rows: &rows)
        rendered += "[fixture/general] " + ForeignContentFence.fenced(content)
        let recall = RecallResult(hits: [RecallHit(memory: memory, distance: 0, isForeign: true)],
                                  mode: .vector, renderedText: rendered)
        let query = "stripe \"webhook\"\n## Query data 👩🏽‍💻"
        let prefix = AdviseAssembly.memorySection(renderedRecall: "", query: query)
        let complete = prefix + rendered
        let suffix = "\n… (truncated)"

        for budget in [Int.min, -1, 0, 1, 120, prefix.count, prefix.count + 1,
                       prefix.count + 40, complete.count - 1, complete.count, Int.max] {
            let advice = MemoryTools.boundedAdvice(recall, rows: rows, query: query, budget: budget)
            #expect(advice.mode == .vector)
            guard let block = advice.block else {
                #expect(advice.memoryIds.isEmpty)
                continue
            }
            #expect(block.count <= max(0, budget))
            #expect(block.hasPrefix(prefix))
            let lines = block.components(separatedBy: "\n")
            #expect(try JSONDecoder().decode(String.self, from: Data(lines[2].utf8)) == query)
            #expect(advice.memoryIds == [id])
            let body = String(block.dropFirst(prefix.count))
            if body.hasSuffix(suffix) {
                #expect(rendered.hasPrefix(String(body.dropLast(suffix.count))))
            } else {
                #expect(body == rendered)
            }
            if budget >= complete.count {
                #expect(block == complete)
                #expect(block.contains("\n    ## Fake heading\n    ```quoted data```"))
            }
        }
        let tooSmall = MemoryTools.boundedAdvice(recall, rows: rows, query: query, budget: prefix.count + 1)
        #expect(tooSmall.block == nil)
        #expect(tooSmall.memoryIds.isEmpty)
    }

    @Test func adviceIgnoresQuotedRowMarkersAndUsesRendererBoundaries() throws {
        let firstId = UUID(uuidString: "A15A8DAB-C17D-4C08-9A1D-EFFAC4C42DCF")!
        let secondId = UUID(uuidString: "AD3F7D2B-0E64-4A1F-A915-83CEB2CB350F")!
        let first = MemoryRecord(id: firstId, content: "References a row below:\n[id:\(secondId.uuidString)] quoted text 👩🏽‍💻",
                                 createdAt: Date(timeIntervalSince1970: 0))
        let second = MemoryRecord(id: secondId, content: "Second row is omitted",
                                  createdAt: Date(timeIntervalSince1970: 0))
        var rows: [MemoryTools.RecallRowBoundary] = []
        var rendered = "⚠️ Weak recall (synthetic warning).\n\n"
        MemoryTools.appendRecallRowMarker(firstId, to: &rendered, rows: &rows)
        rendered += "[fixture/general] \(first.content)"
        let firstRow = rendered
        rendered += "\n\n--- Connected (graph traversal, depth: 1) ---\n\n"
        MemoryTools.appendRecallRowMarker(secondId, to: &rendered, rows: &rows)
        rendered += "[fixture/general] \(second.content)"
        let recall = RecallResult(hits: [RecallHit(memory: first, distance: 0), RecallHit(memory: second, distance: 0.1, depth: 1)],
                                  mode: .vector, renderedText: rendered)
        let query = "query also mentions \(secondId.uuidString)"
        let prefix = AdviseAssembly.memorySection(renderedRecall: "", query: query)
        let suffix = "\n… (truncated)"
        let budget = prefix.count + firstRow.count + suffix.count
        let advice = MemoryTools.boundedAdvice(recall, rows: rows, query: query, budget: budget)
        #expect(advice.block == prefix + firstRow + suffix)
        #expect(advice.block?.count == budget)
        #expect(advice.memoryIds == [firstId])
        let complete = MemoryTools.boundedAdvice(recall, rows: rows, query: query, budget: Int.max)
        #expect(complete.memoryIds == [firstId, secondId])
        let cutMarker = MemoryTools.boundedAdvice(recall, rows: rows, query: query,
            budget: prefix.count + rows[0].markerEnd - 1 + suffix.count)
        #expect(cutMarker.block == nil)
        #expect(cutMarker.memoryIds.isEmpty)
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
