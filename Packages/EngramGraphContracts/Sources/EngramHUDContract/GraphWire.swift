import Foundation
import CryptoKit
import EngramGraphContract

public enum EngramHUDGraphContractError: Error, Equatable, Sendable { case invalidEnvelope, identityMismatch }

/// Canonical selector, never an authority grant. The trusted Connect host still authorizes export.
public enum EngramHUDGraphWire {
    public static let provider = "engram"
    public static let view = "projectGraph"
    public static let snapshotSchema = "io.jsflax.engram.project-graph"
    public static let stateSchema = "io.jsflax.engram.project-graph-state"
    public static let maximumGraphBytes = 4 * 1024 * 1024

    public static func resourceIdentifier(for scope: EngramGraphScope) -> String {
        // Length-prefixed UTF-8 is unambiguous even when identifiers contain delimiters.
        var data = Data("io.jsflax.engram.project-graph/resource/v1\0".utf8)
        for value in [scope.workspaceID, scope.project] + scope.topics {
            let bytes = Data(value.utf8)
            var count = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return "project-graph-v1:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func scope(_ raw: Any?) throws -> EngramGraphScope {
        guard let values = raw as? [String: Any], Set(values.keys) == ["workspaceID", "project", "topics"],
              let workspace = values["workspaceID"] as? String, let project = values["project"] as? String,
              let topics = values["topics"] as? [String] else { throw EngramHUDGraphContractError.invalidEnvelope }
        return try EngramGraphScope(workspaceID: workspace, project: project, topics: topics)
    }
    public static func scopeValues(_ scope: EngramGraphScope) -> [String: Any] {
        ["workspaceID": scope.workspaceID, "project": scope.project, "topics": scope.topics]
    }
    public static func require(_ scope: EngramGraphScope, identity: [String: String]) throws {
        guard identity["providerIdentifier"] == provider, identity["viewIdentifier"] == view,
              identity["workspaceIdentifier"] == scope.workspaceID,
              identity["resourceIdentifier"] == resourceIdentifier(for: scope) else { throw EngramHUDGraphContractError.identityMismatch }
    }
}
