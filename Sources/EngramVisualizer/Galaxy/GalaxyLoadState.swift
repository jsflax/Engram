import Foundation

enum GalaxyLoadStatus: String, Sendable {
    case waiting, loading, complete, failed, cancelled
}

/// Database reads remain small; only detached edge values are combined before
/// one MainActor publication. The caller retains ownership of scan completion
/// and observer reconciliation. A failed/cancelled group is never returned.
enum GalaxyEdgeScan {
    static let queryLimit = 50
    static let pagesPerPublication = 4
    typealias Row = (pk: Int64, edge: EdgeData)

    struct Page: Sendable {
        let rawCount: Int
        let lastPrimaryKey: Int64?
        let rows: [Row]
    }

    struct Group: Sendable {
        let cursor: Int64
        let rows: [Row]
        let reachedEnd: Bool
    }

    enum Failure: Error { case invalidPage }

    static func readGroup(after initialCursor: Int64, check: () throws -> Void,
                          readPage: (Int64, Int) throws -> Page) throws -> Group {
        var cursor = initialCursor
        var rows: [Row] = []
        rows.reserveCapacity(queryLimit * pagesPerPublication)
        for _ in 0..<pagesPerPublication {
            try check()
            let page = try readPage(cursor, queryLimit)
            try check()
            guard (0...queryLimit).contains(page.rawCount), page.rows.count <= page.rawCount else {
                throw Failure.invalidPage
            }
            if page.rawCount == 0 {
                guard page.lastPrimaryKey == nil, page.rows.isEmpty else { throw Failure.invalidPage }
                return Group(cursor: cursor, rows: rows, reachedEnd: true)
            }
            guard let last = page.lastPrimaryKey, last > cursor,
                  page.rows.allSatisfy({ $0.pk > cursor && $0.pk <= last }) else {
                throw Failure.invalidPage
            }
            rows.append(contentsOf: page.rows)
            cursor = last
        }
        return Group(cursor: cursor, rows: rows, reachedEnd: false)
    }
}

#if DEBUG
enum GalaxyEdgeScanEvent: Sendable {
    case pageRead(limit: Int, rawCount: Int)
    case willPublish(rowCount: Int)
}
#endif

/// Observers retain keys, never hydrated rows or one Task per notification.
/// Overflow requests another complete scan (including missing-row removal).
/// The rendered graph is necessarily O(rows); queued work is bounded separately.
struct GalaxyLoadChanges: Sendable {
    static let capacity = 2_048
    private(set) var generation: UInt64 = 0
    private(set) var revision: UInt64 = 0
    private(set) var active = false
    private(set) var retired = false
    private(set) var workerRunning = false
    private(set) var needsScan = true
    private(set) var nodes: Set<Int64> = []
    private(set) var edges: Set<Int64> = []

    enum Work {
        case scan
        case rows(nodes: [Int64], edges: [Int64])
        case idle
    }

    mutating func begin() -> UInt64 {
        guard !retired else { return generation }
        generation &+= 1
        active = true
        workerRunning = true
        needsScan = true
        nodes.removeAll(); edges.removeAll()
        return generation
    }

    func accepts(_ generation: UInt64) -> Bool { active && self.generation == generation }

    mutating func requestScan() -> UInt64? {
        guard active else { return nil }
        revision &+= 1
        needsScan = true
        guard !workerRunning else { return nil }
        workerRunning = true
        return generation
    }

    /// True grants the caller the single worker launch for this generation.
    mutating func record(_ pk: Int64, edge: Bool, generation: UInt64) -> Bool {
        guard accepts(generation) else { return false }
        revision &+= 1
        if nodes.count + edges.count < Self.capacity || (edge ? edges.contains(pk) : nodes.contains(pk)) {
            if edge { edges.insert(pk) } else { nodes.insert(pk) }
        } else {
            needsScan = true
        }
        guard !workerRunning else { return false }
        workerRunning = true
        return true
    }

    mutating func next(generation: UInt64, limit: Int = 50) -> Work {
        guard accepts(generation) else { return .idle }
        if needsScan {
            needsScan = false
            nodes.removeAll(); edges.removeAll()
            return .scan
        }
        let nodeKeys = Array(nodes.prefix(limit))
        let edgeKeys = Array(edges.prefix(max(0, limit - nodeKeys.count)))
        nodes.subtract(nodeKeys); edges.subtract(edgeKeys)
        return nodeKeys.isEmpty && edgeKeys.isEmpty ? .idle : .rows(nodes: nodeKeys, edges: edgeKeys)
    }

    /// Called AFTER publishing completion, so a notification during that await
    /// keeps this worker alive instead of losing a wakeup.
    mutating func finishIfIdle(generation: UInt64) -> Bool {
        guard accepts(generation) else { return true }
        guard !needsScan && nodes.isEmpty && edges.isEmpty else { return false }
        workerRunning = false
        return true
    }

    mutating func failed(generation: UInt64) {
        guard accepts(generation) else { return }
        needsScan = true
        workerRunning = false
    }

    mutating func stop() {
        retired = true
        active = false
        generation &+= 1
        nodes.removeAll(); edges.removeAll()
        workerRunning = false
    }
}
