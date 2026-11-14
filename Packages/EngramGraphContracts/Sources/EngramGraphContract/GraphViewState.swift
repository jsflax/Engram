import Foundation

// Shared pure validation for persisted native camera state. The Surface aliases preserve its
// existing public error type and callers without linking a renderer into the native host.
public enum EngramGraphSurfaceError: Error, Equatable, Sendable {
    case invalidIdentity, identityMismatch, staleRequest, staleRevision, revoked, invalidState, alreadyMounted
}

/// Bounded presentation state only. Contains no memory content, credentials, filters or action.
/// The host saves it under its exact document/instance identity; restoration never changes scope.
public struct EngramGraphViewState: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public let selectedNode: UUID?
    public let azimuth: Double
    public let elevation: Double
    public let target: EngramGraphPosition
    public let orbitRadius: Double

    public init(selectedNode: UUID?, azimuth: Double, elevation: Double,
                target: EngramGraphPosition, orbitRadius: Double) throws {
        guard azimuth.isFinite, abs(azimuth) <= 1_000_000,
              elevation.isFinite, abs(elevation) <= Double(Float.pi / 2 - 0.1),
              orbitRadius.isFinite, (1...10_000_000).contains(orbitRadius) else {
            throw EngramGraphSurfaceError.invalidState
        }
        self.selectedNode = selectedNode; self.azimuth = azimuth; self.elevation = elevation
        self.target = target; self.orbitRadius = orbitRadius
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 2_048 else { throw EngramGraphSurfaceError.invalidState }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 2_048 else { throw EngramGraphSurfaceError.invalidState }
        return data
    }
    private enum CodingKeys: String, CodingKey { case version, selectedNode, azimuth, elevation, target, orbitRadius }
    public init(from decoder: any Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        guard try value.decode(Int.self, forKey: .version) == Self.schemaVersion else {
            throw EngramGraphSurfaceError.invalidState
        }
        try self.init(selectedNode: value.decodeIfPresent(UUID.self, forKey: .selectedNode),
                      azimuth: value.decode(Double.self, forKey: .azimuth),
                      elevation: value.decode(Double.self, forKey: .elevation),
                      target: value.decode(EngramGraphPosition.self, forKey: .target),
                      orbitRadius: value.decode(Double.self, forKey: .orbitRadius))
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(Self.schemaVersion, forKey: .version)
        try value.encodeIfPresent(selectedNode, forKey: .selectedNode)
        try value.encode(azimuth, forKey: .azimuth); try value.encode(elevation, forKey: .elevation)
        try value.encode(target, forKey: .target); try value.encode(orbitRadius, forKey: .orbitRadius)
    }
}
