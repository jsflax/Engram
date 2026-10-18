@testable import Engram
import XCTest

final class GalaxyLoadChangesTests: XCTestCase {
    func testChangesDuringBaselineAreReplayedOnceAndCoalesced() {
        var state = GalaxyLoadChanges()
        let generation = state.begin()
        guard case .scan = state.next(generation: generation) else { return XCTFail("Initial scan missing") }
        for _ in 0..<100 {
            XCTAssertFalse(state.record(7, edge: false, generation: generation))
        }
        XCTAssertFalse(state.record(9, edge: true, generation: generation))
        guard case let .rows(nodes, edges) = state.next(generation: generation) else { return XCTFail("Lost changes") }
        XCTAssertEqual(nodes, [7])
        XCTAssertEqual(edges, [9])
        XCTAssertTrue(state.finishIfIdle(generation: generation))
        XCTAssertTrue(state.record(7, edge: false, generation: generation), "Exactly one worker wakeup")
        XCTAssertFalse(state.record(8, edge: false, generation: generation))
    }

    func testOverflowRetainsBoundAndRequestsCompleteReconciliation() {
        var state = GalaxyLoadChanges()
        let generation = state.begin()
        _ = state.next(generation: generation)
        for pk in 0...GalaxyLoadChanges.capacity {
            XCTAssertFalse(state.record(Int64(pk), edge: pk.isMultiple(of: 2), generation: generation))
        }
        XCTAssertEqual(state.nodes.count + state.edges.count, GalaxyLoadChanges.capacity)
        XCTAssertTrue(state.needsScan)
        XCTAssertFalse(state.finishIfIdle(generation: generation))
        guard case .scan = state.next(generation: generation) else { return XCTFail("Overflow must rescan") }
        XCTAssertTrue(state.nodes.isEmpty && state.edges.isEmpty)
        XCTAssertFalse(state.record(-1, edge: false, generation: generation))
        guard case let .rows(nodes, _) = state.next(generation: generation) else { return XCTFail("Lost rescan race") }
        XCTAssertEqual(nodes, [-1])
    }

    func testPublicationRaceCannotLoseWorkerWakeup() {
        var state = GalaxyLoadChanges()
        let generation = state.begin()
        _ = state.next(generation: generation)
        guard case .idle = state.next(generation: generation) else { return XCTFail("Expected idle") }
        XCTAssertFalse(state.record(1, edge: false, generation: generation))
        XCTAssertFalse(state.finishIfIdle(generation: generation), "Keep the existing worker across publication")
        _ = state.next(generation: generation)
        XCTAssertTrue(state.finishIfIdle(generation: generation))
    }

    func testStoppedGenerationCannotPublishOrScheduleAfterReplacement() {
        var state = GalaxyLoadChanges()
        let old = state.begin()
        state.stop()
        XCTAssertFalse(state.accepts(old))
        XCTAssertFalse(state.record(1, edge: false, generation: old))
        let current = state.begin()
        XCTAssertNotEqual(old, current)
        state.failed(generation: old)
        XCTAssertFalse(state.workerRunning)
        XCTAssertFalse(state.accepts(current), "A late load task must not resurrect a removed Galaxy")
        XCTAssertFalse(state.record(2, edge: true, generation: old))
        XCTAssertTrue(state.nodes.isEmpty && state.edges.isEmpty)
    }

    func testFailureRetriesWithFullScanAndFilteringInvalidatesInFlightBaseline() {
        var state = GalaxyLoadChanges()
        let generation = state.begin()
        _ = state.next(generation: generation)
        XCTAssertNil(state.requestScan(), "A running worker owns the filter change")
        guard case .scan = state.next(generation: generation) else { return XCTFail("Filter change must rescan") }
        state.failed(generation: generation)
        XCTAssertTrue(state.record(1, edge: false, generation: generation))
        guard case .scan = state.next(generation: generation) else { return XCTFail("Failed scans cannot become complete") }
    }

    func testEachWorkBatchHasOneSharedLimitForNodesAndEdges() {
        var state = GalaxyLoadChanges()
        let generation = state.begin()
        _ = state.next(generation: generation)
        for pk in 0..<125 {
            _ = state.record(Int64(pk), edge: false, generation: generation)
            _ = state.record(Int64(pk), edge: true, generation: generation)
        }
        var total = 0
        while case let .rows(nodes, edges) = state.next(generation: generation) {
            XCTAssertLessThanOrEqual(nodes.count + edges.count, 50)
            total += nodes.count + edges.count
        }
        XCTAssertEqual(total, 250)
    }
}
