import Foundation
import simd
import XCTest
@testable import EngramRealityKit

/// Mirrors the native metadata-domain regressions in the selected app host.
@MainActor
final class SceneMetadataDomainTests: XCTestCase {
    private func endpointNode(id: UUID = UUID(), project: String = "project") -> RKNodeSnapshot {
        RKNodeSnapshot(id: id, project: project, topic: "topic", label: "label", importance: 1, isHub: false)
    }

    private func endpointEdge(_ source: RKNodeSnapshot, _ target: RKNodeSnapshot, id: UUID = UUID()) -> RKEdgeSnapshot {
        RKEdgeSnapshot(id: id, sourceId: source.id, targetId: target.id, relation: "related_to")
    }

    private func mascotNode(_ id: UUID = UUID(), project: String) -> RKNodeSnapshot {
        RKNodeSnapshot(id: id, project: project, topic: "topic", label: "Node", importance: 1, isHub: false)
    }

    private func makeNodes(_ count: Int, project: String = "test") -> [RKNodeSnapshot] {
        (0..<count).map { i in
            RKNodeSnapshot(id: UUID(), project: project, topic: "topic", label: "node_\(i)",
                           importance: i % 5 + 1, isHub: i % 10 == 0)
        }
    }

    func testRevisionDomainsPreserveLateEndpointsAndSkipUnchangedPrefixes() {
        let owner = NSObject()
        var cache = EdgeEndpointIndexCache()
        let a = endpointNode(), b = endpointNode(), c = endpointNode()
        let late = endpointEdge(a, c)
        cache.update(nodes: [a], edges: [late], provider: owner,
                     nodeVersion: 1, edgeVersion: 1, nodeAppendGeneration: 1)
        XCTAssertTrue(cache.targetIndices == [-1])
        cache.update(nodes: [a, b], edges: [late], provider: owner,
                     nodeVersion: 2, edgeVersion: 1, nodeAppendGeneration: 1)
        cache.update(nodes: [a, b, c], edges: [late], provider: owner,
                     nodeVersion: 4, edgeVersion: 1, nodeAppendGeneration: 1)
        XCTAssertTrue(cache.sourceIndices == [0])
        XCTAssertTrue(cache.targetIndices == [2])
        XCTAssertTrue(cache.nodePrefixComparisonCount == 0)
        XCTAssertTrue(cache.edgePrefixComparisonCount == 0)
        let edges = [late, endpointEdge(b, c)]
        cache.update(nodes: [a, b, c], edges: edges, provider: owner,
                     nodeVersion: 4, edgeVersion: 2, nodeAppendGeneration: 1)
        XCTAssertTrue(cache.sourceIndices == [0, 1])
        XCTAssertTrue(cache.targetIndices == [2, 2])
        XCTAssertTrue(cache.nodePrefixComparisonCount == 0)
        XCTAssertTrue(cache.edgePrefixComparisonCount == 1)
        for _ in 0..<100 {
            cache.update(nodes: [a, b, c], edges: edges, provider: owner,
                         nodeVersion: 4, edgeVersion: 2, nodeAppendGeneration: 1)
        }
        XCTAssertTrue(cache.edgePrefixComparisonCount == 1)
        XCTAssertTrue(cache.targetIndices == [2, 2])
    }

    func testRevisionFallbacksMatchConservativeEndpointResults() {
        let owner = NSObject(), replacement = NSObject()
        let a = endpointNode(), b = endpointNode(), c = endpointNode(), d = endpointNode()
        let ab = endpointEdge(a, b), bc = endpointEdge(b, c)
        let cases: [([RKNodeSnapshot], [RKEdgeSnapshot])] = [
            ([a, b], [ab]),
            ([c, b, a], [ab, bc]), // prefix edit during growth
            ([a, b, c], [endpointEdge(c, b, id: ab.id), bc]), // same-count reorder/endpoint edit
            ([b], [ab]), // shrink/deletion leaves a missing endpoint
            ([b, d], [endpointEdge(d, b, id: ab.id)]),
            ([], []),
        ]
        var actual = EdgeEndpointIndexCache(), reference = EdgeEndpointIndexCache()
        for (offset, pair) in cases.enumerated() {
            let revision = UInt64(offset + 1)
            reference.update(nodes: pair.0, edges: pair.1)
            actual.update(nodes: pair.0, edges: pair.1, provider: owner,
                          nodeVersion: revision, edgeVersion: revision, nodeAppendGeneration: revision)
            XCTAssertTrue(actual.sourceIndices == reference.sourceIndices)
            XCTAssertTrue(actual.targetIndices == reference.targetIndices)
        }
        actual.update(nodes: [a, b], edges: [ab], provider: owner,
                      nodeVersion: 10, edgeVersion: 10, nodeAppendGeneration: 10)
        actual.update(nodes: [b, a], edges: [ab], provider: replacement,
                      nodeVersion: 10, edgeVersion: 10, nodeAppendGeneration: 10)
        XCTAssertTrue(actual.sourceIndices == [1])
        XCTAssertTrue(actual.targetIndices == [0])
    }

    func testDuplicateAppendPreservesExistingEndpointPolicy() {
        let owner = NSObject()
        var actual = EdgeEndpointIndexCache(), reference = EdgeEndpointIndexCache()
        let a = endpointNode(), b = endpointNode(), duplicate = endpointNode(id: a.id, project: "copy")
        let first = endpointEdge(a, b), second = endpointEdge(b, duplicate)
        reference.update(nodes: [a, b], edges: [first])
        actual.update(nodes: [a, b], edges: [first], provider: owner,
                      nodeVersion: 1, edgeVersion: 1, nodeAppendGeneration: 1)
        reference.update(nodes: [a, b, duplicate], edges: [first, second])
        actual.update(nodes: [a, b, duplicate], edges: [first, second], provider: owner,
                      nodeVersion: 2, edgeVersion: 2, nodeAppendGeneration: 1)
        // Existing resolved edges retain their index; newly indexed endpoints
        // use the last duplicate, exactly as the conservative append path does.
        XCTAssertTrue(actual.sourceIndices == [0, 1])
        XCTAssertTrue(actual.targetIndices == [1, 2])
        XCTAssertTrue(actual.sourceIndices == reference.sourceIndices)
        XCTAssertTrue(actual.targetIndices == reference.targetIndices)
        reference.update(nodes: [a, duplicate, b], edges: [first, second])
        actual.update(nodes: [a, duplicate, b], edges: [first, second], provider: owner,
                      nodeVersion: 3, edgeVersion: 2, nodeAppendGeneration: 2)
        XCTAssertTrue(actual.sourceIndices == reference.sourceIndices)
        XCTAssertTrue(actual.targetIndices == reference.targetIndices)
        XCTAssertTrue(actual.sourceIndices == [1, 2])
        XCTAssertTrue(actual.targetIndices == [2, 1])
    }

    func testRoutingDomainsExtendOnlyCertifiedNodeSuffixes() {
        let owner = NSObject()
        let first = mascotNode(project: "A"), second = mascotNode(project: "B")
        let duplicate = mascotNode(first.id, project: "B"), fourth = mascotNode(project: "C")
        let index = MascotGraphIndex()
        index.update(nodes: [first], nodeVersion: 1, nodeAppendGeneration: 7, provider: owner)
        index.update(nodes: [first, second], nodeVersion: 2, nodeAppendGeneration: 7, provider: owner)
        index.update(nodes: [first, second, duplicate, fourth], nodeVersion: 4,
                     nodeAppendGeneration: 7, provider: owner)
        for _ in 0..<100 {
            index.update(nodes: [first, second, duplicate, fourth], nodeVersion: 4,
                         nodeAppendGeneration: 7, provider: owner)
        }
        XCTAssertTrue(index.nodesVisited == 4)
        XCTAssertTrue(index.projects == ["A", "B", "C"])
        XCTAssertTrue(index.indicesByProject["B"] == [1, 2])
        XCTAssertTrue(index.indexByID[first.id] == 0)
        XCTAssertTrue(index.indexByID[fourth.id] == 3)
    }

    func testRoutingDomainsRebuildForEditsRemovalAndReplacement() {
        let owner = NSObject(), replacement = NSObject()
        let a = mascotNode(project: "A"), b = mascotNode(project: "B"), c = mascotNode(project: "C")
        let index = MascotGraphIndex()
        index.update(nodes: [a, b], nodeVersion: 1, nodeAppendGeneration: 1, provider: owner)
        let edited = mascotNode(a.id, project: "changed")
        let cases = [[edited, b, c], [c, b, edited], [b], []]
        for (offset, nodes) in cases.enumerated() {
            let revision = UInt64(offset + 2)
            index.update(nodes: nodes, nodeVersion: revision,
                         nodeAppendGeneration: revision, provider: owner)
            XCTAssertTrue(index.projects == Set(nodes.map(\.project)))
            for project in index.projects {
                XCTAssertTrue(index.indicesByProject[project] == nodes.indices.filter { nodes[$0].project == project })
            }
            XCTAssertTrue(index.indexByID.count == nodes.count)
            for (i, node) in nodes.enumerated() { XCTAssertTrue(index.indexByID[node.id] == i) }
        }
        index.update(nodes: [a, b], nodeVersion: 10, nodeAppendGeneration: 10, provider: owner)
        index.update(nodes: [c, edited], nodeVersion: 10, nodeAppendGeneration: 10, provider: replacement)
        XCTAssertTrue(index.projects == ["C", "changed"])
        XCTAssertTrue(index.indexByID[b.id] == nil)
        XCTAssertTrue(index.indexByID[a.id] == 1)
    }

    func testMetadataDomainsMatchConservativeVisibilityAcrossMutations() {
        let optimized = LODSystem(), reference = LODSystem()
        var owner = NSObject()
        var nodes = makeNodes(3)
        var positions: [SIMD3<Float>] = [.init(10, 0, 0), .init(1000, 0, 0), .init(3000, 0, 0)]
        var edges: [RKEdgeSnapshot] = []
        var topology: UInt64 = 1, nodeRevision: UInt64 = 1, edgeRevision: UInt64 = 1
        var hubRevision: UInt64 = 1, generation: UInt64 = 1
        func compare() {
            let hubs = Set(nodes.filter(\.isHub).map(\.id))
            let actual = optimized.computeVisibleSet(
                nodes: nodes, edges: edges, positions: [:], positionArray: positions,
                cameraPosition: .zero, selectedNode: nil, glowingNodes: [:], hubs: hubs,
                topologyVersion: topology, positionVersion: topology, provider: owner,
                nodeVersion: nodeRevision, hubVersion: hubRevision, edgeVersion: edgeRevision,
                nodeAppendGeneration: generation)
            let expected = reference.computeVisibleSet(
                nodes: nodes, edges: edges, positions: [:], positionArray: positions,
                cameraPosition: .zero, selectedNode: nil, glowingNodes: [:], hubs: hubs,
                topologyVersion: topology, positionVersion: topology)
            XCTAssertTrue(actual.nearNodes == expected.nearNodes)
            XCTAssertTrue(actual.midNodes == expected.midNodes)
            XCTAssertTrue(actual.farNodes == expected.farNodes)
            XCTAssertTrue(actual.visibleEdgeIndices == expected.visibleEdgeIndices)
            XCTAssertTrue(actual.visibleLabelIndices == expected.visibleLabelIndices)
        }
        compare()
        for _ in 0..<10 {
            edges.append(RKEdgeSnapshot(id: UUID(), sourceId: nodes[0].id, targetId: nodes[2].id, relation: "r"))
            edgeRevision += 1
            topology += 1
            compare()
        }
        XCTAssertTrue(optimized.priorityBuildCount == 3)
        XCTAssertTrue(optimized.endpointNodeComparisonCount == 0)
        // Two node chunks arrive before the next consumer frame.
        nodes += makeNodes(2)
        positions += [.init(2000, 0, 0), .init(500, 0, 0)]
        nodeRevision += 2
        topology += 1
        // These new fixtures include a hub, so publish that independent domain.
        hubRevision += 1
        compare()
        let countAfterHubChange = optimized.priorityBuildCount
        let suffix = RKNodeSnapshot(id: UUID(), project: "new", topic: "t", label: "new", importance: 4, isHub: false)
        nodes.append(suffix)
        positions.append(.init(750, 0, 0))
        nodeRevision += 1
        topology += 1
        compare()
        XCTAssertTrue(optimized.priorityBuildCount == countAfterHubChange + 1)
        // Reorder and edit an existing prefix while the total count grows.
        nodes.swapAt(0, 1)
        positions.swapAt(0, 1)
        let edited = nodes[0]
        nodes[0] = RKNodeSnapshot(id: edited.id, project: "changed", topic: "t", label: "changed",
                                  importance: 9, isHub: edited.isHub)
        nodes.append(suffix)
        positions.append(.init(200, 0, 0))
        nodeRevision += 1
        generation += 1
        topology += 1
        compare()
        nodes.removeFirst(2)
        positions.removeFirst(2)
        nodeRevision += 1
        generation += 1
        hubRevision += 1
        topology += 1
        compare()
        edges.reverse()
        if let first = edges.first {
            edges[0] = RKEdgeSnapshot(id: first.id, sourceId: nodes[0].id, targetId: nodes[1].id, relation: "edited")
        }
        edgeRevision += 1
        topology += 1
        compare()
        // Identical revision numbers from a different provider are not authority
        // to reuse metadata from the previous provider instance.
        owner = NSObject()
        nodes.reverse()
        positions.reverse()
        topology += 1
        compare()
    }

    func testMetadataReusePreservesMotionAndLivePriorityOverrides() {
        let lod = LODSystem(), owner = NSObject()
        lod.maxNodeInstances = 1
        var nodes = (0..<2).map { _ in
            RKNodeSnapshot(id: UUID(), project: "p", topic: "t", label: "n", importance: 1, isHub: false)
        }
        var positions: [SIMD3<Float>] = [.init(100, 0, 0), .init(100, 0, 0)]
        var topology: UInt64 = 1, positionRevision: UInt64 = 1, hubRevision: UInt64 = 1
        func visible(selected: UUID? = nil, glowing: [UUID: Float] = [:]) -> [Int] {
            let result = lod.computeVisibleSet(
                nodes: nodes, edges: [], positions: [:], positionArray: positions,
                cameraPosition: .zero, selectedNode: selected, glowingNodes: glowing,
                hubs: Set(nodes.filter(\.isHub).map(\.id)), topologyVersion: topology,
                positionVersion: positionRevision, provider: owner, nodeVersion: 1,
                hubVersion: hubRevision, edgeVersion: 1, nodeAppendGeneration: 1)
            return result.nearNodes + result.midNodes + result.farNodes
        }
        XCTAssertTrue(visible() == [0])
        for _ in 0..<100 {
            topology += 1 // color/status-only publications
            XCTAssertTrue(visible() == [0])
        }
        XCTAssertTrue(lod.priorityBuildCount == 2)
        XCTAssertTrue(lod.endpointNodeComparisonCount == 0)
        XCTAssertTrue(visible(selected: nodes[1].id) == [1])
        XCTAssertTrue(visible(glowing: [nodes[1].id: 0]) == [1])
        XCTAssertTrue(visible() == [0])
        let hub = nodes[1]
        nodes[1] = RKNodeSnapshot(id: hub.id, project: hub.project, topic: hub.topic,
                                  label: hub.label, importance: 1, isHub: true)
        hubRevision += 1
        XCTAssertTrue(visible() == [1])
        XCTAssertTrue(lod.priorityBuildCount == 4)
        positions = [.init(10, 0, 0), .init(3000, 0, 0)]
        positionRevision += 1
        XCTAssertTrue(visible() == [0])
        positions.swapAt(0, 1)
        positionRevision += 1
        XCTAssertTrue(visible() == [1])
        XCTAssertTrue(lod.priorityBuildCount == 4)
    }
}
