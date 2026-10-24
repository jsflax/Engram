@testable import Engram
import EngramKit
import EngramSceneKit
import EngramRealityKit
import Lattice
import RealityKit
import XCTest

@MainActor
final class AdapterSnapshotTests: XCTestCase {
    private let config = DrainConfig(hiddenProjects: [], hiddenRelations: [], timeFilter: nil,
                                     is3D: true, soundEnabled: false, notificationsEnabled: false)

    func testSparsePositionsFollowSimulationChangesAndRegistryReplacement() {
        let registry = GalaxyRegistry(), replacement = GalaxyRegistry()
        let adapter = GalaxyRegistryAdapter(registry: registry)
        let erased: any SceneDataProvider = adapter
        let a = UUID(), b = UUID(), c = UUID()
        let sim = registry.unifiedSimulation
        XCTAssertNil(erased.position(for: a))
        sim.addNode(b, project: "p", topic: "t")
        sim.addNode(a, project: "p", topic: "t")
        sim.setPosition(a, to: SIMD3(1, 2, 3))
        sim.setPosition(b, to: SIMD3(4, 5, 6))
        XCTAssertTrue(adapter.nodes.isEmpty, "Sparse positions are simulation values, not render-array slots")
        XCTAssertEqual(erased.position(for: a), sim.positions[a])
        XCTAssertEqual(erased.position(for: b), sim.positions[b])

        // No adapter tick or render revision is needed to see moved coordinates.
        sim.setPosition(a, to: SIMD3(7, 8, 9))
        XCTAssertEqual(erased.position(for: a), SIMD3<Float>(7, 8, 9))
        sim.addNode(c, project: "p", topic: "t")
        sim.setPosition(c, to: SIMD3(10, 11, 12))
        XCTAssertEqual(erased.position(for: c), SIMD3<Float>(10, 11, 12))
        sim.removeNodes([b])
        XCTAssertEqual(sim.index(for: a), 0)
        XCTAssertNil(erased.position(for: b))
        XCTAssertEqual(erased.position(for: a), SIMD3<Float>(7, 8, 9))
        XCTAssertEqual(erased.position(for: c), SIMD3<Float>(10, 11, 12))
        sim.removeNodes([a])
        XCTAssertNil(erased.position(for: a))
        XCTAssertEqual(erased.position(for: c), SIMD3<Float>(10, 11, 12))

        replacement.unifiedSimulation.addNode(a, project: "p", topic: "t")
        replacement.unifiedSimulation.setPosition(a, to: SIMD3(13, 14, 15))
        adapter.registry = replacement
        XCTAssertEqual(erased.position(for: a), SIMD3<Float>(13, 14, 15))
        XCTAssertNil(erased.position(for: c))
        adapter.registry = nil
        XCTAssertNil(erased.position(for: a))
    }

    func testMascotVisibilityReachesSceneAndPreservesExistingEntities() throws {
        let registry = GalaxyRegistry()
        let manager = try XCTUnwrap(RKSceneManager(registry: registry))
        let mascot = Entity()
        mascot.position = SIMD3<Float>(1, 2, 3)
        manager.rkScene.mascotContainer.addChild(mascot)
        XCTAssertTrue(manager.showMascots)
        XCTAssertTrue(manager.rkScene.mascotContainer.isEnabled)

        manager.showMascots = false
        XCTAssertFalse(manager.rkScene.showMascots)
        XCTAssertFalse(manager.rkScene.mascotContainer.isEnabled)
        XCTAssertTrue(mascot.parent === manager.rkScene.mascotContainer)
        XCTAssertFalse(mascot.isEnabledInHierarchy)
        // An already-started async factory may finish while hidden.
        let lateMascot = Entity()
        lateMascot.position = SIMD3<Float>(4, 5, 6)
        manager.rkScene.mascotContainer.addChild(lateMascot)
        XCTAssertFalse(lateMascot.isEnabledInHierarchy)

        manager.showMascots = true
        XCTAssertTrue(manager.rkScene.showMascots)
        XCTAssertTrue(manager.rkScene.mascotContainer.isEnabled)
        XCTAssertTrue(manager.rkScene.mascotContainer.children.first === mascot)
        XCTAssertTrue(lateMascot.parent === manager.rkScene.mascotContainer)
        XCTAssertTrue(mascot.isEnabledInHierarchy)
        XCTAssertTrue(lateMascot.isEnabledInHierarchy)
        XCTAssertEqual(mascot.position, SIMD3<Float>(1, 2, 3))
        XCTAssertEqual(lateMascot.position, SIMD3<Float>(4, 5, 6))
    }

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
        let originalEdgeVersion = adapter.edgeVersion
        let originalNodeVersion = adapter.nodeVersion

        galaxy.renderStore.edges = [
            EdgeData(id: original.id, sourceId: nodes[0].id, targetId: nodes[2].id, relation: "part_of"),
            EdgeData(id: UUID(), sourceId: nodes[1].id, targetId: nodes[2].id, relation: "relates_to"),
        ]
        galaxy.renderStore.bumpTopology()
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.count, 2)
        XCTAssertEqual(adapter.edges[0].targetId, nodes[2].id)
        XCTAssertEqual(adapter.edges[0].relation, "part_of")
        XCTAssertNotEqual(adapter.edgeVersion, originalEdgeVersion)
        XCTAssertEqual(adapter.nodeVersion, originalNodeVersion)
        let editedEdgeVersion = adapter.edgeVersion

        galaxy.renderStore.edges.removeFirst()
        galaxy.renderStore.bumpTopology()
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.count, 1)
        XCTAssertEqual(adapter.edges[0].sourceId, nodes[1].id)
        XCTAssertNotEqual(adapter.edgeVersion, editedEdgeVersion)
        XCTAssertEqual(adapter.nodeVersion, originalNodeVersion)
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
        XCTAssertTrue(adapter.projectCentroids.isEmpty)
        XCTAssertTrue(adapter.nebulaClusters.isEmpty)
        XCTAssertEqual(adapter.galaxySnapshots.first?.nodeCount, 0)
        XCTAssertEqual(adapter.galaxySnapshots.first?.radius, 300)
        registry.unifiedSimulation.addNode(n.id, project: n.project, topic: n.topic)
        registry.unifiedSimulation.setPosition(n.id, to: SIMD3<Float>(10, 20, 30))
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.topologyVersion, topology)
        XCTAssertEqual(adapter.positionArray, [SIMD3<Float>(10, 20, 30)])
        XCTAssertTrue(adapter.projectCentroids.isEmpty, "Position-only publication keeps the 30-frame cadence")
        for _ in 3...30 { adapter.tick(dt: 1 / 60) }
        XCTAssertEqual(adapter.projectCentroids[n.project], SIMD3<Float>(10, 20, 30))
        XCTAssertEqual(adapter.nebulaClusters.first?.count, 1)
        XCTAssertEqual(adapter.nebulaClusters.first?.radius, 40)
        XCTAssertEqual(adapter.galaxySnapshots.first?.nodeCount, 1)
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

    func testStreamingCentroidsKeepPreviewUntilFrameThirtyWithoutDelayingNodes() async throws {
        let (lattice, registry, galaxy, generation, adapter) = try await streamingFixture()
        defer { lattice.close() }
        let a = node(), b = node()
        let origin = SIMD3<Float>.zero, next = SIMD3<Float>(60, 0, 0)
        galaxy.applyLoadChunk(nodes: [(1, a)], generation: generation)
        registry.unifiedSimulation.setPosition(a.id, to: origin)
        adapter.tick(dt: 1 / 60) // Frame 1: the first preview is immediate.
        XCTAssertFalse(galaxy.isDrainingInitialSnapshot)
        XCTAssertEqual(galaxy.loadStatus, .loading)
        XCTAssertEqual(adapter.projectCentroids[a.project], origin)
        XCTAssertEqual(adapter.nebulaClusters.first?.count, 1)
        XCTAssertEqual(adapter.galaxySnapshots.first?.nodeCount, 1)

        galaxy.applyLoadChunk(nodes: [(2, b)], generation: generation)
        registry.unifiedSimulation.setPosition(b.id, to: next)
        adapter.tick(dt: 1 / 60) // Frame 2: render data still publishes immediately.
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, b.id])
        XCTAssertEqual(adapter.positionArray, [origin, next])
        XCTAssertTrue(registry.galaxyForNode(a.id) === galaxy)
        XCTAssertTrue(registry.galaxyForNode(b.id) === galaxy)
        for _ in 3...29 { adapter.tick(dt: 1 / 60) }
        XCTAssertEqual(adapter.projectCentroids[a.project], origin)
        XCTAssertEqual(adapter.nebulaClusters.first?.count, 1)
        XCTAssertEqual(adapter.galaxySnapshots.first?.nodeCount, 1)

        adapter.tick(dt: 1 / 60) // Frame 30: all derived aggregates catch up.
        XCTAssertEqual(adapter.projectCentroids[a.project], SIMD3<Float>(30, 0, 0))
        let cluster = try XCTUnwrap(adapter.nebulaClusters.first)
        XCTAssertEqual(cluster.count, 2)
        XCTAssertEqual(cluster.centroid, SIMD3<Float>(30, 0, 0))
        XCTAssertEqual(cluster.radius, 70, accuracy: 0.0001)
        XCTAssertEqual(adapter.galaxySnapshots.first?.nodeCount, 2)
        XCTAssertEqual(adapter.positionArray, [origin, next])
    }

    func testOptionalTickTimingsPreserveAdapterOutputsAndPublicationCadence() async throws {
        let (plainLattice, plainRegistry, plainGalaxy, plainGeneration, plain) = try await streamingFixture()
        defer { plainLattice.close() }
        let (timedLattice, timedRegistry, timedGalaxy, timedGeneration, timed) = try await streamingFixture()
        defer { timedLattice.close() }
        let a = node(), b = node()
        let origin = SIMD3<Float>.zero, next = SIMD3<Float>(60, 0, 0)
        for frame in 1...30 {
            if frame <= 2 {
                let value = frame == 1 ? a : b
                let position = frame == 1 ? origin : next
                plainGalaxy.applyLoadChunk(nodes: [(Int64(frame), value)], generation: plainGeneration)
                timedGalaxy.applyLoadChunk(nodes: [(Int64(frame), value)], generation: timedGeneration)
                plainRegistry.unifiedSimulation.setPosition(value.id, to: position)
                timedRegistry.unifiedSimulation.setPosition(value.id, to: position)
            }
            plain.tick(dt: 1 / 60)
            XCTAssertNotNil(timed.tickWithTimings(dt: 1 / 60))
            XCTAssertEqual(timed.nodes.map(\.id), plain.nodes.map(\.id))
            XCTAssertEqual(timed.positionArray, plain.positionArray)
            XCTAssertEqual(timed.projectCentroids, plain.projectCentroids)
            XCTAssertEqual(timed.nebulaClusters.first?.centroid, plain.nebulaClusters.first?.centroid)
            XCTAssertEqual(timed.nebulaClusters.first?.count, plain.nebulaClusters.first?.count)
            XCTAssertEqual(timed.nebulaClusters.first?.radius, plain.nebulaClusters.first?.radius)
            XCTAssertEqual(timed.galaxySnapshots.first?.nodeCount, plain.galaxySnapshots.first?.nodeCount)
            XCTAssertEqual(timed.galaxySnapshots.first?.radius, plain.galaxySnapshots.first?.radius)
            // A duplicate or omitted provider tick would publish at the wrong
            // frame even if both paths eventually contained the same nodes.
            XCTAssertEqual(timed.projectCentroids[a.project], frame < 30 ? origin : SIMD3<Float>(30, 0, 0))
            XCTAssertEqual(timed.nebulaClusters.first?.count, frame < 30 ? 1 : 2)
        }
        XCTAssertEqual(timed.nodes.map(\.id), [a.id, b.id])
        XCTAssertEqual(timed.positionArray, [origin, next])
        XCTAssertEqual(timed.nebulaClusters.first?.radius, 70)
        timed.registry = nil
        XCTAssertNil(timed.tickWithTimings(dt: 1 / 60))
    }

    func testStreamingTerminalStatesAndCompletedEditsRefreshCentroidsImmediately() async throws {
        for terminal in [GalaxyLoadStatus.complete, .failed, .cancelled] {
            let (lattice, registry, galaxy, generation, adapter) = try await streamingFixture()
            defer { lattice.close() }
            let a = node(), b = node(), c = node()
            galaxy.applyLoadChunk(nodes: [(1, a)], generation: generation)
            registry.unifiedSimulation.setPosition(a.id, to: .zero)
            adapter.tick(dt: 1 / 60)
            galaxy.applyLoadChunk(nodes: [(2, b)], generation: generation)
            registry.unifiedSimulation.setPosition(b.id, to: SIMD3<Float>(60, 0, 0))
            adapter.tick(dt: 1 / 60)
            XCTAssertEqual(adapter.projectCentroids[a.project], .zero)
            XCTAssertEqual(adapter.galaxySnapshots.first?.nodeCount, 1)

            // Match setLoadStatus's existing terminal-state/topology publication.
            galaxy.loadStatus = terminal
            galaxy.isLoaded = terminal == .complete
            galaxy.renderStore.bumpTopology()
            adapter.tick(dt: 1 / 60) // Frame 3, not the periodic frame 30.
            XCTAssertEqual(adapter.projectCentroids[a.project], SIMD3<Float>(30, 0, 0))
            XCTAssertEqual(adapter.nebulaClusters.first?.count, 2)
            XCTAssertEqual(adapter.galaxySnapshots.first?.nodeCount, 2)
            if terminal == .complete {
                galaxy.applyLoadChunk(nodes: [(3, c)], generation: generation)
                registry.unifiedSimulation.setPosition(c.id, to: SIMD3<Float>(120, 0, 0))
                adapter.tick(dt: 1 / 60) // An ordinary live edit also refreshes now.
                XCTAssertEqual(adapter.nodes.map(\.id), [a.id, b.id, c.id])
                XCTAssertEqual(adapter.projectCentroids[a.project], SIMD3<Float>(60, 0, 0))
                XCTAssertEqual(adapter.nebulaClusters.first?.count, 3)
                XCTAssertEqual(adapter.galaxySnapshots.first?.nodeCount, 3)
            }
        }
    }

    func testStreamingAppendContinuitySpansSeveralChunksBeforePublication() async throws {
        let (lattice, registry, galaxy, generation, adapter) = try await streamingFixture()
        defer { lattice.close() }
        let a = node(label: "First"), b = node(label: "Second"), c = node(label: "Third")
        let d = node(label: "Fourth")
        galaxy.applyLoadChunk(nodes: [(1, a)], generation: generation)
        registry.unifiedSimulation.setPosition(a.id, to: SIMD3<Float>(1, 0, 0))
        adapter.tick(dt: 1 / 60)
        let retained = adapter.nodes
        let compared = adapter.nodePrefixComparisonCount
        let built = adapter.nodeSnapshotBuildCount
        let routed = registry.routingNodeVisitCount
        let appendGeneration = galaxy.renderStore.nodeAppendGeneration

        // More than one producer page may arrive between renderer ticks.
        galaxy.applyLoadChunk(nodes: [(2, b)], generation: generation)
        galaxy.applyLoadChunk(nodes: [(3, c), (4, d)], generation: generation)
        for (index, value) in [b, c, d].enumerated() {
            registry.unifiedSimulation.setPosition(value.id, to: SIMD3<Float>(Float(index + 2), 0, 0))
        }
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, b.id, c.id, d.id])
        XCTAssertEqual(adapter.nodes.map(\.label), ["First", "Second", "Third", "Fourth"])
        XCTAssertEqual(adapter.positionArray, [1, 2, 3, 4].map { SIMD3<Float>(Float($0), 0, 0) })
        XCTAssertEqual(retained.map(\.id), [a.id], "Published snapshots must remain immutable")
        XCTAssertTrue([a, b, c, d].allSatisfy { registry.galaxyForNode($0.id) === galaxy })
        XCTAssertEqual(Set(registry.nodeToGalaxy.keys), Set([a.id, b.id, c.id, d.id]))
        XCTAssertEqual(galaxy.renderStore.nodeAppendGeneration, appendGeneration)
        XCTAssertEqual(adapter.nodePrefixComparisonCount, compared)
        XCTAssertEqual(adapter.nodeSnapshotBuildCount - built, 3)
        XCTAssertEqual(registry.routingNodeVisitCount - routed, 3)

        // A separate consumer can publish more than once between adapter
        // frames. An older certificate must not certify this adapter's prefix.
        let e = node(label: "Fifth"), f = node(label: "Sixth")
        let staleVersion = adapter.nodeVersion
        galaxy.applyLoadChunk(nodes: [(5, e)], generation: generation)
        registry.mergeRenderData()
        galaxy.applyLoadChunk(nodes: [(6, f)], generation: generation)
        registry.mergeRenderData()
        XCTAssertNil(registry.preservedNodePrefix(since: staleVersion, count: 4))
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, b.id, c.id, d.id, e.id, f.id])
        XCTAssertEqual(adapter.nodes.map(\.label), ["First", "Second", "Third", "Fourth", "Fifth", "Sixth"])
        XCTAssertTrue([a, b, c, d, e, f].allSatisfy { registry.galaxyForNode($0.id) === galaxy })
        XCTAssertGreaterThan(adapter.nodePrefixComparisonCount, compared)
    }

    func testStreamingPreviewOverlapAndPrefixEditCannotCertifyOldMetadata() async throws {
        let (lattice, registry, galaxy, generation, adapter) = try await streamingFixture()
        defer { lattice.close() }
        let preview = node(label: "Preview"), next = node(label: "Next"), last = node(label: "Last")
        galaxy.applyLoadChunk(nodes: [(50, preview)], generation: generation)
        adapter.tick(dt: 1 / 60)
        let retained = adapter.nodes
        let appendGeneration = galaxy.renderStore.nodeAppendGeneration
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let changed = NodeData(id: preview.id, project: "Edited project", topic: "Edited topic",
                               label: "Current", content: "Current body", createdAt: created,
                               lastAccessedAt: created.addingTimeInterval(10), importance: 5)
        // The full scan overlaps the preview and edits a prefix member in the
        // same publication interval as certified suffix inserts.
        galaxy.applyLoadChunk(nodes: [(1, next)], generation: generation)
        galaxy.applyLoadChunk(nodes: [(50, changed), (51, last)], generation: generation)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [preview.id, next.id, last.id])
        let current = try XCTUnwrap(adapter.nodes.first)
        XCTAssertEqual(current.project, changed.project)
        XCTAssertEqual(current.topic, changed.topic)
        XCTAssertEqual(current.label, changed.label)
        XCTAssertEqual(current.content, changed.content)
        XCTAssertEqual(current.createdAt, changed.createdAt)
        XCTAssertEqual(current.lastAccessedAt, changed.lastAccessedAt)
        XCTAssertEqual(current.importance, changed.importance)
        XCTAssertEqual(retained.first?.label, "Preview")
        XCTAssertEqual(Set(adapter.nodes.map(\.id)).count, 3)
        XCTAssertTrue([preview, next, last].allSatisfy { registry.galaxyForNode($0.id) === galaxy })
        XCTAssertNotEqual(galaxy.renderStore.nodeAppendGeneration, appendGeneration)
    }

    func testStreamingEdgeAndHubChangesKeepNodeOutputsAndRefreshHubStyle() async throws {
        let (lattice, registry, galaxy, generation, adapter) = try await streamingFixture()
        defer { lattice.close() }
        let a = node(), b = node()
        galaxy.applyLoadChunk(nodes: [(1, a), (2, b)], generation: generation)
        registry.unifiedSimulation.setPosition(a.id, to: SIMD3<Float>(1, 2, 3))
        registry.unifiedSimulation.setPosition(b.id, to: SIMD3<Float>(4, 5, 6))
        adapter.tick(dt: 1 / 60)
        let positions = adapter.positionArray
        let nodesVersion = adapter.nodeVersion
        let hubsVersion = adapter.hubVersion
        let built = adapter.nodeSnapshotBuildCount
        let compared = adapter.nodePrefixComparisonCount
        let routed = registry.routingNodeVisitCount
        let edgeID = UUID()
        let edge = EdgeData(id: edgeID, sourceId: a.id, targetId: b.id, relation: "relates_to")
        galaxy.applyLoadChunk(edges: [(1, edge)], generation: generation)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, b.id])
        XCTAssertEqual(adapter.positionArray, positions)
        XCTAssertEqual(adapter.edges.map(\.id), [edgeID])
        XCTAssertFalse(adapter.nodes.contains { $0.isHub })
        XCTAssertEqual(adapter.nodeVersion, nodesVersion)
        XCTAssertEqual(adapter.hubVersion, hubsVersion)
        XCTAssertEqual(adapter.nodeSnapshotBuildCount, built)
        XCTAssertEqual(adapter.nodePrefixComparisonCount, compared)
        XCTAssertEqual(registry.routingNodeVisitCount, routed)

        let topologyBeforeHiddenEdge = adapter.topologyVersion
        let invisible = EdgeData(id: UUID(), sourceId: a.id, targetId: UUID(), relation: "relates_to")
        galaxy.applyLoadChunk(edges: [(2, invisible)], generation: generation)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.map(\.id), [edgeID])
        XCTAssertEqual(adapter.topologyVersion, topologyBeforeHiddenEdge,
                       "A singleton allEdges-only change must not invalidate unchanged visible output")

        let edgeBuilt = adapter.edgeSnapshotBuildCount
        galaxy.renderStore.colorMap[a.project] = .red
        galaxy.loadStatus = .complete
        galaxy.worldCenter = SIMD3<Float>(12, 34, 56)
        galaxy.renderStore.bumpTopology()
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, b.id])
        XCTAssertEqual(adapter.edges.map(\.id), [edgeID])
        XCTAssertEqual(adapter.positionArray, positions)
        XCTAssertEqual(adapter.galaxySnapshots.first?.worldCenter, SIMD3<Float>(12, 34, 56))
        XCTAssertEqual(adapter.nodeVersion, nodesVersion)
        XCTAssertEqual(adapter.hubVersion, hubsVersion)
        XCTAssertEqual(adapter.nodeSnapshotBuildCount, built)
        XCTAssertEqual(adapter.edgeSnapshotBuildCount, edgeBuilt)
        XCTAssertEqual(registry.routingNodeVisitCount, routed)

        let hubEdge = EdgeData(id: edgeID, sourceId: a.id, targetId: b.id, relation: "part_of")
        galaxy.applyLoadChunk(edges: [(1, hubEdge)], generation: generation)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.first?.relation, "part_of")
        XCTAssertEqual(adapter.hubs, [b.id])
        XCTAssertEqual(adapter.nodes.filter(\.isHub).map(\.id), [b.id])
        XCTAssertEqual(adapter.positionArray, positions)
        XCTAssertEqual(adapter.nodeVersion, nodesVersion)
        XCTAssertNotEqual(adapter.hubVersion, hubsVersion)
        XCTAssertGreaterThan(adapter.nodeSnapshotBuildCount, built)

        galaxy.applyLoadChunk(removedEdges: [1], generation: generation)
        adapter.tick(dt: 1 / 60)
        XCTAssertTrue(adapter.edges.isEmpty)
        XCTAssertTrue(adapter.hubs.isEmpty)
        XCTAssertFalse(adapter.nodes.contains { $0.isHub })
        XCTAssertTrue([a, b].allSatisfy { registry.galaxyForNode($0.id) === galaxy })
    }

    func testStreamingFilterDeletionReorderAndShrinkCannotRetainStalePrefix() async throws {
        let (lattice, registry, galaxy, generation, adapter) = try await streamingFixture()
        defer { lattice.close() }
        let a = node(label: "Deleted"), b = node(label: "Hidden"), c = node(label: "Survivor")
        let d = node(label: "Appended")
        galaxy.applyLoadChunk(nodes: [(1, a), (2, b), (3, c)], generation: generation)
        adapter.tick(dt: 1 / 60)
        let settings = VisualizerConfig()
        settings.hiddenProjects = ["Hidden project"]
        registry.updateDrainConfig(from: settings, timeFilter: nil)
        let hidden = NodeData(id: b.id, project: "Hidden project", topic: b.topic,
                              label: b.label, content: b.content, createdAt: b.createdAt,
                              lastAccessedAt: b.lastAccessedAt, importance: b.importance)
        galaxy.applyLoadChunk(nodes: [(2, hidden), (4, d)], removedNodes: [1], generation: generation)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [c.id, d.id])
        XCTAssertNil(registry.galaxyForNode(a.id))
        XCTAssertNil(registry.galaxyForNode(b.id))
        XCTAssertEqual(Set(registry.nodeToGalaxy.keys), Set([c.id, d.id]))

        // The store revision alone invalidates an earlier append proof,
        // even when an ordinary mutation does not manually bump topology.
        galaxy.renderStore.nodes.reverse()
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [d.id, c.id])
        galaxy.applyLoadChunk(removedNodes: [3], generation: generation)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [d.id])
        XCTAssertEqual(adapter.positionArray.count, 1)
        XCTAssertEqual(Set(registry.nodeToGalaxy.keys), [d.id])
        XCTAssertNil(registry.unifiedSimulation.index(for: c.id))
    }

    func testStreamingHigherPriorityAppendAndSameIDReplacementChangeWinner() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        defer { lattice.close() }
        let registry = GalaxyRegistry()
        registry.unifiedSimulation.isActive = false
        let synced = Galaxy(id: "synced", displayName: "Synced", lattice: lattice.sendableReference)
        let groupID = "group:team"
        let group = Galaxy(id: groupID, displayName: "Team", lattice: lattice.sendableReference)
        let shared = node(label: "Synced copy"), team = node(label: "Team only"), tail = node(label: "Tail")
        registry.register(synced)
        registry.register(group)
        let syncedChanges = await synced.loadChanges
        let groupChanges = await group.loadChanges
        let syncedGeneration = syncedChanges.withLock { $0.begin() }
        let groupGeneration = groupChanges.withLock { $0.begin() }
        synced.loadStatus = .loading
        group.loadStatus = .loading
        synced.applyLoadChunk(nodes: [(1, shared)], generation: syncedGeneration)
        group.applyLoadChunk(nodes: [(1, team)], generation: groupGeneration)
        let adapter = GalaxyRegistryAdapter(registry: registry)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [team.id, shared.id])

        let winner = node(id: shared.id, label: "Team wins", topic: "Team topic")
        group.applyLoadChunk(nodes: [(2, winner)], generation: groupGeneration)
        synced.applyLoadChunk(nodes: [(2, tail)], generation: syncedGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [team.id, shared.id, tail.id])
        XCTAssertEqual(adapter.nodes[1].label, "Team wins")
        XCTAssertEqual(adapter.nodes[1].topic, "Team topic")
        XCTAssertEqual(registry.mergedNodeById[shared.id]?.label, "Team wins")
        XCTAssertTrue(registry.galaxyForNode(shared.id) === group)
        XCTAssertEqual(Set(adapter.nodes.map(\.id)).count, 3)
        let publishedNodesVersion = adapter.nodeVersion

        // Match counts and the sequence of mutations in the original instance.
        let replacement = Galaxy(id: groupID, displayName: "Replacement", lattice: lattice.sendableReference)
        registry.register(replacement)
        let replacementChanges = await replacement.loadChanges
        let replacementGeneration = replacementChanges.withLock { $0.begin() }
        replacement.loadStatus = .loading
        replacement.applyLoadChunk(nodes: [(1, team)], generation: replacementGeneration)
        replacement.applyLoadChunk(nodes: [(2, node(id: shared.id, label: "Replacement wins"))],
                                   generation: replacementGeneration)
        XCTAssertEqual(replacement.renderStore.topologyVersion, group.renderStore.topologyVersion)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [team.id, shared.id, tail.id])
        XCTAssertEqual(adapter.nodes[1].label, "Replacement wins")
        XCTAssertEqual(registry.mergedNodeById[shared.id]?.label, "Replacement wins")
        XCTAssertTrue(registry.galaxyForNode(shared.id) === replacement)
        XCTAssertNotEqual(adapter.nodeVersion, publishedNodesVersion)

        registry.remove(groupID)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [shared.id, tail.id])
        XCTAssertEqual(adapter.nodes.first?.label, "Synced copy")
        XCTAssertEqual(registry.mergedNodeById[shared.id]?.label, "Synced copy")
        XCTAssertTrue(registry.galaxyForNode(shared.id) === synced)
    }

    func testCurrentNodeLookupPreservesPrecedenceAndIndependentSnapshots() throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        defer { lattice.close() }
        let registry = GalaxyRegistry()
        let synced = Galaxy(id: "synced", displayName: "Synced", lattice: lattice.sendableReference)
        let groupID = "group:team"
        let group = Galaxy(id: groupID, displayName: "Team", lattice: lattice.sendableReference)
        registry.register(synced)
        registry.register(group)
        let lower = node(label: "Synced copy")
        let winner = node(id: lower.id, label: "Team wins")
        let lookupOnly = node(label: "Lookup-only row")
        synced.renderStore.nodeById[lower.id] = lower
        group.renderStore.nodeById[winner.id] = winner
        group.renderStore.nodeById[lookupOnly.id] = lookupOnly
        registry.mergeRenderData()
        let topology = registry.mergedTopologyVersion
        let snapshot = registry.mergedNodeById
        XCTAssertTrue(registry.mergedNodes.isEmpty)
        XCTAssertEqual(registry.node(for: winner.id)?.label, "Team wins")
        XCTAssertEqual(registry.node(for: lookupOnly.id)?.label, "Lookup-only row")
        XCTAssertNil(registry.node(for: UUID()))

        let accessed = winner.lastAccessedAt.addingTimeInterval(60)
        group.renderStore.nodeById[winner.id]?.lastAccessedAt = accessed
        // Metadata lookup is current even before the next render callback.
        XCTAssertEqual(registry.node(for: winner.id)?.lastAccessedAt, accessed)
        registry.mergeRenderData()
        XCTAssertEqual(registry.mergedTopologyVersion, topology)
        XCTAssertEqual(snapshot[winner.id]?.lastAccessedAt, winner.lastAccessedAt)
        XCTAssertEqual(registry.mergedNodeById[winner.id]?.lastAccessedAt, accessed)

        // Removing a winning lookup reveals the lower-priority copy without
        // needing a visible-node owner or a whole-graph lookup publication.
        group.renderStore.nodeById.removeValue(forKey: winner.id)
        XCTAssertEqual(registry.node(for: winner.id)?.label, "Synced copy")
        XCTAssertEqual(snapshot[winner.id]?.label, "Team wins")
        let replacement = Galaxy(id: groupID, displayName: "Replacement", lattice: lattice.sendableReference)
        replacement.renderStore.nodeById[winner.id] = node(id: winner.id, label: "Replacement wins")
        registry.register(replacement)
        XCTAssertEqual(registry.node(for: winner.id)?.label, "Replacement wins")
        XCTAssertNil(registry.node(for: lookupOnly.id))
        registry.remove(groupID)
        XCTAssertEqual(registry.node(for: winner.id)?.label, "Synced copy")
        XCTAssertEqual(registry.mergedNodeById[winner.id]?.label, "Synced copy")
    }

    func testStreamingCrossGalaxyEdgesAndLookupRespectIndependentRevisions() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        defer { lattice.close() }
        let registry = GalaxyRegistry()
        registry.unifiedSimulation.isActive = false
        let synced = Galaxy(id: "synced", displayName: "Synced", lattice: lattice.sendableReference)
        let group = Galaxy(id: "group:team", displayName: "Team", lattice: lattice.sendableReference)
        registry.register(synced)
        registry.register(group)
        let syncedChanges = await synced.loadChanges
        let groupChanges = await group.loadChanges
        let syncedGeneration = syncedChanges.withLock { $0.begin() }
        let groupGeneration = groupChanges.withLock { $0.begin() }
        let a = node(label: "Group node"), b = node(label: "Synced node")
        group.applyLoadChunk(nodes: [(1, a)], generation: groupGeneration)
        synced.applyLoadChunk(nodes: [(1, b)], generation: syncedGeneration)
        let adapter = GalaxyRegistryAdapter(registry: registry)
        adapter.tick(dt: 1 / 60)
        let nodeVersion = adapter.nodeVersion
        let built = adapter.nodeSnapshotBuildCount
        let routed = registry.routingNodeVisitCount
        let edge = EdgeData(id: UUID(), sourceId: a.id, targetId: b.id, relation: "relates_to")
        // Neither store contains both endpoints: only the allEdges domain
        // changes, but the merged scene must still publish this connection.
        group.applyLoadChunk(edges: [(1, edge)], generation: groupGeneration)
        XCTAssertTrue(group.renderStore.edges.isEmpty)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.map(\.id), [edge.id])
        XCTAssertEqual(adapter.edges.first?.sourceId, a.id)
        XCTAssertEqual(adapter.edges.first?.targetId, b.id)
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, b.id])
        XCTAssertEqual(adapter.nodeVersion, nodeVersion)
        XCTAssertEqual(adapter.nodeSnapshotBuildCount, built)
        XCTAssertEqual(registry.routingNodeVisitCount, routed)

        registry.hiddenRelations = ["relates_to"]
        adapter.tick(dt: 1 / 60)
        XCTAssertTrue(adapter.edges.isEmpty)
        registry.hiddenRelations = []
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.map(\.id), [edge.id])

        let topologyBeforeLookup = adapter.topologyVersion
        let accessed = a.lastAccessedAt.addingTimeInterval(60)
        let activityOnly = NodeData(id: a.id, project: a.project, topic: a.topic,
                                    label: a.label, content: a.content, createdAt: a.createdAt,
                                    lastAccessedAt: accessed, importance: a.importance)
        group.applyLoadChunk(nodes: [(1, activityOnly)], generation: groupGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(registry.mergedNodeById[a.id]?.lastAccessedAt, accessed)
        XCTAssertEqual(adapter.topologyVersion, topologyBeforeLookup,
                       "Activity metadata must not trigger a full render/centroid publication")
        XCTAssertEqual(adapter.nodeVersion, nodeVersion)
        XCTAssertEqual(adapter.nodeSnapshotBuildCount, built)
        XCTAssertEqual(registry.routingNodeVisitCount, routed)
        XCTAssertTrue(registry.galaxyForNode(a.id) === group)
        XCTAssertTrue(registry.galaxyForNode(b.id) === synced)

        synced.applyLoadChunk(removedNodes: [1], generation: syncedGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id])
        XCTAssertTrue(adapter.edges.isEmpty, "An absent endpoint must remove its cross-galaxy edge")
        XCTAssertNil(registry.galaxyForNode(b.id))
    }

    func testCertifiedCrossGalaxyNodeAppendsReuseUnchangedEdges() async throws {
        let (lattice, registry, group, groupGeneration, personal, personalGeneration, adapter) =
            try await crossGalaxyStreamingFixture()
        defer { lattice.close() }
        let a = node(label: "Group"), b = node(label: "Personal"), c = node(label: "New group")
        let d = node(label: "New personal"), e = node(label: "Later personal")
        group.applyLoadChunk(nodes: [(1, a)], generation: groupGeneration)
        personal.applyLoadChunk(nodes: [(1, b)], generation: personalGeneration)
        let first = EdgeData(id: UUID(), sourceId: a.id, targetId: b.id, relation: "relates_to")
        let second = EdgeData(id: UUID(), sourceId: b.id, targetId: a.id, relation: "supports")
        group.applyLoadChunk(edges: [(1, first)], generation: groupGeneration)
        personal.applyLoadChunk(edges: [(1, second)], generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        let edgeVersion = adapter.edgeVersion, nodeVersion = adapter.nodeVersion
        let compared = adapter.edgePrefixComparisonCount, built = adapter.edgeSnapshotBuildCount
        let groupAppend = group.renderStore.nodeAppendGeneration
        let personalAppend = personal.renderStore.nodeAppendGeneration

        // Several chunks may arrive before a frame, including a higher-priority
        // copy of an already visible UUID. Its owner changes, not its visibility.
        group.applyLoadChunk(nodes: [(2, c)], generation: groupGeneration)
        let winner = node(id: b.id, label: "Group copy", topic: "New owner")
        group.applyLoadChunk(nodes: [(3, winner)], generation: groupGeneration)
        personal.applyLoadChunk(nodes: [(2, d)], generation: personalGeneration)
        for (index, value) in [a, c, winner, d].enumerated() {
            registry.unifiedSimulation.setPosition(value.id, to: SIMD3<Float>(Float(index + 1), 0, 0))
        }
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, c.id, b.id, d.id])
        XCTAssertEqual(adapter.nodes.map(\.label), [a.label, c.label, winner.label, d.label])
        XCTAssertEqual(adapter.nodes[2].topic, winner.topic)
        XCTAssertTrue(registry.galaxyForNode(b.id) === group)
        XCTAssertEqual(adapter.positionArray, [1, 2, 3, 4].map { SIMD3<Float>(Float($0), 0, 0) })
        XCTAssertNotEqual(adapter.nodeVersion, nodeVersion)
        XCTAssertEqual(group.renderStore.nodeAppendGeneration, groupAppend)
        XCTAssertEqual(personal.renderStore.nodeAppendGeneration, personalAppend)
        XCTAssertEqual(adapter.edges.map(\.id), [first.id, second.id])
        XCTAssertEqual(adapter.edges.map(\.sourceId), [a.id, b.id])
        XCTAssertEqual(adapter.edges.map(\.targetId), [b.id, a.id])
        XCTAssertEqual(adapter.edges.map(\.relation), [first.relation, second.relation])
        XCTAssertEqual(adapter.edgeVersion, edgeVersion)
        XCTAssertEqual(adapter.edgePrefixComparisonCount, compared)
        XCTAssertEqual(adapter.edgeSnapshotBuildCount, built)

        personal.applyLoadChunk(nodes: [(3, e)], generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, c.id, b.id, d.id, e.id])
        XCTAssertEqual(adapter.edges.map(\.id), [first.id, second.id])
        XCTAssertEqual(adapter.edgeVersion, edgeVersion)
        XCTAssertEqual(adapter.edgePrefixComparisonCount, compared)
        XCTAssertEqual(adapter.edgeSnapshotBuildCount, built)
    }

    func testCrossGalaxyMissingEndpointsArriveSeparatelyWithoutReorderingEdges() async throws {
        let (lattice, registry, group, groupGeneration, personal, personalGeneration, adapter) =
            try await crossGalaxyStreamingFixture()
        defer { lattice.close() }
        let synced = Galaxy(id: "synced", displayName: "Synced", lattice: lattice.sendableReference)
        registry.register(synced)
        let changes = await synced.loadChanges
        let generation = changes.withLock { $0.begin() }
        synced.loadStatus = .loading
        let a = node(), b = node(), c = node(), d = node(), unrelated = node()
        group.applyLoadChunk(nodes: [(1, a)], generation: groupGeneration)
        personal.applyLoadChunk(nodes: [(1, b)], generation: personalGeneration)
        let before = EdgeData(id: UUID(), sourceId: a.id, targetId: b.id, relation: "before")
        let missing = EdgeData(id: UUID(), sourceId: c.id, targetId: d.id, relation: "bridge")
        let after = EdgeData(id: UUID(), sourceId: b.id, targetId: a.id, relation: "after")
        // One edge per precedence tier makes the exact full-merge order explicit.
        group.applyLoadChunk(edges: [(1, before)], generation: groupGeneration)
        synced.applyLoadChunk(edges: [(1, missing)], generation: generation)
        personal.applyLoadChunk(edges: [(1, after)], generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.map(\.id), [before.id, after.id])
        let initialVersion = adapter.edgeVersion, compared = adapter.edgePrefixComparisonCount
        group.applyLoadChunk(nodes: [(2, unrelated)], generation: groupGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edgeVersion, initialVersion)
        XCTAssertEqual(adapter.edgePrefixComparisonCount, compared)
        XCTAssertEqual(adapter.edges.map(\.id), [before.id, after.id])

        group.applyLoadChunk(nodes: [(3, c)], generation: groupGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.map(\.id), [before.id, after.id])
        XCTAssertNotEqual(adapter.edgeVersion, initialVersion)
        let firstEndpointVersion = adapter.edgeVersion
        personal.applyLoadChunk(nodes: [(2, d)], generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertNotEqual(adapter.edgeVersion, firstEndpointVersion)
        XCTAssertEqual(adapter.edges.map(\.id), [before.id, missing.id, after.id])
        XCTAssertEqual(adapter.edges.map(\.sourceId), [a.id, c.id, b.id])
        XCTAssertEqual(adapter.edges.map(\.targetId), [b.id, d.id, a.id])
        XCTAssertEqual(adapter.edges.map(\.relation), ["before", "bridge", "after"])
        XCTAssertTrue(synced.renderStore.edges.isEmpty,
                      "Both bridge endpoints remain outside the edge's source galaxy")
    }

    func testCrossGalaxyHiddenAndDanglingWinnersSuppressVisibleDuplicates() async throws {
        let (lattice, registry, group, groupGeneration, personal, personalGeneration, adapter) =
            try await crossGalaxyStreamingFixture()
        defer { lattice.close() }
        let a = node(), b = node(), missing = node(), unrelated = node()
        group.applyLoadChunk(nodes: [(1, a)], generation: groupGeneration)
        personal.applyLoadChunk(nodes: [(1, a), (2, b)], generation: personalGeneration)
        let high = EdgeData(id: UUID(), sourceId: a.id, targetId: missing.id, relation: "hidden")
        let low = EdgeData(id: high.id, sourceId: a.id, targetId: b.id, relation: "visible")
        group.applyLoadChunk(edges: [(1, high)], generation: groupGeneration)
        personal.applyLoadChunk(edges: [(1, low)], generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertTrue(adapter.edges.isEmpty, "The dangling winner still claims its edge ID")
        let danglingVersion = adapter.edgeVersion
        personal.applyLoadChunk(nodes: [(3, unrelated)], generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertTrue(adapter.edges.isEmpty)
        XCTAssertEqual(adapter.edgeVersion, danglingVersion)

        registry.hiddenRelations = ["hidden"]
        adapter.tick(dt: 1 / 60)
        let hiddenVersion = adapter.edgeVersion
        personal.applyLoadChunk(nodes: [(4, missing)], generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertTrue(adapter.edges.isEmpty, "A hidden winner also suppresses the visible lower copy")
        XCTAssertEqual(adapter.edgeVersion, hiddenVersion,
                       "An endpoint of a hidden edge cannot change rendered edges")
        registry.hiddenRelations = []
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.map(\.id), [high.id])
        XCTAssertEqual(adapter.edges.first?.targetId, missing.id)
        XCTAssertEqual(adapter.edges.first?.relation, high.relation)

        registry.hiddenRelations = ["hidden"]
        group.applyLoadChunk(removedEdges: [1], generation: groupGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.map(\.id), [low.id])
        XCTAssertEqual(adapter.edges.first?.sourceId, a.id)
        XCTAssertEqual(adapter.edges.first?.targetId, b.id)
        XCTAssertEqual(adapter.edges.first?.relation, low.relation)
    }

    func testCrossGalaxyAppendsWithEdgeEditsDeletesAndFiltersUseFullMerge() async throws {
        let (lattice, registry, group, groupGeneration, personal, personalGeneration, adapter) =
            try await crossGalaxyStreamingFixture()
        defer { lattice.close() }
        let a = node(), b = node(), c = node(), d = node(), e = node()
        group.applyLoadChunk(nodes: [(1, a)], generation: groupGeneration)
        personal.applyLoadChunk(nodes: [(1, b)], generation: personalGeneration)
        let original = EdgeData(id: UUID(), sourceId: a.id, targetId: b.id, relation: "relates_to")
        group.applyLoadChunk(edges: [(1, original)], generation: groupGeneration)
        adapter.tick(dt: 1 / 60)
        let initialVersion = adapter.edgeVersion
        let edited = EdgeData(id: original.id, sourceId: a.id, targetId: c.id, relation: "part_of")
        group.applyLoadChunk(nodes: [(2, c)], edges: [(1, edited)], generation: groupGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertNotEqual(adapter.edgeVersion, initialVersion)
        XCTAssertEqual(adapter.edges.map(\.id), [edited.id])
        XCTAssertEqual(adapter.edges.first?.sourceId, a.id)
        XCTAssertEqual(adapter.edges.first?.targetId, c.id)
        XCTAssertEqual(adapter.edges.first?.relation, edited.relation)
        XCTAssertTrue(try XCTUnwrap(adapter.nodes.first { $0.id == c.id }).isHub)

        personal.applyLoadChunk(nodes: [(2, d)], generation: personalGeneration)
        group.applyLoadChunk(removedEdges: [1], generation: groupGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertTrue(adapter.edges.isEmpty)
        XCTAssertFalse(try XCTUnwrap(adapter.nodes.first { $0.id == c.id }).isHub)
        group.applyLoadChunk(edges: [(2, original)], generation: groupGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.map(\.id), [original.id])
        registry.hiddenRelations = [original.relation]
        group.applyLoadChunk(nodes: [(3, e)], generation: groupGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertTrue(adapter.edges.isEmpty)
        registry.hiddenRelations = []
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.map(\.id), [original.id])
        XCTAssertEqual(adapter.edges.first?.targetId, b.id)

        personal.applyLoadChunk(nodes: [(3, node())], removedNodes: [1], generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertTrue(adapter.edges.isEmpty)
        XCTAssertNotNil(group.renderStore.allEdges[original.id],
                        "The source edge survives deletion of its endpoint in another galaxy")
    }

    func testCrossGalaxyPrefixEditsReorderFilteringAndShrinkInvalidateReuse() async throws {
        let (lattice, registry, group, groupGeneration, personal, personalGeneration, adapter) =
            try await crossGalaxyStreamingFixture()
        defer { lattice.close() }
        let a = node(label: "Preview"), b = node(), c = node(label: "New")
        group.applyLoadChunk(nodes: [(1, a)], generation: groupGeneration)
        personal.applyLoadChunk(nodes: [(1, b)], generation: personalGeneration)
        let edge = EdgeData(id: UUID(), sourceId: a.id, targetId: b.id, relation: "relates_to")
        group.applyLoadChunk(edges: [(1, edge)], generation: groupGeneration)
        adapter.tick(dt: 1 / 60)
        let initialVersion = adapter.edgeVersion
        let edited = node(id: a.id, label: "Reconciled", topic: "Changed")
        group.applyLoadChunk(nodes: [(1, edited), (2, c)], generation: groupGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertNotEqual(adapter.edgeVersion, initialVersion)
        XCTAssertEqual(adapter.nodes.map(\.label), [edited.label, c.label, b.label])
        XCTAssertEqual(adapter.nodes.first?.topic, edited.topic)
        XCTAssertEqual(adapter.edges.map(\.id), [edge.id])
        let editedVersion = adapter.edgeVersion
        group.renderStore.nodes.reverse()
        adapter.tick(dt: 1 / 60)
        XCTAssertNotEqual(adapter.edgeVersion, editedVersion)
        XCTAssertEqual(adapter.nodes.map(\.id), [c.id, a.id, b.id])
        XCTAssertEqual(adapter.edges.map(\.id), [edge.id])

        let settings = VisualizerConfig()
        settings.hiddenProjects = ["Blocked"]
        registry.updateDrainConfig(from: settings, timeFilter: nil)
        personal.applyLoadChunk(nodes: [(1, node(id: b.id, project: "Blocked")), (2, node())],
                                generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertNil(registry.galaxyForNode(b.id))
        XCTAssertTrue(adapter.edges.isEmpty)
        settings.hiddenProjects = []
        registry.updateDrainConfig(from: settings, timeFilter: nil)
        personal.applyLoadChunk(nodes: [(1, b)], generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.map(\.id), [edge.id])

        // An arbitrary array mutation invalidates continuity even without an
        // edge revision or a manually published topology revision.
        let sourceVersion = group.renderStore.allEdgesVersion
        group.renderStore.nodes.removeAll { $0.id == a.id }
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(group.renderStore.allEdgesVersion, sourceVersion)
        XCTAssertNil(registry.galaxyForNode(a.id))
        XCTAssertTrue(adapter.edges.isEmpty)
    }

    func testCrossGalaxyReplacementPrecedenceAndSingleGalaxyTransitionsResetReuse() async throws {
        let (lattice, registry, group, groupGeneration, personal, personalGeneration, adapter) =
            try await crossGalaxyStreamingFixture()
        defer { lattice.close() }
        let a = node(), b = node(), missing = node()
        group.applyLoadChunk(nodes: [(1, a)], generation: groupGeneration)
        personal.applyLoadChunk(nodes: [(1, a), (2, b)], generation: personalGeneration)
        let high = EdgeData(id: UUID(), sourceId: a.id, targetId: b.id, relation: "group")
        let low = EdgeData(id: high.id, sourceId: b.id, targetId: a.id, relation: "personal")
        group.applyLoadChunk(edges: [(1, high)], generation: groupGeneration)
        personal.applyLoadChunk(edges: [(1, low)], generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.map(\.id), [high.id])
        XCTAssertEqual(adapter.edges.first?.relation, high.relation)

        let replacement = Galaxy(id: "group:team", displayName: "Replacement", lattice: lattice.sendableReference)
        registry.register(replacement)
        let changes = await replacement.loadChanges
        let generation = changes.withLock { $0.begin() }
        replacement.loadStatus = .loading
        let replaced = EdgeData(id: high.id, sourceId: a.id, targetId: missing.id, relation: "replacement")
        replacement.applyLoadChunk(nodes: [(1, a)], edges: [(1, replaced)], generation: generation)
        XCTAssertEqual(replacement.renderStore.nodesVersion, group.renderStore.nodesVersion)
        XCTAssertEqual(replacement.renderStore.allEdgesVersion, group.renderStore.allEdgesVersion)
        adapter.tick(dt: 1 / 60)
        XCTAssertTrue(adapter.edges.isEmpty, "Equal counters cannot certify a replacement instance")
        personal.applyLoadChunk(nodes: [(3, missing)], generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.map(\.id), [replaced.id])
        XCTAssertEqual(adapter.edges.first?.targetId, missing.id)
        XCTAssertEqual(adapter.edges.first?.relation, replaced.relation)

        let earlier = Galaxy(id: "group:aaa", displayName: "Earlier", lattice: lattice.sendableReference)
        registry.register(earlier)
        let earlierChanges = await earlier.loadChanges
        let earlierGeneration = earlierChanges.withLock { $0.begin() }
        earlier.loadStatus = .loading
        let winner = EdgeData(id: high.id, sourceId: b.id, targetId: a.id, relation: "earlier")
        earlier.applyLoadChunk(edges: [(1, winner)], generation: earlierGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.map(\.id), [winner.id])
        XCTAssertEqual(adapter.edges.first?.relation, winner.relation)
        XCTAssertEqual(adapter.edges.first?.targetId, a.id)
        registry.remove("group:aaa")
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.map(\.id), [replaced.id])
        XCTAssertEqual(adapter.edges.first?.relation, replaced.relation)
        registry.remove("group:team")
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.map(\.id), [low.id])
        XCTAssertEqual(adapter.edges.first?.relation, low.relation)
        XCTAssertEqual(adapter.edges.first?.targetId, a.id)
        registry.remove("personal")
        adapter.tick(dt: 1 / 60)
        XCTAssertTrue(adapter.nodes.isEmpty)
        XCTAssertTrue(adapter.edges.isEmpty)
    }

    func testStreamingCompletedScanReconcilesPreviewMetadataAndAbsentRows() async throws {
        let lattice = try Lattice(Memory.self, MemoryEdge.self, configuration: .init(storage: .memory()))
        defer { lattice.close() }
        var rows: [Memory] = []
        for index in 0..<61 {
            let row = Memory(content: "Current row \(index)", topic: "Current topic", project: "Current project",
                             importance: 2)
            try lattice.add(row)
            rows.append(row)
        }
        let ids = try rows.map { try XCTUnwrap($0.globalId) }
        let previewPrimaryKey = try XCTUnwrap(rows[0].primaryKey)
        let edge = MemoryEdge(sourceGlobalId: ids[0], targetGlobalId: ids[60], relation: .partOf)
        try lattice.add(edge)
        let edgeID = try XCTUnwrap(edge.globalId)
        let registry = GalaxyRegistry()
        registry.unifiedSimulation.isActive = false
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let stale = node(id: ids[0], label: "Stale preview"), absent = node(label: "Absent from database")
        galaxy.insertNodeBatch([stale, absent], config: config)
        galaxy.renderStore.pkToGlobalId[previewPrimaryKey] = stale.id
        galaxy.renderStore.pkToGlobalId[Int64.max] = absent.id
        galaxy.renderStore.bumpTopology()
        let adapter = GalaxyRegistryAdapter(registry: registry)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [stale.id, absent.id])

        await galaxy.loadData()
        await galaxy.stopObservers()
        adapter.tick(dt: 1 / 60)
        XCTAssertTrue(galaxy.isLoaded)
        XCTAssertEqual(galaxy.loadStatus, .complete)
        XCTAssertEqual(Set(adapter.nodes.map(\.id)), Set(ids))
        XCTAssertEqual(adapter.nodes.count, ids.count)
        let refreshed = try XCTUnwrap(adapter.nodes.first { $0.id == stale.id })
        XCTAssertEqual(refreshed.content, rows[0].content)
        XCTAssertEqual(refreshed.project, rows[0].project)
        XCTAssertEqual(refreshed.topic, rows[0].topic)
        XCTAssertNil(registry.galaxyForNode(absent.id))
        XCTAssertNil(galaxy.renderStore.pkToGlobalId[Int64.max])
        XCTAssertEqual(adapter.edges.map(\.id), [edgeID])
        XCTAssertEqual(adapter.nodes.filter(\.isHub).map(\.id), [ids[60]])
        XCTAssertTrue(ids.allSatisfy { registry.galaxyForNode($0) === galaxy })
    }

    func testCentroidSlotsPreserveGroupingMissingPositionsAndDownwardExtents() throws {
        let provider = GalaxyRegistry()
        var cache = CentroidMembershipCache()
        let groups = [(project: "x|y", galaxy: "g"), (project: "y", galaxy: "g|x"),
                      (project: "x|y", galaxy: "g"), (project: "Solo", galaxy: "personal"),
                      (project: "Missing", galaxy: "empty")]
        cache.refresh(nodeCount: groups.count, nodeVersion: 1, appendGeneration: 1,
                      provider: provider) { groups[$0] }
        let positions = [SIMD3<Float>.zero, SIMD3<Float>(10, 0, 0), SIMD3<Float>(20, 0, 0),
                         .zero, SIMD3<Float>(999, 0, 0)]
        let centers = ["g": SIMD3<Float>.zero, "g|x": SIMD3<Float>(10, 0, 0),
                       "personal": .zero, "empty": .zero]
        // A mapped but unreadable simulation position is already gathered as
        // zero by the adapter; only a negative index is excluded from reduction.
        cache.reduce(positions: positions, simulationIndices: [0, 1, 2, 100, -1], galaxyCenters: centers)
        XCTAssertEqual(cache.projectCentroids, ["x|y": SIMD3<Float>(10, 0, 0),
                                               "y": SIMD3<Float>(10, 0, 0), "Solo": .zero])
        XCTAssertEqual(cache.nebulaClusters.count, 2)
        let collision = try XCTUnwrap(cache.nebulaClusters.first { $0.count == 3 })
        XCTAssertEqual(collision.galaxyId, "g")
        XCTAssertEqual(collision.project, "x|y")
        XCTAssertEqual(collision.centroid, SIMD3<Float>(10, 0, 0))
        XCTAssertEqual(collision.radius, 50)
        XCTAssertEqual(cache.galaxyAggregate(for: "g").count, 2)
        XCTAssertEqual(cache.galaxyAggregate(for: "g").radius, 20)
        XCTAssertEqual(cache.galaxyAggregate(for: "g").dominantProject, "x|y")
        XCTAssertEqual(cache.galaxyAggregate(for: "g|x").dominantProject, "y")
        XCTAssertEqual(cache.galaxyAggregate(for: "g|x").radius, 0)
        XCTAssertEqual(cache.galaxyAggregate(for: "personal").radius, 0)
        XCTAssertNil(cache.galaxyAggregate(for: "empty").radius)
        XCTAssertEqual(cache.galaxyAggregate(for: "unknown").count, 0)

        // The last usable member supplies collision labels; an unresolved tail
        // cannot override them. No membership rebuild is needed as slots resolve.
        cache.reduce(positions: positions, simulationIndices: [0, 1, -1, 100, -1], galaxyCenters: centers)
        let partial = try XCTUnwrap(cache.nebulaClusters.first { $0.count == 2 })
        XCTAssertEqual(partial.galaxyId, "g|x")
        XCTAssertEqual(partial.project, "y")
        XCTAssertEqual(partial.centroid, SIMD3<Float>(5, 0, 0))
        XCTAssertEqual(partial.radius, 45)
        cache.reduce(positions: Array(repeating: .zero, count: groups.count),
                     simulationIndices: [0, 1, 2, 100, -1],
                     galaxyCenters: ["g": SIMD3<Float>(3, 0, 0), "personal": .zero])
        XCTAssertTrue(cache.nebulaClusters.allSatisfy { $0.centroid == .zero && $0.radius == 40 })
        XCTAssertEqual(cache.galaxyAggregate(for: "g").radius, 3)
        XCTAssertNil(cache.galaxyAggregate(for: "g|x").radius, "Unknown galaxy centers have no extent")
        XCTAssertEqual(cache.galaxyAggregate(for: "g|x").count, 1)
        cache.reduce(positions: positions, simulationIndices: Array(repeating: -1, count: groups.count),
                     galaxyCenters: centers)
        XCTAssertTrue(cache.projectCentroids.isEmpty)
        XCTAssertTrue(cache.nebulaClusters.isEmpty)
        XCTAssertEqual(cache.galaxyAggregate(for: "g").count, 0)
        XCTAssertNil(cache.galaxyAggregate(for: "g").radius)
        XCTAssertNil(cache.galaxyAggregate(for: "g").dominantProject)
    }

    func testCentroidSlotsReuseCertifiedAppendAndInvalidateMembershipChanges() {
        let provider = GalaxyRegistry(), replacement = GalaxyRegistry()
        var cache = CentroidMembershipCache()
        var groups = [(project: "P", galaxy: "g"), (project: "Q", galaxy: "h")]
        var visits: [Int] = []
        cache.refresh(nodeCount: 2, nodeVersion: 1, appendGeneration: 7, provider: provider) {
            visits.append($0); return groups[$0]
        }
        XCTAssertEqual(visits, [0, 1])
        visits.removeAll()
        cache.refresh(nodeCount: 2, nodeVersion: 1, appendGeneration: 7, provider: provider) {
            visits.append($0); return groups[$0]
        }
        XCTAssertTrue(visits.isEmpty)
        groups.append(("P", "g"))
        // Several skipped append publications share the same continuity domain.
        cache.refresh(nodeCount: 3, nodeVersion: 4, appendGeneration: 7, provider: provider) {
            visits.append($0); return groups[$0]
        }
        XCTAssertEqual(visits, [2])
        let positions = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(2, 0, 0), SIMD3<Float>(3, 0, 0)]
        cache.reduce(positions: positions, simulationIndices: [0, 1, 2], galaxyCenters: [:])
        XCTAssertEqual(cache.projectCentroids, ["P": SIMD3<Float>(2, 0, 0), "Q": SIMD3<Float>(2, 0, 0)])

        groups[0] = ("Edited", "h") // Same count, changed project AND owner.
        visits.removeAll()
        cache.refresh(nodeCount: 3, nodeVersion: 5, appendGeneration: 8, provider: provider) {
            visits.append($0); return groups[$0]
        }
        XCTAssertEqual(visits, [0, 1, 2])
        cache.reduce(positions: positions, simulationIndices: [0, 1, 2], galaxyCenters: [:])
        XCTAssertEqual(cache.projectCentroids["Edited"], positions[0])
        XCTAssertEqual(cache.projectCentroids["P"], positions[2])
        XCTAssertEqual(cache.galaxyAggregate(for: "g").count, 1)
        XCTAssertEqual(cache.galaxyAggregate(for: "h").count, 2)

        groups.reverse()
        cache.refresh(nodeCount: 3, nodeVersion: 6, appendGeneration: 9, provider: provider) { groups[$0] }
        cache.reduce(positions: positions, simulationIndices: [0, 1, 2], galaxyCenters: [:])
        XCTAssertEqual(cache.projectCentroids["P"], positions[0])
        XCTAssertEqual(cache.projectCentroids["Edited"], positions[2])
        groups.removeLast()
        cache.refresh(nodeCount: 2, nodeVersion: 7, appendGeneration: 10, provider: provider) { groups[$0] }
        cache.reduce(positions: Array(positions.prefix(2)), simulationIndices: [0, 1], galaxyCenters: [:])
        XCTAssertNil(cache.projectCentroids["Edited"])
        XCTAssertEqual(cache.galaxyAggregate(for: "h").count, 1)

        groups[0] = ("Replacement", "new")
        visits.removeAll()
        cache.refresh(nodeCount: 2, nodeVersion: 7, appendGeneration: 10, provider: replacement) {
            visits.append($0); return groups[$0]
        }
        XCTAssertEqual(visits, [0, 1], "Equal counters from another provider cannot certify membership")
        cache.reduce(positions: Array(positions.prefix(2)), simulationIndices: [0, 1], galaxyCenters: [:])
        XCTAssertNil(cache.projectCentroids["P"])
        XCTAssertEqual(cache.projectCentroids["Replacement"], positions[0])
        XCTAssertEqual(cache.galaxyAggregate(for: "g").count, 0)
        cache.refresh(nodeCount: 0, nodeVersion: 8, appendGeneration: 11, provider: replacement) { groups[$0] }
        cache.reduce(positions: [], simulationIndices: [], galaxyCenters: [:])
        XCTAssertTrue(cache.projectCentroids.isEmpty)
        XCTAssertTrue(cache.nebulaClusters.isEmpty)
    }

    func testAdapterCentroidGroupsTrackSameSizeProjectAndOwnershipChanges() throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        defer { lattice.close() }
        let registry = GalaxyRegistry()
        registry.unifiedSimulation.isActive = false
        let personal = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        let team = Galaxy(id: "group:team", displayName: "Team", lattice: lattice.sendableReference)
        let empty = Galaxy(id: "empty", displayName: "Empty", lattice: lattice.sendableReference)
        for galaxy in [personal, team, empty] { registry.register(galaxy) }
        personal.worldCenter = .zero
        team.worldCenter = SIMD3<Float>(10, 0, 0)
        let a = node(project: "A"), b = node(project: "A"), c = node(project: "B"), d = node(project: "B")
        personal.insertNodeBatch([a, b, c], config: config)
        team.insertNodeBatch([d], config: config)
        personal.renderStore.colorMap["A"] = .red
        personal.renderStore.colorMap["B"] = .blue
        team.renderStore.colorMap["B"] = .blue
        for (n, x) in [(a, Float(0)), (b, 4), (c, 2), (d, 10)] {
            registry.unifiedSimulation.setPosition(n.id, to: SIMD3<Float>(x, 0, 0))
        }
        let adapter = GalaxyRegistryAdapter(registry: registry)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.projectCentroids, ["A": SIMD3<Float>(2, 0, 0), "B": SIMD3<Float>(6, 0, 0)])
        let first = try XCTUnwrap(adapter.galaxySnapshots.first { $0.id == "personal" })
        XCTAssertEqual(first.nodeCount, 3)
        XCTAssertEqual(first.radius, 4)
        XCTAssertEqual(first.dominantColor, adapter.projectColorMap["A"])
        XCTAssertEqual(adapter.galaxySnapshots.first { $0.id == "group:team" }?.radius, 0)
        XCTAssertEqual(adapter.galaxySnapshots.first { $0.id == "empty" }?.radius, 300)

        let changed = node(id: a.id, project: "B")
        personal.renderStore.nodes[0] = changed
        personal.renderStore.nodeById[changed.id] = changed
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.count, 4)
        XCTAssertEqual(adapter.projectCentroids, ["A": SIMD3<Float>(4, 0, 0), "B": SIMD3<Float>(4, 0, 0)])
        XCTAssertEqual(adapter.galaxySnapshots.first { $0.id == "personal" }?.dominantColor,
                       adapter.projectColorMap["B"])

        // Higher-priority duplicate changes ownership without changing merged count.
        team.insertNodeBatch([changed], config: config)
        registry.unifiedSimulation.setPosition(changed.id, to: .zero)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.count, 4)
        XCTAssertTrue(registry.galaxyForNode(changed.id) === team)
        XCTAssertEqual(adapter.galaxySnapshots.first { $0.id == "personal" }?.nodeCount, 2)
        XCTAssertEqual(adapter.galaxySnapshots.first { $0.id == "group:team" }?.nodeCount, 2)
        let cluster = try XCTUnwrap(adapter.nebulaClusters.first { $0.galaxyId == "group:team" && $0.project == "B" })
        XCTAssertEqual(cluster.centroid, SIMD3<Float>(5, 0, 0))
        XCTAssertEqual(cluster.count, 2)
        XCTAssertEqual(cluster.radius, 45)
        let nodeVersion = adapter.nodeVersion
        team.worldCenter = SIMD3<Float>(5, 0, 0)
        team.renderStore.colorMap["B"] = .green
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodeVersion, nodeVersion)
        let moved = try XCTUnwrap(adapter.galaxySnapshots.first { $0.id == "group:team" })
        XCTAssertEqual(moved.worldCenter, SIMD3<Float>(5, 0, 0))
        XCTAssertEqual(moved.radius, 5)
        XCTAssertEqual(moved.dominantColor, adapter.projectColorMap["B"])
    }

    func testAdapterCentroidProviderReplacementRejectsEqualRevisionCounters() throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        defer { lattice.close() }
        let old = GalaxyRegistry(), replacement = GalaxyRegistry()
        old.unifiedSimulation.isActive = false
        replacement.unifiedSimulation.isActive = false
        let personal = Galaxy(id: "personal", displayName: "Old", lattice: lattice.sendableReference)
        let team = Galaxy(id: "group:team", displayName: "New", lattice: lattice.sendableReference,
                          parentGalaxyId: "parent")
        old.register(personal)
        replacement.register(team)
        let a = node(project: "Old"), b = node(project: "New")
        personal.insertNodeBatch([a], config: config)
        team.insertNodeBatch([b], config: config)
        old.unifiedSimulation.setPosition(a.id, to: .zero)
        replacement.unifiedSimulation.setPosition(b.id, to: SIMD3<Float>(9, 0, 0))
        team.worldCenter = SIMD3<Float>(9, 0, 0)
        let adapter = GalaxyRegistryAdapter(registry: old)
        adapter.tick(dt: 1 / 60)
        replacement.mergeRenderData()
        XCTAssertEqual(old.mergedTopologyVersion, replacement.mergedTopologyVersion)
        XCTAssertEqual(old.mergedNodesVersion, replacement.mergedNodesVersion)
        XCTAssertEqual(old.mergedNodeAppendGeneration, replacement.mergedNodeAppendGeneration)
        adapter.registry = replacement
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [b.id])
        XCTAssertEqual(adapter.positionArray, [SIMD3<Float>(9, 0, 0)])
        XCTAssertEqual(adapter.projectCentroids, ["New": SIMD3<Float>(9, 0, 0)])
        XCTAssertEqual(adapter.nebulaClusters.first?.galaxyId, "group:team")
        let snapshot = try XCTUnwrap(adapter.galaxySnapshots.first)
        XCTAssertEqual(snapshot.id, "group:team")
        XCTAssertEqual(snapshot.displayName, "New")
        XCTAssertEqual(snapshot.parentGalaxyId, "parent")
        XCTAssertEqual(snapshot.nodeCount, 1)
        XCTAssertEqual(snapshot.radius, 0)
    }

    func testHubMembershipRevisionChangesOnlyForActualMembership() {
        let store = GraphRenderStore()
        let a = UUID(), b = UUID(), absent = UUID()
        let initial = store.hubsVersion
        XCTAssertFalse(store.removeHub(absent))
        store.subtractHubs([absent])
        store.hubs = []
        XCTAssertEqual(store.hubsVersion, initial)
        XCTAssertTrue(store.insertHub(a))
        let inserted = store.hubsVersion
        let retained = store.hubs
        XCTAssertFalse(store.insertHub(a))
        store.hubs.insert(a) // Compatibility mutation must also be a no-op.
        store.hubs = [a]
        store.subtractHubs([absent])
        XCTAssertEqual(store.hubsVersion, inserted)
        XCTAssertTrue(store.insertHub(b))
        XCTAssertNotEqual(store.hubsVersion, inserted)
        XCTAssertEqual(store.hubs, [a, b])
        XCTAssertEqual(retained, [a], "Previously published membership must remain immutable")
        let both = store.hubsVersion
        store.subtractHubs([a, absent])
        XCTAssertNotEqual(store.hubsVersion, both)
        XCTAssertEqual(store.hubs, [b])
        let subtracted = store.hubsVersion
        store.subtractHubs([a, absent])
        XCTAssertEqual(store.hubsVersion, subtracted)
        XCTAssertTrue(store.removeHub(b))
        XCTAssertTrue(store.hubs.isEmpty)
        let empty = store.hubsVersion
        XCTAssertFalse(store.removeHub(b))
        XCTAssertEqual(store.hubsVersion, empty)
        store.hubs = [a, b]
        XCTAssertNotEqual(store.hubsVersion, empty)
        XCTAssertEqual(store.hubs, [a, b])
    }

    func testStreamingPartOfHubChangesPatchOnlyAffectedSnapshots() async throws {
        let (lattice, registry, galaxy, generation, adapter) = try await streamingFixture()
        defer { lattice.close() }
        let a = node(label: "Source"), b = node(label: "Parent"), c = node(label: "Other")
        galaxy.applyLoadChunk(nodes: [(1, a), (2, b), (3, c)], generation: generation)
        let positions = [SIMD3<Float>(1, 2, 3), SIMD3<Float>(4, 5, 6), SIMD3<Float>(7, 8, 9)]
        for (value, position) in zip([a, b, c], positions) {
            registry.unifiedSimulation.setPosition(value.id, to: position)
        }
        adapter.tick(dt: 1 / 60)
        let retained = adapter.nodes
        let built = adapter.nodeSnapshotBuildCount, compared = adapter.nodePrefixComparisonCount
        let nodeVersion = adapter.nodeVersion
        let first = EdgeData(id: UUID(), sourceId: a.id, targetId: b.id, relation: "part_of")
        let second = EdgeData(id: UUID(), sourceId: c.id, targetId: b.id, relation: "part_of")
        let third = EdgeData(id: UUID(), sourceId: a.id, targetId: c.id, relation: "part_of")
        galaxy.applyLoadChunk(edges: [(1, first)], generation: generation)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.isHub), [false, true, false])
        XCTAssertEqual(adapter.nodeSnapshotBuildCount - built, 1)
        let firstHubVersion = galaxy.renderStore.hubsVersion

        galaxy.applyLoadChunk(edges: [(2, second)], generation: generation)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(galaxy.renderStore.hubsVersion, firstHubVersion)
        XCTAssertEqual(adapter.nodeSnapshotBuildCount - built, 1)
        XCTAssertEqual(adapter.nodes.map(\.isHub), [false, true, false])
        XCTAssertEqual(adapter.edges.map(\.id), [first.id, second.id])

        galaxy.applyLoadChunk(edges: [(3, third)], generation: generation)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.isHub), [false, true, true])
        XCTAssertEqual(adapter.nodeSnapshotBuildCount - built, 2)
        let bothHubVersion = galaxy.renderStore.hubsVersion
        galaxy.applyLoadChunk(removedEdges: [1], generation: generation)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(galaxy.renderStore.hubsVersion, bothHubVersion)
        XCTAssertEqual(adapter.nodeSnapshotBuildCount - built, 2)
        XCTAssertEqual(adapter.nodes.map(\.isHub), [false, true, true])
        galaxy.applyLoadChunk(removedEdges: [2], generation: generation)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.isHub), [false, false, true])
        XCTAssertEqual(adapter.nodeSnapshotBuildCount - built, 3)
        XCTAssertEqual(adapter.edges.map(\.id), [third.id])
        galaxy.applyLoadChunk(removedEdges: [3], generation: generation)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.isHub), [false, false, false])
        XCTAssertEqual(adapter.nodeSnapshotBuildCount - built, 4)
        XCTAssertTrue(adapter.hubs.isEmpty)
        XCTAssertTrue(adapter.edges.isEmpty)
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(adapter.nodes.map(\.label), [a.label, b.label, c.label])
        XCTAssertEqual(adapter.positionArray, positions)
        XCTAssertEqual(adapter.nodeVersion, nodeVersion)
        XCTAssertEqual(adapter.nodePrefixComparisonCount, compared)
        XCTAssertFalse(retained.contains { $0.isHub })
    }

    func testCertifiedAppendAndHubPatchPreservePrefixMetadataAndPositions() async throws {
        let (lattice, registry, galaxy, generation, adapter) = try await streamingFixture()
        defer { lattice.close() }
        let a = node(label: "Prefix A"), b = node(label: "Prefix B")
        let c = node(label: "Suffix C"), d = node(label: "Suffix D")
        galaxy.applyLoadChunk(nodes: [(1, a), (2, b)], generation: generation)
        registry.unifiedSimulation.setPosition(a.id, to: SIMD3<Float>(1, 0, 0))
        registry.unifiedSimulation.setPosition(b.id, to: SIMD3<Float>(2, 0, 0))
        adapter.tick(dt: 1 / 60)
        let retained = adapter.nodes
        let built = adapter.nodeSnapshotBuildCount, compared = adapter.nodePrefixComparisonCount
        let appendGeneration = galaxy.renderStore.nodeAppendGeneration
        galaxy.applyLoadChunk(nodes: [(3, c)], generation: generation)
        galaxy.applyLoadChunk(nodes: [(4, d)], generation: generation)
        galaxy.applyLoadChunk(edges: [
            (1, EdgeData(id: UUID(), sourceId: c.id, targetId: a.id, relation: "part_of")),
            (2, EdgeData(id: UUID(), sourceId: d.id, targetId: c.id, relation: "part_of")),
        ], generation: generation)
        registry.unifiedSimulation.setPosition(c.id, to: SIMD3<Float>(3, 0, 0))
        registry.unifiedSimulation.setPosition(d.id, to: SIMD3<Float>(4, 0, 0))
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, b.id, c.id, d.id])
        XCTAssertEqual(adapter.nodes.map(\.label), [a.label, b.label, c.label, d.label])
        XCTAssertEqual(adapter.nodes.map(\.isHub), [true, false, true, false])
        XCTAssertEqual(adapter.positionArray, [1, 2, 3, 4].map { SIMD3<Float>(Float($0), 0, 0) })
        XCTAssertEqual(galaxy.renderStore.nodeAppendGeneration, appendGeneration)
        XCTAssertEqual(adapter.nodePrefixComparisonCount, compared)
        XCTAssertEqual(adapter.nodeSnapshotBuildCount - built, 3,
                       "Build two appended snapshots and patch only the changed prefix hub")
        XCTAssertEqual(retained.map(\.id), [a.id, b.id])
        XCTAssertFalse(retained.contains { $0.isHub })

        let absent = UUID(), afterAppend = adapter.nodeSnapshotBuildCount
        galaxy.renderStore.insertHub(absent)
        adapter.tick(dt: 1 / 60)
        XCTAssertTrue(adapter.hubs.contains(absent))
        XCTAssertEqual(adapter.nodes.map(\.isHub), [true, false, true, false])
        XCTAssertEqual(adapter.nodeSnapshotBuildCount, afterAppend)
        XCTAssertEqual(adapter.nodePrefixComparisonCount, compared)
    }

    func testHubPatchesRespectMetadataReorderDeletionAndDuplicateIDs() async throws {
        let (lattice, registry, galaxy, generation, adapter) = try await streamingFixture()
        defer { lattice.close() }
        let a = node(label: "Original"), b = node(label: "Delete"), c = node(label: "Keep")
        galaxy.applyLoadChunk(nodes: [(1, a), (2, b), (3, c)], generation: generation)
        let pa = SIMD3<Float>(1, 0, 0), pb = SIMD3<Float>(2, 0, 0), pc = SIMD3<Float>(3, 0, 0)
        for (value, position) in zip([a, b, c], [pa, pb, pc]) {
            registry.unifiedSimulation.setPosition(value.id, to: position)
        }
        adapter.tick(dt: 1 / 60)
        let compared = adapter.nodePrefixComparisonCount
        let edited = node(id: a.id, label: "Edited", topic: "New topic", project: "New project")
        galaxy.applyLoadChunk(nodes: [(1, edited)], generation: generation)
        galaxy.renderStore.nodes.reverse()
        galaxy.renderStore.insertHub(a.id)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [c.id, b.id, a.id])
        XCTAssertEqual(adapter.nodes.map(\.isHub), [false, false, true])
        XCTAssertEqual(adapter.positionArray, [pc, pb, pa])
        let current = try XCTUnwrap(adapter.nodes.last)
        XCTAssertEqual(current.label, edited.label)
        XCTAssertEqual(current.content, edited.content)
        XCTAssertEqual(current.project, edited.project)
        XCTAssertEqual(current.topic, edited.topic)
        XCTAssertEqual(current.createdAt, edited.createdAt)
        XCTAssertEqual(current.lastAccessedAt, edited.lastAccessedAt)
        XCTAssertEqual(current.importance, edited.importance)
        XCTAssertGreaterThan(adapter.nodePrefixComparisonCount, compared)
        galaxy.applyLoadChunk(removedNodes: [2], generation: generation)
        galaxy.renderStore.removeHub(a.id)
        galaxy.renderStore.insertHub(c.id)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [c.id, a.id])
        XCTAssertEqual(adapter.nodes.map(\.isHub), [true, false])
        XCTAssertEqual(adapter.positionArray, [pc, pa])

        // Arbitrary single-store data can contain duplicate UUIDs. Every row
        // must get the hub style, without silently picking one cached index.
        let duplicate = node(id: a.id, label: "Duplicate copy", topic: "Duplicate topic")
        galaxy.renderStore.nodes = [edited, c, duplicate]
        adapter.tick(dt: 1 / 60)
        let beforeHub = adapter.nodeSnapshotBuildCount, beforeComparison = adapter.nodePrefixComparisonCount
        galaxy.renderStore.insertHub(a.id)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, c.id, a.id])
        XCTAssertEqual(adapter.nodes.map(\.label), [edited.label, c.label, duplicate.label])
        XCTAssertEqual(adapter.nodes.map(\.isHub), [true, true, true])
        XCTAssertEqual(adapter.positionArray, [pa, pc, pa])
        XCTAssertEqual(adapter.nodeSnapshotBuildCount - beforeHub, 2)
        XCTAssertEqual(adapter.nodePrefixComparisonCount, beforeComparison)

        // Truncating the duplicate suffix must leave a correct unique index.
        galaxy.renderStore.nodes.removeLast()
        adapter.tick(dt: 1 / 60)
        let beforeRemoval = adapter.nodeSnapshotBuildCount
        galaxy.renderStore.removeHub(a.id)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, c.id])
        XCTAssertEqual(adapter.nodes.map(\.isHub), [false, true])
        XCTAssertEqual(adapter.positionArray, [pa, pc])
        XCTAssertEqual(adapter.nodeSnapshotBuildCount - beforeRemoval, 1)
    }

    func testHubSnapshotIdentityResetsForSameIDGalaxyAndRegistryReplacement() throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        defer { lattice.close() }
        let old = GalaxyRegistry(), replacement = GalaxyRegistry()
        old.unifiedSimulation.isActive = false
        replacement.unifiedSimulation.isActive = false
        let first = Galaxy(id: "personal", displayName: "First", lattice: lattice.sendableReference)
        let second = Galaxy(id: "personal", displayName: "Second", lattice: lattice.sendableReference)
        old.register(first)
        replacement.register(second)
        let a = node(label: "A"), b = node(label: "B")
        first.insertNodeBatch([a, b], config: config)
        second.insertNodeBatch([a, b], config: config)
        first.renderStore.insertHub(a.id)
        second.renderStore.insertHub(b.id)
        let pa = SIMD3<Float>(1, 0, 0), pb = SIMD3<Float>(2, 0, 0)
        old.unifiedSimulation.setPosition(a.id, to: .zero)
        old.unifiedSimulation.setPosition(b.id, to: .zero)
        replacement.unifiedSimulation.setPosition(a.id, to: pa)
        replacement.unifiedSimulation.setPosition(b.id, to: pb)
        let adapter = GalaxyRegistryAdapter(registry: old)
        adapter.tick(dt: 1 / 60)
        replacement.mergeRenderData()
        XCTAssertEqual(old.mergedNodesVersion, replacement.mergedNodesVersion)
        XCTAssertEqual(old.mergedHubsVersion, replacement.mergedHubsVersion)
        XCTAssertEqual(adapter.nodes.map(\.isHub), [true, false])
        adapter.registry = replacement
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, b.id])
        XCTAssertEqual(adapter.nodes.map(\.isHub), [false, true])
        XCTAssertEqual(adapter.positionArray, [pa, pb])

        let sameID = Galaxy(id: "personal", displayName: "Same ID, new instance", lattice: lattice.sendableReference)
        replacement.register(sameID)
        let edited = node(id: a.id, label: "New instance A", topic: "New topic")
        sameID.insertNodeBatch([edited, b], config: config)
        sameID.renderStore.insertHub(a.id)
        XCTAssertEqual(sameID.renderStore.hubsVersion, second.renderStore.hubsVersion)
        replacement.unifiedSimulation.setPosition(a.id, to: pa)
        replacement.unifiedSimulation.setPosition(b.id, to: pb)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, b.id])
        XCTAssertEqual(adapter.nodes.map(\.label), [edited.label, b.label])
        XCTAssertEqual(adapter.nodes.map(\.isHub), [true, false])
        XCTAssertEqual(adapter.positionArray, [pa, pb])
        XCTAssertTrue(replacement.galaxyForNode(a.id) === sameID)
    }

    func testMultigalaxyHubUnionSurvivesRemovalFromOneDuplicateOwner() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        defer { lattice.close() }
        let registry = GalaxyRegistry()
        registry.unifiedSimulation.isActive = false
        let group = Galaxy(id: "group:team", displayName: "Team", lattice: lattice.sendableReference)
        let synced = Galaxy(id: "synced", displayName: "Synced", lattice: lattice.sendableReference)
        registry.register(group)
        registry.register(synced)
        let a = node(label: "Team source"), b = node(label: "Team winner"), c = node(label: "Synced source")
        let losingCopy = node(id: b.id, label: "Synced duplicate")
        group.insertNodeBatch([a, b], config: config)
        synced.insertNodeBatch([c, losingCopy], config: config)
        let groupChanges = await group.loadChanges
        let syncedChanges = await synced.loadChanges
        let groupGeneration = groupChanges.withLock { $0.begin() }
        let syncedGeneration = syncedChanges.withLock { $0.begin() }
        let groupEdge = EdgeData(id: UUID(), sourceId: a.id, targetId: b.id, relation: "part_of")
        let syncedEdge = EdgeData(id: UUID(), sourceId: c.id, targetId: b.id, relation: "part_of")
        group.applyLoadChunk(edges: [(1, groupEdge)], generation: groupGeneration)
        synced.applyLoadChunk(edges: [(1, syncedEdge)], generation: syncedGeneration)
        let positions = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(2, 0, 0), SIMD3<Float>(3, 0, 0)]
        for (value, position) in zip([a, b, c], positions) {
            registry.unifiedSimulation.setPosition(value.id, to: position)
        }
        let adapter = GalaxyRegistryAdapter(registry: registry)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(adapter.nodes.map(\.label), [a.label, b.label, c.label])
        XCTAssertEqual(adapter.nodes.map(\.isHub), [false, true, false])
        XCTAssertTrue(registry.galaxyForNode(b.id) === group)
        let built = adapter.nodeSnapshotBuildCount, compared = adapter.nodePrefixComparisonCount
        group.applyLoadChunk(removedEdges: [1], generation: groupGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertFalse(group.renderStore.hubs.contains(b.id))
        XCTAssertTrue(synced.renderStore.hubs.contains(b.id))
        XCTAssertEqual(adapter.nodes.map(\.isHub), [false, true, false])
        XCTAssertEqual(adapter.nodeSnapshotBuildCount, built)
        XCTAssertEqual(adapter.edges.map(\.id), [syncedEdge.id])
        synced.applyLoadChunk(removedEdges: [1], generation: syncedGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(adapter.nodes.map(\.label), [a.label, b.label, c.label])
        XCTAssertEqual(adapter.nodes.map(\.isHub), [false, false, false])
        XCTAssertEqual(adapter.positionArray, positions)
        XCTAssertEqual(adapter.nodeSnapshotBuildCount - built, 1)
        XCTAssertEqual(adapter.nodePrefixComparisonCount, compared)
        XCTAssertTrue(adapter.edges.isEmpty)
        XCTAssertTrue(registry.galaxyForNode(b.id) === group)
    }

    func testCertifiedTailAndNoOpAvoidRetainedMergeAndSnapshotWork() async throws {
        let (lattice, registry, group, groupGeneration, personal, personalGeneration, adapter) =
            try await crossGalaxyStreamingFixture()
        defer { lattice.close() }
        // The empty middle segment must not prevent a true tail proof or make
        // an insertion before the personal suffix look like a tail append.
        let empty = Galaxy(id: "synced", displayName: "Empty", lattice: lattice.sendableReference)
        registry.register(empty)
        let first = node(label: "Group winner")
        let suffix = (0..<1_024).map { node(label: "Personal \($0)") }
        group.applyLoadChunk(nodes: [(1, first)], generation: groupGeneration)
        personal.applyLoadChunk(nodes: suffix.enumerated().map { (Int64($0.offset + 1), $0.element) },
                                generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        let retained = adapter.nodes
        let copied = registry.retainedNodeCopyCount
        let snapshots = adapter.retainedSnapshotCopyCount
        let remapped = adapter.retainedNodeIndexRemapCount
        let built = adapter.nodeSnapshotBuildCount
        let tail = node(label: "Tail")
        let oldVersion = adapter.nodeVersion
        personal.applyLoadChunk(nodes: [(1_025, tail)], generation: personalGeneration)
        group.renderStore.insertHub(first.id)
        adapter.tick(dt: 1 / 60)
        let proof = try XCTUnwrap(adapter.nodeInsertionReuse(since: oldVersion, count: retained.count))
        XCTAssertTrue(proof.preservesExistingIndices)
        XCTAssertEqual(adapter.nodes.map(\.id), [first.id] + suffix.map(\.id) + [tail.id])
        XCTAssertEqual(adapter.nodes.first?.isHub, true, "A tail proof cannot suppress independent hub changes")
        XCTAssertEqual(adapter.nodeSnapshotBuildCount - built, 2, "One new row and one changed hub style")
        XCTAssertEqual(registry.retainedNodeCopyCount, copied)
        XCTAssertEqual(adapter.retainedSnapshotCopyCount, snapshots)
        XCTAssertEqual(adapter.retainedNodeIndexRemapCount, remapped)
        XCTAssertEqual(retained.map(\.id), [first.id] + suffix.map(\.id))
        XCTAssertFalse(retained[0].isHub, "Previously published value snapshots remain immutable")

        // A lower-priority duplicate publishes a new source revision without
        // adding a visible row. Keep its descriptor/version and old winner.
        let noOpVersion = adapter.nodeVersion, noOpBuilt = adapter.nodeSnapshotBuildCount
        personal.applyLoadChunk(nodes: [(1_026, node(id: first.id, label: "Hidden duplicate"))],
                                generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        let noOp = try XCTUnwrap(adapter.nodeInsertionReuse(since: noOpVersion, count: retained.count + 1))
        XCTAssertTrue(noOp.preservesExistingIndices)
        XCTAssertTrue(noOp.insertedRanges.isEmpty)
        XCTAssertGreaterThan(adapter.nodeVersion, noOpVersion)
        XCTAssertEqual(adapter.nodes.first?.label, first.label)
        XCTAssertTrue(registry.galaxyForNode(first.id) === group)
        XCTAssertEqual(adapter.nodeSnapshotBuildCount, noOpBuilt)
        XCTAssertEqual(registry.retainedNodeCopyCount, copied)
        XCTAssertEqual(adapter.retainedSnapshotCopyCount, snapshots)
        XCTAssertEqual(adapter.retainedNodeIndexRemapCount, remapped)

        // The no-op still consumed the hidden source row. A later append must
        // resume from the new galaxy ends and publish just its new visible row.
        let afterNoOp = node(label: "After no-op"), afterNoOpVersion = adapter.nodeVersion
        personal.applyLoadChunk(nodes: [(1_027, afterNoOp)], generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        let resumed = try XCTUnwrap(adapter.nodeInsertionReuse(since: afterNoOpVersion, count: retained.count + 1))
        XCTAssertTrue(resumed.preservesExistingIndices)
        XCTAssertEqual(adapter.nodes.map(\.id), [first.id] + suffix.map(\.id) + [tail.id, afterNoOp.id])
        XCTAssertEqual(adapter.nodeSnapshotBuildCount, noOpBuilt + 1)
        XCTAssertEqual(registry.retainedNodeCopyCount, copied)
        XCTAssertEqual(adapter.retainedSnapshotCopyCount, snapshots)
        XCTAssertEqual(adapter.retainedNodeIndexRemapCount, remapped)

        // Positive work control: a genuine interior insertion must still move
        // retained rows. The new counters would detect the former tail path.
        let interior = node(label: "Interior"), interiorVersion = adapter.nodeVersion
        group.applyLoadChunk(nodes: [(2, interior)], generation: groupGeneration)
        adapter.tick(dt: 1 / 60)
        let shifted = try XCTUnwrap(adapter.nodeInsertionReuse(since: interiorVersion, count: retained.count + 2))
        XCTAssertFalse(shifted.preservesExistingIndices)
        XCTAssertEqual(adapter.nodes.map(\.id), [first.id, interior.id] + suffix.map(\.id) + [tail.id, afterNoOp.id])
        XCTAssertEqual(registry.retainedNodeCopyCount - copied, UInt64(retained.count + 2))
        XCTAssertEqual(adapter.retainedSnapshotCopyCount - snapshots, UInt64(retained.count + 2))
        XCTAssertEqual(adapter.retainedNodeIndexRemapCount - remapped, UInt64(retained.count + 2))
    }

    func testCertifiedTailAndNoOpAvoidSimulationAndMembershipRemaps() throws {
        let sim = ForceSimulation3D(), owner = GalaxyRegistry()
        var indices = SimulationIndexCache(), memberships = CentroidMembershipCache()
        _ = indices.refresh(nodeCount: 0, preservingPrefix: false, simulation: sim, nodeVersion: 1) { _ in
            XCTFail("An empty cache has no IDs"); return UUID()
        }
        memberships.refresh(nodeCount: 0, nodeVersion: 1, appendGeneration: 1, provider: owner) { _ in
            XCTFail("An empty cache has no members"); return ("", "")
        }
        var ids = (0..<1_024).map { _ in UUID() }
        for id in ids.dropLast() { sim.addNode(id, project: "P", topic: "T") }
        var groups = Array(repeating: (project: "P", galaxy: "g"), count: ids.count)
        let emptyProof = try XCTUnwrap(NodeInsertionReuse(fromVersion: 1, toVersion: 2,
            oldCount: 0, newCount: ids.count, retainedRanges: []))
        XCTAssertTrue(indices.refresh(nodeCount: ids.count, preservingPrefix: false, simulation: sim,
            insertionReuse: emptyProof, nodeVersion: 2) { ids[$0] })
        memberships.refresh(nodeCount: groups.count, nodeVersion: 2, appendGeneration: 2,
            provider: owner, insertionReuse: emptyProof) { groups[$0] }
        XCTAssertEqual(indices.indices.last, -1)
        let oldCount = ids.count, tail = UUID()
        sim.addNode(ids.last!, project: "P", topic: "T")
        sim.addNode(tail, project: "Q", topic: "T")
        ids.append(tail); groups.append(("Q", "g"))
        let tailProof = try XCTUnwrap(NodeInsertionReuse(fromVersion: 2, toVersion: 3,
            oldCount: oldCount, newCount: ids.count,
            retainedRanges: [.init(oldRange: 0..<1, newStart: 0),
                             .init(oldRange: 1..<oldCount, newStart: 1)]))
        var visited: [Int] = []
        XCTAssertTrue(indices.refresh(nodeCount: ids.count, preservingPrefix: false, simulation: sim,
            insertionReuse: tailProof, nodeVersion: 3) { visited.append($0); return ids[$0] })
        XCTAssertEqual(visited, [oldCount - 1, oldCount], "Only a previous miss and the new tail need ID lookup")
        memberships.refresh(nodeCount: groups.count, nodeVersion: 3, appendGeneration: 3,
            provider: owner, insertionReuse: tailProof) { groups[$0] }
        let noOp = try XCTUnwrap(NodeInsertionReuse(fromVersion: 3, toVersion: 4,
            oldCount: ids.count, newCount: ids.count,
            retainedRanges: [.init(oldRange: 0..<ids.count, newStart: 0)]))
        visited.removeAll()
        XCTAssertTrue(indices.refresh(nodeCount: ids.count, preservingPrefix: false, simulation: sim,
            insertionReuse: noOp, nodeVersion: 4) { visited.append($0); return ids[$0] })
        memberships.refresh(nodeCount: groups.count, nodeVersion: 4, appendGeneration: 4,
            provider: owner, insertionReuse: noOp) { _ in
                XCTFail("A certified no-op has no new membership"); return ("", "")
            }
        XCTAssertTrue(visited.isEmpty)
        XCTAssertEqual(indices.indices, ids.map { sim.index(for: $0) ?? -1 })
        XCTAssertEqual(indices.retainedIndexCopyCount, 0)
        XCTAssertEqual(memberships.retainedMembershipCopyCount, 0)
        XCTAssertEqual(memberships.membershipOrderVisitCount, 0)

        let inserted = UUID(), previousCount = ids.count
        sim.addNode(inserted, project: "Inserted", topic: "T")
        ids.insert(inserted, at: 1); groups.insert(("Inserted", "h"), at: 1)
        let interior = try XCTUnwrap(NodeInsertionReuse(fromVersion: 4, toVersion: 5,
            oldCount: previousCount, newCount: ids.count,
            retainedRanges: [.init(oldRange: 0..<1, newStart: 0),
                             .init(oldRange: 1..<previousCount, newStart: 2)]))
        _ = indices.refresh(nodeCount: ids.count, preservingPrefix: false, simulation: sim,
            insertionReuse: interior, nodeVersion: 5) { ids[$0] }
        memberships.refresh(nodeCount: groups.count, nodeVersion: 5, appendGeneration: 5,
            provider: owner, insertionReuse: interior) { groups[$0] }
        XCTAssertEqual(indices.indices, ids.map { sim.index(for: $0) ?? -1 })
        XCTAssertEqual(indices.retainedIndexCopyCount, UInt64(previousCount))
        XCTAssertEqual(memberships.retainedMembershipCopyCount, UInt64(previousCount))
        XCTAssertEqual(memberships.membershipOrderVisitCount, UInt64(groups.count))
        let positions = ids.indices.map { SIMD3<Float>(Float($0), 0, 0) }
        memberships.reduce(positions: positions, simulationIndices: Array(ids.indices), galaxyCenters: [:])
        var reference = CentroidMembershipCache()
        reference.refresh(nodeCount: groups.count, nodeVersion: 5, appendGeneration: 5,
                          provider: owner) { groups[$0] }
        reference.reduce(positions: positions, simulationIndices: Array(ids.indices), galaxyCenters: [:])
        XCTAssertEqual(memberships.projectCentroids, reference.projectCentroids)
        XCTAssertEqual(memberships.nebulaClusters.map(\.project), reference.nebulaClusters.map(\.project))
    }

    func testCrossGalaxyInsertionReusePreservesRenderedOrderAndLivePositions() async throws {
        let (lattice, registry, group, groupGeneration, personal, personalGeneration, adapter) =
            try await crossGalaxyStreamingFixture()
        defer { lattice.close() }
        let a = node(label: "Group"), b = node(label: "Personal")
        let c = node(label: "Inserted group"), d = node(label: "Appended personal")
        group.applyLoadChunk(nodes: [(1, a)], generation: groupGeneration)
        personal.applyLoadChunk(nodes: [(1, b)], generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        let retained = adapter.nodes, oldVersion = adapter.nodeVersion
        let built = adapter.nodeSnapshotBuildCount, compared = adapter.nodePrefixComparisonCount
        let routed = registry.routingNodeVisitCount

        group.applyLoadChunk(nodes: [(2, c)], generation: groupGeneration)
        personal.applyLoadChunk(nodes: [(2, d)], generation: personalGeneration)
        for (index, value) in [a, c, b, d].enumerated() {
            registry.unifiedSimulation.setPosition(value.id, to: SIMD3<Float>(Float(index + 1), 0, 0))
        }
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, c.id, b.id, d.id])
        XCTAssertEqual(adapter.nodes.map(\.label), [a.label, c.label, b.label, d.label])
        XCTAssertEqual(adapter.positionArray, [1, 2, 3, 4].map { SIMD3<Float>(Float($0), 0, 0) })
        XCTAssertEqual(retained.map(\.id), [a.id, b.id], "Previously published snapshots remain unchanged")
        XCTAssertEqual(adapter.nodeSnapshotBuildCount - built, 2)
        XCTAssertEqual(adapter.nodePrefixComparisonCount, compared)
        XCTAssertEqual(registry.routingNodeVisitCount - routed, 2)
        XCTAssertTrue(registry.galaxyForNode(a.id) === group)
        XCTAssertTrue(registry.galaxyForNode(b.id) === personal)

        let reuse = try XCTUnwrap(registry.nodeInsertionReuse(since: oldVersion, count: 2))
        XCTAssertEqual(reuse.fromVersion, oldVersion)
        XCTAssertEqual(reuse.toVersion, adapter.nodeVersion)
        XCTAssertEqual(reuse.oldCount, 2)
        XCTAssertEqual(reuse.newCount, 4)
        XCTAssertEqual(reuse.insertedRanges, [1..<2, 3..<4])
        XCTAssertEqual(reuse.newIndex(forOldIndex: 0), 0)
        XCTAssertEqual(reuse.newIndex(forOldIndex: 1), 2)
        let erased: any SceneDataProvider = adapter
        let forwarded = try XCTUnwrap(erased.nodeInsertionReuse(since: oldVersion, count: 2))
        XCTAssertEqual(forwarded.insertedRanges, reuse.insertedRanges)
        XCTAssertEqual(forwarded.toVersion, reuse.toVersion)
    }

    func testCrossGalaxyInsertionBuildsOnlyNewSnapshotsAcrossLargeRetainedSuffix() async throws {
        let (lattice, registry, group, groupGeneration, personal, personalGeneration, adapter) =
            try await crossGalaxyStreamingFixture()
        defer { lattice.close() }
        let a = node(label: "Group"), c = node(label: "New group"), d = node(label: "New personal")
        let suffix = (0..<1_024).map { node(label: "Personal \($0)") }
        group.applyLoadChunk(nodes: [(1, a)], generation: groupGeneration)
        personal.applyLoadChunk(nodes: suffix.enumerated().map { (Int64($0.offset + 1), $0.element) },
                                generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        let previous = adapter.nodes, version = adapter.nodeVersion
        let built = adapter.nodeSnapshotBuildCount, compared = adapter.nodePrefixComparisonCount
        let routed = registry.routingNodeVisitCount

        group.applyLoadChunk(nodes: [(2, c)], generation: groupGeneration)
        personal.applyLoadChunk(nodes: [(1_025, d)], generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, c.id] + suffix.map(\.id) + [d.id])
        XCTAssertEqual(Array(adapter.nodes.dropFirst(2).prefix(suffix.count)).map(\.label), suffix.map(\.label))
        XCTAssertEqual(previous.map(\.id), [a.id] + suffix.map(\.id))
        XCTAssertEqual(adapter.nodeSnapshotBuildCount - built, 2, "An unchanged suffix is moved, not rebuilt")
        XCTAssertEqual(adapter.nodePrefixComparisonCount, compared)
        XCTAssertEqual(registry.routingNodeVisitCount - routed, 2, "Retained routing entries need no UUID visits")
        let reuse = try XCTUnwrap(registry.nodeInsertionReuse(since: version, count: previous.count))
        XCTAssertEqual(reuse.insertedRanges, [1..<2, 1_026..<1_027])
        XCTAssertEqual(reuse.newIndex(forOldIndex: 1_024), 1_025)
    }

    func testCrossGalaxyInsertionProofRejectsTakeoverAndMissedPublication() async throws {
        let (lattice, registry, group, groupGeneration, personal, personalGeneration, adapter) =
            try await crossGalaxyStreamingFixture()
        defer { lattice.close() }
        let a = node(label: "Group"), b = node(label: "Personal")
        group.applyLoadChunk(nodes: [(1, a)], generation: groupGeneration)
        personal.applyLoadChunk(nodes: [(1, b)], generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        let oldVersion = adapter.nodeVersion
        let winner = node(id: b.id, label: "Group wins", topic: "New owner")
        let d = node(label: "Personal suffix")
        group.applyLoadChunk(nodes: [(2, winner)], generation: groupGeneration)
        personal.applyLoadChunk(nodes: [(2, d)], generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertNil(registry.nodeInsertionReuse(since: oldVersion, count: 2),
                     "A higher-priority duplicate changes retained metadata and ownership")
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, b.id, d.id])
        XCTAssertEqual(adapter.nodes[1].label, winner.label)
        XCTAssertEqual(adapter.nodes[1].topic, winner.topic)
        XCTAssertTrue(registry.galaxyForNode(b.id) === group)

        let missedVersion = adapter.nodeVersion, missedCount = adapter.nodes.count
        let c = node(label: "Another group"), e = node(label: "Another personal")
        group.applyLoadChunk(nodes: [(3, c)], generation: groupGeneration)
        registry.mergeRenderData()
        let intermediateVersion = registry.mergedNodesVersion
        let intermediateCount = registry.mergedNodes.count
        XCTAssertNotNil(registry.nodeInsertionReuse(since: missedVersion, count: missedCount))
        personal.applyLoadChunk(nodes: [(3, e)], generation: personalGeneration)
        registry.mergeRenderData()
        XCTAssertNil(registry.nodeInsertionReuse(since: missedVersion, count: missedCount))
        XCTAssertNil(registry.nodeInsertionReuse(since: intermediateVersion, count: intermediateCount - 1))
        XCTAssertNotNil(registry.nodeInsertionReuse(since: intermediateVersion, count: intermediateCount))
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, b.id, c.id, d.id, e.id])
        XCTAssertEqual(adapter.nodes[1].label, winner.label)
        XCTAssertEqual(Set(registry.nodeToGalaxy.keys), Set([a.id, b.id, c.id, d.id, e.id]))
    }

    func testAdapterInsertionOriginChangesWhenRegistryLocalCountersMatch() throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        defer { lattice.close() }
        let original = GalaxyRegistry(), replacement = GalaxyRegistry()
        original.unifiedSimulation.isActive = false
        replacement.unifiedSimulation.isActive = false
        let oldGalaxy = Galaxy(id: "personal", displayName: "Old", lattice: lattice.sendableReference)
        let newGalaxy = Galaxy(id: "personal", displayName: "New", lattice: lattice.sendableReference)
        original.register(oldGalaxy)
        replacement.register(newGalaxy)
        let a = node(label: "Old A"), b = node(label: "Old B")
        let changedA = node(id: a.id, label: "New A", project: "Replacement")
        let changedB = node(id: b.id, label: "New B", project: "Replacement")
        oldGalaxy.insertNodeBatch([a], config: config)
        newGalaxy.insertNodeBatch([changedA], config: config)
        oldGalaxy.renderStore.bumpTopology()
        newGalaxy.renderStore.bumpTopology()
        let adapter = GalaxyRegistryAdapter(registry: original)
        let erased: any SceneDataProvider = adapter
        adapter.tick(dt: 1 / 60)
        replacement.mergeRenderData()
        let oldFromVersion = erased.nodeVersion, oldLocalFromVersion = original.mergedNodesVersion

        oldGalaxy.insertNodeBatch([b], config: config)
        newGalaxy.insertNodeBatch([changedB], config: config)
        oldGalaxy.renderStore.bumpTopology()
        newGalaxy.renderStore.bumpTopology()
        replacement.unifiedSimulation.setPosition(a.id, to: SIMD3<Float>(10, 0, 0))
        replacement.unifiedSimulation.setPosition(b.id, to: SIMD3<Float>(20, 0, 0))
        adapter.tick(dt: 1 / 60)
        replacement.mergeRenderData()
        XCTAssertEqual(original.mergedNodesVersion, replacement.mergedNodesVersion)
        XCTAssertEqual(original.mergedNodeAppendGeneration, replacement.mergedNodeAppendGeneration)
        XCTAssertEqual(original.mergedNodes.count, replacement.mergedNodes.count)
        let oldReuse = try XCTUnwrap(erased.nodeInsertionReuse(since: oldFromVersion, count: 1))
        XCTAssertNotNil(replacement.nodeInsertionReuse(since: oldLocalFromVersion, count: 1),
                        "The replacement deliberately has a numerically matching local certificate")
        let oldVersion = erased.nodeVersion, oldAppendGeneration = erased.nodeAppendGeneration

        adapter.registry = replacement
        XCTAssertGreaterThan(erased.nodeVersion, oldVersion)
        XCTAssertGreaterThan(erased.nodeAppendGeneration, oldAppendGeneration)
        XCTAssertNil(erased.nodeInsertionReuse(since: oldReuse.fromVersion, count: oldReuse.oldCount))
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, b.id])
        XCTAssertEqual(adapter.nodes.map(\.label), [changedA.label, changedB.label])
        XCTAssertEqual(adapter.positionArray, [SIMD3<Float>(10, 0, 0), SIMD3<Float>(20, 0, 0)])
        XCTAssertNil(erased.nodeInsertionReuse(since: oldReuse.fromVersion, count: oldReuse.oldCount))
        XCTAssertNil(erased.nodeInsertionReuse(since: oldVersion, count: 2))

        let replacementVersion = erased.nodeVersion
        let c = node(label: "New C", project: "Replacement")
        newGalaxy.insertNodeBatch([c], config: config)
        newGalaxy.renderStore.bumpTopology()
        adapter.tick(dt: 1 / 60)
        let currentReuse = try XCTUnwrap(erased.nodeInsertionReuse(since: replacementVersion, count: 2))
        XCTAssertEqual(currentReuse.fromVersion, replacementVersion)
        XCTAssertEqual(currentReuse.toVersion, erased.nodeVersion)
        XCTAssertGreaterThan(currentReuse.toVersion, replacement.mergedNodesVersion,
                             "Public certificates use the adapter origin, not bare registry counters")
        XCTAssertEqual(currentReuse.insertedRanges, [2..<3])
        XCTAssertEqual(adapter.nodes.map(\.label), [changedA.label, changedB.label, c.label])
    }

    func testAdapterInsertionOriginSurvivesDeallocatedRegistry() throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        defer { lattice.close() }
        var original: GalaxyRegistry? = GalaxyRegistry()
        original!.unifiedSimulation.isActive = false
        let oldGalaxy = Galaxy(id: "personal", displayName: "Old", lattice: lattice.sendableReference)
        original!.register(oldGalaxy)
        let a = node(label: "Old A"), b = node(label: "Old B")
        let oldEdge = EdgeData(id: UUID(), sourceId: a.id, targetId: b.id, relation: "old")
        oldGalaxy.renderStore.edges = [oldEdge]
        oldGalaxy.insertNodeBatch([a], config: config)
        oldGalaxy.renderStore.bumpTopology()
        let adapter = GalaxyRegistryAdapter(registry: original!)
        let erased: any SceneDataProvider = adapter
        adapter.tick(dt: 1 / 60)
        oldGalaxy.renderStore.nodes[0] = node(id: a.id, label: "Old edited A")
        oldGalaxy.renderStore.bumpTopology()
        adapter.tick(dt: 1 / 60)
        let oldFromVersion = erased.nodeVersion
        oldGalaxy.insertNodeBatch([b], config: config)
        oldGalaxy.renderStore.bumpTopology()
        adapter.tick(dt: 1 / 60)
        XCTAssertNotNil(erased.nodeInsertionReuse(since: oldFromVersion, count: 1))
        let oldVersion = erased.nodeVersion, oldAppend = erased.nodeAppendGeneration
        let oldEdgeVersion = erased.edgeVersion
        let oldEdgeAppend = try XCTUnwrap(erased.edgeAppendGeneration)
        weak var released = original
        original = nil
        XCTAssertNil(released)
        XCTAssertNil(adapter.registry)

        let replacement = GalaxyRegistry()
        replacement.unifiedSimulation.isActive = false
        let galaxy = Galaxy(id: "personal", displayName: "Replacement", lattice: lattice.sendableReference)
        replacement.register(galaxy)
        let newA = node(id: a.id, label: "Replacement A"), newB = node(id: b.id, label: "Replacement B")
        galaxy.renderStore.edges = [EdgeData(id: oldEdge.id, sourceId: b.id, targetId: a.id, relation: "new")]
        galaxy.insertNodeBatch([newA], config: config)
        galaxy.renderStore.bumpTopology()
        replacement.mergeRenderData()
        galaxy.insertNodeBatch([newB], config: config)
        galaxy.renderStore.bumpTopology()
        replacement.mergeRenderData()
        XCTAssertEqual(replacement.mergedNodesVersion + 1, oldVersion,
                       "Using a nil weak oldValue would collide with the former node epoch")
        XCTAssertEqual(replacement.mergedNodeAppendGeneration + 1, oldAppend,
                       "The same weak-origin bug would collide with append continuity")
        adapter.registry = replacement
        XCTAssertGreaterThan(erased.nodeVersion, oldVersion)
        XCTAssertGreaterThan(erased.nodeAppendGeneration, oldAppend)
        XCTAssertGreaterThan(erased.edgeVersion, oldEdgeVersion)
        XCTAssertGreaterThan(try XCTUnwrap(erased.edgeAppendGeneration), oldEdgeAppend)
        adapter.tick(dt: 1 / 60)
        XCTAssertNil(erased.nodeInsertionReuse(since: oldFromVersion, count: 1))
        XCTAssertNil(erased.nodeInsertionReuse(since: oldVersion, count: 2))
        XCTAssertEqual(adapter.nodes.map(\.label), [newA.label, newB.label])
        XCTAssertEqual(adapter.edges.map(\.sourceId), [b.id])
        XCTAssertEqual(adapter.edges.map(\.targetId), [a.id])
        XCTAssertEqual(adapter.edges.map(\.relation), ["new"])
    }

    func testLoadingCentroidInsertionReuseDoesNotScanPastUnconsumedEdit() async throws {
        let (lattice, registry, galaxy, generation, adapter) = try await streamingFixture()
        defer { lattice.close() }
        let a = node(project: "Original"), b = node(project: "Other")
        galaxy.applyLoadChunk(nodes: [(1, a), (2, b)], generation: generation)
        registry.unifiedSimulation.setPosition(a.id, to: SIMD3<Float>(1, 0, 0))
        registry.unifiedSimulation.setPosition(b.id, to: SIMD3<Float>(9, 0, 0))
        adapter.tick(dt: 1 / 60) // Frame 1 publishes the initial preview.
        let visited = adapter.centroidMembershipVisitCount
        XCTAssertEqual(visited, 2)
        XCTAssertEqual(adapter.projectCentroids["Original"], SIMD3<Float>(1, 0, 0))
        let edited = node(id: a.id, label: "Edited", project: "Edited")
        galaxy.applyLoadChunk(nodes: [(1, edited)], generation: generation)
        registry.unifiedSimulation.setPosition(a.id, to: SIMD3<Float>(5, 0, 0))
        adapter.tick(dt: 1 / 60) // Frame 2 cannot reuse old membership through the edit.
        XCTAssertEqual(adapter.nodes.first?.project, "Edited")
        XCTAssertEqual(adapter.centroidMembershipVisitCount, visited)
        XCTAssertNil(adapter.projectCentroids["Edited"])

        let beforeInsertion = adapter.nodeVersion
        let c = node(project: "Inserted")
        galaxy.applyLoadChunk(nodes: [(3, c)], generation: generation)
        registry.unifiedSimulation.setPosition(c.id, to: SIMD3<Float>(13, 0, 0))
        adapter.tick(dt: 1 / 60) // Frame 3 has a proof, but the centroid consumer missed its predecessor.
        XCTAssertNotNil(adapter.nodeInsertionReuse(since: beforeInsertion, count: 2))
        XCTAssertEqual(adapter.centroidMembershipVisitCount, visited)
        XCTAssertEqual(adapter.nodes.map(\.id), [a.id, b.id, c.id])
        for _ in 4...29 { adapter.tick(dt: 1 / 60) }
        XCTAssertEqual(adapter.centroidMembershipVisitCount, visited)
        XCTAssertEqual(adapter.projectCentroids["Original"], SIMD3<Float>(1, 0, 0))
        XCTAssertNil(adapter.projectCentroids["Edited"])
        XCTAssertNil(adapter.projectCentroids["Inserted"])

        adapter.tick(dt: 1 / 60) // Frame 30 performs the deferred full refresh once.
        XCTAssertEqual(adapter.centroidMembershipVisitCount - visited, 3)
        XCTAssertNil(adapter.projectCentroids["Original"])
        XCTAssertEqual(adapter.projectCentroids["Edited"], SIMD3<Float>(5, 0, 0))
        XCTAssertEqual(adapter.projectCentroids["Other"], SIMD3<Float>(9, 0, 0))
        XCTAssertEqual(adapter.projectCentroids["Inserted"], SIMD3<Float>(13, 0, 0))
        XCTAssertEqual(adapter.galaxySnapshots.first?.nodeCount, 3)
    }

    func testIndexInsertionReuseVisitsOnlyInsertedAndPreviouslyMissingNodes() throws {
        let sim = ForceSimulation3D()
        let oldIDs = (0..<1_024).map { _ in UUID() }
        for id in oldIDs.dropLast() { sim.addNode(id, project: "P", topic: "T") }
        var cache = SimulationIndexCache()
        _ = cache.refresh(nodeCount: oldIDs.count, preservingPrefix: false, simulation: sim,
                          nodeVersion: 1) { oldIDs[$0] }
        XCTAssertEqual(cache.indices.last, -1)
        let inserted = UUID(), appended = UUID()
        for id in [inserted, oldIDs.last!, appended] { sim.addNode(id, project: "P", topic: "T") }
        let ids = [oldIDs[0], inserted] + Array(oldIDs.dropFirst()) + [appended]
        let reuse = try XCTUnwrap(NodeInsertionReuse(
            fromVersion: 1, toVersion: 2, oldCount: oldIDs.count, newCount: ids.count,
            retainedRanges: [.init(oldRange: 0..<1, newStart: 0),
                             .init(oldRange: 1..<oldIDs.count, newStart: 2)]))
        var visited: [Int] = []
        XCTAssertTrue(cache.refresh(nodeCount: ids.count, preservingPrefix: false, simulation: sim,
                                    insertionReuse: reuse, nodeVersion: 2) {
            visited.append($0); return ids[$0]
        })
        XCTAssertEqual(visited.count, 3)
        XCTAssertEqual(Set(visited), Set([1, 1_024, 1_025]))
        XCTAssertEqual(cache.indices, ids.map { sim.index(for: $0) ?? -1 })
        visited.removeAll()
        XCTAssertFalse(cache.refresh(nodeCount: ids.count, preservingPrefix: true, simulation: sim,
                                     nodeVersion: 2) {
            visited.append($0); return ids[$0]
        })
        XCTAssertTrue(visited.isEmpty)
    }

    func testIndexInsertionReuseRejectsVersionCountIdentityAndCompactionMismatch() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let oldIDs = [a, b], ids = [a, c, b]
        let valid = try XCTUnwrap(NodeInsertionReuse(
            fromVersion: 1, toVersion: 2, oldCount: 2, newCount: 3,
            retainedRanges: [.init(oldRange: 0..<1, newStart: 0), .init(oldRange: 1..<2, newStart: 2)]))
        let invalidBindings = [
            NodeInsertionReuse(fromVersion: 0, toVersion: 2, oldCount: 2, newCount: 3,
                               retainedRanges: valid.retainedRanges),
            NodeInsertionReuse(fromVersion: 1, toVersion: 3, oldCount: 2, newCount: 3,
                               retainedRanges: valid.retainedRanges),
            NodeInsertionReuse(fromVersion: 1, toVersion: 2, oldCount: 1, newCount: 3,
                               retainedRanges: [.init(oldRange: 0..<1, newStart: 0)]),
            NodeInsertionReuse(fromVersion: 1, toVersion: 2, oldCount: 2, newCount: 4,
                               retainedRanges: valid.retainedRanges),
        ]
        for candidate in invalidBindings {
            let proof = try XCTUnwrap(candidate)
            let sim = ForceSimulation3D()
            for id in oldIDs { sim.addNode(id, project: "P", topic: "T") }
            var cache = SimulationIndexCache()
            _ = cache.refresh(nodeCount: 2, preservingPrefix: false, simulation: sim,
                              nodeVersion: 1) { oldIDs[$0] }
            sim.addNode(c, project: "P", topic: "T")
            var visited: [Int] = []
            _ = cache.refresh(nodeCount: 3, preservingPrefix: false, simulation: sim,
                              insertionReuse: proof, nodeVersion: 2) {
                visited.append($0); return ids[$0]
            }
            XCTAssertEqual(visited, [0, 1, 2])
            XCTAssertEqual(cache.indices, [0, 2, 1])
        }

        for replaceSimulation in [false, true] {
            let original = ForceSimulation3D()
            for id in oldIDs { original.addNode(id, project: "P", topic: "T") }
            var cache = SimulationIndexCache()
            _ = cache.refresh(nodeCount: 2, preservingPrefix: false, simulation: original,
                              nodeVersion: 1) { oldIDs[$0] }
            let current = replaceSimulation ? ForceSimulation3D() : original
            if replaceSimulation {
                for id in [b, c, a] { current.addNode(id, project: "P", topic: "T") }
                XCTAssertEqual(current.nodeIndexGeneration, original.nodeIndexGeneration)
            } else {
                current.removeNodes([a])
                for id in [c, a] { current.addNode(id, project: "P", topic: "T") }
            }
            var visited: [Int] = []
            _ = cache.refresh(nodeCount: 3, preservingPrefix: false, simulation: current,
                              insertionReuse: valid, nodeVersion: 2) {
                visited.append($0); return ids[$0]
            }
            XCTAssertEqual(visited, [0, 1, 2])
            XCTAssertEqual(cache.indices, [2, 1, 0])
        }
    }

    func testCentroidInsertionReuseVisitsOnlyNewMembershipAndRejectsStaleOwners() throws {
        let provider = GalaxyRegistry(), replacement = GalaxyRegistry()
        var cache = CentroidMembershipCache()
        let oldGroups = [(project: "P", galaxy: "g")]
            + Array(repeating: (project: "Q", galaxy: "h"), count: 1_023)
        cache.refresh(nodeCount: oldGroups.count, nodeVersion: 1, appendGeneration: 1,
                      provider: provider) { oldGroups[$0] }
        var groups = [oldGroups[0], (project: "Inserted", galaxy: "g")]
            + Array(oldGroups.dropFirst()) + [(project: "Q", galaxy: "h")]
        let reuse = try XCTUnwrap(NodeInsertionReuse(
            fromVersion: 1, toVersion: 2, oldCount: oldGroups.count, newCount: groups.count,
            retainedRanges: [.init(oldRange: 0..<1, newStart: 0),
                             .init(oldRange: 1..<oldGroups.count, newStart: 2)]))
        var visited: [Int] = []
        cache.refresh(nodeCount: groups.count, nodeVersion: 2, appendGeneration: 2,
                      provider: provider, insertionReuse: reuse) {
            visited.append($0); return groups[$0]
        }
        XCTAssertEqual(visited, [1, 1_025])
        let positions = [SIMD3<Float>.zero, SIMD3<Float>(9, 0, 0)]
            + Array(repeating: SIMD3<Float>(4, 0, 0), count: 1_023) + [SIMD3<Float>(8, 0, 0)]
        cache.reduce(positions: positions, simulationIndices: Array(groups.indices), galaxyCenters: [:])
        var reference = CentroidMembershipCache()
        reference.refresh(nodeCount: groups.count, nodeVersion: 2, appendGeneration: 2,
                          provider: provider) { groups[$0] }
        reference.reduce(positions: positions, simulationIndices: Array(groups.indices), galaxyCenters: [:])
        XCTAssertEqual(cache.projectCentroids, reference.projectCentroids)
        XCTAssertEqual(cache.projectCentroids["Inserted"], SIMD3<Float>(9, 0, 0))
        XCTAssertEqual(cache.galaxyAggregate(for: "g").count, 2)
        XCTAssertEqual(cache.galaxyAggregate(for: "h").count, 1_024)

        // An older descriptor cannot hide a same-count membership edit.
        groups[2] = (project: "Edited", galaxy: "new owner")
        visited.removeAll()
        cache.refresh(nodeCount: groups.count, nodeVersion: 3, appendGeneration: 3,
                      provider: provider, insertionReuse: reuse) {
            visited.append($0); return groups[$0]
        }
        XCTAssertEqual(visited, Array(groups.indices))
        cache.reduce(positions: positions, simulationIndices: Array(groups.indices), galaxyCenters: [:])
        XCTAssertEqual(cache.projectCentroids["Edited"], positions[2])
        XCTAssertEqual(cache.galaxyAggregate(for: "h").count, 1_023)

        let oldCount = groups.count
        groups[0] = (project: "Replacement", galaxy: "replacement")
        groups.append((project: "Tail", galaxy: "replacement"))
        let matchingNumbers = try XCTUnwrap(NodeInsertionReuse(
            fromVersion: 3, toVersion: 4, oldCount: oldCount, newCount: groups.count,
            retainedRanges: [.init(oldRange: 0..<oldCount, newStart: 0)]))
        visited.removeAll()
        cache.refresh(nodeCount: groups.count, nodeVersion: 4, appendGeneration: 4,
                      provider: replacement, insertionReuse: matchingNumbers) {
            visited.append($0); return groups[$0]
        }
        XCTAssertEqual(visited, Array(groups.indices), "Equal descriptor counters cannot certify another provider")
        cache.reduce(positions: positions + [SIMD3<Float>(20, 0, 0)],
                     simulationIndices: Array(groups.indices), galaxyCenters: [:])
        XCTAssertNil(cache.projectCentroids["P"])
        XCTAssertEqual(cache.projectCentroids["Replacement"], .zero)
        XCTAssertEqual(cache.galaxyAggregate(for: "replacement").count, 2)
    }

    func testCertifiedEdgeTailBatchesVisitOnlyNewRows() async throws {
        let (lattice, registry, group, groupGeneration, personal, personalGeneration, adapter) =
            try await crossGalaxyStreamingFixture()
        defer { lattice.close() }
        let a = node(), b = node()
        group.applyLoadChunk(nodes: [(1, a)], generation: groupGeneration)
        personal.applyLoadChunk(nodes: [(1, b)], generation: personalGeneration)
        let high = EdgeData(id: UUID(), sourceId: a.id, targetId: b.id, relation: "high")
        let first = EdgeData(id: UUID(), sourceId: b.id, targetId: a.id, relation: "first")
        group.applyLoadChunk(edges: [(1, high)], generation: groupGeneration)
        personal.applyLoadChunk(edges: [(1, first)], generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        let initialIDs = adapter.edges.map(\.id)
        let visits = registry.edgeMergeVisitCount, builds = adapter.edgeSnapshotBuildCount
        let comparisons = adapter.edgePrefixComparisonCount, generation = adapter.edgeAppendGeneration
        let additions = (0..<100).map { _ in
            EdgeData(id: UUID(), sourceId: a.id, targetId: b.id, relation: "new")
        }
        // Two source chunks before publication, then another publication.
        for batch in 0..<2 {
            let start = batch * 40
            personal.applyLoadChunk(edges: (start..<(start + 40)).map { (Int64($0 + 2), additions[$0]) },
                                    generation: personalGeneration)
        }
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.map(\.id), initialIDs + additions.prefix(80).map(\.id))
        personal.applyLoadChunk(edges: (80..<100).map { (Int64($0 + 2), additions[$0]) },
                                generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.map(\.id), initialIDs + additions.map(\.id))
        XCTAssertEqual(adapter.edges.suffix(100).map(\.sourceId), additions.map(\.sourceId))
        XCTAssertEqual(adapter.edges.suffix(100).map(\.targetId), additions.map(\.targetId))
        XCTAssertEqual(adapter.edges.suffix(100).map(\.relation), additions.map(\.relation))
        XCTAssertEqual(registry.edgeMergeVisitCount - visits, 100)
        XCTAssertEqual(adapter.edgeSnapshotBuildCount - builds, 100)
        XCTAssertEqual(adapter.edgePrefixComparisonCount, comparisons)
        XCTAssertEqual(adapter.edgeAppendGeneration, generation)
        XCTAssertEqual(registry.edgeTailMergeCount, 2)
    }

    func testEdgeTailPreservesHiddenAndDanglingWinnersAndRevealsLateEndpoints() async throws {
        let (lattice, registry, group, groupGeneration, personal, personalGeneration, adapter) =
            try await crossGalaxyStreamingFixture()
        defer { lattice.close() }
        let a = node(), b = node(), missing = node(), later = node()
        group.applyLoadChunk(nodes: [(1, a)], generation: groupGeneration)
        personal.applyLoadChunk(nodes: [(1, b)], generation: personalGeneration)
        let hidden = EdgeData(id: UUID(), sourceId: a.id, targetId: b.id, relation: "hidden")
        let dangling = EdgeData(id: UUID(), sourceId: a.id, targetId: missing.id, relation: "high")
        group.applyLoadChunk(edges: [(1, hidden), (2, dangling)], generation: groupGeneration)
        registry.hiddenRelations = ["hidden"]
        adapter.tick(dt: 1 / 60)
        let generation = adapter.edgeAppendGeneration, visits = registry.edgeMergeVisitCount
        let lowCopies = [hidden, dangling].map {
            EdgeData(id: $0.id, sourceId: a.id, targetId: b.id, relation: "low")
        }
        let late = EdgeData(id: UUID(), sourceId: a.id, targetId: later.id, relation: "late")
        personal.applyLoadChunk(edges: [(1, lowCopies[0]), (2, lowCopies[1]), (3, late)],
                                generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertTrue(adapter.edges.isEmpty)
        XCTAssertEqual(registry.edgeMergeVisitCount - visits, 3)
        XCTAssertEqual(adapter.edgeAppendGeneration, generation)
        personal.applyLoadChunk(nodes: [(2, later)], generation: personalGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.edges.map(\.id), [late.id])
        XCTAssertNotEqual(adapter.edgeAppendGeneration, generation)
        group.applyLoadChunk(removedEdges: [1, 2], generation: groupGeneration)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(Set(adapter.edges.map(\.id)), Set(lowCopies.map(\.id) + [late.id]))
        XCTAssertEqual(adapter.edges.filter { $0.id != late.id }.map(\.relation), ["low", "low"])
    }

    func testUnsafeEdgeTailChangesMatchConservativeMerge() async throws {
        for mode in 0..<8 {
            let (lattice, registry, group, groupGeneration, personal, personalGeneration, adapter) =
                try await crossGalaxyStreamingFixture()
            defer { lattice.close() }
            let a = node(), b = node(), c = node()
            group.applyLoadChunk(nodes: [(1, a)], generation: groupGeneration)
            personal.applyLoadChunk(nodes: [(1, b), (2, c)], generation: personalGeneration)
            let original = EdgeData(id: UUID(), sourceId: a.id, targetId: b.id, relation: "old")
            personal.applyLoadChunk(edges: [(1, original)], generation: personalGeneration)
            adapter.tick(dt: 1 / 60)
            let generation = adapter.edgeAppendGeneration
            let extra = EdgeData(id: UUID(), sourceId: b.id, targetId: a.id, relation: "new")
            let edited = EdgeData(id: original.id, sourceId: c.id, targetId: a.id, relation: "edited")
            personal.applyLoadChunk(edges: [(2, extra)], generation: personalGeneration)
            switch mode {
            case 0: // Higher-priority takeover, including changed endpoints/relation.
                group.applyLoadChunk(edges: [(1, edited)], generation: groupGeneration)
            case 1:
                personal.applyLoadChunk(edges: [(1, edited)], generation: personalGeneration)
            case 2:
                personal.applyLoadChunk(removedEdges: [1], generation: personalGeneration)
            case 3:
                registry.hiddenRelations = ["old"]
            case 4: // Arbitrary subscript mutation must invalidate journal continuity.
                personal.renderStore.allEdges[original.id] = edited
            case 5:
                personal.applyLoadChunk(removedNodes: [1], generation: personalGeneration)
            case 6: // Earlier unique insertion also cannot extend the published tail.
                group.applyLoadChunk(edges: [(1, EdgeData(id: UUID(), sourceId: a.id,
                    targetId: b.id, relation: "earlier"))], generation: groupGeneration)
            default:
                let replacement = Galaxy(id: "personal", displayName: "Replacement", lattice: lattice.sendableReference)
                replacement.insertNodeBatch([b, c], config: config)
                replacement.renderStore.allEdges = [edited.id: edited, extra.id: extra]
                registry.register(replacement)
            }
            adapter.tick(dt: 1 / 60)
            var seen: Set<UUID> = []
            var expected: [EdgeData] = []
            let visible = Set(registry.mergedNodes.map(\.id))
            for galaxy in registry.galaxiesInPrecedenceOrder() {
                for (id, edge) in galaxy.renderStore.allEdges {
                    guard seen.insert(id).inserted, !registry.hiddenRelations.contains(edge.relation),
                          visible.contains(edge.sourceId), visible.contains(edge.targetId) else { continue }
                    expected.append(edge)
                }
            }
            XCTAssertEqual(adapter.edges.map(\.id), expected.map(\.id), "mode \(mode)")
            XCTAssertEqual(adapter.edges.map(\.sourceId), expected.map(\.sourceId), "mode \(mode)")
            XCTAssertEqual(adapter.edges.map(\.targetId), expected.map(\.targetId), "mode \(mode)")
            XCTAssertEqual(adapter.edges.map(\.relation), expected.map(\.relation), "mode \(mode)")
            XCTAssertNotEqual(adapter.edgeAppendGeneration, generation, "mode \(mode)")
            XCTAssertEqual(registry.edgeTailMergeCount, 0, "mode \(mode)")
        }
    }

    private func crossGalaxyStreamingFixture() async throws
        -> (Lattice, GalaxyRegistry, Galaxy, UInt64, Galaxy, UInt64, GalaxyRegistryAdapter) {
        let (lattice, registry, personal, personalGeneration, adapter) = try await streamingFixture()
        let group = Galaxy(id: "group:team", displayName: "Team", lattice: lattice.sendableReference)
        registry.register(group)
        let changes = await group.loadChanges
        let generation = changes.withLock { $0.begin() }
        group.loadStatus = .loading
        return (lattice, registry, group, generation, personal, personalGeneration, adapter)
    }

    private func streamingFixture() async throws
        -> (Lattice, GalaxyRegistry, Galaxy, UInt64, GalaxyRegistryAdapter) {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        registry.unifiedSimulation.isActive = false
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let changes = await galaxy.loadChanges
        let generation = changes.withLock { $0.begin() }
        galaxy.loadStatus = .loading
        return (lattice, registry, galaxy, generation, GalaxyRegistryAdapter(registry: registry))
    }

    private func node(id: UUID = UUID(), label: String = "Original", topic: String = "Topic", project: String = "Project") -> NodeData {
        NodeData(id: id, project: project, topic: topic, label: label, content: label,
                 createdAt: .distantPast, lastAccessedAt: .distantPast, importance: 3)
    }
}
