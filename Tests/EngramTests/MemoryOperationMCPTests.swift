@testable import EngramKit
import EngramMemoryCore
import EngramModels
import Foundation
import Lattice
import MCP
import Testing

@Suite("Durable operation MCP wire adapter", .serialized)
struct MemoryOperationMCPTests {
    private actor Embed: Embedder {
        nonisolated let dimension = 384
        var calls = 0
        func embed(text: String) async throws -> [Float]? {
            calls += 1
            return [1] + [Float](repeating: 0, count: dimension - 1)
        }
    }
    private struct Fixture {
        let db: Lattice
        let tools: MemoryTools
        let embedder: Embed
        let scope: MemoryOperationScope?
    }

    private func fixture(enabled: Bool = true, register: Bool = true) throws -> Fixture {
        let root = try #require(ProcessInfo.processInfo.environment["ENGRAM_ADOPTION_TEST_ROOT"])
        let directory = URL(fileURLWithPath: root).appendingPathComponent("operation-wire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("memory.sqlite")
        try MemoryOperationLedger.preflightLocalStore(at: path)
        let db = try Lattice(for: [Memory.self, Edge.self, SyncConfig.self] + (register ? MemoryOperationLedger.localModels : []),
                             configuration: .init(fileURL: path, busyTimeoutMs: 100))
        let scope: MemoryOperationScope?
        if register {
            let ledger = MemoryOperationLedger(lattice: db)
            try ledger.bootstrapStoreID()
            scope = try ledger.scope(principal: .anonymous)
        } else { scope = nil }
        let embedder = Embed()
        let tools = MemoryTools(localRef: db.sendableReference, syncedRef: nil, embedder: embedder,
                                identity: StaticIdentityProvider(.anonymous), enableLocalMutationOperations: enabled)
        return Fixture(db: db, tools: tools, embedder: embedder, scope: scope)
    }

    private func request(_ f: Fixture, operationID: UUID = UUID(), content: String = "synthetic private wire memory") throws -> MemoryOperationRequest {
        try MemoryOperationRequest(operationID: operationID, expectedScope: #require(f.scope),
            provenance: MemoryOperationProvenance(host: "wire-fixture", sessionID: "wire-session", runID: "wire-run",
                source: MemoryOperationSourceInterval(startOffset: 10, endOffset: 20,
                    excerptDigest: MemoryOperationDigest(sha256: String(repeating: "a", count: 64)))),
            mutation: .remember(RememberRequest(content: content, topic: "episode", project: "WireFixture", isPrivate: true)))
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: Value] {
        let result = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
        guard case .object(let fields) = result else { throw MemoryOperationError.invalidRequest("fixture") }
        return fields
    }

    private func envelope(_ result: CallTool.Result) throws -> [String: Value] {
        guard case .object(let outer) = try #require(result.structuredContent),
              case .object(let fields) = outer["engram_operation"] else {
            throw MemoryOperationError.invalidRequest("missing envelope")
        }
        #expect(outer.count == 1)
        #expect(fields["version"] == .int(1))
        guard case .text(let text, _, _) = try #require(result.content.first) else {
            throw MemoryOperationError.invalidRequest("missing text")
        }
        #expect(try JSONDecoder().decode(Value.self, from: Data(text.utf8)) == result.structuredContent)
        return fields
    }

    @Test func roundedLargeUnsignedOffsetsAreRejectedBeforeEmbedding() async throws {
        let f = try fixture()
        defer { f.db.close() }
        let ordinary = try request(f)
        let operation = try MemoryOperationRequest(operationID: ordinary.operationID, expectedScope: ordinary.expectedScope,
            provenance: MemoryOperationProvenance(host: "wire-fixture", sessionID: "wire-session", runID: "wire-run",
                source: MemoryOperationSourceInterval(startOffset: 9_223_372_036_854_775_809,
                    endOffset: 9_223_372_036_854_779_905,
                    excerptDigest: MemoryOperationDigest(sha256: String(repeating: "a", count: 64)))),
            mutation: ordinary.mutation)
        let arguments = try JSONEncoder().encode(operation)
        let raw = Data("{\"name\":\"operation_apply\",\"arguments\":".utf8) + arguments + Data("}".utf8)
        let parameters = try JSONDecoder().decode(CallTool.Parameters.self, from: raw)
        guard case .object(let provenance) = parameters.arguments?["provenance"],
              case .object(let source) = provenance["source"],
              case .double = source["startOffset"] else {
            throw MemoryOperationError.invalidRequest("fixture did not exercise SDK integer coercion")
        }
        let rejected = try await f.tools.handle(parameters)
        #expect(rejected.isError == true)
        #expect(try envelope(rejected)["code"] == .string("invalid_request"))
        #expect(await f.embedder.calls == 0)
        #expect(f.db.objects(Memory.self).snapshot().isEmpty)
        #expect(f.db.objects(EngramOperationReceiptV1.self).snapshot().isEmpty)
    }

    @Test func committedReplayAndStatusHaveIdenticalVersionedReceipts() async throws {
        let f = try fixture()
        defer { f.db.close() }
        #expect(f.tools.capabilities.contains(.localMutationOperationsV1))
        let names = Set(await f.tools.definitions.map(\.name))
        #expect(names.isSuperset(of: ["operation_scope", "operation_apply", "operation_status"]))
        let scopeReply = try await f.tools.handle(.init(name: "operation_scope", arguments: [:]))
        let scopeBody = try envelope(scopeReply)
        #expect(scopeReply.isError == false)
        #expect(scopeBody["kind"] == .string("scope"))
        #expect(scopeBody["capability"] == .string("localMutationOperationsV1"))
        #expect(scopeBody["scope"] == .object(try object(#require(f.scope))))
        let operation = try request(f)
        let arguments = try object(operation)
        let first = try await f.tools.handle(.init(name: "operation_apply", arguments: arguments))
        let second = try await f.tools.handle(.init(name: "operation_apply", arguments: arguments))
        #expect(first.isError == false && first == second)
        let committed = try envelope(first)
        #expect(committed["kind"] == .string("committed"))
        let status = try await f.tools.handle(.init(name: "operation_status", arguments: [
            "operationID": .string(operation.operationID.uuidString), "scope": .object(try object(operation.expectedScope)),
        ]))
        #expect(try envelope(status) == committed)
        let receipt = try JSONDecoder().decode(MemoryOperationReceipt.self,
            from: JSONEncoder().encode(#require(committed["receipt"])))
        #expect(receipt.operationID == operation.operationID && receipt.outcome == .applied)
        #expect(abs(receipt.committedAt.timeIntervalSinceNow) < 60)
        #expect(f.db.objects(Memory.self).snapshot().count == 1)
        #expect(await f.embedder.calls == 1)
        let wire = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        #expect(!wire.contains("synthetic private wire memory"))
    }

    @Test func unknownFieldsAndChangedPayloadCannotBecomeExtraWrites() async throws {
        let f = try fixture()
        defer { f.db.close() }
        let operation = try request(f)
        var arguments = try object(operation)
        arguments["unexpected"] = .string("private query detail")
        let rejected = try await f.tools.handle(.init(name: "operation_apply", arguments: arguments))
        #expect(rejected.isError == true)
        #expect(try envelope(rejected)["code"] == .string("invalid_request"))
        #expect(await f.embedder.calls == 0)
        _ = try await f.tools.handle(.init(name: "operation_apply", arguments: object(operation)))
        let changed = try request(f, operationID: operation.operationID, content: "different private content")
        let conflict = try await f.tools.handle(.init(name: "operation_apply", arguments: object(changed)))
        #expect(conflict.isError == true)
        #expect(try envelope(conflict)["code"] == .string("payload_conflict"))
        #expect(f.db.objects(Memory.self).snapshot().count == 1)
        #expect(await f.embedder.calls == 1)
        #expect(!String(decoding: try JSONEncoder().encode(conflict), as: UTF8.self).contains("private"))
    }

    @Test func authoritativeAbsenceAndUnavailableStorageStayDistinct() async throws {
        let f = try fixture()
        defer { f.db.close() }
        let operationID = UUID()
        let absent = try await f.tools.handle(.init(name: "operation_status", arguments: [
            "operationID": .string(operationID.uuidString), "scope": .object(try object(#require(f.scope))),
        ]))
        let body = try envelope(absent)
        #expect(absent.isError == false)
        #expect(body["kind"] == .string("absent"))
        #expect(body["operationID"] == .string(operationID.uuidString))
        let unavailable = try fixture(register: false)
        defer { unavailable.db.close() }
        let failure = try await unavailable.tools.handle(.init(name: "operation_scope", arguments: [:]))
        #expect(failure.isError == true)
        #expect(try envelope(failure)["kind"] == .string("error"))
        #expect(try envelope(failure)["code"] == .string("storage_unavailable"))
    }

    @Test func disabledInstancesDoNotAdvertiseOrExecuteOperations() async throws {
        let f = try fixture(enabled: false)
        defer { f.db.close() }
        #expect(!f.tools.capabilities.contains(.localMutationOperationsV1))
        #expect(!(await f.tools.definitions).contains { $0.name.hasPrefix("operation_") })
        let rejected = try await f.tools.handle(.init(name: "operation_apply", arguments: object(request(f))))
        #expect(rejected.isError == true)
        #expect(try envelope(rejected)["code"] == .string("unsupported"))
        await #expect(throws: MemoryOperationError.unsupported) { try await f.tools.operationScope() }
        #expect(f.db.objects(Memory.self).snapshot().isEmpty)
        #expect(await f.embedder.calls == 0)
    }

    @Test func malformedNestedRequestAndOversizeInputAreRejectedBeforeEmbedding() async throws {
        let f = try fixture()
        defer { f.db.close() }
        var arguments = try object(request(f))
        guard case .object(var mutation) = arguments["mutation"],
              case .object(var value) = mutation["request"] else { throw MemoryOperationError.invalidRequest("fixture") }
        value["force"] = .bool(true)
        mutation["request"] = .object(value)
        arguments["mutation"] = .object(mutation)
        let malformed = try await f.tools.handle(.init(name: "operation_apply", arguments: arguments))
        #expect(try envelope(malformed)["code"] == .string("invalid_request"))
        let large = try request(f, content: String(repeating: "x", count: 1_048_577))
        let oversized = try await f.tools.handle(.init(name: "operation_apply", arguments: object(large)))
        #expect(try envelope(oversized)["code"] == .string("invalid_request"))
        #expect(await f.embedder.calls == 0)
        #expect(f.db.objects(Memory.self).snapshot().isEmpty)
    }

    @Test(arguments: ["remember", "append"])
    func dataURLWireCoercionIsRejectedBeforeAnyMutation(_ mode: String) async throws {
        let f = try fixture()
        defer { f.db.close() }
        let original = try request(f, content: "data:,hello")
        let operation: MemoryOperationRequest
        if mode == "append" {
            operation = try MemoryOperationRequest(operationID: original.operationID, expectedScope: original.expectedScope,
                provenance: original.provenance, mutation: .update(UpdateRequest(id: UUID(), append: "data:,hello")))
        } else { operation = original }
        // Go through actual JSON -> MCP.Parameters decoding so this tests the
        // SDK's lossy data-URL conversion rather than a hand-built Value.
        let arguments = try JSONSerialization.jsonObject(with: JSONEncoder().encode(operation))
        let raw = try JSONSerialization.data(withJSONObject: ["name": "operation_apply", "arguments": arguments])
        let parameters = try JSONDecoder().decode(CallTool.Parameters.self, from: raw)
        guard case .object(let mutation) = parameters.arguments?["mutation"],
              case .object(let request) = mutation["request"],
              case .data = request[mode == "remember" ? "content" : "append"] else {
            throw MemoryOperationError.invalidRequest("fixture did not exercise SDK data coercion")
        }
        let rejected = try await f.tools.handle(parameters)
        #expect(rejected.isError == true)
        #expect(try envelope(rejected)["code"] == .string("invalid_request"))
        #expect(await f.embedder.calls == 0)
        #expect(f.db.objects(Memory.self).snapshot().isEmpty)
        #expect(f.db.objects(EngramOperationReceiptV1.self).snapshot().isEmpty)
    }
}
