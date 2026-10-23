import Foundation
import XCTest
import EngramSceneKit
@testable import EngramRealityKit

@MainActor
private final class FrameLookupProvider: SceneDataProvider {
    var nodes: [RKNodeSnapshot] = []
    var edges: [RKEdgeSnapshot] = []
    var hubs: Set<UUID> = []
    var projectColorMap: [String: SIMD3<Float>] = [:]
    private var storedPositions: [UUID: SIMD3<Float>] = [:]
    private(set) var positionReads = 0
    var positions: [UUID: SIMD3<Float>] {
        get { positionReads += 1; return storedPositions }
        set { storedPositions = newValue }
    }
    var glowingNodes: [UUID: Float] = [:]
    var newNodeGlows: [UUID: Float] = [:]
    var dyingNodes: Set<UUID> = []
    var selectedNode: UUID?
    var expandedHubs: Set<UUID> = []
    var searchMatchIds: Set<UUID> = []
    var isSearchActive = false
    var projectCentroids: [String: SIMD3<Float>] = [:]
    var topologyVersion: UInt64 = 0
    var positionVersion: UInt64 = 0
    var explicitNodeVersion: UInt64?
    var explicitHubVersion: UInt64?
    var explicitAppendGeneration: UInt64?
    var nodeVersion: UInt64 { explicitNodeVersion ?? topologyVersion }
    var hubVersion: UInt64 { explicitHubVersion ?? topologyVersion }
    var nodeAppendGeneration: UInt64 { explicitAppendGeneration ?? topologyVersion }
    private(set) var tickDeltas: [Float] = []
    func tick(dt: Float) { tickDeltas.append(dt) }
}

@MainActor
final class FrameLookupInvalidationTests: XCTestCase {
    func testFrameGapIntervalsTailAndDrain() {
        let diagnostics = FrameGapDiagnostics(enabled: true), owner = NSObject()
        diagnostics.recordLoad(rows: 4, accepted: true, queuedAt: 50, startedAt: 60, endedAt: 70)
        let first = diagnostics.beginCallback(owner: owner, at: 100)
        XCTAssertTrue(first?.sequence == 1)
        XCTAssertTrue(first?.previousSequence == 0)
        XCTAssertTrue(first?.hasPreviousCallback == false)
        XCTAssertTrue(first?.entryIntervalNanoseconds == 0)
        XCTAssertTrue(first?.outsideCallbackNanoseconds == 0)
        XCTAssertTrue(first?.previousLoggerTailNanoseconds == 0)
        XCTAssertTrue(first?.load.rows == 4)
        diagnostics.finishCallback(owner: owner, bodyEndedAt: 140, exitedAt: 155)
        diagnostics.recordLoad(rows: 2, accepted: false, queuedAt: nil, startedAt: 170, endedAt: 180)
        diagnostics.recordForce(outcome: .positionsApplied, queuedAt: 160, startedAt: 180, endedAt: 190)
        let second = diagnostics.beginCallback(owner: owner, at: 200)
        XCTAssertTrue(second?.sequence == 2)
        XCTAssertTrue(second?.previousSequence == 1)
        XCTAssertTrue(second?.hasPreviousCallback == true)
        XCTAssertTrue(second?.entryIntervalNanoseconds == 100)
        XCTAssertTrue(second?.outsideCallbackNanoseconds == 45)
        XCTAssertTrue(second?.previousLoggerTailNanoseconds == 15)
        XCTAssertTrue(second?.load.count == 1)
        XCTAssertTrue(second?.load.rows == 2)
        XCTAssertTrue(second?.load.rejectedCount == 1)
        XCTAssertTrue(second?.force.acceptedCount == 1)
        // A missing/invalid exit cannot manufacture a complete interval.
        diagnostics.finishCallback(owner: owner, bodyEndedAt: 199, exitedAt: 220)
        let incomplete = diagnostics.beginCallback(owner: owner, at: 250)
        XCTAssertTrue(incomplete?.hasPreviousCallback == false)
        XCTAssertTrue(incomplete?.previousSequence == 0)
        XCTAssertTrue(incomplete?.entryIntervalNanoseconds == 0)
        XCTAssertTrue(incomplete?.outsideCallbackNanoseconds == 0)
        XCTAssertTrue(incomplete?.previousLoggerTailNanoseconds == 0)
        XCTAssertTrue(incomplete?.load.count == 0)
        XCTAssertTrue(incomplete?.load.durationNanoseconds == 0)
        XCTAssertTrue(incomplete?.load.maximumDurationNanoseconds == 0)
        XCTAssertTrue(incomplete?.force.count == 0)
        XCTAssertTrue(incomplete?.force.queueSamples == 0)
        // Earlier samples are values; subsequent draining does not erase them.
        XCTAssertTrue(first?.load.rows == 4)
        XCTAssertTrue(second?.force.acceptedCount == 1)
    }

    func testFrameGapOwnershipDoesNotStealAndResetsAfterRelease() {
        let diagnostics = FrameGapDiagnostics(enabled: true), other = NSObject()
        var owner: NSObject? = NSObject()
        weak var observedOwner: NSObject? = owner
        _ = diagnostics.beginCallback(owner: owner!, at: 100)
        diagnostics.finishCallback(owner: owner!, bodyEndedAt: 130, exitedAt: 140)
        diagnostics.recordLoad(rows: 7, accepted: true, queuedAt: 150, startedAt: 160, endedAt: 170)
        XCTAssertTrue(diagnostics.beginCallback(owner: other, at: 180) == nil)
        diagnostics.finishCallback(owner: other, bodyEndedAt: 181, exitedAt: 190)
        let retained = diagnostics.beginCallback(owner: owner!, at: 200)
        XCTAssertTrue(retained?.sequence == 2)
        XCTAssertTrue(retained?.previousSequence == 1)
        XCTAssertTrue(retained?.outsideCallbackNanoseconds == 60)
        XCTAssertTrue(retained?.previousLoggerTailNanoseconds == 10)
        XCTAssertTrue(retained?.load.count == 1)
        XCTAssertTrue(retained?.load.rows == 7)
        diagnostics.finishCallback(owner: owner!, bodyEndedAt: 220, exitedAt: 230)
        diagnostics.recordForce(outcome: .rejected, queuedAt: nil, startedAt: 240, endedAt: 245)
        owner = nil
        XCTAssertTrue(observedOwner == nil)
        let replacement = diagnostics.beginCallback(owner: other, at: 300)
        XCTAssertTrue(replacement?.sequence == 3)
        XCTAssertTrue(replacement?.previousSequence == 0)
        XCTAssertTrue(replacement?.hasPreviousCallback == false)
        XCTAssertTrue(replacement?.entryIntervalNanoseconds == 0)
        XCTAssertTrue(replacement?.outsideCallbackNanoseconds == 0)
        XCTAssertTrue(replacement?.previousLoggerTailNanoseconds == 0)
        XCTAssertTrue(replacement?.force.rejectedCount == 1)
        XCTAssertTrue(replacement?.load.count == 0)
    }

    func testFrameGapWorkAggregatesAndSaturates() {
        let diagnostics = FrameGapDiagnostics(enabled: true), owner = NSObject()
        diagnostics.recordLoad(rows: 2, accepted: true, queuedAt: 10, startedAt: 20, endedAt: 50)
        diagnostics.recordLoad(rows: 3, accepted: false, queuedAt: nil, startedAt: 40, endedAt: 45)
        diagnostics.recordLoad(rows: 4, accepted: true, queuedAt: 100, startedAt: 60, endedAt: 70)
        diagnostics.recordForce(outcome: .positionsApplied, queuedAt: 15, startedAt: 20, endedAt: 30)
        diagnostics.recordForce(outcome: .rejected, queuedAt: nil, startedAt: 40, endedAt: 60)
        diagnostics.recordForce(outcome: .rawFallback, queuedAt: 30, startedAt: 30, endedAt: 34)
        let sample = diagnostics.beginCallback(owner: owner, at: 100)
        XCTAssertTrue(sample?.load.count == 3)
        XCTAssertTrue(sample?.load.acceptedCount == 2)
        XCTAssertTrue(sample?.load.rejectedCount == 1)
        XCTAssertTrue(sample?.load.rows == 9)
        XCTAssertTrue(sample?.load.durationNanoseconds == 45)
        XCTAssertTrue(sample?.load.maximumDurationNanoseconds == 30)
        XCTAssertTrue(sample?.load.queueSamples == 1)
        XCTAssertTrue(sample?.load.queueNanoseconds == 10)
        XCTAssertTrue(sample?.load.maximumQueueNanoseconds == 10)
        XCTAssertTrue(sample?.force.count == 3)
        XCTAssertTrue(sample?.force.acceptedCount == 1)
        XCTAssertTrue(sample?.force.rejectedCount == 1)
        XCTAssertTrue(sample?.force.fallbackCount == 1)
        XCTAssertTrue(sample?.force.durationNanoseconds == 34)
        XCTAssertTrue(sample?.force.maximumDurationNanoseconds == 20)
        XCTAssertTrue(sample?.force.queueSamples == 2)
        XCTAssertTrue(sample?.force.queueNanoseconds == 5)
        XCTAssertTrue(sample?.force.maximumQueueNanoseconds == 5)

        // Exercise the emitted numeric contract with nonzero milliseconds,
        // including queue availability and previous-callback attribution.
        let csv = FrameGapDiagnostics(enabled: true)
        csv.recordLoad(rows: 2, accepted: true, queuedAt: 1_000_000,
                       startedAt: 3_000_000, endedAt: 8_000_000)
        csv.recordForce(outcome: .rawFallback, queuedAt: nil,
                        startedAt: 9_000_000, endedAt: 12_000_000)
        let csvFirst = csv.beginCallback(owner: owner, at: 20_000_000)
        let columns = FrameGapDiagnostics.csvHeader.components(separatedBy: ",")
        let firstValues = FrameGapDiagnostics.csvValues(csvFirst).components(separatedBy: ",")
        XCTAssertTrue(columns.count == 24)
        XCTAssertTrue(Set(columns).count == columns.count)
        XCTAssertTrue(firstValues.count == columns.count)
        let firstFields = Dictionary(uniqueKeysWithValues: zip(columns, firstValues))
        XCTAssertTrue(firstFields["gap_flags"] == "1")
        XCTAssertTrue(firstFields["load_count"] == "1")
        XCTAssertTrue(firstFields["load_accepted"] == "1")
        XCTAssertTrue(firstFields["load_rows"] == "2")
        XCTAssertTrue(firstFields["load_apply_ms"] == "5.000")
        XCTAssertTrue(firstFields["load_apply_max_ms"] == "5.000")
        XCTAssertTrue(firstFields["load_queue_samples"] == "1")
        XCTAssertTrue(firstFields["load_queue_ms"] == "2.000")
        XCTAssertTrue(firstFields["force_raw_fallback"] == "1")
        XCTAssertTrue(firstFields["force_applied"] == "0")
        XCTAssertTrue(firstFields["force_apply_ms"] == "3.000")
        XCTAssertTrue(firstFields["force_queue_samples"] == "0")
        csv.finishCallback(owner: owner, bodyEndedAt: 30_000_000, exitedAt: 32_000_000)
        let csvSecond = csv.beginCallback(owner: owner, at: 50_000_000)
        let nextValues = FrameGapDiagnostics.csvValues(csvSecond).components(separatedBy: ",")
        XCTAssertTrue(nextValues.count == columns.count)
        let nextFields = Dictionary(uniqueKeysWithValues: zip(columns, nextValues))
        XCTAssertTrue(nextFields["gap_flags"] == "3")
        XCTAssertTrue(nextFields["gap_callback"] == "2")
        XCTAssertTrue(nextFields["gap_previous_callback"] == "1")
        XCTAssertTrue(nextFields["callback_entry_dt_ms"] == "30.000")
        XCTAssertTrue(nextFields["callback_outside_ms"] == "18.000")
        XCTAssertTrue(nextFields["previous_logger_tail_ms"] == "2.000")
        XCTAssertTrue(nextFields["load_count"] == "0")
        XCTAssertTrue(nextFields["force_apply_count"] == "0")

        diagnostics.recordLoad(rows: Int.max, accepted: true, queuedAt: nil, startedAt: 0, endedAt: .max)
        diagnostics.recordLoad(rows: Int.max, accepted: true, queuedAt: nil, startedAt: 0, endedAt: .max)
        diagnostics.recordLoad(rows: Int.max, accepted: false, queuedAt: 0, startedAt: .max, endedAt: .max)
        diagnostics.recordLoad(rows: -1, accepted: false, queuedAt: 0, startedAt: .max, endedAt: .max)
        let saturated = diagnostics.beginCallback(owner: owner, at: .max)
        XCTAssertTrue(saturated?.load.count == 4)
        XCTAssertTrue(saturated?.load.rows == UInt64.max)
        XCTAssertTrue(saturated?.load.durationNanoseconds == UInt64.max)
        XCTAssertTrue(saturated?.load.maximumDurationNanoseconds == UInt64.max)
        XCTAssertTrue(saturated?.load.queueSamples == 2)
        XCTAssertTrue(saturated?.load.queueNanoseconds == UInt64.max)
        XCTAssertTrue(saturated?.load.maximumQueueNanoseconds == UInt64.max)
        XCTAssertTrue(saturated?.force.count == 0)
    }

    func testFrameGapDisabledPathDoesNotReadClock() {
        XCTAssertTrue(FrameGapDiagnostics.enabled(forPath: nil) == false)
        XCTAssertTrue(FrameGapDiagnostics.enabled(forPath: "") == false)
        XCTAssertTrue(FrameGapDiagnostics.enabled(forPath: "/owned/frame.csv") == true)
        var clockReads = 0
        let disabledStamp = FrameGapDiagnostics.timestamp(enabled: false) { clockReads += 1; return 42 }
        XCTAssertTrue(disabledStamp == nil)
        XCTAssertTrue(clockReads == 0)
        let enabledStamp = FrameGapDiagnostics.timestamp(enabled: true) { clockReads += 1; return 42 }
        XCTAssertTrue(enabledStamp == 42)
        XCTAssertTrue(clockReads == 1)
        let diagnostics = FrameGapDiagnostics(enabled: false), owner = NSObject()
        diagnostics.recordLoad(rows: 50, accepted: true, queuedAt: 1, startedAt: 2, endedAt: 3)
        diagnostics.recordForce(outcome: .positionsApplied, queuedAt: 1, startedAt: 2, endedAt: 3)
        XCTAssertTrue(diagnostics.beginCallback(owner: owner, at: 4) == nil)
        diagnostics.finishCallback(owner: owner, bodyEndedAt: 5, exitedAt: 6)
        XCTAssertTrue(diagnostics.beginCallback(owner: owner, at: 7) == nil)
        let unavailable = FrameGapDiagnostics.csvValues(nil).components(separatedBy: ",")
        XCTAssertTrue(unavailable.count == FrameGapDiagnostics.csvHeader.components(separatedBy: ",").count)
        XCTAssertTrue(unavailable.allSatisfy { $0 == "0" })
    }

    func testFrameGapForceOutcomesPreserveAcceptanceGuards() {
        let simulation = ForceSimulation3D()
        let first = UUID(), second = UUID(), replacement = UUID()
        simulation.addNode(first, project: "p", topic: "t")
        simulation.addNode(second, project: "p", topic: "t")
        let dispatchedOrder = simulation.nodeOrderVersion
        simulation.removeNodes([first])
        simulation.addNode(replacement, project: "p", topic: "t")
        simulation.setPosition(second, to: SIMD3(1, 2, 3))
        simulation.setPosition(replacement, to: SIMD3(4, 5, 6))
        let before = simulation.positions, revision = simulation.positionVersion
        let readback = ForceResult(positions: [SIMD3(10, 20, 30), SIMD3(40, 50, 60)])
        let stale = simulation.applyGPUForces(readback, expectedNodeOrderVersion: dispatchedOrder)
        if case .rejected = stale {} else { XCTAssertTrue(false) }
        XCTAssertTrue(simulation.positions == before)
        XCTAssertTrue(simulation.positionVersion == revision)
        XCTAssertTrue(simulation.topologyDirtyForGPU)
        let short = simulation.applyGPUForces(ForceResult(positions: [SIMD3(99, 99, 99)]),
                                              expectedNodeOrderVersion: simulation.nodeOrderVersion)
        if case .rejected = short {} else { XCTAssertTrue(false) }
        XCTAssertTrue(simulation.positions == before)
        XCTAssertTrue(simulation.positionVersion == revision)
        let applied = simulation.applyGPUForces(readback, expectedNodeOrderVersion: simulation.nodeOrderVersion)
        if case .positionsApplied = applied {} else { XCTAssertTrue(false) }
        XCTAssertTrue(simulation.positions[second] == SIMD3<Float>(10, 20, 30))
        XCTAssertTrue(simulation.positions[replacement] == SIMD3<Float>(40, 50, 60))
        XCTAssertTrue(simulation.positionVersion > revision)
        let acceptedPositions = simulation.positions, acceptedRevision = simulation.positionVersion
        let fallback = simulation.applyGPUForces(ForceResult(fx: [1, 2], fy: [3, 4], fz: [5, 6]))
        if case .rawFallback = fallback {} else { XCTAssertTrue(false) }
        XCTAssertTrue(simulation.positions == acceptedPositions)
        XCTAssertTrue(simulation.positionVersion == acceptedRevision)
        let shortForces = simulation.applyGPUForces(ForceResult(fx: [1], fy: [2], fz: [3]))
        if case .rejected = shortForces {} else { XCTAssertTrue(false) }
        XCTAssertTrue(simulation.positions == acceptedPositions)
        XCTAssertTrue(simulation.positionVersion == acceptedRevision)
    }

    func testOptionalTickTimingFallbackCallsOrdinaryProviderExactlyOnce() {
        let provider = FrameLookupProvider()
        let erased: any SceneDataProvider = provider
        XCTAssertTrue(erased.tickWithTimings(dt: 0.25) == nil)
        XCTAssertTrue(provider.tickDeltas == [0.25])
        erased.tick(dt: 0.5)
        XCTAssertTrue(provider.tickDeltas == [0.25, 0.5])
    }

    private func node(_ id: UUID, _ project: String, topic: String = "topic") -> RKNodeSnapshot {
        RKNodeSnapshot(id: id, project: project, topic: topic, label: project,
                       importance: 1, isHub: false)
    }

    private func edge(_ source: UUID, _ target: UUID) -> RKEdgeSnapshot {
        RKEdgeSnapshot(id: UUID(), sourceId: source, targetId: target, relation: "related")
    }

    func testLightColorsRemainLive() {
        let provider = FrameLookupProvider(), lookup = MascotGraphIndex()
        let id = UUID()
        let red = SIMD3<Float>(1, 0, 0), blue = SIMD3<Float>(0, 0, 1)
        provider.nodes = [node(id, "first"), node(id, "duplicate")]
        provider.projectColorMap = ["first": red, "duplicate": blue]
        for _ in 0..<100 {
            XCTAssertTrue(lookup.projectColor(for: id, dataProvider: provider) == red)
            XCTAssertTrue(lookup.indexByID[id] == 0)
        }
        provider.projectColorMap["first"] = blue
        XCTAssertTrue(lookup.projectColor(for: id, dataProvider: provider) == blue)
        provider.projectColorMap.removeValue(forKey: "first")
        XCTAssertTrue(lookup.projectColor(for: id, dataProvider: provider) == SIMD3<Float>(repeating: 0.5))
        XCTAssertTrue(lookup.projectColor(for: UUID(), dataProvider: provider) == SIMD3<Float>(repeating: 0.5))
    }

    func testLightNodeInvalidation() {
        let provider = FrameLookupProvider(), lookup = MascotGraphIndex()
        let first = UUID(), second = UUID()
        let red = SIMD3<Float>(1, 0, 0), blue = SIMD3<Float>(0, 0, 1)
        provider.projectColorMap = ["A": red, "B": blue]
        provider.nodes = [node(first, "A")]
        XCTAssertTrue(lookup.projectColor(for: first, dataProvider: provider) == red)
        provider.nodes.append(node(second, "B"))
        provider.topologyVersion += 1
        XCTAssertTrue(lookup.projectColor(for: second, dataProvider: provider) == blue)
        provider.nodes = [node(second, "B"), node(first, "B")]
        provider.topologyVersion += 1
        XCTAssertTrue(lookup.projectColor(for: first, dataProvider: provider) == blue)
        XCTAssertTrue(lookup.indexByID[first] == 1)
        provider.nodes.removeLast()
        provider.topologyVersion += 1
        XCTAssertTrue(lookup.projectColor(for: first, dataProvider: provider) == SIMD3<Float>(repeating: 0.5))
        let replacement = FrameLookupProvider()
        replacement.nodes = [node(second, "A")]
        replacement.projectColorMap = provider.projectColorMap
        replacement.topologyVersion = provider.topologyVersion
        XCTAssertTrue(lookup.projectColor(for: second, dataProvider: replacement) == red)
    }

    func testSelectedEdgeDeletion() {
        let provider = FrameLookupProvider(), system = RKFlowParticleSystem()
        let selected = UUID(), target = UUID(), other = UUID()
        provider.selectedNode = selected
        provider.positions = [selected: .zero, target: SIMD3(1, 2, 3)]
        provider.edges = [edge(other, target), edge(selected, target)]
        system.update(dataProvider: provider, dt: 0.4)
        XCTAssertTrue(system.connectedEdgeIndices == [1])
        XCTAssertTrue(system.particles.map(\.edgeIndex) == [1])
        provider.edges.removeFirst()
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 0.4)
        XCTAssertTrue(provider.selectedNode == selected)
        XCTAssertTrue(system.connectedEdgeIndices == [0])
        XCTAssertTrue(system.particles.map(\.edgeIndex) == [0])
        XCTAssertTrue(system.particles.first?.targetPos == SIMD3<Float>(1, 2, 3))
        provider.edges.removeAll()
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 0.4)
        XCTAssertTrue(system.connectedEdgeIndices.isEmpty)
        XCTAssertTrue(system.particles.isEmpty)
    }

    func testSelectedEdgeReorderAndReplacement() {
        let provider = FrameLookupProvider(), system = RKFlowParticleSystem()
        let selected = UUID(), a = UUID(), b = UUID()
        provider.selectedNode = selected
        provider.positions = [selected: .zero, a: SIMD3(1, 0, 0), b: SIMD3(2, 0, 0)]
        provider.edges = [edge(selected, a), edge(a, b)]
        system.update(dataProvider: provider, dt: 0.4)
        provider.edges.reverse()
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 0.4)
        XCTAssertTrue(system.connectedEdgeIndices == [1])
        XCTAssertTrue(system.particles.map(\.edgeIndex) == [1])
        provider.edges[1] = edge(b, selected)
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 0.4)
        XCTAssertTrue(system.particles.count == 1)
        XCTAssertTrue(system.particles.first?.sourcePos == SIMD3<Float>.zero)
        XCTAssertTrue(system.particles.first?.targetPos == SIMD3<Float>(2, 0, 0))
    }

    func testStableFlowAndSelectionChange() {
        let provider = FrameLookupProvider(), system = RKFlowParticleSystem()
        let selected = UUID(), target = UUID()
        provider.selectedNode = selected
        provider.positions = [selected: .zero, target: SIMD3(1, 0, 0)]
        provider.edges = [edge(selected, target)]
        system.update(dataProvider: provider, dt: 0.2)
        XCTAssertTrue(system.particles.isEmpty)
        XCTAssertTrue(provider.positionReads == 0)
        system.update(dataProvider: provider, dt: 0.2)
        XCTAssertTrue(system.particles.count == 1)
        XCTAssertTrue(provider.positionReads == 1)
        let age = system.particles[0].age
        system.update(dataProvider: provider, dt: 0.1)
        XCTAssertTrue(system.particles.count == 1)
        XCTAssertTrue(system.particles[0].age > age)
        XCTAssertTrue(provider.positionReads == 1)
        provider.selectedNode = nil
        system.update(dataProvider: provider, dt: 0.1)
        XCTAssertTrue(system.connectedEdgeIndices.isEmpty)
        XCTAssertTrue(system.particles.isEmpty)
        XCTAssertTrue(provider.positionReads == 1)
        provider.selectedNode = target
        system.update(dataProvider: provider, dt: 0.4)
        XCTAssertTrue(system.particles.first?.sourcePos == SIMD3<Float>(1, 0, 0))
        XCTAssertTrue(system.particles.first?.targetPos == SIMD3<Float>.zero)
        XCTAssertTrue(provider.positionReads == 2)

        // A long frame uses one snapshot for all due batches. Existing particles
        // retain their captured endpoints while aging on non-spawn frames.
        let catchUp = RKFlowParticleSystem()
        catchUp.update(dataProvider: provider, dt: 0.8)
        XCTAssertTrue(provider.positionReads == 3)
        XCTAssertTrue(catchUp.particles.count == 2)
        XCTAssertTrue(catchUp.particles.allSatisfy { $0.age == 0.8 && $0.progress == 0.8 / 1.25 })
        provider.positions = [selected: SIMD3(5, 0, 0), target: SIMD3(7, 0, 0)]
        catchUp.update(dataProvider: provider, dt: 0)
        catchUp.update(dataProvider: provider, dt: 0.1)
        XCTAssertTrue(provider.positionReads == 3)
        XCTAssertTrue(catchUp.particles.count == 2)
        XCTAssertTrue(catchUp.particles.allSatisfy { $0.age > 0.8 && $0.sourcePos == SIMD3<Float>(1, 0, 0) && $0.targetPos == .zero })

        provider.edges = []
        system.update(dataProvider: provider, dt: 2)
        XCTAssertTrue(system.particles.isEmpty)
        XCTAssertTrue(provider.positionReads == 3)
        provider.edges = [edge(UUID(), UUID())]
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 2)
        XCTAssertTrue(system.connectedEdgeIndices.isEmpty)
        XCTAssertTrue(provider.positionReads == 3)
        provider.edges = [edge(selected, target)]
        provider.positions = [:]
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 0.4)
        XCTAssertTrue(system.particles.isEmpty)
        XCTAssertTrue(provider.positionReads == 4)
    }

    func testFlowProviderCountAndCap() {
        let provider = FrameLookupProvider(), system = RKFlowParticleSystem()
        let selected = UUID(), target = UUID()
        provider.selectedNode = selected
        provider.positions = [selected: .zero, target: SIMD3(1, 0, 0)]
        provider.edges = (0..<40).map { _ in edge(selected, target) }
        system.update(dataProvider: provider, dt: 0.4)
        XCTAssertTrue(system.connectedEdgeIndices == Array(0..<30))
        XCTAssertTrue(system.particles.count == 30)
        provider.edges = [provider.edges[0]] // Defensive count guard, even without a revision.
        system.update(dataProvider: provider, dt: 0.4)
        XCTAssertTrue(system.connectedEdgeIndices == [0])
        XCTAssertTrue(system.particles.count == 1)
        provider.edges.append(edge(target, selected))
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 0.4)
        XCTAssertTrue(system.connectedEdgeIndices == [0, 1])
        XCTAssertTrue(system.particles.count == 2)
        let replacement = FrameLookupProvider()
        replacement.selectedNode = selected
        replacement.positions = provider.positions
        replacement.edges = [edge(target, UUID()), edge(target, UUID())]
        replacement.topologyVersion = provider.topologyVersion
        system.update(dataProvider: replacement, dt: 0.4)
        XCTAssertTrue(system.connectedEdgeIndices.isEmpty)
        XCTAssertTrue(system.particles.isEmpty)
    }

    func testLabelMembershipSeparatesDomainsAndExtendsAppendPrefix() {
        let provider = FrameLookupProvider()
        var cache = LabelProjectTopicCache()
        let first = UUID(), second = UUID(), third = UUID()
        provider.explicitNodeVersion = 1
        provider.explicitHubVersion = 1
        provider.explicitAppendGeneration = 1
        provider.nodes = [node(first, "First")]
        let initial = cache.update(provider)
        XCTAssertTrue(initial.projects == Set(["First"]))
        XCTAssertTrue(initial.topics == Set(["topic"]))
        cache.rescanPositions(nodes: provider.nodes, positionArray: [SIMD3(0, 8, 0)], positions: [:])
        let originalTopic = cache.topic(at: 0)
        let visited = cache.nodesVisited, revision = cache.revision

        provider.edges = [edge(first, second)]
        provider.topologyVersion += 1
        provider.hubs = [first]
        provider.explicitHubVersion = 2
        let independent = cache.update(provider)
        XCTAssertTrue(independent.projects == initial.projects)
        XCTAssertTrue(independent.topics == initial.topics)
        XCTAssertTrue(cache.nodesVisited == visited)
        XCTAssertTrue(cache.revision == revision)

        // Two producer publications may arrive before this consumer updates.
        provider.nodes.append(RKNodeSnapshot(id: second, project: "Second", topic: "new topic",
                                            label: "Second", importance: 1, isHub: false))
        provider.explicitNodeVersion = 2
        provider.nodes.append(node(third, "Third"))
        provider.explicitNodeVersion = 3
        let appended = cache.update(provider)
        XCTAssertTrue(appended.projects == Set(["First", "Second", "Third"]))
        XCTAssertTrue(appended.topics == Set(["topic", "new topic"]))
        XCTAssertTrue(initial.projects == Set(["First"]))
        XCTAssertTrue(cache.nodesVisited - visited == 2)
        XCTAssertTrue(cache.revision > revision)
        cache.rescanPositions(nodes: provider.nodes,
                              positionArray: [SIMD3(0, -2, 0), SIMD3(0, 10, 0), SIMD3(0, -4, 0)],
                              positions: [:])
        XCTAssertTrue(cache.maxY(forProject: "First") == -2)
        XCTAssertTrue(cache.maxY(forProject: "Second") == 10)
        XCTAssertTrue(cache.maxY(forProject: "Third") == -4)
        XCTAssertTrue(cache.topicCount == 2)
        XCTAssertTrue(cache.topic(at: 0)?.name == "topic")
        XCTAssertTrue(cache.topic(at: 0)?.sum == SIMD3<Float>(0, -6, 0))
        XCTAssertTrue(cache.topic(at: 0)?.count == 2)
        XCTAssertTrue(cache.topic(at: 0)?.project == "Third")
        XCTAssertTrue(cache.topic(at: 1)?.name == "new topic")
        XCTAssertTrue(cache.topic(at: 1)?.count == 1)
        XCTAssertTrue(originalTopic?.maxY == 8)
    }

    func testLabelMembershipRejectsInvalidContinuity() {
        let provider = FrameLookupProvider()
        var cache = LabelProjectTopicCache()
        let first = UUID(), second = UUID()
        provider.explicitNodeVersion = 1
        provider.explicitAppendGeneration = 1
        provider.nodes = [node(first, "Old"), node(second, "Removed")]
        let initial = cache.update(provider)
        XCTAssertTrue(initial.projects == Set(["Old", "Removed"]))
        cache.rescanPositions(nodes: provider.nodes,
                              positionArray: [SIMD3(0, 10, 0), SIMD3(0, 20, 0)], positions: [:])

        // Same count, different order and metadata: the old set cannot be
        // extended even though the node array did not shrink.
        provider.nodes = [node(second, "Current"), node(first, "Current")]
        provider.explicitNodeVersion = 2
        provider.explicitAppendGeneration = 2
        let edited = cache.update(provider)
        XCTAssertTrue(edited.projects == Set(["Current"]))
        XCTAssertTrue(edited.topics == Set(["topic"]))
        cache.rescanPositions(nodes: provider.nodes,
                              positionArray: [SIMD3(0, 1, 0), SIMD3(0, 2, 0)], positions: [:])
        XCTAssertTrue(cache.maxY(forProject: "Old") == nil)
        XCTAssertTrue(cache.maxY(forProject: "Removed") == nil)
        XCTAssertTrue(cache.maxY(forProject: "Current") == 2)
        XCTAssertTrue(cache.topic(at: 0)?.sum == SIMD3<Float>(0, 3, 0))
        provider.nodes.removeAll()
        provider.explicitNodeVersion = 3
        // Defensive shrink refusal also applies if a producer failed to
        // advance its generation; no stale project/topic survives.
        let emptied = cache.update(provider)
        XCTAssertTrue(emptied.projects.isEmpty)
        XCTAssertTrue(emptied.topics.isEmpty)
        cache.rescanPositions(nodes: [], positionArray: [], positions: [:])
        XCTAssertTrue(cache.topicCount == 0)
        XCTAssertTrue(cache.maxY(forProject: "Current") == nil)

        provider.nodes = [node(first, "Repopulated")]
        provider.explicitNodeVersion = 4
        provider.explicitAppendGeneration = 3
        XCTAssertTrue(cache.update(provider).projects == Set(["Repopulated"]))
        let replacement = FrameLookupProvider()
        replacement.nodes = [RKNodeSnapshot(id: first, project: "Replacement", topic: "replacement topic",
                                             label: "Replacement", importance: 1, isHub: false)]
        replacement.explicitNodeVersion = provider.explicitNodeVersion
        replacement.explicitAppendGeneration = provider.explicitAppendGeneration
        let replaced = cache.update(replacement)
        XCTAssertTrue(replaced.projects == Set(["Replacement"]))
        XCTAssertTrue(replaced.topics == Set(["replacement topic"]))
        cache.rescanPositions(nodes: replacement.nodes, positionArray: [SIMD3(0, -5, 0)], positions: [:])
        XCTAssertTrue(cache.maxY(forProject: "Repopulated") == nil)
        XCTAssertTrue(cache.topicCount == 1)
        XCTAssertTrue(cache.topic(at: 0)?.name == "replacement topic")
        XCTAssertTrue(cache.topic(at: 0)?.project == "Replacement")
        XCTAssertTrue(cache.topic(at: 0)?.maxY == -5)

        // The ordinary conservative provider contract changes generation with
        // topology, so a simultaneous prefix edit and append is fully read.
        let conservative = FrameLookupProvider()
        conservative.nodes = [node(first, "Before")]
        XCTAssertTrue(cache.update(conservative).projects == Set(["Before"]))
        conservative.nodes = [node(first, "After"), node(second, "Appended")]
        conservative.topologyVersion += 1
        let fallback = cache.update(conservative)
        XCTAssertTrue(fallback.projects == Set(["After", "Appended"]))
        XCTAssertTrue(fallback.topics == Set(["topic"]))
    }

    func testLabelNumericRescanFollowsMotion() {
        let provider = FrameLookupProvider()
        var cache = LabelProjectTopicCache()
        provider.nodes = [node(UUID(), "A"), node(UUID(), "B"), node(UUID(), "A", topic: "other")]
        _ = cache.update(provider)
        cache.rescanPositions(nodes: provider.nodes,
                              positionArray: [SIMD3(2, 8, 4), SIMD3(4, 12, 2), SIMD3(0, 3, 0)],
                              positions: [:])
        XCTAssertTrue(cache.maxY(forProject: "A") == 8)
        XCTAssertTrue(cache.maxY(forProject: "B") == 12)
        XCTAssertTrue(cache.topic(at: 0)?.sum == SIMD3<Float>(6, 20, 6))
        XCTAssertTrue(cache.topic(at: 0)?.count == 2)
        XCTAssertTrue(cache.topic(at: 0)?.project == "B")
        XCTAssertTrue(cache.topic(at: 0)?.maxY == 12)
        XCTAssertTrue(cache.topic(at: 1)?.count == 1)
        let visited = cache.nodesVisited, revision = cache.revision

        provider.positionVersion += 1
        _ = cache.update(provider)
        cache.rescanPositions(nodes: provider.nodes,
                              positionArray: [SIMD3(2, -8, 4), SIMD3(4, -12, 2), SIMD3(0, -3, 0)],
                              positions: [:])
        XCTAssertTrue(cache.nodesVisited == visited)
        XCTAssertTrue(cache.revision == revision)
        XCTAssertTrue(cache.maxY(forProject: "A") == -3)
        XCTAssertTrue(cache.maxY(forProject: "B") == -12)
        XCTAssertTrue(cache.topic(at: 0)?.sum == SIMD3<Float>(6, -20, 6))
        XCTAssertTrue(cache.topic(at: 0)?.count == 2)
        XCTAssertTrue(cache.topic(at: 0)?.maxY == -8)
        XCTAssertTrue(cache.topic(at: 1)?.sum == SIMD3<Float>(0, -3, 0))
    }

    func testLabelNumericRescanPreservesMissingPositionSemantics() {
        let provider = FrameLookupProvider()
        var cache = LabelProjectTopicCache()
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        provider.nodes = [node(a, "A"), node(b, "B"), node(c, "C"), node(d, "D", topic: "missing")]
        let membership = cache.update(provider)
        XCTAssertTrue(membership.projects == Set(["A", "B", "C", "D"]))
        cache.rescanPositions(nodes: provider.nodes, positionArray: [.zero],
                              positions: [a: SIMD3(99, 99, 99), b: SIMD3(2, 4, 6)])
        XCTAssertTrue(cache.maxY(forProject: "A") == 0)
        XCTAssertTrue(cache.maxY(forProject: "B") == 4)
        XCTAssertTrue(cache.maxY(forProject: "C") == nil)
        XCTAssertTrue(cache.maxY(forProject: "D") == nil)
        XCTAssertTrue(cache.topic(at: 0)?.sum == SIMD3<Float>(2, 4, 6))
        XCTAssertTrue(cache.topic(at: 0)?.count == 2)
        XCTAssertTrue(cache.topic(at: 0)?.project == "B")
        XCTAssertTrue(cache.topic(at: 1) == nil)

        // The previous last valid node disappears; an absent suffix must not
        // retain its sum, height or color project.
        cache.rescanPositions(nodes: provider.nodes, positionArray: [.zero], positions: [c: SIMD3(3, 6, 9)])
        XCTAssertTrue(cache.maxY(forProject: "B") == nil)
        XCTAssertTrue(cache.topic(at: 0)?.sum == SIMD3<Float>(3, 6, 9))
        XCTAssertTrue(cache.topic(at: 0)?.project == "C")
        XCTAssertTrue(cache.topic(at: 0)?.maxY == 6)

        cache.rescanPositions(nodes: provider.nodes, positionArray: [.zero, .zero, .zero, .zero], positions: [:])
        XCTAssertTrue(cache.topic(at: 0)?.count == 3)
        XCTAssertTrue(cache.topic(at: 0)?.sum == SIMD3<Float>.zero)
        XCTAssertTrue(cache.topic(at: 0)?.project == "C")
        XCTAssertTrue(cache.topic(at: 1)?.count == 1)
        XCTAssertTrue(cache.maxY(forProject: "D") == 0)
        cache.rescanPositions(nodes: provider.nodes, positionArray: [], positions: [:])
        XCTAssertTrue(cache.topicCount == 2) // Atlas membership includes unpositioned nodes.
        XCTAssertTrue(cache.topic(at: 0) == nil)
        XCTAssertTrue(cache.topic(at: 1) == nil)
        XCTAssertTrue(cache.maxY(forProject: "A") == nil)
    }

    func testLabelNumericSlotsFollowReorderAndTopicChanges() {
        let provider = FrameLookupProvider()
        var cache = LabelProjectTopicCache()
        let a = UUID(), b = UUID()
        provider.nodes = [node(a, "A"), node(b, "B")]
        _ = cache.update(provider)
        cache.rescanPositions(nodes: provider.nodes, positionArray: [],
                              positions: [a: SIMD3(1, 2, 3), b: SIMD3(4, 5, 6)])
        XCTAssertTrue(cache.topic(at: 0)?.project == "B")
        provider.nodes.reverse()
        provider.topologyVersion += 1
        _ = cache.update(provider)
        cache.rescanPositions(nodes: provider.nodes, positionArray: [],
                              positions: [a: SIMD3(1, 2, 3), b: SIMD3(4, 5, 6)])
        XCTAssertTrue(cache.topic(at: 0)?.project == "A")
        XCTAssertTrue(cache.topic(at: 0)?.sum == SIMD3<Float>(5, 7, 9))

        provider.nodes = [node(b, "Changed", topic: "new"), node(a, "Changed", topic: "new")]
        provider.topologyVersion += 1
        _ = cache.update(provider)
        cache.rescanPositions(nodes: provider.nodes, positionArray: [],
                              positions: [a: SIMD3(1, -2, 3), b: SIMD3(4, -5, 6)])
        XCTAssertTrue(cache.maxY(forProject: "A") == nil)
        XCTAssertTrue(cache.maxY(forProject: "B") == nil)
        XCTAssertTrue(cache.maxY(forProject: "Changed") == -2)
        XCTAssertTrue(cache.topicCount == 1)
        XCTAssertTrue(cache.topic(at: 0)?.name == "new")
        XCTAssertTrue(cache.topic(at: 0)?.project == "Changed")
        XCTAssertTrue(cache.topic(at: 0)?.sum == SIMD3<Float>(5, -7, 9))
        XCTAssertTrue(cache.topic(at: 0)?.count == 2)
    }
}
