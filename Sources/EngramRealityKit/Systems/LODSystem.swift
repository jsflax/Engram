import simd
import Foundation

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
    private var nearBuf: [(index: Int, distance: Float, priority: Int)] = []
    private var midBuf: [(index: Int, distance: Float, priority: Int)] = []
    private var farBuf: [(index: Int, distance: Float, priority: Int)] = []
    private var visibleBits: [Bool] = []
    private var edgeSrcIdx: [Int32] = []
    private var edgeTgtIdx: [Int32] = []
    private var edgeTopologyVersion: UInt64 = .max
    /// EMA of the previous frames' min/max node-to-camera distance —
    /// the basis for scale-free LOD tier thresholds.
    private var distMinEMA: Float = 0
    private var distMaxEMA: Float = 5000

    // Reuse only a complete, explicitly stable publication. Providers without a
    // position revision cannot prove that a static camera means static geometry.
    private var cachedVisibleSet: VisibleSet?
    private var lastCameraPosition: SIMD3<Float> = .init(repeating: .greatestFiniteMagnitude)
    private var lastVisibleTopologyVersion: UInt64 = .max
    private var lastPositionRevision: UInt64?
    private var lastSelectedNode: UUID?
    private var lastGlowingNodeIDs: Set<UUID> = []
    private var lastNodeCount = -1
    private var lastEdgeCount = -1
    private var lastNodeBudget = -1
    private var lastEdgeBudget = -1
    private var lastLabelBudget = -1
    private var emaConverging = false
    // Internal work evidence for regression tests: cache hits do not visit nodes/edges.
    private(set) var visibilityComputationCount: UInt64 = 0
    private var edgeNodeCount = -1

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
        positionRevision: UInt64? = nil
    ) -> VisibleSet {
        let n = nodes.count
        let useArray = positionArray.count == n

        // Glow membership can change budget winners; elapsed glow time cannot.
        let glowingNodeIDs = Set(glowingNodes.keys)
        if let cached = cachedVisibleSet,
           let positionRevision, positionRevision == lastPositionRevision,
           !emaConverging,
           topologyVersion == lastVisibleTopologyVersion,
           n == lastNodeCount, edges.count == lastEdgeCount,
           selectedNode == lastSelectedNode,
           glowingNodeIDs == lastGlowingNodeIDs,
           maxNodeInstances == lastNodeBudget,
           maxEdgeInstances == lastEdgeBudget,
           maxLabelInstances == lastLabelBudget,
           cameraPosition == lastCameraPosition {
            return cached
        }
        visibilityComputationCount &+= 1

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
        nearBuf.removeAll(keepingCapacity: true)
        midBuf.removeAll(keepingCapacity: true)
        farBuf.removeAll(keepingCapacity: true)
        var frameMinSq: Float = .greatestFiniteMagnitude
        var frameMaxSq: Float = 0

        positionArray.withUnsafeBufferPointer { posBuf in
            for i in 0..<n {
                let node = nodes[i]
                let pos: SIMD3<Float>
                if useArray {
                    pos = posBuf[i]
                } else {
                    guard let p = positions[node.id] else { continue }
                    pos = p
                }
                let distSq = simd_length_squared(pos - cameraPosition)
                if distSq < frameMinSq { frameMinSq = distSq }
                if distSq > frameMaxSq { frameMaxSq = distSq }

                // Priority: selected > glowing > hub > importance > distance.
                // The glow lookup is gated: an empty dict still costs a UUID
                // hash per node per frame (42k/frame) without the check.
                var priority = 0
                if node.id == selectedNode { priority = 1000 }
                else if hasGlows, glowingNodes[node.id] != nil { priority = 500 }
                else if node.isHub { priority = 100 }
                else { priority = node.importance }

                if distSq < nearTSq { nearBuf.append((i, distSq, priority)) }
                else if distSq < midTSq { midBuf.append((i, distSq, priority)) }
                else if distSq < farTSq { farBuf.append((i, distSq, priority)) }
            }
        }
        // Classification used the previous EMA. Keep recomputing until the
        // update reaches a Float fixed point, even after geometry stops moving.
        // This also handles one/equidistant nodes and eventually admits restored
        // endpoints after a large force/camera/topology change.
        emaConverging = false
        if frameMinSq <= frameMaxSq, frameMaxSq.isFinite {
            let nextMin = 0.8 * distMinEMA + 0.2 * frameMinSq.squareRoot()
            let nextMax = 0.8 * distMaxEMA + 0.2 * frameMaxSq.squareRoot()
            emaConverging = nextMin != distMinEMA || nextMax != distMaxEMA
            distMinEMA = nextMin
            distMaxEMA = nextMax
        }

        // Apply render budget. Sort a tier only when it overflows what's left
        // of the budget — sorted order is irrelevant when everything fits.
        var remaining = maxNodeInstances
        func capped(_ buf: inout [(index: Int, distance: Float, priority: Int)]) -> [Int] {
            guard remaining > 0 else { return [] }
            if buf.count > remaining {
                buf.sort { $0.priority != $1.priority ? $0.priority > $1.priority : $0.distance < $1.distance }
            }
            let take = min(buf.count, remaining)
            remaining -= take
            var out = [Int](); out.reserveCapacity(take)
            for k in 0..<take { out.append(buf[k].index) }
            return out
        }
        var nearCapped = capped(&nearBuf)
        var midCapped = capped(&midBuf)
        var farCapped = capped(&farBuf)

        // First-frame guard (EMA not yet seeded): render the first
        // budget-worth of nodes rather than a blank frame. Quantile tiers
        // make this unreachable afterwards.
        if nearCapped.isEmpty && midCapped.isEmpty && farCapped.isEmpty && n > 0 {
            farCapped = Array(0..<min(n, maxNodeInstances))
        }
        _ = nearCapped; _ = midCapped

        // Edge endpoints as node indices, cached on topology. The UUID-Set
        // filter did 2 hashed lookups × edge count per frame (460k+ at 230k
        // edges); with int indices + a bit array it's two loads and two tests.
        if edgeTopologyVersion != topologyVersion || edgeSrcIdx.count != edges.count || edgeNodeCount != n {
            var idToIndex = [UUID: Int32](minimumCapacity: n)
            for i in 0..<n { idToIndex[nodes[i].id] = Int32(i) }
            edgeSrcIdx = [Int32](repeating: -1, count: edges.count)
            edgeTgtIdx = [Int32](repeating: -1, count: edges.count)
            for e in 0..<edges.count {
                edgeSrcIdx[e] = idToIndex[edges[e].sourceId] ?? -1
                edgeTgtIdx[e] = idToIndex[edges[e].targetId] ?? -1
            }
            edgeTopologyVersion = topologyVersion
            edgeNodeCount = n
        }

        if visibleBits.count != n { visibleBits = [Bool](repeating: false, count: n) }
        else { for i in 0..<n { visibleBits[i] = false } }
        for idx in nearCapped { visibleBits[idx] = true }
        for idx in midCapped { visibleBits[idx] = true }
        for idx in farCapped { visibleBits[idx] = true }

        var visibleEdges: [Int] = []
        visibleEdges.reserveCapacity(min(edges.count, maxEdgeInstances))
        let edgeCount = edges.count
        edgeSrcIdx.withUnsafeBufferPointer { src in
            edgeTgtIdx.withUnsafeBufferPointer { tgt in
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
        lastPositionRevision = positionRevision
        lastGlowingNodeIDs = glowingNodeIDs
        lastNodeCount = n; lastEdgeCount = edges.count
        lastNodeBudget = maxNodeInstances
        lastEdgeBudget = maxEdgeInstances
        lastLabelBudget = maxLabelInstances
        return result
    }
}
