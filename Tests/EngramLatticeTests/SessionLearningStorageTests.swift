import EngramLattice
import EngramMemoryCore
import EngramTestSupport
import Foundation
import MCP
import Testing

@Suite("Scoped learning storage", .timeLimit(.minutes(1)))
struct SessionLearningStorageTests {
    private func withFixture(embedder: any Embedder = UnavailableMemoryEmbedder(),
                             operation: (MemoryTools, SessionLearningIdentity) async throws -> Void) async throws {
        let directory = try EngramTestFixtureRoot.directory()
            .appendingPathComponent("scoped-learning-\(UUID())")
        defer {
            if FileManager.default.fileExists(atPath: directory.path) {
                do { try FileManager.default.removeItem(at: directory) }
                catch { Issue.record(error) }
            }
        }
        // The inner scope releases its service before the directory cleanup.
        try await useFixture(directory: directory, embedder: embedder, operation: operation)
    }

    private func useFixture(directory: URL, embedder: any Embedder,
                            operation: (MemoryTools, SessionLearningIdentity) async throws -> Void) async throws {
        let binding = AgentMemoryBinding(agentId: UUID())
        let service = try AgentMemoryStore.open(binding: binding, directory: directory, embedder: embedder)
        let identity = SessionLearningIdentity(
            attemptID: UUID(), workspaceID: "fixture-workspace", roomID: "fixture-room",
            turnID: UUID().uuidString, generation: 1, graphID: binding.graphId,
            principalID: binding.agentId, inputSHA256: String(repeating: "a", count: 64))
        try await operation(service, identity)
    }

    @Test func scopedRememberRecordsTheCommittedMemoryAndCannotReplay() async throws {
        try await withFixture { service, identity in
            #expect(try await service.beginSessionLearning(identity))
            let result = try await service.handleSessionLearningTool(.init(name: "remember", arguments: [
                "content": .string("A bounded fixture learning fact"), "topic": .string("fixture"),
            ]), identity: identity)
            #expect(result.isError != true)
            let completed = try await service.finishSessionLearning(identity, state: .completed, reason: .stop)
            #expect(completed.state == .completed)
            #expect(completed.memoryIDs.count == 1)
            #expect(completed.toolCalls == 1 && completed.writeCalls == 1)
            #expect(!completed.inFlightWrite)
            #expect(try await service.beginSessionLearning(identity) == false)
            let status = await service.agentMemoryStatus()
            #expect(status.memoryCount == 1 && status.pendingEmbeddingCount == 1)
            #expect(!service.capabilities.contains(.localMutationOperationsV1))
        }
    }

    @Test func withdrawingAdmissionDuringEmbeddingPreventsTheLaterWrite() async throws {
        let embedder = PausedLearningEmbedder()
        try await withFixture(embedder: embedder) { service, identity in
            #expect(try await service.beginSessionLearning(identity))
            let write = Task {
                do {
                    let result = try await service.handleSessionLearningTool(.init(name: "remember", arguments: [
                        "content": .string("This withdrawn attempt must not persist"),
                    ]), identity: identity)
                    await embedder.writeFinished()
                    return result
                } catch {
                    await embedder.writeFinished()
                    throw error
                }
            }
            do {
                try await embedder.waitUntilEntered()
                let stopped = try await service.finishSessionLearning(identity, state: .cancelled, reason: .grantChanged)
                await embedder.release()
                #expect(stopped.state == .reconciliationRequired && stopped.inFlightWrite)
                await #expect(throws: MemoryServiceError.self) { _ = try await write.value }
                #expect(await service.agentMemoryStatus().memoryCount == 0)
                let receipt = try await service.sessionLearningReceipt(identity)
                #expect(receipt?.state == .reconciliationRequired)
                #expect(receipt?.memoryIDs.isEmpty == true)
            } catch {
                write.cancel()
                await embedder.release()
                _ = await write.result
                throw error
            }
        }
    }
}

private actor PausedLearningEmbedder: Embedder {
    private enum GateError: Error { case writeEndedBeforeEmbedding, entryDeadline }
    let dimension = 384
    private var entered = false
    private var finished = false
    private var released = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func embed(text: String) async throws -> [Float]? {
        entered = true
        if !released {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if released { continuation.resume() }
                    else { releaseWaiter = continuation }
                }
            } onCancel: {
                Task { await self.release() }
            }
        }
        try Task.checkCancellation()
        return [1] + Array(repeating: 0, count: 383)
    }

    func waitUntilEntered() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !entered {
            try Task.checkCancellation()
            if finished { throw GateError.writeEndedBeforeEmbedding }
            guard clock.now < deadline else { throw GateError.entryDeadline }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func writeFinished() { finished = true }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
