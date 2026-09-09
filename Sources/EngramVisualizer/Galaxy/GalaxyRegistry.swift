import Combine
import EngramSceneKit
import EngramKit
import EngramSceneKit
import Lattice
import SwiftUI
import simd

/// Manages N galaxies and produces merged data for the single Metal renderer.
/// @Observable so SidebarView can react to topology changes. renderTick reads
/// outside SwiftUI observation tracking, so no spurious view updates.
/// Per-frame properties (positions) are @ObservationIgnored.
@MainActor
final class GalaxyRegistry {
    private(set) var galaxies: [String: Galaxy] = [:]  // id -> Galaxy

    /// Single unified simulation for all galaxies. Galaxy membership is metadata (galaxyGroup),
    /// not a physics boundary. This eliminates per-galaxy sim contention, O(n) position merges,
    /// and double force compute cost.
    let unifiedSimulation = ForceSimulation3D()

    // SyncConfig observation — drives node migration between personal ↔ synced galaxies
    @ObservationIgnored private var syncConfigObserver: AnyCancellable?
    @ObservationIgnored weak var syncManager: SyncManager?

    // Hierarchy spacing
    let levelSpacing: Float = 3000    // Y between hierarchy levels
    let siblingSpacing: Float = 4000  // X between same-level galaxies

    // Merged data for renderer (recomputed when any galaxy's topology changes).
    // @ObservationIgnored — these change on topology updates and are read by the
    // RealityKit scene via GalaxyRegistryAdapter, not SwiftUI views. Without this,
    // every topology change triggers GraphView.body re-evaluation (~400% CPU).
    @ObservationIgnored private(set) var mergedNodes: [NodeData] = []
    @ObservationIgnored private(set) var mergedEdges: [EdgeData] = []
    @ObservationIgnored private(set) var mergedHubs: Set<UUID> = []
    @ObservationIgnored private(set) var mergedColorMap: [String: Color] = [:]
    @ObservationIgnored private(set) var mergedNodeById: [UUID: NodeData] = [:]
    @ObservationIgnored let panelSnapshot = GalaxyPanelSnapshot()

    // Node -> galaxy routing (for selection, detail panel, search)
    @ObservationIgnored private(set) var nodeToGalaxy: [UUID: String] = [:]
    var focusedGalaxyId: String?

    // Render config (pushed from VisualizerConfig, used by drain + edge filtering)
    var hiddenProjects: Set<String> = []
    var hiddenRelations: Set<String> = []

    /// Snapshot pushed before loading and whenever a graph setting changes.
    /// The RealityKit drain and partition migrations consume this same config.
    var currentDrainConfig = DrainConfig(
        hiddenProjects: [], hiddenRelations: [], timeFilter: nil,
        is3D: true, soundEnabled: false, notificationsEnabled: false
    )

    func updateDrainConfig(from config: VisualizerConfig, timeFilter: Date?) {
        hiddenProjects = config.hiddenProjects
        hiddenRelations = config.hiddenRelations
        currentDrainConfig = DrainConfig(
            hiddenProjects: hiddenProjects, hiddenRelations: hiddenRelations,
            timeFilter: timeFilter, is3D: true,
            soundEnabled: config.soundEnabled, notificationsEnabled: config.notificationsEnabled
        )
    }

    // Per-galaxy revisions include metadata consumed by cached render aggregates.
    private struct RenderRevision: Equatable {
        let identity: ObjectIdentifier
        let topology: UInt64
        let colors: UInt64
        let worldCenter: SIMD3<Float>
    }
    @ObservationIgnored private var lastMergedRevisions: [String: RenderRevision] = [:]
    @ObservationIgnored private(set) var mergedTopologyVersion: UInt64 = 0
    @ObservationIgnored private var loadTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Galaxy Management

    func register(_ galaxy: Galaxy) {
        galaxies[galaxy.id] = galaxy
        galaxy.simulation3D = unifiedSimulation
        galaxy.registry = self
        computeWorldLayout()
        unifiedSimulation.setGalaxyCenter(galaxy.id, galaxy.worldCenter)
    }

    func remove(_ galaxyId: String) {
        guard let galaxy = galaxies.removeValue(forKey: galaxyId) else { return }
        loadTasks.removeValue(forKey: galaxyId)?.cancel()
        galaxy.renderStore.pendingNodeFlush?.cancel()
        galaxy.renderStore.pendingEdgeFlush?.cancel()
        // Detached observers/queued flushes must never mutate the shared sim.
        galaxy.simulation3D = nil
        galaxy.registry = nil
        galaxy.embeddingProjection.invalidate()
        reconcileSimulationOwnership(for: galaxy.renderStore.visibleNodeIds)
        Task { await galaxy.stopObservers() }
        computeWorldLayout()
    }

    /// Observer deletes can remove only one copy of a shared UUID. Preserve
    /// the unified slot while another displayed galaxy owns it, and move its
    /// galaxy metadata to the same precedence winner used by rendering.
    func reconcileSimulationOwnership(for nodeIDs: Set<UUID>) {
        guard !nodeIDs.isEmpty else { return }
        let owners = galaxiesInPrecedenceOrder()
        var unowned: Set<UUID> = []
        var retained: [String: Set<UUID>] = [:]
        for id in nodeIDs {
            if let owner = owners.first(where: { $0.renderStore.visibleNodeIds.contains(id) }) {
                retained[owner.id, default: []].insert(id)
            } else { unowned.insert(id) }
        }
        unifiedSimulation.removeNodes(unowned)
        for (galaxyID, ids) in retained { unifiedSimulation.changeGalaxyGroup(for: ids, to: galaxyID) }
    }

    /// A spring belongs to an endpoint pair, not an individual edge row. A
    /// replicated copy or different relation in another galaxy may retain it.
    func removeSimulationEdgeIfUnowned(from source: UUID, to target: UUID) {
        if galaxies.count == 1, let only = galaxies.values.first {
            if only.renderStore.edges.contains(where: { $0.sourceId == source && $0.targetId == target }) { return }
        } else {
            let ordered = galaxiesInPrecedenceOrder()
            let sourceVisible = ordered.contains { $0.renderStore.visibleNodeIds.contains(source) }
            let targetVisible = ordered.contains { $0.renderStore.visibleNodeIds.contains(target) }
            if sourceVisible && targetVisible {
                // Match mergeRenderData's first-wins global-ID precedence,
                // including edges whose endpoints now live in different galaxies.
                for galaxy in ordered {
                    for candidate in galaxy.renderStore.edgesByNode[source] ?? []
                    where candidate.sourceId == source && candidate.targetId == target {
                        guard let owner = ordered.first(where: { $0.renderStore.allEdges[candidate.id] != nil }),
                              let edge = owner.renderStore.allEdges[candidate.id] else { continue }
                        if edge.sourceId == source && edge.targetId == target
                            && !hiddenRelations.contains(edge.relation) { return }
                    }
                }
            }
        }
        unifiedSimulation.removeEdge(from: source, to: target)
    }

    /// The focused galaxy (for detail panel, search, etc.)
    var focusedGalaxy: Galaxy? {
        if let id = focusedGalaxyId { return galaxies[id] }
        return galaxies.values.first
    }

    /// Route a node ID to its owning galaxy.
    func galaxyForNode(_ nodeId: UUID) -> Galaxy? {
        if let galaxyId = nodeToGalaxy[nodeId] {
            return galaxies[galaxyId]
        }
        return nil
    }

    // MARK: - World Layout

    /// Assigns worldCenter to each galaxy based on hierarchy level.
    /// Level 0 galaxies spread on X axis at Y=0.
    /// Level 1 centered above their children at Y=levelSpacing.
    /// Level 2 at Y=2*levelSpacing.
    func computeWorldLayout() {
        // Group galaxies by hierarchy level
        var byLevel: [Int: [Galaxy]] = [:]
        for galaxy in galaxies.values {
            byLevel[galaxy.hierarchyLevel, default: []].append(galaxy)
        }

        // Layout each level
        for (level, levelGalaxies) in byLevel {
            let sorted = levelGalaxies.sorted(by: { $0.id < $1.id })
            let count = sorted.count
            let totalWidth = Float(count - 1) * siblingSpacing
            let startX = -totalWidth / 2.0

            for (i, galaxy) in sorted.enumerated() {
                let center = SIMD3<Float>(
                    startX + Float(i) * siblingSpacing,
                    Float(level) * levelSpacing,
                    0
                )
                #if ENGRAM_INSTRUMENTATION
                print("LAYOUT: galaxy=\(galaxy.id) center=\(center) galaxyCount=\(galaxies.count)")
                #endif
                galaxy.worldCenter = center
                unifiedSimulation.setGalaxyCenter(galaxy.id, center)
            }
        }
    }

    // MARK: - Reactive Galaxy Lifecycle

    /// Idempotent entry point for creating and loading a galaxy. Returns early if
    /// the galaxy already exists. `register()` runs synchronously on MainActor so
    /// `computeWorldLayout()` fires with the correct galaxy count before any data
    /// arrives. The actual data load + observer setup happens in a background Task.
    func onLatticeAvailable(id: String, displayName: String,
                            latticeRef: LatticeThreadSafeReference,
                            hierarchyLevel: Int = 0,
                            parentGalaxyId: String? = nil,
                            nodeFilter: (@Sendable (Memory) -> Bool)? = nil,
                            projectResolver: (@Sendable (UUID?, String) -> String)? = nil) {
        guard galaxies[id] == nil else { return }
        // parentGalaxyId must reach the Galaxy init — it is what
        // interGalaxyConnections draws hierarchy lines from; dropping it
        // here meant no parent→child line ever rendered.
        let galaxy = Galaxy(id: id, displayName: displayName,
                            lattice: latticeRef, hierarchyLevel: hierarchyLevel,
                            parentGalaxyId: parentGalaxyId)
        register(galaxy)

        loadTasks[id] = Task { [weak self] in
            defer {
                if self?.galaxies[id] === galaxy { self?.loadTasks[id] = nil }
            }
            if let filter = nodeFilter { galaxy.setNodeFilter(filter) }
            // Before loadData — the loader snapshots it per node.
            if let resolver = projectResolver { galaxy.setProjectResolver(resolver) }
            await galaxy.loadData()
            guard !Task.isCancelled else { return }
            await galaxy.startObservers()
        }
    }

    // MARK: - Merge

    #if ENGRAM_INSTRUMENTATION
    private var mergeTimingFile: UnsafeMutablePointer<FILE>? = nil
    private var migrationTimingFile: UnsafeMutablePointer<FILE>? = nil

    private func migrationLog(_ line: String) {
        if migrationTimingFile == nil {
            migrationTimingFile = fopen("/tmp/galaxy-migration.csv", "w")
            if let f = migrationTimingFile {
                fputs("timestamp,event,project,direction,from_galaxy,to_galaxy,node_count,edge_count,position_count,elapsed_ms\n", f)
            }
        }
        if let f = migrationTimingFile {
            fputs(line + "\n", f)
            fflush(f)
        }
    }
    #endif

    /// Rebuild merged data from all galaxies. Called each frame by renderTick.
    /// Only does real work when topology has changed.
    /// Galaxies in dedup-precedence order: group > synced > personal, with
    /// the most specific group first (leaf team before its org) and sorted id
    /// as the final tiebreak. Matches the node-filter precedence, so the
    /// merge backstop lands on the same galaxy the filters intended.
    func galaxiesInPrecedenceOrder() -> [Galaxy] {
        func rank(_ id: String) -> Int {
            if id.hasPrefix("group:") { return 0 }
            if id == "synced" { return 1 }
            return 2
        }
        return galaxies.values.sorted { lhs, rhs in
            let (lr, rr) = (rank(lhs.id), rank(rhs.id))
            if lr != rr { return lr < rr }
            if lr == 0, lhs.hierarchyLevel != rhs.hierarchyLevel {
                return lhs.hierarchyLevel < rhs.hierarchyLevel
            }
            return lhs.id < rhs.id
        }
    }

    func mergeRenderData() {
        // Contents, colors, instance identity, and layout all affect the merge.
        let revisions = galaxies.mapValues {
            // Immutable metadata belongs to this Galaxy instance, not just
            // its ID. A same-ID replacement can restart store revisions at
            // the same values while changing its display name or hierarchy.
            RenderRevision(identity: ObjectIdentifier($0),
                           topology: $0.renderStore.topologyVersion,
                           colors: $0.renderStore.colorMapVersion,
                           worldCenter: $0.worldCenter)
        }
        guard revisions != lastMergedRevisions else { return }
        let previousRevisions = lastMergedRevisions
        lastMergedRevisions = revisions
        mergedTopologyVersion &+= 1

        #if ENGRAM_INSTRUMENTATION
        let mergeStart = CFAbsoluteTimeGetCurrent()
        #endif

        let nodeCount: Int
        let edgeCount: Int

        if galaxies.count <= 1, let only = galaxies.values.first {
            // Single-galaxy fast path: CoW references, no allocation or iteration.
            // With 1 galaxy there are no cross-galaxy edges to discover.
            let store = only.renderStore
            mergedNodes = store.nodes
            mergedEdges = store.edges
            mergedHubs = store.hubs
            mergedColorMap = store.colorMap
            mergedNodeById = store.nodeById

            // Bulk drains only append and bump topology once per slice. Reuse
            // established routing until final reconciliation; unrelated edits
            // (including filtering or replacement) still force a full rebuild.
            let previous = previousRevisions[only.id]
            let canAppendRouting = only.isDrainingInitialSnapshot
                && lastSingleGalaxyId == only.id
                && previous?.identity == ObjectIdentifier(only)
                && previous.map { $0.topology &+ 1 == store.topologyVersion } == true
                && nodeToGalaxy.count <= store.nodes.count
            let start = canAppendRouting ? nodeToGalaxy.count : 0
            if !canAppendRouting { nodeToGalaxy.removeAll(keepingCapacity: true) }
            for node in store.nodes.dropFirst(start) { nodeToGalaxy[node.id] = only.id }
            lastSingleGalaxyId = only.id
            nodeCount = store.nodes.count
            edgeCount = store.edges.count
        } else {
            // Multi-galaxy: full rebuild
            var nodes: [NodeData] = []
            var hubs: Set<UUID> = []
            var colorMap: [String: Color] = [:]
            var nodeById: [UUID: NodeData] = [:]
            var newNodeToGalaxy: [UUID: String] = [:]

            // Precedence order, NOT dictionary order. Every merge below is
            // first-wins (`seenIds.insert`, `{ existing, _ in existing }`),
            // so iterating `galaxies.values` made the winner for a duplicated
            // node depend on hashing — the same memory would jump between
            // galaxies from one launch to the next. The node filters should
            // already prevent duplicates; this is the backstop, and a
            // backstop that picks arbitrarily is how the flicker survives.
            let ordered = galaxiesInPrecedenceOrder()

            var seenIds = Set<UUID>()
            for galaxy in ordered {
                let store = galaxy.renderStore
                for node in store.nodes {
                    if seenIds.insert(node.id).inserted {
                        nodes.append(node)
                        newNodeToGalaxy[node.id] = galaxy.id
                    }
                }
                hubs.formUnion(store.hubs)
                colorMap.merge(store.colorMap) { existing, _ in existing }
                nodeById.merge(store.nodeById) { existing, _ in existing }
            }

            // Cross-galaxy edge merge: iterate ALL galaxies' allEdges, dedup by globalId,
            // filter against merged visible node set + hiddenRelations.
            let mergedVisibleIds = Set(nodes.map(\.id))
            var seen = Set<UUID>()
            var crossEdges: [EdgeData] = []
            for galaxy in ordered {
                for (gid, edge) in galaxy.renderStore.allEdges {
                    guard seen.insert(gid).inserted else { continue }
                    guard mergedVisibleIds.contains(edge.sourceId),
                          mergedVisibleIds.contains(edge.targetId) else { continue }
                    guard !hiddenRelations.contains(edge.relation) else { continue }
                    crossEdges.append(edge)
                }
            }

            mergedNodes = nodes
            mergedEdges = crossEdges
            mergedHubs = hubs
            mergedColorMap = colorMap
            mergedNodeById = nodeById
            self.nodeToGalaxy = newNodeToGalaxy
            lastSingleGalaxyId = nil
            nodeCount = nodes.count
            edgeCount = crossEdges.count
        }

        #if ENGRAM_INSTRUMENTATION
        let mergeMs = (CFAbsoluteTimeGetCurrent() - mergeStart) * 1000.0
        if mergeMs > 0.5 {
            if mergeTimingFile == nil {
                mergeTimingFile = fopen("/tmp/merge-timing.csv", "w")
                if let f = mergeTimingFile {
                    fputs("timestamp,galaxy_count,node_count,edge_count,merge_ms\n", f)
                }
            }
            if let f = mergeTimingFile {
                let ts = String(format: "%.3f", CFAbsoluteTimeGetCurrent())
                let line = "\(ts),\(galaxies.count),\(nodeCount),\(edgeCount),\(String(format: "%.2f", mergeMs))\n"
                fputs(line, f)
                fflush(f)
            }
        }
        #endif
        // A background panel scan retains the mutable node buffers. Publishing
        // each partial snapshot would force another full CoW copy next frame.
        // The completed snapshot and every ordinary live update still refresh.
        if !galaxies.values.contains(where: { $0.isDrainingInitialSnapshot }) {
            panelSnapshot.refresh(from: self)
        }
    }

    /// A synchronous borrow around a bulk mutation. No suspension or external
    /// publication occurs while aliases are released; callers see restored,
    /// consistent store/simulation snapshots as soon as the drain returns.
    func withReleasedSingleGalaxySnapshot(for galaxy: Galaxy, _ mutation: () -> Void) {
        guard galaxies.count == 1, galaxies[galaxy.id] === galaxy,
              lastSingleGalaxyId == galaxy.id else {
            mutation()
            return
        }
        mergedNodes = []
        mergedEdges = []
        mergedNodeById = [:]
        mergedHubs = []
        mergedColorMap = [:]
        defer {
            let store = galaxy.renderStore
            mergedNodes = store.nodes
            mergedEdges = store.edges
            mergedNodeById = store.nodeById
            mergedHubs = store.hubs
            mergedColorMap = store.colorMap
        }
        mutation()
    }

    @ObservationIgnored private var lastSingleGalaxyId: String?

    // MARK: - Merged Accessors (convenience for renderer)

    /// Positions from the unified simulation — already in world space.
    var mergedPositions: [UUID: SIMD3<Float>] {
        unifiedSimulation.positions
    }

    /// Merged allEdges from all galaxies.
    var mergedAllEdges: [UUID: EdgeData] {
        var result: [UUID: EdgeData] = [:]
        for galaxy in galaxies.values {
            result.merge(galaxy.renderStore.allEdges) { _, new in new }
        }
        return result
    }

    /// Merged allNodes from all galaxies.
    var mergedAllNodes: [UUID: NodeData] {
        var result: [UUID: NodeData] = [:]
        for galaxy in galaxies.values {
            result.merge(galaxy.renderStore.allNodes) { _, new in new }
        }
        return result
    }

    /// Merged edgesByNode from all galaxies.
    var mergedEdgesByNode: [UUID: [EdgeData]] {
        var result: [UUID: [EdgeData]] = [:]
        for galaxy in galaxies.values {
            for (id, edges) in galaxy.renderStore.edgesByNode {
                result[id, default: []].append(contentsOf: edges)
            }
        }
        return result
    }

    /// Merged visual effects from all galaxies.
    /// Single-galaxy fast path avoids dictionary rebuilds (most common case).
    var mergedGlowingNodes: [UUID: Date] {
        if galaxies.count == 1, let only = galaxies.values.first {
            return only.renderStore.glowingNodes
        }
        var result: [UUID: Date] = [:]
        for galaxy in galaxies.values {
            result.merge(galaxy.renderStore.glowingNodes) { _, new in new }
        }
        return result
    }

    var mergedNewNodeGlows: [UUID: Date] {
        if galaxies.count == 1, let only = galaxies.values.first {
            return only.renderStore.newNodeGlows
        }
        var result: [UUID: Date] = [:]
        for galaxy in galaxies.values {
            result.merge(galaxy.renderStore.newNodeGlows) { _, new in new }
        }
        return result
    }

    var mergedDyingNodes: [UUID: DyingNode] {
        if galaxies.count == 1, let only = galaxies.values.first {
            return only.renderStore.dyingNodes
        }
        var result: [UUID: DyingNode] = [:]
        for galaxy in galaxies.values {
            result.merge(galaxy.renderStore.dyingNodes) { _, new in new }
        }
        return result
    }

    var mergedTopicGroups: [TopicGroupInfo] {
        if galaxies.count == 1, let only = galaxies.values.first {
            return only.renderStore.topicGroups
        }
        var result: [TopicGroupInfo] = []
        for galaxy in galaxies.values {
            result.append(contentsOf: galaxy.renderStore.topicGroups)
        }
        return result
    }

    var mergedClusterGroups: [[UUID]] {
        if galaxies.count == 1, let only = galaxies.values.first {
            return only.renderStore.clusterGroups
        }
        var result: [[UUID]] = []
        for galaxy in galaxies.values {
            result.append(contentsOf: galaxy.renderStore.clusterGroups)
        }
        return result
    }

    var mergedSearchMatchIds: Set<UUID> {
        if galaxies.count == 1, let only = galaxies.values.first {
            return only.renderStore.searchMatchIds
        }
        var result: Set<UUID> = []
        for galaxy in galaxies.values {
            result.formUnion(galaxy.renderStore.searchMatchIds)
        }
        return result
    }

    var mergedIsSearchActive: Bool {
        galaxies.values.contains { $0.renderStore.isSearchActive }
    }

    var mergedVisibleNodeIds: Set<UUID> {
        var result: Set<UUID> = []
        for galaxy in galaxies.values {
            result.formUnion(galaxy.renderStore.visibleNodeIds)
        }
        return result
    }

    var mergedRelationCounts: [(key: String, value: Int)] {
        var counts: [String: Int] = [:]
        for galaxy in galaxies.values {
            for (key, value) in galaxy.renderStore.relationCounts {
                counts[key, default: 0] += value
            }
        }
        return counts.sorted(by: { $0.key < $1.key })
    }

    /// Merged colorMapVersion — sum of all galaxy versions.
    var mergedColorMapVersion: UInt64 {
        mergedTopologyVersion
    }

    /// Merged edgeCountByNode.
    var mergedEdgeCountByNode: [UUID: Int] {
        var result: [UUID: Int] = [:]
        for galaxy in galaxies.values {
            result.merge(galaxy.renderStore.edgeCountByNode) { a, b in a + b }
        }
        return result
    }

    /// Merged recentNodes (top 50 across all galaxies, deduplicated by UUID).
    var mergedRecentNodes: [NodeData] {
        var seen: Set<UUID> = []
        var all: [NodeData] = []
        for galaxy in galaxies.values {
            for node in galaxy.renderStore.recentNodes {
                if seen.insert(node.id).inserted {
                    all.append(node)
                }
            }
        }
        return Array(all.sorted(by: { $0.createdAt > $1.createdAt }).prefix(50))
    }

    /// Merged filteredEdgeIds.
    var mergedFilteredEdgeIds: Set<UUID> {
        var result: Set<UUID> = []
        for galaxy in galaxies.values {
            result.formUnion(galaxy.renderStore.filteredEdgeIds)
        }
        return result
    }

    /// Merged pkToGlobalId.
    var mergedPkToGlobalId: [Int64: UUID] {
        var result: [Int64: UUID] = [:]
        for galaxy in galaxies.values {
            result.merge(galaxy.renderStore.pkToGlobalId) { _, new in new }
        }
        return result
    }

    // MARK: - Inter-Galaxy Connections

    /// Returns pairs of world-space centers for galaxies connected by parent→child hierarchy.
    var interGalaxyConnections: [(from: SIMD3<Float>, to: SIMD3<Float>, label: String)] {
        var result: [(from: SIMD3<Float>, to: SIMD3<Float>, label: String)] = []
        for galaxy in galaxies.values {
            guard let parentId = galaxy.parentGalaxyId,
                  let parent = galaxies[parentId] else { continue }
            result.append((from: parent.worldCenter, to: galaxy.worldCenter, label: galaxy.displayName))
        }
        return result
    }

    // MARK: - SyncConfig Observation & Node Migration

    /// Observe SyncConfig changes on the personal galaxy's Lattice.
    /// When a project's policy flips, migrate nodes between personal ↔ synced galaxies
    /// and rebuild the personal galaxy's nodeFilter. Uses `currentDrainConfig` for
    /// filter params — no captured config needed.
    func setupSyncConfigObserver() {
        guard let personal = galaxies["personal"] else { return }
        let latticeRef = personal.latticeRef

        Task.detached {
            guard let lattice = latticeRef.resolve() else { preconditionFailure() }
            let syncConfigObserver = lattice.objects(SyncConfig.self).observe { [weak self] change in
                switch change {
                case .insert(let pk), .update(let pk):
                    let capturedPk = pk
                    Task { @MainActor [weak self] in
                        guard let self,
                              let personal = self.galaxies["personal"],
                              let syncConfig = personal.latticeRef.resolve()?.object(SyncConfig.self, primaryKey: capturedPk) else { return }
                        // One row carries BOTH the personal policy and the
                        // group exposure set, so this fires for either edit —
                        // resolve where the project belongs now and move it
                        // there, rather than branching on a personal↔synced
                        // binary that a group destination doesn't fit.
                        self.migrateProject(syncConfig.project,
                                            to: self.destinationGalaxyId(for: syncConfig))
                        self.rebuildNodeFilters()
                    }
                case .delete:
                    Task { @MainActor [weak self] in
                        self?.reconcileSyncState()
                        self?.rebuildNodeFilters()
                    }
                }
            }
            Task { @MainActor in
                self.syncConfigObserver = syncConfigObserver
            }
        }
    }

    /// Which galaxy owns a project's nodes, by precedence group > synced >
    /// personal (a group-shared project renders with its group).
    ///
    /// Ties are broken DETERMINISTICALLY: among attached groups the project
    /// is exposed to, the most specific one wins (lowest hierarchy level —
    /// the leaf team rather than its org), then sorted galaxy id. "Whichever
    /// we happened to see first" would move nodes between galaxies on every
    /// relaunch.
    func destinationGalaxyId(for config: SyncConfig) -> String {
        if let owner = GroupHierarchy.owningGroup(
            exposedGroupIds: config.exposedGroups,
            attachedLevels: attachedGroupLevels()) {
            return "group:\(owner.uuidString)"
        }
        return config.policy == .sync ? "synced" : "personal"
    }

    /// Attached group galaxies as (groupId → hierarchy level), the input the
    /// placement rules take.
    private func attachedGroupLevels() -> [UUID: Int] {
        var levels: [UUID: Int] = [:]
        for (id, galaxy) in galaxies where id.hasPrefix("group:") {
            guard let uuid = UUID(uuidString: String(id.dropFirst("group:".count))) else { continue }
            levels[uuid] = galaxy.hierarchyLevel
        }
        return levels
    }

    /// Move a project's rendered nodes into `destination`, wherever they are
    /// now. Replaces the old personal→synced / synced→personal pair: with
    /// group galaxies the source can be any galaxy, and a project can move
    /// group→group when exposure changes.
    func migrateProject(_ project: String, to destination: String) {
        if destination == "synced" { ensureSyncedGalaxyExists() }
        guard galaxies[destination] != nil else { return }

        let sources = galaxies.keys.filter { id in
            id != destination
                && galaxies[id]?.renderStore.allNodes.values
                    .contains(where: { $0.project == project }) == true
        }.sorted()
        guard !sources.isEmpty else { return }   // idempotent: already there

        for source in sources {
#if ENGRAM_INSTRUMENTATION
            let migStart = CFAbsoluteTimeGetCurrent()
#endif
            let extracted = migrateProjectOut(project, from: source)
            guard !extracted.nodes.isEmpty else { continue }
            migrateRenderStoreIn(destination, nodes: extracted.nodes,
                                 intraProjectEdges: extracted.intraEdges)
            // Reassign galaxy group in unified sim (no remove+re-add)
            let nodeIds = Set(extracted.nodes.map(\.id))
            unifiedSimulation.changeGalaxyGroup(for: nodeIds, to: destination)
            unifiedSimulation.wake()
#if ENGRAM_INSTRUMENTATION
            let migMs = (CFAbsoluteTimeGetCurrent() - migStart) * 1000.0
            let ts = String(format: "%.3f", CFAbsoluteTimeGetCurrent())
            migrationLog("\(ts),migrate,\(project),\(source)→\(destination),\(source),\(destination),\(extracted.nodes.count),\(extracted.intraEdges.count),0,\(String(format: "%.2f", migMs))")
#endif
        }
    }

    /// Create + load the synced galaxy if it doesn't already exist.
    /// Uses `onLatticeAvailable` for idempotent creation.
    private func ensureSyncedGalaxyExists() {
        guard let syncedLattice = syncManager?.actor.syncedLatticeRef else { return }
        onLatticeAvailable(id: "synced", displayName: "Synced", latticeRef: syncedLattice)
    }

    /// Extract a project's nodes from a galaxy's render store. Edges STAY in the
    /// source galaxy's `allEdges`/`edgesByNode` — they're resolved at merge time by
    /// `mergeRenderData()` which filters all galaxies' `allEdges` against the merged
    /// visible node set. This avoids expensive edge removal/insertion during migration.
    ///
    /// Returns extracted nodes + intra-project edges (both endpoints migrating) so the
    /// destination galaxy can wire them into its force simulation via `edgesByNode`.
    @discardableResult
    private func migrateProjectOut(_ project: String, from galaxyId: String) -> (nodes: [NodeData], intraEdges: [EdgeData]) {
        guard let galaxy = galaxies[galaxyId] else { return ([], []) }
        let store = galaxy.renderStore

        #if ENGRAM_INSTRUMENTATION
        let outStart = CFAbsoluteTimeGetCurrent()
        let preNodeCount = store.allNodes.count
        let preSimCount = unifiedSimulation.positions.count
        #endif

        // Collect nodes BEFORE removing
        let removedNodes = store.allNodes.values.filter { $0.project == project }
        let removedIds = Set(removedNodes.map(\.id))
        guard !removedIds.isEmpty else { return ([], []) }

        // Collect intra-project edges from store.edgesByNode (O(removed·degree))
        // instead of scanning allEdges (O(allEdges))
        var intraEdges: [EdgeData] = []
        var intraEdgeIds = Set<UUID>()
        for id in removedIds {
            for edge in store.edgesByNode[id] ?? [] {
                guard removedIds.contains(edge.sourceId) && removedIds.contains(edge.targetId) else { continue }
                if intraEdgeIds.insert(edge.id).inserted {
                    intraEdges.append(edge)
                }
            }
        }

        // Remove NODES from all node data structures
        for id in removedIds {
            store.allNodes.removeValue(forKey: id)
            store.nodeById.removeValue(forKey: id)
            store.visibleNodeIds.remove(id)
        }
        store.nodes.removeAll { $0.project == project }
        store.pkToGlobalId = store.pkToGlobalId.filter { !removedIds.contains($0.value) }

        // Edges STAY in allEdges/edgesByNode for cross-galaxy rendering.
        // Filter existing store.edges (O(store.edges)) — NOT allEdges (O(allEdges)).
        store.edges.removeAll { removedIds.contains($0.sourceId) || removedIds.contains($0.targetId) }
        store.filteredEdgeIds = Set(store.edges.map(\.id))

        store.clusterGroups = store.clusterGroups.compactMap { cluster in
            let filtered = cluster.filter { !removedIds.contains($0) }
            return filtered.count >= 2 ? filtered : nil
        }

        // Don't remove from unified sim — changeGalaxyGroup will reassign them
        // after migrateRenderStoreIn moves the render store data.

        // Lightweight derived data rebuild — skip full recomputeDerivedData.
        // visibleNodeIds and nodeById are already maintained inline above.
        // Only rebuild relation counts, topic groups, and edge counts.
        recomputeStatsOnly(for: galaxy)
        store.bumpTopology()

        #if ENGRAM_INSTRUMENTATION
        let outMs = (CFAbsoluteTimeGetCurrent() - outStart) * 1000.0
        let ts = String(format: "%.3f", CFAbsoluteTimeGetCurrent())
        migrationLog("\(ts),migrate_out,\(project),from_\(galaxyId),\(galaxyId),,\(removedIds.count),\(intraEdges.count),0,\(String(format: "%.2f", outMs))")
        migrationLog("\(ts),migrate_out_counts,\(project),from_\(galaxyId),pre_nodes=\(preNodeCount) post_nodes=\(store.allNodes.count) pre_sim=\(preSimCount) post_sim=\(unifiedSimulation.positions.count),,,,")
        #endif

        return (Array(removedNodes), Array(intraEdges))
    }

    /// Capture world-space positions for all nodes of a project in a given galaxy.
    /// Must be called BEFORE migrateProjectOut removes them.

    /// Move render store data into destination galaxy without touching the unified sim.
    /// Used during migration where `changeGalaxyGroup` handles the sim side.
    private func migrateRenderStoreIn(_ galaxyId: String, nodes: [NodeData], intraProjectEdges: [EdgeData]) {
        guard let galaxy = galaxies[galaxyId] else { return }
        let store = galaxy.renderStore
        let config = currentDrainConfig

        // Copy intra-project edges
        for edge in intraProjectEdges {
            guard store.allEdges[edge.id] == nil else { continue }
            store.allEdges[edge.id] = edge
            store.edgesByNode[edge.sourceId, default: []].append(edge)
            store.edgesByNode[edge.targetId, default: []].append(edge)
        }

        // Add nodes to render store
        for nd in nodes {
            // The destination may already hold the same replicated UUID while
            // its source observer catches up with a partition policy change.
            guard !store.visibleNodeIds.contains(nd.id) else { continue }
            store.allNodes[nd.id] = nd
            let visible = !config.hiddenProjects.contains(nd.project) &&
                (config.timeFilter == nil || nd.createdAt <= config.timeFilter!)
            guard visible else { continue }
            store.nodes.append(nd)
            store.nodeById[nd.id] = nd
            store.visibleNodeIds.insert(nd.id)

            // Wire visible edges
            for edge in store.edgesByNode[nd.id] ?? [] {
                let otherId = edge.sourceId == nd.id ? edge.targetId : edge.sourceId
                guard store.visibleNodeIds.contains(otherId),
                      !config.hiddenRelations.contains(edge.relation) else { continue }
                if !store.filteredEdgeIds.contains(edge.id) {
                    store.filteredEdgeIds.insert(edge.id)
                    store.edges.append(edge)
                }
            }

            // Hub detection
            if let edges = store.edgesByNode[nd.id] {
                for edge in edges where edge.relation == "part_of" && edge.targetId == nd.id {
                    store.hubs.insert(nd.id)
                    break
                }
            }

            // Assign color
            if store.colorMap[nd.project] == nil {
                if nd.project == "global" {
                    store.colorMap["global"] = .gray
                } else {
                    let idx = store.colorMap.count - (store.colorMap["global"] != nil ? 1 : 0)
                    store.colorMap[nd.project] = GraphView.goldenAngleColor(at: idx)
                }
            }
        }

        galaxy.isInitialLoad = false
        recomputeStatsOnly(for: galaxy)
        store.bumpTopology()
    }

    /// Full reconciliation — query Lattice for current synced projects, diff against
    /// what's actually in the personal galaxy's visible set, and fix discrepancies.
    /// Single pass over nodes/edges, single topology bump.
    private func reconcileSyncState() {
        guard let personal = galaxies["personal"] else { return }
        guard let lattice = personal.latticeRef.resolve() else { preconditionFailure() }

        var syncedProjects = Set<String>()
        for config in lattice.objects(SyncConfig.self).where({ $0.policy == .sync }) {
            syncedProjects.insert(config.project)
        }

        let store = personal.renderStore

        // Collect unique projects that need to move out
        let projectsToRemove = Set(store.nodes.filter { syncedProjects.contains($0.project) }.map(\.project))

        // Collect projects that should be local but aren't visible
        let visibleProjects = Set(store.nodes.map(\.project))
        let allProjects = Set(store.allNodes.values.map(\.project))
        let projectsToAdd = allProjects.subtracting(syncedProjects).subtracting(visibleProjects)

        guard !projectsToRemove.isEmpty || !projectsToAdd.isEmpty else { return }

        // Batch remove — single pass (nodes only; edges stay in allEdges for cross-galaxy rendering)
        if !projectsToRemove.isEmpty {
            let removedIds = Set(store.nodes.filter { projectsToRemove.contains($0.project) }.map(\.id))
            store.nodes.removeAll { projectsToRemove.contains($0.project) }
            for id in removedIds {
                store.nodeById.removeValue(forKey: id)
                store.allNodes.removeValue(forKey: id)
                store.visibleNodeIds.remove(id)
            }
            // Rebuild per-galaxy edges from allEdges against remaining visible nodes
            let remainingVisible = store.visibleNodeIds
            store.edges = store.allEdges.values.filter {
                remainingVisible.contains($0.sourceId) && remainingVisible.contains($0.targetId)
            }
            store.filteredEdgeIds = Set(store.edges.map(\.id))
            store.clusterGroups = store.clusterGroups.compactMap { cluster in
                let filtered = cluster.filter { !removedIds.contains($0) }
                return filtered.count >= 2 ? filtered : nil
            }
        }

        // Batch add — single pass
        for project in projectsToAdd {
            let addedNodes = store.allNodes.values.filter {
                $0.project == project && !store.visibleNodeIds.contains($0.id)
            }
            for node in addedNodes {
                store.nodes.append(node)
                store.nodeById[node.id] = node
                store.visibleNodeIds.insert(node.id)
                unifiedSimulation.addNode(node.id, project: node.project, topic: node.topic, galaxyId: personal.id)
            }
        }

        if !projectsToAdd.isEmpty {
            // Wire edges for all newly visible nodes in one pass
            let allVisibleIds = store.visibleNodeIds
            let newEdges = store.allEdges.values.filter { edge in
                allVisibleIds.contains(edge.sourceId) && allVisibleIds.contains(edge.targetId) &&
                !store.filteredEdgeIds.contains(edge.id)
            }
            store.edges.append(contentsOf: newEdges)
            store.filteredEdgeIds.formUnion(newEdges.map(\.id))
            for edge in newEdges {
                unifiedSimulation.addEdge(from: edge.sourceId, to: edge.targetId)
            }

            var hubs = Set<UUID>()
            for edge in store.allEdges.values where edge.relation == "part_of" {
                hubs.insert(edge.targetId)
            }
            store.hubs = hubs
        }

        // Single recompute + topology bump
        personal.recomputeDerivedData()
        store.bumpTopology()
    }

    /// Lightweight stats-only rebuild — used during migration where visibleNodeIds and
    /// nodeById are already maintained inline. Skips the O(nodes) set/dict rebuilds that
    /// `recomputeDerivedData` does, only rebuilding relation counts, topic groups, and
    /// edge counts from the current visible state.
    private func recomputeStatsOnly(for galaxy: Galaxy) {
        let store = galaxy.renderStore
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
            var entry = groups[key] ?? (topic: node.topic, project: node.project, ids: [])
            entry.ids.append(node.id)
            groups[key] = entry
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

    /// Rebuild every galaxy's nodeFilter from current SyncConfig state.
    ///
    /// Node-dedup precedence is group > synced > personal: a project claimed
    /// by an ATTACHED group galaxy (id "group:<uuid>") renders there — the
    /// group galaxy owns its spoke's copies — so personal AND synced exclude
    /// it. Private rows always stay personal (they never relay anywhere).
    /// Dormant until group galaxies register; personal↔synced behavior is
    /// unchanged until then. The SyncConfig observer fires on any row write
    /// — policy flips AND exposedGroups edits — and lands here.
    func rebuildNodeFilters() {
        guard let personal = galaxies["personal"] else { return }
        guard let lattice = personal.latticeRef.resolve() else { preconditionFailure() }

        let attachedGroupIds = Set(galaxies.keys.compactMap {
            $0.hasPrefix("group:") ? String($0.dropFirst("group:".count)) : nil
        })
        var syncedProjects = Set<String>()
        var groupClaimedProjects = Set<String>()
        // project → the ONE group galaxy that renders it, so a project
        // exposed to two groups doesn't draw twice (mergeRenderData's seenIds
        // would pick an arbitrary winner, which flips between launches).
        var groupOwner: [String: String] = [:]
        for config in lattice.objects(SyncConfig.self) {
            if config.policy == .sync { syncedProjects.insert(config.project) }
            guard !attachedGroupIds.isEmpty,
                  !config.exposedGroups.isDisjoint(with: attachedGroupIds) else { continue }
            groupClaimedProjects.insert(config.project)
            groupOwner[config.project] = destinationGalaxyId(for: config)
        }

        let personalExcluded = syncedProjects.union(groupClaimedProjects)
        if personalExcluded.isEmpty {
            personal.setNodeFilter(nil)
        } else {
            let captured = personalExcluded
            personal.setNodeFilter { @Sendable memory in
                !captured.contains(memory.project) || memory.isPrivate
            }
        }

        if let synced = galaxies["synced"] {
            if groupClaimedProjects.isEmpty {
                synced.setNodeFilter(nil)
            } else {
                // Private rows never reach the synced DB, so a pure project
                // check suffices (group > synced precedence).
                let captured = groupClaimedProjects
                synced.setNodeFilter { @Sendable memory in
                    !captured.contains(memory.project)
                }
            }
        }

        // Each group galaxy drops rows for a project another group galaxy
        // owns. A project this user never exposed (a teammate's, present only
        // in that spoke) has no owner entry and stays visible — otherwise
        // joining a team would show an empty galaxy.
        for (galaxyId, galaxy) in galaxies where galaxyId.hasPrefix("group:") {
            let owned = groupOwner
            let me = galaxyId
            galaxy.setNodeFilter { @Sendable memory in
                guard memory.deletedAt == nil else { return false }
                guard let owner = owned[memory.project] else { return true }
                return owner == me
            }
        }
    }
}
