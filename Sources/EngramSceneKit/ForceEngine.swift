@preconcurrency import Metal
import CEngramSceneTypes
import simd
import os

/// Encapsulates GPU force dispatch orchestration.
/// Checks readiness, manages topology, creates separate command buffers
/// on the shared queue, and delivers results via callback.
@MainActor
public final class ForceEngine {
    public let forceCompute: MetalForceCompute
    /// GPU simulation state for integration (position/velocity buffers).
    public let simState: GPUSimulationState?

    public init(forceCompute: MetalForceCompute, simState: GPUSimulationState? = nil) {
        self.forceCompute = forceCompute
        self.simState = simState
    }

    /// Whether the underlying force compute pipeline is ready.
    public var isFullSimAvailable: Bool { forceCompute.isFullSimAvailable }

    /// Whether a force dispatch is currently in flight on the GPU.
    public var isInFlight: Bool { forceCompute.inFlight }

    /// Snapshot of simulation state needed for force encoding.
    /// Simplified to match JS reference — no topic leash, no crossProjectSpringScale.
    public struct SimulationSnapshot {
        public let nodeCount: Int
        public let isSettled: Bool
        public let posX: [Float]
        public let posY: [Float]
        public let posZ: [Float]
        public let projectGroups: [Int]
        public let topicGroups: [Int]
        public let topicProjectGroup: [Int]
        public let galaxyGroups: [Int]
        public let galaxyCenters: [SIMD3<Float>]
        public let edgeIndices: [(Int, Int)]
        public let topologyDirty: Bool

        // Force parameters (matching JS force-params.ts)
        public let chargeStrength: Float
        public let crossChargeMultiplier: Float
        public let sameTopicChargeScale: Float
        public let sameProjectChargeScale: Float
        public let springLength: Float
        public let crossProjectSpringLength: Float
        public let springStrength: Float
        public let cohesionStrength: Float
        public let centroidRepulsion: Float
        public let topicCohesionStrength: Float
        public let topicCentroidRepulsion: Float
        public let centerStrength: Float
        public let alpha: Float
        public let damping: Float
        public let maxSpeed: Float

        public init(
            nodeCount: Int, isSettled: Bool,
            posX: [Float], posY: [Float], posZ: [Float],
            projectGroups: [Int], topicGroups: [Int],
            topicProjectGroup: [Int] = [],
            galaxyGroups: [Int], galaxyCenters: [SIMD3<Float>],
            edgeIndices: [(Int, Int)], topologyDirty: Bool,
            chargeStrength: Float, crossChargeMultiplier: Float,
            sameTopicChargeScale: Float, sameProjectChargeScale: Float,
            springLength: Float, crossProjectSpringLength: Float, springStrength: Float,
            cohesionStrength: Float, centroidRepulsion: Float,
            topicCohesionStrength: Float, topicCentroidRepulsion: Float,
            centerStrength: Float,
            alpha: Float, damping: Float, maxSpeed: Float
        ) {
            self.nodeCount = nodeCount; self.isSettled = isSettled
            self.posX = posX; self.posY = posY; self.posZ = posZ
            self.projectGroups = projectGroups; self.topicGroups = topicGroups
            self.topicProjectGroup = topicProjectGroup
            self.galaxyGroups = galaxyGroups; self.galaxyCenters = galaxyCenters
            self.edgeIndices = edgeIndices; self.topologyDirty = topologyDirty
            self.chargeStrength = chargeStrength
            self.crossChargeMultiplier = crossChargeMultiplier
            self.sameTopicChargeScale = sameTopicChargeScale
            self.sameProjectChargeScale = sameProjectChargeScale
            self.springLength = springLength
            self.crossProjectSpringLength = crossProjectSpringLength
            self.springStrength = springStrength
            self.cohesionStrength = cohesionStrength
            self.centroidRepulsion = centroidRepulsion
            self.topicCohesionStrength = topicCohesionStrength
            self.topicCentroidRepulsion = topicCentroidRepulsion
            self.centerStrength = centerStrength
            self.alpha = alpha
            self.damping = damping; self.maxSpeed = maxSpeed
        }
    }

    /// Synchronous GPU force pass — encodes, waits, reads back, returns result.
    public func encodeForcePassSync(
        queue: MTLCommandQueue,
        snapshot: SimulationSnapshot
    ) -> ForceResult? {
        guard !snapshot.isSettled,
              snapshot.nodeCount > 1,
              forceCompute.isFullSimAvailable else { return nil }

        let t0 = CFAbsoluteTimeGetCurrent()

        if snapshot.topologyDirty {
            forceCompute.setTopologyDirty(edges: snapshot.edgeIndices)
        }
        if forceCompute.topologyDirtyForDispatch {
            forceCompute.rebuildTopology(
                nodeCount: snapshot.nodeCount,
                projectGroups: snapshot.projectGroups,
                topicGroups: snapshot.topicGroups,
                topicProjectGroup: snapshot.topicProjectGroup,
                galaxyGroups: snapshot.galaxyGroups,
                galaxyCenters: snapshot.galaxyCenters,
                x: snapshot.posX, y: snapshot.posY, z: snapshot.posZ)
        }

        guard let cmdBuf = queue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else { return nil }

        forceCompute.encodeForces(
            encoder: encoder,
            x: snapshot.posX, y: snapshot.posY, z: snapshot.posZ,
            projectGroups: snapshot.projectGroups, topicGroups: snapshot.topicGroups,
            galaxyGroups: snapshot.galaxyGroups, galaxyCenters: snapshot.galaxyCenters,
            chargeStrength: snapshot.chargeStrength,
            crossChargeMultiplier: snapshot.crossChargeMultiplier,
            sameTopicChargeScale: snapshot.sameTopicChargeScale,
            sameProjectChargeScale: snapshot.sameProjectChargeScale,
            springLength: snapshot.springLength,
            crossProjectSpringLength: snapshot.crossProjectSpringLength,
            springStrength: snapshot.springStrength,
            cohesionStrength: snapshot.cohesionStrength,
            centroidRepulsion: snapshot.centroidRepulsion,
            topicCohesionStrength: snapshot.topicCohesionStrength,
            topicCentroidRepulsion: snapshot.topicCentroidRepulsion,
            centerStrength: snapshot.centerStrength,
            alpha: snapshot.alpha, damping: snapshot.damping, maxSpeed: snapshot.maxSpeed)

        if let ss = simState, let forceBuf = forceCompute.outputForceBuffer {
            ss.uploadPositions(x: snapshot.posX, y: snapshot.posY, z: snapshot.posZ)
            ss.encodeIntegration(encoder: encoder, forceBuffer: forceBuf,
                                 damping: snapshot.damping, maxSpeed: snapshot.maxSpeed)
        }
        encoder.endEncoding()

        let t1 = CFAbsoluteTimeGetCurrent()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        let t2 = CFAbsoluteTimeGetCurrent()

        var result: ForceResult?
        if let ss = simState {
            ss.readBackPositions()
            result = ForceResult(positions: ss.cpuPositions)
        } else if let forces = forceCompute.readBackForces() {
            result = ForceResult(fx: forces.fx, fy: forces.fy, fz: forces.fz)
        }
        let t3 = CFAbsoluteTimeGetCurrent()

        result?.cpuPrepMs = (t1 - t0) * 1000
        result?.gpuMs = (t2 - t1) * 1000
        result?.readbackMs = (t3 - t2) * 1000
        result?.algorithm = forceCompute.lastChargeAlgorithm
        return result
    }

    /// Attempt to encode a GPU force pass (async).
    @discardableResult
    public func encodeForcePass(
        queue: MTLCommandQueue,
        snapshot: SimulationSnapshot,
        onComplete: @MainActor @Sendable @escaping (ForceResult) -> Void
    ) -> MTLCommandBuffer? {
        guard !snapshot.isSettled,
              snapshot.nodeCount > 1,
              forceCompute.isFullSimAvailable,
              !forceCompute.inFlight else { return nil }

        if snapshot.topologyDirty {
            forceCompute.setTopologyDirty(edges: snapshot.edgeIndices)
        }
        if forceCompute.topologyDirtyForDispatch {
            forceCompute.rebuildTopology(
                nodeCount: snapshot.nodeCount,
                projectGroups: snapshot.projectGroups,
                topicGroups: snapshot.topicGroups,
                topicProjectGroup: snapshot.topicProjectGroup,
                galaxyGroups: snapshot.galaxyGroups,
                galaxyCenters: snapshot.galaxyCenters,
                x: snapshot.posX, y: snapshot.posY, z: snapshot.posZ)
        }

        guard let cmdBuf = queue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else { return nil }

        forceCompute.inFlight = true

        forceCompute.encodeForces(
            encoder: encoder,
            x: snapshot.posX, y: snapshot.posY, z: snapshot.posZ,
            projectGroups: snapshot.projectGroups, topicGroups: snapshot.topicGroups,
            galaxyGroups: snapshot.galaxyGroups, galaxyCenters: snapshot.galaxyCenters,
            chargeStrength: snapshot.chargeStrength,
            crossChargeMultiplier: snapshot.crossChargeMultiplier,
            sameTopicChargeScale: snapshot.sameTopicChargeScale,
            sameProjectChargeScale: snapshot.sameProjectChargeScale,
            springLength: snapshot.springLength,
            crossProjectSpringLength: snapshot.crossProjectSpringLength,
            springStrength: snapshot.springStrength,
            cohesionStrength: snapshot.cohesionStrength,
            centroidRepulsion: snapshot.centroidRepulsion,
            topicCohesionStrength: snapshot.topicCohesionStrength,
            topicCentroidRepulsion: snapshot.topicCentroidRepulsion,
            centerStrength: snapshot.centerStrength,
            alpha: snapshot.alpha, damping: snapshot.damping, maxSpeed: snapshot.maxSpeed)

        let hasGPUIntegration: Bool
        if let ss = simState, let forceBuf = forceCompute.outputForceBuffer {
            ss.uploadPositions(x: snapshot.posX, y: snapshot.posY, z: snapshot.posZ)
            ss.encodeIntegration(encoder: encoder, forceBuffer: forceBuf,
                                 damping: snapshot.damping, maxSpeed: snapshot.maxSpeed)
            hasGPUIntegration = true
        } else {
            hasGPUIntegration = false
        }
        encoder.endEncoding()

        let fc = forceCompute
        let ss = simState
        let nodeCount = snapshot.nodeCount
        cmdBuf.addCompletedHandler { @Sendable cb in
            GPULog.log("FORCE CB complete status=\(cb.status.rawValue)")
            // True GPU occupancy + which charge path ran — the BH-vs-BRUTE
            // question decides where the 42k optimization effort goes.
            let gpuMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            GPULog.log("FORCE GPU \(String(format: "%.2f", gpuMs))ms algo=\(fc.lastChargeAlgorithm) n=\(nodeCount)")
            if cb.status == .error {
                GPULog.log("FORCE ERROR: \(cb.error?.localizedDescription ?? "unknown")")
                Task { @MainActor in fc.inFlight = false }
                return
            }

            if hasGPUIntegration, let ss {
                ss.readBackPositions()
                let positions = ss.cpuPositions
                let result = ForceResult(positions: positions,
                                         diagnosticEnqueuedAt: FrameGapDiagnostics.timestamp())
                Task { @MainActor in
                    fc.inFlight = false
                    onComplete(result)
                }
            } else if let forces = fc.readBackForces() {
                let result = ForceResult(fx: forces.fx, fy: forces.fy, fz: forces.fz,
                                         diagnosticEnqueuedAt: FrameGapDiagnostics.timestamp())
                Task { @MainActor in
                    fc.inFlight = false
                    onComplete(result)
                }
            } else {
                Task { @MainActor in fc.inFlight = false }
            }
        }
        cmdBuf.commit()
        return cmdBuf
    }
}
