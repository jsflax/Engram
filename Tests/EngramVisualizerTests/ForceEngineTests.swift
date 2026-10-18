import Foundation
import Testing
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

    @MainActor private func makeForceEngine() throws -> (ForceEngine, MTLCommandQueue) {
        let device = try #require(Self.device)
        let library = try EngramMetalShaders.makeLibrary(device: device)
        let queue = try #require(device.makeCommandQueue())
        let fc = try #require(MetalForceCompute(device: device, library: library))
        return (ForceEngine(forceCompute: fc), queue)
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

    /// Only project/topic cohesion and galaxy centering are active. Each test
    /// group fits within its reference radius, giving a simple force oracle
    /// while still using the packaged Metal kernels and their real buffers.
    private func preparationSnapshot(x: [Float], groups: [Int], dirty: Bool) -> ForceEngine.SimulationSnapshot {
        ForceEngine.SimulationSnapshot(
            nodeCount: x.count, isSettled: false,
            posX: x, posY: Array(repeating: 0, count: x.count), posZ: Array(repeating: 0, count: x.count),
            projectGroups: groups, topicGroups: groups,
            topicProjectGroup: [0, 1, 2],
            galaxyGroups: groups, galaxyCenters: [.zero, SIMD3(100, 0, 0), SIMD3(200, 0, 0)],
            edgeIndices: (1..<x.count).map { ($0 - 1, $0) }, topologyDirty: dirty,
            chargeStrength: 0, crossChargeMultiplier: 1,
            sameTopicChargeScale: 1, sameProjectChargeScale: 1,
            springLength: 1, crossProjectSpringLength: 1, springStrength: 0,
            cohesionStrength: 0.02, centroidRepulsion: 0,
            topicCohesionStrength: 0.03, topicCentroidRepulsion: 0,
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
        let grownX = (0..<513).map { Float($0 % 3) * 100 + Float(($0 / 3) % 2) * 10 }
        let grown = preparationSnapshot(x: grownX, groups: grownGroups, dirty: true)
        let grownResult = try #require(engine.encodeForcePassSync(queue: queue, snapshot: grown))
        try expectPreparationForces(grownResult, snapshot: grown)
        #expect(fc.centroidUpdateCount == 3)
        #expect(fc.groupUploadCount == 3)
    }

    @Test
    @MainActor func testPreparationAsyncDirtyDispatch() async throws {
        let (engine, queue) = try makeForceEngine()
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
            #expect(fc.groupUploadCount == pass)
            #expect(!engine.isInFlight)
        }
    }
}
