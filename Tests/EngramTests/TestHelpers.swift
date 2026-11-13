import Testing
@testable import EngramKit
import Lattice
import MCP
import Foundation

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
/// Every test using this helper keeps embedding diagnostics out of desktop logs.
let sharedEmbedder: EmbeddingService = {
    let e = EmbeddingService(diagnosticSink: { _ in })
    return e
}()

/// Create a MemoryTools with an isolated temp database and the real embedding model.
func makeTools() async throws -> MemoryTools {
    let path = FileManager.default.temporaryDirectory
        .appending(path: "claude-memory-test-\(UUID().uuidString).sqlite")
    let lattice = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self, configuration: .init(fileURL: path))
    let embedder = sharedEmbedder
    if await !embedder.isLoaded {
        await embedder.load()
    }
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
    let localPath = FileManager.default.temporaryDirectory
        .appending(path: "claude-memory-test-local-\(UUID().uuidString).sqlite")
    let syncedPath = FileManager.default.temporaryDirectory
        .appending(path: "claude-memory-test-synced-\(UUID().uuidString).sqlite")

    let localLattice = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self, configuration: .init(fileURL: localPath))
    let syncedLattice = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: .init(fileURL: syncedPath))

    let embedder = sharedEmbedder
    if await !embedder.isLoaded {
        await embedder.load()
    }

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
