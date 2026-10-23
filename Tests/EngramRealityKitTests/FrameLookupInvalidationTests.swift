import Foundation
import Testing
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
    var insertionReuse: NodeInsertionReuse?
    func nodeInsertionReuse(since version: UInt64, count: Int) -> NodeInsertionReuse? { insertionReuse }
    private(set) var tickDeltas: [Float] = []
    func tick(dt: Float) { tickDeltas.append(dt) }
}

@MainActor
private final class SparsePositionProvider: SceneDataProvider {
    var nodes: [RKNodeSnapshot] = []
    var edges: [RKEdgeSnapshot] = []
    var hubs: Set<UUID> = []
    var projectColorMap: [String: SIMD3<Float>] = [:]
    var storedPositions: [UUID: SIMD3<Float>] = [:]
    private(set) var positionReads = 0
    private(set) var requestedIDs: [UUID] = []
    var positions: [UUID: SIMD3<Float>] {
        positionReads += 1
        return storedPositions
    }
    func position(for id: UUID) -> SIMD3<Float>? {
        requestedIDs.append(id)
        return storedPositions[id]
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
    func tick(dt: Float) {}
}

@Suite("Frame lookup invalidation")
@MainActor
struct FrameLookupInvalidationTests {
    @Test("Frame gaps distinguish startup, previous logger tail and drained work")
    func frameGapIntervalsTailAndDrain() {
        let diagnostics = FrameGapDiagnostics(enabled: true), owner = NSObject()
        diagnostics.recordLoad(rows: 4, accepted: true, queuedAt: 50, startedAt: 60, endedAt: 70)
        let first = diagnostics.beginCallback(owner: owner, at: 100)
        #expect(first?.sequence == 1)
        #expect(first?.previousSequence == 0)
        #expect(first?.hasPreviousCallback == false)
        #expect(first?.entryIntervalNanoseconds == 0)
        #expect(first?.outsideCallbackNanoseconds == 0)
        #expect(first?.previousLoggerTailNanoseconds == 0)
        #expect(first?.load.rows == 4)
        diagnostics.finishCallback(owner: owner, bodyEndedAt: 140, exitedAt: 155)
        diagnostics.recordLoad(rows: 2, accepted: false, queuedAt: nil, startedAt: 170, endedAt: 180)
        diagnostics.recordForce(outcome: .positionsApplied, queuedAt: 160, startedAt: 180, endedAt: 190)
        let second = diagnostics.beginCallback(owner: owner, at: 200)
        #expect(second?.sequence == 2)
        #expect(second?.previousSequence == 1)
        #expect(second?.hasPreviousCallback == true)
        #expect(second?.entryIntervalNanoseconds == 100)
        #expect(second?.outsideCallbackNanoseconds == 45)
        #expect(second?.previousLoggerTailNanoseconds == 15)
        #expect(second?.load.count == 1)
        #expect(second?.load.rows == 2)
        #expect(second?.load.rejectedCount == 1)
        #expect(second?.force.acceptedCount == 1)
        // A missing/invalid exit cannot manufacture a complete interval.
        diagnostics.finishCallback(owner: owner, bodyEndedAt: 199, exitedAt: 220)
        let incomplete = diagnostics.beginCallback(owner: owner, at: 250)
        #expect(incomplete?.hasPreviousCallback == false)
        #expect(incomplete?.previousSequence == 0)
        #expect(incomplete?.entryIntervalNanoseconds == 0)
        #expect(incomplete?.outsideCallbackNanoseconds == 0)
        #expect(incomplete?.previousLoggerTailNanoseconds == 0)
        #expect(incomplete?.load.count == 0)
        #expect(incomplete?.load.durationNanoseconds == 0)
        #expect(incomplete?.load.maximumDurationNanoseconds == 0)
        #expect(incomplete?.force.count == 0)
        #expect(incomplete?.force.queueSamples == 0)
        // Earlier samples are values; subsequent draining does not erase them.
        #expect(first?.load.rows == 4)
        #expect(second?.force.acceptedCount == 1)
    }

    @Test("A second scene cannot steal counters and replacement loses prior timing")
    func frameGapOwnershipDoesNotStealAndResetsAfterRelease() {
        let diagnostics = FrameGapDiagnostics(enabled: true), other = NSObject()
        var owner: NSObject? = NSObject()
        weak var observedOwner: NSObject? = owner
        _ = diagnostics.beginCallback(owner: owner!, at: 100)
        diagnostics.finishCallback(owner: owner!, bodyEndedAt: 130, exitedAt: 140)
        diagnostics.recordLoad(rows: 7, accepted: true, queuedAt: 150, startedAt: 160, endedAt: 170)
        #expect(diagnostics.beginCallback(owner: other, at: 180) == nil)
        diagnostics.finishCallback(owner: other, bodyEndedAt: 181, exitedAt: 190)
        let retained = diagnostics.beginCallback(owner: owner!, at: 200)
        #expect(retained?.sequence == 2)
        #expect(retained?.previousSequence == 1)
        #expect(retained?.outsideCallbackNanoseconds == 60)
        #expect(retained?.previousLoggerTailNanoseconds == 10)
        #expect(retained?.load.count == 1)
        #expect(retained?.load.rows == 7)
        diagnostics.finishCallback(owner: owner!, bodyEndedAt: 220, exitedAt: 230)
        diagnostics.recordForce(outcome: .rejected, queuedAt: nil, startedAt: 240, endedAt: 245)
        owner = nil
        #expect(observedOwner == nil)
        let replacement = diagnostics.beginCallback(owner: other, at: 300)
        #expect(replacement?.sequence == 3)
        #expect(replacement?.previousSequence == 0)
        #expect(replacement?.hasPreviousCallback == false)
        #expect(replacement?.entryIntervalNanoseconds == 0)
        #expect(replacement?.outsideCallbackNanoseconds == 0)
        #expect(replacement?.previousLoggerTailNanoseconds == 0)
        #expect(replacement?.force.rejectedCount == 1)
        #expect(replacement?.load.count == 0)
    }

    @Test("Gap work keeps exact outcomes, unknown queue stamps and saturating totals")
    func frameGapWorkAggregatesAndSaturates() {
        let diagnostics = FrameGapDiagnostics(enabled: true), owner = NSObject()
        diagnostics.recordLoad(rows: 2, accepted: true, queuedAt: 10, startedAt: 20, endedAt: 50)
        diagnostics.recordLoad(rows: 3, accepted: false, queuedAt: nil, startedAt: 40, endedAt: 45)
        diagnostics.recordLoad(rows: 4, accepted: true, queuedAt: 100, startedAt: 60, endedAt: 70)
        diagnostics.recordForce(outcome: .positionsApplied, queuedAt: 15, startedAt: 20, endedAt: 30)
        diagnostics.recordForce(outcome: .rejected, queuedAt: nil, startedAt: 40, endedAt: 60)
        diagnostics.recordForce(outcome: .rawFallback, queuedAt: 30, startedAt: 30, endedAt: 34)
        let sample = diagnostics.beginCallback(owner: owner, at: 100)
        #expect(sample?.load.count == 3)
        #expect(sample?.load.acceptedCount == 2)
        #expect(sample?.load.rejectedCount == 1)
        #expect(sample?.load.rows == 9)
        #expect(sample?.load.durationNanoseconds == 45)
        #expect(sample?.load.maximumDurationNanoseconds == 30)
        #expect(sample?.load.queueSamples == 1)
        #expect(sample?.load.queueNanoseconds == 10)
        #expect(sample?.load.maximumQueueNanoseconds == 10)
        #expect(sample?.force.count == 3)
        #expect(sample?.force.acceptedCount == 1)
        #expect(sample?.force.rejectedCount == 1)
        #expect(sample?.force.fallbackCount == 1)
        #expect(sample?.force.durationNanoseconds == 34)
        #expect(sample?.force.maximumDurationNanoseconds == 20)
        #expect(sample?.force.queueSamples == 2)
        #expect(sample?.force.queueNanoseconds == 5)
        #expect(sample?.force.maximumQueueNanoseconds == 5)

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
        #expect(columns.count == 24)
        #expect(Set(columns).count == columns.count)
        #expect(firstValues.count == columns.count)
        let firstFields = Dictionary(uniqueKeysWithValues: zip(columns, firstValues))
        #expect(firstFields["gap_flags"] == "1")
        #expect(firstFields["load_count"] == "1")
        #expect(firstFields["load_accepted"] == "1")
        #expect(firstFields["load_rows"] == "2")
        #expect(firstFields["load_apply_ms"] == "5.000")
        #expect(firstFields["load_apply_max_ms"] == "5.000")
        #expect(firstFields["load_queue_samples"] == "1")
        #expect(firstFields["load_queue_ms"] == "2.000")
        #expect(firstFields["force_raw_fallback"] == "1")
        #expect(firstFields["force_applied"] == "0")
        #expect(firstFields["force_apply_ms"] == "3.000")
        #expect(firstFields["force_queue_samples"] == "0")
        csv.finishCallback(owner: owner, bodyEndedAt: 30_000_000, exitedAt: 32_000_000)
        let csvSecond = csv.beginCallback(owner: owner, at: 50_000_000)
        let nextValues = FrameGapDiagnostics.csvValues(csvSecond).components(separatedBy: ",")
        #expect(nextValues.count == columns.count)
        let nextFields = Dictionary(uniqueKeysWithValues: zip(columns, nextValues))
        #expect(nextFields["gap_flags"] == "3")
        #expect(nextFields["gap_callback"] == "2")
        #expect(nextFields["gap_previous_callback"] == "1")
        #expect(nextFields["callback_entry_dt_ms"] == "30.000")
        #expect(nextFields["callback_outside_ms"] == "18.000")
        #expect(nextFields["previous_logger_tail_ms"] == "2.000")
        #expect(nextFields["load_count"] == "0")
        #expect(nextFields["force_apply_count"] == "0")

        diagnostics.recordLoad(rows: Int.max, accepted: true, queuedAt: nil, startedAt: 0, endedAt: .max)
        diagnostics.recordLoad(rows: Int.max, accepted: true, queuedAt: nil, startedAt: 0, endedAt: .max)
        diagnostics.recordLoad(rows: Int.max, accepted: false, queuedAt: 0, startedAt: .max, endedAt: .max)
        diagnostics.recordLoad(rows: -1, accepted: false, queuedAt: 0, startedAt: .max, endedAt: .max)
        let saturated = diagnostics.beginCallback(owner: owner, at: .max)
        #expect(saturated?.load.count == 4)
        #expect(saturated?.load.rows == UInt64.max)
        #expect(saturated?.load.durationNanoseconds == UInt64.max)
        #expect(saturated?.load.maximumDurationNanoseconds == UInt64.max)
        #expect(saturated?.load.queueSamples == 2)
        #expect(saturated?.load.queueNanoseconds == UInt64.max)
        #expect(saturated?.load.maximumQueueNanoseconds == UInt64.max)
        #expect(saturated?.force.count == 0)
    }

    @Test("Disabled gap diagnostics never invoke the supplied clock or emit a sample")
    func frameGapDisabledPathDoesNotReadClock() {
        #expect(FrameGapDiagnostics.enabled(forPath: nil) == false)
        #expect(FrameGapDiagnostics.enabled(forPath: "") == false)
        #expect(FrameGapDiagnostics.enabled(forPath: "/owned/frame.csv") == true)
        var clockReads = 0
        let disabledStamp = FrameGapDiagnostics.timestamp(enabled: false) { clockReads += 1; return 42 }
        #expect(disabledStamp == nil)
        #expect(clockReads == 0)
        let enabledStamp = FrameGapDiagnostics.timestamp(enabled: true) { clockReads += 1; return 42 }
        #expect(enabledStamp == 42)
        #expect(clockReads == 1)
        let diagnostics = FrameGapDiagnostics(enabled: false), owner = NSObject()
        diagnostics.recordLoad(rows: 50, accepted: true, queuedAt: 1, startedAt: 2, endedAt: 3)
        diagnostics.recordForce(outcome: .positionsApplied, queuedAt: 1, startedAt: 2, endedAt: 3)
        #expect(diagnostics.beginCallback(owner: owner, at: 4) == nil)
        diagnostics.finishCallback(owner: owner, bodyEndedAt: 5, exitedAt: 6)
        #expect(diagnostics.beginCallback(owner: owner, at: 7) == nil)
        let unavailable = FrameGapDiagnostics.csvValues(nil).components(separatedBy: ",")
        #expect(unavailable.count == FrameGapDiagnostics.csvHeader.components(separatedBy: ",").count)
        #expect(unavailable.allSatisfy { $0 == "0" })
    }

    @Test("Gap force outcomes preserve stale ordering, count guards and actual position writes")
    func frameGapForceOutcomesPreserveAcceptanceGuards() {
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
        if case .rejected = stale {} else { #expect(false) }
        #expect(simulation.positions == before)
        #expect(simulation.positionVersion == revision)
        #expect(simulation.topologyDirtyForGPU)
        let short = simulation.applyGPUForces(ForceResult(positions: [SIMD3(99, 99, 99)]),
                                              expectedNodeOrderVersion: simulation.nodeOrderVersion)
        if case .rejected = short {} else { #expect(false) }
        #expect(simulation.positions == before)
        #expect(simulation.positionVersion == revision)
        let applied = simulation.applyGPUForces(readback, expectedNodeOrderVersion: simulation.nodeOrderVersion)
        if case .positionsApplied = applied {} else { #expect(false) }
        #expect(simulation.positions[second] == SIMD3<Float>(10, 20, 30))
        #expect(simulation.positions[replacement] == SIMD3<Float>(40, 50, 60))
        #expect(simulation.positionVersion > revision)
        let acceptedPositions = simulation.positions, acceptedRevision = simulation.positionVersion
        let fallback = simulation.applyGPUForces(ForceResult(fx: [1, 2], fy: [3, 4], fz: [5, 6]))
        if case .rawFallback = fallback {} else { #expect(false) }
        #expect(simulation.positions == acceptedPositions)
        #expect(simulation.positionVersion == acceptedRevision)
        let shortForces = simulation.applyGPUForces(ForceResult(fx: [1], fy: [2], fz: [3]))
        if case .rejected = shortForces {} else { #expect(false) }
        #expect(simulation.positions == acceptedPositions)
        #expect(simulation.positionVersion == acceptedRevision)
    }

    @Test("Optional timing fallback calls the ordinary provider exactly once")
    func optionalTickTimingFallbackCallsOrdinaryProviderExactlyOnce() {
        let provider = FrameLookupProvider()
        let erased: any SceneDataProvider = provider
        #expect(erased.tickWithTimings(dt: 0.25) == nil)
        #expect(provider.tickDeltas == [0.25])
        erased.tick(dt: 0.5)
        #expect(provider.tickDeltas == [0.25, 0.5])
    }

    @Test("Sparse position fallback preserves live and missing dictionary values")
    func sparsePositionFallbackPreservesDictionarySemantics() {
        let provider = FrameLookupProvider(), id = UUID(), missing = UUID()
        let erased: any SceneDataProvider = provider
        #expect(erased.position(for: id) == nil)
        provider.positions = [id: SIMD3(1, 2, 3)]
        #expect(erased.position(for: id) == SIMD3<Float>(1, 2, 3))
        provider.positions = [id: SIMD3(4, 5, 6)]
        #expect(erased.position(for: id) == SIMD3<Float>(4, 5, 6))
        #expect(erased.position(for: missing) == nil)
        provider.positions = [:]
        #expect(erased.position(for: id) == nil)
        #expect(provider.positionReads == 5)
    }

    @Test("Audio selection reads only near positions regardless of graph size")
    func sparseAudioPositionsScaleWithNearCandidates() {
        for count in [3, 50_000] {
            let provider = SparsePositionProvider()
            provider.nodes = (0..<count).map { _ in node(UUID(), "project") }
            let ids = provider.nodes.prefix(3).map(\.id)
            provider.storedPositions = [ids[0]: SIMD3(30, 0, 0), ids[2]: SIMD3(3, 4, 0)]
            let erased: any SceneDataProvider = provider
            #expect(RKSpatialAudioSystem.proximityCandidates(
                nodes: provider.nodes, dataProvider: erased, nearNodes: [], cameraPosition: .zero).isEmpty)
            #expect(provider.requestedIDs.isEmpty)
            let first = RKSpatialAudioSystem.proximityCandidates(
                nodes: provider.nodes, dataProvider: erased, nearNodes: [0, 1, 2], cameraPosition: .zero)
            #expect(first.map(\.index) == [2, 0])
            #expect(first.map(\.distance) == [5, 30])
            #expect(provider.requestedIDs == ids)
            #expect(provider.positionReads == 0)

            // Resolve live coordinates and omissions through the existential;
            // neither a previous selection nor a whole-map snapshot is reused.
            provider.storedPositions = [ids[0]: SIMD3(1, 0, 0)]
            let moved = RKSpatialAudioSystem.proximityCandidates(
                nodes: provider.nodes, dataProvider: erased, nearNodes: [0, 1, 2], cameraPosition: SIMD3(2, 0, 0))
            #expect(moved.map(\.index) == [0])
            #expect(moved.map(\.distance) == [1])
            #expect(provider.requestedIDs == ids + ids)
            #expect(erased.position(for: ids[2]) == nil)
            #expect(provider.positionReads == 0)
            provider.nodes = []
            #expect(RKSpatialAudioSystem.proximityCandidates(
                nodes: provider.nodes, dataProvider: erased, nearNodes: [], cameraPosition: .zero).isEmpty)
            #expect(provider.requestedIDs.count == 7)
            #expect(provider.positionReads == 0)
        }
    }

    private func node(_ id: UUID, _ project: String, topic: String = "topic") -> RKNodeSnapshot {
        RKNodeSnapshot(id: id, project: project, topic: topic, label: project,
                       importance: 1, isHub: false)
    }

    private func edge(_ source: UUID, _ target: UUID) -> RKEdgeSnapshot {
        RKEdgeSnapshot(id: UUID(), sourceId: source, targetId: target, relation: "related")
    }

    @Test("Stable light lookups preserve first-match and live palette behavior")
    func lightColorsRemainLive() {
        let provider = FrameLookupProvider(), lookup = MascotGraphIndex()
        let id = UUID()
        let red = SIMD3<Float>(1, 0, 0), blue = SIMD3<Float>(0, 0, 1)
        provider.nodes = [node(id, "first"), node(id, "duplicate")]
        provider.projectColorMap = ["first": red, "duplicate": blue]
        for _ in 0..<100 {
            #expect(lookup.projectColor(for: id, dataProvider: provider) == red)
            #expect(lookup.indexByID[id] == 0)
        }
        provider.projectColorMap["first"] = blue
        #expect(lookup.projectColor(for: id, dataProvider: provider) == blue)
        provider.projectColorMap.removeValue(forKey: "first")
        #expect(lookup.projectColor(for: id, dataProvider: provider) == SIMD3<Float>(repeating: 0.5))
        #expect(lookup.projectColor(for: UUID(), dataProvider: provider) == SIMD3<Float>(repeating: 0.5))
    }

    @Test("Light lookup follows append, edits, deletion, reorder and provider replacement")
    func lightNodeInvalidation() {
        let provider = FrameLookupProvider(), lookup = MascotGraphIndex()
        let first = UUID(), second = UUID()
        let red = SIMD3<Float>(1, 0, 0), blue = SIMD3<Float>(0, 0, 1)
        provider.projectColorMap = ["A": red, "B": blue]
        provider.nodes = [node(first, "A")]
        #expect(lookup.projectColor(for: first, dataProvider: provider) == red)
        provider.nodes.append(node(second, "B"))
        provider.topologyVersion += 1
        #expect(lookup.projectColor(for: second, dataProvider: provider) == blue)
        provider.nodes = [node(second, "B"), node(first, "B")]
        provider.topologyVersion += 1
        #expect(lookup.projectColor(for: first, dataProvider: provider) == blue)
        #expect(lookup.indexByID[first] == 1)
        provider.nodes.removeLast()
        provider.topologyVersion += 1
        #expect(lookup.projectColor(for: first, dataProvider: provider) == SIMD3<Float>(repeating: 0.5))
        let replacement = FrameLookupProvider()
        replacement.nodes = [node(second, "A")]
        replacement.projectColorMap = provider.projectColorMap
        replacement.topologyVersion = provider.topologyVersion
        #expect(lookup.projectColor(for: second, dataProvider: replacement) == red)
    }

    @Test("Deleting an edge preserves selection and discards obsolete particle offsets")
    func selectedEdgeDeletion() {
        let provider = FrameLookupProvider(), system = RKFlowParticleSystem()
        let selected = UUID(), target = UUID(), other = UUID()
        provider.selectedNode = selected
        provider.positions = [selected: .zero, target: SIMD3(1, 2, 3)]
        provider.edges = [edge(other, target), edge(selected, target)]
        system.update(dataProvider: provider, dt: 0.4)
        #expect(system.connectedEdgeIndices == [1])
        #expect(system.particles.map(\.edgeIndex) == [1])
        provider.edges.removeFirst()
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 0.4)
        #expect(provider.selectedNode == selected)
        #expect(system.connectedEdgeIndices == [0])
        #expect(system.particles.map(\.edgeIndex) == [0])
        #expect(system.particles.first?.targetPos == SIMD3<Float>(1, 2, 3))
        provider.edges.removeAll()
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 0.4)
        #expect(system.connectedEdgeIndices.isEmpty)
        #expect(system.particles.isEmpty)
    }

    @Test("Same-count edge reorder and replacement refresh a retained selection")
    func selectedEdgeReorderAndReplacement() {
        let provider = FrameLookupProvider(), system = RKFlowParticleSystem()
        let selected = UUID(), a = UUID(), b = UUID()
        provider.selectedNode = selected
        provider.positions = [selected: .zero, a: SIMD3(1, 0, 0), b: SIMD3(2, 0, 0)]
        provider.edges = [edge(selected, a), edge(a, b)]
        system.update(dataProvider: provider, dt: 0.4)
        provider.edges.reverse()
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 0.4)
        #expect(system.connectedEdgeIndices == [1])
        #expect(system.particles.map(\.edgeIndex) == [1])
        provider.edges[1] = edge(b, selected)
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 0.4)
        #expect(system.particles.count == 1)
        #expect(system.particles.first?.sourcePos == SIMD3<Float>.zero)
        #expect(system.particles.first?.targetPos == SIMD3<Float>(2, 0, 0))
    }

    @Test("Unchanged frames retain spawn progress and selection changes reset it")
    func stableFlowAndSelectionChange() {
        let provider = FrameLookupProvider(), system = RKFlowParticleSystem()
        let selected = UUID(), target = UUID()
        provider.selectedNode = selected
        provider.positions = [selected: .zero, target: SIMD3(1, 0, 0)]
        provider.edges = [edge(selected, target)]
        system.update(dataProvider: provider, dt: 0.2)
        #expect(system.particles.isEmpty)
        #expect(provider.positionReads == 0)
        system.update(dataProvider: provider, dt: 0.2)
        #expect(system.particles.count == 1)
        #expect(provider.positionReads == 1)
        let age = system.particles[0].age
        system.update(dataProvider: provider, dt: 0.1)
        #expect(system.particles.count == 1)
        #expect(system.particles[0].age > age)
        #expect(provider.positionReads == 1)
        provider.selectedNode = nil
        system.update(dataProvider: provider, dt: 0.1)
        #expect(system.connectedEdgeIndices.isEmpty)
        #expect(system.particles.isEmpty)
        #expect(provider.positionReads == 1)
        provider.selectedNode = target
        system.update(dataProvider: provider, dt: 0.4)
        #expect(system.particles.first?.sourcePos == SIMD3<Float>(1, 0, 0))
        #expect(system.particles.first?.targetPos == SIMD3<Float>.zero)
        #expect(provider.positionReads == 2)

        // A long frame uses one snapshot for all due batches. Existing particles
        // retain their captured endpoints while aging on non-spawn frames.
        let catchUp = RKFlowParticleSystem()
        catchUp.update(dataProvider: provider, dt: 0.8)
        #expect(provider.positionReads == 3)
        #expect(catchUp.particles.count == 2)
        #expect(catchUp.particles.allSatisfy { $0.age == 0.8 && $0.progress == 0.8 / 1.25 })
        provider.positions = [selected: SIMD3(5, 0, 0), target: SIMD3(7, 0, 0)]
        catchUp.update(dataProvider: provider, dt: 0)
        catchUp.update(dataProvider: provider, dt: 0.1)
        #expect(provider.positionReads == 3)
        #expect(catchUp.particles.count == 2)
        #expect(catchUp.particles.allSatisfy { $0.age > 0.8 && $0.sourcePos == SIMD3<Float>(1, 0, 0) && $0.targetPos == .zero })

        provider.edges = []
        system.update(dataProvider: provider, dt: 2)
        #expect(system.particles.isEmpty)
        #expect(provider.positionReads == 3)
        provider.edges = [edge(UUID(), UUID())]
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 2)
        #expect(system.connectedEdgeIndices.isEmpty)
        #expect(provider.positionReads == 3)
        provider.edges = [edge(selected, target)]
        provider.positions = [:]
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 0.4)
        #expect(system.particles.isEmpty)
        #expect(provider.positionReads == 4)
    }

    @Test("Provider/count changes invalidate offsets and keep the thirty-edge cap")
    func flowProviderCountAndCap() {
        let provider = FrameLookupProvider(), system = RKFlowParticleSystem()
        let selected = UUID(), target = UUID()
        provider.selectedNode = selected
        provider.positions = [selected: .zero, target: SIMD3(1, 0, 0)]
        provider.edges = (0..<40).map { _ in edge(selected, target) }
        system.update(dataProvider: provider, dt: 0.4)
        #expect(system.connectedEdgeIndices == Array(0..<30))
        #expect(system.particles.count == 30)
        provider.edges = [provider.edges[0]] // Defensive count guard, even without a revision.
        system.update(dataProvider: provider, dt: 0.4)
        #expect(system.connectedEdgeIndices == [0])
        #expect(system.particles.count == 1)
        provider.edges.append(edge(target, selected))
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 0.4)
        #expect(system.connectedEdgeIndices == [0, 1])
        #expect(system.particles.count == 2)
        let replacement = FrameLookupProvider()
        replacement.selectedNode = selected
        replacement.positions = provider.positions
        replacement.edges = [edge(target, UUID()), edge(target, UUID())]
        replacement.topologyVersion = provider.topologyVersion
        system.update(dataProvider: replacement, dt: 0.4)
        #expect(system.connectedEdgeIndices.isEmpty)
        #expect(system.particles.isEmpty)
    }

    @Test("Label membership reuses independent edge and hub changes and extends certified appends")
    func labelMembershipSeparatesDomainsAndExtendsAppendPrefix() {
        let provider = FrameLookupProvider()
        var cache = LabelProjectTopicCache()
        let first = UUID(), second = UUID(), third = UUID()
        provider.explicitNodeVersion = 1
        provider.explicitHubVersion = 1
        provider.explicitAppendGeneration = 1
        provider.nodes = [node(first, "First")]
        let initial = cache.update(provider)
        #expect(initial.projects == Set(["First"]))
        #expect(initial.topics == Set(["topic"]))
        cache.rescanPositions(nodes: provider.nodes, positionArray: [SIMD3(0, 8, 0)], positions: [:])
        let originalTopic = cache.topic(at: 0)
        let visited = cache.nodesVisited, revision = cache.revision

        provider.edges = [edge(first, second)]
        provider.topologyVersion += 1
        provider.hubs = [first]
        provider.explicitHubVersion = 2
        let independent = cache.update(provider)
        #expect(independent.projects == initial.projects)
        #expect(independent.topics == initial.topics)
        #expect(cache.nodesVisited == visited)
        #expect(cache.revision == revision)

        // Two producer publications may arrive before this consumer updates.
        provider.nodes.append(RKNodeSnapshot(id: second, project: "Second", topic: "new topic",
                                            label: "Second", importance: 1, isHub: false))
        provider.explicitNodeVersion = 2
        provider.nodes.append(node(third, "Third"))
        provider.explicitNodeVersion = 3
        let appended = cache.update(provider)
        #expect(appended.projects == Set(["First", "Second", "Third"]))
        #expect(appended.topics == Set(["topic", "new topic"]))
        #expect(initial.projects == Set(["First"]))
        #expect(cache.nodesVisited - visited == 2)
        #expect(cache.revision > revision)
        cache.rescanPositions(nodes: provider.nodes,
                              positionArray: [SIMD3(0, -2, 0), SIMD3(0, 10, 0), SIMD3(0, -4, 0)],
                              positions: [:])
        #expect(cache.maxY(forProject: "First") == -2)
        #expect(cache.maxY(forProject: "Second") == 10)
        #expect(cache.maxY(forProject: "Third") == -4)
        #expect(cache.topicCount == 2)
        #expect(cache.topic(at: 0)?.name == "topic")
        #expect(cache.topic(at: 0)?.sum == SIMD3<Float>(0, -6, 0))
        #expect(cache.topic(at: 0)?.count == 2)
        #expect(cache.topic(at: 0)?.project == "Third")
        #expect(cache.topic(at: 1)?.name == "new topic")
        #expect(cache.topic(at: 1)?.count == 1)
        #expect(originalTopic?.maxY == 8)
    }

    @Test("Label membership drops stale values after edits, shrink and provider replacement")
    func labelMembershipRejectsInvalidContinuity() {
        let provider = FrameLookupProvider()
        var cache = LabelProjectTopicCache()
        let first = UUID(), second = UUID()
        provider.explicitNodeVersion = 1
        provider.explicitAppendGeneration = 1
        provider.nodes = [node(first, "Old"), node(second, "Removed")]
        let initial = cache.update(provider)
        #expect(initial.projects == Set(["Old", "Removed"]))
        cache.rescanPositions(nodes: provider.nodes,
                              positionArray: [SIMD3(0, 10, 0), SIMD3(0, 20, 0)], positions: [:])

        // Same count, different order and metadata: the old set cannot be
        // extended even though the node array did not shrink.
        provider.nodes = [node(second, "Current"), node(first, "Current")]
        provider.explicitNodeVersion = 2
        provider.explicitAppendGeneration = 2
        let edited = cache.update(provider)
        #expect(edited.projects == Set(["Current"]))
        #expect(edited.topics == Set(["topic"]))
        cache.rescanPositions(nodes: provider.nodes,
                              positionArray: [SIMD3(0, 1, 0), SIMD3(0, 2, 0)], positions: [:])
        #expect(cache.maxY(forProject: "Old") == nil)
        #expect(cache.maxY(forProject: "Removed") == nil)
        #expect(cache.maxY(forProject: "Current") == 2)
        #expect(cache.topic(at: 0)?.sum == SIMD3<Float>(0, 3, 0))
        provider.nodes.removeAll()
        provider.explicitNodeVersion = 3
        // Defensive shrink refusal also applies if a producer failed to
        // advance its generation; no stale project/topic survives.
        let emptied = cache.update(provider)
        #expect(emptied.projects.isEmpty)
        #expect(emptied.topics.isEmpty)
        cache.rescanPositions(nodes: [], positionArray: [], positions: [:])
        #expect(cache.topicCount == 0)
        #expect(cache.maxY(forProject: "Current") == nil)

        provider.nodes = [node(first, "Repopulated")]
        provider.explicitNodeVersion = 4
        provider.explicitAppendGeneration = 3
        #expect(cache.update(provider).projects == Set(["Repopulated"]))
        let replacement = FrameLookupProvider()
        replacement.nodes = [RKNodeSnapshot(id: first, project: "Replacement", topic: "replacement topic",
                                             label: "Replacement", importance: 1, isHub: false)]
        replacement.explicitNodeVersion = provider.explicitNodeVersion
        replacement.explicitAppendGeneration = provider.explicitAppendGeneration
        let replaced = cache.update(replacement)
        #expect(replaced.projects == Set(["Replacement"]))
        #expect(replaced.topics == Set(["replacement topic"]))
        cache.rescanPositions(nodes: replacement.nodes, positionArray: [SIMD3(0, -5, 0)], positions: [:])
        #expect(cache.maxY(forProject: "Repopulated") == nil)
        #expect(cache.topicCount == 1)
        #expect(cache.topic(at: 0)?.name == "replacement topic")
        #expect(cache.topic(at: 0)?.project == "Replacement")
        #expect(cache.topic(at: 0)?.maxY == -5)

        // The ordinary conservative provider contract changes generation with
        // topology, so a simultaneous prefix edit and append is fully read.
        let conservative = FrameLookupProvider()
        conservative.nodes = [node(first, "Before")]
        #expect(cache.update(conservative).projects == Set(["Before"]))
        conservative.nodes = [node(first, "After"), node(second, "Appended")]
        conservative.topologyVersion += 1
        let fallback = cache.update(conservative)
        #expect(fallback.projects == Set(["After", "Appended"]))
        #expect(fallback.topics == Set(["topic"]))
    }

    @Test("Label numeric rescans refresh moving sums and downward maxima without revisiting metadata")
    func labelNumericRescanFollowsMotion() {
        let provider = FrameLookupProvider()
        var cache = LabelProjectTopicCache()
        provider.nodes = [node(UUID(), "A"), node(UUID(), "B"), node(UUID(), "A", topic: "other")]
        _ = cache.update(provider)
        cache.rescanPositions(nodes: provider.nodes,
                              positionArray: [SIMD3(2, 8, 4), SIMD3(4, 12, 2), SIMD3(0, 3, 0)],
                              positions: [:])
        #expect(cache.maxY(forProject: "A") == 8)
        #expect(cache.maxY(forProject: "B") == 12)
        #expect(cache.topic(at: 0)?.sum == SIMD3<Float>(6, 20, 6))
        #expect(cache.topic(at: 0)?.count == 2)
        #expect(cache.topic(at: 0)?.project == "B")
        #expect(cache.topic(at: 0)?.maxY == 12)
        #expect(cache.topic(at: 1)?.count == 1)
        let visited = cache.nodesVisited, revision = cache.revision

        provider.positionVersion += 1
        _ = cache.update(provider)
        cache.rescanPositions(nodes: provider.nodes,
                              positionArray: [SIMD3(2, -8, 4), SIMD3(4, -12, 2), SIMD3(0, -3, 0)],
                              positions: [:])
        #expect(cache.nodesVisited == visited)
        #expect(cache.revision == revision)
        #expect(cache.maxY(forProject: "A") == -3)
        #expect(cache.maxY(forProject: "B") == -12)
        #expect(cache.topic(at: 0)?.sum == SIMD3<Float>(6, -20, 6))
        #expect(cache.topic(at: 0)?.count == 2)
        #expect(cache.topic(at: 0)?.maxY == -8)
        #expect(cache.topic(at: 1)?.sum == SIMD3<Float>(0, -3, 0))
    }

    @Test("Label reductions preserve flat-prefix, missing-map and explicit-zero position semantics")
    func labelNumericRescanPreservesMissingPositionSemantics() {
        let provider = FrameLookupProvider()
        var cache = LabelProjectTopicCache()
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        provider.nodes = [node(a, "A"), node(b, "B"), node(c, "C"), node(d, "D", topic: "missing")]
        let membership = cache.update(provider)
        #expect(membership.projects == Set(["A", "B", "C", "D"]))
        cache.rescanPositions(nodes: provider.nodes, positionArray: [.zero],
                              positions: [a: SIMD3(99, 99, 99), b: SIMD3(2, 4, 6)])
        #expect(cache.maxY(forProject: "A") == 0)
        #expect(cache.maxY(forProject: "B") == 4)
        #expect(cache.maxY(forProject: "C") == nil)
        #expect(cache.maxY(forProject: "D") == nil)
        #expect(cache.topic(at: 0)?.sum == SIMD3<Float>(2, 4, 6))
        #expect(cache.topic(at: 0)?.count == 2)
        #expect(cache.topic(at: 0)?.project == "B")
        #expect(cache.topic(at: 1) == nil)

        // The previous last valid node disappears; an absent suffix must not
        // retain its sum, height or color project.
        cache.rescanPositions(nodes: provider.nodes, positionArray: [.zero], positions: [c: SIMD3(3, 6, 9)])
        #expect(cache.maxY(forProject: "B") == nil)
        #expect(cache.topic(at: 0)?.sum == SIMD3<Float>(3, 6, 9))
        #expect(cache.topic(at: 0)?.project == "C")
        #expect(cache.topic(at: 0)?.maxY == 6)

        cache.rescanPositions(nodes: provider.nodes, positionArray: [.zero, .zero, .zero, .zero], positions: [:])
        #expect(cache.topic(at: 0)?.count == 3)
        #expect(cache.topic(at: 0)?.sum == SIMD3<Float>.zero)
        #expect(cache.topic(at: 0)?.project == "C")
        #expect(cache.topic(at: 1)?.count == 1)
        #expect(cache.maxY(forProject: "D") == 0)
        cache.rescanPositions(nodes: provider.nodes, positionArray: [], positions: [:])
        #expect(cache.topicCount == 2) // Atlas membership includes unpositioned nodes.
        #expect(cache.topic(at: 0) == nil)
        #expect(cache.topic(at: 1) == nil)
        #expect(cache.maxY(forProject: "A") == nil)
    }

    @Test("Label slots follow node reorder and same-count project/topic edits")
    func labelNumericSlotsFollowReorderAndTopicChanges() {
        let provider = FrameLookupProvider()
        var cache = LabelProjectTopicCache()
        let a = UUID(), b = UUID()
        provider.nodes = [node(a, "A"), node(b, "B")]
        _ = cache.update(provider)
        cache.rescanPositions(nodes: provider.nodes, positionArray: [],
                              positions: [a: SIMD3(1, 2, 3), b: SIMD3(4, 5, 6)])
        #expect(cache.topic(at: 0)?.project == "B")
        provider.nodes.reverse()
        provider.topologyVersion += 1
        _ = cache.update(provider)
        cache.rescanPositions(nodes: provider.nodes, positionArray: [],
                              positions: [a: SIMD3(1, 2, 3), b: SIMD3(4, 5, 6)])
        #expect(cache.topic(at: 0)?.project == "A")
        #expect(cache.topic(at: 0)?.sum == SIMD3<Float>(5, 7, 9))

        provider.nodes = [node(b, "Changed", topic: "new"), node(a, "Changed", topic: "new")]
        provider.topologyVersion += 1
        _ = cache.update(provider)
        cache.rescanPositions(nodes: provider.nodes, positionArray: [],
                              positions: [a: SIMD3(1, -2, 3), b: SIMD3(4, -5, 6)])
        #expect(cache.maxY(forProject: "A") == nil)
        #expect(cache.maxY(forProject: "B") == nil)
        #expect(cache.maxY(forProject: "Changed") == -2)
        #expect(cache.topicCount == 1)
        #expect(cache.topic(at: 0)?.name == "new")
        #expect(cache.topic(at: 0)?.project == "Changed")
        #expect(cache.topic(at: 0)?.sum == SIMD3<Float>(5, -7, 9))
        #expect(cache.topic(at: 0)?.count == 2)
    }
    @Test("Inserted ranges preserve label slot order and last usable topic color without rereading old metadata")
    func labelInsertionRangesMatchFullRebuild() {
        let provider = FrameLookupProvider()
        let a = node(UUID(), "A", topic: "shared"), b = node(UUID(), "B", topic: "other")
        let c = node(UUID(), "C", topic: "shared")
        provider.nodes = [a, b, c]
        provider.explicitNodeVersion = 1; provider.explicitAppendGeneration = 1
        var cache = LabelProjectTopicCache()
        _ = cache.update(provider)
        let visited = cache.nodesVisited
        let first = node(UUID(), "B", topic: "other"), middle = node(UUID(), "D", topic: "new")
        provider.nodes = [first, a, middle, b, c]
        provider.explicitNodeVersion = 2; provider.explicitAppendGeneration = 2
        provider.insertionReuse = NodeInsertionReuse(fromVersion: 1, toVersion: 2, oldCount: 3, newCount: 5,
            retainedRanges: [.init(oldRange: 0..<1, newStart: 1), .init(oldRange: 1..<3, newStart: 3)])
        let result = cache.update(provider)
        var reference = LabelProjectTopicCache()
        let expected = reference.update(provider)
        #expect(result.projects == expected.projects && result.topics == expected.topics)
        #expect(cache.nodesVisited - visited == 2)
        let positions = provider.nodes.indices.map { SIMD3<Float>(Float($0), Float($0 - 3), 2) }
        cache.rescanPositions(nodes: provider.nodes, positionArray: positions, positions: [:])
        reference.rescanPositions(nodes: provider.nodes, positionArray: positions, positions: [:])
        #expect(cache.topicCount == reference.topicCount)
        for slot in 0..<cache.topicCount {
            #expect(cache.topic(at: slot)?.name == reference.topic(at: slot)?.name)
            #expect(cache.topic(at: slot)?.sum == reference.topic(at: slot)?.sum)
            #expect(cache.topic(at: slot)?.count == reference.topic(at: slot)?.count)
            #expect(cache.topic(at: slot)?.project == reference.topic(at: slot)?.project)
            #expect(cache.topic(at: slot)?.maxY == reference.topic(at: slot)?.maxY)
        }
        for project in result.projects { #expect(cache.maxY(forProject: project) == reference.maxY(forProject: project)) }
        #expect(cache.topic(at: 0)?.name == "other")
        #expect(cache.topic(at: 1)?.project == "C")
        cache.rescanPositions(nodes: provider.nodes, positionArray: [.zero], positions: [a.id: SIMD3(0, -9, 0)])
        #expect(cache.topic(at: 1)?.project == "A")
        #expect(cache.topic(at: 1)?.maxY == -9)
    }

    @Test("Inserted ranges rebase mascot project indices and preserve duplicate first wins")
    func mascotInsertionRangesMatchFullRebuild() {
        let provider = FrameLookupProvider()
        let a = node(UUID(), "A"), b = node(UUID(), "B"), duplicate = node(a.id, "B")
        provider.nodes = [a, b, duplicate]
        provider.explicitNodeVersion = 1; provider.explicitAppendGeneration = 1
        let index = MascotGraphIndex()
        index.update(nodes: provider.nodes, nodeVersion: 1, nodeAppendGeneration: 1, provider: provider)
        let visited = index.nodesVisited
        provider.nodes = [node(a.id, "First"), a, node(UUID(), "B"), b, duplicate, node(a.id, "Last")]
        provider.explicitNodeVersion = 2; provider.explicitAppendGeneration = 2
        provider.insertionReuse = NodeInsertionReuse(fromVersion: 1, toVersion: 2, oldCount: 3, newCount: 6,
            retainedRanges: [.init(oldRange: 0..<1, newStart: 1), .init(oldRange: 1..<3, newStart: 3)])
        index.update(nodes: provider.nodes, nodeVersion: 2, nodeAppendGeneration: 2, provider: provider)
        let reference = MascotGraphIndex()
        reference.update(nodes: provider.nodes, topologyVersion: 2, provider: NSObject())
        #expect(index.nodesVisited - visited == 3)
        #expect(index.projects == reference.projects)
        #expect(index.indicesByProject == reference.indicesByProject)
        #expect(index.indexByID == reference.indexByID)
        #expect(index.indexByID[a.id] == 0)
        #expect(index.indicesByProject["B"] == [2, 3, 4])
    }

    @Test("Insertion consumers reject stale versions, counts and provider identity and retain edit/removal fallback")
    func insertionMembershipFallbacksMatchFullRebuild() {
        let a = node(UUID(), "A"), b = node(UUID(), "B")
        for mode in 0..<5 {
            let original = FrameLookupProvider()
            original.nodes = [a, b]; original.explicitNodeVersion = 1; original.explicitAppendGeneration = 1
            var cache = LabelProjectTopicCache(); _ = cache.update(original)
            let index = MascotGraphIndex()
            index.update(nodes: original.nodes, nodeVersion: 1, nodeAppendGeneration: 1, provider: original)
            let provider = mode == 2 ? FrameLookupProvider() : original
            provider.nodes = mode == 4 ? [b] : [node(a.id, "Edited", topic: "changed"), b, node(UUID(), "New")]
            provider.explicitNodeVersion = 3; provider.explicitAppendGeneration = 3
            if mode < 3 {
                provider.insertionReuse = NodeInsertionReuse(fromVersion: mode == 0 ? 2 : 1, toVersion: 3,
                    oldCount: mode == 1 ? 1 : 2, newCount: 3,
                    retainedRanges: [.init(oldRange: 0..<(mode == 1 ? 1 : 2), newStart: 0)])
            }
            let actual = cache.update(provider)
            var fresh = LabelProjectTopicCache(); let expected = fresh.update(provider)
            #expect(actual.projects == expected.projects && actual.topics == expected.topics)
            #expect(cache.nodesVisited == UInt64(2 + provider.nodes.count))
            index.update(nodes: provider.nodes, nodeVersion: 3, nodeAppendGeneration: 3, provider: provider)
            let freshIndex = MascotGraphIndex()
            freshIndex.update(nodes: provider.nodes, topologyVersion: 3, provider: NSObject())
            #expect(index.indexByID == freshIndex.indexByID && index.indicesByProject == freshIndex.indicesByProject)
            #expect(index.nodesVisited == 2 + provider.nodes.count)
        }
    }

}
