import Metal
import EngramMetalShaders
import EngramSceneKit

/// Exclusive ownership transfers to the main-actor session once. Nothing retains a second copy
/// of the mutable simulation buffers after preparation, and no unchecked Sendable is introduced.
struct GraphPreparedForces {
    let compute: MetalForceCompute
    let simulation: GPUSimulationState
}

actor GraphForcePreparer {
    /// Library loading (including the existing source fallback) and pipeline compilation may
    /// block. Keep them off MainActor; RealityKit entity creation remains on MainActor.
    func prepare(device: any MTLDevice) throws -> sending GraphPreparedForces? {
        try Task.checkCancellation()
        let library = try EngramMetalShaders.makeLibrary(device: device)
        try Task.checkCancellation()
        guard let compute = MetalForceCompute(device: device, library: library),
              compute.isFullSimAvailable else { return nil }
        let simulation = GPUSimulationState(device: device, library: library)
        try Task.checkCancellation()
        guard simulation.integratePipeline != nil else { return nil }
        return GraphPreparedForces(compute: compute, simulation: simulation)
    }
}
