/// Writes the force kernel's per-node adjacency directly into its destination
/// buffers. One retained integer array serves first as degree counts and then
/// as scatter cursors; there are no per-node arrays or flattened edge copy.
struct ForceEdgeCSR {
    private var scratch: [Int] = []

    /// Keeps the old adjacency order exactly: input edges in order for each
    /// node, including duplicate edges and both references of a self-loop.
    /// Invalid input or insufficient storage returns false before either
    /// destination is changed. The production caller treats that as a violated
    /// topology precondition, rather than dropping malformed edges silently.
    mutating func write(
        nodeCount: Int,
        edges: [(Int, Int)],
        ranges: UnsafeMutableBufferPointer<SIMD2<UInt32>>,
        adjacency: UnsafeMutableBufferPointer<SIMD2<UInt32>>
    ) -> Bool {
        guard nodeCount >= 0, nodeCount <= Int(UInt32.max),
              edges.count <= Int(UInt32.max) / 2,
              ranges.count >= nodeCount, adjacency.count >= edges.count * 2 else { return false }

        if scratch.count < nodeCount {
            scratch.append(contentsOf: repeatElement(0, count: nodeCount - scratch.count))
        }
        return scratch.withUnsafeMutableBufferPointer { cursors in
            for index in 0..<nodeCount { cursors[index] = 0 }
            for (source, target) in edges {
                guard source >= 0, source < nodeCount,
                      target >= 0, target < nodeCount else { return false }
                cursors[source] += 1
                cursors[target] += 1
            }

            var offset = 0
            for index in 0..<nodeCount {
                let count = cursors[index]
                ranges[index] = SIMD2(UInt32(offset), UInt32(count))
                cursors[index] = offset
                offset += count
            }

            // Stable scatter: walking the original input once preserves the
            // exact per-node summation order used by the force kernel.
            for (source, target) in edges {
                let pair = SIMD2(UInt32(source), UInt32(target))
                adjacency[cursors[source]] = pair
                cursors[source] += 1
                adjacency[cursors[target]] = pair
                cursors[target] += 1
            }
            return true
        }
    }
}
