import Foundation
import Testing
@testable import EngramMemoryCore

struct ProjectGraphServiceTests {
    @Test func trustedGrantRequiresAuthenticatedPrincipalAndCurrentGroups() throws {
        let scope = try EngramGraphScope(workspaceID: "account", project: "hud")
        #expect(throws: EngramGraphExportError.notAuthorized) {
            try EngramGraphReadGrant(trustedConnectionID: UUID(), connectionGeneration: 1,
                                     authenticatedPrincipal: .anonymous, authorizedScope: scope,
                                     approvedGroupIDs: [])
        }
        #expect(throws: EngramGraphExportError.notAuthorized) {
            try EngramGraphReadGrant(trustedConnectionID: UUID(), connectionGeneration: 1,
                                     authenticatedPrincipal: Principal(id: UUID(), kind: .user),
                                     authorizedScope: scope, approvedGroupIDs: [UUID()])
        }
        #expect(throws: EngramGraphExportError.notAuthorized) {
            try EngramGraphReadGrant(trustedConnectionID: UUID(), connectionGeneration: 0,
                                     authenticatedPrincipal: Principal(id: UUID(), kind: .user),
                                     authorizedScope: scope, approvedGroupIDs: [])
        }
    }

    @Test func exactConnectionGenerationScopeAndPrincipalRemainInGrant() throws {
        let account = UUID(), group = UUID(), connection = UUID()
        let scope = try EngramGraphScope(workspaceID: "account", project: "hud", topics: ["design"])
        let principal = Principal(id: account, kind: .user, groupIds: [group], scopes: ["viz-readonly"])
        func grant(generation: UInt64, scope: EngramGraphScope) throws -> EngramGraphReadGrant {
            try EngramGraphReadGrant(trustedConnectionID: connection, connectionGeneration: generation,
                                     authenticatedPrincipal: principal, authorizedScope: scope,
                                     approvedGroupIDs: [group])
        }
        let admitted = try grant(generation: 1, scope: scope)
        #expect(admitted.principal == MemoryOperationPrincipalBinding(principal))
        #expect(admitted.connectionID == connection && admitted.scope == scope)
        #expect(admitted != (try grant(generation: 2, scope: scope)))
        #expect(admitted != (try grant(generation: 1, scope: EngramGraphScope(workspaceID: "other", project: "hud", topics: ["design"]))))
        #expect(admitted != (try grant(generation: 1, scope: EngramGraphScope(workspaceID: "account", project: "hud"))))
    }
}
