import Testing
import Foundation
import simd
@testable import EngramRealityKit

@Suite("LODSystem Tests")
@MainActor
struct LODSystemTests {

    @Test("Compact priorities refresh on metadata revisions and preserve live overrides")
    func compactPrioritiesFollowMetadataAndOverrides() {
        let lod = LODSystem()
        lod.maxNodeInstances = 1
        let ids = [UUID(), UUID()]
        var nodes = [
            RKNodeSnapshot(id: ids[0], project: "p", topic: "t", label: "first", importance: 1, isHub: false),
            RKNodeSnapshot(id: ids[1], project: "p", topic: "t", label: "second", importance: 5, isHub: false),
        ]
        func visible(_ revision: UInt64, selected: UUID? = nil, glowing: [UUID: Float] = [:],
                     hubs: Set<UUID> = []) -> [Int] {
            let result = lod.computeVisibleSet(
                nodes: nodes, edges: [], positions: [:],
                positionArray: [.init(100, 0, 0), .init(100, 0, 0)],
                cameraPosition: .zero, selectedNode: selected, glowingNodes: glowing,
                hubs: hubs, topologyVersion: revision, positionVersion: 1)
            return result.nearNodes + result.midNodes + result.farNodes
        }
        #expect(visible(1) == [1])
        nodes[0] = RKNodeSnapshot(id: ids[0], project: "p", topic: "t", label: "edited", importance: 9, isHub: false)
        #expect(visible(2) == [0])
        #expect(visible(2, selected: ids[1]) == [1])
        #expect(visible(2, glowing: [ids[1]: 0]) == [1])
        #expect(visible(2) == [0])
        nodes[1] = RKNodeSnapshot(id: ids[1], project: "p", topic: "t", label: "hub", importance: 1, isHub: true)
        #expect(visible(2, hubs: [ids[1]]) == [1])
    }

    @Test("Partial budget selection matches stable full sorting across input shapes and limits")
    func partialSelectionMatchesFullSort() {
        for count in [0, 1, 2, 23, 24, 25, 127, 1024, 4097] {
            for shape in 0..<5 {
                let original: [LODBudgetSelection.Candidate] = (0..<count).map { index in
                    let distance: Float
                    switch shape {
                    case 0: distance = 100 // exact ties retain the original node order
                    case 1: distance = Float(index)
                    case 2: distance = Float(count - index)
                    case 3: distance = Float(min(index, count - index))
                    default: distance = Float((index * 719) % 197)
                    }
                    return (index, distance, shape == 4 ? (index * 13) % 7 : 1)
                }
                for limit in Set([0, 1, count / 8, count / 2, max(0, count - 1), count, count + 1]) {
                    var expected = original
                    if count > limit {
                        expected.sort {
                            $0.priority != $1.priority ? $0.priority > $1.priority : $0.distance < $1.distance
                        }
                    }
                    var actual = original
                    let indices = LODBudgetSelection.indices(from: &actual, limit: limit)
                    #expect(indices == expected.prefix(limit).map(\.index))
                }
            }
        }
    }

    @Test("A tiny far-tier budget retains selected, recalled and hub nodes in priority order")
    func tinyFarBudgetRetainsPriorityNodes() {
        let lod = LODSystem()
        lod.maxNodeInstances = 5
        let nodes = (0..<4096).map { index in
            RKNodeSnapshot(id: UUID(), project: "p", topic: "t", label: "n\(index)",
                           importance: 1, isHub: index == 4093)
        }
        var positions = [SIMD3<Float>](repeating: SIMD3(3000, 0, 0), count: nodes.count)
        positions[0] = SIMD3(10, 0, 0)
        positions[1] = SIMD3(1000, 0, 0)
        let edges = [
            RKEdgeSnapshot(id: UUID(), sourceId: nodes[0].id, targetId: nodes[4095].id, relation: "r"),
            RKEdgeSnapshot(id: UUID(), sourceId: nodes[0].id, targetId: nodes[2].id, relation: "r"),
        ]
        let result = lod.computeVisibleSet(
            nodes: nodes, edges: edges, positions: [:], positionArray: positions,
            cameraPosition: .zero, selectedNode: nodes[4095].id,
            glowingNodes: [nodes[4094].id: 0], hubs: [nodes[4093].id],
            topologyVersion: 1, positionVersion: 1)
        #expect(result.nearNodes == [0])
        #expect(result.midNodes == [1])
        #expect(result.farNodes == [4095, 4094, 4093])
        #expect(result.visibleLabelIndices == [0])
        #expect(result.visibleEdgeIndices == [0])
    }

    @Test("Optimized tier selection preserves full-sort nodes, labels and edges while inputs change")
    func tierSelectionMatchesReferenceAcrossChanges() {
        let lod = LODSystem()
        let uncappedLOD = LODSystem()
        var nodes = makeNodes(4096)
        let positions = nodes.indices.map { index in
            SIMD3<Float>(Float((index * 719) % 5100), Float(index % 23), 0)
        }
        let edges = (0..<nodes.count - 1).map { index in
            RKEdgeSnapshot(id: UUID(), sourceId: nodes[index].id, targetId: nodes[index + 1].id, relation: "r")
        }
        var topology: UInt64 = 1
        for frame in 0..<24 {
            if frame == 12 {
                // Same-ID metadata changes must affect overflow priorities and
                // mid labels without relying on node-count changes.
                let node = nodes[100]
                nodes[100] = RKNodeSnapshot(id: node.id, project: node.project, topic: node.topic,
                                           label: node.label, importance: 6, isHub: true)
                topology += 1
            }
            let camera = SIMD3<Float>(Float(frame % 6) * 300, 0, 0)
            let selected = frame % 3 == 0 ? nodes[4095].id : nil
            let glowing: [UUID: Float] = frame % 4 == 0 ? [nodes[4094].id: 0] : [:]
            let hubs = Set(nodes.filter(\.isHub).map(\.id))
            lod.maxNodeInstances = [1, 7, 700, 1500, 2500, 5000][frame % 6]
            lod.maxLabelInstances = 70
            lod.maxEdgeInstances = 53
            uncappedLOD.maxNodeInstances = nodes.count
            let all = uncappedLOD.computeVisibleSet(
                nodes: nodes, edges: edges, positions: [:], positionArray: positions,
                cameraPosition: camera, selectedNode: selected, glowingNodes: glowing, hubs: hubs,
                topologyVersion: topology, positionVersion: 1)
            let actual = lod.computeVisibleSet(
                nodes: nodes, edges: edges, positions: [:], positionArray: positions,
                cameraPosition: camera, selectedNode: selected, glowingNodes: glowing, hubs: hubs,
                topologyVersion: topology, positionVersion: 1)
            let referencePriorities = nodes.map { node -> Int in
                if node.id == selected { return 1000 }
                if glowing[node.id] != nil { return 500 }
                return node.isHub ? 100 : node.importance
            }
            var remaining = lod.maxNodeInstances
            func reference(_ tier: [Int]) -> [Int] {
                var ordered = tier
                if tier.count > remaining {
                    ordered.sort {
                        let lhs = referencePriorities[$0], rhs = referencePriorities[$1]
                        return lhs != rhs ? lhs > rhs
                            : simd_length_squared(positions[$0] - camera) < simd_length_squared(positions[$1] - camera)
                    }
                }
                let result = Array(ordered.prefix(remaining))
                remaining -= result.count
                return result
            }
            let near = reference(all.nearNodes)
            let mid = reference(all.midNodes)
            let far = reference(all.farNodes)
            let expectedLabels = Array((near + mid.filter { nodes[$0].isHub || nodes[$0].importance >= 3 }).prefix(70))
            let visible = Set(near + mid + far)
            let expectedEdges = Array(edges.indices.filter { visible.contains($0) && visible.contains($0 + 1) }.prefix(53))
            #expect(actual.nearNodes == near)
            #expect(actual.midNodes == mid)
            #expect(actual.farNodes == far)
            #expect(actual.visibleLabelIndices == expectedLabels)
            #expect(actual.visibleEdgeIndices == expectedEdges)
        }
    }

    @Test("Static graph converges to its distance-relative tiers before idle caching")
    func idleCacheWaitsForDistanceConvergence() {
        let lod = LODSystem()
        let nodes = makeNodes(3)
        func compute() -> VisibleSet {
            lod.computeVisibleSet(
                nodes: nodes, edges: [], positions: [:],
                positionArray: [SIMD3(1000, 0, 0), SIMD3(2000, 0, 0), SIMD3(10000, 0, 0)],
                cameraPosition: .zero, selectedNode: nil, glowingNodes: [:], hubs: [],
                topologyVersion: 1, positionVersion: 1)
        }
        let first = compute()
        #expect(first.nearNodes.isEmpty)
        #expect(first.totalNodeCount == 2)
        for _ in 0..<80 { _ = compute() }
        let settled = compute()
        // At convergence min=1000, max=10000: near<1900, mid<4150, far<10450.
        #expect(settled.nearNodes == [0])
        #expect(settled.midNodes == [1])
        #expect(settled.farNodes == [2])
        let cached = compute()
        #expect(cached.nearNodes == settled.nearNodes)
        #expect(cached.midNodes == settled.midNodes)
        #expect(cached.farNodes == settled.farNodes)
    }

    @Test("Stationary camera reclassifies moving nodes")
    func movingNodesInvalidateCache() {
        let lod = LODSystem()
        let nodes = makeNodes(2)
        let first = lod.computeVisibleSet(
            nodes: nodes, edges: [], positions: [:],
            positionArray: [SIMD3(10, 0, 0), SIMD3(3000, 0, 0)],
            cameraPosition: .zero, selectedNode: nil, glowingNodes: [:], hubs: [],
            topologyVersion: 1, positionVersion: 1)
        let second = lod.computeVisibleSet(
            nodes: nodes, edges: [], positions: [:],
            positionArray: [SIMD3(3000, 0, 0), SIMD3(10, 0, 0)],
            cameraPosition: .zero, selectedNode: nil, glowingNodes: [:], hubs: [],
            topologyVersion: 1, positionVersion: 2)
        #expect(first.nearNodes == [0])
        #expect(second.nearNodes == [1])
    }

    @Test("Recall glow displaces an unselected node at the visibility budget")
    func glowMembershipInvalidatesCache() {
        let lod = LODSystem()
        lod.maxNodeInstances = 1
        let nodes = makeNodes(2)
        let positions: [SIMD3<Float>] = [SIMD3(10, 0, 0), SIMD3(20, 0, 0)]
        let first = lod.computeVisibleSet(
            nodes: nodes, edges: [], positions: [:], positionArray: positions,
            cameraPosition: .zero, selectedNode: nil, glowingNodes: [:], hubs: [],
            topologyVersion: 1, positionVersion: 1)
        let recalled = lod.computeVisibleSet(
            nodes: nodes, edges: [], positions: [:], positionArray: positions,
            cameraPosition: .zero, selectedNode: nil, glowingNodes: [nodes[1].id: 0], hubs: [],
            topologyVersion: 1, positionVersion: 1)
        let expired = lod.computeVisibleSet(
            nodes: nodes, edges: [], positions: [:], positionArray: positions,
            cameraPosition: .zero, selectedNode: nil, glowingNodes: [:], hubs: [],
            topologyVersion: 1, positionVersion: 1)
        #expect(first.nearNodes == [0])
        #expect(recalled.nearNodes == [1])
        #expect(expired.nearNodes == [0])
    }

    private func makeNodes(_ count: Int, project: String = "test") -> [RKNodeSnapshot] {
        (0..<count).map { i in
            RKNodeSnapshot(
                id: UUID(),
                project: project,
                topic: "topic",
                label: "node_\(i)",
                importance: i % 5 + 1,
                isHub: i % 10 == 0
            )
        }
    }

    @Test("All near nodes when camera is at origin and nodes are close")
    func allNearNodes() {
        let lod = LODSystem()
        let nodes = makeNodes(10)
        var positions: [UUID: SIMD3<Float>] = [:]
        for (i, node) in nodes.enumerated() {
            positions[node.id] = SIMD3<Float>(Float(i * 10), 0, 0) // max 90 units away
        }

        let result = lod.computeVisibleSet(
            nodes: nodes, edges: [], positions: positions,
            cameraPosition: .zero, selectedNode: nil,
            glowingNodes: [:], hubs: []
        )

        #expect(result.nearNodes.count == 10)
        #expect(result.midNodes.isEmpty)
        #expect(result.farNodes.isEmpty)
        #expect(result.totalNodeCount == 10)
    }

    @Test("Mixed tiers based on distance")
    func mixedTiers() {
        let lod = LODSystem()
        let nodes = makeNodes(3)
        var positions: [UUID: SIMD3<Float>] = [:]
        positions[nodes[0].id] = SIMD3<Float>(100, 0, 0)    // near
        positions[nodes[1].id] = SIMD3<Float>(1000, 0, 0)   // mid
        positions[nodes[2].id] = SIMD3<Float>(3000, 0, 0)   // far

        let result = lod.computeVisibleSet(
            nodes: nodes, edges: [], positions: positions,
            cameraPosition: .zero, selectedNode: nil,
            glowingNodes: [:], hubs: []
        )

        #expect(result.nearNodes.count == 1)
        #expect(result.midNodes.count == 1)
        #expect(result.farNodes.count == 1)
    }

    @Test("Distant nodes stay visible — quantile tiers, no fixed cull")
    func distantNodesNotCulled() {
        // The V2 LOD rewrite replaced fixed distance cutoffs with quantile
        // tiers (min/max-distance EMA): a fixed 5000-unit cull blanked the
        // whole graph at 42k scale where everything sits far from the
        // camera. Density is governed by the render budget (see
        // renderBudgetCap), not absolute distance — a lone distant node
        // must therefore stay visible.
        let lod = LODSystem()
        let nodes = makeNodes(1)
        let positions: [UUID: SIMD3<Float>] = [nodes[0].id: SIMD3<Float>(6000, 0, 0)]

        let result = lod.computeVisibleSet(
            nodes: nodes, edges: [], positions: positions,
            cameraPosition: .zero, selectedNode: nil,
            glowingNodes: [:], hubs: []
        )

        #expect(result.totalNodeCount == 1)
    }

    @Test("Render budget caps node count")
    func renderBudgetCap() {
        let lod = LODSystem()
        lod.maxNodeInstances = 5

        let nodes = makeNodes(20)
        var positions: [UUID: SIMD3<Float>] = [:]
        for node in nodes {
            positions[node.id] = SIMD3<Float>(Float.random(in: 0...100), 0, 0)
        }

        let result = lod.computeVisibleSet(
            nodes: nodes, edges: [], positions: positions,
            cameraPosition: .zero, selectedNode: nil,
            glowingNodes: [:], hubs: []
        )

        #expect(result.totalNodeCount <= 5)
    }

    @Test("Selected node gets highest priority")
    func selectedNodePriority() {
        let lod = LODSystem()
        lod.maxNodeInstances = 1

        let nodes = makeNodes(3)
        var positions: [UUID: SIMD3<Float>] = [:]
        // Node 0 is closest, Node 2 is selected but farther
        positions[nodes[0].id] = SIMD3<Float>(10, 0, 0)
        positions[nodes[1].id] = SIMD3<Float>(50, 0, 0)
        positions[nodes[2].id] = SIMD3<Float>(200, 0, 0)

        let result = lod.computeVisibleSet(
            nodes: nodes, edges: [], positions: positions,
            cameraPosition: .zero, selectedNode: nodes[2].id,
            glowingNodes: [:], hubs: []
        )

        // Selected node should be in the visible set
        #expect(result.nearNodes.contains(2))
    }

    @Test("Edge filtering: both endpoints must be visible")
    func edgeFiltering() {
        let lod = LODSystem()
        let nodes = makeNodes(3)
        var positions: [UUID: SIMD3<Float>] = [:]
        positions[nodes[0].id] = SIMD3<Float>(10, 0, 0)   // near
        positions[nodes[1].id] = SIMD3<Float>(50, 0, 0)   // near
        positions[nodes[2].id] = SIMD3<Float>(6000, 0, 0) // culled

        let edges = [
            RKEdgeSnapshot(id: UUID(), sourceId: nodes[0].id, targetId: nodes[1].id, relation: "r"),
            RKEdgeSnapshot(id: UUID(), sourceId: nodes[0].id, targetId: nodes[2].id, relation: "r"),
        ]

        let result = lod.computeVisibleSet(
            nodes: nodes, edges: edges, positions: positions,
            cameraPosition: .zero, selectedNode: nil,
            glowingNodes: [:], hubs: []
        )

        #expect(result.visibleEdgeIndices.count == 1)
        #expect(result.visibleEdgeIndices.contains(0)) // edge between nodes 0 and 1
    }

    @Test("Label visibility: near nodes + important mid nodes")
    func labelVisibility() {
        let lod = LODSystem()
        var nodes: [RKNodeSnapshot] = []
        var positions: [UUID: SIMD3<Float>] = [:]

        // 3 near nodes
        for i in 0..<3 {
            let n = RKNodeSnapshot(id: UUID(), project: "p", topic: "t", label: "near_\(i)", importance: 1, isHub: false)
            nodes.append(n)
            positions[n.id] = SIMD3<Float>(Float(i * 10), 0, 0)
        }

        // 3 mid nodes — one hub, one important, one regular
        let hubNode = RKNodeSnapshot(id: UUID(), project: "p", topic: "t", label: "hub", importance: 1, isHub: true)
        nodes.append(hubNode)
        positions[hubNode.id] = SIMD3<Float>(800, 0, 0)

        let importantNode = RKNodeSnapshot(id: UUID(), project: "p", topic: "t", label: "important", importance: 4, isHub: false)
        nodes.append(importantNode)
        positions[importantNode.id] = SIMD3<Float>(900, 0, 0)

        let regularMid = RKNodeSnapshot(id: UUID(), project: "p", topic: "t", label: "regular", importance: 1, isHub: false)
        nodes.append(regularMid)
        positions[regularMid.id] = SIMD3<Float>(1000, 0, 0)

        let result = lod.computeVisibleSet(
            nodes: nodes, edges: [], positions: positions,
            cameraPosition: .zero, selectedNode: nil,
            glowingNodes: [:], hubs: [hubNode.id]
        )

        // 3 near nodes + hub mid + important mid = 5 labels (regular mid excluded)
        #expect(result.visibleLabelIndices.count == 5)
    }
}
