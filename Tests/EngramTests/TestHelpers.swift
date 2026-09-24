import Testing
import EngramKit
import EngramMemoryCore
import Lattice
import MCP
import Foundation
import SwiftLM

// Lattice isn't Sendable but tests are sequential — safe for test inspection.
extension Lattice: @retroactive @unchecked Sendable {}

/// Helper to extract the text string from a CallTool.Result
func text(from result: CallTool.Result) -> String {
    guard case .text(let text, _, _) = result.content.first else {
        return ""
    }
    return text
}

/// Shared embedder — loads the bundled CoreML model once for all tests.
let sharedEmbedder: EmbeddingService = {
    let e = EmbeddingService()
    return e
}()

private enum FixtureEmbeddingError: Error {
    case invalidComputeUnits(String)
    case missingResource(String)
    case invalidDimension(Int)
    case invalidVector
}

/// The same real MiniLM model, restricted to CPU execution for isolated runners.
private actor CPUFixtureEmbedder: Embedder {
    private let model: CoreMLEmbeddingModel

    init(model: CoreMLEmbeddingModel) { self.model = model }

    var dimension: Int { model.embeddingDimension }

    func embed(text: String) async throws -> [Float]? {
        let vector = try await model.embed(text: text)
        guard vector.count == 384, vector.allSatisfy({ $0.isFinite }) else {
            throw FixtureEmbeddingError.invalidVector
        }
        return vector
    }
}

// Global initialization is lazy; ordinary test runs keep using sharedEmbedder.
// One task shares successful loading or its error across concurrent fixtures.
private let cpuFixtureEmbedder = Task<CPUFixtureEmbedder, Error> {
    let bundle: Bundle
    if let path = ProcessInfo.processInfo.environment["ENGRAM_TEST_RESOURCE_BUNDLE"] {
        guard let configured = Bundle(path: path) else {
            throw FixtureEmbeddingError.missingResource(path)
        }
        bundle = configured
    } else {
        bundle = engramKitResourceBundle
    }
    guard let modelURL = bundle.url(forResource: "paraphrase-MiniLM-L6-v2_Embedding",
                                    withExtension: "mlmodelc"),
          let tokenizerURL = bundle.url(forResource: "paraphrase-MiniLM-L6-v2_tokenizer",
                                        withExtension: nil) else {
        throw FixtureEmbeddingError.missingResource("MiniLM model and tokenizer")
    }
    let model = try await CoreMLEmbeddingModel.loadCompiled(
        url: modelURL, tokenizerDirectory: tokenizerURL, computeUnits: .cpuOnly)
    guard model.embeddingDimension == 384 else {
        throw FixtureEmbeddingError.invalidDimension(model.embeddingDimension)
    }
    return CPUFixtureEmbedder(model: model)
}

/// Opt into CPU-only real embeddings without changing production/default tests.
func loadedFixtureEmbedder() async throws -> any Embedder {
    switch ProcessInfo.processInfo.environment["ENGRAM_TEST_COMPUTE_UNITS"] {
    case "cpuOnly":
        return try await cpuFixtureEmbedder.value
    case nil, "":
        if await !sharedEmbedder.isLoaded {
            await sharedEmbedder.load()
        }
        return sharedEmbedder
    case let value?:
        throw FixtureEmbeddingError.invalidComputeUnits(value)
    }
}

/// Allow isolated test runners to choose a writable fixture directory.
func testFixtureDirectory() throws -> URL {
    let directory = ProcessInfo.processInfo.environment["ENGRAM_TEST_ROOT"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Create a MemoryTools with an isolated temp database and the real embedding model.
func makeTools() async throws -> MemoryTools {
    let path = try testFixtureDirectory()
        .appending(path: "claude-memory-test-\(UUID().uuidString).sqlite")
    let lattice = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self, configuration: .init(fileURL: path))
    let embedder = try await loadedFixtureEmbedder()
    return MemoryTools(localRef: lattice.sendableReference, syncedRef: nil, embedder: embedder)
}

/// Context returned by makeDualDBTools for test inspection.
struct DualDBContext {
    let tools: MemoryTools
    let localLattice: Lattice
    let syncedLattice: Lattice
}

/// Create a MemoryTools with separate local and synced databases for testing dual-DB routing.
func makeDualDBTools() async throws -> DualDBContext {
    let directory = try testFixtureDirectory()
    let localPath = directory
        .appending(path: "claude-memory-test-local-\(UUID().uuidString).sqlite")
    let syncedPath = directory
        .appending(path: "claude-memory-test-synced-\(UUID().uuidString).sqlite")

    let localLattice = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self, configuration: .init(fileURL: localPath))
    let syncedLattice = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: .init(fileURL: syncedPath))

    let embedder = try await loadedFixtureEmbedder()

    let tools = MemoryTools(
        localRef: localLattice.sendableReference,
        syncedRef: syncedLattice.sendableReference,
        embedder: embedder
    )
    return DualDBContext(tools: tools, localLattice: localLattice, syncedLattice: syncedLattice)
}

/// Helper to extract a UUID from text like "id:550E8400-..." or "id: 550E8400-..."
func extractId(from text: String) -> String? {
    guard let range = text.range(of: "id:", options: .literal) else {
        return nil
    }
    let after = text[range.upperBound...].drop(while: { $0 == " " })
    // UUID is 36 chars: 8-4-4-4-12
    let candidate = String(after.prefix(36))
    guard UUID(uuidString: candidate) != nil else { return nil }
    return candidate
}

/// Helper to extract an edge UUID from text like "edge id: 550E8400-..."
func extractEdgeId(from text: String) -> String? {
    guard let range = text.range(of: "edge id: ", options: .literal) else {
        return nil
    }
    let after = text[range.upperBound...]
    let candidate = String(after.prefix(36))
    guard UUID(uuidString: candidate) != nil else { return nil }
    return candidate
}

/// Helper to extract a task ID from text like "task:42" (tasks still use integer IDs)
func extractTaskId(from text: String) -> Int? {
    guard let range = text.range(of: "task:", options: .literal) else {
        return nil
    }
    let after = text[range.upperBound...]
    let digits = after.prefix(while: { $0.isNumber })
    return Int(digits)
}

/// Episodes are now memories — extract UUID using the same "id:" format.
func extractEpisodeId(from text: String) -> String? {
    extractId(from: text)
}

/// Extract memory UUID from "Stored memory (id: UUID, ..."
func extractMemoryId(from text: String) -> String? {
    extractId(from: text)
}

extension String {
    static func random(length: Int) -> String {
        let letters = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<length).map { _ in letters.randomElement()! })
    }
}
