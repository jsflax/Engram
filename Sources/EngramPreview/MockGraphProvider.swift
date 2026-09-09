import Foundation
import simd
import Metal
import EngramRealityKit
import EngramSceneKit
import EngramMetalShaders
import EngramKit
import Lattice

/// Mock SceneDataProvider using ForceSimulation3D for realistic graph layout.
@Observable
@MainActor
final class MockGraphProvider: SceneDataProvider {
    private var random = PreviewRandomGenerator()

    private(set) var nodes: [RKNodeSnapshot] = []
    private(set) var edges: [RKEdgeSnapshot] = []
    private(set) var hubs: Set<UUID> = []
    private(set) var projectColorMap: [String: SIMD3<Float>] = [:]
    // Lazy passthrough to the sim's on-demand dict — reading this triggers a
    // one-time build only if a consumer (hitTest/teleport) actually needs it.
    var positions: [UUID: SIMD3<Float>] { simulation.positions }
    var positionVersion: UInt64 { simulation.positionVersion }
    /// Cached flat position array — built from sim arrays, avoids 23K UUID dict lookups per frame.
    private(set) var positionArray: [SIMD3<Float>] = []
    /// Maps nodes[i].id → simulation index for O(1) position lookup.
    @ObservationIgnored private var nodeToSimIndex: [UUID: Int] = [:]
    var glowingNodes: [UUID: Float] = [:]
    var newNodeGlows: [UUID: Float] = [:]
    var dyingNodes: Set<UUID> = []
    var selectedNode: UUID?
    var expandedHubs: Set<UUID> = []
    var searchMatchIds: Set<UUID> = []
    var isSearchActive: Bool = false
    var projectCentroids: [String: SIMD3<Float>] = [:]
    private(set) var topologyVersion: UInt64 = 0
    @ObservationIgnored private let nebulaCache = SingleGalaxyNebulaCache()
    var nebulaClusters: [RKNebulaCluster] { nebulaCache.clusters(for: self) }

    // MARK: - Multi-Galaxy State
    private(set) var projectToGalaxy: [String: String] = [:]
    private let galaxyCenters: [String: SIMD3<Float>] = [
        "personal": SIMD3<Float>(-2000, 0, 0),
        "synced":   SIMD3<Float>( 2000, 0, 0),
    ]
    var galaxyAssignment: [String: String] { projectToGalaxy }

    // MARK: - Instrumentation (gated on PREVIEW_INSTRUMENTATION=1)
    private var instrumentationEnabled = false
    private var instrumentLogPath = "/tmp/preview-instrumentation"
    private var frameFile: UnsafeMutablePointer<FILE>?
    private var frameIndex = 0
    private var wasSettled = false
    private var forceMsHistory: [Double] = []
    private var wallMsHistory: [Double] = []

    /// Number of nodes to generate.
    var nodeCount: Int = 200 {
        didSet { regenerateGraph() }
    }

    /// Project definitions with relative weight and associated topics.
    private let projectDefs: [(name: String, weight: Float, topics: [String])] = [
        ("Architecture", 0.30, ["rendering", "scene-graph", "ECS", "shaders", "camera"]),
        ("Debugging",    0.20, ["force-sim", "GPU-crash", "concurrency", "memory-leak"]),
        ("Patterns",     0.18, ["MVVM", "coordinator", "dependency-injection", "protocols"]),
        ("Workflow",     0.18, ["CI-CD", "testing", "code-review", "deploy"]),
        ("Preferences",  0.14, ["editor", "keybindings", "theme", "sync"]),
    ]

    /// Real force simulation for proper graph layout.
    let simulation = ForceSimulation3D()

    /// GPU force engine — nil if Metal unavailable.
    private var forceEngine: ForceEngine?
    private var commandQueue: MTLCommandQueue?

    /// Node ID → index mapping for reading simulation positions.
    private var nodeIds: [UUID] = []
    private var simIndexByNodeIndex: [Int] = []
    private var simIndexTopologyVersion: UInt64 = .max
    private var cachedPositionVersion: UInt64 = .max
    private var cachedPositionTopology: UInt64 = .max
    private var tickSubFrame: UInt64 = 0

    static let shared: MockGraphProvider = .init()

    private enum PreviewError: Error {
        case noMetalDevice
        case noCommandQueue
        case forceComputeInitFailed
    }
    
    private init() {
        // Set up GPU force engine. Failures here are fatal for the preview
        // (it exists to exercise the GPU path), so report the underlying
        // error on stderr — stdout's block buffer is lost when
        // preconditionFailure fires.
        do {
            guard let device = MTLCreateSystemDefaultDevice() else { throw PreviewError.noMetalDevice }
            guard let queue = device.makeCommandQueue() else { throw PreviewError.noCommandQueue }
            let library = try EngramMetalShaders.makeLibrary(device: device)
            guard let forceCompute = MetalForceCompute(device: device, library: library) else {
                throw PreviewError.forceComputeInitFailed
            }
            let simState = GPUSimulationState(device: device, library: library)
            self.forceEngine = ForceEngine(forceCompute: forceCompute, simState: simState)
            self.commandQueue = queue
            print("[preview] GPU force engine initialized")
        } catch {
            FileHandle.standardError.write("[preview] GPU force engine init FAILED: \(error)\n".data(using: .utf8)!)
            preconditionFailure("GPU force engine init failed: \(error)")
        }

        // Instrumentation setup (env vars)
        if ProcessInfo.processInfo.environment["PREVIEW_INSTRUMENTATION"] == "1" {
            instrumentationEnabled = true
            instrumentLogPath = ProcessInfo.processInfo.environment["PREVIEW_LOG_PATH"] ?? instrumentLogPath
            openFrameCSV()
        }
        if let countStr = ProcessInfo.processInfo.environment["PREVIEW_NODE_COUNT"],
           let count = Int(countStr) {
            nodeCount = count  // didSet doesn't fire in class init
        }

        // Load from Lattice if requested, otherwise use mock data
        if ProcessInfo.processInfo.environment["PREVIEW_USE_LATTICE"] == "1" {
            let personalPath = ProcessInfo.processInfo.environment["CLAUDE_MEMORY_DB"]
                ?? NSHomeDirectory() + "/.claude/memory.sqlite"
            // CLAUDE_SYNCED_DB mirrors CLAUDE_MEMORY_DB: without it, every
            // instrumented/baseline run opens the LIVE synced DB the daemon
            // is actively writing.
            let syncedPath = ProcessInfo.processInfo.environment["CLAUDE_SYNCED_DB"]
                ?? NSHomeDirectory() + "/.claude/sync/memory-synced.sqlite"
            loadFromLattice(
                personalDbPath: personalPath,
                syncedDbPath: FileManager.default.fileExists(atPath: syncedPath) ? syncedPath : nil
            )
        }

        // Fall back to mock data if Lattice didn't load or wasn't requested
        if nodes.isEmpty {
            regenerateGraph()
        }
    }

    private func nextID() -> UUID {
        let b = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &random) }
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// Pick a project index weighted by `projectDefs.weight`.
    private func weightedProjectIndex() -> Int {
        let r = Float.random(in: 0..<1, using: &random)
        var cum: Float = 0
        for (i, def) in projectDefs.enumerated() {
            cum += def.weight
            if r < cum { return i }
        }
        return projectDefs.count - 1
    }

    func tick(dt: Float) {
        let wallStart = instrumentationEnabled ? CFAbsoluteTimeGetCurrent() : 0
        let tsub0 = ProcessInfo.processInfo.environment["ENGRAM_FRAME_STATS"] != nil ? DispatchTime.now().uptimeNanoseconds : 0

        // Dispatch GPU forces asynchronously — never block main thread
        if let engine = forceEngine, let queue = commandQueue {
            let sim = simulation
            if !sim.isSettled, sim.nodeCount > 1, engine.isFullSimAvailable, !engine.isInFlight {
                let snapshot = ForceEngine.SimulationSnapshot(
                    nodeCount: sim.nodeCount, isSettled: sim.isSettled,
                    posX: sim.posX, posY: sim.posY, posZ: sim.posZ,
                    projectGroups: sim.projectGroupPublic, topicGroups: sim.topicGroupPublic,
                    topicProjectGroup: sim.topicProjectGroupPublic,
                    galaxyGroups: sim.galaxyGroupPublic, galaxyCenters: sim.galaxyCentersPublic,
                    edgeIndices: sim.edgeIndicesPublic, topologyDirty: sim.topologyDirtyForGPU,
                    chargeStrength: sim.chargeStrength, crossChargeMultiplier: sim.crossChargeMultiplier,
                    sameTopicChargeScale: sim.sameTopicChargeScale, sameProjectChargeScale: sim.sameProjectChargeScale,
                    springLength: sim.springLength, crossProjectSpringLength: sim.crossProjectSpringLength,
                    springStrength: sim.springStrength,
                    cohesionStrength: sim.cohesionStrength, centroidRepulsion: sim.centroidRepulsion,
                    topicCohesionStrength: sim.topicCohesionStrength, topicCentroidRepulsion: sim.topicCentroidRepulsion,
                    centerStrength: sim.centerStrength,
                    alpha: sim.alpha, damping: 0.78, maxSpeed: 12.0
                )
                sim.topologyDirtyForGPU = false
                let nodeOrderVersion = sim.nodeOrderVersion

                engine.encodeForcePass(queue: queue, snapshot: snapshot) { [weak self] result in
                    sim.applyGPUForces(result, expectedNodeOrderVersion: nodeOrderVersion)
                    // Log separation quality periodically
                    if sim.framesSinceWake % 60 == 1 || sim.isSettled {
                        self?.logSeparation(sim: sim)
                    }
                }
            }
        }

        let tsub = ProcessInfo.processInfo.environment["ENGRAM_FRAME_STATS"] != nil
        let t0 = tsub ? DispatchTime.now().uptimeNanoseconds : 0

        // Tick the force simulation (integrates whatever forces are available)
        simulation.tick()
        let t1 = tsub ? DispatchTime.now().uptimeNanoseconds : 0

        // positions is now a lazy passthrough — NOT read here, so a
        // render-only frame never materializes the 42k dict.
        let t2 = tsub ? DispatchTime.now().uptimeNanoseconds : 0

        // Build positionArray from sim's flat arrays — O(n), no UUID hashing.
        // The node→sim index map is flattened to [Int] on topology change:
        // 41k UUID dict lookups per frame cost ~30ms on their own.
        let px = simulation.posX, py = simulation.posY, pz = simulation.posZ
        let n = nodes.count
        if simIndexByNodeIndex.count != n || simIndexTopologyVersion != topologyVersion {
            // Build privately: repeated mutations of an observable dictionary
            // add unnecessary bookkeeping to the first 40k-node scene update.
            var mapping = nodeToSimIndex
            nodeToSimIndex = [:]
            mapping.removeAll(keepingCapacity: true)
            mapping.reserveCapacity(simulation.nodeCount)
            for (si, id) in simulation.nodeIds.enumerated() { mapping[id] = si }
            simIndexByNodeIndex = nodes.map { mapping[$0.id] ?? -1 }
            nodeToSimIndex = mapping
            simIndexTopologyVersion = topologyVersion
        }
        if cachedPositionVersion != positionVersion || cachedPositionTopology != topologyVersion {
            cachedPositionVersion = positionVersion
            cachedPositionTopology = topologyVersion
            if positionArray.count != n { positionArray = [SIMD3<Float>](repeating: .zero, count: n) }
            let pxc = px.count
            positionArray.withUnsafeMutableBufferPointer { out in
                simIndexByNodeIndex.withUnsafeBufferPointer { simIdx in
                    px.withUnsafeBufferPointer { xb in
                        py.withUnsafeBufferPointer { yb in
                            pz.withUnsafeBufferPointer { zb in
                                for i in 0..<n {
                                    let si = Int(simIdx[i])
                                    if si >= 0 && si < pxc {
                                        out[i] = SIMD3<Float>(xb[si], yb[si], zb[si])
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if tsub {
            let t3 = DispatchTime.now().uptimeNanoseconds
            tickSubFrame &+= 1
            if tickSubFrame % 120 == 11 {
                let ms = { (a: UInt64, b: UInt64) in Double(b &- a) / 1_000_000 }
                print("[tick-sub] frame=\(tickSubFrame) dispatch=\(String(format: "%.1f", ms(tsub0, t0))) simTick=\(String(format: "%.1f", ms(t0, t1))) posArray=\(String(format: "%.1f", ms(t2, t3))) inFlight=\(forceEngine?.isInFlight ?? false) settled=\(simulation.isSettled)")
            }
        }

        // Instrumentation: write per-frame CSV and check settlement
        if instrumentationEnabled {
            let wallMs = (CFAbsoluteTimeGetCurrent() - wallStart) * 1000
            let settled = simulation.isSettled
            wallMsHistory.append(wallMs)
            let minSep = computeMinProjSep()
            if let f = frameFile {
                let line = String(format: "%d,%.2f,0,0,0,0,async,%.4f,%.2f,%.1f,%d,%@\n",
                                  frameIndex, wallMs,
                                  simulation.alpha, simulation.lastMaxSpeedSq, minSep,
                                  simulation.nodeCount, settled ? "true" : "false")
                fputs(line, f)
                fflush(f)
            }
            frameIndex += 1
            if settled && !wasSettled {
                wasSettled = true
                writeClusterReport()
                writeSettledSignal()
            }
        }

        // Animate glow timers
        for (id, elapsed) in glowingNodes {
            glowingNodes[id] = elapsed + dt
            if elapsed + dt > 4.5 { glowingNodes.removeValue(forKey: id) }
        }
        for (id, elapsed) in newNodeGlows {
            newNodeGlows[id] = elapsed + dt
            if elapsed + dt > 5.8 { newNodeGlows.removeValue(forKey: id) }
        }

        // Recompute centroids occasionally
        if Int.random(in: 0..<60, using: &random) == 0 {
            computeCentroids()
        }
    }

    // MARK: - Graph Generation

    func regenerateGraph() {
        projectColorMap = [
            "Architecture": SIMD3<Float>(0.15, 0.55, 1.0),
            "Debugging":    SIMD3<Float>(1.0, 0.2, 0.25),
            "Patterns":     SIMD3<Float>(0.1, 0.85, 0.35),
            "Workflow":     SIMD3<Float>(1.0, 0.75, 0.0),
            "Preferences":  SIMD3<Float>(0.8, 0.2, 1.0),
        ]
        var newNodes: [RKNodeSnapshot] = []
        var newEdges: [RKEdgeSnapshot] = []
        var newHubs: Set<UUID> = []
        var ids: [UUID] = []
        var edgePairs: [(UUID, UUID)] = []
        var projectForNode: [UUID: String] = [:]
        var topicForNode: [UUID: String] = [:]

        // Nodes grouped by project → topic for intra-cluster edge wiring.
        var buckets: [String: [String: [UUID]]] = [:]

        // --- Generate nodes with weighted project distribution ---
        for i in 0..<nodeCount {
            let id = nextID()
            let pIdx = weightedProjectIndex()
            let def = projectDefs[pIdx]
            let project = def.name
            let topic = def.topics.randomElement(using: &random)!
            // Skew importance: hubs get 4-5, most nodes 1-3
            let isHub = i % 15 == 0
            let importance = isHub ? Int.random(in: 4...5, using: &random) : Int.random(in: 1...3, using: &random)

            newNodes.append(RKNodeSnapshot(
                id: id, project: project, topic: topic,
                label: "\(topic)_\(i)", importance: importance, isHub: isHub
            ))

            if isHub { newHubs.insert(id) }
            ids.append(id)
            projectForNode[id] = project
            topicForNode[id] = topic
            buckets[project, default: [:]][topic, default: []].append(id)
        }

        // --- Intra-topic edges (tight clusters) ---
        for (_, topics) in buckets {
            for (_, members) in topics where members.count >= 2 {
                // Chain within topic
                for i in 1..<members.count {
                    newEdges.append(RKEdgeSnapshot(
                        id: nextID(), sourceId: members[i - 1], targetId: members[i], relation: "relates_to"
                    ))
                    edgePairs.append((members[i - 1], members[i]))
                }
            }
        }

        // --- Intra-project / cross-topic edges (link topics within a project) ---
        for (_, topics) in buckets {
            let topicKeys = Array(topics.keys)
            guard topicKeys.count >= 2 else { continue }
            for i in 0..<topicKeys.count {
                let j = (i + 1) % topicKeys.count
                let a = topics[topicKeys[i]]!, b = topics[topicKeys[j]]!
                // A few bridges between adjacent topics
                let bridgeCount = max(1, min(a.count, b.count) / 3)
                for k in 0..<bridgeCount {
                    let src = a[k % a.count], tgt = b[k % b.count]
                    newEdges.append(RKEdgeSnapshot(
                        id: nextID(), sourceId: src, targetId: tgt, relation: "part_of"
                    ))
                    edgePairs.append((src, tgt))
                }
            }
        }

        // --- Cross-project edges (sparse, keep clusters separated) ---
        let crossCount = max(nodeCount / 25, 3)
        for _ in 0..<crossCount {
            let i = Int.random(in: 0..<newNodes.count, using: &random)
            var j = Int.random(in: 0..<newNodes.count, using: &random)
            // Ensure cross-project
            while newNodes[j].project == newNodes[i].project && newNodes.count > 1 {
                j = Int.random(in: 0..<newNodes.count, using: &random)
            }
            newEdges.append(RKEdgeSnapshot(
                id: nextID(), sourceId: newNodes[i].id, targetId: newNodes[j].id, relation: "derived_from"
            ))
            edgePairs.append((newNodes[i].id, newNodes[j].id))
        }

        self.nodes = newNodes
        self.edges = newEdges
        self.hubs = newHubs
        self.nodeIds = ids
        self.nodeToSimIndex.removeAll()  // force rebuild on next tick
        self.topologyVersion += 1

        // Feed into force simulation
        simulation.updateGraph(
            nodeIds: Set(ids),
            edges: edgePairs,
            projectForNode: projectForNode,
            topicForNode: topicForNode
        )

        // Multi-galaxy setup: first 3 projects → personal, last 2 → synced
        for (galaxyId, center) in galaxyCenters {
            simulation.setGalaxyCenter(galaxyId, center)
        }
        projectToGalaxy = [:]
        for (i, def) in projectDefs.enumerated() {
            projectToGalaxy[def.name] = i < 3 ? "personal" : "synced"
        }
        // Group node IDs by galaxy and assign
        var galaxyNodeIds: [String: Set<UUID>] = [:]
        for (id, project) in projectForNode {
            let galaxy = projectToGalaxy[project] ?? "personal"
            galaxyNodeIds[galaxy, default: []].insert(id)
        }
        for (galaxy, ids) in galaxyNodeIds {
            simulation.changeGalaxyGroup(for: ids, to: galaxy)
        }
        // Seed node positions near their galaxy center so clusters start separated
        var galaxyPositions: [UUID: SIMD3<Float>] = [:]
        for (galaxy, nodeSet) in galaxyNodeIds {
            guard let center = galaxyCenters[galaxy] else { continue }
            for id in nodeSet {
                let r = Float.random(in: 80...180, using: &random)
                let angle = Float.random(in: 0..<(.pi * 2), using: &random)
                let phi = Float.random(in: -0.5...0.5, using: &random)
                galaxyPositions[id] = center + SIMD3<Float>(
                    cos(angle) * cos(phi) * r,
                    sin(angle) * cos(phi) * r,
                    sin(phi) * r
                )
            }
        }
        simulation.setPositions(galaxyPositions)

        simulation.wake()

        // Reset instrumentation state for new graph
        if instrumentationEnabled {
            frameIndex = 0
            wasSettled = false
            forceMsHistory.removeAll()
            wallMsHistory.removeAll()
            if let f = frameFile { fclose(f) }
            openFrameCSV()
            try? FileManager.default.removeItem(atPath: "\(instrumentLogPath)-settled")
            try? FileManager.default.removeItem(atPath: "\(instrumentLogPath)-final.json")
        }

        // Read initial positions
        computeCentroids()

        // Demo glow effects
        if newNodes.count > 5 {
            glowingNodes[newNodes[2].id] = 0
            newNodeGlows[newNodes[4].id] = 0
        }
    }

    // MARK: - Lattice Loading

    /// Load graph data from real Lattice databases instead of mock data.
    func loadFromLattice(personalDbPath: String, syncedDbPath: String?) {
        var newNodes: [RKNodeSnapshot] = []
        var newEdges: [RKEdgeSnapshot] = []
        var newHubs: Set<UUID> = []
        var ids: [UUID] = []
        var edgePairs: [(UUID, UUID)] = []
        var projectForNode: [UUID: String] = [:]
        var topicForNode: [UUID: String] = [:]
        var nodeGalaxy: [UUID: String] = [:]
        var allProjects: Set<String> = []
        var partOfTargets: Set<UUID> = []

        func loadDB(path: String, galaxyId: String) {
            let config = Lattice.Configuration(
                fileURL: URL(fileURLWithPath: path),
                migration: engramMigrations
            )
            guard let lattice = try? Lattice(Memory.self, Edge.self, configuration: config) else {
                print("[preview] Failed to open Lattice at \(path)")
                return
            }

            var dbNodeIds: Set<UUID> = []
            for memory in lattice.objects(Memory.self) {
                guard let globalId = memory.globalId else { continue }
                let project = memory.project
                let topic = memory.topic

                newNodes.append(RKNodeSnapshot(
                    id: globalId,
                    project: project,
                    topic: topic,
                    label: String(memory.content.prefix(40)),
                    content: memory.content,
                    importance: memory.importance,
                    isHub: false,
                    createdAt: memory.createdAt,
                    lastAccessedAt: memory.lastAccessedAt
                ))
                ids.append(globalId)
                projectForNode[globalId] = project
                topicForNode[globalId] = topic
                nodeGalaxy[globalId] = galaxyId
                allProjects.insert(project)
                dbNodeIds.insert(globalId)
            }

            for edge in lattice.objects(Edge.self) {
                guard let globalId = edge.globalId else { continue }
                newEdges.append(RKEdgeSnapshot(
                    id: globalId,
                    sourceId: edge.sourceGlobalId,
                    targetId: edge.targetGlobalId,
                    relation: edge.relation.rawValue
                ))
                edgePairs.append((edge.sourceGlobalId, edge.targetGlobalId))
                if edge.relation == .partOf {
                    partOfTargets.insert(edge.targetGlobalId)
                }
            }

            print("[preview] Loaded \(dbNodeIds.count) nodes from \(galaxyId) (\(path))")
        }

        loadDB(path: personalDbPath, galaxyId: "personal")
        if let syncedPath = syncedDbPath {
            loadDB(path: syncedPath, galaxyId: "synced")
        }

        guard !newNodes.isEmpty else {
            print("[preview] No nodes loaded from Lattice, keeping mock data")
            return
        }

        // Mark hubs (targets of part_of edges)
        newHubs = partOfTargets
        newNodes = newNodes.map { node in
            guard partOfTargets.contains(node.id) else { return node }
            return RKNodeSnapshot(
                id: node.id, project: node.project, topic: node.topic,
                label: node.label, content: node.content,
                importance: max(node.importance, 4), isHub: true,
                createdAt: node.createdAt, lastAccessedAt: node.lastAccessedAt
            )
        }

        // Golden-angle hue spacing for project colors
        let sortedProjects = allProjects.sorted()
        let goldenAngle: Float = 137.508 / 360.0
        var newProjectColors: [String: SIMD3<Float>] = [:]
        for (i, project) in sortedProjects.enumerated() {
            let h = (Float(i) * goldenAngle).truncatingRemainder(dividingBy: 1.0)
            let c = Float(0.9) * Float(0.8)
            let x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
            let m = Float(0.9) - c
            let (r, g, b): (Float, Float, Float)
            switch h * 6 {
            case 0..<1: (r, g, b) = (c, x, 0)
            case 1..<2: (r, g, b) = (x, c, 0)
            case 2..<3: (r, g, b) = (0, c, x)
            case 3..<4: (r, g, b) = (0, x, c)
            case 4..<5: (r, g, b) = (x, 0, c)
            default:    (r, g, b) = (c, 0, x)
            }
            newProjectColors[project] = SIMD3<Float>(r + m, g + m, b + m)
        }

        // Filter edges to those with both endpoints present
        let nodeIdSet = Set(ids)
        let validEdges = newEdges.filter { nodeIdSet.contains($0.sourceId) && nodeIdSet.contains($0.targetId) }
        let validPairs = edgePairs.filter { nodeIdSet.contains($0.0) && nodeIdSet.contains($0.1) }

        self.nodes = newNodes
        self.edges = validEdges
        self.hubs = newHubs
        self.projectColorMap = newProjectColors
        self.nodeIds = ids
        self.topologyVersion += 1

        // Feed into force simulation
        simulation.updateGraph(
            nodeIds: Set(ids),
            edges: validPairs,
            projectForNode: projectForNode,
            topicForNode: topicForNode
        )

        // Multi-galaxy setup
        for (galaxyId, center) in galaxyCenters {
            simulation.setGalaxyCenter(galaxyId, center)
        }
        projectToGalaxy = [:]
        for (nodeId, galaxy) in nodeGalaxy {
            if let project = projectForNode[nodeId] {
                projectToGalaxy[project] = galaxy
            }
        }

        var galaxyNodeIds: [String: Set<UUID>] = [:]
        for (nodeId, galaxy) in nodeGalaxy {
            galaxyNodeIds[galaxy, default: []].insert(nodeId)
        }
        for (galaxy, gIds) in galaxyNodeIds {
            simulation.changeGalaxyGroup(for: gIds, to: galaxy)
        }

        // Seed positions near galaxy centers (wider spread for larger graphs)
        var galaxyPositions: [UUID: SIMD3<Float>] = [:]
        for (galaxy, nodeSet) in galaxyNodeIds {
            guard let center = galaxyCenters[galaxy] else { continue }
            for id in nodeSet {
                let r = Float.random(in: 80...400, using: &random)
                let angle = Float.random(in: 0..<(.pi * 2), using: &random)
                let phi = Float.random(in: -0.5...0.5, using: &random)
                galaxyPositions[id] = center + SIMD3<Float>(
                    cos(angle) * cos(phi) * r,
                    sin(angle) * cos(phi) * r,
                    sin(phi) * r
                )
            }
        }
        simulation.setPositions(galaxyPositions)
        simulation.wake()

        computeCentroids()

        // Reset instrumentation for new data
        if instrumentationEnabled {
            frameIndex = 0
            wasSettled = false
            forceMsHistory.removeAll()
            wallMsHistory.removeAll()
            if let f = frameFile { fclose(f) }
            openFrameCSV()
            try? FileManager.default.removeItem(atPath: "\(instrumentLogPath)-settled")
            try? FileManager.default.removeItem(atPath: "\(instrumentLogPath)-final.json")
        }

        print("[preview] Lattice load complete: \(nodes.count) nodes, \(edges.count) edges, \(sortedProjects.count) projects")
    }

    /// Insert a new node with arrival glow, wired to a random same-project node.
    func insertNewNode() {
        let pIdx = weightedProjectIndex()
        let def = projectDefs[pIdx]
        let project = def.name
        let topic = def.topics.randomElement(using: &random)!
        let id = nextID()

        let node = RKNodeSnapshot(
            id: id, project: project, topic: topic,
            label: "\(topic)_new_\(nodes.count)", importance: Int.random(in: 1...3, using: &random), isHub: false
        )
        nodes.append(node)
        nodeIds.append(id)

        // Wire to a random same-project node
        if let peer = nodes.filter({ $0.project == project && $0.id != id }).randomElement(using: &random) {
            edges.append(RKEdgeSnapshot(
                id: nextID(), sourceId: peer.id, targetId: id, relation: "relates_to"
            ))
            simulation.addEdge(from: peer.id, to: id)
        }

        let galaxyId = projectToGalaxy[project] ?? "personal"
        simulation.addNode(id, project: project, topic: topic, galaxyId: galaxyId)
        newNodeGlows[id] = 0
        topologyVersion += 1
    }

    /// Migrate a random project to the other galaxy. Returns (project, targetGalaxy) on success.
    @discardableResult
    func migrateRandomProject() -> (project: String, targetGalaxy: String)? {
        guard let project = projectDefs.randomElement(using: &random)?.name,
              let currentGalaxy = projectToGalaxy[project] else { return nil }
        let targetGalaxy = currentGalaxy == "personal" ? "synced" : "personal"
        projectToGalaxy[project] = targetGalaxy

        let nodeIdsToMigrate = Set(nodes.filter { $0.project == project }.map(\.id))
        guard !nodeIdsToMigrate.isEmpty else { return nil }

        simulation.changeGalaxyGroup(for: nodeIdsToMigrate, to: targetGalaxy)
        simulation.wake()
        return (project, targetGalaxy)
    }

    /// Compute centroid + radius for all nodes in a galaxy (for camera teleport).
    func galaxyBounds(_ galaxyId: String) -> (center: SIMD3<Float>, radius: Float) {
        let galaxyNodes = nodes.filter { projectToGalaxy[$0.project] == galaxyId }
        guard !galaxyNodes.isEmpty else {
            return (galaxyCenters[galaxyId] ?? .zero, 500)
        }
        var sum = SIMD3<Float>.zero
        var count: Float = 0
        for node in galaxyNodes {
            if let pos = positions[node.id] {
                sum += pos
                count += 1
            }
        }
        guard count > 0 else { return (galaxyCenters[galaxyId] ?? .zero, 500) }
        let centroid = sum / count
        var maxDist: Float = 0
        for node in galaxyNodes {
            if let pos = positions[node.id] {
                maxDist = max(maxDist, simd_length(pos - centroid))
            }
        }
        return (centroid, max(maxDist, 200))
    }

    private func computeCentroids() {
        var sums: [String: (sum: SIMD3<Float>, count: Int)] = [:]
        for node in nodes {
            guard let pos = positions[node.id] else { continue }
            let entry = sums[node.project] ?? (.zero, 0)
            sums[node.project] = (entry.sum + pos, entry.count + 1)
        }
        projectCentroids = sums.mapValues { $0.sum / Float($0.count) }
    }

    private func logSeparation(sim: ForceSimulation3D) {
        var projSums: [Int: (sum: SIMD3<Float>, count: Int)] = [:]
        for i in 0..<sim.nodeCount {
            let pg = sim.projectGroupPublic[i]
            let pos = SIMD3<Float>(sim.posX[i], sim.posY[i], sim.posZ[i])
            let e = projSums[pg] ?? (.zero, 0)
            projSums[pg] = (e.sum + pos, e.count + 1)
        }
        let centroids = projSums.mapValues { $0.sum / Float($0.count) }
        var minSep: Float = .infinity
        let keys = Array(centroids.keys).sorted()
        for i in 0..<keys.count {
            for j in (i+1)..<keys.count {
                minSep = min(minSep, simd_length(centroids[keys[i]]! - centroids[keys[j]]!))
            }
        }
        print("[preview] frame=\(sim.framesSinceWake) alpha=\(String(format:"%.4f",sim.alpha)) maxSpeedSq=\(String(format:"%.2f",sim.lastMaxSpeedSq)) sep=\(String(format:"%.0f",minSep)) settled=\(sim.isSettled)")
    }

    // MARK: - Instrumentation Helpers

    /// Replace NaN/infinity with 0 for JSON safety.
    private func safe(_ v: Double) -> Double { v.isFinite ? v : 0 }
    private func safe(_ v: Float) -> Double { Double(v).isFinite ? Double(v) : 0 }

    private func openFrameCSV() {
        let csvPath = "\(instrumentLogPath)-frames.csv"
        frameFile = fopen(csvPath, "w")
        if let f = frameFile {
            fputs("frame,wall_ms,force_ms,cpu_prep_ms,gpu_ms,readback_ms,algo,alpha,maxSpeedSq,minProjSep,nodeCount,settled\n", f)
            fflush(f)
        }
    }

    private func computeMinProjSep() -> Float {
        let sim = simulation
        guard sim.nodeCount > 0 else { return 0 }
        var projSums: [Int: (sum: SIMD3<Float>, count: Int)] = [:]
        for i in 0..<sim.nodeCount {
            let pg = sim.projectGroupPublic[i]
            let pos = SIMD3<Float>(sim.posX[i], sim.posY[i], sim.posZ[i])
            let e = projSums[pg] ?? (.zero, 0)
            projSums[pg] = (e.sum + pos, e.count + 1)
        }
        let centroids = projSums.mapValues { $0.sum / Float($0.count) }
        var minSep: Float = .infinity
        let keys = Array(centroids.keys).sorted()
        for i in 0..<keys.count {
            for j in (i+1)..<keys.count {
                minSep = min(minSep, simd_length(centroids[keys[i]]! - centroids[keys[j]]!))
            }
        }
        return minSep == .infinity ? 0 : minSep
    }

    private func writeClusterReport() {
        let sim = simulation
        let simIds = sim.nodeIds

        // Build UUID → node info lookup
        var idToProject: [UUID: String] = [:]
        var idToTopic: [UUID: String] = [:]
        var idToLabel: [UUID: String] = [:]
        for node in nodes {
            idToProject[node.id] = node.project
            idToTopic[node.id] = node.topic
            idToLabel[node.id] = node.label
        }

        // Gather positions grouped by project and topic
        var projectPositions: [String: [SIMD3<Float>]] = [:]
        var topicPositions: [String: [String: [SIMD3<Float>]]] = [:]
        struct NodeInfo { let label: String; let project: String; let pos: SIMD3<Float> }
        var allNodeInfo: [NodeInfo] = []

        for i in 0..<sim.nodeCount {
            guard i < simIds.count else { break }
            let id = simIds[i]
            let pos = SIMD3<Float>(sim.posX[i], sim.posY[i], sim.posZ[i])
            let project = idToProject[id] ?? "Unknown"
            let topic = idToTopic[id] ?? "Unknown"
            let label = idToLabel[id] ?? "?"
            projectPositions[project, default: []].append(pos)
            topicPositions[project, default: [:]][topic, default: []].append(pos)
            allNodeInfo.append(NodeInfo(label: label, project: project, pos: pos))
        }

        // Project centroids and P75 radii
        var projCentroids: [String: SIMD3<Float>] = [:]
        var projRadii: [String: Float] = [:]
        var projCounts: [String: Int] = [:]

        for (project, positions) in projectPositions {
            let centroid = positions.reduce(SIMD3<Float>.zero, +) / Float(positions.count)
            projCentroids[project] = centroid
            projCounts[project] = positions.count
            let dists = positions.map { simd_length($0 - centroid) }.sorted()
            projRadii[project] = dists[dists.count * 3 / 4]
        }

        // Topic centroids and P75 radii per project
        struct TopicCluster { let name: String; let centroid: SIMD3<Float>; let radiusP75: Float; let nodeCount: Int }
        var projectTopicClusters: [String: [TopicCluster]] = [:]

        for (project, topics) in topicPositions {
            for (topic, positions) in topics {
                let centroid = positions.reduce(SIMD3<Float>.zero, +) / Float(positions.count)
                let dists = positions.map { simd_length($0 - centroid) }.sorted()
                let r75 = dists.isEmpty ? Float(0) : dists[dists.count * 3 / 4]
                projectTopicClusters[project, default: []].append(
                    TopicCluster(name: topic, centroid: centroid, radiusP75: r75, nodeCount: positions.count)
                )
            }
        }

        // Project separation
        let projNames = Array(projCentroids.keys).sorted()
        var pairs: [(String, String, Float)] = []
        var minProjSep: Float = .infinity
        var totalProjSep: Float = 0
        var pairCount = 0
        for i in 0..<projNames.count {
            for j in (i+1)..<projNames.count {
                let d = simd_length(projCentroids[projNames[i]]! - projCentroids[projNames[j]]!)
                pairs.append((projNames[i], projNames[j], d))
                minProjSep = min(minProjSep, d)
                totalProjSep += d
                pairCount += 1
            }
        }
        let avgProjSep = pairCount > 0 ? totalProjSep / Float(pairCount) : 0

        // Per-project compactness and separation quality
        // R50 = median distance to centroid, compactness = R50/R75 (tight≈0.65, fragmented<0.4)
        // sepRatio = dist to nearest other project / R75 (>2 = clear gap, <1 = overlapping)
        var projR50: [String: Float] = [:]
        for (project, positions) in projectPositions {
            guard let centroid = projCentroids[project] else { continue }
            let dists = positions.map { simd_length($0 - centroid) }.sorted()
            projR50[project] = dists[dists.count / 2]
        }

        // Topic separation per project + topic overlap rate
        // topicOverlapRate = fraction of nodes closer to a *different* topic centroid than their own
        var topicSepEntries: [[String: Any]] = []
        for project in projNames {
            let topics = projectTopicClusters[project] ?? []
            var minSep: Float = .infinity
            var totalSep: Float = 0
            var count = 0
            for i in 0..<topics.count {
                for j in (i+1)..<topics.count {
                    let d = simd_length(topics[i].centroid - topics[j].centroid)
                    minSep = min(minSep, d)
                    totalSep += d
                    count += 1
                }
            }

            // Topic overlap: for each node in this project, check if it's closer to
            // a different topic's centroid than its own topic's centroid
            var topicOverlapCount = 0
            var topicNodeCount = 0
            let topicCentroidMap = Dictionary(uniqueKeysWithValues: topics.map { ($0.name, $0.centroid) })
            if let projTopics = topicPositions[project] {
                for (topic, positions) in projTopics {
                    guard let myCentroid = topicCentroidMap[topic] else { continue }
                    for pos in positions {
                        topicNodeCount += 1
                        let myDist = simd_length(pos - myCentroid)
                        for (otherTopic, otherCentroid) in topicCentroidMap where otherTopic != topic {
                            if simd_length(pos - otherCentroid) < myDist {
                                topicOverlapCount += 1
                                break
                            }
                        }
                    }
                }
            }

            let r75 = projRadii[project] ?? 1
            let r50 = projR50[project] ?? 0
            // Distance to nearest other project centroid
            var nearestProjDist: Float = .infinity
            if let c = projCentroids[project] {
                for (other, oc) in projCentroids where other != project {
                    nearestProjDist = min(nearestProjDist, simd_length(c - oc))
                }
            }
            topicSepEntries.append([
                "project": project,
                "minSep": safe(count > 0 ? minSep : 0),
                "avgSep": safe(count > 0 ? totalSep / Float(count) : 0),
                "topicCount": topics.count,
                "topicOverlapRate": safe(topicNodeCount > 0 ? Float(topicOverlapCount) / Float(topicNodeCount) : 0),
                "compactness": safe(r50 / r75),
                "sepRatio": safe(nearestProjDist / r75)
            ] as [String: Any])
        }

        // Global sep/radius ratio — the single most important quality metric
        let meanR75 = projRadii.values.reduce(Float(0), +) / Float(max(projRadii.count, 1))
        let sepRadiusRatio = meanR75 > 0 ? (minProjSep == .infinity ? 0 : minProjSep) / meanR75 : 0

        // Straggler detection: nodes closer to a different project's centroid than their own
        var stragglerNodes: [[String: Any]] = []
        for info in allNodeInfo {
            guard let myCentroid = projCentroids[info.project] else { continue }
            let myDist = simd_length(info.pos - myCentroid)
            for (proj, centroid) in projCentroids where proj != info.project {
                if simd_length(info.pos - centroid) < myDist {
                    stragglerNodes.append([
                        "label": info.label,
                        "project": info.project,
                        "nearestWrong": proj
                    ])
                    break
                }
            }
        }

        // Performance percentiles from accumulated frame history
        let sortedForce = forceMsHistory.sorted()
        let sortedWall = wallMsHistory.sorted()
        func pct(_ sorted: [Double], _ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(Int(Double(sorted.count) * p), sorted.count - 1)]
        }

        // Build JSON via dictionaries — all floats sanitized to avoid NaN/infinity
        let report: [String: Any] = [
            "nodeCount": sim.nodeCount,
            "edgeCount": edges.count,
            "framesToSettle": frameIndex,
            "projects": projNames.map { proj -> [String: Any] in
                let c = projCentroids[proj]!
                return [
                    "name": proj,
                    "centroid": [safe(c.x), safe(c.y), safe(c.z)],
                    "radiusP75": safe(projRadii[proj] ?? 0),
                    "nodeCount": projCounts[proj] ?? 0,
                    "topics": (projectTopicClusters[proj] ?? []).map { t -> [String: Any] in
                        [
                            "name": t.name,
                            "centroid": [safe(t.centroid.x), safe(t.centroid.y), safe(t.centroid.z)],
                            "radiusP75": safe(t.radiusP75),
                            "nodeCount": t.nodeCount
                        ]
                    }
                ]
            },
            "projectSeparation": [
                "min": safe(minProjSep),
                "avg": safe(avgProjSep),
                "sepRadiusRatio": safe(sepRadiusRatio),
                "pairs": pairs.map { [$0.0, $0.1, safe($0.2)] as [Any] }
            ] as [String: Any],
            "topicSeparation": topicSepEntries,
            "stragglers": [
                "count": stragglerNodes.count,
                "rate": safe(Double(stragglerNodes.count) / Double(max(sim.nodeCount, 1))),
                "nodes": Array(stragglerNodes.prefix(20))
            ] as [String: Any],
            "performance": [
                "forceMs": [
                    "p50": safe(pct(sortedForce, 0.5)),
                    "p95": safe(pct(sortedForce, 0.95)),
                    "max": safe(sortedForce.last ?? 0)
                ] as [String: Any],
                "wallMs": [
                    "p50": safe(pct(sortedWall, 0.5)),
                    "p95": safe(pct(sortedWall, 0.95)),
                    "max": safe(sortedWall.last ?? 0)
                ] as [String: Any]
            ] as [String: Any]
        ]

        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            try? json.write(toFile: "\(instrumentLogPath)-final.json", atomically: true, encoding: .utf8)
        }
    }

    private func writeSettledSignal() {
        FileManager.default.createFile(atPath: "\(instrumentLogPath)-settled", contents: nil)
    }
}

/// SplitMix64 makes profiling fixtures repeatable with PREVIEW_SEED.
private struct PreviewRandomGenerator: RandomNumberGenerator {
    private var state: UInt64 = ProcessInfo.processInfo.environment["PREVIEW_SEED"]
        .flatMap(UInt64.init) ?? UInt64.random(in: .min ... .max)

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
