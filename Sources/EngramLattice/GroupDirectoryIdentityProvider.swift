import EngramMemoryCore
import Foundation

/// The CLI/hook identity source: the daemon-authored groups.json
/// (`selfUserId` + memberships). Deliberately not the Keychain — short-lived
/// hook processes can't reliably read it, and userId is not a secret.
///
/// This is the DEFAULT `IdentityProviding` for every on-device MemoryTools;
/// the HTTP service constructs a `StaticIdentityProvider` from the
/// authenticated token instead (identity is constructor state, never
/// ambient — increment 1b).
public struct GroupDirectoryIdentityProvider: IdentityProviding {
    public init() {}

    public func currentPrincipal() -> Principal {
        let userId = GroupDirectory.currentUserId()
        let groups = GroupDirectory.load()?.groups.map(\.id) ?? []
        return Principal(id: userId, kind: .user,
                         displayName: nil,
                         groupIds: groups,
                         scopes: ["full"])
    }
}
