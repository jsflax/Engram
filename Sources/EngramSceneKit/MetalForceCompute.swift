import Foundation
import CEngramSceneTypes
@preconcurrency import Metal
import simd
import os

/// An accepted octree is immutable until the next replacement. Keep its GPU
/// representation across encodes, including replacements that fit the buffer.
struct BHOctreeUploadCache {
    private(set) var nodes: [OctreeNode]?
    private var buffer: MTLBuffer?
    private var capacity = 0
    private var needsUpload = true
    private(set) var uploadCount = 0

    mutating func replace(with nodes: [OctreeNode]) {
        self.nodes = nodes
        needsUpload = true
    }

    mutating func prepare(device: MTLDevice) -> MTLBuffer? {
        guard let nodes, !nodes.isEmpty else { return nil }
        if buffer == nil || nodes.count > capacity {
            // A failed allocation must not leave the old tree marked ready.
            buffer = nil
            capacity = 0
            needsUpload = true
            let newCapacity = max(nodes.count * 2, 512)
            guard let allocated = device.makeBuffer(
                length: newCapacity * MemoryLayout<BHOctreeNode>.stride,
                options: .storageModeShared
            ) else { return nil }
            buffer = allocated
            capacity = newCapacity
        }
        guard let buffer else { return nil }
        guard needsUpload else { return buffer }

        let treePtr = buffer.contents().bindMemory(to: BHOctreeNode.self, capacity: nodes.count)
        for (i, src) in nodes.enumerated() {
            treePtr[i] = BHOctreeNode(
                cx: src.cx, cy: src.cy, cz: src.cz, halfSize: src.halfSize,
                comX: src.comX, comY: src.comY, comZ: src.comZ, mass: src.mass,
                children: (src.child(0), src.child(1), src.child(2), src.child(3),
                           src.child(4), src.child(5), src.child(6), src.child(7)),
                bodyIndex: src.bodyIndex, _pad: 0)
        }
        uploadCount &+= 1
        needsUpload = false
        return buffer
    }
}

// MARK: - Metal Force Compute

/// GPU-accelerated force simulation — 3-pass architecture matching JS reference.
/// Pass 1: compute_charge_forces (O(n²) pairwise repulsion, clears force buffer)
/// Pass 2: compute_spring_and_structural (springs, center gravity, cohesion, centroid repulsion)
/// Pass 3: integrate_positions (velocity + position update)
///
/// Centroids are computed CPU-side every 10 ticks and uploaded to GPU.
public final class MetalForceCompute: @unchecked Sendable {
    private let device: MTLDevice

    // 3 core pipelines (matching JS WebGPU reference)
    private let chargePipeline: MTLComputePipelineState
    private var springPipeline: MTLComputePipelineState?
    private var bhChargePipeline: MTLComputePipelineState?

    /// Simple flag — only one dispatch at a time.
    public var inFlight = false
    public var lastChargeAlgorithm: String = ""

    /// Whether the full GPU simulation pipeline is available.
    public var isFullSimAvailable: Bool { springPipeline != nil }

    /// Initialize with an external device and library.
    public init?(device: MTLDevice, library: MTLLibrary) {
        guard let chargeFn = library.makeFunction(name: "compute_charge_forces"),
              let chargePL = try? device.makeComputePipelineState(function: chargeFn)
        else { return nil }

        self.device = device
        self.chargePipeline = chargePL

        if let fn = library.makeFunction(name: "compute_spring_and_structural") {
            springPipeline = try? device.makeComputePipelineState(function: fn)
        }
        if let fn = library.makeFunction(name: "compute_charge_forces_bh") {
            bhChargePipeline = try? device.makeComputePipelineState(function: fn)
        }
    }

    // MARK: - Persistent GPU Buffers

    private var positionBuffer: MTLBuffer?    // float3[N]
    private var forceBuffer: MTLBuffer?       // float3[N]
    private var groupBuffer: MTLBuffer?       // int4[N] (projId, topicId, galaxyId, 0)
    private var edgeBuffer: MTLBuffer?        // uint2[E] (src, tgt)
    private var edgeRangeBuffer: MTLBuffer?   // uint2[N] (start, count)
    private var centroidBuffer: MTLBuffer?    // float4[numProj+numTopic+numGalaxy]
    private var centroidMappingBuffer: MTLBuffer? // uint2[N] (projCentIdx, topicCentIdx)
    private var groupMetadataBuffer: MTLBuffer?   // uint[256] topicToProject + projectToGalaxy
    private var refRadiusBuffer: MTLBuffer?   // float[numProjects]
    private var chargeParamsBuffer: MTLBuffer? // ChargeParams
    private var springParamsBuffer: MTLBuffer? // SpringParams

    private var nodeCapacity: Int = 0
    private var edgeCapacity: Int = 0
    private var centroidCapacity: Int = 0
    private var lastEncodedNodeCount: Int = 0

    // Barnes-Hut octree (CPU-built, GPU-walked)
    private var bhTree = BHOctreeUploadCache()
    private var bhParamBuffer: MTLBuffer?
    private var bhTreeDirty: Bool = true
    private let pendingTreeNodes = OSAllocatedUnfairLock<[OctreeNode]?>(initialState: nil)
    private let treeRebuildInFlight = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var treeCacheFrameAge: Int = 0
    private let treeCacheMaxAge: Int = 10

    // CSR topology
    private var csrEdgeCount: Int = 0
    public private(set) var topologyDirtyForDispatch = true
    private var dispatchEdges: [(Int, Int)] = []

    // CPU-side centroid state
    private var tickCount: Int = 0

    // Internal diagnostics distinguish redundant preparation with identical output.
    private(set) var centroidUpdateCount = 0
    private(set) var groupUploadCount = 0

    // MARK: - Buffer Capacity Management

    private func ensureNodeCapacity(_ n: Int) {
        guard n > nodeCapacity else { return }
        let cap = max(n * 2, 512)
        positionBuffer = device.makeBuffer(length: cap * MemoryLayout<SIMD3<Float>>.stride, options: .storageModeShared)
        forceBuffer = device.makeBuffer(length: cap * MemoryLayout<SIMD3<Float>>.stride, options: .storageModeShared)
        groupBuffer = device.makeBuffer(length: cap * MemoryLayout<SIMD4<Int32>>.stride, options: .storageModeShared)
        edgeRangeBuffer = device.makeBuffer(length: cap * MemoryLayout<SIMD2<UInt32>>.stride, options: .storageModeShared)
        centroidMappingBuffer = device.makeBuffer(length: cap * MemoryLayout<SIMD2<UInt32>>.stride, options: .storageModeShared)
        nodeCapacity = cap
        // Replacing node storage invalidates even an equal group input key.
        preparedGroupInputs = nil
        groupsDirty = true
    }

    private func ensureCentroidCapacity(_ totalGroups: Int) {
        guard totalGroups > centroidCapacity else { return }
        let cap = max(totalGroups * 2, 64)
        preparedGroupInputs = nil
        centroidBuffer = device.makeBuffer(length: cap * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)
        refRadiusBuffer = device.makeBuffer(length: cap * MemoryLayout<Float>.stride, options: .storageModeShared)
        centroidCapacity = cap
    }

    // MARK: - Topology Management

    public func setTopologyDirty(edges: [(Int, Int)]) {
        dispatchEdges = edges
        topologyDirtyForDispatch = true
        groupsDirty = true
    }

    /// Edge edits always rebuild adjacency. Static group mappings can survive
    /// those edits only when every input is equal and their storage is valid.
    private struct GroupInputs: Equatable {
        let nodeCount: Int
        let projects: [Int]
        let topics: [Int]
        let topicProjects: [Int]
        let galaxies: [Int]
        let galaxyCount: Int
    }

    private var preparedGroupInputs: GroupInputs?
    private var groupsDirty = true
    private var cachedNumProjects = 1
    private var cachedNumTopics = 1

    private func groupBuffersAreValid(nodeCount: Int, totalGroups: Int) -> Bool {
        guard let groups = groupBuffer, let mapping = centroidMappingBuffer,
              let metadata = groupMetadataBuffer, let centroids = centroidBuffer,
              let radii = refRadiusBuffer else { return false }
        return groups.length >= nodeCount * MemoryLayout<SIMD4<Int32>>.stride
            && mapping.length >= nodeCount * MemoryLayout<SIMD2<UInt32>>.stride
            && metadata.length >= 256 * MemoryLayout<UInt32>.stride
            && centroids.length >= totalGroups * MemoryLayout<SIMD4<Float>>.stride
            && radii.length >= totalGroups * MemoryLayout<Float>.stride
    }

    /// Rebuild CSR edge buffers and per-node group/centroid mapping.
    public func rebuildTopology(
        nodeCount n: Int,
        edges: [(Int, Int)],
        projectGroups: [Int],
        topicGroups: [Int],
        topicProjectGroup: [Int],
        galaxyGroups: [Int],
        galaxyCenters: [SIMD3<Float>],
        x: [Float], y: [Float], z: [Float]
    ) {
        let e = edges.count

        // Ensure node buffer capacity
        ensureNodeCapacity(n)

        // Build edge CSR: per-node (start, count) into flat edge array
        // JS uses per-node edge ranges pointing into a flattened edge list
        var edgesPerNode: [[Int]] = Array(repeating: [], count: n)
        for (idx, (s, t)) in edges.enumerated() {
            edgesPerNode[s].append(idx)
            edgesPerNode[t].append(idx)
        }

        // Flatten into CSR
        var flatEdges: [(UInt32, UInt32)] = []
        flatEdges.reserveCapacity(e * 2) // each edge referenced by both endpoints
        guard let erBuf = edgeRangeBuffer else { return }
        let erPtr = erBuf.contents().bindMemory(to: SIMD2<UInt32>.self, capacity: n)

        for i in 0..<n {
            erPtr[i] = SIMD2<UInt32>(UInt32(flatEdges.count), UInt32(edgesPerNode[i].count))
            for edgeIdx in edgesPerNode[i] {
                let (s, t) = edges[edgeIdx]
                flatEdges.append((UInt32(s), UInt32(t)))
            }
        }

        // Upload flat edges
        let flatEdgeCount = flatEdges.count
        if flatEdgeCount > edgeCapacity {
            let cap = max(flatEdgeCount * 2, 256)
            edgeBuffer = device.makeBuffer(length: cap * MemoryLayout<SIMD2<UInt32>>.stride, options: .storageModeShared)
            edgeCapacity = cap
        }
        if let eBuf = edgeBuffer, !flatEdges.isEmpty {
            let ePtr = eBuf.contents().bindMemory(to: SIMD2<UInt32>.self, capacity: flatEdgeCount)
            for (i, (s, t)) in flatEdges.enumerated() {
                ePtr[i] = SIMD2<UInt32>(s, t)
            }
        }
        csrEdgeCount = e

        let groupInputs = GroupInputs(
            nodeCount: n, projects: projectGroups, topics: topicGroups,
            topicProjects: topicProjectGroup, galaxies: galaxyGroups,
            galaxyCount: galaxyCenters.count)
        let previousTotalGroups = cachedNumProjects + cachedNumTopics + max(galaxyCenters.count, 1)
        if preparedGroupInputs != groupInputs
            || !groupBuffersAreValid(nodeCount: n, totalGroups: previousTotalGroups) {
            // Never retain a certificate for an incomplete preparation.
            preparedGroupInputs = nil
            guard prepareGroups(groupInputs) else { return }
            preparedGroupInputs = groupInputs
        }

        groupsDirty = false
        topologyDirtyForDispatch = false
        // Even edge-only edits reset the cadence: centroids and radii depend on
        // current positions, not just the reusable static group membership.
        tickCount = 0
    }

    private func prepareGroups(_ inputs: GroupInputs) -> Bool {
        let n = inputs.nodeCount
        let projectGroups = inputs.projects
        let topicGroups = inputs.topics
        let topicProjectGroup = inputs.topicProjects
        let galaxyGroups = inputs.galaxies
        let numProjects = max((projectGroups.max() ?? 0) + 1, 1)
        let numTopics = max((topicGroups.max() ?? 0) + 1, 1)
        let totalGroups = numProjects + numTopics + max(inputs.galaxyCount, 1)
        ensureCentroidCapacity(totalGroups)
        if groupMetadataBuffer == nil || groupMetadataBuffer!.length < 256 * MemoryLayout<UInt32>.stride {
            groupMetadataBuffer = device.makeBuffer(length: 256 * MemoryLayout<UInt32>.stride, options: .storageModeShared)
        }
        guard groupBuffersAreValid(nodeCount: n, totalGroups: totalGroups),
              let gBuf = groupBuffer, let cmBuf = centroidMappingBuffer,
              let gmBuf = groupMetadataBuffer else { return false }

        // Build per-node group buffer (int4: projId, topicId, galaxyId, 0)
        let gPtr = gBuf.contents().bindMemory(to: SIMD4<Int32>.self, capacity: n)
        for i in 0..<n {
            gPtr[i] = SIMD4<Int32>(
                Int32(projectGroups[i]),
                Int32(i < topicGroups.count ? topicGroups[i] : 0),
                Int32(i < galaxyGroups.count ? galaxyGroups[i] : 0),
                0
            )
        }
        groupUploadCount &+= 1

        // Per-node centroid mapping: (projCentroidIdx, topicCentroidIdx)
        let cmPtr = cmBuf.contents().bindMemory(to: SIMD2<UInt32>.self, capacity: n)
        for i in 0..<n {
            let projIdx = UInt32(projectGroups[i])
            let topicCentIdx = UInt32(numProjects + (i < topicGroups.count ? topicGroups[i] : 0))
            cmPtr[i] = SIMD2<UInt32>(projIdx, topicCentIdx)
        }

        // Group metadata: [0..numTopics) = topicToProject, [128..128+numProjects) = projectToGalaxy
        let gmPtr = gmBuf.contents().bindMemory(to: UInt32.self, capacity: 256)
        memset(gmPtr, 0, 256 * MemoryLayout<UInt32>.stride)
        // topicToProject[t] at index t
        for (t, projGroup) in topicProjectGroup.enumerated() where t < 128 {
            gmPtr[t] = UInt32(projGroup)
        }
        // projectToGalaxy[p] at index 128 + p
        if !galaxyGroups.isEmpty {
            // Build from node data: first node of each project determines its galaxy
            var projGalaxy = [Int](repeating: 0, count: numProjects)
            var projSeen = [Bool](repeating: false, count: numProjects)
            for i in 0..<n {
                let pg = projectGroups[i]
                if !projSeen[pg] {
                    projSeen[pg] = true
                    projGalaxy[pg] = i < galaxyGroups.count ? galaxyGroups[i] : 0
                }
            }
            for p in 0..<numProjects where p + 128 < 256 {
                gmPtr[128 + p] = UInt32(projGalaxy[p])
            }
        }

        cachedNumProjects = numProjects
        cachedNumTopics = numTopics
        return true
    }

    /// Rebuild topology from stashed edges (convenience for ForceEngine).
    public func rebuildTopology(
        nodeCount: Int, projectGroups: [Int], topicGroups: [Int],
        topicProjectGroup: [Int], galaxyGroups: [Int], galaxyCenters: [SIMD3<Float>],
        x: [Float], y: [Float], z: [Float]
    ) {
        guard topologyDirtyForDispatch else { return }
        rebuildTopology(
            nodeCount: nodeCount, edges: dispatchEdges,
            projectGroups: projectGroups, topicGroups: topicGroups,
            topicProjectGroup: topicProjectGroup,
            galaxyGroups: galaxyGroups, galaxyCenters: galaxyCenters,
            x: x, y: y, z: z
        )
    }

    // MARK: - CPU Centroid Computation (every 10 ticks)

    private func updateCentroids(
        x: [Float], y: [Float], z: [Float], n: Int,
        projectGroups: [Int], topicGroups: [Int],
        galaxyCenters: [SIMD3<Float>],
        numProjects: Int, numTopics: Int
    ) {
        let numGalaxies = max(galaxyCenters.count, 1)
        let totalGroups = numProjects + numTopics + numGalaxies
        ensureCentroidCapacity(totalGroups)

        guard let cBuf = centroidBuffer, let rBuf = refRadiusBuffer else { return }
        centroidUpdateCount &+= 1
        let cPtr = cBuf.contents().bindMemory(to: SIMD4<Float>.self, capacity: totalGroups)
        let rPtr = rBuf.contents().bindMemory(to: Float.self, capacity: numProjects)

        // Zero centroid buffer
        memset(cPtr, 0, totalGroups * MemoryLayout<SIMD4<Float>>.stride)

        // Accumulate project sums
        var projSums = [(Float, Float, Float, Float)](repeating: (0,0,0,0), count: numProjects)
        var topicSums = [(Float, Float, Float, Float)](repeating: (0,0,0,0), count: numTopics)

        for i in 0..<n {
            let pg = projectGroups[i]
            projSums[pg].0 += x[i]
            projSums[pg].1 += y[i]
            projSums[pg].2 += z[i]
            projSums[pg].3 += 1

            let tg = i < topicGroups.count ? topicGroups[i] : 0
            topicSums[tg].0 += x[i]
            topicSums[tg].1 += y[i]
            topicSums[tg].2 += z[i]
            topicSums[tg].3 += 1
        }

        // Write project centroids (mean)
        for p in 0..<numProjects {
            let (sx, sy, sz, count) = projSums[p]
            if count > 0 {
                cPtr[p] = SIMD4<Float>(sx / count, sy / count, sz / count, count)
            }
        }

        // Write topic centroids (mean)
        for t in 0..<numTopics {
            let (sx, sy, sz, count) = topicSums[t]
            if count > 0 {
                cPtr[numProjects + t] = SIMD4<Float>(sx / count, sy / count, sz / count, count)
            }
        }

        // Write galaxy centers
        for (gi, gc) in galaxyCenters.enumerated() {
            cPtr[numProjects + numTopics + gi] = SIMD4<Float>(gc.x, gc.y, gc.z, 1)
        }
        if galaxyCenters.isEmpty {
            cPtr[numProjects + numTopics] = SIMD4<Float>(0, 0, 0, 1)
        }

        // Compute 75th-percentile radius per project
        var projectRadii = [[Float]](repeating: [], count: numProjects)
        for i in 0..<n {
            let pg = projectGroups[i]
            let cx = cPtr[pg].x, cy = cPtr[pg].y, cz = cPtr[pg].z
            let dx = x[i] - cx, dy = y[i] - cy, dz = z[i] - cz
            let r = sqrt(dx*dx + dy*dy + dz*dz)
            projectRadii[pg].append(r)
        }
        let minRefRadius: Float = 30.0
        for p in 0..<numProjects {
            var radii = projectRadii[p]
            if radii.count < 2 {
                rPtr[p] = minRefRadius
                continue
            }
            radii.sort()
            let p75 = radii[radii.count * 3 / 4]
            rPtr[p] = max(minRefRadius, p75)
        }
    }

    // MARK: - Encode Forces

    /// Encode all 2 force compute passes into a compute encoder.
    /// (Charge + Spring+Structural. Integration is encoded separately by GPUSimulationState.)
    @discardableResult
    public func encodeForces(
        encoder: MTLComputeCommandEncoder,
        x: [Float], y: [Float], z: [Float],
        projectGroups: [Int], topicGroups: [Int],
        galaxyGroups: [Int], galaxyCenters: [SIMD3<Float>],
        chargeStrength: Float, crossChargeMultiplier: Float,
        sameTopicChargeScale: Float, sameProjectChargeScale: Float,
        springLength: Float, crossProjectSpringLength: Float, springStrength: Float,
        cohesionStrength: Float, centroidRepulsion: Float,
        topicCohesionStrength: Float, topicCentroidRepulsion: Float,
        centerStrength: Float,
        alpha: Float, damping: Float, maxSpeed: Float,
        recordDiagnostics: Bool = false
    ) -> GPULog.ForceMetadata? {
        let n = x.count
        var diagnostics = recordDiagnostics ? GPULog.ForceMetadata(nodes: n) : nil
        guard n > 1, isFullSimAvailable else {
            GPULog.log("ENCODE SKIP n=\(n) ready=\(isFullSimAvailable)")
            return diagnostics
        }

        ensureNodeCapacity(n)
        lastEncodedNodeCount = n
        tickCount += 1

        let numGalaxies = max(galaxyCenters.count, 1)

        // Upload positions to GPU
        guard let posBuf = positionBuffer, let forceBuf = forceBuffer,
              let grpBuf = groupBuffer else { return diagnostics }

        let posPtr = posBuf.contents().bindMemory(to: SIMD3<Float>.self, capacity: n)
        for i in 0..<n {
            posPtr[i] = SIMD3<Float>(x[i], y[i], z[i])
        }

        // Group buffer + project/topic counts change ONLY on topology edits.
        // Recompute + re-upload just then, not every frame.
        if groupsDirty {
            // This fallback does not prepare mapping/metadata together, so it
            // cannot preserve a complete static-group certificate.
            preparedGroupInputs = nil
            cachedNumProjects = max((projectGroups.max() ?? 0) + 1, 1)
            cachedNumTopics = max((topicGroups.max() ?? 0) + 1, 1)
            let gPtr = grpBuf.contents().bindMemory(to: SIMD4<Int32>.self, capacity: n)
            for i in 0..<n {
                gPtr[i] = SIMD4<Int32>(
                    Int32(projectGroups[i]),
                    Int32(i < topicGroups.count ? topicGroups[i] : 0),
                    Int32(i < galaxyGroups.count ? galaxyGroups[i] : 0),
                    0
                )
            }
            groupUploadCount &+= 1
            groupsDirty = false
        }
        let numProjects = cachedNumProjects
        let numTopics = cachedNumTopics
        diagnostics?.csrEdges = csrEdgeCount
        diagnostics?.projects = numProjects
        diagnostics?.topics = numTopics
        diagnostics?.galaxies = numGalaxies

        // Update centroids every 10 ticks (matches JS)
        if tickCount % 10 == 0 || tickCount <= 1 {
            updateCentroids(
                x: x, y: y, z: z, n: n,
                projectGroups: projectGroups, topicGroups: topicGroups,
                galaxyCenters: galaxyCenters,
                numProjects: numProjects, numTopics: numTopics
            )
        }

        // Ensure param buffers exist
        if chargeParamsBuffer == nil {
            chargeParamsBuffer = device.makeBuffer(length: MemoryLayout<ChargeParams>.stride, options: .storageModeShared)
        }
        if springParamsBuffer == nil {
            springParamsBuffer = device.makeBuffer(length: MemoryLayout<SpringParams>.stride, options: .storageModeShared)
        }

        let tgSize = 256

        // === PASS 1: Charge Forces ===
        // Determine brute-force vs BH
        var chargeSpan: Float = 0
        do {
            var mnX = x[0], mxX = x[0], mnY = y[0], mxY = y[0], mnZ = z[0], mxZ = z[0]
            for i in 1..<n {
                mnX = min(mnX, x[i]); mxX = max(mxX, x[i])
                mnY = min(mnY, y[i]); mxY = max(mxY, y[i])
                mnZ = min(mnZ, z[i]); mxZ = max(mxZ, z[i])
            }
            chargeSpan = max(mxX - mnX, max(mxY - mnY, mxZ - mnZ))
        }

        let useBH = bhChargePipeline != nil

        // Swap in async-built octree if available
        if let newTree = pendingTreeNodes.withLock({ val -> [OctreeNode]? in
            let r = val; val = nil; return r
        }) {
            bhTree.replace(with: newTree)
            treeCacheFrameAge = 0
        } else {
            treeCacheFrameAge += 1
        }

        if useBH, bhTree.nodes == nil || bhTreeDirty || treeCacheFrameAge >= treeCacheMaxAge {
            rebuildOctreeAsync(x: x, y: y, z: z, n: n)
            bhTreeDirty = false
        }

        if useBH, bhTree.nodes == nil {
            bhTree.replace(with: buildOctree(x: x, y: y, z: z, n: n))
            treeCacheFrameAge = 0
        }

        if useBH, let bhPL = bhChargePipeline, let treeNodes = bhTree.nodes {
            lastChargeAlgorithm = "BH"
            let treeCount = treeNodes.count
            if bhParamBuffer == nil {
                bhParamBuffer = device.makeBuffer(length: MemoryLayout<BHChargeParams>.stride, options: .storageModeShared)
            }

            if let treeBuf = bhTree.prepare(device: device), let bhPBuf = bhParamBuffer {
                let cutoff = max(500.0, chargeSpan * 0.3)
                bhPBuf.contents().bindMemory(to: BHChargeParams.self, capacity: 1).pointee = BHChargeParams(
                    chargeStrength: chargeStrength, crossChargeMultiplier: crossChargeMultiplier,
                    sameTopicChargeScale: sameTopicChargeScale, sameProjectChargeScale: sameProjectChargeScale,
                    cutoffSq: cutoff * cutoff, thetaSq: 0.85 * 0.85,
                    nodeCount: UInt32(n), treeNodeCount: UInt32(treeCount),
                    galaxyGroupCount: UInt32(numGalaxies), _bhpad: 0)

                encoder.setComputePipelineState(bhPL)
                encoder.setBuffer(posBuf, offset: 0, index: 0)
                encoder.setBuffer(forceBuf, offset: 0, index: 1)
                encoder.setBuffer(grpBuf, offset: 0, index: 2)
                encoder.setBuffer(treeBuf, offset: 0, index: 3)
                encoder.setBuffer(bhPBuf, offset: 0, index: 4)
                let chargeTg = min(Int(bhPL.maxTotalThreadsPerThreadgroup), tgSize)
                encoder.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                                       threadsPerThreadgroup: MTLSize(width: chargeTg, height: 1, depth: 1))
                diagnostics?.charge = .barnesHut
                diagnostics?.treeNodes = treeCount
                encoder.memoryBarrier(scope: .buffers)
            }
        } else {
            // Brute force O(n²)
            lastChargeAlgorithm = "BRUTE"

            if let cpBuf = chargeParamsBuffer {
                cpBuf.contents().bindMemory(to: ChargeParams.self, capacity: 1).pointee = ChargeParams(
                    nodeCount: UInt32(n),
                    chargeStrength: chargeStrength,
                    crossChargeMultiplier: crossChargeMultiplier,
                    sameProjectChargeScale: sameProjectChargeScale,
                    sameTopicChargeScale: sameTopicChargeScale,
                    cutoffSq: 250000, // 500² — matches JS
                    _pad0: 0, _pad1: 0)
            }

            encoder.setComputePipelineState(chargePipeline)
            encoder.setBuffer(posBuf, offset: 0, index: 0)
            encoder.setBuffer(forceBuf, offset: 0, index: 1)
            encoder.setBuffer(grpBuf, offset: 0, index: 2)
            if let cpBuf = chargeParamsBuffer { encoder.setBuffer(cpBuf, offset: 0, index: 3) }
            let chargeTg = min(Int(chargePipeline.maxTotalThreadsPerThreadgroup), tgSize)
            encoder.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                                   threadsPerThreadgroup: MTLSize(width: chargeTg, height: 1, depth: 1))
            diagnostics?.charge = .bruteForce
            encoder.memoryBarrier(scope: .buffers)
        }

        // === PASS 2: Spring + Structural Forces ===
        guard let springPL = springPipeline,
              let eBuf = edgeBuffer, let erBuf = edgeRangeBuffer,
              let cBuf = centroidBuffer, let cmBuf = centroidMappingBuffer,
              let spBuf = springParamsBuffer, let gmBuf = groupMetadataBuffer,
              let rBuf = refRadiusBuffer else { return diagnostics }

        spBuf.contents().bindMemory(to: SpringParams.self, capacity: 1).pointee = SpringParams(
            nodeCount: UInt32(n),
            edgeCount: UInt32(csrEdgeCount),
            alpha: alpha,
            springLength: springLength,
            crossProjectSpringLength: crossProjectSpringLength,
            springStrength: springStrength,
            centerStrength: centerStrength,
            cohesionStrength: cohesionStrength,
            topicCohesionStrength: topicCohesionStrength,
            centroidRepulsion: centroidRepulsion,
            topicCentroidRepulsion: topicCentroidRepulsion,
            numProjects: UInt32(numProjects),
            numTopics: UInt32(numTopics),
            minRefRadius: 30.0,
            numGalaxies: UInt32(numGalaxies),
            _pad0: 0)

        encoder.setComputePipelineState(springPL)
        encoder.setBuffer(posBuf, offset: 0, index: 0)
        encoder.setBuffer(forceBuf, offset: 0, index: 1)
        encoder.setBuffer(grpBuf, offset: 0, index: 2)
        encoder.setBuffer(eBuf, offset: 0, index: 3)
        encoder.setBuffer(erBuf, offset: 0, index: 4)
        encoder.setBuffer(cBuf, offset: 0, index: 5)
        encoder.setBuffer(cmBuf, offset: 0, index: 6)
        encoder.setBuffer(spBuf, offset: 0, index: 7)
        encoder.setBuffer(gmBuf, offset: 0, index: 8)
        encoder.setBuffer(rBuf, offset: 0, index: 9)
        let springTg = min(Int(springPL.maxTotalThreadsPerThreadgroup), tgSize)
        encoder.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                               threadsPerThreadgroup: MTLSize(width: springTg, height: 1, depth: 1))
        diagnostics?.structural = true
        encoder.memoryBarrier(scope: .buffers)

        GPULog.log("ENCODE END n=\(n) algo=\(lastChargeAlgorithm)")
        return diagnostics
    }

    // MARK: - Force Buffer Access

    /// Expose the GPU force output buffer for integration.
    public var outputForceBuffer: MTLBuffer? { forceBuffer }

    /// Read back force results from GPU shared buffer after command buffer completion.
    public func readBackForces() -> (fx: [Float], fy: [Float], fz: [Float])? {
        let n = lastEncodedNodeCount
        guard n > 0, let forceBuf = forceBuffer else { return nil }
        let forcePtr = forceBuf.contents().bindMemory(to: SIMD3<Float>.self, capacity: n)
        var fx = [Float](repeating: 0, count: n)
        var fy = [Float](repeating: 0, count: n)
        var fz = [Float](repeating: 0, count: n)
        for i in 0..<n { fx[i] = forcePtr[i].x; fy[i] = forcePtr[i].y; fz[i] = forcePtr[i].z }
        return (fx, fy, fz)
    }

    // MARK: - Async Octree

    func rebuildOctreeAsync(x: [Float], y: [Float], z: [Float], n: Int) {
        let alreadyBuilding = treeRebuildInFlight.withLock { val -> Bool in
            if val { return true }
            val = true
            return false
        }
        guard !alreadyBuilding else { return }
        let pending = pendingTreeNodes
        let inFlight = treeRebuildInFlight
        Task.detached(priority: .userInitiated) {
            let tree = buildOctree(x: x, y: y, z: z, n: n)
            pending.withLock { $0 = tree }
            inFlight.withLock { $0 = false }
        }
    }
}
