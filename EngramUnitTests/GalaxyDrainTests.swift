@testable import Engram
import EngramKit
import Lattice
import SwiftUI
import XCTest

private extension Galaxy {
    /// The fixture producer enters the Galaxy actor just like loadData/observers;
    /// tests never reach across actor isolation to mutate the pending buffer.
    func mutatePendingUpdateForTesting(_ mutation: @Sendable (inout RenderUpdate) -> Void) {
        pendingUpdate.withLock { mutation(&$0) }
    }
}

@MainActor
final class GalaxyDrainTests: XCTestCase {
    private let config = DrainConfig(hiddenProjects: [], hiddenRelations: [], timeFilter: nil,
                                     is3D: true, soundEnabled: false, notificationsEnabled: false)

    func testPublishedDrainConfigCarriesAllGraphSettings() {
        let registry = GalaxyRegistry()
        let settings = VisualizerConfig()
        settings.hiddenProjects = ["Hidden"]
        settings.hiddenRelations = ["part_of"]
        settings.soundEnabled = true
        settings.notificationsEnabled = true
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        registry.updateDrainConfig(from: settings, timeFilter: date)
        XCTAssertEqual(registry.hiddenProjects, settings.hiddenProjects)
        XCTAssertEqual(registry.hiddenRelations, settings.hiddenRelations)
        XCTAssertEqual(registry.currentDrainConfig.hiddenProjects, settings.hiddenProjects)
        XCTAssertEqual(registry.currentDrainConfig.hiddenRelations, settings.hiddenRelations)
        XCTAssertEqual(registry.currentDrainConfig.timeFilter, date)
        XCTAssertTrue(registry.currentDrainConfig.is3D)
        XCTAssertTrue(registry.currentDrainConfig.soundEnabled)
        XCTAssertTrue(registry.currentDrainConfig.notificationsEnabled)
        settings.hiddenProjects = []
        settings.hiddenRelations = []
        settings.soundEnabled = false
        settings.notificationsEnabled = false
        registry.updateDrainConfig(from: settings, timeFilter: nil)
        XCTAssertTrue(registry.currentDrainConfig.hiddenProjects.isEmpty)
        XCTAssertTrue(registry.currentDrainConfig.hiddenRelations.isEmpty)
        XCTAssertNil(registry.currentDrainConfig.timeFilter)
        XCTAssertFalse(registry.currentDrainConfig.soundEnabled)
        XCTAssertFalse(registry.currentDrainConfig.notificationsEnabled)
    }

    func testAdapterInitialLoadUsesPublishedProjectRelationAndTimeFilters() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let settings = VisualizerConfig()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        settings.hiddenProjects = ["Hidden"]
        settings.hiddenRelations = ["part_of"]
        // Match GraphView: publish saved settings before registering/loading.
        registry.updateDrainConfig(from: settings, timeFilter: date)
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let nodes = (0..<4).map { index in
            NodeData(id: UUID(), project: index == 2 ? "Hidden" : "Visible", topic: "topic",
                     label: "Node", content: "", createdAt: index == 3 ? date.addingTimeInterval(1) : date,
                     lastAccessedAt: date, importance: 1)
        }
        let visible = EdgeData(id: UUID(), sourceId: nodes[0].id, targetId: nodes[1].id, relation: "relates_to")
        let hidden = EdgeData(id: UUID(), sourceId: nodes[1].id, targetId: nodes[0].id, relation: "part_of")
        await galaxy.mutatePendingUpdateForTesting {
            $0.bulkEdges = ([visible.id: visible, hidden.id: hidden], [:],
                           [nodes[0].id: [visible, hidden], nodes[1].id: [visible, hidden]])
            $0.bulkNodeBatches = [nodes.enumerated().map { (pk: Int64($0.offset + 1), node: $0.element) }]
            $0.finalize = true
        }
        let adapter = GalaxyRegistryAdapter(registry: registry)
        adapter.tick(dt: 1 / 60)
        XCTAssertTrue(galaxy.isLoaded)
        XCTAssertEqual(Set(adapter.nodes.map(\.id)), Set(nodes.prefix(2).map(\.id)))
        XCTAssertEqual(adapter.edges.map(\.id), [visible.id])
        XCTAssertEqual(registry.unifiedSimulation.nodeCount, 2)
        XCTAssertEqual(registry.unifiedSimulation.edgeIndicesPublic.count, 1)
    }

    func testDeferredLiveInsertsUseLatestFiltersAndRefreshHiddenPanelCounts() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let settings = VisualizerConfig()
        registry.updateDrainConfig(from: settings, timeFilter: nil)
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let nodes = makeNodes(2)
        galaxy.insertNodeBatch(nodes, config: config)
        galaxy.renderStore.bumpTopology()
        galaxy.setIsInitialLoad(false)
        registry.mergeRenderData()
        let revision = registry.mergedTopologyVersion
        let hidden = NodeData(id: UUID(), project: "Hidden", topic: "topic", label: "Hidden", content: "",
                              createdAt: nodes[0].createdAt, lastAccessedAt: nodes[0].lastAccessedAt, importance: 1)
        let edge = EdgeData(id: UUID(), sourceId: nodes[0].id, targetId: nodes[1].id, relation: "part_of")
        galaxy.handleNodeInsert(pk: 3, node: hidden, config: registry.currentDrainConfig)
        galaxy.handleEdgeInsert(edge, config: registry.currentDrainConfig)
        let nodeFlush = galaxy.renderStore.pendingNodeFlush
        let edgeFlush = galaxy.renderStore.pendingEdgeFlush
        // A setting can change before the coalescing tasks resume; neither
        // flush may use its captured, previously unfiltered configuration.
        settings.hiddenProjects = ["Hidden"]
        settings.hiddenRelations = ["part_of"]
        registry.updateDrainConfig(from: settings, timeFilter: nil)
        await nodeFlush?.value
        await edgeFlush?.value
        registry.mergeRenderData()
        XCTAssertEqual(galaxy.renderStore.allNodes.count, 3)
        XCTAssertEqual(galaxy.renderStore.nodes.count, 2)
        XCTAssertNil(galaxy.renderStore.nodeById[hidden.id])
        XCTAssertTrue(galaxy.renderStore.edges.isEmpty)
        XCTAssertEqual(registry.unifiedSimulation.nodeCount, 2)
        XCTAssertGreaterThan(registry.mergedTopologyVersion, revision)
        // Wait on observable state with a bound; never miss an early refresh.
        let deadline = Date().addingTimeInterval(2)
        while registry.panelSnapshot.totalCount != 3 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(registry.panelSnapshot.totalCount, 3)
        XCTAssertEqual(registry.panelSnapshot.visibleCount, 2)
        XCTAssertEqual(registry.panelSnapshot.projectCounts["Hidden"], 1)
        XCTAssertTrue(registry.panelSnapshot.projects.contains("Hidden"))
    }

    func testInitialNodeScalarSnapshotReducesSQLAndRestoresLiveReads() throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let author = UUID()
        let memory = Memory(content: "Snapshot content", topic: "architecture", project: "Source",
                            importance: 4, authorUserId: author)
        try lattice.add(memory)
        let row = try XCTUnwrap(lattice.objects(Memory.self).first)
        row.dematerialize()
        let liveStart = Lattice.threadSQLStatementCount
        let expected = (row.globalId, row.project, row.topic, row.content,
                        row.createdAt, row.lastAccessedAt, row.importance)
        let liveReads = Lattice.threadSQLStatementCount - liveStart
        let snapshotStart = Lattice.threadSQLStatementCount
        let snapshot = try XCTUnwrap(Galaxy.snapshotNode(row,
            filter: { !$0.isPrivate },
            projectResolver: { userID, project in userID == author ? "Resolved " + project : project }))
        let snapshotReads = Lattice.threadSQLStatementCount - snapshotStart

        XCTAssertLessThan(snapshotReads, liveReads)
        XCTAssertLessThanOrEqual(snapshotReads, 2, "A scalar row snapshot must not issue per-property SQL")
        XCTAssertFalse(row.isMaterialized)
        XCTAssertEqual(snapshot.node.id, expected.0)
        XCTAssertEqual(snapshot.node.project, "Resolved " + expected.1)
        XCTAssertEqual(snapshot.node.topic, expected.2)
        XCTAssertEqual(snapshot.node.content, expected.3)
        XCTAssertEqual(snapshot.node.createdAt, expected.4)
        XCTAssertEqual(snapshot.node.lastAccessedAt, expected.5)
        XCTAssertEqual(snapshot.node.importance, expected.6)
        XCTAssertNil(Galaxy.snapshotNode(row, filter: { $0.project == "Excluded" }))
        XCTAssertFalse(row.isMaterialized)

        row.materialize()
        let materializedStart = Lattice.threadSQLStatementCount
        XCTAssertNotNil(Galaxy.snapshotNode(row))
        XCTAssertEqual(Lattice.threadSQLStatementCount, materializedStart)
        XCTAssertTrue(row.isMaterialized, "A caller's existing snapshot scope must be preserved")
    }

    func testInitialEdgeScalarSnapshotReducesSQLAndPreservesEndpoints() throws {
        let lattice = try Lattice(MemoryEdge.self, configuration: .init(storage: .memory()))
        let edge = MemoryEdge(sourceGlobalId: UUID(), targetGlobalId: UUID(), relation: .partOf)
        try lattice.add(edge)
        let row = try XCTUnwrap(lattice.objects(MemoryEdge.self).first)
        row.dematerialize()
        let liveStart = Lattice.threadSQLStatementCount
        let expected = (row.globalId, row.sourceGlobalId, row.targetGlobalId, row.relation.rawValue)
        let liveReads = Lattice.threadSQLStatementCount - liveStart
        let snapshotStart = Lattice.threadSQLStatementCount
        let snapshot = try XCTUnwrap(Galaxy.snapshotEdge(row))
        let snapshotReads = Lattice.threadSQLStatementCount - snapshotStart

        XCTAssertLessThan(snapshotReads, liveReads)
        XCTAssertLessThanOrEqual(snapshotReads, 2)
        XCTAssertFalse(row.isMaterialized)
        XCTAssertEqual(snapshot.edge.id, expected.0)
        XCTAssertEqual(snapshot.edge.sourceId, expected.1)
        XCTAssertEqual(snapshot.edge.targetId, expected.2)
        XCTAssertEqual(snapshot.edge.relation, expected.3)
    }

    func testInitialFinalizeMatchesFullDerivationWithFiltersAndDanglingEdges() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let actual = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(actual)
        let reference = Galaxy(id: "reference", displayName: "Reference", lattice: lattice.sendableReference)
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let nodes = (0..<6).map { index in
            NodeData(id: UUID(), project: index == 3 ? "Hidden" : "Visible",
                     topic: index == 2 ? "general" : "architecture", label: "Node \(index)",
                     content: "Content \(index)", createdAt: index == 5 ? epoch.addingTimeInterval(100) : epoch,
                     lastAccessedAt: epoch, importance: index)
        }
        let edges = [
            EdgeData(id: UUID(), sourceId: nodes[0].id, targetId: nodes[1].id, relation: "relates_to"),
            EdgeData(id: UUID(), sourceId: nodes[1].id, targetId: nodes[0].id, relation: "part_of"),
            EdgeData(id: UUID(), sourceId: nodes[3].id, targetId: nodes[0].id, relation: "relates_to"),
            EdgeData(id: UUID(), sourceId: nodes[5].id, targetId: nodes[0].id, relation: "relates_to"),
            EdgeData(id: UUID(), sourceId: nodes[0].id, targetId: nodes[0].id, relation: "relates_to"),
            EdgeData(id: UUID(), sourceId: UUID(), targetId: nodes[1].id, relation: "relates_to"),
        ]
        let allEdges = Dictionary(uniqueKeysWithValues: edges.map { ($0.id, $0) })
        var adjacency: [UUID: [EdgeData]] = [:]
        for edge in edges {
            adjacency[edge.sourceId, default: []].append(edge)
            adjacency[edge.targetId, default: []].append(edge)
        }
        let byNode = adjacency
        let filtered = DrainConfig(hiddenProjects: ["Hidden"], hiddenRelations: ["part_of"],
                                   timeFilter: epoch, is3D: true, soundEnabled: false, notificationsEnabled: false)
        reference.renderStore.allEdges = allEdges
        reference.renderStore.edgesByNode = byNode
        reference.insertNodeBatch(nodes, config: filtered)
        reference.recomputeDerivedData()
        await actual.mutatePendingUpdateForTesting {
            $0.bulkEdges = (allEdges, [:], byNode)
            $0.bulkNodeBatches = nodes.enumerated().map { [(pk: Int64($0.offset + 1), node: $0.element)] }
            $0.finalize = true
        }
        for _ in nodes { actual.drainPendingUpdate(config: filtered, workBudget: 0) }

        XCTAssertTrue(actual.isLoaded, "Finalization remains synchronous with the last complete node batch")
        XCTAssertEqual(actual.renderStore.visibleNodeIds, reference.renderStore.visibleNodeIds)
        XCTAssertEqual(actual.renderStore.nodeById.mapValues(\.label), reference.renderStore.nodeById.mapValues(\.label))
        XCTAssertEqual(actual.renderStore.edgeCountByNode, reference.renderStore.edgeCountByNode)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: actual.renderStore.relationCounts),
                       Dictionary(uniqueKeysWithValues: reference.renderStore.relationCounts))
        XCTAssertEqual(actual.renderStore.topicGroups, reference.renderStore.topicGroups)
        XCTAssertEqual(actual.renderStore.hubs, reference.renderStore.hubs)
        XCTAssertEqual(Set(actual.renderStore.colorMap.keys), Set(reference.renderStore.colorMap.keys))
        XCTAssertEqual(actual.renderStore.filteredEdgeIds, reference.renderStore.filteredEdgeIds)
    }

    func testInitialAggregatesReconcileMetadataEditsBetweenDrainSlices() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let nodes = makeNodes(3)
        await galaxy.mutatePendingUpdateForTesting {
            $0.bulkNodeBatches = nodes.enumerated().map { [(pk: Int64($0.offset + 1), node: $0.element)] }
            $0.finalize = true
        }
        galaxy.drainPendingUpdate(config: config, workBudget: 0)
        let changed = NodeData(id: nodes[0].id, project: "Renamed", topic: "different", label: "Changed",
                               content: "New metadata", createdAt: nodes[0].createdAt,
                               lastAccessedAt: nodes[0].lastAccessedAt, importance: 5)
        galaxy.handleNodeUpdate(pk: 1, node: changed, config: config)
        galaxy.drainPendingUpdate(config: config, workBudget: 0)
        galaxy.drainPendingUpdate(config: config, workBudget: 0)

        XCTAssertTrue(galaxy.isLoaded)
        XCTAssertEqual(galaxy.renderStore.nodeById[nodes[0].id]?.label, "Changed")
        XCTAssertEqual(galaxy.renderStore.topicGroups.count, 1)
        XCTAssertEqual(galaxy.renderStore.topicGroups.first?.ids, Array(nodes.dropFirst()).map(\.id))
        XCTAssertNotNil(galaxy.renderStore.colorMap["Renamed"])
    }

    func testInitialAggregatesReconcileVisibilityChangesBetweenDrainSlices() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let template = makeNodes(3)
        let nodes = template.enumerated().map { index, node in
            NodeData(id: node.id, project: index == 0 ? "Hidden" : "Visible", topic: node.topic,
                     label: node.label, content: node.content, createdAt: node.createdAt,
                     lastAccessedAt: node.lastAccessedAt, importance: node.importance)
        }
        let edges = (1..<3).map { index in
            EdgeData(id: UUID(), sourceId: nodes[index - 1].id, targetId: nodes[index].id, relation: "relates_to")
        }
        var adjacency: [UUID: [EdgeData]] = [:]
        for edge in edges {
            adjacency[edge.sourceId, default: []].append(edge)
            adjacency[edge.targetId, default: []].append(edge)
        }
        let byNode = adjacency
        await galaxy.mutatePendingUpdateForTesting {
            $0.bulkEdges = (Dictionary(uniqueKeysWithValues: edges.map { ($0.id, $0) }), [:], byNode)
            $0.bulkEdgeCounts = byNode.mapValues(\.count)
            $0.bulkNodeBatches = nodes.enumerated().map { [(pk: Int64($0.offset + 1), node: $0.element)] }
            $0.finalize = true
        }
        galaxy.drainPendingUpdate(config: config, workBudget: 0)
        // Match a UI filtering update: mutate visible nodes, reconcile indexes,
        // and advance topology before the next producer slice arrives.
        galaxy.renderStore.nodes.removeAll { $0.project == "Hidden" }
        galaxy.recomputeDerivedData()
        galaxy.renderStore.bumpTopology()
        registry.unifiedSimulation.removeNodes([nodes[0].id])
        let hidden = DrainConfig(hiddenProjects: ["Hidden"], hiddenRelations: [], timeFilter: nil,
                                 is3D: true, soundEnabled: false, notificationsEnabled: false)
        galaxy.drainPendingUpdate(config: hidden, workBudget: 0)
        galaxy.drainPendingUpdate(config: hidden, workBudget: 0)

        XCTAssertTrue(galaxy.isLoaded)
        XCTAssertEqual(galaxy.renderStore.visibleNodeIds, Set(nodes.dropFirst().map(\.id)))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: galaxy.renderStore.relationCounts), ["relates_to": 1])
        XCTAssertEqual(galaxy.renderStore.topicGroups.first?.ids, Array(nodes.dropFirst()).map(\.id))
        XCTAssertEqual(galaxy.renderStore.edgeCountByNode, byNode.mapValues(\.count))
        XCTAssertNotNil(galaxy.renderStore.colorMap["Hidden"])
        XCTAssertEqual(registry.unifiedSimulation.nodeCount, 2)
    }

    func testFinalizedEnvelopeDeletionPublishesReconciledCountsAndTopics() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let nodes = makeNodes(2)
        let edge = EdgeData(id: UUID(), sourceId: nodes[0].id, targetId: nodes[1].id, relation: "relates_to")
        await galaxy.mutatePendingUpdateForTesting {
            $0.bulkEdges = ([edge.id: edge], [:], [nodes[0].id: [edge], nodes[1].id: [edge]])
            $0.bulkNodeBatches = [[(pk: 1, node: nodes[0])], [(pk: 2, node: nodes[1])]]
            $0.removedNodePks = [2]
            $0.finalize = true
        }
        galaxy.drainPendingUpdate(config: config, workBudget: 0)
        XCTAssertFalse(galaxy.isLoaded)
        galaxy.drainPendingUpdate(config: config, workBudget: 0)

        XCTAssertTrue(galaxy.isLoaded)
        XCTAssertEqual(galaxy.renderStore.nodes.map(\.id), [nodes[0].id])
        XCTAssertEqual(galaxy.renderStore.nodeById.count, 1)
        XCTAssertNil(galaxy.renderStore.pkToGlobalId[2])
        XCTAssertTrue(galaxy.renderStore.edges.isEmpty)
        XCTAssertTrue(galaxy.renderStore.relationCounts.isEmpty)
        XCTAssertTrue(galaxy.renderStore.topicGroups.isEmpty)
        XCTAssertEqual(registry.unifiedSimulation.nodeCount, 1)
        XCTAssertTrue(registry.unifiedSimulation.edgeIndicesPublic.isEmpty)
    }

    func testFinalizedEnvelopeMixedUpdatesReconcileBeforeDeferredInserts() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let nodes = makeNodes(4)
        let original = EdgeData(id: UUID(), sourceId: nodes[0].id, targetId: nodes[1].id, relation: "relates_to")
        let deleted = EdgeData(id: UUID(), sourceId: nodes[1].id, targetId: nodes[2].id, relation: "part_of")
        let updated = EdgeData(id: original.id, sourceId: nodes[0].id, targetId: nodes[2].id, relation: "derived_from")
        let inserted = EdgeData(id: UUID(), sourceId: nodes[2].id, targetId: nodes[3].id, relation: "relates_to")
        let changedNode = NodeData(id: nodes[2].id, project: nodes[2].project, topic: "different",
                                   label: "Changed", content: "Changed content", createdAt: nodes[2].createdAt,
                                   lastAccessedAt: nodes[2].lastAccessedAt, importance: 4)
        await galaxy.mutatePendingUpdateForTesting {
            $0.bulkEdges = ([original.id: original, deleted.id: deleted], [:],
                           [nodes[0].id: [original], nodes[1].id: [original, deleted], nodes[2].id: [deleted]])
            $0.bulkNodeBatches = nodes.prefix(3).enumerated().map { [(pk: Int64($0.offset + 1), node: $0.element)] }
            $0.updatedNodes = [(pk: 3, node: changedNode)]
            $0.updatedEdges = [updated]
            $0.removedEdgeGids = [deleted.id]
            $0.insertedNodes = [(pk: 4, node: nodes[3])]
            $0.insertedEdges = [(pk: 4, edge: inserted)]
            $0.finalize = true
        }
        for _ in 0..<3 { galaxy.drainPendingUpdate(config: config, workBudget: 0) }

        XCTAssertTrue(galaxy.isLoaded)
        XCTAssertEqual(galaxy.renderStore.nodes.count, 3)
        XCTAssertEqual(galaxy.renderStore.edges.map(\.id), [updated.id])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: galaxy.renderStore.relationCounts), ["derived_from": 1])
        XCTAssertEqual(galaxy.renderStore.topicGroups.first?.ids, Array(nodes.prefix(2)).map(\.id))
        XCTAssertEqual(galaxy.renderStore.nodeById[nodes[2].id]?.label, "Changed")
        XCTAssertFalse(galaxy.renderStore.hubs.contains(nodes[2].id))
        XCTAssertEqual(galaxy.renderStore.pendingNodeInserts.count, 1)
        XCTAssertEqual(galaxy.renderStore.pendingEdgeInserts.count, 1)
        XCTAssertNil(galaxy.renderStore.nodeById[nodes[3].id])

        // Finalization must not flush these queues early or break their normal
        // store/simulation consistency when the coalesced work later executes.
        galaxy.flushPendingNodeInserts(config: config)
        galaxy.flushPendingEdgeInserts(config: config)
        XCTAssertEqual(galaxy.renderStore.nodes.count, 4)
        XCTAssertEqual(galaxy.renderStore.edges.count, 2)
        XCTAssertEqual(registry.unifiedSimulation.nodeCount, 4)
        XCTAssertEqual(registry.unifiedSimulation.edgeIndicesPublic.count, 2)
    }

    func testHiddenRowMetadataEditDuringLoadDoesNotLeavePhantomLookupEntry() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let nodes = makeNodes(3)
        let hiddenNode = NodeData(id: nodes[0].id, project: "Hidden", topic: nodes[0].topic,
                                  label: nodes[0].label, content: nodes[0].content,
                                  createdAt: nodes[0].createdAt, lastAccessedAt: nodes[0].lastAccessedAt, importance: 1)
        let filtered = DrainConfig(hiddenProjects: ["Hidden"], hiddenRelations: [], timeFilter: nil,
                                   is3D: true, soundEnabled: false, notificationsEnabled: false)
        await galaxy.mutatePendingUpdateForTesting {
            $0.bulkNodeBatches = [[(pk: 1, node: hiddenNode)], [(pk: 2, node: nodes[1])], [(pk: 3, node: nodes[2])]]
            $0.finalize = true
        }
        galaxy.drainPendingUpdate(config: filtered, workBudget: 0)
        let changed = NodeData(id: hiddenNode.id, project: hiddenNode.project, topic: hiddenNode.topic,
                               label: "Updated hidden row", content: "New content", createdAt: hiddenNode.createdAt,
                               lastAccessedAt: hiddenNode.lastAccessedAt, importance: 5)
        galaxy.handleNodeUpdate(pk: 1, node: changed, config: filtered)
        galaxy.drainPendingUpdate(config: filtered, workBudget: 0)
        galaxy.drainPendingUpdate(config: filtered, workBudget: 0)

        XCTAssertTrue(galaxy.isLoaded)
        XCTAssertEqual(galaxy.renderStore.allNodes[hiddenNode.id]?.label, "Updated hidden row")
        XCTAssertNil(galaxy.renderStore.nodeById[hiddenNode.id])
        XCTAssertFalse(galaxy.renderStore.visibleNodeIds.contains(hiddenNode.id))
        XCTAssertEqual(galaxy.renderStore.nodeById.count, 2)
        XCTAssertEqual(registry.unifiedSimulation.nodeCount, 2)
    }

    func testColorOnlyChangeRefreshesGalaxyDominantColorWithoutPositionChanges() throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        registry.unifiedSimulation.isActive = false
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let node = makeNodes(1)[0]
        galaxy.insertNodeBatch([node], config: config)
        galaxy.renderStore.bumpTopology()
        let adapter = GalaxyRegistryAdapter(registry: registry)
        adapter.tick(dt: 1 / 60)
        let topologyBefore = adapter.topologyVersion
        let positionsBefore = adapter.positionVersion
        let storeTopologyBefore = galaxy.renderStore.topologyVersion

        galaxy.renderStore.colorMap[node.project] = .red
        adapter.tick(dt: 1 / 60)

        XCTAssertEqual(galaxy.renderStore.topologyVersion, storeTopologyBefore)
        XCTAssertEqual(adapter.positionVersion, positionsBefore)
        XCTAssertGreaterThan(adapter.topologyVersion, topologyBefore)
        let snapshot = try XCTUnwrap(adapter.galaxySnapshots.first)
        XCTAssertEqual(snapshot.dominantColor, try XCTUnwrap(adapter.projectColorMap[node.project]))
    }

    func testSameIDGalaxyReplacementRefreshesImmutableMetadataWithEqualStoreRevisions() throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        registry.unifiedSimulation.isActive = false
        let original = Galaxy(id: "personal", displayName: "Before", lattice: lattice.sendableReference)
        registry.register(original)
        let node = makeNodes(1)[0]
        original.insertNodeBatch([node], config: config)
        original.renderStore.bumpTopology()
        let adapter = GalaxyRegistryAdapter(registry: registry)
        adapter.tick(dt: 1 / 60)
        let topologyBefore = adapter.topologyVersion
        let positionsBefore = adapter.positionVersion

        let replacement = Galaxy(id: "personal", displayName: "After", lattice: lattice.sendableReference,
                                 hierarchyLevel: 0, parentGalaxyId: "group:parent")
        registry.register(replacement)
        replacement.insertNodeBatch([node], config: config)
        replacement.renderStore.bumpTopology()
        XCTAssertEqual(replacement.renderStore.topologyVersion, original.renderStore.topologyVersion)
        XCTAssertEqual(replacement.renderStore.colorMapVersion, original.renderStore.colorMapVersion)
        XCTAssertEqual(replacement.worldCenter, original.worldCenter)
        adapter.tick(dt: 1 / 60)

        XCTAssertEqual(adapter.positionVersion, positionsBefore)
        XCTAssertGreaterThan(adapter.topologyVersion, topologyBefore)
        let snapshot = try XCTUnwrap(adapter.galaxySnapshots.first)
        XCTAssertEqual(snapshot.displayName, "After")
        XCTAssertEqual(snapshot.worldCenter, replacement.worldCenter)
        XCTAssertEqual(snapshot.parentGalaxyId, "group:parent")
    }

    func testGalaxyCenterChangeRefreshesSnapshotWithoutPositionChanges() throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        registry.unifiedSimulation.isActive = false
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        galaxy.insertNodeBatch(makeNodes(1), config: config)
        galaxy.renderStore.bumpTopology()
        let adapter = GalaxyRegistryAdapter(registry: registry)
        adapter.tick(dt: 1 / 60)
        let positionsBefore = adapter.positionVersion

        galaxy.worldCenter = SIMD3<Float>(100, 200, 300)
        adapter.tick(dt: 1 / 60)

        XCTAssertEqual(adapter.positionVersion, positionsBefore)
        XCTAssertEqual(try XCTUnwrap(adapter.galaxySnapshots.first).worldCenter, galaxy.worldCenter)
    }

    func testInsertThenDeleteBeforeDeferredFlushDoesNotResurrect() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let node = makeNodes(1)[0]
        await galaxy.mutatePendingUpdateForTesting {
            $0.insertedNodes = [(pk: 99, node: node)]
            $0.removedNodePks = [99]
        }
        galaxy.drainPendingUpdate(config: config)
        XCTAssertTrue(galaxy.renderStore.pendingNodeInserts.isEmpty)
        // Exercise both the explicit flush and the already-scheduled flush task.
        galaxy.flushPendingNodeInserts(config: config)
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(galaxy.renderStore.nodes.isEmpty)
        XCTAssertTrue(galaxy.renderStore.allNodes.isEmpty)
        XCTAssertNil(galaxy.renderStore.pkToGlobalId[99])
        XCTAssertEqual(registry.unifiedSimulation.nodeCount, 0)
    }

    func testDeletionBurstCompactsSimulationOnlyOnce() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let nodes = makeNodes(100)
        galaxy.insertNodeBatch(nodes, config: config)
        for (index, node) in nodes.enumerated() { galaxy.renderStore.pkToGlobalId[Int64(index)] = node.id }
        let orderingBeforeDelete = registry.unifiedSimulation.nodeOrderVersion
        await galaxy.mutatePendingUpdateForTesting { $0.removedNodePks = Array(0..<50).map(Int64.init) }
        galaxy.drainPendingUpdate(config: config)
        XCTAssertEqual(galaxy.renderStore.nodes.count, 50)
        XCTAssertEqual(registry.unifiedSimulation.nodeCount, 50)
        XCTAssertEqual(registry.unifiedSimulation.nodeOrderVersion, orderingBeforeDelete + 1)
    }

    func testPartitionDeletionPreservesSharedUUIDUntilLastVisibleOwnerLeaves() throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let personal = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        let synced = Galaxy(id: "synced", displayName: "Synced", lattice: lattice.sendableReference)
        let group = Galaxy(id: "group:test", displayName: "Group", lattice: lattice.sendableReference)
        let node = makeNodes(1)[0]
        for galaxy in [personal, synced, group] {
            registry.register(galaxy)
            galaxy.insertNodeBatch([node], config: config)
            galaxy.renderStore.pkToGlobalId[1] = node.id
            galaxy.renderStore.bumpTopology()
        }
        registry.mergeRenderData()
        let position = registry.unifiedSimulation.positions[node.id]
        XCTAssertEqual(registry.unifiedSimulation.nodeCount, 1)
        personal.handleNodeDelete(1, config: config)
        synced.handleNodeDelete(1, config: config)
        registry.mergeRenderData()
        XCTAssertEqual(registry.mergedNodes.map(\.id), [node.id])
        XCTAssertEqual(registry.nodeToGalaxy[node.id], "group:test")
        XCTAssertEqual(registry.unifiedSimulation.nodeCount, 1)
        XCTAssertEqual(registry.unifiedSimulation.positions[node.id], position)
        XCTAssertEqual(registry.unifiedSimulation.galaxyGroupPublic.first,
                       registry.unifiedSimulation.galaxyIndex(for: "group:test"))
        group.handleNodeDelete(1, config: config)
        registry.mergeRenderData()
        XCTAssertTrue(registry.mergedNodes.isEmpty)
        XCTAssertEqual(registry.unifiedSimulation.nodeCount, 0)
    }

    func testGalaxyRemovalPreservesSharedNodesAndDetachesPendingSimulationWrites() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let personal = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        let synced = Galaxy(id: "synced", displayName: "Synced", lattice: lattice.sendableReference)
        registry.register(personal)
        registry.register(synced)
        let nodes = makeNodes(3)
        personal.insertNodeBatch([nodes[0]], config: config)
        synced.insertNodeBatch([nodes[0], nodes[1]], config: config)
        personal.renderStore.bumpTopology()
        synced.renderStore.bumpTopology()
        synced.handleNodeInsert(pk: 99, node: nodes[2], config: config)
        registry.remove("synced")
        await Task.yield()
        await Task.yield()
        let adapter = GalaxyRegistryAdapter(registry: registry)
        adapter.tick(dt: 1 / 60)
        XCTAssertEqual(adapter.nodes.map(\.id), [nodes[0].id])
        XCTAssertEqual(adapter.positionArray.count, 1)
        XCTAssertEqual(Set(adapter.positions.keys), [nodes[0].id])
        XCTAssertEqual(registry.unifiedSimulation.nodeCount, 1)
        XCTAssertNil(synced.simulation3D)
        registry.remove("personal")
        adapter.tick(dt: 1 / 60)
        XCTAssertTrue(adapter.nodes.isEmpty)
        XCTAssertTrue(adapter.positionArray.isEmpty)
        XCTAssertTrue(adapter.positions.isEmpty)
    }

    func testMigrationIntoExistingReplicaDoesNotDuplicateRenderOrSimulationNodes() throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let personal = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        let group = Galaxy(id: "group:test", displayName: "Group", lattice: lattice.sendableReference)
        let node = makeNodes(1)[0]
        for galaxy in [personal, group] {
            registry.register(galaxy)
            galaxy.insertNodeBatch([node], config: config)
            galaxy.renderStore.pkToGlobalId[1] = node.id
            galaxy.renderStore.bumpTopology()
        }
        registry.migrateProject(node.project, to: "group:test")
        personal.handleNodeDelete(1, config: config)
        registry.mergeRenderData()
        XCTAssertTrue(personal.renderStore.nodes.isEmpty)
        XCTAssertEqual(group.renderStore.nodes.count, 1)
        XCTAssertEqual(registry.mergedNodes.map(\.id), [node.id])
        XCTAssertEqual(registry.unifiedSimulation.nodeCount, 1)
    }

    func testDeferredInsertUsesLatestUpdateForTheSamePK() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        let node = makeNodes(1)[0]
        let updated = NodeData(id: node.id, project: "Changed", topic: "changed", label: "Latest",
                               content: "Latest content", createdAt: node.createdAt,
                               lastAccessedAt: node.lastAccessedAt, importance: 5)
        await galaxy.mutatePendingUpdateForTesting {
            $0.insertedNodes = [(pk: 1, node: node)]
            $0.updatedNodes = [(pk: 1, node: updated)]
        }
        galaxy.drainPendingUpdate(config: config)
        galaxy.flushPendingNodeInserts(config: config)
        XCTAssertEqual(galaxy.renderStore.nodes.count, 1)
        XCTAssertEqual(galaxy.renderStore.nodes.first?.label, "Latest")
        XCTAssertEqual(galaxy.renderStore.nodeById[node.id]?.project, "Changed")
    }

    func testDeferredEdgeEventsRespectDeletionAndLatestEndpoints() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let nodes = makeNodes(3)
        galaxy.insertNodeBatch(nodes, config: config)
        let deleted = EdgeData(id: UUID(), sourceId: nodes[0].id, targetId: nodes[1].id, relation: "related_to")
        await galaxy.mutatePendingUpdateForTesting {
            $0.insertedEdges = [(pk: 1, edge: deleted)]
            $0.removedEdgeGids = [deleted.id]
        }
        galaxy.drainPendingUpdate(config: config)
        galaxy.flushPendingEdgeInserts(config: config)
        XCTAssertTrue(galaxy.renderStore.pendingEdgeInserts.isEmpty)
        XCTAssertTrue(galaxy.renderStore.edges.isEmpty)
        XCTAssertTrue(registry.unifiedSimulation.edgeIndicesPublic.isEmpty)

        let original = EdgeData(id: UUID(), sourceId: nodes[0].id, targetId: nodes[1].id, relation: "part_of")
        let latest = EdgeData(id: original.id, sourceId: nodes[0].id, targetId: nodes[2].id, relation: "part_of")
        galaxy.handleEdgeInsert(original, config: config)
        galaxy.handleEdgeUpdate(latest, config: config)
        galaxy.flushPendingEdgeInserts(config: config)
        XCTAssertEqual(galaxy.renderStore.edges.count, 1)
        XCTAssertEqual(galaxy.renderStore.edges.first?.targetId, nodes[2].id)
        XCTAssertEqual(galaxy.renderStore.edgeCountByNode[nodes[1].id] ?? 0, 0)
        XCTAssertEqual(galaxy.renderStore.edgeCountByNode[nodes[2].id], 1)
        XCTAssertEqual(registry.unifiedSimulation.edgeIndicesPublic.count, 1)

        galaxy.handleEdgeUpdate(original, config: config)
        XCTAssertEqual(galaxy.renderStore.edgeCountByNode[nodes[0].id], 1)
        XCTAssertEqual(galaxy.renderStore.edgeCountByNode[nodes[1].id], 1)
        XCTAssertEqual(galaxy.renderStore.edgeCountByNode[nodes[2].id], 0)
        XCTAssertTrue(galaxy.renderStore.hubs.contains(nodes[1].id))
        XCTAssertFalse(galaxy.renderStore.hubs.contains(nodes[2].id))
    }

    func testInitialLoadSpansFramesWithoutLosingNodesEdgesOrQueuedDeletion() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let nodes = makeNodes(150)
        let edges = (1..<nodes.count).map { i in
            EdgeData(id: UUID(), sourceId: nodes[i - 1].id, targetId: nodes[i].id, relation: "related_to")
        }
        var byNode: [UUID: [EdgeData]] = [:]
        for edge in edges {
            byNode[edge.sourceId, default: []].append(edge)
            byNode[edge.targetId, default: []].append(edge)
        }
        let finalByNode = byNode
        await galaxy.mutatePendingUpdateForTesting {
            $0.bulkEdges = (Dictionary(uniqueKeysWithValues: edges.map { ($0.id, $0) }), [:], finalByNode)
            $0.bulkNodeBatches = stride(from: 0, to: nodes.count, by: 50).map { start in
                (start..<min(start + 50, nodes.count)).map { (pk: Int64($0 + 1), node: nodes[$0]) }
            }
            $0.finalize = true
        }
        galaxy.drainPendingUpdate(config: config, workBudget: 0)
        XCTAssertEqual(galaxy.renderStore.nodes.count, 50)
        XCTAssertEqual(registry.unifiedSimulation.nodeCount, 50)
        XCTAssertEqual(galaxy.renderStore.edges.count, 49)
        XCTAssertFalse(galaxy.isLoaded)
        // This deletion must wait behind the older snapshot row in batch 3.
        await galaxy.mutatePendingUpdateForTesting { $0.removedNodePks.append(150) }
        galaxy.drainPendingUpdate(config: config, workBudget: 0)
        XCTAssertEqual(galaxy.renderStore.nodes.count, 100)
        XCTAssertEqual(registry.unifiedSimulation.nodeCount, 100)
        XCTAssertFalse(galaxy.isLoaded)
        galaxy.drainPendingUpdate(config: config, workBudget: 0)
        XCTAssertTrue(galaxy.isLoaded)
        XCTAssertEqual(galaxy.renderStore.nodes.count, 150)
        XCTAssertEqual(galaxy.renderStore.edges.count, 149)
        XCTAssertEqual(registry.unifiedSimulation.edgeIndicesPublic.count, 149)
        galaxy.drainPendingUpdate(config: config, workBudget: 0)
        XCTAssertEqual(galaxy.renderStore.nodes.count, 149)
        XCTAssertEqual(registry.unifiedSimulation.nodeCount, 149)
        XCTAssertFalse(galaxy.renderStore.visibleNodeIds.contains(nodes[149].id))
    }

    func testInitialDrainReusesSingleGalaxyPublishedBufferAndMaintainsRouting() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let nodes = makeNodes(150)
        // Exclude capacity growth: this regression checks for an avoidable
        // complete copy caused solely by the registry's published alias.
        galaxy.renderStore.nodes.reserveCapacity(200)
        await galaxy.mutatePendingUpdateForTesting {
            $0.bulkNodeBatches = stride(from: 0, to: nodes.count, by: 50).map { start in
                (start..<start + 50).map { (pk: Int64($0 + 1), node: nodes[$0]) }
            }
            $0.finalize = true
        }
        galaxy.drainPendingUpdate(config: config, workBudget: 0)
        registry.mergeRenderData()
        let firstStorage = galaxy.renderStore.nodes.withUnsafeBufferPointer {
            UInt(bitPattern: $0.baseAddress!)
        }
        XCTAssertTrue(galaxy.isDrainingInitialSnapshot)

        galaxy.drainPendingUpdate(config: config, workBudget: 0)
        let nextStorage = galaxy.renderStore.nodes.withUnsafeBufferPointer {
            UInt(bitPattern: $0.baseAddress!)
        }
        XCTAssertEqual(nextStorage, firstStorage)
        XCTAssertEqual(registry.mergedNodes.count, 100)
        XCTAssertEqual(registry.mergedNodeById.count, 100)
        XCTAssertEqual(registry.unifiedSimulation.nodeCount, 100)
        registry.mergeRenderData()
        XCTAssertEqual(registry.nodeToGalaxy.count, 100)
        XCTAssertTrue(nodes.prefix(100).allSatisfy { registry.galaxyForNode($0.id) === galaxy })

        galaxy.drainPendingUpdate(config: config, workBudget: 0)
        registry.mergeRenderData()
        XCTAssertFalse(galaxy.isDrainingInitialSnapshot)
        XCTAssertTrue(galaxy.isLoaded)
        XCTAssertEqual(registry.mergedNodes.count, 150)
        XCTAssertEqual(registry.nodeToGalaxy.count, 150)
        XCTAssertTrue(nodes.allSatisfy { registry.galaxyForNode($0.id) === galaxy })
    }

    func testInitialDrainKeepsIndependentlyRetainedSnapshotUnchanged() async throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let nodes = makeNodes(150)
        await galaxy.mutatePendingUpdateForTesting {
            $0.bulkNodeBatches = stride(from: 0, to: nodes.count, by: 50).map { start in
                (start..<start + 50).map { (pk: Int64($0 + 1), node: nodes[$0]) }
            }
            $0.finalize = true
        }
        galaxy.drainPendingUpdate(config: config, workBudget: 0)
        registry.mergeRenderData()
        let independentSnapshot = registry.mergedNodes
        let independentLookup = registry.mergedNodeById

        galaxy.drainPendingUpdate(config: config, workBudget: 0)
        registry.mergeRenderData()

        XCTAssertEqual(independentSnapshot.map(\.id), Array(nodes.prefix(50)).map(\.id))
        XCTAssertEqual(independentLookup.count, 50)
        XCTAssertEqual(registry.mergedNodes.count, 100)
        XCTAssertEqual(registry.mergedNodeById.count, 100)
        XCTAssertEqual(registry.unifiedSimulation.nodeCount, 100)
    }

    func testMetadataRefreshAndSameCountReplacementRebuildMergedSnapshots() throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let nodes = makeNodes(2)
        galaxy.insertNodeBatch([nodes[0]], config: config)
        galaxy.renderStore.pkToGlobalId[1] = nodes[0].id
        galaxy.renderStore.bumpTopology()
        registry.mergeRenderData()
        let revision = registry.mergedTopologyVersion
        let changed = NodeData(id: nodes[0].id, project: "Changed project", topic: "Changed topic",
                               label: "Changed label", content: "Changed content", createdAt: nodes[0].createdAt,
                               lastAccessedAt: nodes[0].lastAccessedAt, importance: 5)
        galaxy.handleNodeUpdate(pk: 1, node: changed, config: config)
        registry.mergeRenderData()
        XCTAssertGreaterThan(registry.mergedTopologyVersion, revision)
        XCTAssertEqual(registry.mergedNodes.first?.label, "Changed label")
        galaxy.handleNodeDelete(1, config: config)
        galaxy.insertNodeBatch([nodes[1]], config: config)
        galaxy.renderStore.bumpTopology()
        registry.mergeRenderData()
        XCTAssertEqual(registry.nodeToGalaxy[nodes[1].id], "personal")
        XCTAssertNil(registry.nodeToGalaxy[nodes[0].id])
        registry.remove("personal")
        registry.mergeRenderData()
        XCTAssertTrue(registry.mergedNodes.isEmpty)
        XCTAssertTrue(registry.nodeToGalaxy.isEmpty)
        XCTAssertEqual(registry.unifiedSimulation.nodeCount, 0)
    }

    private func makeNodes(_ count: Int) -> [NodeData] {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return (0..<count).map {
            NodeData(id: UUID(), project: "Test", topic: "topic", label: "Node \($0)",
                     content: "", createdAt: date, lastAccessedAt: date, importance: 1)
        }
    }

    func testRepeatedRecallRestartsAnimationWithoutTopologyChange() throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let node = makeNodes(1)[0]
        galaxy.insertNodeBatch([node], config: config)
        galaxy.renderStore.bumpTopology()
        let adapter = GalaxyRegistryAdapter(registry: registry)
        galaxy.renderStore.glowingNodes[node.id] = Date().addingTimeInterval(-2)
        adapter.tick(dt: 1 / 60)
        XCTAssertGreaterThan(adapter.glowingNodes[node.id] ?? 0, 1.9)
        let revision = adapter.topologyVersion
        galaxy.renderStore.glowingNodes[node.id] = Date()
        adapter.tick(dt: 1 / 60)
        XCTAssertLessThan(adapter.glowingNodes[node.id] ?? 10, 0.5)
        XCTAssertEqual(adapter.topologyVersion, revision)
        galaxy.renderStore.glowingNodes.removeValue(forKey: node.id)
        adapter.tick(dt: 1 / 60)
        XCTAssertTrue(adapter.glowingNodes.isEmpty)
    }

    func testEdgeEditsInvalidateHubStyleAndKeepSimulationConsistent() throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let galaxy = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        registry.register(galaxy)
        let nodes = makeNodes(3)
        galaxy.insertNodeBatch(nodes, config: config)
        let edge = EdgeData(id: UUID(), sourceId: nodes[0].id, targetId: nodes[1].id, relation: "part_of")
        galaxy.handleEdgeUpdate(edge, config: config)
        registry.mergeRenderData()
        XCTAssertTrue(registry.mergedHubs.contains(nodes[1].id))
        XCTAssertEqual(registry.unifiedSimulation.edgeIndicesPublic.count, 1)
        let revision = registry.mergedTopologyVersion
        let moved = EdgeData(id: edge.id, sourceId: nodes[0].id, targetId: nodes[2].id, relation: "related_to")
        galaxy.handleEdgeUpdate(moved, config: config)
        registry.mergeRenderData()
        XCTAssertGreaterThan(registry.mergedTopologyVersion, revision)
        XCTAssertFalse(registry.mergedHubs.contains(nodes[1].id))
        XCTAssertEqual(registry.mergedEdges.first?.targetId, nodes[2].id)
        XCTAssertEqual(registry.unifiedSimulation.edgeIndicesPublic.count, 1)
        galaxy.handleEdgeDelete(edge.id)
        registry.mergeRenderData()
        XCTAssertTrue(registry.mergedEdges.isEmpty)
        XCTAssertTrue(registry.unifiedSimulation.edgeIndicesPublic.isEmpty)
    }

    func testDeletingOneReplicatedEdgeKeepsOtherGalaxySpring() throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let personal = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        let synced = Galaxy(id: "synced", displayName: "Synced", lattice: lattice.sendableReference)
        registry.register(personal)
        registry.register(synced)
        let nodes = makeNodes(2)
        let edge = EdgeData(id: UUID(), sourceId: nodes[0].id, targetId: nodes[1].id, relation: "relates_to")
        for galaxy in [personal, synced] {
            galaxy.insertNodeBatch(nodes, config: config)
            galaxy.handleEdgeUpdate(edge, config: config)
        }
        personal.handleEdgeDelete(edge.id)
        registry.mergeRenderData()
        XCTAssertEqual(registry.mergedEdges.map(\.id), [edge.id])
        XCTAssertEqual(registry.unifiedSimulation.edgeIndicesPublic.count, 1)
        synced.handleEdgeDelete(edge.id)
        registry.mergeRenderData()
        XCTAssertTrue(registry.mergedEdges.isEmpty)
        XCTAssertTrue(registry.unifiedSimulation.edgeIndicesPublic.isEmpty)
    }

    func testMovingEdgeKeepsOldSpringOwnedByAnotherGalaxyRelation() throws {
        let lattice = try Lattice(Memory.self, configuration: .init(storage: .memory()))
        let registry = GalaxyRegistry()
        let personal = Galaxy(id: "personal", displayName: "Personal", lattice: lattice.sendableReference)
        let synced = Galaxy(id: "synced", displayName: "Synced", lattice: lattice.sendableReference)
        registry.register(personal)
        registry.register(synced)
        let nodes = makeNodes(3)
        for galaxy in [personal, synced] { galaxy.insertNodeBatch(nodes, config: config) }
        let original = EdgeData(id: UUID(), sourceId: nodes[0].id, targetId: nodes[1].id, relation: "relates_to")
        let retained = EdgeData(id: UUID(), sourceId: nodes[0].id, targetId: nodes[1].id, relation: "part_of")
        personal.handleEdgeUpdate(original, config: config)
        synced.handleEdgeUpdate(retained, config: config)
        let moved = EdgeData(id: original.id, sourceId: nodes[0].id, targetId: nodes[2].id, relation: original.relation)
        personal.handleEdgeUpdate(moved, config: config)
        registry.mergeRenderData()
        XCTAssertEqual(registry.mergedEdges.count, 2)
        XCTAssertEqual(registry.unifiedSimulation.edgeIndicesPublic.count, 2)
        synced.handleEdgeDelete(retained.id)
        registry.mergeRenderData()
        XCTAssertEqual(registry.mergedEdges.map(\.id), [moved.id])
        XCTAssertEqual(registry.unifiedSimulation.edgeIndicesPublic.count, 1)
        personal.handleEdgeDelete(moved.id)
        XCTAssertTrue(registry.unifiedSimulation.edgeIndicesPublic.isEmpty)
    }
}
