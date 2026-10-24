import Foundation
import Testing
import os
import simd
import CEngramSceneTypes
@preconcurrency import Metal
import EngramMetalShaders
@testable import EngramSceneKit

/// Tests that ForceEngine correctly orchestrates GPU force dispatch.
/// Catches the specific bugs from the debugging session:
/// - cutoffSq hardcoded → BH O(n²) degeneration
/// - Topology rebuild missing → edges=0 → no clustering
/// - Uses separate command buffer on shared queue (no dual-queue contention)
@Suite("ForceEngine")
struct ForceEngineTests {

    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()

    @MainActor private func makeForceEngine(diagnosticWriter: GPULog.Writer? = nil) throws -> (ForceEngine, MTLCommandQueue) {
        let device = try #require(Self.device)
        let library = try EngramMetalShaders.makeLibrary(device: device)
        let queue = try #require(device.makeCommandQueue())
        let fc = try #require(MetalForceCompute(device: device, library: library))
        let engine = diagnosticWriter.map { ForceEngine(forceCompute: fc, diagnosticWriter: $0) }
            ?? ForceEngine(forceCompute: fc)
        return (engine, queue)
    }

    private func makeSnapshot(
        nodeCount n: Int = 8000,
        edgeCount: Int = 1000,
        topologyDirty: Bool = true,
        isSettled: Bool = false
    ) -> ForceEngine.SimulationSnapshot {
        let projectCount = 15
        let topicCount = 247
        let x = (0..<n).map { _ in Float.random(in: -500...500) }
        let y = (0..<n).map { _ in Float.random(in: -500...500) }
        let z = (0..<n).map { _ in Float.random(in: -500...500) }
        let projectGroups = (0..<n).map { $0 % projectCount }
        let topicGroups = (0..<n).map { $0 % topicCount }
        let galaxyGroups = [Int](repeating: 0, count: n)

        var edges: [(Int, Int)] = []
        for _ in 0..<edgeCount {
            let s = Int.random(in: 0..<n)
            var t = Int.random(in: 0..<n)
            while t == s { t = Int.random(in: 0..<n) }
            edges.append((s, t))
        }

        return ForceEngine.SimulationSnapshot(
            nodeCount: n, isSettled: isSettled,
            posX: x, posY: y, posZ: z,
            projectGroups: projectGroups, topicGroups: topicGroups,
            galaxyGroups: galaxyGroups, galaxyCenters: [.zero],
            edgeIndices: edges, topologyDirty: topologyDirty,
            chargeStrength: 500, crossChargeMultiplier: 3.0,
            sameTopicChargeScale: 0.35, sameProjectChargeScale: 1.0,
            springLength: 240, crossProjectSpringLength: 400, springStrength: 0.0004,
            cohesionStrength: 0.0015, centroidRepulsion: 2500,
            topicCohesionStrength: 0.009, topicCentroidRepulsion: 3500,
            centerStrength: 0.006,
            alpha: 1.0, damping: 0.78, maxSpeed: 12.0
        )
    }

    @Test("encodeForcePass returns true and delivers non-zero forces")
    @MainActor func testEncodeForcePassDelivers() async throws {
        let (engine, queue) = try makeForceEngine()
        let snapshot = makeSnapshot(nodeCount: 500, edgeCount: 200)

        let result: ForceResult = await withCheckedContinuation { cont in
            let didEncode = engine.encodeForcePass(queue: queue, snapshot: snapshot) { result in
                cont.resume(returning: result)
            }
            #expect(didEncode != nil, "Should encode forces for non-settled sim")
        }

        #expect(result.fx.count == 500)
        // At least some forces should be non-zero
        let maxForce = result.fx.map { abs($0) }.max() ?? 0
        #expect(maxForce > 0, "Forces should be non-zero at production scale")
    }

    @Test("skips encoding when settled")
    @MainActor func testSkipsWhenSettled() throws {
        let (engine, queue) = try makeForceEngine()
        let snapshot = makeSnapshot(nodeCount: 100, isSettled: true)

        let didEncode = engine.encodeForcePass(queue: queue, snapshot: snapshot) { _ in }
        #expect(didEncode == nil, "Should not encode when settled")
    }

    @Test("skips encoding when only 1 node")
    @MainActor func testSkipsSingleNode() throws {
        let (engine, queue) = try makeForceEngine()
        let snapshot = makeSnapshot(nodeCount: 1, edgeCount: 0)

        let didEncode = engine.encodeForcePass(queue: queue, snapshot: snapshot) { _ in }
        #expect(didEncode == nil, "Should not encode for single node")
    }

    @Test("topology rebuild fires when dirty — catches edges=0 bug")
    @MainActor func testTopologyRebuildWhenDirty() async throws {
        let (engine, queue) = try makeForceEngine()
        // Topology dirty with edges → should rebuild before encoding
        let snapshot = makeSnapshot(nodeCount: 200, edgeCount: 500, topologyDirty: true)

        let result: ForceResult = await withCheckedContinuation { cont in
            engine.encodeForcePass(queue: queue, snapshot: snapshot) { result in
                cont.resume(returning: result)
            }
        }

        // With edges present and topology rebuilt, springs should produce forces
        #expect(result.fx.count == 200)
        let maxForce = result.fx.map { abs($0) }.max() ?? 0
        #expect(maxForce > 0, "Forces should be non-zero after topology rebuild")
    }

    @Test("does not double-dispatch when inFlight")
    @MainActor func testNoDoubleDispatch() async throws {
        let (engine, queue) = try makeForceEngine()
        let snapshot = makeSnapshot(nodeCount: 200, edgeCount: 100)

        // First dispatch should succeed
        var firstCompleted = false
        let didEncode1 = engine.encodeForcePass(queue: queue, snapshot: snapshot) { _ in
            firstCompleted = true
        }
        #expect(didEncode1 != nil)

        // While first is in flight, second should be rejected
        let didEncode2 = engine.encodeForcePass(queue: queue, snapshot: snapshot) { _ in }
        #expect(didEncode2 == nil, "Should reject dispatch while in flight")

        // Wait for first to complete
        while !firstCompleted {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test("isFullSimAvailable reflects underlying compute state")
    @MainActor func testSimAvailability() throws {
        let (engine, _) = try makeForceEngine()
        #expect(engine.isFullSimAvailable, "Full sim should be available with proper shaders")
    }

    /// Defaults isolate cohesion and galaxy centering for the analytical oracle.
    /// Overrides exercise springs and metadata through the same packaged kernels.
    private func preparationSnapshot(
        x: [Float], groups: [Int], dirty: Bool,
        topics: [Int]? = nil, topicProjects: [Int] = [0, 1, 2],
        galaxies: [Int]? = nil,
        centers: [SIMD3<Float>] = [.zero, SIMD3(100, 0, 0), SIMD3(200, 0, 0)],
        edges: [(Int, Int)]? = nil, springs: Float = 0,
        projectRepulsion: Float = 0, topicRepulsion: Float = 0
    ) -> ForceEngine.SimulationSnapshot {
        ForceEngine.SimulationSnapshot(
            nodeCount: x.count, isSettled: false,
            posX: x, posY: Array(repeating: 0, count: x.count), posZ: Array(repeating: 0, count: x.count),
            projectGroups: groups, topicGroups: topics ?? groups,
            topicProjectGroup: topicProjects,
            galaxyGroups: galaxies ?? groups, galaxyCenters: centers,
            edgeIndices: edges ?? (1..<x.count).map { ($0 - 1, $0) }, topologyDirty: dirty,
            chargeStrength: 0, crossChargeMultiplier: 1,
            sameTopicChargeScale: 1, sameProjectChargeScale: 1,
            springLength: 1, crossProjectSpringLength: 1, springStrength: springs,
            cohesionStrength: 0.02, centroidRepulsion: projectRepulsion,
            topicCohesionStrength: 0.03, topicCentroidRepulsion: topicRepulsion,
            centerStrength: 0.001,
            alpha: 1, damping: 0.78, maxSpeed: 12)
    }

    private func expectPreparationForces(_ result: ForceResult, snapshot: ForceEngine.SimulationSnapshot) throws {
        try #require(result.fx.count == snapshot.nodeCount)
        try #require(result.fy.count == snapshot.nodeCount)
        try #require(result.fz.count == snapshot.nodeCount)
        var sums: [Int: (sum: Float, count: Int)] = [:]
        for i in snapshot.posX.indices {
            let group = snapshot.projectGroups[i]
            let prior = sums[group, default: (0, 0)]
            sums[group] = (prior.sum + snapshot.posX[i], prior.count + 1)
        }
        for i in snapshot.posX.indices {
            let group = snapshot.projectGroups[i]
            let members = try #require(sums[group])
            let mean = members.sum / Float(members.count)
            let expected = (mean - snapshot.posX[i]) * 0.05
                + (snapshot.galaxyCenters[group].x - snapshot.posX[i]) * 0.001
            #expect(result.fx[i].isFinite && abs(result.fx[i] - expected) < 0.0001,
                    "Node \(i) must use the current group, centroid and galaxy-center offsets")
            #expect(result.fy[i].isFinite && abs(result.fy[i]) < 0.0001)
            #expect(result.fz[i].isFinite && abs(result.fz[i]) < 0.0001)
        }
    }

    private func expectSameForces(_ actual: ForceResult, _ expected: ForceResult) throws {
        for (actualAxis, expectedAxis) in [(actual.fx, expected.fx), (actual.fy, expected.fy), (actual.fz, expected.fz)] {
            try #require(actualAxis.count == expectedAxis.count)
            for (a, e) in zip(actualAxis, expectedAxis) {
                #expect(a.isFinite && e.isFinite && abs(a - e) < 0.0001)
            }
        }
    }

    @MainActor private func freshlyPreparedForces(_ snapshot: ForceEngine.SimulationSnapshot) throws -> ForceResult {
        let (fresh, queue) = try makeForceEngine()
        if snapshot.edgeIndices.isEmpty {
            // The existing zero-edge contract retains a previously allocated
            // edge buffer. Seed only that storage; a different group key forces
            // the following real dispatch to prepare all static mappings anew.
            let seed = preparationSnapshot(
                x: snapshot.posX, groups: Array(repeating: 1, count: snapshot.nodeCount), dirty: true,
                edges: [(0, 1)])
            fresh.forceCompute.rebuildTopology(
                nodeCount: seed.nodeCount, edges: seed.edgeIndices,
                projectGroups: seed.projectGroups, topicGroups: seed.topicGroups,
                topicProjectGroup: seed.topicProjectGroup,
                galaxyGroups: seed.galaxyGroups, galaxyCenters: seed.galaxyCenters,
                x: seed.posX, y: seed.posY, z: seed.posZ)
        }
        return try #require(fresh.encodeForcePassSync(queue: queue, snapshot: snapshot))
    }

    @Test
    @MainActor func testPreparationEdgeOnlyReusesGroupsAndUpdatesSprings() throws {
        let (engine, queue) = try makeForceEngine()
        let fc = engine.forceCompute
        let x: [Float] = [0, 3, 9, 15, 21, 27]
        let groups = Array(repeating: 0, count: x.count)
        let batches: [[(Int, Int)]] = [
            [(0, 1), (1, 2)],
            [(0, 1), (1, 2), (2, 5)],
            [(2, 5), (1, 2), (0, 1)], // same edges, different CSR accumulation order
            [(2, 5), (2, 5), (3, 3)], // duplicate endpoint references and a self-loop
            [], // remove every edge after storage has already been allocated
            [(5, 0)]
        ]
        var results: [ForceResult] = []
        for (index, edges) in batches.enumerated() {
            let snapshot = preparationSnapshot(x: x, groups: groups, dirty: true, edges: edges, springs: 0.07)
            let result = try #require(engine.encodeForcePassSync(queue: queue, snapshot: snapshot))
            try expectSameForces(result, freshlyPreparedForces(snapshot))
            #expect(fc.groupUploadCount == 1, "Edge-only edits must retain the exact static mappings")
            #expect(fc.centroidUpdateCount == index + 1)
            results.append(result)
        }
        // Nonzero springs must actually distinguish adding and removing edges.
        #expect(abs(results[0].fx[5] - results[1].fx[5]) > 0.1)
        #expect(abs(results[3].fx[5] - results[4].fx[5]) > 0.1)
        try expectPreparationForces(results[4], snapshot: preparationSnapshot(x: x, groups: groups, dirty: true))
    }

    @Test
    @MainActor func testPreparationEdgeOnlyKeepsCurrentCentroids() throws {
        let (engine, queue) = try makeForceEngine()
        let fc = engine.forceCompute
        let groups = Array(repeating: 0, count: 6)
        let positions: [[Float]] = [[0, 10, 20, 30, 40, 300], [0, 20, 30, 50, 60, 900], [10, 13, 19, 25, 31, 37]]
        var previous: ForceResult?
        for (index, x) in positions.enumerated() {
            // Change center values without changing their count as well. Both
            // centers and the p75 radii must refresh on this dirty dispatch.
            let snapshot = preparationSnapshot(
                x: x, groups: groups, dirty: true,
                centers: [SIMD3(Float(index * 100), 0, 0)])
            let result = try #require(engine.encodeForcePassSync(queue: queue, snapshot: snapshot))
            try expectSameForces(result, freshlyPreparedForces(snapshot))
            if let previous { #expect(abs(result.fx[5] - previous.fx[5]) > 0.1) }
            #expect(fc.groupUploadCount == 1)
            #expect(fc.centroidUpdateCount == index + 1)
            previous = result
        }
    }

    @Test
    @MainActor func testPreparationCentroidsUseFirstEncodePositionsAndCadence() throws {
        let (engine, queue) = try makeForceEngine()
        let fc = engine.forceCompute
        let x: [Float] = [0, 10, 100, 110, 200, 210]
        let groups = [0, 0, 1, 1, 2, 2]
        let snapshot = preparationSnapshot(x: x, groups: groups, dirty: false)
        // A public rebuild can precede command creation and later position changes.
        fc.rebuildTopology(
            nodeCount: x.count, edges: snapshot.edgeIndices,
            projectGroups: groups, topicGroups: groups, topicProjectGroup: [0, 1, 2],
            galaxyGroups: groups, galaxyCenters: snapshot.galaxyCenters,
            x: x.map { $0 - 400 }, y: snapshot.posY, z: snapshot.posZ)
        #expect(fc.centroidUpdateCount == 0)
        #expect(fc.groupUploadCount == 1)
        #expect(!fc.topologyDirtyForDispatch)

        for encode in 1...20 {
            let result = try #require(engine.encodeForcePassSync(queue: queue, snapshot: snapshot))
            try expectPreparationForces(result, snapshot: snapshot)
            #expect(fc.centroidUpdateCount == 1 + encode / 10)
            #expect(fc.groupUploadCount == 1, "A clean encode must reuse the prepared groups")
        }
    }

    @Test
    @MainActor func testPreparationRegroupAndCapacityGrowth() throws {
        let (engine, queue) = try makeForceEngine()
        let fc = engine.forceCompute
        let x: [Float] = [0, 10, 100, 110, 200, 210]
        let first = preparationSnapshot(x: x, groups: [0, 0, 0, 1, 1, 1], dirty: true)
        let firstResult = try #require(engine.encodeForcePassSync(queue: queue, snapshot: first))
        try expectPreparationForces(firstResult, snapshot: first)
        #expect(fc.centroidUpdateCount == 1)
        #expect(fc.groupUploadCount == 1)

        // Same node count, different assignments and project/topic counts. Call
        // the public rebuild directly, without setTopologyDirty as a prerequisite.
        let regrouped = preparationSnapshot(x: x, groups: [1, 1, 0, 0, 2, 2], dirty: false)
        fc.rebuildTopology(
            nodeCount: x.count, edges: regrouped.edgeIndices,
            projectGroups: regrouped.projectGroups, topicGroups: regrouped.topicGroups,
            topicProjectGroup: regrouped.topicProjectGroup,
            galaxyGroups: regrouped.galaxyGroups, galaxyCenters: regrouped.galaxyCenters,
            x: x, y: regrouped.posY, z: regrouped.posZ)
        #expect(fc.centroidUpdateCount == 1)
        #expect(fc.groupUploadCount == 2)
        let regroupedResult = try #require(engine.encodeForcePassSync(queue: queue, snapshot: regrouped))
        try expectPreparationForces(regroupedResult, snapshot: regrouped)
        #expect(fc.centroidUpdateCount == 2)
        #expect(fc.groupUploadCount == 2)

        // The initial allocation has capacity 512. Force new group storage and
        // verify all 513 outputs, not merely unchanged preparation counters.
        let grownGroups = (0..<513).map { $0 % 3 }
        let grownX: [Float] = (0..<513).map { (index: Int) -> Float in
            let group: Int = index % 3
            let alternatingOffset: Int = (index / 3) % 2
            let groupPosition: Float = Float(group) * 100
            let offset: Float = Float(alternatingOffset) * 10
            return groupPosition + offset
        }
        let grown = preparationSnapshot(x: grownX, groups: grownGroups, dirty: true)
        let grownResult = try #require(engine.encodeForcePassSync(queue: queue, snapshot: grown))
        try expectPreparationForces(grownResult, snapshot: grown)
        #expect(fc.centroidUpdateCount == 3)
        #expect(fc.groupUploadCount == 3)

        // Shrinking within the retained allocation must rewrite mappings too.
        let shrunk = preparationSnapshot(x: x, groups: [0, 0, 0, 1, 1, 1], dirty: true)
        let shrunkResult = try #require(engine.encodeForcePassSync(queue: queue, snapshot: shrunk))
        try expectPreparationForces(shrunkResult, snapshot: shrunk)
        #expect(fc.groupUploadCount == 4)
        #expect(fc.centroidUpdateCount == 4)

        // Exercise each exact-key field independently at a fixed node count.
        // Nonzero repulsions make topic-to-project and project-to-galaxy
        // metadata observable, rather than checking upload counts alone.
        let projects = [0, 0, 0, 1, 1, 1]
        let topics = [0, 0, 1, 2, 2, 2]
        let galaxies = Array(repeating: 0, count: 6)
        let variants = [
            preparationSnapshot(x: x, groups: projects, dirty: true, topics: topics,
                                topicProjects: [0, 0, 1], galaxies: galaxies,
                                projectRepulsion: 400, topicRepulsion: 400),
            preparationSnapshot(x: x, groups: projects, dirty: true, topics: topics,
                                topicProjects: [0, 1, 1], galaxies: galaxies,
                                projectRepulsion: 400, topicRepulsion: 400),
            preparationSnapshot(x: x, groups: projects, dirty: true, topics: topics,
                                topicProjects: [0, 1, 1], galaxies: [0, 0, 0, 1, 1, 1],
                                projectRepulsion: 400, topicRepulsion: 400),
            preparationSnapshot(x: x, groups: projects, dirty: true, topics: topics,
                                topicProjects: [0, 1, 1], galaxies: [0, 0, 0, 1, 1, 1],
                                centers: [.zero, SIMD3(100, 0, 0), SIMD3(200, 0, 0), SIMD3(300, 0, 0)],
                                projectRepulsion: 400, topicRepulsion: 400),
            preparationSnapshot(x: x, groups: projects, dirty: true, topics: [0, 1, 1, 2, 2, 2],
                                topicProjects: [0, 1, 1], galaxies: [0, 0, 0, 1, 1, 1],
                                centers: [.zero, SIMD3(100, 0, 0), SIMD3(200, 0, 0), SIMD3(300, 0, 0)],
                                projectRepulsion: 400, topicRepulsion: 400),
            preparationSnapshot(x: x, groups: [0, 0, 1, 1, 1, 1], dirty: true, topics: [0, 1, 1, 2, 2, 2],
                                topicProjects: [0, 1, 1], galaxies: [0, 0, 0, 1, 1, 1],
                                centers: [.zero, SIMD3(100, 0, 0), SIMD3(200, 0, 0), SIMD3(300, 0, 0)],
                                projectRepulsion: 400, topicRepulsion: 400)
        ]
        var variantResults: [ForceResult] = []
        for (index, snapshot) in variants.enumerated() {
            let result = try #require(engine.encodeForcePassSync(queue: queue, snapshot: snapshot))
            try expectSameForces(result, freshlyPreparedForces(snapshot))
            #expect(fc.groupUploadCount == 5 + index)
            #expect(fc.centroidUpdateCount == 5 + index)
            variantResults.append(result)
        }
        #expect(abs(variantResults[0].fx[0] - variantResults[1].fx[0]) > 0.001)
        #expect(abs(variantResults[1].fx[3] - variantResults[2].fx[3]) > 0.001)
    }

    @Test
    @MainActor func testPreparationAsyncDirtyDispatch() async throws {
        let logQueue = DispatchQueue(label: "force-test.diagnostics")
        let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
        let writer = GPULog.Writer(queue: logQueue) { line in lines.withLock { $0.append(line) } }
        let (engine, queue) = try makeForceEngine(diagnosticWriter: writer)
        let fc = engine.forceCompute
        for pass in 1...2 {
            let snapshot = preparationSnapshot(
                x: [0, 10, 100, 110, 200, 210].map { Float($0 + pass * 20) },
                groups: [0, 0, 1, 1, 2, 2], dirty: true)
            var delivered: ForceResult?
            let command = try #require(engine.encodeForcePass(queue: queue, snapshot: snapshot) { delivered = $0 })
            let deadline = ContinuousClock.now + .seconds(5)
            while delivered == nil && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let result = try #require(delivered, "Owned GPU pass must deliver within the test bound")
            #expect(command.status == .completed)
            try expectPreparationForces(result, snapshot: snapshot)
            #expect(fc.centroidUpdateCount == pass)
            #expect(fc.groupUploadCount == 1)
            #expect(!engine.isInFlight)
            logQueue.sync {}
            let saved = lines.withLock { $0 }
            try #require(saved.count == pass)
            let row = try #require(JSONSerialization.jsonObject(with: Data(saved[pass - 1].utf8)) as? [String: Any])
            let metadata = try #require(row["metadata"] as? [String: Any])
            #expect(metadata["nodes"] as? Int == 6)
            #expect(metadata["csrEdges"] as? Int == 5)
            #expect(metadata["projects"] as? Int == 3)
            #expect(metadata["topics"] as? Int == 3)
            #expect(metadata["galaxies"] as? Int == 3)
            #expect(metadata["charge"] as? String == "barnesHut")
            #expect(try #require(metadata["treeNodes"] as? Int) > 0)
            #expect(metadata["structural"] as? Bool == true)
            #expect(metadata["integrationRequested"] as? Bool == false)
            #expect(row["snapshotEdges"] as? Int == 5)
            #expect(row["status"] as? Int == Int(MTLCommandBufferStatus.completed.rawValue))
            let intervals = try #require(row["intervalsMs"] as? [String: Double])
            #expect(intervals["preparation_to_commit"] != nil)
            #expect(intervals["readback"] != nil)
            #expect(intervals["mainactor_delivery"] != nil)
            // Metal may leave GPU timestamps unavailable. Never turn that into
            // a zero-duration success or require hardware timing support.
            let validGPU = try #require(row["gpuTimingValid"] as? Bool)
            #expect((intervals["gpu_execution"] != nil) == validGPU)
        }
    }
}
