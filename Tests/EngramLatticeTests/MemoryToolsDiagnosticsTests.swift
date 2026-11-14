@testable import EngramLattice
import EngramMemoryContract
import EngramMemoryCore
import Foundation
import Testing

@Suite("MemoryTools diagnostic routing")
struct MemoryToolsDiagnosticsTests {
    @Test(arguments: [false, true])
    func suppliedDiagnosticsRespectPrivateMode(privateGraphOnly: Bool) async throws {
        let recorder = MemoryToolsDiagnosticRecorder()
        let harness = PortableLatticeContractHarness(diagnostics: recorder.sinks)
        let service = try await harness.makeService(
            principal: ContractPrincipals.userA, embedding: .deterministic, fencing: false)
        let normalTools = try #require(service as? MemoryTools)
        let tools: MemoryTools
        if privateGraphOnly {
            let reference = await normalTools.privateGraphReference
            tools = MemoryTools(
                localRef: reference, syncedRef: nil, embedder: DeterministicEmbedder(),
                identity: StaticIdentityProvider(ContractPrincipals.userA),
                privateGraphOnly: true, diagnostics: recorder.sinks)
        } else {
            tools = normalTools
        }
        let actualPrivateMode = await tools.privateGraphOnly
        let fencesForeignContent = await tools.fenceForeignContent
        #expect(actualPrivateMode == privateGraphOnly)
        #expect(fencesForeignContent == privateGraphOnly)

        await tools.log("fixture general diagnostic")
        await tools.sessionLog("fixture session diagnostic")
        await tools.appendSessionSaveLog(
            sessionId: "diagnostic-fixture", globalId: "fixture-id", project: "fixture-project",
            topic: "fixture-topic", preview: "fixture-preview")
        await tools.appendSessionSaveLog(
            sessionId: nil, globalId: "nil-session-id", project: "nil-session-project",
            topic: "nil-session-topic", preview: "nil-session-preview")

        let expected: [MemoryToolsDiagnosticEvent] = privateGraphOnly ? [] : [
            .general("fixture general diagnostic"),
            .session("fixture session diagnostic"),
            .save(.init(sessionId: "diagnostic-fixture", globalId: "fixture-id",
                        project: "fixture-project", topic: "fixture-topic", preview: "fixture-preview")),
            .save(.init(sessionId: nil, globalId: "nil-session-id",
                        project: "nil-session-project", topic: "nil-session-topic", preview: "nil-session-preview")),
        ]
        let events = recorder.snapshot()
        #expect(events == expected)
    }

    @Test func normalHarnessAndPeerRouteReachableSessionDiagnostics() async throws {
        let recorder = MemoryToolsDiagnosticRecorder()
        let harness = PortableLatticeContractHarness(diagnostics: recorder.sinks)
        let service = try await harness.makeService(
            principal: ContractPrincipals.userA, embedding: .deterministic, fencing: false)
        let tools = try #require(service as? MemoryTools)
        let normalPrivateMode = await tools.privateGraphOnly
        #expect(normalPrivateMode == false)
        let content = "the relay daemon uploads tombstones to the group hub during sync"
        let stored = try await service.remember(RememberRequest(
            content: content, topic: "diagnostics", project: "diagnostics-project"))

        let possiblePeer = try await harness.makePeer(
            of: service, principal: ContractPrincipals.userA, embedding: .deterministic, fencing: false)
        let peerService = try #require(possiblePeer)
        let peer = try #require(peerService as? MemoryTools)
        let peerPrivateMode = await peer.privateGraphOnly
        #expect(peerPrivateMode == false)
        let recalled = try await peerService.recall(RecallRequest(
            query: "relay daemon tombstones group hub sync", project: "diagnostics-project", depth: 0))
        let recalledStoredRow = recalled.hits.contains { $0.memory.id == stored.id }
        #expect(recalledStoredRow)

        let events = recorder.snapshot()
        let sawRemember = events.contains { $0 == .general("[remember] START") }
        let sawRecallSession = events.contains {
            if case .session(let message) = $0 { return message.hasPrefix("[recall] START query=") }
            return false
        }
        let saves = events.compactMap { event -> MemoryToolsSessionSaveDiagnostic? in
            if case .save(let value) = event { return value }
            return nil
        }
        #expect(sawRemember)
        #expect(sawRecallSession)
        #expect(saves.count == 1)
        let saved = try #require(saves.first)
        #expect(saved.globalId == stored.id.uuidString)
        #expect(saved.project == "diagnostics-project")
        #expect(saved.topic == "diagnostics")
        #expect(saved.preview == String(content.prefix(50)))
        // Leave ambient currentSessionId unchanged. Explicit nil forwarding is
        // covered by suppliedDiagnosticsRespectPrivateMode, not assumed here.
    }
}

private struct MemoryToolsSessionSaveDiagnostic: Equatable, Sendable {
    let sessionId: String?
    let globalId: String
    let project: String
    let topic: String
    let preview: String
}

private enum MemoryToolsDiagnosticEvent: Equatable, Sendable {
    case general(String)
    case session(String)
    case save(MemoryToolsSessionSaveDiagnostic)
}

/// All recorder state is protected by the lock; sinks can cross into the actor.
private final class MemoryToolsDiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MemoryToolsDiagnosticEvent] = []

    var sinks: MemoryToolsDiagnostics {
        MemoryToolsDiagnostics(
            log: { [self] in append(.general($0)) },
            sessionLog: { [self] in append(.session($0)) },
            appendSessionSaveLog: { [self] sessionId, globalId, project, topic, preview in
                append(.save(.init(sessionId: sessionId, globalId: globalId, project: project,
                                   topic: topic, preview: preview)))
            })
    }

    private func append(_ event: MemoryToolsDiagnosticEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }

    func snapshot() -> [MemoryToolsDiagnosticEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}
