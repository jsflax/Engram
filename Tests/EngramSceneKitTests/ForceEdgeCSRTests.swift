import Testing
@testable import EngramSceneKit

@Suite("Force edge CSR")
struct ForceEdgeCSRTests {
    private typealias Pair = SIMD2<UInt32>
    private let sentinel = Pair(0xdeadbeef, 0xf00dcafe)

    /// The former production algorithm is an independent ordering oracle.
    private func reference(nodeCount: Int, edges: [(Int, Int)]) -> (ranges: [Pair], adjacency: [Pair]) {
        var perNode = [[Int]](repeating: [], count: nodeCount)
        for (index, edge) in edges.enumerated() {
            perNode[edge.0].append(index)
            perNode[edge.1].append(index)
        }
        var ranges: [Pair] = []
        var adjacency: [Pair] = []
        for indices in perNode {
            ranges.append(Pair(UInt32(adjacency.count), UInt32(indices.count)))
            for index in indices {
                adjacency.append(Pair(UInt32(edges[index].0), UInt32(edges[index].1)))
            }
        }
        return (ranges, adjacency)
    }

    private func verify(_ builder: inout ForceEdgeCSR, nodeCount: Int, edges: [(Int, Int)]) {
        let expected = reference(nodeCount: nodeCount, edges: edges)
        // Guards around rebased buffers also detect a stray cursor write.
        var ranges = [Pair](repeating: sentinel, count: nodeCount + 2)
        var adjacency = [Pair](repeating: sentinel, count: edges.count * 2 + 2)
        let success = ranges.withUnsafeMutableBufferPointer { rangeStorage in
            adjacency.withUnsafeMutableBufferPointer { edgeStorage in
                builder.write(nodeCount: nodeCount, edges: edges,
                    ranges: UnsafeMutableBufferPointer(rebasing: rangeStorage[1..<(nodeCount + 1)]),
                    adjacency: UnsafeMutableBufferPointer(rebasing: edgeStorage[1..<(edges.count * 2 + 1)]))
            }
        }
        #expect(success)
        #expect(Array(ranges.dropFirst().dropLast()) == expected.ranges)
        #expect(Array(adjacency.dropFirst().dropLast()) == expected.adjacency)
        #expect(ranges.first == sentinel && ranges.last == sentinel)
        #expect(adjacency.first == sentinel && adjacency.last == sentinel)
        for range in ranges.dropFirst().dropLast() {
            #expect(Int(range.x) + Int(range.y) <= edges.count * 2)
        }
    }

    // Stable adjacency retains duplicates, self-loops, orientation and isolated nodes.
    @Test
    func exactOrdering() {
        var builder = ForceEdgeCSR()
        verify(&builder, nodeCount: 7, edges: [
            (3, 1), (1, 1), (0, 3), (3, 1), (1, 3), (5, 5), (0, 0), (5, 1),
        ])
    }

    // Reusable scratch handles growth, shrink, edits and empty graphs.
    @Test
    func changingTopologies() {
        var builder = ForceEdgeCSR()
        verify(&builder, nodeCount: 0, edges: [])
        verify(&builder, nodeCount: 4, edges: [(0, 3), (1, 2), (2, 2)])
        verify(&builder, nodeCount: 19, edges: [(18, 0), (18, 18), (7, 5), (0, 18)])
        verify(&builder, nodeCount: 3, edges: [(2, 0), (1, 0)])
        verify(&builder, nodeCount: 3, edges: [(1, 2), (2, 2)])
        verify(&builder, nodeCount: 3, edges: [])
        verify(&builder, nodeCount: 0, edges: [])
        verify(&builder, nodeCount: 1, edges: [(0, 0), (0, 0)])
        verify(&builder, nodeCount: 4, edges: [(3, 1), (1, 0)])
    }

    // Large loading topology exactly matches the old reference.
    @Test
    func largeTopology() {
        let nodeCount = 55_837
        var random: UInt64 = 0x17c5
        var edges: [(Int, Int)] = []
        for index in 0..<65_504 {
            random = random &* 6_364_136_223_846_793_005 &+ 1
            let source = Int(random % UInt64(nodeCount))
            random = random &* 6_364_136_223_846_793_005 &+ 1
            let target = index % 11 == 0 ? 0 : Int(random % UInt64(nodeCount))
            edges.append((source, index % 23 == 0 ? source : target))
        }
        edges.append(contentsOf: edges.prefix(50))
        var builder = ForceEdgeCSR()
        verify(&builder, nodeCount: nodeCount, edges: edges)
        // A later load batch replaces, deletes and inserts edges without
        // changing node count; scratch must not retain prior degrees/cursors.
        edges.removeFirst(100)
        edges.append(contentsOf: [(0, nodeCount - 1), (0, 0), (nodeCount - 1, 0)])
        verify(&builder, nodeCount: nodeCount, edges: edges)
    }

    // Malformed input and insufficient destinations cannot partially publish CSR.
    @Test
    func rejectsInvalidInput() {
        var builder = ForceEdgeCSR()
        let cases: [(nodes: Int, edges: [(Int, Int)], rangeCount: Int, edgeCount: Int)] = [
            (3, [(0, 1), (-1, 2)], 3, 4),
            (3, [(0, 1), (2, -1)], 3, 4),
            (3, [(0, 1), (3, 2)], 3, 4),
            (3, [(0, 1), (2, 3)], 3, 4),
            (0, [(0, 0)], 0, 2),
            (-1, [], 0, 0),
            (Int(UInt32.max) + 1, [], 0, 0),
            (3, [(0, 1)], 2, 2),
            (3, [(0, 1)], 3, 1),
        ]
        for input in cases {
            var ranges = [Pair](repeating: sentinel, count: input.rangeCount)
            var adjacency = [Pair](repeating: sentinel, count: input.edgeCount)
            let success = ranges.withUnsafeMutableBufferPointer { ranges in
                adjacency.withUnsafeMutableBufferPointer { adjacency in
                    builder.write(nodeCount: input.nodes, edges: input.edges,
                                  ranges: ranges, adjacency: adjacency)
                }
            }
            #expect(!success)
            #expect(ranges.allSatisfy { $0 == sentinel })
            #expect(adjacency.allSatisfy { $0 == sentinel })
            verify(&builder, nodeCount: 3, edges: [(2, 2), (0, 1)])
        }
    }

    // Larger destination capacity retains unused storage.
    @Test
    func unusedCapacity() {
        var builder = ForceEdgeCSR()
        var ranges = [Pair](repeating: sentinel, count: 8)
        var adjacency = [Pair](repeating: sentinel, count: 12)
        let success = ranges.withUnsafeMutableBufferPointer { ranges in
            adjacency.withUnsafeMutableBufferPointer { adjacency in
                builder.write(nodeCount: 3, edges: [(2, 0), (1, 1)],
                              ranges: ranges, adjacency: adjacency)
            }
        }
        #expect(success)
        #expect(Array(ranges.prefix(3)) == [Pair(0, 1), Pair(1, 2), Pair(3, 1)])
        #expect(Array(adjacency.prefix(4)) == [Pair(2, 0), Pair(1, 1), Pair(1, 1), Pair(2, 0)])
        #expect(ranges.dropFirst(3).allSatisfy { $0 == sentinel })
        #expect(adjacency.dropFirst(4).allSatisfy { $0 == sentinel })
    }
}
