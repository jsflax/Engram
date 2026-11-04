import Foundation
import EngramMemoryCore
import EngramHUDContract
import EngramGraphSurface
import HUDNativeViewABI

enum GraphWireError: Error { case invalidEnvelope, staleRevision, identityMismatch, invalidated, unavailable }

/// Source-compatible selector API. The pure contract has no graph renderer/native provider.
public typealias EngramHUDGraphWire = EngramHUDContract.EngramHUDGraphWire

extension EngramHUDGraphWire {
    static func copiedPayload(_ raw: [String: Any], state: Bool = false) throws -> [String: Any] {
        var error: NSError?
        guard let value = HUDNativeCopyPayloadV1(raw, state ? stateSchema : snapshotSchema, 1,
            state ? HUDNativeSavedStateLimitsV1() : HUDNativeSnapshotLimitsV1(), &error) else {
            throw error ?? GraphWireError.invalidEnvelope as NSError
        }
        return value
    }
}

struct GraphEnvelope: Sendable {
    enum Phase: String, Sendable { case loading, ready, failed }
    let revision: UInt64
    let scope: EngramGraphScope
    let phase: Phase
    let data: Data?
    init(_ raw: [String: Any]) throws {
        let copy = try EngramHUDGraphWire.copiedPayload(raw)
        guard let values = copy["values"] as? [String: Any],
              let revision = copy["revision"] as? NSNumber,
              let phaseName = values["phase"] as? String, let phase = Phase(rawValue: phaseName),
              Set(values.keys) == (phase == .ready ? ["scope", "phase", "graphJSON"] : ["scope", "phase"])
        else { throw GraphWireError.invalidEnvelope }
        self.revision = revision.uint64Value
        self.scope = try EngramHUDGraphWire.scope(values["scope"])
        self.phase = phase
        if phase == .ready {
            guard let data = values["graphJSON"] as? Data, !data.isEmpty,
                  data.count <= EngramHUDGraphWire.maximumGraphBytes else { throw GraphWireError.invalidEnvelope }
            self.data = data
        } else { self.data = nil }
    }
}

protocol GraphSnapshotDecoding: Actor {
    func decode(_ data: Data) async throws -> EngramGraphSnapshot
}
actor GraphSnapshotDecoder: GraphSnapshotDecoding {
    func decode(_ data: Data) throws -> EngramGraphSnapshot {
        try Task.checkCancellation()
        guard data.count <= EngramHUDGraphWire.maximumGraphBytes else { throw GraphWireError.invalidEnvelope }
        let value = try EngramGraphSnapshot.decode(data)
        try Task.checkCancellation()
        return value
    }
}

struct GraphSavedState {
    let revision: UInt64
    let scope: EngramGraphScope
    let state: EngramGraphViewState
    init(_ raw: [String: Any]) throws {
        let copy = try EngramHUDGraphWire.copiedPayload(raw, state: true)
        guard let values = copy["values"] as? [String: Any], Set(values.keys) == ["scope", "camera"],
              let camera = values["camera"] as? [String: Any], let revision = copy["revision"] as? NSNumber
        else { throw GraphWireError.invalidEnvelope }
        scope = try EngramHUDGraphWire.scope(values["scope"])
        self.revision = revision.uint64Value
        state = try EngramGraphViewState.decode(JSONSerialization.data(withJSONObject: camera))
    }
    static func envelope(scope: EngramGraphScope, state: EngramGraphViewState, revision: UInt64) throws -> [String: Any] {
        let camera = try JSONSerialization.jsonObject(with: state.encoded())
        return try EngramHUDGraphWire.copiedPayload([
            "schemaIdentifier": EngramHUDGraphWire.stateSchema, "schemaVersion": 1, "revision": revision,
            "values": ["scope": EngramHUDGraphWire.scopeValues(scope), "camera": camera]], state: true)
    }
}
