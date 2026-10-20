import Foundation
import Testing
@testable import EngramCoreML
import EngramLattice

@Suite("Bundled offline MiniLM", .serialized)
struct CoreMLMemoryEmbedderTests {
    @Test(arguments: ["EngramPortable_EngramCoreML.bundle", "Engram_EngramCoreML.bundle"])
    func installedAppAndHelperBundlesPrecedeGeneratedFallback(bundleName: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("engram-assets-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for relativeRoot in ["Orbital.app/Contents/Resources", "helpers"] {
            let bundleRoot = root.appendingPathComponent(relativeRoot)
            let bundle = bundleRoot.appendingPathComponent(bundleName)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let asset = bundle.appendingPathComponent("fixture.txt")
            try Data("bundled offline fixture".utf8).write(to: asset)
            let found = CoreMLMemoryAssets.assetURL("fixture", extension: "txt", bundleRoots: [bundleRoot]) {
                Issue.record("Installed resource lookup evaluated the generated SwiftPM fallback")
                return .main
            }
            #expect(found?.standardizedFileURL == asset.standardizedFileURL)
        }
    }

    @Test func bundledModelProducesSemanticVectorsAndIndexesPendingMemory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("engram-coreml-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = AgentMemoryBinding(agentId: UUID())
        let offline = try AgentMemoryStore.open(binding: binding, directory: root)
        let saved = try await offline.remember(.init(content: "The puppy enjoys playing with a ball in the park."))
        #expect(await offline.agentMemoryStatus().pendingEmbeddingCount == 1)
        let embedder = CoreMLMemoryEmbedder(computePolicy: .cpuOnly)
        let puppy = try #require(try await embedder.embed(text: "The dog likes playing outside."))
        let related = try #require(try await embedder.embed(text: "A puppy plays with a ball in a park."))
        let unrelated = try #require(try await embedder.embed(text: "Database replication uses transaction sequence numbers."))
        #expect(puppy.count == 384)
        #expect(abs(puppy.reduce(Float(0)) { $0 + $1 * $1 } - 1) < 0.01)
        func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
        #expect(dot(puppy, related) > dot(puppy, unrelated) + 0.25)
        let memory = try AgentMemoryStore.open(binding: binding, directory: root, embedder: embedder)
        #expect(try await memory.backfillPendingEmbeddings() == 1)
        #expect(await memory.agentMemoryStatus().pendingEmbeddingCount == 0)
        let recalled = try await memory.recall(.init(query: "The dog likes playing outside.", depth: 0))
        #expect(recalled.mode == .vector)
        #expect(recalled.hits.contains { $0.memory.id == saved.id })
    }

    @Test func missingOrRemoteAssetsFailWithoutDownloading() async throws {
        let missing = CoreMLMemoryEmbedder(resourceDirectory: URL(fileURLWithPath: "/missing-" + UUID().uuidString))
        await #expect(throws: CoreMLMemoryEmbedder.LoadError.self) { try await missing.load() }
        let remote = CoreMLMemoryEmbedder(resourceDirectory: URL(string: "https://example.invalid/model")!)
        await #expect(throws: CoreMLMemoryEmbedder.LoadError.self) { try await remote.load() }
    }
}
