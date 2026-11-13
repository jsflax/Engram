import Foundation
import Testing
import EngramGraphContract
import EngramHUDContract

@Suite(.timeLimit(.minutes(1))) struct EngramHUDGraphContractTests {
    @Test func canonicalSelectorRetainsItsPublishedWireAlgorithmWithoutRenderer() throws {
        let scope = try EngramGraphScope(workspaceID: "personal:00000000-0000-0000-0000-000000000001",
            project: "hud", topics: ["design", "code"])
        // Independently generated from UTF-8 lengths + SHA256; no provider/UI implementation linked.
        #expect(EngramHUDGraphWire.resourceIdentifier(for: scope) ==
            "project-graph-v1:021a3b8d6bc21cfa4d0ccf3434b91c3490904c17791c9c928eeb2386807e9407")
        #expect(EngramHUDGraphWire.provider == "engram")
        #expect(EngramHUDGraphWire.snapshotSchema == "io.jsflax.engram.project-graph")
        #expect(EngramHUDGraphWire.stateSchema == "io.jsflax.engram.project-graph-state")
    }
    @Test func wireScopeUsesThePortableValidatorAndRejectsAuthorityFields() throws {
        let scope = try EngramGraphScope(workspaceID: "personal:fixture", project: "hud", topics: ["b", "a"])
        #expect(try EngramHUDGraphWire.scope(EngramHUDGraphWire.scopeValues(scope)) == scope)
        var raw = EngramHUDGraphWire.scopeValues(scope); raw["token"] = "not-authority"
        #expect(throws: EngramHUDGraphContractError.invalidEnvelope) { _ = try EngramHUDGraphWire.scope(raw) }
        raw = EngramHUDGraphWire.scopeValues(scope); raw["topics"] = ["a", "a"]
        #expect(throws: EngramGraphError.duplicateIdentity) { _ = try EngramHUDGraphWire.scope(raw) }
    }
    @Test func exactProviderWorkspaceAndResourceRemainRequired() throws {
        let scope = try EngramGraphScope(workspaceID: "personal:fixture", project: "hud")
        let identity = ["providerIdentifier": "engram", "viewIdentifier": "projectGraph",
            "workspaceIdentifier": scope.workspaceID, "resourceIdentifier": EngramHUDGraphWire.resourceIdentifier(for: scope)]
        try EngramHUDGraphWire.require(scope, identity: identity)
        for (key, value) in [("providerIdentifier", "io.jsflax.engram"), ("workspaceIdentifier", "personal:other"),
                             ("resourceIdentifier", "project-graph-v1:other")] {
            var changed = identity; changed[key] = value
            #expect(throws: EngramHUDGraphContractError.identityMismatch) { try EngramHUDGraphWire.require(scope, identity: changed) }
        }
    }
}
