import Foundation
import EngramGraphContract

/// Selectors for one admitted native instance. These values confer no access by themselves.
public struct EngramGraphSessionIdentity: Equatable, Sendable {
    public let connectionID: String
    public let documentID: String
    public let documentLifetimeID: String
    public let instanceID: String
    public let scope: EngramGraphScope

    public init(connectionID: String, documentID: String, documentLifetimeID: String,
                instanceID: String, scope: EngramGraphScope) throws {
        for value in [connectionID, documentID, documentLifetimeID, instanceID] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= 256, !value.utf8.contains(0) else {
                throw EngramGraphSurfaceError.invalidIdentity
            }
        }
        self.connectionID = connectionID; self.documentID = documentID
        self.documentLifetimeID = documentLifetimeID; self.instanceID = instanceID; self.scope = scope
    }
}

public typealias EngramGraphSurfaceError = EngramGraphContract.EngramGraphSurfaceError

public enum EngramGraphVisibility: String, Sendable { case visible, hidden, suspended }
public enum EngramGraphLoadState: Equatable, Sendable { case idle, loading, ready, failed, revoked }

/// Only the host session can issue a request ticket. A cancelled/replaced request cannot publish.
public struct EngramGraphLoadTicket: Equatable, Sendable {
    let session: UUID
    let request: UUID
}

// The provider and optional host decode exactly the same camera contract.
public typealias EngramGraphViewState = EngramGraphContract.EngramGraphViewState
