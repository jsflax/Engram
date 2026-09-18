@testable import EngramKit
import EngramMemoryCore
import EngramModels
import Foundation
import Lattice
import MCP
import Testing

// The pure cases exercise the released SDK's explicit outcomes; the disposable
// store case exercises the actual vacuum tool without a model or provider.
@Suite("Lattice adoption maintenance", .serialized)
struct LatticeAdoptionMaintenanceTests {
    private func outcome(
        checkpoint: CheckpointResult = .init(busy: false, complete: true, logFrames: 0, checkpointed: 0),
        rows: Int64 = 1,
        vacuum: Bool? = true,
        finalFrames: Int64 = 0
    ) -> MemoryTools.VacuumStoreOutcome {
        .init(label: "fixture", checkpoint: checkpoint, reindexedRows: rows,
              vacuumSucceeded: vacuum, boundedCheckpointFrames: finalFrames)
    }

    @Test func checkpointBusyPartialAndFailureAreNotSuccess() {
        let busy = outcome(checkpoint: .init(busy: true, complete: false, logFrames: 3, checkpointed: 1))
        #expect(busy.failed)
        #expect(busy.checkpointDescription == "busy")
        let partial = outcome(checkpoint: .init(busy: false, complete: false, logFrames: 3, checkpointed: 1))
        #expect(partial.failed)
        #expect(partial.checkpointDescription == "partial")
        let failed = outcome(checkpoint: .init(busy: false, complete: false, logFrames: -1, checkpointed: -1))
        #expect(failed.failed)
        #expect(failed.checkpointDescription == "failed")
    }

    @Test func failedVacuumAndUnavailableMaintenanceCountsAreErrors() {
        #expect(outcome(vacuum: false).failed)
        #expect(outcome(vacuum: false).description.contains("database VACUUM failed"))
        #expect(outcome(rows: -1).failed)
        #expect(outcome(finalFrames: -1).failed)
        #expect(outcome(finalFrames: -1).description.contains("busy or failed"))
    }

    @Test func boundedFrameCountDoesNotClaimTruncation() {
        let result = outcome(finalFrames: 2)
        #expect(!result.failed)
        #expect(result.description.contains("processed 2 frames"))
        #expect(!result.description.contains("WAL truncated"))
        let spoke = outcome(vacuum: nil)
        #expect(!spoke.failed)
        #expect(spoke.description.contains("database VACUUM not requested"))
    }

    private struct UnusedEmbedder: Embedder {
        var dimension: Int { 384 }
        func embed(text: String) async throws -> [Float]? { nil }
    }

    @Test func vacuumToolPreservesMemoryAndReportsObservedOutcomes() async throws {
        let root = ProcessInfo.processInfo.environment["ENGRAM_ADOPTION_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("lattice-maintenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("memory.sqlite")
        let writer = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self,
                                 configuration: .init(fileURL: path, busyTimeoutMs: 100))
        var vector = [Float](repeating: 0, count: 384)
        vector[0] = 1
        let row = Memory(content: "maintenance fixture", topic: "maintenance", project: "Adoption",
                         embedding: Vector<Float>(vector))
        try writer.add(row)
        let id = try #require(row.globalId)
        let tools = MemoryTools(localRef: writer.sendableReference, syncedRef: nil,
                                embedder: UnusedEmbedder(), identity: StaticIdentityProvider(.anonymous))
        let result = try await tools.handle(CallTool.Parameters(name: "vacuum"))
        let text = result.content.compactMap { item -> String? in
            if case .text(let value, _, _) = item { return value }
            return nil
        }.joined(separator: "\n")
        #expect(result.isError == false)
        #expect(text.contains("Vacuum maintenance finished."))
        #expect(text.contains("local: initial checkpoint complete"))
        #expect(text.contains("database VACUUM succeeded"))
        #expect(text.contains("Final WAL truncation is not confirmed"))
        // Reopen independently to check that maintenance preserved committed rows.
        let reader = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self,
                                 configuration: .init(fileURL: path, busyTimeoutMs: 100))
        let saved = reader.objects(Memory.self).where { $0.globalId == id }
        #expect(saved.count == 1)
        #expect(saved.first?.content == "maintenance fixture")
    }
}
