import EngramMemoryCore
import Foundation
import MCP

/// Versioned wire adapter for the local durable operation contract. This does
/// not initialize a store. Startup must preflight/register/bootstrap it first.
extension MemoryTools {
    static var operationToolDefinitions: [Tool] {
        let uuid: Value = .object(["type": .string("string"), "format": .string("uuid")])
        let string: Value = .object(["type": .string("string")])
        let integer: Value = .object(["type": .string("integer")])
        let boolean: Value = .object(["type": .string("boolean")])
        let version: Value = .object(["type": .string("integer"), "const": .int(1)])
        let strings: Value = .object(["type": .string("array"), "items": string])
        let uuids: Value = .object(["type": .string("array"), "items": uuid])
        let principal = operationObjectSchema([
            "id": uuid, "kind": string, "groupIds": uuids, "scopes": strings,
        ], required: ["kind", "groupIds", "scopes"])
        let scope = operationObjectSchema(["version": version, "storeID": uuid, "principal": principal],
                                          required: ["version", "storeID", "principal"])
        let digest: Value = .object(["type": .string("string"), "pattern": .string("^[0-9a-f]{64}$")])
        let source = operationObjectSchema(["startOffset": integer, "endOffset": integer, "excerptDigest": digest],
                                           required: ["startOffset", "endOffset", "excerptDigest"])
        let provenance = operationObjectSchema([
            "host": string, "sessionID": string, "runID": string, "source": source,
        ], required: ["host", "sessionID", "runID", "source"])
        let remember = operationObjectSchema([
            "content": string, "topic": string, "project": string, "source": string,
            "importance": integer, "isPrivate": boolean, "parentId": uuid, "expiresInDays": integer,
        ], required: ["content", "isPrivate"])
        let update = operationObjectSchema([
            "id": uuid, "content": string, "append": string, "prepend": string,
            "find": string, "replace": string, "topic": string, "project": string,
            "source": string, "importance": integer, "expiresInDays": integer,
            "isPrivate": boolean, "undelete": .object(["type": .string("boolean"), "const": .bool(false)]),
        ], required: ["id", "undelete"])
        let connect = operationObjectSchema(["sourceId": uuid, "targetId": uuid, "relation": string],
                                            required: ["sourceId", "targetId", "relation"])
        let mutations: [Value] = [("remember", remember), ("update", update), ("connect", connect)].map { kind, request in
            operationObjectSchema([
                "kind": .object(["type": .string("string"), "const": .string(kind)]), "request": request,
            ], required: ["kind", "request"])
        }
        let request = operationObjectSchema([
            "version": version, "operationID": uuid, "expectedScope": scope,
            "provenance": provenance, "mutation": .object(["oneOf": .array(mutations)]),
        ], required: ["version", "operationID", "expectedScope", "provenance", "mutation"])
        return [
            Tool(name: "operation_scope", description: "Read the local store and current principal binding for durable mutation operations V1. Retain the original backend route as well as this scope.",
                 inputSchema: operationObjectSchema([:], required: []), annotations: .init(readOnlyHint: true)),
            Tool(name: "operation_apply", description: "Apply one immutable remember, update or connect operation in the local owning store. Persist the exact request and stable operationID before calling. Exact retries return the original receipt; changed payloads conflict. Never fall back to legacy writes after an uncertain result. Input is limited to one MiB; committedAt uses seconds since 2001-01-01 UTC.",
                 inputSchema: request, annotations: .init(readOnlyHint: false, idempotentHint: true)),
            Tool(name: "operation_status", description: "Look up an operation in its original local store and principal. A committed receipt proves that transaction committed. Absent does not prove an earlier writer has stopped and does not authorize replay or cursor advancement.",
                 inputSchema: operationObjectSchema(["operationID": uuid, "scope": scope], required: ["operationID", "scope"]),
                 annotations: .init(readOnlyHint: true)),
        ]
    }

    private static func operationObjectSchema(_ properties: [String: Value], required: [String]) -> Value {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(required.map(Value.string)), "additionalProperties": .bool(false)])
    }

    func handleOperationTool(_ params: CallTool.Parameters) async -> CallTool.Result {
        do {
            guard localMutationOperationsEnabled else { throw MemoryOperationError.unsupported }
            let arguments = params.arguments ?? [:]
            // MCP.Value decodes complete data-URL strings as binary and loses
            // their original spelling. Never mutate or hash re-encoded text
            // that differs from the caller's persisted immutable request.
            try Self.rejectLossyTransportValues(.object(arguments), allowDouble: false)
            let encoded = try JSONEncoder().encode(Value.object(arguments))
            guard encoded.count <= 1_048_576 else { throw MemoryOperationError.invalidRequest("Input exceeds limit") }
            let result: [String: Value]
            switch params.name {
            case "operation_scope":
                guard arguments.isEmpty else { throw MemoryOperationError.invalidRequest("Unexpected field") }
                result = ["kind": .string("scope"),
                          "capability": .string(MemoryCapability.localMutationOperationsV1.rawValue),
                          "scope": try Self.operationValue(await operationScope())]
            case "operation_apply":
                try Self.validateOperationShape(.object(arguments))
                let request = try JSONDecoder().decode(MemoryOperationRequest.self, from: encoded)
                result = ["kind": .string("committed"), "receipt": try Self.operationValue(await applyOperation(request))]
            case "operation_status":
                try Self.operationKeys(.object(arguments), allowed: ["operationID", "scope"], required: ["operationID", "scope"])
                try Self.validateScopeShape(arguments["scope"]!)
                let request = try JSONDecoder().decode(OperationStatusArguments.self, from: encoded)
                switch try await operationStatus(operationID: request.operationID, scope: request.scope) {
                case .committed(let receipt):
                    result = ["kind": .string("committed"), "receipt": try Self.operationValue(receipt)]
                case .absent(let operationID, let scope):
                    result = ["kind": .string("absent"), "operationID": .string(operationID.uuidString),
                              "scope": try Self.operationValue(scope)]
                }
            default: throw MemoryOperationError.unsupported
            }
            return Self.operationResult(result, isError: false)
        } catch {
            let code: String
            switch error {
            case MemoryOperationError.unsupported: code = "unsupported"
            case MemoryOperationError.scopeMismatch: code = "scope_mismatch"
            case MemoryOperationError.payloadConflict: code = "payload_conflict"
            case MemoryOperationError.unsupportedTarget: code = "unsupported_target"
            case MemoryOperationError.invalidRequest, is DecodingError: code = "invalid_request"
            default: code = "storage_unavailable"
            }
            // Errors intentionally contain no request values, SQL, paths or
            // underlying diagnostics. None is authoritative operation absence.
            return Self.operationResult(["kind": .string("error"), "code": .string(code)], isError: true)
        }
    }

    private struct OperationStatusArguments: Decodable {
        let operationID: UUID
        let scope: MemoryOperationScope
    }

    private static func operationValue<T: Encodable>(_ value: T) throws -> Value {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate // Explicit wire contract: seconds since 2001.
        let result = try JSONDecoder().decode(Value.self, from: encoder.encode(value))
        try rejectLossyTransportValues(result, allowDouble: true)
        return result
    }

    private static func rejectLossyTransportValues(_ value: Value, allowDouble: Bool) throws {
        switch value {
        case .data:
            throw MemoryOperationError.invalidRequest("Data URLs cannot be represented exactly by this transport")
        case .double where !allowDouble:
            // Every numeric input in V1 is an integer. MCP.Value decodes
            // UInt64 values above Int64.max through Double, which can round
            // source bounds before canonical hashing. Refuse those inputs;
            // output receipt timestamps legitimately contain fractional values.
            throw MemoryOperationError.invalidRequest("Input integers must be represented exactly by this transport")
        case .array(let values):
            for value in values { try rejectLossyTransportValues(value, allowDouble: allowDouble) }
        case .object(let values):
            for value in values.values { try rejectLossyTransportValues(value, allowDouble: allowDouble) }
        default: break
        }
    }

    private static func operationResult(_ payload: [String: Value], isError: Bool) -> CallTool.Result {
        var envelope = payload
        envelope["version"] = .int(1)
        let value: Value = .object(["engram_operation": .object(envelope)])
        // Matching structured and text forms support clients that retain only
        // text. The gateway accepts the versioned envelope, never success prose.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"engram_operation\":{\"version\":1,\"kind\":\"error\",\"code\":\"storage_unavailable\"}}"
        return CallTool.Result(content: [.text(text: text)], structuredContent: Optional.some(value), isError: isError)
    }

    private static func operationKeys(_ value: Value, allowed: Set<String>, required: Set<String>) throws {
        guard case .object(let object) = value, Set(object.keys).isSubset(of: allowed),
              required.isSubset(of: Set(object.keys)) else { throw MemoryOperationError.invalidRequest("Invalid fields") }
    }

    private static func validateScopeShape(_ value: Value) throws {
        try operationKeys(value, allowed: ["version", "storeID", "principal"], required: ["version", "storeID", "principal"])
        guard case .object(let scope) = value else { throw MemoryOperationError.invalidRequest("Invalid scope") }
        try operationKeys(scope["principal"]!, allowed: ["id", "kind", "groupIds", "scopes"], required: ["kind", "groupIds", "scopes"])
    }

    private static func validateOperationShape(_ value: Value) throws {
        try operationKeys(value, allowed: ["version", "operationID", "expectedScope", "provenance", "mutation"],
                          required: ["version", "operationID", "expectedScope", "provenance", "mutation"])
        guard case .object(let object) = value else { throw MemoryOperationError.invalidRequest("Invalid request") }
        try validateScopeShape(object["expectedScope"]!)
        try operationKeys(object["provenance"]!, allowed: ["host", "sessionID", "runID", "source"], required: ["host", "sessionID", "runID", "source"])
        guard case .object(let provenance) = object["provenance"]! else { throw MemoryOperationError.invalidRequest("Invalid provenance") }
        try operationKeys(provenance["source"]!, allowed: ["startOffset", "endOffset", "excerptDigest"], required: ["startOffset", "endOffset", "excerptDigest"])
        try operationKeys(object["mutation"]!, allowed: ["kind", "request"], required: ["kind", "request"])
        guard case .object(let mutation) = object["mutation"]!, case .string(let kind) = mutation["kind"]! else {
            throw MemoryOperationError.invalidRequest("Invalid mutation")
        }
        let allowed: Set<String>, required: Set<String>
        switch kind {
        case "remember":
            allowed = ["content", "topic", "project", "source", "importance", "isPrivate", "parentId", "expiresInDays"]
            required = ["content", "isPrivate"]
        case "update":
            allowed = ["id", "content", "append", "prepend", "find", "replace", "topic", "project", "source", "importance", "expiresInDays", "isPrivate", "undelete"]
            required = ["id", "undelete"]
        case "connect":
            allowed = ["sourceId", "targetId", "relation"]
            required = allowed
        default: throw MemoryOperationError.invalidRequest("Invalid mutation")
        }
        try operationKeys(mutation["request"]!, allowed: allowed, required: required)
    }
}
