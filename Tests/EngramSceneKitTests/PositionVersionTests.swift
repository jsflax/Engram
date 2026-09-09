import Foundation
import Testing
import EngramSceneKit

@MainActor
struct PositionVersionTests {
    @Test("Equal-count replacement rejects stale GPU slot ordering")
    func rejectsStaleGPUResultAfterReplacement() {
        let simulation = ForceSimulation3D()
        let a = UUID(), b = UUID(), replacement = UUID()
        simulation.addNode(a, project: "p", topic: "t")
        simulation.addNode(b, project: "p", topic: "t")
        let dispatchedOrder = simulation.nodeOrderVersion
        let readback = ForceResult(positions: [SIMD3(100, 200, 300), SIMD3(400, 500, 600)])
        simulation.removeNodes([a])
        simulation.addNode(replacement, project: "p", topic: "t")
        let beforeReadback = simulation.positions
        let positionRevision = simulation.positionVersion
        #expect(simulation.nodeCount == 2)
        #expect(simulation.nodeOrderVersion != dispatchedOrder)
        simulation.applyGPUForces(readback, expectedNodeOrderVersion: dispatchedOrder)
        #expect(simulation.positions == beforeReadback)
        #expect(simulation.positionVersion == positionRevision)
        #expect(simulation.topologyDirtyForGPU)
        // The next dispatch with the rebuilt ordering is accepted normally.
        simulation.applyGPUForces(readback, expectedNodeOrderVersion: simulation.nodeOrderVersion)
        #expect(simulation.positions[b] == SIMD3(100, 200, 300))
        #expect(simulation.positions[replacement] == SIMD3(400, 500, 600))
    }

    @Test("Position revisions track mutation but not force bookkeeping ticks")
    func revisionTracksPositions() {
        let simulation = ForceSimulation3D()
        let a = UUID(), b = UUID()
        let empty = simulation.positionVersion
        simulation.addNode(a, project: "p", topic: "t")
        simulation.addNode(b, project: "p", topic: "t")
        #expect(simulation.positionVersion > empty)
        let added = simulation.positionVersion
        for _ in 0..<3 { simulation.tick() }
        #expect(simulation.positionVersion == added)
        simulation.setPosition(a, to: SIMD3(1, 2, 3))
        #expect(simulation.positionVersion > added)
        let positioned = simulation.positionVersion
        simulation.applyGPUForces(ForceResult(positions: [SIMD3(4, 5, 6), SIMD3(7, 8, 9)]))
        #expect(simulation.positionVersion > positioned)
        #expect(simulation.positions[a] == SIMD3(4, 5, 6))
        let simulated = simulation.positionVersion
        simulation.removeNodes([b])
        #expect(simulation.positionVersion > simulated)
        #expect(simulation.positions[b] == nil)
    }
}
