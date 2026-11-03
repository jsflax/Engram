import Foundation

/// Optional graph-export capability. A host must construct an authenticated exporter;
/// accepting this request is not evidence that its scope strings grant permission.
public protocol EngramProjectGraphProviding: Sendable {
    func projectGraph(_ scope: EngramGraphScope) async throws -> EngramGraphSnapshot
}

public enum EngramGraphExportError: Error, Equatable, Sendable {
    case notAuthorized, authorizationChanged, storageUnavailable, inconsistentRows, revisionExhausted, capacity
}

/// An assertion made ONLY by the trusted connector/auth host for the exact service/store namespace
/// it constructed. Not Codable and never accepted from tool arguments or a view bundle. The host
/// authenticates the account, proves the store namespace belongs to it, and checks exact project /
/// topic access before issuing this value. Engram's Memory rows have no workspace column and cannot
/// independently prove that association. This value carries no credentials into a graph snapshot.
public struct EngramGraphReadGrant: Equatable, Sendable {
    public let connectionID: UUID
    public let connectionGeneration: UInt64
    public let principal: MemoryOperationPrincipalBinding
    public let scope: EngramGraphScope
    public let approvedGroupIDs: Set<UUID>

    public init(trustedConnectionID: UUID, connectionGeneration: UInt64,
                authenticatedPrincipal: Principal, authorizedScope: EngramGraphScope,
                approvedGroupIDs: Set<UUID>) throws {
        guard authenticatedPrincipal.id != nil, connectionGeneration > 0,
              approvedGroupIDs.isSubset(of: Set(authenticatedPrincipal.groupIds)) else {
            throw EngramGraphExportError.notAuthorized
        }
        self.connectionID = trustedConnectionID
        self.connectionGeneration = connectionGeneration
        self.principal = MemoryOperationPrincipalBinding(authenticatedPrincipal)
        self.scope = authorizedScope
        self.approvedGroupIDs = approvedGroupIDs
    }
}

/// Constructor-injected authority, owned by Connect/auth infrastructure. Implementations consult
/// an immutable admitted connection plus current revocation/generation state synchronously; they
/// must not do network work, prompt, or authenticate from request strings here. Rechecking the same
/// request must return the SAME grant while authorized, and throw/change generation on revocation.
public protocol EngramGraphReadAuthorizing: Sendable {
    func authorizeGraphRead(scope: EngramGraphScope, principal: Principal) throws -> EngramGraphReadGrant
}
