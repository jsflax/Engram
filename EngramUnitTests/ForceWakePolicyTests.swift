@testable import EngramSceneKit
import Foundation
import XCTest

@MainActor
final class ForceWakePolicyTests: XCTestCase {
    private func populate(_ simulation: ForceSimulation3D, count: Int) -> [UUID] {
        let ids = (0..<count).map { _ in UUID() }
        for id in ids { simulation.addNode(id, project: "Wake policy", topic: "general", galaxyId: "first") }
        return ids
    }

    private func settle(_ simulation: ForceSimulation3D, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<1_000 { simulation.tick() }
        XCTAssertTrue(simulation.isSettled, file: file, line: line)
    }

    func testExactly24ActualChangesStaySettledDespiteDuplicateAndAbsentOperations() {
        let simulation = ForceSimulation3D()
        let ids = populate(simulation, count: 35)
        settle(simulation)
        let alpha = simulation.alpha
        let retainedPosition = simulation.positions[ids[0]]
        for _ in 0..<100 { simulation.addEdge(from: ids[0], to: ids[1]) }
        // One edge, one actual node removal, and 22 additions are exactly 24.
        simulation.removeNodes(Set([ids[34]] + (0..<24).map { _ in UUID() }))
        _ = populate(simulation, count: 22)
        simulation.tick()
        XCTAssertTrue(simulation.isSettled)
        XCTAssertEqual(simulation.alpha, alpha)
        XCTAssertEqual(simulation.positions[ids[0]], retainedPosition)
        XCTAssertEqual(simulation.edgeIndicesPublic.count, 1)
        XCTAssertEqual(simulation.nodeCount, 56)
    }

    func test25ActualChangesReheatFromTheSettledFloor() {
        let simulation = ForceSimulation3D()
        _ = populate(simulation, count: 2)
        settle(simulation)
        let alpha = simulation.alpha, frames = simulation.framesSinceWake
        simulation.isActive = false
        _ = populate(simulation, count: 25)
        simulation.tick()
        XCTAssertTrue(simulation.isSettled, "Inactive ticks neither apply nor discard the pending wake")
        XCTAssertEqual(simulation.alpha, alpha)
        XCTAssertEqual(simulation.framesSinceWake, frames)
        simulation.isActive = true
        simulation.tick()
        XCTAssertFalse(simulation.isSettled)
        XCTAssertEqual(simulation.alpha, 0.995, accuracy: 0.000_001)
        XCTAssertEqual(simulation.framesSinceWake, 1)
    }

    func testSmallActiveChangesPreserveCoolingAndNearFloorSettlingProgress() {
        let simulation = ForceSimulation3D()
        let ids = populate(simulation, count: 2)
        for _ in 0..<500 { simulation.tick() }
        XCTAssertFalse(simulation.isSettled)
        for _ in 0..<10 {
            let alpha = simulation.alpha, frames = simulation.framesSinceWake
            _ = populate(simulation, count: 1)
            simulation.tick()
            XCTAssertEqual(simulation.alpha, alpha * 0.995, accuracy: 0.000_001)
            XCTAssertEqual(simulation.framesSinceWake, frames + 1)
        }

        for _ in 0..<1_000 {
            if simulation.alpha <= 0.011 { break }
            simulation.tick()
        }
        XCTAssertLessThanOrEqual(simulation.alpha, 0.011)
        // The threshold-crossing tick is the first of 30 settling frames.
        for _ in 0..<20 { simulation.tick() }
        XCTAssertFalse(simulation.isSettled)
        simulation.addEdge(from: ids[0], to: ids[1])
        simulation.tick()
        for _ in 0..<8 { simulation.tick() }
        XCTAssertTrue(simulation.isSettled, "A small live change must not restart the settling window")
    }

    func testMigrationReheatsButRepeatedAndMissingMembershipChangesDoNot() {
        let simulation = ForceSimulation3D()
        let ids = populate(simulation, count: 3)
        settle(simulation)
        simulation.changeGalaxyGroup(for: [ids[0]], to: "second")
        simulation.tick()
        XCTAssertFalse(simulation.isSettled)
        XCTAssertEqual(simulation.alpha, 0.995, accuracy: 0.000_001)
        XCTAssertEqual(simulation.framesSinceWake, 1)
        settle(simulation)
        let alpha = simulation.alpha, frames = simulation.framesSinceWake
        simulation.changeGalaxyGroup(for: [ids[0], UUID()], to: "second")
        simulation.tick()
        XCTAssertTrue(simulation.isSettled)
        XCTAssertEqual(simulation.alpha, alpha)
        XCTAssertEqual(simulation.framesSinceWake, frames)
    }

    func testRemovingOnlyAbsentNodesDoesNotInvalidateOrWake() {
        let simulation = ForceSimulation3D()
        _ = populate(simulation, count: 3)
        settle(simulation)
        let order = simulation.nodeOrderVersion, positions = simulation.positionVersion
        let alpha = simulation.alpha
        simulation.topologyDirtyForGPU = false
        simulation.removeNodes(Set((0..<100).map { _ in UUID() }))
        simulation.tick()
        XCTAssertEqual(simulation.nodeOrderVersion, order)
        XCTAssertEqual(simulation.positionVersion, positions)
        XCTAssertFalse(simulation.topologyDirtyForGPU)
        XCTAssertTrue(simulation.isSettled)
        XCTAssertEqual(simulation.alpha, alpha)
    }

    func testHubRemovalCountsIncidentEdgesTowardBulkWake() {
        let simulation = ForceSimulation3D()
        let ids = populate(simulation, count: 27)
        for id in ids[1...25] { simulation.addEdge(from: ids[0], to: id) }
        settle(simulation)
        simulation.removeNodes([ids[0]])
        simulation.tick()
        XCTAssertEqual(simulation.nodeCount, 26)
        XCTAssertTrue(simulation.edgeIndicesPublic.isEmpty)
        XCTAssertFalse(simulation.isSettled, "One node and its 25 dropped edges are a bulk topology change")
        XCTAssertEqual(simulation.alpha, 0.995, accuracy: 0.000_001)
        XCTAssertEqual(simulation.framesSinceWake, 1)
    }

    func testSingletonTickDrainsChangesBeforeTheNextBatch() {
        let simulation = ForceSimulation3D()
        let ids = populate(simulation, count: 2)
        settle(simulation)
        simulation.removeNodes([ids[1]])
        simulation.tick()
        XCTAssertEqual(simulation.nodeCount, 1)
        _ = populate(simulation, count: 24)
        simulation.tick()
        XCTAssertTrue(simulation.isSettled, "The prior singleton tick must not leak its removal into this 24-change batch")
    }
}
