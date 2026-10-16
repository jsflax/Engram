import Foundation
import Testing
@testable import EngramMemoryCore

@Suite("Durable memory operation contract")
struct MemoryOperationContractTests {
    private let digest = try! MemoryOperationDigest(sha256: String(repeating: "a", count: 64))

    private func scope() throws -> MemoryOperationScope {
        try MemoryOperationScope(storeID: UUID(), principal: .init(.anonymous))
    }

    private func provenance() throws -> MemoryOperationProvenance {
        try MemoryOperationProvenance(
            host: "codex", sessionID: "session-1", runID: "run-1",
            source: .init(startOffset: 100, endOffset: 200, excerptDigest: digest))
    }

    private func request(_ mutation: MemoryMutation) throws -> MemoryOperationRequest {
        try MemoryOperationRequest(operationID: UUID(), expectedScope: scope(),
                                   provenance: provenance(), mutation: mutation)
    }

    @Test func legacyBackendsRefuseEveryOperationWithoutCallingLegacyWrites() async throws {
        // Existential dispatch is intentional: transports hold MemoryService,
        // not the concrete backend. Each legacy method throws a distinct error.
        let service: any MemoryService = LegacyOnlyMemoryService()
        #expect(!service.capabilities.contains(.localMutationOperationsV1))
        await #expect(throws: MemoryOperationError.unsupported) {
            try await service.operationScope()
        }
        let operationScope = try scope()
        await #expect(throws: MemoryOperationError.unsupported) {
            try await service.operationStatus(operationID: UUID(), scope: operationScope)
        }
        for mutation in [
            MemoryMutation.remember(.init(content: "A durable fact")),
            .update(.init(id: UUID(), append: " An append must never be repeated.")),
            .connect(.init(sourceId: UUID(), targetId: UUID(), relation: "related_to")),
        ] {
            let operation = try request(mutation)
            await #expect(throws: MemoryOperationError.unsupported) {
                try await service.applyOperation(operation)
            }
        }
    }

    @Test func wireRoundTripRetainsOperationIdentityProvenanceAndNonIdempotentPayload() throws {
        let memoryID = UUID()
        let original = try request(.update(.init(id: memoryID, append: "append exactly once")))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MemoryOperationRequest.self, from: data)
        #expect(decoded.operationID == original.operationID)
        #expect(decoded.expectedScope == original.expectedScope)
        #expect(decoded.provenance == original.provenance)
        guard case .update(let update) = decoded.mutation else {
            Issue.record("The mutation kind changed during transport")
            return
        }
        #expect(update.id == memoryID)
        #expect(update.append == "append exactly once")
        #expect(update.content == nil)
        // A transport carries kind + request, not a client-provided payload
        // digest which a backend might accidentally trust instead of hashing.
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["payloadDigest"] == nil)
        let mutation = try #require(object["mutation"] as? [String: Any])
        #expect(mutation["kind"] as? String == "update")
    }

    @Test func unknownVersionsAreRejectedAtDecodeBoundary() throws {
        let operation = try request(.remember(.init(content: "fact")))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(operation)) as? [String: Any])
        object["version"] = 2
        let changed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: MemoryOperationError.self) {
            try JSONDecoder().decode(MemoryOperationRequest.self, from: changed)
        }
        var scopeObject = try #require(object["expectedScope"] as? [String: Any])
        scopeObject["version"] = 0
        #expect(throws: MemoryOperationError.self) {
            try JSONDecoder().decode(MemoryOperationScope.self,
                                     from: JSONSerialization.data(withJSONObject: scopeObject))
        }
    }

    @Test func provenanceValidationCannotBeBypassedByDecoding() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(provenance())) as? [String: Any])
        for value in ["", "run\nnot-an-identifier", String(repeating: "é", count: 65)] {
            object["runID"] = value
            #expect(throws: MemoryOperationError.self) {
                try JSONDecoder().decode(MemoryOperationProvenance.self,
                                         from: JSONSerialization.data(withJSONObject: object))
            }
        }
        let valid = try provenance()
        #expect(try JSONDecoder().decode(MemoryOperationProvenance.self,
                                        from: JSONEncoder().encode(valid)) == valid)
    }

    @Test func sourceIntervalAndDigestRejectInvalidDecodedValues() throws {
        for text in ["", String(repeating: "A", count: 64), String(repeating: "g", count: 64), String(repeating: "a", count: 63)] {
            #expect(throws: MemoryOperationError.self) {
                try JSONDecoder().decode(MemoryOperationDigest.self, from: JSONEncoder().encode(text))
            }
        }
        for (start, end) in [(100, 100), (101, 100)] {
            let data = try JSONSerialization.data(withJSONObject: [
                "startOffset": start, "endOffset": end, "excerptDigest": digest.sha256,
            ])
            #expect(throws: MemoryOperationError.self) {
                try JSONDecoder().decode(MemoryOperationSourceInterval.self, from: data)
            }
        }
    }

    @Test func principalBindingIgnoresPresentationAndOrderingButTracksAuthority() throws {
        let id = UUID(), groupA = UUID(), groupB = UUID()
        let original = MemoryOperationPrincipalBinding(Principal(
            id: id, kind: .user, displayName: "Before", groupIds: [groupA, groupB], scopes: ["read", "write"]))
        let reordered = MemoryOperationPrincipalBinding(Principal(
            id: id, kind: .user, displayName: "After", groupIds: [groupB, groupA, groupA], scopes: ["write", "read"]))
        #expect(original == reordered)
        for changed in [
            Principal(id: UUID(), kind: .user, groupIds: [groupA, groupB], scopes: ["read", "write"]),
            Principal(id: id, kind: .agent, groupIds: [groupA, groupB], scopes: ["read", "write"]),
            Principal(id: id, kind: .user, groupIds: [groupA], scopes: ["read", "write"]),
            Principal(id: id, kind: .user, groupIds: [groupA, groupB], scopes: ["read"]),
        ] {
            #expect(original != MemoryOperationPrincipalBinding(changed))
        }
        #expect(try JSONDecoder().decode(MemoryOperationPrincipalBinding.self,
                                        from: JSONEncoder().encode(original)) == original)
    }

    @Test func committedAndAbsentStatusRemainDistinctAndContentFree() throws {
        let operationScope = try scope(), operationID = UUID(), memoryID = UUID()
        for outcome in [MemoryOperationReceipt.Outcome.applied, .unchanged] {
            let receipt = try MemoryOperationReceipt(
                operationID: operationID, scope: operationScope, payloadDigest: digest,
                mutation: .remember, outcome: outcome, memoryIDs: [memoryID],
                committedAt: Date(timeIntervalSince1970: 1_790_000_000))
            let status = MemoryOperationStatus.committed(receipt)
            let data = try JSONEncoder().encode(status)
            #expect(try JSONDecoder().decode(MemoryOperationStatus.self, from: data) == status)
            let encoded = try #require(String(data: data, encoding: .utf8))
            #expect(!encoded.contains("content"))
            #expect(!encoded.contains("renderedText"))
            #expect(!encoded.contains("source"))
        }
        let absent = MemoryOperationStatus.absent(operationID: operationID, scope: operationScope)
        #expect(try JSONDecoder().decode(MemoryOperationStatus.self,
                                        from: JSONEncoder().encode(absent)) == absent)
    }

    @Test func oversizedAndMalformedReceiptsAreRejected() throws {
        let operationScope = try scope(), operationID = UUID(), memoryID = UUID()
        func receipt(_ ids: [UUID], at: Date = Date()) throws -> MemoryOperationReceipt {
            try MemoryOperationReceipt(operationID: operationID, scope: operationScope,
                                       payloadDigest: digest, mutation: .remember, outcome: .applied,
                                       memoryIDs: ids, committedAt: at)
        }
        #expect(throws: MemoryOperationError.self) { try receipt([memoryID, memoryID]) }
        #expect(throws: MemoryOperationError.self) {
            try receipt((0...MemoryOperationReceipt.maximumResultIDs).map { _ in UUID() })
        }
        #expect(throws: MemoryOperationError.self) {
            try receipt([memoryID], at: Date(timeIntervalSince1970: .infinity))
        }
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt([memoryID]))) as? [String: Any])
        object["memoryIDs"] = [memoryID.uuidString, memoryID.uuidString]
        #expect(throws: MemoryOperationError.self) {
            try JSONDecoder().decode(MemoryOperationReceipt.self,
                                     from: JSONSerialization.data(withJSONObject: object))
        }
    }
}

/// Deliberately has no durable-operation witnesses. It represents existing
/// backends and decorators which must remain source-compatible and fail closed.
private struct LegacyOnlyMemoryService: MemoryService {
    private enum Unexpected: Error { case reachedLegacyAPI }
    let principal = Principal.anonymous
    let capabilities: Set<MemoryCapability> = []
    func recall(_ request: RecallRequest) async throws -> RecallResult { throw Unexpected.reachedLegacyAPI }
    func advise(_ request: AdviseRequest) async throws -> AdviseResult { throw Unexpected.reachedLegacyAPI }
    func graph(_ request: GraphRequest) async throws -> GraphResult { throw Unexpected.reachedLegacyAPI }
    func remember(_ request: RememberRequest) async throws -> RememberResult { throw Unexpected.reachedLegacyAPI }
    func update(_ request: UpdateRequest) async throws -> ToolReply { throw Unexpected.reachedLegacyAPI }
    func forget(_ request: ForgetRequest) async throws -> ToolReply { throw Unexpected.reachedLegacyAPI }
    func connect(_ request: ConnectRequest) async throws -> ToolReply { throw Unexpected.reachedLegacyAPI }
    func disconnect(_ request: ConnectRequest) async throws -> ToolReply { throw Unexpected.reachedLegacyAPI }
    func merge(ids: [UUID], content: String, topic: String?, project: String?) async throws -> ToolReply { throw Unexpected.reachedLegacyAPI }
    func stats(project: String?) async throws -> ToolReply { throw Unexpected.reachedLegacyAPI }
    func listTopics(project: String?) async throws -> ToolReply { throw Unexpected.reachedLegacyAPI }
    func timeline(project: String?, groupBy: String?) async throws -> ToolReply { throw Unexpected.reachedLegacyAPI }
    func beginEpisode(title: String, sessionKey: String?) async throws -> ToolReply { throw Unexpected.reachedLegacyAPI }
    func endEpisode(summary: String?, sessionKey: String?) async throws -> ToolReply { throw Unexpected.reachedLegacyAPI }
    func recallEpisode(id: UUID, limit: Int?) async throws -> ToolReply { throw Unexpected.reachedLegacyAPI }
    func listEpisodes(limit: Int?) async throws -> ToolReply { throw Unexpected.reachedLegacyAPI }
    func checkpoint(title: String, sessionKey: String?) async throws -> ToolReply { throw Unexpected.reachedLegacyAPI }
    func resume(taskId: Int) async throws -> ToolReply { throw Unexpected.reachedLegacyAPI }
    func listTasks() async throws -> ToolReply { throw Unexpected.reachedLegacyAPI }
    func findClusters(project: String?) async throws -> ToolReply { throw Unexpected.reachedLegacyAPI }
    func detectCommunities(project: String) async throws -> ToolReply { throw Unexpected.reachedLegacyAPI }
    func organize(ids: [UUID], label: String, project: String?, summary: String?) async throws -> ToolReply { throw Unexpected.reachedLegacyAPI }
    func consolidate(ids: [UUID], content: String, topic: String?, project: String?, force: Bool) async throws -> ToolReply { throw Unexpected.reachedLegacyAPI }
    func vacuum() async throws -> ToolReply { throw Unexpected.reachedLegacyAPI }
    func trainVectors() async throws -> ToolReply { throw Unexpected.reachedLegacyAPI }
}
