@testable import EngramLattice
import EngramMemoryCore
import EngramModels
import EngramTestSupport
import Foundation
@testable import Lattice
import Testing

@Suite("Recall preserves the selected graph's reader schema")
struct RecallReaderSchemaTests {
    @Test(arguments: [false, true])
    func recallKeepsEveryRegisteredTableAndTheReadableGraph(vectors: Bool) async throws {
        let directory = try EngramTestFixtureRoot.directory()
            .appending(path: "recall-reader-schema-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binding = AgentMemoryBinding(agentId: UUID(), displayName: "Original owner")
        let file = AgentMemoryStore.fileURL(binding: binding, directory: directory)
        let embedder: any Embedder
        if vectors { embedder = ReaderSchemaEmbedder() }
        else { embedder = UnavailableMemoryEmbedder() }

        let original = try AgentMemoryStore.open(binding: binding, directory: directory, embedder: embedder)
        let first = try await original.remember(.init(content: ReaderSchemaFixture.firstContent))
        let second = try await original.remember(.init(content: ReaderSchemaFixture.secondContent))
        #expect(first.embeddingPending == !vectors)
        #expect(second.embeddingPending == !vectors)
        let connected = try await original.connect(.init(
            sourceId: first.id, targetId: second.id, relation: "relates_to"))
        #expect(!connected.isError)

        let reopened = try AgentMemoryStore.open(
            binding: .init(agentId: binding.agentId, graphId: binding.graphId, displayName: "Renamed owner"),
            directory: directory, embedder: embedder)
        try await reopened.prepareStorage()
        let beforeSchema = try await dynamicSchema(file: file)
        #expect(Set(beforeSchema.keys) == Set(AgentMemoryStore.schema.map { $0.entityName }))
        let before = try await page(file: file, binding: binding)
        let savedIDs: Set<UUID> = [first.id, second.id]
        #expect(Set(before.memories.map(\.id)) == savedIDs)
        #expect(before.matchingMemoryCount == 2)
        #expect(before.edges.count == 1)
        let edge = try #require(before.edges.first)
        #expect(edge.sourceId == first.id && edge.targetId == second.id && edge.relation == "relates_to")

        let recalled = try await reopened.recall(.init(query: ReaderSchemaFixture.query, depth: 0, limit: 2))
        #expect(recalled.mode == (vectors ? .vector : .fullText))
        #expect(Set(recalled.hits.map { $0.memory.id }) == savedIDs)
        let handles = await reopened.readerSchemaHandleSnapshot()
        #expect(handles.outcome == (vectors ? .bumped(rows: 2) : .skippedNothing))
        if vectors {
            let stats = try #require(handles.stats)
            #expect(stats.identity != handles.ownerIdentity)
            #expect(stats.timeout == 75)
            #expect(!stats.hasScheduler && !stats.hasTransport)
            #expect(stats.modelNames == Set(beforeSchema.keys))
        } else {
            // The real no-model path skips the stats opener; it must remain a
            // passing control rather than accidentally exercising vector recall.
            #expect(handles.stats == nil)
        }

        // Do not open another typed handle here: that could restore the full
        // schema snapshot and conceal what the recall's dedicated opener did.
        let afterSchema = try await dynamicSchema(file: file)
        #expect(afterSchema == beforeSchema)
        let after = try await page(file: file, binding: binding)
        #expect(Set(after.memories.map(\.id)) == savedIDs)
        #expect(after.matchingMemoryCount == 2)
        #expect(after.pendingEmbeddingCount == (vectors ? 0 : 2))
        #expect(after.memories.allSatisfy { $0.accessCount == (vectors ? 1 : 0) })
        #expect(after.edges.count == 1)
        let retainedEdge = try #require(after.edges.first)
        #expect(retainedEdge.id == edge.id)
        #expect(retainedEdge.sourceId == first.id && retainedEdge.targetId == second.id)
        #expect(retainedEdge.relation == "relates_to")

        // Retain both real writer owners throughout the detached reader calls.
        // No checkpoint, raw writer, or cold reopen is needed for the viewer.
        let originalStatus = await original.agentMemoryStatus()
        let reopenedStatus = await reopened.agentMemoryStatus()
        #expect(originalStatus.memoryCount == 2 && reopenedStatus.memoryCount == 2)
    }

    private func dynamicSchema(file: URL) async throws -> [String: Set<PropertyInfo>] {
        try await Task.detached {
            let reader = try Lattice.dynamic(fileURL: file)
            defer { reader.close() }
            return Dictionary(uniqueKeysWithValues: reader.dynamicSchema.map {
                ($0.name, Set($0.properties))
            })
        }.value
    }

    private func page(file: URL, binding: AgentMemoryBinding) async throws -> AgentMemoryBrowserSnapshot {
        try await Task.detached {
            try AgentMemoryReader.read(fileURL: file, binding: binding)
        }.value
    }
}

private enum ReaderSchemaFixture {
    static let firstContent = "Peregrine telescope calibration uses a violet target"
    static let secondContent = "Orchard irrigation valves close after rainfall"
    static let query = "Peregrine calibration orchard irrigation"
}

private struct ReaderSchemaEmbedder: Embedder {
    var dimension: Int { 384 }

    func embed(text: String) async throws -> [Float]? {
        var vector = [Float](repeating: 0, count: dimension)
        switch text {
        case ReaderSchemaFixture.firstContent: vector[0] = 1
        case ReaderSchemaFixture.secondContent: vector[1] = 1
        case ReaderSchemaFixture.query:
            vector[0] = Float(0.5).squareRoot()
            vector[1] = Float(0.5).squareRoot()
        default: throw ReaderSchemaFixtureError.unexpectedEmbeddingInput
        }
        // Orthogonal stored vectors avoid both duplicate rejection and an
        // automatic edge; the query is equally close to both retained rows.
        return vector
    }
}

private enum ReaderSchemaFixtureError: Error { case unexpectedEmbeddingInput }

private struct ReaderSchemaStatsSnapshot: Sendable {
    let identity: Int64
    let timeout: Int
    let hasScheduler: Bool
    let hasTransport: Bool
    let modelNames: Set<String>
}

private struct ReaderSchemaHandleSnapshot: Sendable {
    let ownerIdentity: Int64
    let outcome: AccessStatBumpOutcome
    let stats: ReaderSchemaStatsSnapshot?
}

private extension MemoryTools {
    func readerSchemaHandleSnapshot() -> ReaderSchemaHandleSnapshot {
        let stats = accessStatLattice.map { handle in
            let configuration = handle.configuration
            return ReaderSchemaStatsSnapshot(
                identity: handle.backend.identityHash, timeout: configuration.busyTimeoutMs,
                hasScheduler: handle.isolation != nil,
                hasTransport: configuration.wssEndpoint != nil || configuration.authorizationToken != nil
                    || !(configuration.ipcTargets ?? []).isEmpty,
                modelNames: Set(handle.modelTypes.map { $0.entityName }))
        }
        return ReaderSchemaHandleSnapshot(ownerIdentity: localLattice.backend.identityHash,
                                          outcome: lastAccessStatBump, stats: stats)
    }
}
