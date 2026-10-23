import Testing
import EngramSceneKit

struct NodeInsertionReuseModelTests {
    @Test("Insertion reuse agrees with complete arrays for every small gap pattern")
    func exhaustiveInsertionPatterns() throws {
        // The reference is a complete new array made independently of the
        // descriptor. Each of its gaps receives zero, one or two new rows.
        for oldCount in 0...5 {
            let previous = Array(0..<oldCount)
            let patterns = (0...oldCount).reduce(1) { count, _ in count * 3 }
            for pattern in 0..<patterns {
                var digits = pattern
                var expected: [Int] = []
                var insertedIndices: [Int] = []
                for gap in 0...oldCount {
                    let additions = digits % 3
                    digits /= 3
                    for _ in 0..<additions {
                        insertedIndices.append(expected.count)
                        expected.append(-1 - expected.count)
                    }
                    if gap < oldCount { expected.append(gap) }
                }

                // Both per-row and coalesced certificates describe the same
                // publication. Consumers cannot depend on range granularity.
                for coalesce in [false, true] {
                    var retained: [NodeInsertionReuse.RetainedRange] = []
                    for oldIndex in previous.indices {
                        let newIndex = try #require(expected.firstIndex(of: oldIndex))
                        if coalesce, let last = retained.last,
                           last.newStart + last.oldRange.count == newIndex {
                            retained.removeLast()
                            retained.append(.init(oldRange: last.oldRange.lowerBound..<(oldIndex + 1),
                                                  newStart: last.newStart))
                        } else {
                            retained.append(.init(oldRange: oldIndex..<(oldIndex + 1),
                                                  newStart: newIndex))
                        }
                    }
                    let reuse = try #require(NodeInsertionReuse(
                        fromVersion: 41, toVersion: 42, oldCount: oldCount,
                        newCount: expected.count, retainedRanges: retained))
                    var constructedIndices: [Int] = []
                    let actual = reuse.remap(previous) { index in
                        constructedIndices.append(index)
                        return expected[index]
                    }
                    #expect(actual == expected)
                    #expect(constructedIndices == insertedIndices)
                    #expect(reuse.insertedRanges.flatMap { Array($0) } == insertedIndices)
                    #expect(reuse.preservesExistingIndices == (Array(expected.prefix(oldCount)) == previous))
                    for oldIndex in previous.indices {
                        #expect(reuse.newIndex(forOldIndex: oldIndex) == expected.firstIndex(of: oldIndex))
                    }
                    #expect(reuse.newIndex(forOldIndex: -1) == nil)
                    #expect(reuse.newIndex(forOldIndex: oldCount) == nil)
                    #expect(previous == Array(0..<oldCount))
                }
            }
        }
    }

    @Test("A stale source array cannot construct inserted values")
    func wrongSourceCountDoesNotInvokeInsertion() throws {
        let reuse = try #require(NodeInsertionReuse(
            fromVersion: 7, toVersion: 8, oldCount: 2, newCount: 4,
            retainedRanges: [.init(oldRange: 0..<1, newStart: 0),
                             .init(oldRange: 1..<2, newStart: 2)]))
        var calls = 0
        let result = reuse.remap([10]) { _ in calls += 1; return 99 }
        #expect(result == nil)
        #expect(calls == 0)
        #expect(!reuse.matches(fromVersion: 6, oldCount: 2, toVersion: 8, newCount: 4))
        #expect(!reuse.matches(fromVersion: 7, oldCount: 2, toVersion: 9, newCount: 4))
    }

    @Test("Retained index arithmetic stays within a valid Int boundary")
    func indexNearIntMaxDoesNotOverflow() throws {
        let reuse = try #require(NodeInsertionReuse(
            fromVersion: 1, toVersion: 2, oldCount: 3, newCount: Int.max,
            retainedRanges: [.init(oldRange: 0..<2, newStart: 0),
                             .init(oldRange: 2..<3, newStart: Int.max - 1)]))
        #expect(reuse.newIndex(forOldIndex: 0) == 0)
        #expect(reuse.newIndex(forOldIndex: 2) == Int.max - 1)
        #expect(reuse.insertedRanges == [2..<(Int.max - 1)])
        #expect(!reuse.preservesExistingIndices)
        let wrapped = try #require(NodeInsertionReuse(
            fromVersion: .max, toVersion: 0, oldCount: 3, newCount: 4,
            retainedRanges: [.init(oldRange: 0..<1, newStart: 0),
                             .init(oldRange: 1..<3, newStart: 1)]))
        #expect(wrapped.preservesExistingIndices)
        #expect(wrapped.matches(fromVersion: .max, oldCount: 3, toVersion: 0, newCount: 4))
    }

    @Test("Malformed certificates cannot lose, reorder or overlap retained rows")
    func malformedRetainedRangesAreRejected() {
        let invalid: [[NodeInsertionReuse.RetainedRange]] = [
            [],
            [.init(oldRange: 1..<3, newStart: 0)],
            [.init(oldRange: 0..<2, newStart: 0)],
            [.init(oldRange: 0..<2, newStart: 0), .init(oldRange: 1..<3, newStart: 2)],
            [.init(oldRange: 0..<2, newStart: 1), .init(oldRange: 2..<3, newStart: 2)],
            [.init(oldRange: 0..<3, newStart: -1)],
            [.init(oldRange: 0..<3, newStart: 2)],
            [.init(oldRange: 0..<4, newStart: 0)],
            // Matching first/last positions alone is not a proof: a shifted
            // middle row overlaps the unchanged last row and must be rejected.
            [.init(oldRange: 0..<1, newStart: 0), .init(oldRange: 1..<2, newStart: 2),
             .init(oldRange: 2..<3, newStart: 2)],
        ]
        for ranges in invalid {
            #expect(NodeInsertionReuse(fromVersion: 1, toVersion: 2,
                oldCount: 3, newCount: 4, retainedRanges: ranges) == nil)
        }
        #expect(NodeInsertionReuse(fromVersion: 1, toVersion: 1,
            oldCount: 0, newCount: 0, retainedRanges: []) == nil)
        #expect(NodeInsertionReuse(fromVersion: 1, toVersion: 2,
            oldCount: -1, newCount: 0, retainedRanges: []) == nil)
        #expect(NodeInsertionReuse(fromVersion: 1, toVersion: 2,
            oldCount: 1, newCount: 0, retainedRanges: []) == nil)
    }
}
