import Foundation
import Testing
import EngramMemoryCore
import EngramGraphContract

@Suite(.timeLimit(.minutes(1)))
struct GraphSnapshotAliasTests {
    @Test func legacyMemoryCoreNamesAreTheSamePureContractTypesAndWireValues() throws {
        let scope: EngramMemoryCore.EngramGraphScope = try EngramGraphContract.EngramGraphScope(
            workspaceID: "fixture", project: "hud", topics: ["sync"])
        let position: EngramMemoryCore.EngramGraphPosition = try EngramGraphContract.EngramGraphPosition(x: 1, y: 2, z: 3)
        let node: EngramMemoryCore.EngramGraphNode = EngramGraphContract.EngramGraphNode(
            id: UUID(), project: "hud", topic: "sync", label: "Same type", importance: 2, isHub: false, position: position)
        let edge: EngramMemoryCore.EngramGraphEdge = EngramGraphContract.EngramGraphEdge(
            id: UUID(), sourceID: node.id, targetID: node.id, relation: "related_to")
        let snapshot: EngramMemoryCore.EngramGraphSnapshot = try EngramGraphContract.EngramGraphSnapshot(
            scope: scope, revision: 1, completeness: .complete, nodes: [node], edges: [edge])
        let encoded = try snapshot.encoded()
        #expect(try EngramMemoryCore.EngramGraphSnapshot.decode(encoded) == EngramGraphContract.EngramGraphSnapshot.decode(encoded))
        let error: EngramMemoryCore.EngramGraphError = EngramGraphContract.EngramGraphError.capacity
        #expect(error == .capacity)
        #expect(ObjectIdentifier(EngramMemoryCore.EngramGraphLimits.self) == ObjectIdentifier(EngramGraphContract.EngramGraphLimits.self))
        #expect(ObjectIdentifier(EngramMemoryCore.EngramGraphSnapshot.self) == ObjectIdentifier(EngramGraphContract.EngramGraphSnapshot.self))
    }
}
