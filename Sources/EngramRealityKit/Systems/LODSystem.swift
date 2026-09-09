import simd
import Foundation

/// Keep the same priority/distance order as a stable full sort, without sorting
/// thousands of discarded nodes when only a small part of a tier fits. The
/// index tie-break preserves classification order even after partitioning.
enum LODBudgetSelection {
    typealias Candidate = (index: Int, distance: Float, priority: Int)

    private static func precedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
        return lhs.index < rhs.index
    }

    static func indices(from candidates: inout [Candidate], limit: Int) -> [Int] {
        let take = min(candidates.count, max(0, limit))
        guard take > 0 else { return [] }
        if candidates.count > take {
            candidates.withUnsafeMutableBufferPointer { buffer in
                partitionPrefix(buffer, count: take)
                var prefix = UnsafeMutableBufferPointer(rebasing: buffer[..<take])
                prefix.sort(by: precedes)
            }
        }
        // Tiers that fit retain input order, including their label ordering.
        return candidates.prefix(take).map(\.index)
    }

    private static func partitionPrefix(_ candidates: UnsafeMutableBufferPointer<Candidate>, count: Int) {
        let buffer = candidates
        var lower = 0
        var upper = buffer.count
        var depth = 2 * (Int.bitWidth - buffer.count.leadingZeroBitCount)
        while upper - lower > 24 {
            // Bound adversarial partition sequences; sorting the active range
            // still keeps worst-case work at O(n log n), as before this change.
            guard depth > 0 else {
                var remainder = UnsafeMutableBufferPointer(rebasing: buffer[lower..<upper])
                remainder.sort(by: precedes)
                return
            }
            depth -= 1
            let middle = lower + (upper - lower) / 2
            let last = upper - 1
            // Median-of-three avoids degenerate splits on already ordered,
            // reverse-ordered, or distance-clustered input.
            if precedes(buffer[middle], buffer[lower]) { buffer.swapAt(middle, lower) }
            if precedes(buffer[last], buffer[lower]) { buffer.swapAt(last, lower) }
            if precedes(buffer[last], buffer[middle]) { buffer.swapAt(last, middle) }
            buffer.swapAt(middle, last)
            let pivot = buffer[last]
            var boundary = lower
            for index in lower..<last where precedes(buffer[index], pivot) {
                if index != boundary { buffer.swapAt(index, boundary) }
                boundary += 1
            }
            buffer.swapAt(boundary, last)
            if boundary == count { return }
            if boundary < count { lower = boundary + 1 }
            else { upper = boundary }
        }
        var remainder = UnsafeMutableBufferPointer(rebasing: buffer[lower..<upper])
        remainder.sort(by: precedes)
    }
}

/// Distance-based LOD + culling system. Runs before batch systems.
/// Determines which nodes/edges/labels are visible each frame.
///
/// LOD tiers:
/// - Near (< 500): Full sphere, glow effects, labels
/// - Mid (500–2000): Reduced detail, hub/important labels only
/// - Far (2000–5000): Point sprite, no labels
/// - Culled (> 5000): Hidden
///
/// Render budget caps:
/// - Max ~8,000 node instances (near + mid + far combined)
/// - Max ~30,000 edge instances
/// - Max ~2,000 label instances
@MainActor
public final class LODSystem {

    /// Render budget caps. Env overrides (ENGRAM_LOD_NODE_BUDGET /
    /// ENGRAM_LOD_EDGE_BUDGET) exist for perf-harness budget sweeps —
    /// production defaults are unchanged without them.
    public var maxNodeInstances: Int =
        ProcessInfo.processInfo.environment["ENGRAM_LOD_NODE_BUDGET"].flatMap(Int.init) ?? 8_000
    public var maxEdgeInstances: Int =
        ProcessInfo.processInfo.environment["ENGRAM_LOD_EDGE_BUDGET"].flatMap(Int.init) ?? 30_000
    public var maxLabelInstances: Int = 2_000

    public init() {}

    // Reused per-frame buffers + topology-cached edge endpoint indices.
    private var nearBuf: [LODBudgetSelection.Candidate] = []
    private var midBuf: [LODBudgetSelection.Candidate] = []
    private var farBuf: [LODBudgetSelection.Candidate] = []
    private var visibleBits: [Bool] = []
    // Classification only needs these two scalar fields from each large node
    // snapshot. Keep them compact so orbiting a settled graph does not walk
    // the strings/dates in tens of thousands of immutable snapshots per frame.
    private var basePriorities: [Int] = []
    private var prioritiesTopologyVersion: UInt64 = .max
    private var edgeEndpoints = EdgeEndpointIndexCache()
    private var edgeTopologyVersion: UInt64 = .max
    /// EMA of the previous frames' min/max node-to-camera distance —
    /// the basis for scale-free LOD tier thresholds.
    private var distMinEMA: Float = 0
    private var distMaxEMA: Float = 5000
    private var distanceRangeIsSettled = false

    // Idle cache: the full O(nodes + edges) visible-set recompute is wasted
    // when the camera is static and topology unchanged — the common case in
    // real use (the graph sits still between interactions). Reuse the last
    // result until the camera moves past a small threshold or topology bumps.
    private var cachedVisibleSet: VisibleSet?
    private var lastCameraPosition: SIMD3<Float> = .init(repeating: .greatestFiniteMagnitude)
    private var lastVisibleTopologyVersion: UInt64 = .max
    private var lastSelectedNode: UUID?
    private var lastPositionVersion: UInt64?
    private var lastGlowingIDs: Set<UUID> = []
    private var lastHubs: Set<UUID> = []
    private var lastBudgets: SIMD3<Int> = .zero

    /// Compute which nodes/edges/labels are visible this frame.
    ///
    /// Scale note: tier thresholds are RELATIVE to the graph's extent
    /// (EMA-smoothed radius from the previous frame). Absolute thresholds
    /// culled the entire graph once it outgrew ~5000 units — at 40k nodes
    /// the camera fits the whole graph well beyond that.
    public func computeVisibleSet(
        nodes: [RKNodeSnapshot],
        edges: [RKEdgeSnapshot],
        positions: [UUID: SIMD3<Float>],
        positionArray: [SIMD3<Float>] = [],
        cameraPosition: SIMD3<Float>,
        selectedNode: UUID?,
        glowingNodes: [UUID: Float],
        hubs: Set<UUID>,
        topologyVersion: UInt64 = 0,
        positionVersion: UInt64? = nil
    ) -> VisibleSet {
        let n = nodes.count
        let useArray = positionArray.count == n
        if prioritiesTopologyVersion != topologyVersion || basePriorities.count != n || hubs != lastHubs {
            basePriorities = nodes.map { $0.isHub ? 100 : $0.importance }
            prioritiesTopologyVersion = topologyVersion
        }

        let glowingIDs = Set(glowingNodes.keys)
        let budgets = SIMD3(maxNodeInstances, maxEdgeInstances, maxLabelInstances)
        // Callers without a position revision deliberately bypass this cache.
        // Recall membership can displace a node when a tier exceeds its budget.
        if let cached = cachedVisibleSet,
           distanceRangeIsSettled,
           let positionVersion, positionVersion == lastPositionVersion,
           topologyVersion == lastVisibleTopologyVersion,
           selectedNode == lastSelectedNode,
           glowingIDs == lastGlowingIDs, hubs == lastHubs, budgets == lastBudgets,
           simd_distance_squared(cameraPosition, lastCameraPosition) < 0.25 {
            return cached
        }

        // Scale-relative thresholds. radiusEMA lags one frame — fine, it only
        // moves LOD boundaries. Scale 1.0 reproduces the historical tiers for
        // graphs up to radius 2500.
        // Scale-free tiers: thresholds are fractions of the previous frame's
        // [min, max] camera-distance range (EMA-smoothed). Absolute-distance
        // tiers culled the entire graph whenever it outgrew the constants;
        // range-relative tiers always populate (the nearest node defines min).
        let range = max(distMaxEMA - distMinEMA, 1)
        // Compare in SQUARED distance to avoid a sqrt per node (42k/frame).
        // Squared distance is monotonic in distance, so tier boundaries and
        // sort order are identical; only the two EMA updates need a sqrt.
        let nearTSq = { let t = distMinEMA + 0.10 * range; return t * t }()
        let midTSq = { let t = distMinEMA + 0.35 * range; return t * t }()
        let farTSq = { let t = distMinEMA + 1.05 * range; return t * t }()

        // Classify into tiers (reused buffers)
        let hasGlows = !glowingNodes.isEmpty
        let hasPriorityOverrides = selectedNode != nil || hasGlows
        nearBuf.removeAll(keepingCapacity: true)
        midBuf.removeAll(keepingCapacity: true)
        farBuf.removeAll(keepingCapacity: true)
        var frameMinSq: Float = .greatestFiniteMagnitude
        var frameMaxSq: Float = 0

        positionArray.withUnsafeBufferPointer { posBuf in
            for i in 0..<n {
                let pos: SIMD3<Float>
                if useArray {
                    pos = posBuf[i]
                } else {
                    guard let p = positions[nodes[i].id] else { continue }
                    pos = p
                }
                let distSq = simd_length_squared(pos - cameraPosition)
                if distSq < frameMinSq { frameMinSq = distSq }
                if distSq > frameMaxSq { frameMaxSq = distSq }

                // Priority: selected > glowing > hub > importance > distance.
                // The glow lookup is gated: an empty dict still costs a UUID
                // hash per node per frame (42k/frame) without the check.
                var priority = basePriorities[i]
                if hasPriorityOverrides {
                    let id = nodes[i].id
                    if id == selectedNode { priority = 1000 }
                    else if hasGlows, glowingNodes[id] != nil { priority = 500 }
                }

                if distSq < nearTSq { nearBuf.append((i, distSq, priority)) }
                else if distSq < midTSq { midBuf.append((i, distSq, priority)) }
                else if distSq < farTSq { farBuf.append((i, distSq, priority)) }
            }
        }
        if frameMinSq <= frameMaxSq, frameMaxSq.isFinite {
            let minDistance = frameMinSq.squareRoot()
            let maxDistance = frameMaxSq.squareRoot()
            let tolerance = max(0.01, (maxDistance - minDistance) * 0.0001)
            // Classification above used the previous EMA. After snapping to
            // the final range, require one more classification before caching;
            // otherwise the last visible set still reflects the old thresholds.
            distanceRangeIsSettled = distMinEMA == minDistance && distMaxEMA == maxDistance
            if abs(distMinEMA - minDistance) <= tolerance && abs(distMaxEMA - maxDistance) <= tolerance {
                distMinEMA = minDistance
                distMaxEMA = maxDistance
            } else {
                distMinEMA = 0.8 * distMinEMA + 0.2 * minDistance
                distMaxEMA = 0.8 * distMaxEMA + 0.2 * maxDistance
            }
        } else {
            distanceRangeIsSettled = true
        }

        // Apply the unchanged tier budgets. Select only the retained prefix of
        // an overflowing tier; full sorting is especially wasteful near the
        // graph, where near/mid nodes can leave only a few hundred far slots.
        var remaining = maxNodeInstances
        func capped(_ buf: inout [LODBudgetSelection.Candidate]) -> [Int] {
            let out = LODBudgetSelection.indices(from: &buf, limit: remaining)
            remaining -= out.count
            return out
        }
        let nearCapped = capped(&nearBuf)
        let midCapped = capped(&midBuf)
        var farCapped = capped(&farBuf)

        // First-frame guard (EMA not yet seeded): render the first
        // budget-worth of nodes rather than a blank frame. Quantile tiers
        // make this unreachable afterwards.
        if nearCapped.isEmpty && midCapped.isEmpty && farCapped.isEmpty && n > 0 {
            farCapped = Array(0..<min(n, maxNodeInstances))
        }
        // Edge endpoints as node indices, cached on topology. The UUID-Set
        // filter did 2 hashed lookups × edge count per frame (460k+ at 230k
        // edges); with int indices + a bit array it's two loads and two tests.
        if edgeTopologyVersion != topologyVersion || edgeEndpoints.sourceIndices.count != edges.count
            || edgeEndpoints.nodeCount != n {
            edgeEndpoints.update(nodes: nodes, edges: edges)
            edgeTopologyVersion = topologyVersion
        }

        if visibleBits.count != n { visibleBits = [Bool](repeating: false, count: n) }
        else { for i in 0..<n { visibleBits[i] = false } }
        for idx in nearCapped { visibleBits[idx] = true }
        for idx in midCapped { visibleBits[idx] = true }
        for idx in farCapped { visibleBits[idx] = true }

        var visibleEdges: [Int] = []
        visibleEdges.reserveCapacity(min(edges.count, maxEdgeInstances))
        let edgeCount = edges.count
        edgeEndpoints.sourceIndices.withUnsafeBufferPointer { src in
            edgeEndpoints.targetIndices.withUnsafeBufferPointer { tgt in
                visibleBits.withUnsafeBufferPointer { bits in
                    for e in 0..<edgeCount {
                        guard visibleEdges.count < maxEdgeInstances else { break }
                        let a = src[e], b = tgt[e]
                        if a >= 0 && b >= 0 && bits[Int(a)] && bits[Int(b)] {
                            visibleEdges.append(e)
                        }
                    }
                }
            }
        }

        // Labels: near nodes + important mid nodes
        var visibleLabels: [Int] = []
        visibleLabels.reserveCapacity(min(nearCapped.count + midCapped.count, maxLabelInstances))
        for idx in nearCapped {
            guard visibleLabels.count < maxLabelInstances else { break }
            visibleLabels.append(idx)
        }
        for idx in midCapped {
            guard visibleLabels.count < maxLabelInstances else { break }
            if nodes[idx].isHub || nodes[idx].importance >= 3 {
                visibleLabels.append(idx)
            }
        }

        let result = VisibleSet(
            nearNodes: nearCapped,
            midNodes: midCapped,
            farNodes: farCapped,
            visibleEdgeIndices: visibleEdges,
            visibleLabelIndices: visibleLabels
        )
        cachedVisibleSet = result
        lastCameraPosition = cameraPosition
        lastVisibleTopologyVersion = topologyVersion
        lastSelectedNode = selectedNode
        lastPositionVersion = positionVersion
        lastGlowingIDs = glowingIDs
        lastHubs = hubs
        lastBudgets = budgets
        return result
    }
}
