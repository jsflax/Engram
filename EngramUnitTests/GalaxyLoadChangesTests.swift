@testable import Engram
import Foundation
import XCTest

final class GalaxyLoadChangesTests: XCTestCase {
    private func scanRows(_ count: Int) -> [GalaxyEdgeScan.Row] {
        let source = UUID(), target = UUID()
        return (1...count).map {
            (Int64($0), EdgeData(id: UUID(), sourceId: source, targetId: target, relation: "relates_to"))
        }
    }

    func testInitialEdgeGroupsKeepSmallQueriesAndPublishEveryRowOnce() throws {
        let rows = scanRows(499)
        var cursor = Int64.min
        var requestedLimits: [Int] = []
        var published: [GalaxyEdgeScan.Row] = []
        var sizes: [Int] = []
        while true {
            let group = try GalaxyEdgeScan.readGroup(after: cursor, check: {}, readPage: { after, limit in
                requestedLimits.append(limit)
                let page = Array(rows.dropFirst(after == .min ? 0 : Int(after)).prefix(limit))
                return .init(rawCount: page.count, lastPrimaryKey: page.last?.pk, rows: page)
            })
            sizes.append(group.rows.count)
            published.append(contentsOf: group.rows)
            cursor = group.cursor
            if group.reachedEnd { break }
        }
        XCTAssertEqual(requestedLimits, Array(repeating: 50, count: 11))
        XCTAssertEqual(sizes, [200, 200, 99], "Publish the final short group without enlarging database reads")
        XCTAssertEqual(published.map(\.pk), rows.map(\.pk))
        XCTAssertEqual(published.map(\.edge.id), rows.map(\.edge.id))
        XCTAssertEqual(cursor, 499)
    }

    func testFilteredEdgePagesAdvanceRawCursorWithoutEndingOrUnboundingScan() throws {
        let rows = scanRows(225)
        var queries = 0
        func read(_ after: Int64, _ limit: Int) -> GalaxyEdgeScan.Page {
            queries += 1
            let raw = Array(rows.dropFirst(after == .min ? 0 : Int(after)).prefix(limit))
            // A full invalid-endpoint page sits between valid pages.
            let valid = raw.filter { !(51...100).contains($0.pk) }
            return .init(rawCount: raw.count, lastPrimaryKey: raw.last?.pk, rows: valid)
        }
        let first = try GalaxyEdgeScan.readGroup(after: .min, check: {}, readPage: read)
        XCTAssertEqual(queries, 4)
        XCTAssertEqual(first.cursor, 200)
        XCTAssertFalse(first.reachedEnd)
        XCTAssertEqual(first.rows.map(\.pk), Array(1...50).map(Int64.init) + Array(101...200).map(Int64.init))
        let tail = try GalaxyEdgeScan.readGroup(after: first.cursor, check: {}, readPage: read)
        XCTAssertTrue(tail.reachedEnd)
        XCTAssertEqual(tail.rows.map(\.pk), Array(201...225).map(Int64.init))
        var emptyQueries = 0
        let empty = try GalaxyEdgeScan.readGroup(after: .min, check: {}, readPage: { after, limit in
            emptyQueries += 1
            return .init(rawCount: limit, lastPrimaryKey: after == .min ? 50 : after + 50, rows: [])
        })
        XCTAssertEqual(emptyQueries, 4, "Filtered-out rows still consume the per-group query budget")
        XCTAssertEqual(empty.cursor, 200)
        XCTAssertTrue(empty.rows.isEmpty)
        XCTAssertFalse(empty.reachedEnd, "Only a raw empty query is EOF")
    }

    func testInitialEdgeGroupCancellationDiscardsAlreadyReadValues() {
        let rows = scanRows(100)
        var state = GalaxyLoadChanges()
        let generation = state.begin()
        var reads = 0
        XCTAssertThrowsError(try GalaxyEdgeScan.readGroup(after: .min, check: {
            guard state.accepts(generation) else { throw CancellationError() }
        }, readPage: { after, limit in
            reads += 1
            let page = Array(rows.dropFirst(after == .min ? 0 : Int(after)).prefix(limit))
            if reads == 2 { state.stop() }
            return .init(rawCount: page.count, lastPrimaryKey: page.last?.pk, rows: page)
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(reads, 2, "Cancellation after a query must stop before another read or publication")
    }

    func testInitialEdgeGroupReadFailureCannotPublishPartialValues() {
        enum ReadFailure: Error { case unavailable }
        let rows = scanRows(150)
        var reads = 0
        XCTAssertThrowsError(try GalaxyEdgeScan.readGroup(after: .min, check: {}, readPage: { after, limit in
            reads += 1
            if reads == 3 { throw ReadFailure.unavailable }
            let page = Array(rows.dropFirst(after == .min ? 0 : Int(after)).prefix(limit))
            return .init(rawCount: page.count, lastPrimaryKey: page.last?.pk, rows: page)
        })) { XCTAssertTrue($0 is ReadFailure) }
        XCTAssertEqual(reads, 3)
    }

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
