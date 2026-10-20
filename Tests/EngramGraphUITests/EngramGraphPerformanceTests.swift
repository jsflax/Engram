import Foundation
import Testing
import simd
import EngramSceneKit
@testable import EngramGraphUI

@Suite @MainActor
struct EngramGraphPerformanceTests {
    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llx", Int64(value + 1)))!
    }
    private func graph(count: Int, edgeCount: Int = 0, hubCount: Int = 0) -> EngramGraphSnapshot {
        let rows = (0..<count).map { index in
            EngramGraphMemory(id: id(index), content: "Synthetic memory \(index)", project: "project-\(index % 48)",
                topic: "topic-\(index % 7)", importance: 2, createdAt: Date(timeIntervalSince1970: 10),
                lastAccessedAt: Date(timeIntervalSince1970: 20))
        }
        var edges: [EngramGraphEdge] = []
        for index in 0..<edgeCount {
            let inHub = index < hubCount * 64
            let source = inHub ? hubCount + index : index % count
            let target = inHub ? index / 64 : (index * 13 + 17) % count
            edges.append(EngramGraphEdge(id: id(count + index), sourceID: id(source), targetID: id(target),
                relation: inHub ? "part_of" : "relates_to"))
        }
        return EngramGraphSnapshot(scopeID: "synthetic-performance", graphID: id(900_000), ownerID: id(900_001),
            revisionID: "1", title: "Synthetic graph", memories: rows, edges: edges,
            coverage: EngramGraphCoverage(totalMemoryCount: count, totalEdgeCount: edgeCount))
    }
    private func adapter(_ snapshot: EngramGraphSnapshot) -> EngramGraphDataAdapter {
        let result = EngramGraphDataAdapter()
        result.replace(snapshot: snapshot, hiddenProjects: [], hiddenRelations: [])
        let positions = Dictionary(uniqueKeysWithValues: snapshot.memories.enumerated().map { index, row in
            (row.id, SIMD3<Float>(Float(index % 100), Float((index / 100) % 100), Float(index % 17)))
        })
        result.simulation.setPositions(positions)
        result.isActive = true
        result.tick(dt: 0)
        return result
    }
    private func storageAddress(_ adapter: EngramGraphDataAdapter) -> UInt {
        adapter.positionArray.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
    }
    private func settle(_ adapter: EngramGraphDataAdapter) {
        for _ in 0..<1_100 {
            if adapter.simulation.isSettled { break }
            adapter.tick(dt: 1 / 60)
        }
        #expect(adapter.simulation.isSettled)
        // Flush the last changed centroid if the simulation never moved in this fixture.
        for _ in 0..<30 { adapter.tick(dt: 1 / 60) }
    }
    private func ms(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
    private func percentile(_ samples: [Double], _ p: Double) -> Double {
        let sorted = samples.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    @Test func scale42000Nodes200000EdgesPreservesBuffersAndStopsSettledWork() throws {
        let setup = DispatchTime.now().uptimeNanoseconds
        let a = adapter(graph(count: 42_000, edgeCount: 200_000, hubCount: 24))
        let setupMS = ms(setup)
        #expect(a.nodes.count == 42_000 && a.edges.count == 200_000)
        #expect(a.hubExpansion.indexedWork.topologyEdges == 200_000)
        #expect(a.hubExpansion.indexedWork.orbitOffsets == 24 * 64)
        let address = storageAddress(a), resizes = a.work.flatBufferResizes
        var frames: [Double] = []
        var deliveries = 0
        for frame in 0..<60 {
            let delivered = a.simulation.nodeIds.enumerated().map { index, _ in
                SIMD3<Float>(Float(index % 100) + Float(frame), Float(index % 17), Float(frame))
            }
            // This is the real CPU completion API used by the GPU engine. The
            // fixture supplies no Metal commands and does not claim GPU timing.
            a.simulation.applyGPUForces(ForceResult(positions: delivered)); deliveries += 1
            let start = DispatchTime.now().uptimeNanoseconds
            a.tick(dt: 1 / 60)
            frames.append(ms(start))
            #expect(storageAddress(a) == address)
        }
        #expect(deliveries == 60)
        #expect(a.work.flatBufferResizes == resizes)
        #expect(a.work.dictionaryBuilds == 0)
        let map = a.positions
        let second = a.positions
        #expect(map.count == 42_000 && second == map)
        #expect(a.work.dictionaryBuilds == 1)
        settle(a)
        let before = a.work, hubBefore = a.hubExpansion.indexedWork
        let idleStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<600 { a.tick(dt: 1 / 60) }
        let idleMS = ms(idleStart)
        #expect(a.work.positionRefreshes == before.positionRefreshes)
        #expect(a.work.forceRows == before.forceRows)
        #expect(a.work.aggregatePasses == before.aggregatePasses)
        #expect(a.work.dictionaryBuilds == before.dictionaryBuilds)
        #expect(a.hubExpansion.indexedWork == hubBefore)
        a.isActive = false
        let paused = a.work
        for _ in 0..<600 { a.tick(dt: 1 / 60) }
        #expect(a.work == paused)
        let report: [String: Any] = ["nodes": 42_000, "edges": 200_000, "forceCallbacks": deliveries,
            "setupMS": setupMS, "activeAdapterP50MS": percentile(frames, 0.5), "activeAdapterP95MS": percentile(frames, 0.95),
            "settled600TicksMS": idleMS, "flatBufferResizes": resizes, "steadyBufferAddressChanges": 0,
            "dictionaryBuildsBeforeExplicitRead": 0, "settledPositionRefreshes": 0, "settledAggregatePasses": 0,
            "scope": "CPU adapter only; fake force deliveries; no device performance claim"]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("ENGRAM_GRAPH_PERF " + String(decoding: data, as: UTF8.self))
    }

    @Test func expandedHubsVisitOnlyCachedChildrenAndStopAfterAnimation() {
        let a = adapter(graph(count: 42_000, edgeCount: 200_000, hubCount: 24))
        settle(a)
        let originals = a.positions
        for index in 0..<24 { a.toggleHub(id(index)) }
        let work = a.hubExpansion.indexedWork
        for _ in 0..<21 { a.tick(dt: 1 / 60) }
        #expect(a.expandedHubs.count == 24)
        #expect(!a.hubExpansion.isIndexedAnimating)
        #expect(a.hubExpansion.indexedWork.topologyEdges == work.topologyEdges)
        #expect(a.hubExpansion.indexedWork.orbitOffsets == work.orbitOffsets)
        #expect(a.hubExpansion.indexedWork.childVisits - work.childVisits <= 21 * 24 * 64)
        let steady = a.hubExpansion.indexedWork
        let aggregates = a.work.aggregatePasses
        for _ in 0..<600 { a.tick(dt: 1 / 60) }
        #expect(a.hubExpansion.indexedWork == steady)
        #expect(a.work.aggregatePasses == aggregates)
        let expanded = a.positions
        for index in 0..<24 {
            for child in a.hubExpansion.indexedChildren(of: id(index)) {
                #expect(abs(simd_length(expanded[child]! - expanded[id(index)]!) - 80) < 0.001)
            }
            a.toggleHub(id(index))
        }
        for _ in 0..<21 { a.tick(dt: 1 / 60) }
        #expect(a.expandedHubs.isEmpty)
        #expect(a.positions == originals)
    }

    @Test func indexedHubAnimationMatchesLegacyOrbitIncludingMovingCenterAndCollapse() {
        let hub = id(0), children = (1...7).map { id($0) }
        let edges = children.map { (sourceId: $0, targetId: hub, relation: "part_of") }
        let ids = [hub] + children
        let indices = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        var flat = ids.indices.map { SIMD3<Float>(Float($0), 2, 3) }
        var old = Dictionary(uniqueKeysWithValues: zip(ids, flat))
        let legacy = EngramGraphHubExpansionController(), indexed = EngramGraphHubExpansionController()
        indexed.installTopology(edges: edges, nodeIndices: indices)
        legacy.toggleHubExpansion(hubId: hub, positions: old, edges: edges)
        indexed.toggleIndexed(hub: hub, positions: flat)
        var collapsed: Set<UUID> = []
        for frame in 0..<45 {
            if frame == 23 {
                legacy.toggleHubExpansion(hubId: hub, positions: old, edges: edges)
                indexed.toggleIndexed(hub: hub, positions: flat)
            }
            if frame == 8 { old[hub] = SIMD3(10, 20, 30); flat[0] = SIMD3(10, 20, 30) }
            legacy.updateExpansions(dt: 1 / 60, positions: &old, edges: edges)
            indexed.updateIndexed(dt: 1 / 60, positions: &flat, baseChanged: false) { id, _ in collapsed.insert(id) }
            for index in ids.indices { #expect(simd_distance(old[ids[index]]!, flat[index]) < 0.0001) }
        }
        #expect(collapsed == Set(children))
        #expect(indexed.expandedHubs.isEmpty)
    }

    @Test func semanticSmoothingConvergesWithoutFullGraphCopiesAndLeavesOtherNodesUntouched() {
        let a = adapter(graph(count: 42_000, edgeCount: 200_000))
        settle(a)
        let initial = a.positions
        let targets = Dictionary(uniqueKeysWithValues: (0..<1_200).map { index in (id(index), initial[id(index)]! + SIMD3<Float>(12, -6, 18)) })
        a.semanticPositions = targets
        let forceRows = a.work.forceRows
        let start = initial[id(1)]!
        a.tick(dt: 0.02)
        #expect(simd_distance(a.positions[id(1)]!, start + SIMD3(12, -6, 18) * 0.1) < 0.0001)
        for _ in 0..<400 { a.tick(dt: 1 / 60) }
        let final = a.positions
        for (id, target) in targets { #expect(final[id] == target) }
        #expect(final[id(41_999)] == initial[id(41_999)])
        #expect(a.work.forceRows - forceRows == 42_000)
        let settled = a.work
        for _ in 0..<600 { a.tick(dt: 1 / 60) }
        #expect(a.work.semanticRows == settled.semanticRows)
        #expect(a.work.forceRows == settled.forceRows)
        #expect(a.work.aggregatePasses == settled.aggregatePasses)
        a.semanticPositions = nil
        a.tick(dt: 0)
        #expect(a.positions == initial)
    }

    @Test func lateForceResultAfterSettleRefreshesExactPositionsAndCentroids() {
        let a = adapter(graph(count: 64))
        settle(a)
        let before = a.work
        let delivered = Array(repeating: SIMD3<Float>(50, 60, 70), count: a.nodes.count)
        a.simulation.applyGPUForces(ForceResult(positions: delivered))
        #expect(a.simulation.isSettled)
        a.tick(dt: 1 / 60)
        #expect(a.positionArray == delivered)
        #expect(a.work.positionRefreshes == before.positionRefreshes + 1)
        #expect(a.work.aggregatePasses == before.aggregatePasses + 1)
        #expect(a.projectCentroids.values.allSatisfy { $0 == SIMD3(50, 60, 70) })
    }

    @Test func sameSizeTopologyReplacementInvalidatesUUIDMapEvenAtIdenticalPositions() {
        let a = adapter(graph(count: 2))
        a.simulation.setPositions([id(0): .zero, id(1): .zero]); a.tick(dt: 0)
        #expect(Set(a.positions.keys) == [id(0), id(1)])
        let row = EngramGraphMemory(id: id(20), content: "replacement", project: "p", topic: "t", importance: 1,
            createdAt: .distantPast, lastAccessedAt: .distantPast)
        let original = graph(count: 2)
        let replacement = EngramGraphSnapshot(scopeID: original.scopeID, graphID: original.graphID, ownerID: original.ownerID,
            revisionID: "2", title: original.title, memories: [original.memories[0], row], edges: [],
            coverage: EngramGraphCoverage(totalMemoryCount: 2, totalEdgeCount: 0))
        a.replace(snapshot: replacement, hiddenProjects: [], hiddenRelations: [])
        a.simulation.setPositions([id(0): .zero, id(20): .zero]); a.tick(dt: 0)
        #expect(Set(a.positions.keys) == [id(0), id(20)])
    }

    @Test func positionRevisionTracksMutationAndNotCoolingTicks() {
        let sim = ForceSimulation3D(), first = id(0), second = id(1)
        sim.updateGraph(nodeIds: [first, second], edges: [])
        let initial = sim.positionRevision
        for _ in 0..<100 { sim.tick() }
        #expect(sim.positionRevision == initial)
        sim.setPosition(first, to: SIMD3(1, 2, 3))
        #expect(sim.positionRevision != initial)
        let beforeDelivery = sim.positionRevision
        sim.applyGPUForces(ForceResult(positions: [.zero, .zero]))
        #expect(sim.positionRevision != beforeDelivery)
        let beforeTopology = sim.positionRevision
        sim.removeNodes([second])
        #expect(sim.positionRevision != beforeTopology)
    }
    @Test func publishedPositionRevisionTracksForceSemanticAndHubOverlays() throws {
        let a = adapter(graph(count: 70, edgeCount: 64, hubCount: 1))
        settle(a)
        let original = try #require(a.positionRevision)
        let delivery = a.simulation.nodeIds.indices.map { index in
            SIMD3<Float>(a.simulation.posX[index] + 5, a.simulation.posY[index], a.simulation.posZ[index])
        }
        a.simulation.applyGPUForces(ForceResult(positions: delivery))
        #expect(a.positionRevision == original) // Only published coordinates advance it.
        a.tick(dt: 0)
        #expect(a.positionRevision != original)
        settle(a)
        let forceRevision = a.positionRevision
        let same = a.simulation.nodeIds.indices.map { SIMD3<Float>(a.simulation.posX[$0], a.simulation.posY[$0], a.simulation.posZ[$0]) }
        a.simulation.applyGPUForces(ForceResult(positions: same)); a.tick(dt: 0)
        #expect(a.positionRevision == forceRevision)
        let first = a.nodes[0].id
        a.semanticPositions = [first: a.positionArray[0] + SIMD3<Float>(50, 0, 0)]
        a.tick(dt: 1 / 60)
        #expect(a.positionRevision != forceRevision)
        a.semanticPositions = nil; a.tick(dt: 0)
        let beforeHub = a.positionRevision
        a.toggleHub(id(0)); a.tick(dt: 1 / 60)
        #expect(a.positionRevision != beforeHub)
        for _ in 0..<600 { a.tick(dt: 1 / 60) }
        let settledRevision = a.positionRevision
        for _ in 0..<100 { a.tick(dt: 1 / 60) }
        #expect(a.positionRevision == settledRevision)
    }

}
