@testable import Engram
import EngramKit
import Lattice
import XCTest

@MainActor
final class AdapterSnapshotTests: XCTestCase {
    private let config = DrainConfig(hiddenProjects: [], hiddenRelations: [], timeFilter: nil,
                                     is3D: true, soundEnabled: false, notificationsEnabled: false)

    func testAppendDoesNotHideEditsToExistingNodeMetadataOrHubStyle() throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let original = node()
        galaxy.insertNodeBatch([original], config: config)
        galaxy.renderStore.bumpTopology()
        let adapter = GalaxyRegistryAdapter(registry: registry)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.first?.label, "Original")

        let changed = node(id: original.id, label: "Changed", topic: "New topic")
        galaxy.renderStore.nodes[0] = changed
        galaxy.renderStore.nodeById[changed.id] = changed
        galaxy.renderStore.hubs.insert(changed.id)
        galaxy.insertNodeBatch([node()], config: config)
        galaxy.renderStore.bumpTopology()
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.count, 2)
        XCTAssertEqual(adapter.nodes[0].label, "Changed")
        XCTAssertEqual(adapter.nodes[0].topic, "New topic")
        XCTAssertTrue(adapter.nodes[0].isHub)
    }

    func testEdgeAppendPreservesSimultaneousEndpointAndRelationEdit() throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let nodes = [node(), node(), node()]
        galaxy.insertNodeBatch(nodes, config: config)
        let original = EdgeData(id: UUID(), sourceId: nodes[0].id, targetId: nodes[1].id, relation: "relates_to")
        galaxy.renderStore.edges = [original]
        galaxy.renderStore.bumpTopology()
        let adapter = GalaxyRegistryAdapter(registry: registry)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.count, 1)

        galaxy.renderStore.edges = [
            EdgeData(id: original.id, sourceId: nodes[0].id, targetId: nodes[2].id, relation: "part_of"),
            EdgeData(id: UUID(), sourceId: nodes[1].id, targetId: nodes[2].id, relation: "relates_to"),
        ]
        galaxy.renderStore.bumpTopology()
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.count, 2)
        XCTAssertEqual(adapter.edges[0].targetId, nodes[2].id)
        XCTAssertEqual(adapter.edges[0].relation, "part_of")

        galaxy.renderStore.edges.removeFirst()
        galaxy.renderStore.bumpTopology()
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.count, 1)
        XCTAssertEqual(adapter.edges[0].sourceId, nodes[1].id)
    }

    private func node(id: UUID = UUID(), label: String = "Original", topic: String = "Topic") -> NodeData {
        NodeData(id: id, project: "Project", topic: topic, label: label, content: label,
                 createdAt: .distantPast, lastAccessedAt: .distantPast, importance: 3)
    }
}
