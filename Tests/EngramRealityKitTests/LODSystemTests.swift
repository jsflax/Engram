import Testing
import Foundation
import simd
@testable import EngramRealityKit

@Suite("LODSystem Tests")
@MainActor
struct LODSystemTests {

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

@Suite("LOD invalidation and settled work") @MainActor
struct LODInvalidationTests {
    private func nodes(_ count: Int) -> [RKNodeSnapshot] {
        (0..<count).map { RKNodeSnapshot(id: UUID(), project: "p", topic: "t", label: "n\($0)", importance: 1, isHub: false) }
    }
    private func visible(_ value: VisibleSet) -> Set<Int> {
        Set(value.nearNodes + value.midNodes + value.farNodes)
    }

    @Test(arguments: [true, false])
    func movedPositionsInvalidateWithOrWithoutRevision(hasRevision: Bool) {
        let lod = LODSystem(), rows = nodes(3)
        func compute(_ x: [Float], _ revision: UInt64) -> VisibleSet {
            lod.computeVisibleSet(nodes: rows, edges: [], positions: [:],
                positionArray: x.map { SIMD3<Float>($0, 0, 0) }, cameraPosition: .zero,
                selectedNode: nil, glowingNodes: [:], hubs: [], topologyVersion: 1,
                positionRevision: hasRevision ? revision : nil)
        }
        for _ in 0..<256 { _ = compute([10, 20, 30], 1) }
        #expect(visible(compute([10, 20, 30], 1)).contains(0))
        let before = lod.visibilityComputationCount
        // Same camera, same topology, changed published force coordinates.
        #expect(!visible(compute([3000, 20, 30], 2)).contains(0))
        #expect(lod.visibilityComputationCount == before + 1)
        #expect(visible(compute([10, 20, 30], 3)).contains(0))
        if !hasRevision {
            let before = lod.visibilityComputationCount
            for _ in 0..<20 { _ = compute([10, 20, 30], 3) }
            #expect(lod.visibilityComputationCount == before + 20)
        }
    }

    @Test func emaConvergesAfterRestorationWithoutCameraInputThenStopsWork() {
        let lod = LODSystem(), rows = nodes(2)
        let edge = RKEdgeSnapshot(id: UUID(), sourceId: rows[0].id, targetId: rows[1].id, relation: "r")
        func compute(_ restored: Bool) -> VisibleSet {
            lod.computeVisibleSet(nodes: rows, edges: restored ? [edge] : [], positions: [:],
                positionArray: [SIMD3<Float>(10, 0, 0), SIMD3<Float>(restored ? 10_000 : 20, 0, 0)],
                cameraPosition: .zero, selectedNode: nil, glowingNodes: [:], hubs: [],
                topologyVersion: restored ? 2 : 1, positionRevision: restored ? 2 : 1)
        }
        for _ in 0..<256 { _ = compute(false) }
        let first = compute(true)
        #expect(first.totalNodeCount == 1 && first.visibleEdgeIndices.isEmpty)
        // A single publication is sufficient: EMA must continue without a new
        // position revision, Center action, selection, or camera movement.
        for _ in 0..<256 { _ = compute(true) }
        let settled = compute(true), before = lod.visibilityComputationCount
        #expect(settled.totalNodeCount == 2 && settled.visibleEdgeIndices == [0])
        for _ in 0..<1_000 { _ = compute(true) }
        #expect(lod.visibilityComputationCount == before)
    }

    @Test func glowMembershipAndSelectionChangeBudgetWinnersButGlowAgeDoesNot() {
        let lod = LODSystem(), rows = nodes(3)
        lod.maxNodeInstances = 1
        func compute(_ glow: [UUID: Float], selected: UUID? = nil) -> VisibleSet {
            lod.computeVisibleSet(nodes: rows, edges: [], positions: [:],
                positionArray: Array(repeating: SIMD3<Float>(100, 0, 0), count: 3),
                cameraPosition: .zero, selectedNode: selected, glowingNodes: glow, hubs: [],
                topologyVersion: 1, positionRevision: 1)
        }
        for _ in 0..<256 { _ = compute([rows[0].id: 0]) }
        #expect(visible(compute([rows[0].id: 0])) == [0])
        #expect(visible(compute([rows[2].id: 0])) == [2])
        let before = lod.visibilityComputationCount
        #expect(visible(compute([rows[2].id: 20])) == [2])
        #expect(lod.visibilityComputationCount == before)
        #expect(visible(compute([rows[2].id: 20], selected: rows[1].id)) == [1])
        #expect(visible(compute([rows[0].id: 0])) == [0])
    }

    @Test func liveBudgetChangesRecomputeNodesEdgesAndLabels() {
        let lod = LODSystem(), rows = nodes(2)
        let edge = RKEdgeSnapshot(id: UUID(), sourceId: rows[0].id, targetId: rows[1].id, relation: "r")
        func compute() -> VisibleSet {
            lod.computeVisibleSet(nodes: rows, edges: [edge], positions: [:],
                positionArray: Array(repeating: SIMD3<Float>(100, 0, 0), count: 2),
                cameraPosition: .zero, selectedNode: nil, glowingNodes: [:], hubs: [],
                topologyVersion: 1, positionRevision: 1)
        }
        for _ in 0..<256 { _ = compute() }
        #expect(compute().totalNodeCount == 2)
        #expect(compute().visibleLabelIndices.count == 2)
        #expect(compute().visibleEdgeIndices == [0])
        lod.maxNodeInstances = 1
        #expect(compute().totalNodeCount == 1 && compute().visibleEdgeIndices.isEmpty)
        lod.maxNodeInstances = 2; lod.maxEdgeInstances = 0; lod.maxLabelInstances = 0
        let limited = compute()
        #expect(limited.totalNodeCount == 2 && limited.visibleEdgeIndices.isEmpty && limited.visibleLabelIndices.isEmpty)
        lod.maxEdgeInstances = 1; lod.maxLabelInstances = 2
        #expect(compute().visibleEdgeIndices == [0] && compute().visibleLabelIndices.count == 2)
    }

    @Test func smallCameraMovementAndMetadataPublicationInvalidate() {
        let lod = LODSystem(), original = nodes(2)
        lod.maxNodeInstances = 1
        var rows = original
        func compute(camera: SIMD3<Float> = .zero, topology: UInt64 = 1) -> VisibleSet {
            lod.computeVisibleSet(nodes: rows, edges: [], positions: [:],
                positionArray: Array(repeating: SIMD3<Float>(100, 0, 0), count: 2),
                cameraPosition: camera, selectedNode: nil, glowingNodes: [:], hubs: [],
                topologyVersion: topology, positionRevision: 1)
        }
        for _ in 0..<256 { _ = compute() }
        let before = lod.visibilityComputationCount
        _ = compute(camera: SIMD3(0.01, 0, 0))
        #expect(lod.visibilityComputationCount == before + 1)
        rows[1] = RKNodeSnapshot(id: original[1].id, project: "p", topic: "t", label: "changed", importance: 99, isHub: true)
        #expect(visible(compute(topology: 2)) == [1])
    }
}
