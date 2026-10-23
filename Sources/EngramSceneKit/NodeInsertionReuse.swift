/// A single publication that inserts nodes without changing or removing any
/// existing row. Consumers must also establish the same provider identity.
/// Retained ranges cover the complete old array, in its original order.
public struct NodeInsertionReuse: Equatable, Sendable {
    public struct RetainedRange: Equatable, Sendable {
        public let oldRange: Range<Int>
        public let newStart: Int

        public init(oldRange: Range<Int>, newStart: Int) {
            self.oldRange = oldRange
            self.newStart = newStart
        }
    }

    public let fromVersion: UInt64
    public let toVersion: UInt64
    public let oldCount: Int
    public let newCount: Int
    public let retainedRanges: [RetainedRange]
    public let insertedRanges: [Range<Int>]

    /// The validated ranges cover every old row. If each starts at its old
    /// index, only tail insertions (or no insertions) remain. Empty old arrays
    /// satisfy this too; consumers still must validate origin and versions.
    public var preservesExistingIndices: Bool {
        retainedRanges.allSatisfy { $0.newStart == $0.oldRange.lowerBound }
    }

    public init?(fromVersion: UInt64, toVersion: UInt64, oldCount: Int,
                 newCount: Int, retainedRanges: [RetainedRange]) {
        guard fromVersion != toVersion, oldCount >= 0, newCount >= oldCount else { return nil }
        var oldEnd = 0
        var newEnd = 0
        var inserted: [Range<Int>] = []
        for range in retainedRanges {
            guard range.oldRange.lowerBound == oldEnd,
                  range.oldRange.upperBound > oldEnd,
                  range.oldRange.upperBound <= oldCount,
                  range.newStart >= newEnd, range.newStart <= newCount else { return nil }
            let length = range.oldRange.upperBound - oldEnd
            guard length <= newCount - range.newStart else { return nil }
            if newEnd < range.newStart { inserted.append(newEnd..<range.newStart) }
            oldEnd = range.oldRange.upperBound
            newEnd = range.newStart + length
        }
        guard oldEnd == oldCount else { return nil }
        if newEnd < newCount { inserted.append(newEnd..<newCount) }
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.oldCount = oldCount
        self.newCount = newCount
        self.retainedRanges = retainedRanges
        self.insertedRanges = inserted
    }

    public func matches(fromVersion: UInt64, oldCount: Int,
                        toVersion: UInt64, newCount: Int) -> Bool {
        self.fromVersion == fromVersion && self.oldCount == oldCount
            && self.toVersion == toVersion && self.newCount == newCount
    }

    public func newIndex(forOldIndex index: Int) -> Int? {
        guard index >= 0, index < oldCount else { return nil }
        var lower = 0
        var upper = retainedRanges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let range = retainedRanges[middle]
            if index < range.oldRange.lowerBound { upper = middle }
            else if index >= range.oldRange.upperBound { lower = middle + 1 }
            else { return range.newStart + (index - range.oldRange.lowerBound) }
        }
        return nil
    }

    /// Copies retained values without reading node metadata. The closure is
    /// evaluated in rendered order, only for newly inserted indices.
    public func remap<Value>(_ previous: [Value], inserting: (Int) -> Value) -> [Value]? {
        guard previous.count == oldCount else { return nil }
        var result: [Value] = []
        result.reserveCapacity(newCount)
        for range in retainedRanges {
            for index in result.count..<range.newStart { result.append(inserting(index)) }
            result.append(contentsOf: previous[range.oldRange])
        }
        for index in result.count..<newCount { result.append(inserting(index)) }
        return result
    }
}
