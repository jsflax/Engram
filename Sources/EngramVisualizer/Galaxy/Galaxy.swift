import SwiftUI
import EngramSceneKit
import Lattice
import EngramSceneKit
import Combine
import EngramKit
import os

private let flushLog = Logger(subsystem: "io.engram.app", category: "GalaxyLoader")
private let stallLog = OSLog(subsystem: "io.engram.app", category: "FrameStall")

/// Atomic update produced by the Galaxy actor, consumed by MainActor render loop.
/// Written via OSAllocatedUnfairLock from the Galaxy actor (observer callbacks + loadData).
/// Drained once per frame in renderTick — ensures store + simulation are always consistent.
struct RenderUpdate: Sendable {
    // Incremental changes (from observers)
    var insertedNodes: [(pk: Int64, node: NodeData)] = []
    // pk rides along so a node entering the galaxy's partition via the
    // update path (unknown to the render store) can take the insert route.
    var updatedNodes: [(pk: Int64, node: NodeData)] = []
    var removedNodePks: [Int64] = []
    var insertedEdges: [(pk: Int64, edge: EdgeData)] = []
    var updatedEdges: [EdgeData] = []
    var removedEdgeGids: [UUID] = []

    // Bulk load (initial — replaces entire edge store, batches nodes)
    var bulkEdges: (allEdges: [UUID: EdgeData],
                    pkToGid: [Int64: UUID],
                    byNode: [UUID: [EdgeData]])?
    var bulkEdgeCounts: [UUID: Int]?
    var bulkNodeBatches: [[(pk: Int64, node: NodeData)]] = []
    var clusterGroups: [[UUID]]?
    var finalize: Bool = false  // recomputeDerivedData + wake sim + mark loaded

    var isEmpty: Bool {
        insertedNodes.isEmpty && updatedNodes.isEmpty && removedNodePks.isEmpty &&
        insertedEdges.isEmpty && updatedEdges.isEmpty && removedEdgeGids.isEmpty &&
        bulkEdges == nil && bulkEdgeCounts == nil && bulkNodeBatches.isEmpty && clusterGroups == nil && !finalize
    }
}

/// Per-frame config snapshot consumed by the drain. Built once per frame by
/// MetalSceneManager from VisualizerConfig + layout mode, stored on GalaxyRegistry.
struct DrainConfig: Sendable {
    let hiddenProjects: Set<String>
    let hiddenRelations: Set<String>
    let timeFilter: Date?
    let is3D: Bool
    let soundEnabled: Bool
    let notificationsEnabled: Bool
}

/// Built during the same bounded slices that insert initial nodes. A reference
/// type keeps nested dictionary/array mutation in-place across those slices.
@MainActor
private final class InitialLoadDerivedData {
    var isValid: Bool
    var expectedTopology: UInt64
    let hiddenProjects: Set<String>
    let hiddenRelations: Set<String>
    let timeFilter: Date?
    var projects: Set<String> = []
    var topics: [String: (topic: String, project: String, ids: [UUID])] = [:]
    var relationCounts: [String: Int] = [:]
    var countedSelfEdges: Set<UUID> = []

    init(store: GraphRenderStore, config: DrainConfig) {
        isValid = store.allNodes.isEmpty && store.nodes.isEmpty
        expectedTopology = store.topologyVersion
        hiddenProjects = config.hiddenProjects
        hiddenRelations = config.hiddenRelations
        timeFilter = config.timeFilter
    }

    func validate(store: GraphRenderStore, config: DrainConfig) {
        isValid = isValid && expectedTopology == store.topologyVersion
            && hiddenProjects == config.hiddenProjects && hiddenRelations == config.hiddenRelations
            && timeFilter == config.timeFilter
    }
}

/// Encapsulates one complete graph data pipeline: Lattice + RenderStore + Simulation + EmbeddingProjection.
/// Each Galaxy renders as a separate cluster in the 3D world.
/// Serializes the cluster pass across all galaxies. The body is deliberately
/// synchronous — no suspension points, so actor reentrancy cannot interleave
/// two galaxies' passes.
private actor ClusterPassGate {
    static let shared = ClusterPassGate()
    func run<T: Sendable>(_ body: @Sendable () -> T) -> T { body() }
}

actor Galaxy: Identifiable {
    let id: String                        // e.g. "personal", "synced", "team-a-bob"
    let displayName: String
    let latticeRef: LatticeThreadSafeReference
    let hierarchyLevel: Int               // 0 = individual, 1 = team hive, 2 = org
    let parentGalaxyId: String?           // nil for root-level

    // Per-galaxy pipeline
    @MainActor let renderStore = GraphRenderStore()
    @MainActor let embeddingProjection = EmbeddingProjection()

    /// Reference to the unified simulation owned by GalaxyRegistry.
    /// Set during register(). All node/edge ops go through this.
    @MainActor weak var simulation3D: ForceSimulation3D?
    @MainActor weak var registry: GalaxyRegistry?


    /// Lock-protected update buffer — written by Galaxy actor, drained by MainActor.
    let pendingUpdate = OSAllocatedUnfairLock<RenderUpdate>(initialState: .init())

    /// Lock-protected pk→gid mirror for edges — maintained alongside pendingUpdate so
    /// the edge delete observer can resolve pk→gid without dispatching to MainActor.
    let edgePkToGidLock = OSAllocatedUnfairLock<[Int64: UUID]>(initialState: [:])

    // World-space center (set by GalaxyRegistry.computeWorldLayout)
    @MainActor var worldCenter: SIMD3<Float> = .zero

    // Per-galaxy node filter (for data partitioning — prevents duplication across galaxies)
    // Local galaxy: { !syncedProjects.contains($0.project) || $0.isPrivate }
    // Synced/team galaxies: nil (show everything in that DB)
    // Lock-protected (not actor state): the live observers apply it from
    // Lattice's background callback thread, outside this actor — without
    // observer-path filtering, every post-load memory appeared in BOTH the
    // personal and synced galaxies until restart.
    private let nodeFilterLock = OSAllocatedUnfairLock<(@Sendable (Memory) -> Bool)?>(initialState: nil)
    nonisolated var nodeFilter: (@Sendable (Memory) -> Bool)? {
        nodeFilterLock.withLock { $0 }
    }
    nonisolated func setNodeFilter(_ filter: (@Sendable (Memory) -> Bool)?) {
        nodeFilterLock.withLock { $0 = filter }
    }

    /// effectiveProject resolution (decision 13) for GROUP galaxies: members
    /// derive `project` from their own folder names, so the same shared
    /// project arrives under each author's local string. The resolver maps
    /// (authorUserId, localProject) → the group's canonical name, so
    /// clusters, labels, nebulae, and stats group by ONE project instead of
    /// one per member. Nil (personal/synced) is identity. Same lock idiom as
    /// nodeFilter — the observer path reads it off-actor.
    private let projectResolverLock =
        OSAllocatedUnfairLock<(@Sendable (_ author: UUID?, _ local: String) -> String)?>(initialState: nil)
    nonisolated var projectResolver: (@Sendable (UUID?, String) -> String)? {
        projectResolverLock.withLock { $0 }
    }
    nonisolated func setProjectResolver(_ resolver: (@Sendable (UUID?, String) -> String)?) {
        projectResolverLock.withLock { $0 = resolver }
    }

    /// Resolved display project for a memory in this galaxy.
    nonisolated func displayProject(_ memory: Memory) -> String {
        projectResolver?(memory.authorUserId, memory.project) ?? memory.project
    }
    
    // Per-galaxy mascot fleet (nil until Metal device is available)
    @MainActor var mascotFleet: MascotFleet?

    #if ENGRAM_INSTRUMENTATION
    @MainActor var glowLogFile: UnsafeMutablePointer<FILE>? = nil
    @MainActor var flushTimingFile: UnsafeMutablePointer<FILE>? = nil
    #endif

    @MainActor var isLoaded = false
    @MainActor var isInitialLoad = true
    @MainActor private var loadingUpdate: RenderUpdate?
    @MainActor private var loadingBatchIndex = 0
    @MainActor private var initialDerivedData: InitialLoadDerivedData?
    @MainActor var isDrainingInitialSnapshot: Bool { loadingUpdate != nil }

    /// Actor-isolated in-flight flag for loadData. The `isLoaded` guard alone
    /// is racy: it hops to MainActor (a suspension point), so two callers —
    /// onAppear's load and the daemon-connect re-load — can both read `false`
    /// and each run a full-DB scan. The scans serialize on this actor (no
    /// data race), but doubling multi-GB scans is exactly the page-cache
    /// pressure that triggered the sqlite OOM crash. Checked and set
    /// synchronously on the actor, before any await — no window.
    private var loadInFlight = false

    @MainActor init(id: String, displayName: String, lattice: LatticeThreadSafeReference,
         hierarchyLevel: Int = 0, parentGalaxyId: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.latticeRef = lattice
        self.hierarchyLevel = hierarchyLevel
        self.parentGalaxyId = parentGalaxyId
    }
    
    var nodeObserver: AnyCancellable?
    var edgeObserver: AnyCancellable?

    /// Set up live Lattice observers. Callbacks push raw data into pendingUpdate —
    /// all filtering (hidden projects/relations, time) happens during drain via DrainConfig.
    func startObservers() {
        guard !Task.isCancelled else { return }
        // Sign-out (or any teardown) can invalidate the lattice while the
        // initial load is still in flight — observers just don't start.
        // Crashing here took the app down when signing out mid-load.
        guard let lattice = latticeRef.resolve() else { return }

        edgeObserver = lattice.objects(MemoryEdge.self).observe { [pendingUpdate, edgePkToGidLock] change in
            // Lattice torn down (sign-out) — drop the change, observer dies with it.
            guard let bg = self.latticeRef.resolve() else { return }
            switch change {
            case .insert(let pk):
                guard let edge = bg.object(MemoryEdge.self, primaryKey: pk),
                      let gid = edge.globalId else { return }
                let data = EdgeData(id: gid, sourceId: edge.sourceGlobalId,
                                    targetId: edge.targetGlobalId, relation: edge.relation.rawValue)
                edgePkToGidLock.withLock { $0[pk] = gid }
                pendingUpdate.withLock { $0.insertedEdges.append((pk, data)) }
            case .update(let pk):
                guard let edge = bg.object(MemoryEdge.self, primaryKey: pk),
                      let gid = edge.globalId else { return }
                let data = EdgeData(id: gid, sourceId: edge.sourceGlobalId,
                                    targetId: edge.targetGlobalId, relation: edge.relation.rawValue)
                pendingUpdate.withLock { $0.updatedEdges.append(data) }
            case .delete(let pk):
                // Resolve pk→gid under lock, push to pendingUpdate for drain processing.
                // No MainActor dispatch needed — the lock mirror is maintained alongside
                // pendingUpdate on inserts and bulk loads.
                guard let gid = edgePkToGidLock.withLock({ $0.removeValue(forKey: pk) }) else { return }
                pendingUpdate.withLock { $0.removedEdgeGids.append(gid) }
            }
        }

        nodeObserver = lattice.objects(Memory.self).observe { [pendingUpdate] change in
            // Lattice torn down (sign-out) — drop the change, observer dies with it.
            guard let bg = self.latticeRef.resolve() else { return }
            switch change {
            case .insert(let pk):
                guard let memory = bg.object(Memory.self, primaryKey: pk),
                      let gid = memory.globalId else { return }
                // Same structural partition loadData applies — without it a
                // post-load memory lands in every galaxy whose DB has it.
                if let filter = self.nodeFilter, !filter(memory) { return }
                let node = NodeData(
                    id: gid, project: self.displayProject(memory), topic: memory.topic,
                    label: extractLabel(content: memory.content, topic: memory.topic),
                    content: memory.content,
                    createdAt: memory.createdAt, lastAccessedAt: memory.lastAccessedAt,
                    importance: memory.importance)
                pendingUpdate.withLock { $0.insertedNodes.append((pk, node)) }
            case .update(let pk):
                guard let memory = bg.object(Memory.self, primaryKey: pk),
                      let gid = memory.globalId else { return }
                if let filter = self.nodeFilter, !filter(memory) {
                    // Fell out of this galaxy's partition (e.g. project
                    // toggled to sync) — remove; no-op if never present.
                    pendingUpdate.withLock { $0.removedNodePks.append(pk) }
                    return
                }
                let node = NodeData(
                    id: gid, project: self.displayProject(memory), topic: memory.topic,
                    label: extractLabel(content: memory.content, topic: memory.topic),
                    content: memory.content,
                    createdAt: memory.createdAt, lastAccessedAt: memory.lastAccessedAt,
                    importance: memory.importance)
                pendingUpdate.withLock { $0.updatedNodes.append((pk, node)) }
            case .delete(let pk):
                pendingUpdate.withLock { $0.removedNodePks.append(pk) }
            }
        }
    }

    func stopObservers() {
        nodeObserver?.cancel()
        edgeObserver?.cancel()
        nodeObserver = nil
        edgeObserver = nil
    }
    
    /// Load all data from a galaxy's Lattice into its renderStore + simulation.
    /// Reads ALL data — visual filtering (hiddenProjects, etc.) happens during
    /// drain via DrainConfig. Only `nodeFilter` (structural partition) is applied here.
    func loadData() async {
        guard !Task.isCancelled else { return }
        // Guard against duplicate loads (onAppear + syncManager.didConnect can
        // both fire). loadInFlight is checked/set synchronously on the actor
        // — airtight; the isLoaded check alone suspends and lets both through.
        guard !loadInFlight else { return }
        loadInFlight = true
        defer { loadInFlight = false }
        guard await !isLoaded else { return }

        let batchSize = 50
        let ref = latticeRef
        let nodeFilter = nodeFilter
        let projectResolver = projectResolver

        guard let bgLattice = ref.resolve() else { return }

        // 1. Read all edges AND build dictionaries off main actor.
        var allEdges: [UUID: EdgeData] = [:]
        var edgePkToGlobalId: [Int64: UUID] = [:]
        var edgesByNode: [UUID: [EdgeData]] = [:]
        for e in bgLattice.objects(MemoryEdge.self) {
            guard !Task.isCancelled else { return }
            guard let (pk, ed) = Self.snapshotEdge(e) else { continue }
            allEdges[ed.id] = ed
            edgePkToGlobalId[pk] = ed.id
            edgesByNode[ed.sourceId, default: []].append(ed)
            edgesByNode[ed.targetId, default: []].append(ed)
        }

        // Push bulk edges into the update buffer + populate pk→gid lock mirror
        let finalEdges = allEdges
        let finalPkToGid = edgePkToGlobalId
        let finalByNode = edgesByNode
        let finalEdgeCounts = edgesByNode.mapValues(\.count)
        edgePkToGidLock.withLock { $0 = finalPkToGid }
        pendingUpdate.withLock {
            $0.bulkEdges = (finalEdges, finalPkToGid, finalByNode)
            $0.bulkEdgeCounts = finalEdgeCounts
        }

        // 2. Read nodes in batches — all off MainActor
        var nodeBatch: [(pk: Int64, node: NodeData)] = []
        var allProjects = Set<String>()
        for m in bgLattice.objects(Memory.self) {
            guard !Task.isCancelled else { return }
            guard let record = Self.snapshotNode(m, filter: nodeFilter, projectResolver: projectResolver) else { continue }
            allProjects.insert(record.node.project)
            nodeBatch.append(record)
            if nodeBatch.count >= batchSize {
                let batch = nodeBatch
                nodeBatch = []
                pendingUpdate.withLock { $0.bulkNodeBatches.append(batch) }
            }
        }
        if !nodeBatch.isEmpty {
            let batch = nodeBatch
            pendingUpdate.withLock { $0.bulkNodeBatches.append(batch) }
        }

        // 3. Mark finalize — drain loop will recomputeDerivedData + wake sim
        pendingUpdate.withLock { $0.finalize = true }

        // 4. Cluster computation off main actor — push result into update buffer.
        // Serialized ACROSS galaxies: the per-project vector queries are the
        // most allocation-heavy phase of a load, and three galaxies running
        // them concurrently over multi-GB DBs is what pushed the SQLite page
        // cache to ~1GB and into transient OOM (crash 2026-08-05). Nodes and
        // edges above still load fully in parallel; only this tail is gated.
        let projects = allProjects
        let finalClusters = await ClusterPassGate.shared.run { [ref] in
            guard let lat = ref.resolve() else { return [[UUID]]() }
            var clusters: [[UUID]] = []
            for project in projects {
                guard !Task.isCancelled else { return [[UUID]]() }
                clusters.append(contentsOf: findMemoryClusters(
                    in: lat, project: project,
                    minClusterSize: 2, neighborLimit: 20).clusters)
            }
            return clusters
        }
        guard !Task.isCancelled else { return }
        pendingUpdate.withLock { $0.clusterGroups = finalClusters }
    }

    /// Scope the hydrated scalar cache to one row. This replaces one SQL read
    /// per property without retaining an all-model snapshot (and embeddings).
    nonisolated static func snapshotNode(
        _ memory: Memory,
        filter: (@Sendable (Memory) -> Bool)? = nil,
        projectResolver: (@Sendable (UUID?, String) -> String)? = nil
    ) -> (pk: Int64, node: NodeData)? {
        memory.withMaterializedReads {
            guard let gid = memory.globalId, let pk = memory.primaryKey else { return nil }
            if let filter, !filter(memory) { return nil }
            let project = projectResolver?(memory.authorUserId, memory.project) ?? memory.project
            let content = memory.content
            let topic = memory.topic
            return (pk, NodeData(
                id: gid, project: project, topic: topic,
                label: extractLabel(content: content, topic: topic), content: content,
                createdAt: memory.createdAt, lastAccessedAt: memory.lastAccessedAt,
                importance: memory.importance
            ))
        }
    }

    nonisolated static func snapshotEdge(_ edge: MemoryEdge) -> (pk: Int64, edge: EdgeData)? {
        edge.withMaterializedReads {
            guard let pk = edge.primaryKey, let gid = edge.globalId else { return nil }
            return (pk, EdgeData(id: gid, sourceId: edge.sourceGlobalId,
                                 targetId: edge.targetGlobalId, relation: edge.relation.rawValue))
        }
    }
    
    // MARK: insert node batch
    @MainActor func insertNodeBatch(_ batch: [NodeData], config: DrainConfig,
                                   deriveInitialData: Bool = false) {
        let store = renderStore
        let sim3D = simulation3D
        // An out-of-band insert during loading is not part of the snapshot's
        // append sequence. Reconcile normally at the end in that rare case.
        if !deriveInitialData { initialDerivedData?.isValid = false }
        let derived = deriveInitialData && initialDerivedData?.isValid == true ? initialDerivedData : nil

        for nd in batch {
            store.allNodes[nd.id] = nd
            derived?.projects.insert(nd.project)

            let visible = !config.hiddenProjects.contains(nd.project) &&
                (config.timeFilter == nil || nd.createdAt <= config.timeFilter!)
            guard visible, !store.visibleNodeIds.contains(nd.id) else { continue }

            store.nodes.append(nd)
            store.nodeById[nd.id] = nd
            store.visibleNodeIds.insert(nd.id)
            if let derived, nd.topic != "general", nd.topic != "episode" {
                let key = "\(nd.project)|\(nd.topic)"
                derived.topics[key, default: (topic: nd.topic, project: nd.project, ids: [])].ids.append(nd.id)
            }

            if config.is3D {
                sim3D?.addNode(nd.id, project: nd.project, topic: nd.topic, galaxyId: self.id)
            }

            // Wire edges where BOTH endpoints now exist
            for edge in store.edgesByNode[nd.id] ?? [] {
                let otherId = edge.sourceId == nd.id ? edge.targetId : edge.sourceId
                guard store.visibleNodeIds.contains(otherId) else { continue }
                // Non-self edges reach this branch once, when their second
                // endpoint is inserted. Self-edges appear twice in adjacency.
                // Counts intentionally include hidden relations, as the full
                // reconciliation does, while still excluding hidden endpoints.
                if let derived,
                   edge.sourceId != edge.targetId || derived.countedSelfEdges.insert(edge.id).inserted {
                    derived.relationCounts[edge.relation, default: 0] += 1
                }
                guard !config.hiddenRelations.contains(edge.relation) else { continue }
                if !store.filteredEdgeIds.contains(edge.id) {
                    store.filteredEdgeIds.insert(edge.id)
                    store.edges.append(edge)
                    if config.is3D {
                        sim3D?.addEdge(from: edge.sourceId, to: edge.targetId)
                    }
                }
            }

            // Hub detection
            if let edges = store.edgesByNode[nd.id] {
                for edge in edges where edge.relation == "part_of" && edge.targetId == nd.id {
                    store.hubs.insert(nd.id)
                    break
                }
            }

            // Assign color for previously unseen project
            if store.colorMap[nd.project] == nil {
                if nd.project == "global" {
                    store.colorMap["global"] = .gray
                } else {
                    let idx = store.colorMap.count - (store.colorMap["global"] != nil ? 1 : 0)
                    store.colorMap[nd.project] = GraphView.goldenAngleColor(at: idx)
                }
            }
        }
    }

    // MARK: - Render Update Drain

    /// Apply complete batches within a small frame budget. Each batch updates
    /// both the render store and simulation before yielding to the renderer.
    /// Live changes wait behind the initial snapshot, so a deletion cannot be
    /// undone by an older bulk row on a subsequent frame.
    @MainActor
    func drainPendingUpdate(config: DrainConfig, workBudget: TimeInterval = 0.002) {
        let deadline = CFAbsoluteTimeGetCurrent() + workBudget
        let store = renderStore
        if loadingUpdate == nil {
            let update = pendingUpdate.withLock { u -> RenderUpdate? in
                let hasBulk = !u.bulkNodeBatches.isEmpty || u.bulkEdges != nil
                guard !hasBulk || u.finalize else { return nil }
                guard !u.isEmpty else { return nil }
                let copy = u
                u = .init()
                return copy
            }
            guard let update else { return }
            if update.finalize {
                loadingUpdate = update
                loadingBatchIndex = 0
                initialDerivedData = InitialLoadDerivedData(store: store, config: config)
                if let bulk = update.bulkEdges {
                    store.allEdges = bulk.allEdges
                    store.edgePkToGlobalId = bulk.pkToGid
                    store.edgesByNode = bulk.byNode
                }
                // The real loader prepared these counts off-main. The fallback
                // supports synthetic producers without changing their contract.
                store.edgeCountByNode = update.bulkEdgeCounts ?? store.edgesByNode.mapValues(\.count)
            } else {
                applyIncrementalUpdate(update, config: config)
                if let clusters = update.clusterGroups { store.clusterGroups = clusters }
                return
            }
        }

        guard let update = loadingUpdate else { return }
        initialDerivedData?.validate(store: store, config: config)
        // The single-galaxy merge borrows the store's buffers. Release those
        // redundant references while mutating, or the first 50-row batch pays
        // for copying the entire accumulated graph and exhausts this budget.
        if let registry {
            registry.withReleasedSingleGalaxySnapshot(for: self) {
                drainInitialSnapshot(update, config: config, deadline: deadline)
            }
        } else {
            drainInitialSnapshot(update, config: config, deadline: deadline)
        }
    }

    @MainActor
    private func drainInitialSnapshot(_ update: RenderUpdate, config: DrainConfig, deadline: CFAbsoluteTime) {
        let store = renderStore
        var insertedBatch = false
        while loadingBatchIndex < update.bulkNodeBatches.count {
            let batch = update.bulkNodeBatches[loadingBatchIndex]
            var nodes: [NodeData] = []
            nodes.reserveCapacity(batch.count)
            for (pk, node) in batch {
                store.pkToGlobalId[pk] = node.id
                nodes.append(node)
            }
            insertNodeBatch(nodes, config: config, deriveInitialData: true)
            loadingBatchIndex += 1
            insertedBatch = true
            if CFAbsoluteTimeGetCurrent() >= deadline { break }
        }
        if insertedBatch { store.bumpTopology() }
        initialDerivedData?.expectedTopology = store.topologyVersion
        guard loadingBatchIndex == update.bulkNodeBatches.count else { return }

        // Incrementals captured with this finalized envelope must precede
        // aggregate publication, just like the original atomic drain. Inserts
        // remain deferred/coalesced; immediate edits/deletes invalidate the
        // bulk accumulator before final metadata and indexes are reconciled.
        applyIncrementalUpdate(update, config: config)
        initialDerivedData?.validate(store: store, config: config)

        // The ordinary initial path has already derived its metadata within
        // the bounded insertion slices. External filtering/topology edits
        // invalidate that accumulator and retain the full reconciliation path.
        if let derived = initialDerivedData, derived.isValid {
            ensureProjectColors(derived.projects)
            store.relationCounts = derived.relationCounts.sorted(by: { $0.key < $1.key })
            store.topicGroups = derived.topics.values.filter { $0.ids.count >= 2 }
                .map { TopicGroupInfo(topic: $0.topic, project: $0.project, ids: $0.ids) }
        } else {
            // A structural edit to a hidden row can temporarily add it to the
            // lookup without making it visible. Restore all derived indexes,
            // not just statistics, on this rare mixed-update fallback.
            recomputeDerivedData()
        }
        store.bumpTopology()
        if config.is3D { simulation3D?.wake() }
        isInitialLoad = false
        isLoaded = true
        loadingUpdate = nil
        loadingBatchIndex = 0
        initialDerivedData = nil
        if let clusters = update.clusterGroups { store.clusterGroups = clusters }
    }

    @MainActor
    private func applyIncrementalUpdate(_ update: RenderUpdate, config: DrainConfig) {
        let store = renderStore
        for (pk, node) in update.insertedNodes {
            handleNodeInsert(pk: pk, node: node, config: config)
        }
        for (pk, node) in update.updatedNodes {
            handleNodeUpdate(pk: pk, node: node, config: config)
        }
        handleNodeDeletes(Set(update.removedNodePks), config: config)
        for (pk, edge) in update.insertedEdges {
            store.edgePkToGlobalId[pk] = edge.id
            handleEdgeInsert(edge, config: config)
        }
        for edge in update.updatedEdges {
            handleEdgeUpdate(edge, config: config)
        }
        for gid in update.removedEdgeGids {
            handleEdgeDelete(gid)
        }
    }

    @MainActor
    func handleNodeInsert(pk: Int64, node: NodeData, config: DrainConfig) {
        let store = renderStore
        store.pendingNodeInserts.append((pk: pk, node: node))
        if store.pendingNodeFlush == nil {
            let capturedConfig = config
            store.pendingNodeFlush = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled else { store.pendingNodeFlush = nil; return }
                // A filter can change while the coalesced insert yields.
                flushPendingNodeInserts(config: registry?.currentDrainConfig ?? capturedConfig)
                store.pendingNodeFlush = nil
            }
        }
    }
    
    @MainActor func handleNodeUpdate(pk: Int64, node: NodeData, config: DrainConfig) {
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { ObserverAccumulator.shared.record("nodeUpdate", ms: (CFAbsoluteTimeGetCurrent() - t0) * 1000.0) }
        let store = renderStore
        let gid = node.id
        guard let old = store.allNodes[gid] else {
            // Unknown to this galaxy — either filtered at load or just now
            // entering the partition. A plain dict write here half-inserted
            // (allNodes/nodeById but never nodes[]/simulation); take the
            // real insert path instead.
            handleNodeInsert(pk: pk, node: node, config: config)
            return
        }

        // Notify mascot fleet of the update
        do {
            if old.project != node.project {
                // Project changed: farewell from old mascot, welcome from new
                mascotFleet?.onNodeUpdated(
                    nodeId: gid, project: old.project,
                    changes: NodeChangeInfo(importanceChanged: false, topicChanged: false, isAccessOnly: false)
                )
                mascotFleet?.onNodeUpdated(
                    nodeId: gid, project: node.project,
                    changes: NodeChangeInfo(importanceChanged: false, topicChanged: true, isAccessOnly: false)
                )
            } else {
                let changes = NodeChangeInfo(
                    importanceChanged: old.importance != node.importance,
                    topicChanged: old.topic != node.topic,
                    isAccessOnly: old.topic == node.topic &&
                                  old.importance == node.importance && old.label == node.label &&
                                  old.content == node.content
                )
                mascotFleet?.onNodeUpdated(nodeId: gid, project: node.project, changes: changes)
            }
        }
        if node.lastAccessedAt > old.lastAccessedAt {
            #if ENGRAM_INSTRUMENTATION
            let wasAlreadyGlowing = store.glowingNodes[gid] != nil
            #endif
            store.glowingNodes[gid] = Date()
            #if ENGRAM_INSTRUMENTATION
            if glowLogFile == nil {
                glowLogFile = fopen("/tmp/glow-log.csv", "w")
                if let f = glowLogFile {
                    fputs("timestamp,galaxy,node_label,old_accessed,new_accessed,delta_s,staleness_s,already_glowing,glow_count\n", f)
                }
            }
            if let f = glowLogFile {
                let now = Date()
                let delta = node.lastAccessedAt.timeIntervalSince(old.lastAccessedAt)
                let staleness = now.timeIntervalSince(node.lastAccessedAt)
                let alreadyGlowing = wasAlreadyGlowing
                let ts = String(format: "%.3f", now.timeIntervalSince1970)
                let line = "\(ts),\(id),\(node.label.prefix(30)),\(old.lastAccessedAt),\(node.lastAccessedAt),\(String(format: "%.1f", delta)),\(String(format: "%.1f", staleness)),\(alreadyGlowing),\(store.glowingNodes.count)\n"
                fputs(line, f)
                fflush(f)
            }
            #endif
        }
        let structuralChange = old.project != node.project ||
            old.topic != node.topic ||
            old.importance != node.importance ||
            old.label != node.label || old.content != node.content
        if !structuralChange {
            // Access-only change: update dicts (O(1)), skip O(n) array scan.
            // nodes[] array gets stale lastAccessedAt but that field doesn't affect
            // rendering — it's only used by activity log which reads from nodeById.
            store.allNodes[gid]?.lastAccessedAt = node.lastAccessedAt
            store.nodeById[gid]?.lastAccessedAt = node.lastAccessedAt
            return
        }
        store.allNodes[gid] = node
        store.nodeById[gid] = node
        if let idx = store.nodes.firstIndex(where: { $0.id == gid }) {
            store.nodes[idx] = node
        }
        if store.colorMap[node.project] == nil {
            store.colorMap[node.project] = node.project == "global" ? .gray :
                GraphView.goldenAngleColor(at: max(0, store.colorMap.count - 1))
        }
        store.bumpTopology()
    }
    
    @MainActor func handleNodeDelete(_ pk: Int64, config: DrainConfig) {
        handleNodeDeletes([pk], config: config)
    }

    @MainActor private func handleNodeDeletes(_ pks: Set<Int64>, config: DrainConfig) {
        guard !pks.isEmpty else { return }
        let soundEnabled = config.soundEnabled
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { ObserverAccumulator.shared.record("nodeDelete", ms: (CFAbsoluteTimeGetCurrent() - t0) * 1000.0) }
        let store = renderStore
        // A just-inserted row may still be waiting for its deferred flush and
        // therefore have no pkToGlobalId entry yet. Cancel it before lookup.
        store.pendingNodeInserts.removeAll { pks.contains($0.pk) }
        let gids = Set(pks.compactMap { store.pkToGlobalId[$0] })
        guard !gids.isEmpty else { return }

        // Notify mascot fleet before removing — capture position for absorb animation
        if let mascotFleet {
            let positions = simulation3D?.positions ?? [:]
            for gid in gids {
                if let nodeData = store.allNodes[gid] {
                    mascotFleet.onNodeDeleted(nodeId: gid, project: nodeData.project, lastPosition: positions[gid])
                }
            }
        }

        for pk in pks { store.pkToGlobalId.removeValue(forKey: pk) }
        for gid in gids {
            store.allNodes.removeValue(forKey: gid)
            store.glowingNodes.removeValue(forKey: gid)
            store.newNodeGlows.removeValue(forKey: gid)
            store.nodeById.removeValue(forKey: gid)
        }
        let removedEdgeIds = Set(store.edges.lazy.filter { gids.contains($0.sourceId) || gids.contains($0.targetId) }.map(\.id))
        store.filteredEdgeIds.subtract(removedEdgeIds)
        store.visibleNodeIds.subtract(gids)
        if config.is3D {
            if let registry { registry.reconcileSimulationOwnership(for: gids) }
            else { simulation3D?.removeNodes(gids) }
        }
        store.nodes.removeAll { gids.contains($0.id) }
        store.edges.removeAll { removedEdgeIds.contains($0.id) }
        store.hubs.subtract(gids)
        store.bumpTopology()
        if !isInitialLoad && soundEnabled {
            DispatchQueue.global(qos: .utility).async { GraphView.removeSound?.play() }
        }
        store.clusterGroups = store.clusterGroups.compactMap { cluster in
            let filtered = cluster.filter { !gids.contains($0) }
            return filtered.count >= 2 ? filtered : nil
        }
    }
    
    @MainActor
    func flushPendingNodeInserts(config: DrainConfig) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let store = renderStore
        var entries: [(pk: Int64, node: NodeData)] = []
        var indexByPK: [Int64: Int] = [:]
        // Updates may arrive while an insert is deferred. Keep the latest row
        // for each PK without changing the first insertion's stable order.
        for entry in store.pendingNodeInserts {
            if let index = indexByPK[entry.pk] { entries[index] = entry }
            else {
                indexByPK[entry.pk] = entries.count
                entries.append(entry)
            }
        }
        store.pendingNodeInserts.removeAll(keepingCapacity: true)
        guard !entries.isEmpty else { return }

        #if ENGRAM_INSTRUMENTATION
        let flushStart = CFAbsoluteTimeGetCurrent()
        #endif

        var addedVisibleNode = false

        for (pk, node) in entries {
            let gid = node.id
            store.pkToGlobalId[pk] = gid
            store.allNodes[gid] = node
            store.newNodeGlows[gid] = Date()
            // Even a hidden project's first row must expose a project entry
            // in the sidebar so it can subsequently be made visible.
            if store.colorMap[node.project] == nil {
                if node.project == "global" { store.colorMap[node.project] = .gray }
                else {
                    let idx = store.colorMap.count - (store.colorMap["global"] == nil ? 0 : 1)
                    store.colorMap[node.project] = GraphView.goldenAngleColor(at: idx)
                }
            }

            let visible = !config.hiddenProjects.contains(node.project) &&
                (config.timeFilter == nil || node.createdAt <= config.timeFilter!)
            guard visible && !store.visibleNodeIds.contains(gid) else { continue }

            store.nodes.append(node)
            store.nodeById[gid] = node
            store.visibleNodeIds.insert(gid)

            // Notify mascot fleet of new node (only after initial load)
            if !isInitialLoad {
                mascotFleet?.onNodeCreated(nodeId: gid, project: node.project)
            }

            if config.is3D {
                simulation3D?.addNode(gid, project: node.project, topic: node.topic, galaxyId: self.id)
            }

            let nodeIds = store.visibleNodeIds
            for edge in store.edgesByNode[gid] ?? [] {
                let otherId = edge.sourceId == gid ? edge.targetId : edge.sourceId
                guard nodeIds.contains(otherId),
                      !config.hiddenRelations.contains(edge.relation) else { continue }
                if config.is3D {
                    simulation3D?.addEdge(from: edge.sourceId, to: edge.targetId)
                }
                if !store.filteredEdgeIds.contains(edge.id) {
                    store.filteredEdgeIds.insert(edge.id)
                    store.edges.append(edge)
                }
                if edge.relation == "part_of" && edge.targetId == gid {
                    store.hubs.insert(gid)
                }
            }

            addedVisibleNode = true
        }

        // Hidden inserts still change allNodes, which backs panel totals and
        // per-project counts. Publish one revision without making them visible.
        store.bumpTopology()
        if addedVisibleNode {
            if !isInitialLoad && config.soundEnabled {
                DispatchQueue.global(qos: .utility).async { GraphView.addSound?.play() }
            }
        }

        #if ENGRAM_INSTRUMENTATION
        let flushMs = (CFAbsoluteTimeGetCurrent() - flushStart) * 1000.0
        if flushTimingFile == nil {
            flushTimingFile = fopen("/tmp/flush-timing.csv", "w")
            if let f = flushTimingFile {
                fputs("timestamp,galaxy,batch_size,flush_ms,edges_added,topology_bumped\n", f)
            }
        }
        if let f = flushTimingFile {
            let ts = String(format: "%.3f", CFAbsoluteTimeGetCurrent())
            let line = "\(ts),\(id),\(entries.count),\(String(format: "%.2f", flushMs)),\(store.edges.count),true\n"
            fputs(line, f)
            fflush(f)
        }
        #endif
    }
    
    
    @MainActor
    func handleEdgeInsert(_ data: EdgeData, config: DrainConfig) {
        let store = renderStore
        store.pendingEdgeInserts.append((pk: data.id, edge: data))
        if store.pendingEdgeFlush == nil {
            let capturedConfig = config
            store.pendingEdgeFlush = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled else { store.pendingEdgeFlush = nil; return }
                flushPendingEdgeInserts(config: registry?.currentDrainConfig ?? capturedConfig)
                store.pendingEdgeFlush = nil
            }
        }
    }

    @MainActor func handleEdgeUpdate(_ data: EdgeData, config: DrainConfig) {
        let store = renderStore
        // Updating an edge whose insert has not flushed supersedes that old row.
        store.pendingEdgeInserts.removeAll { $0.edge.id == data.id }
        let old = store.allEdges[data.id]
        store.allEdges[data.id] = data
        // Only scan the edges array when structural fields changed (relation, endpoints).
        // Edge updates that don't change routing (rare) skip the O(edges) linear scan.
        let structuralChange = old == nil ||
            old!.relation != data.relation ||
            old!.sourceId != data.sourceId ||
            old!.targetId != data.targetId
        if structuralChange {
            store.edges.removeAll { $0.id == data.id }
            store.filteredEdgeIds.remove(data.id)
            if let old {
                store.edgesByNode[old.sourceId]?.removeAll { $0.id == data.id }
                store.edgesByNode[old.targetId]?.removeAll { $0.id == data.id }
                store.edgeCountByNode[old.sourceId] = max(0, (store.edgeCountByNode[old.sourceId] ?? 0) - 1)
                store.edgeCountByNode[old.targetId] = max(0, (store.edgeCountByNode[old.targetId] ?? 0) - 1)
                removeUnownedSimulationEdge(from: old.sourceId, to: old.targetId)
            }
            store.edgesByNode[data.sourceId, default: []].append(data)
            store.edgesByNode[data.targetId, default: []].append(data)
            store.edgeCountByNode[data.sourceId, default: 0] += 1
            store.edgeCountByNode[data.targetId, default: 0] += 1
            if let old, old.relation == "part_of",
               !(store.edgesByNode[old.targetId] ?? []).contains(where: { $0.relation == "part_of" && $0.targetId == old.targetId }) {
                store.hubs.remove(old.targetId)
            }
            if data.relation == "part_of" { store.hubs.insert(data.targetId) }
            if store.visibleNodeIds.contains(data.sourceId), store.visibleNodeIds.contains(data.targetId),
               !config.hiddenRelations.contains(data.relation) {
                store.edges.append(data)
                store.filteredEdgeIds.insert(data.id)
                if config.is3D { simulation3D?.addEdge(from: data.sourceId, to: data.targetId) }
            }
            store.bumpTopology()
        }
    }

    @MainActor func handleEdgeDelete(_ gid: UUID) {
        let store = renderStore
        store.pendingEdgeInserts.removeAll { $0.edge.id == gid }
        if let old = store.allEdges.removeValue(forKey: gid) {
            store.filteredEdgeIds.remove(gid)
            store.edges.removeAll { $0.id == gid }
            store.edgesByNode[old.sourceId]?.removeAll { $0.id == gid }
            store.edgesByNode[old.targetId]?.removeAll { $0.id == gid }
            removeUnownedSimulationEdge(from: old.sourceId, to: old.targetId)
            store.edgeCountByNode[old.sourceId, default: 1] -= 1
            store.edgeCountByNode[old.targetId, default: 1] -= 1
            if old.relation == "part_of" {
                let stillHub = (store.edgesByNode[old.targetId] ?? []).contains { $0.relation == "part_of" && $0.targetId == old.targetId }
                if !stillHub { store.hubs.remove(old.targetId) }
            }
        }
        store.bumpTopology()
    }

    @MainActor private func removeUnownedSimulationEdge(from source: UUID, to target: UUID) {
        if let registry {
            registry.removeSimulationEdgeIfUnowned(from: source, to: target)
        } else if !renderStore.edges.contains(where: { $0.sourceId == source && $0.targetId == target }) {
            simulation3D?.removeEdge(from: source, to: target)
        }
    }
    
    @MainActor func flushPendingEdgeInserts(config: DrainConfig) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let store = renderStore
        let entries = store.pendingEdgeInserts
        store.pendingEdgeInserts.removeAll(keepingCapacity: true)
        guard !entries.isEmpty else { return }
        defer {
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            if ms > 5 { os_log(.fault, log: stallLog, "HOTPATH: flushEdgeInserts count=%d %.1fms", entries.count, ms) }
        }

        #if ENGRAM_INSTRUMENTATION
        let edgeFlushStart = CFAbsoluteTimeGetCurrent()
        #endif

        var addedVisibleEdge = false

        for (_, data) in entries {
            store.allEdges[data.id] = data
            store.edgesByNode[data.sourceId, default: []].append(data)
            store.edgesByNode[data.targetId, default: []].append(data)
            store.edgeCountByNode[data.sourceId, default: 0] += 1
            store.edgeCountByNode[data.targetId, default: 0] += 1
            let nodeIds = store.visibleNodeIds
            if nodeIds.contains(data.sourceId) && nodeIds.contains(data.targetId) &&
               !config.hiddenRelations.contains(data.relation) {
                store.filteredEdgeIds.insert(data.id)
                store.edges.append(data)
                if config.is3D {
                    simulation3D?.addEdge(from: data.sourceId, to: data.targetId)
                }
                addedVisibleEdge = true
            }
            if data.relation == "part_of" {
                store.hubs.insert(data.targetId)
            }
        }
        // Bump topology whenever visible edges were added — ensures mergeRenderData
        // picks up new edges (not just part_of hub changes).
        if addedVisibleEdge {
            store.bumpTopology()
        }

        #if ENGRAM_INSTRUMENTATION
        let edgeFlushMs = (CFAbsoluteTimeGetCurrent() - edgeFlushStart) * 1000.0
        if flushTimingFile == nil {
            flushTimingFile = fopen("/tmp/flush-timing.csv", "w")
            if let f = flushTimingFile {
                fputs("timestamp,galaxy,batch_size,flush_ms,edges_added,topology_bumped\n", f)
            }
        }
        if let f = flushTimingFile {
            let ts = String(format: "%.3f", CFAbsoluteTimeGetCurrent())
            let line = "\(ts),\(id),\(entries.count),\(String(format: "%.2f", edgeFlushMs)),\(store.edges.count),\(addedVisibleEdge)\n"
            fputs(line, f)
            fflush(f)
        }
        #endif
    }
    
    @MainActor func recomputeDerivedData(rebuildVisibleIndex: Bool = true) {
        let store = renderStore

        // Color map
        ensureProjectColors(Set(store.allNodes.values.map(\.project)))

        // Initial insertion maintains both indexes atomically with the sim.
        // Filtering/migration callers still request the full reconciliation.
        if rebuildVisibleIndex {
            store.visibleNodeIds = Set(store.nodes.map(\.id))
            store.nodeById = Dictionary(store.nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        }

        // Relation counts
        let nodeIds = store.visibleNodeIds
        var counts: [String: Int] = [:]
        for edge in store.allEdges.values {
            guard nodeIds.contains(edge.sourceId), nodeIds.contains(edge.targetId) else { continue }
            counts[edge.relation, default: 0] += 1
        }
        store.relationCounts = counts.sorted(by: { $0.key < $1.key })

        // Topic groups
        var groups: [String: (topic: String, project: String, ids: [UUID])] = [:]
        for node in store.nodes {
            guard node.topic != "general", node.topic != "episode" else { continue }
            let key = "\(node.project)|\(node.topic)"
            // Mutate through Dictionary's in-place accessor. Extracting a
            // local tuple copies its growing UUID array on every append.
            groups[key, default: (topic: node.topic, project: node.project, ids: [])].ids.append(node.id)
        }
        store.topicGroups = groups.values
            .filter { $0.ids.count >= 2 }
            .map { TopicGroupInfo(topic: $0.topic, project: $0.project, ids: $0.ids) }

        // Per-node edge counts
        if rebuildVisibleIndex {
            var edgeCounts: [UUID: Int] = [:]
            for edge in store.allEdges.values {
                edgeCounts[edge.sourceId, default: 0] += 1
                edgeCounts[edge.targetId, default: 0] += 1
            }
            store.edgeCountByNode = edgeCounts
        } else {
            // Initial adjacency contains every edge once per endpoint (twice
            // for a self-edge), exactly matching the full count semantics.
            store.edgeCountByNode = store.edgesByNode.mapValues(\.count)
        }
    }

    @MainActor private func ensureProjectColors(_ projects: Set<String>) {
        let store = renderStore
        if store.colorMap["global"] == nil {
            store.colorMap["global"] = .gray
        }
        for project in projects.sorted() {
            if project == "global" { continue }
            if store.colorMap[project] == nil {
                let idx = store.colorMap.count - 1
                store.colorMap[project] = GraphView.goldenAngleColor(at: idx)
            }
        }

    }
    
    @MainActor private func recomputeStatsOnly() {
        let store = renderStore
        let nodeIds = store.visibleNodeIds

        // Relation counts
        var counts: [String: Int] = [:]
        for edge in store.edges {
            counts[edge.relation, default: 0] += 1
        }
        store.relationCounts = counts.sorted(by: { $0.key < $1.key })

        // Topic groups
        var groups: [String: (topic: String, project: String, ids: [UUID])] = [:]
        for node in store.nodes {
            guard node.topic != "general", node.topic != "episode" else { continue }
            let key = "\(node.project)|\(node.topic)"
            groups[key, default: (topic: node.topic, project: node.project, ids: [])].ids.append(node.id)
        }
        store.topicGroups = groups.values
            .filter { $0.ids.count >= 2 }
            .map { TopicGroupInfo(topic: $0.topic, project: $0.project, ids: $0.ids) }

        // Per-node edge counts (only edges with both endpoints visible)
        var edgeCounts: [UUID: Int] = [:]
        for edge in store.allEdges.values {
            guard nodeIds.contains(edge.sourceId), nodeIds.contains(edge.targetId) else { continue }
            edgeCounts[edge.sourceId, default: 0] += 1
            edgeCounts[edge.targetId, default: 0] += 1
        }
        store.edgeCountByNode = edgeCounts
    }
    
    @MainActor func setIsInitialLoad(_ isInitialLoad: Bool) {
        self.isInitialLoad = isInitialLoad
    }
}
