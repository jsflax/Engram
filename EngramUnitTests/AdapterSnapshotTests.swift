@testable import Engram
import EngramKit
import EngramSceneKit
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

    func testSimulationIndexGenerationPreservesAppendButInvalidatesCompaction() {
        let sim = ForceSimulation3D()
        let a = UUID(), b = UUID(), c = UUID()
        sim.addNode(a, project: "Project", topic: "Topic")
        sim.setPosition(a, to: SIMD3<Float>(1, 2, 3))
        let layout = sim.nodeIndexGeneration
        let oldGPUOrder = sim.nodeOrderVersion
        sim.addNode(b, project: "Project", topic: "Topic")
        sim.setPosition(b, to: SIMD3<Float>(4, 5, 6))
        XCTAssertEqual(sim.nodeIndexGeneration, layout)
        XCTAssertNotEqual(sim.nodeOrderVersion, oldGPUOrder)
        XCTAssertEqual(sim.index(for: a), 0)
        XCTAssertEqual(sim.index(for: b), 1)
        // Appending keeps CPU indices valid, but must still reject old GPU work.
        sim.applyGPUForces(ForceResult(positions: [.zero, .zero]), expectedNodeOrderVersion: oldGPUOrder)
        XCTAssertEqual(sim.positions[a], SIMD3<Float>(1, 2, 3))
        XCTAssertEqual(sim.positions[b], SIMD3<Float>(4, 5, 6))

        let beforeDeleteOrder = sim.nodeOrderVersion
        sim.removeNodes([a])
        sim.addNode(c, project: "Project", topic: "Topic")
        sim.setPosition(c, to: SIMD3<Float>(7, 8, 9))
        XCTAssertNotEqual(sim.nodeIndexGeneration, layout)
        XCTAssertNil(sim.index(for: a))
        XCTAssertEqual(sim.index(for: b), 0)
        XCTAssertEqual(sim.index(for: c), 1)
        sim.applyGPUForces(ForceResult(positions: [.zero, .zero]), expectedNodeOrderVersion: beforeDeleteOrder)
        XCTAssertEqual(sim.positions[b], SIMD3<Float>(4, 5, 6))
        XCTAssertEqual(sim.positions[c], SIMD3<Float>(7, 8, 9))

        let compacted = sim.nodeIndexGeneration
        sim.updateGraph(nodeIds: [b, c], edges: [])
        XCTAssertNotEqual(sim.nodeIndexGeneration, compacted)
        XCTAssertEqual(sim.index(for: b), 0)
        XCTAssertEqual(sim.index(for: c), 1)
    }

    func testIndexCacheVisitsOnlyAppendedAndPreviouslyMissingNodes() {
        let sim = ForceSimulation3D()
        let a = UUID(), b = UUID(), c = UUID(), missing = UUID()
        sim.addNode(a, project: "Project", topic: "Topic")
        sim.addNode(b, project: "Project", topic: "Topic")
        var ids = [b, a, missing]
        var cache = SimulationIndexCache()
        var visited: [Int] = []
        XCTAssertTrue(cache.refresh(nodeCount: ids.count, preservingPrefix: true, simulation: sim) {
            visited.append($0); return ids[$0]
        })
        XCTAssertEqual(visited, [0, 1, 2])
        XCTAssertEqual(cache.indices, [1, 0, -1])

        visited = []
        XCTAssertFalse(cache.refresh(nodeCount: ids.count, preservingPrefix: true, simulation: sim) {
            visited.append($0); return ids[$0]
        })
        XCTAssertTrue(visited.isEmpty)

        sim.addNode(c, project: "Project", topic: "Topic")
        XCTAssertFalse(cache.refresh(nodeCount: ids.count, preservingPrefix: true, simulation: sim) {
            visited.append($0); return ids[$0]
        })
        XCTAssertEqual(visited, [2])
        XCTAssertEqual(cache.indices, [1, 0, -1])

        sim.addNode(missing, project: "Project", topic: "Topic")
        ids.append(c)
        visited = []
        XCTAssertTrue(cache.refresh(nodeCount: ids.count, preservingPrefix: true, simulation: sim) {
            visited.append($0); return ids[$0]
        })
        XCTAssertEqual(visited, [2, 3])
        XCTAssertEqual(cache.indices, [1, 0, 3, 2])

        // Edge revisions do not change slots or require any UUID lookup.
        sim.addEdge(from: a, to: b)
        visited = []
        XCTAssertFalse(cache.refresh(nodeCount: ids.count, preservingPrefix: true, simulation: sim) {
            visited.append($0); return ids[$0]
        })
        XCTAssertTrue(visited.isEmpty)

        // A simulation-only append also leaves every resolved render index valid.
        sim.addNode(UUID(), project: "Other", topic: "Topic")
        XCTAssertFalse(cache.refresh(nodeCount: ids.count, preservingPrefix: true, simulation: sim) {
            visited.append($0); return ids[$0]
        })
        XCTAssertTrue(visited.isEmpty)
    }

    func testIndexCacheRejectsStalePrefixCompactionAndSimulationIdentity() {
        let sim = ForceSimulation3D()
        let a = UUID(), b = UUID(), c = UUID()
        for id in [a, b] { sim.addNode(id, project: "Project", topic: "Topic") }
        var ids = [a, b]
        var cache = SimulationIndexCache()
        _ = cache.refresh(nodeCount: ids.count, preservingPrefix: true, simulation: sim) { ids[$0] }
        sim.removeNodes([a])
        sim.addNode(c, project: "Project", topic: "Topic")
        ids = [c, b]
        var visited: [Int] = []
        XCTAssertTrue(cache.refresh(nodeCount: ids.count, preservingPrefix: true, simulation: sim) {
            visited.append($0); return ids[$0]
        })
        XCTAssertEqual(visited, [0, 1])
        XCTAssertEqual(cache.indices, [1, 0])

        ids = [b, c]
        XCTAssertTrue(cache.refresh(nodeCount: ids.count, preservingPrefix: false, simulation: sim) { ids[$0] })
        XCTAssertEqual(cache.indices, [0, 1])
        let replacement = ForceSimulation3D()
        for id in [c, b] { replacement.addNode(id, project: "Project", topic: "Topic") }
        replacement.updateGraph(nodeIds: [b, c], edges: [])
        XCTAssertEqual(replacement.nodeIndexGeneration, sim.nodeIndexGeneration)
        XCTAssertTrue(cache.refresh(nodeCount: ids.count, preservingPrefix: true, simulation: replacement) { ids[$0] })
        XCTAssertEqual(cache.indices, [1, 0])
        ids.removeLast()
        XCTAssertTrue(cache.refresh(nodeCount: ids.count, preservingPrefix: true, simulation: replacement) { ids[$0] })
        XCTAssertEqual(cache.indices, [1])
        ids.removeAll()
        XCTAssertTrue(cache.refresh(nodeCount: 0, preservingPrefix: false, simulation: replacement) { ids[$0] })
        XCTAssertTrue(cache.indices.isEmpty)
    }

    func testAdapterAppendUsesRenderOrderRatherThanSimulationOrder() throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let sim = registry.unifiedSimulation
        sim.isActive = false
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let a = node(), b = node(), c = node()
        for n in [b, a] { sim.addNode(n.id, project: n.project, topic: n.topic) }
        galaxy.insertNodeBatch([a, b], config: config)
        galaxy.renderStore.bumpTopology()
        let pa = SIMD3<Float>(1, 2, 3), pb = SIMD3<Float>(4, 5, 6), pc = SIMD3<Float>(7, 8, 9)
        sim.setPosition(a.id, to: pa)
        sim.setPosition(b.id, to: pb)
        let adapter = GalaxyRegistryAdapter(registry: registry)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, b.id])
        XCTAssertEqual(adapter.positionArray, [pa, pb])

        galaxy.insertNodeBatch([c], config: config)
        galaxy.renderStore.bumpTopology()
        sim.setPosition(c.id, to: pc)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(adapter.positionArray, [pa, pb, pc])
        galaxy.renderStore.colorMap[a.project] = .red
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.positionArray, [pa, pb, pc])
        XCTAssertEqual(adapter.projectColorMap[a.project], adapter.galaxySnapshots.first?.dominantColor)
    }

    func testAdapterResolvesMissingSimulationNodeWithoutRenderRevision() throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        registry.unifiedSimulation.isActive = false
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let n = node()
        let flatConfig = DrainConfig(hiddenProjects: [], hiddenRelations: [], timeFilter: nil,
                                     is3D: false, soundEnabled: false, notificationsEnabled: false)
        galaxy.insertNodeBatch([n], config: flatConfig)
        galaxy.renderStore.bumpTopology()
        let adapter = GalaxyRegistryAdapter(registry: registry)
        adapter.tick(dt: 1 / 60)
        let topology = adapter.topologyVersion
        XCTAssertEqual(adapter.positionArray, [.zero])
        registry.unifiedSimulation.addNode(n.id, project: n.project, topic: n.topic)
        registry.unifiedSimulation.setPosition(n.id, to: SIMD3<Float>(10, 20, 30))
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.topologyVersion, topology)
        XCTAssertEqual(adapter.positionArray, [SIMD3<Float>(10, 20, 30)])
    }

    func testAdapterSameCountReplacementAndReorderCannotReuseOldSlots() throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let sim = registry.unifiedSimulation
        sim.isActive = false
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let a = node(), b = node(), c = node()
        galaxy.insertNodeBatch([a, b], config: config)
        galaxy.renderStore.pkToGlobalId[1] = a.id
        galaxy.renderStore.bumpTopology()
        let pa = SIMD3<Float>(1, 2, 3), pb = SIMD3<Float>(4, 5, 6), pc = SIMD3<Float>(7, 8, 9)
        sim.setPosition(a.id, to: pa)
        sim.setPosition(b.id, to: pb)
        let adapter = GalaxyRegistryAdapter(registry: registry)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.positionArray, [pa, pb])
        galaxy.handleNodeDelete(1, config: config)
        galaxy.insertNodeBatch([c], config: config)
        galaxy.renderStore.bumpTopology()
        sim.setPosition(c.id, to: pc)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [b.id, c.id])
        XCTAssertEqual(adapter.positionArray, [pb, pc])
        galaxy.renderStore.nodes.reverse()
        galaxy.renderStore.bumpTopology()
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [c.id, b.id])
        XCTAssertEqual(adapter.positionArray, [pc, pb])
    }

    private func node(id: UUID = UUID(), label: String = "Original", topic: String = "Topic") -> NodeData {
        NodeData(id: id, project: "Project", topic: topic, label: label, content: label,
                 createdAt: .distantPast, lastAccessedAt: .distantPast, importance: 3)
    }
}
