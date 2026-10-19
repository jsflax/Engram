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
