import Foundation
import Testing
import os
import simd
import CEngramSceneTypes
@preconcurrency import Metal
import EngramMetalShaders
@testable import EngramSceneKit

/// Tests that the O(n²) brute-force charge kernel does NOT fire at 8K+ nodes.
/// This is the root cause of GPU starvation → 1-second drawable blocks → laptop crash.
/// At 8K nodes, brute force = 64M iterations per command buffer, starving the render queue.
@Suite("Brute Force Guard")
struct BruteForceGuardTests {

    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()

    // Each case owns its writer and drains that queue before inspecting records.
    // No global logger configuration, environment changes or shared file paths.
    private struct Capture {
        let queue = DispatchQueue(label: "brute-force-guard.log")
        let lines = OSAllocatedUnfairLock<[String]>(initialState: [])

        func writer() -> GPULog.Writer {
            GPULog.Writer(queue: queue) { [lines] line in lines.withLock { $0.append(line) } }
        }

        func charge(nodeCount: Int) throws -> String {
            queue.sync {}
            let saved = lines.withLock { $0 }
            try #require(saved.count == 1, "One completed dispatch must produce one actual record")
            let row = try #require(JSONSerialization.jsonObject(with: Data(saved[0].utf8)) as? [String: Any])
            #expect(row["kind"] as? String == "force")
            #expect(row["status"] as? Int == Int(MTLCommandBufferStatus.completed.rawValue))
            let metadata = try #require(row["metadata"] as? [String: Any])
            #expect(metadata["nodes"] as? Int == nodeCount)
            return try #require(metadata["charge"] as? String)
        }
    }

    @Test("GPULog writer delivers queued output")
    func testGPULogWorks() {
        let capture = Capture()
        let submitted = capture.writer().submit(.message("TEST MESSAGE"))
        capture.queue.sync {}
        #expect(submitted)
        #expect(capture.lines.withLock { $0 } == ["TEST MESSAGE"])
    }

    // MARK: - Brute force guard at scale

    @Test
    @MainActor func testBruteForceGuard8K() async throws {
        let device = try #require(Self.device)
        let library = try EngramMetalShaders.makeLibrary(device: device)
        let fc = try #require(MetalForceCompute(device: device, library: library))
        let capture = Capture()
        let forceEngine = ForceEngine(forceCompute: fc, diagnosticWriter: capture.writer())
        let queue = try #require(device.makeCommandQueue())
        #expect(fc.isFullSimAvailable)

        let n = 8000
        let x = (0..<n).map { _ in Float.random(in: -500...500) }
        let y = (0..<n).map { _ in Float.random(in: -500...500) }
        let z = (0..<n).map { _ in Float.random(in: -500...500) }
        let projectGroups = (0..<n).map { $0 % 15 }
        let topicGroups = (0..<n).map { $0 % 247 }
        let galaxyGroups = [Int](repeating: 0, count: n)

        var edges: [(Int, Int)] = []
        for _ in 0..<100_000 {
            let s = Int.random(in: 0..<n)
            var t = Int.random(in: 0..<n)
            while t == s { t = Int.random(in: 0..<n) }
            edges.append((s, t))
        }

        let snapshot = ForceEngine.SimulationSnapshot(
            nodeCount: n, isSettled: false,
            posX: x, posY: y, posZ: z,
            projectGroups: projectGroups, topicGroups: topicGroups,
            galaxyGroups: galaxyGroups, galaxyCenters: [SIMD3<Float>.zero],
            edgeIndices: edges, topologyDirty: true,
            chargeStrength: 500, crossChargeMultiplier: 3.0,
            sameTopicChargeScale: 0.35, sameProjectChargeScale: 1.0,
            springLength: 240, crossProjectSpringLength: 400, springStrength: 0.0004,
            cohesionStrength: 0.0015, centroidRepulsion: 2500,
            topicCohesionStrength: 0.009, topicCentroidRepulsion: 3500,
            centerStrength: 0.006,
            alpha: 1.0, damping: 0.78, maxSpeed: 12.0
        )

        // Dispatch forces — this is the exact code path the app uses
        var delivered: ForceResult?
        let command = try #require(forceEngine.encodeForcePass(queue: queue, snapshot: snapshot) { delivered = $0 })
        let deadline = ContinuousClock.now + .seconds(5)
        while delivered == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = try #require(delivered, "Owned GPU pass must deliver within the test bound")
        #expect(command.status == .completed)
        #expect(result.fx.count == n && result.fx.allSatisfy(\.isFinite))

        let charge = try capture.charge(nodeCount: n)
        #expect(charge != "bruteForce", "The 8K production path must not dispatch brute force")
        #expect(charge == "barnesHut", "The packaged BH pipeline must actually dispatch; an empty/skipped record is insufficient")
    }

    // MARK: - Brute force IS allowed for small n

    @Test
    @MainActor func testBruteForceAllowed1K() async throws {
        let device = try #require(Self.device)
        let library = try EngramMetalShaders.makeLibrary(device: device)
        // The normal packaged pipeline uses BH even for small inputs. Model
        // only BH construction failure to exercise the existing real fallback.
        var declinedBH = false
        let candidate = MetalForceCompute(device: device, library: library, makePipeline: { function in
            if function.name == "compute_charge_forces_bh" {
                declinedBH = true
                return nil
            }
            return try? device.makeComputePipelineState(function: function)
        })
        let fc = try #require(candidate)
        #expect(declinedBH)
        #expect(fc.isFullSimAvailable)
        let capture = Capture()
        let forceEngine = ForceEngine(forceCompute: fc, diagnosticWriter: capture.writer())
        let queue = try #require(device.makeCommandQueue())

        let n = 1000
        let x = (0..<n).map { _ in Float.random(in: -500...500) }
        let y = (0..<n).map { _ in Float.random(in: -500...500) }
        let z = (0..<n).map { _ in Float.random(in: -500...500) }
        let projectGroups = (0..<n).map { $0 % 5 }
        let topicGroups = (0..<n).map { $0 % 20 }
        let galaxyGroups = [Int](repeating: 0, count: n)

        let snapshot = ForceEngine.SimulationSnapshot(
            nodeCount: n, isSettled: false,
            posX: x, posY: y, posZ: z,
            projectGroups: projectGroups, topicGroups: topicGroups,
            galaxyGroups: galaxyGroups, galaxyCenters: [SIMD3<Float>.zero],
            edgeIndices: [], topologyDirty: true,
            chargeStrength: 500, crossChargeMultiplier: 3.0,
            sameTopicChargeScale: 0.35, sameProjectChargeScale: 1.0,
            springLength: 240, crossProjectSpringLength: 400, springStrength: 0.0004,
            cohesionStrength: 0.0015, centroidRepulsion: 2500,
            topicCohesionStrength: 0.009, topicCentroidRepulsion: 3500,
            centerStrength: 0.006,
            alpha: 1.0, damping: 0.78, maxSpeed: 12.0
        )

        var delivered: ForceResult?
        let command = try #require(forceEngine.encodeForcePass(queue: queue, snapshot: snapshot) { delivered = $0 })
        let deadline = ContinuousClock.now + .seconds(5)
        while delivered == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = try #require(delivered, "Owned GPU pass must deliver within the test bound")
        #expect(command.status == .completed)
        #expect(result.fx.count == n && result.fx.allSatisfy(\.isFinite))

        let charge = try capture.charge(nodeCount: n)
        #expect(charge == "bruteForce", "A missing BH pipeline must dispatch the real packaged brute kernel")
    }
}
