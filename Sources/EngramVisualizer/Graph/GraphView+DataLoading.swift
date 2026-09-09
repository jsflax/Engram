import SwiftUI
import EngramSceneKit
import Lattice
import EngramSceneKit
import Combine
import EngramKit
import UserNotifications
import os

private let flushLog = Logger(subsystem: "io.engram.app", category: "FlushInsert")

// MARK: - Data Loading, Observation & Batched Flush

extension GraphView {

    // MARK: - Derived Data (cached, recomputed on structural changes)

    /// Recompute all derived data for all galaxies.
    func recomputeDerivedData() {
        for galaxy in galaxyRegistry.galaxies.values {
            galaxy.recomputeDerivedData()
        }
    }

//    func recomputeClusters() {
//        for galaxy in galaxyRegistry.galaxies.values {
//            let store = galaxy.renderStore
//            let visibleProjects = Set(store.nodes.map(\.project))
//            var all: [[UUID]] = []
//            for project in visibleProjects {
//                let projectClusters = findMemoryClusters(in: galaxy.lattice, project: project, minClusterSize: 2, neighborLimit: 20).clusters
//                all.append(contentsOf: projectClusters)
//            }
//            store.clusterGroups = all
//        }
//    }

    // MARK: - Data Loading & Observation

    /// Set up galaxies reactively — no async, no temporal dependencies.
    /// `onLatticeAvailable` is idempotent so this is safe to call from both
    /// `onAppear` and `onReceive(syncManager.didConnect)`.
    func loadData() {
        // Propagate initial filter config to registry (onChange only fires on subsequent changes)
        syncDrainConfig()

        // Personal galaxy filter
        var personalFilter: (@Sendable (Memory) -> Bool)?
        if syncManager.isSyncing {
            let syncedProjects = syncManager.syncedProjectNames
            if !syncedProjects.isEmpty {
                personalFilter = { !syncedProjects.contains($0.project) || $0.isPrivate }
            }
        }

        // Register ALL galaxies synchronously FIRST — computeWorldLayout runs with
        // the correct galaxy count, so worldCenter is final before any data arrives.
        let personalRef = lattice.sendableReference
        if galaxyRegistry.galaxies["personal"] == nil {
            let personal = Galaxy(id: "personal", displayName: "Personal",
                                  lattice: personalRef, hierarchyLevel: 0)
            galaxyRegistry.register(personal)
        }

        var syncedRef: LatticeThreadSafeReference?
        if syncManager.isSyncing, let ref = syncManager.actor.syncedLatticeRef {
            syncedRef = ref
            if galaxyRegistry.galaxies["synced"] == nil {
                let synced = Galaxy(id: "synced", displayName: "Synced",
                                    lattice: ref, hierarchyLevel: 0)
                galaxyRegistry.register(synced)
            }
        }

        // Group galaxies register in the SAME synchronous block, before any
        // load starts: computeWorldLayout runs on register(), and if a group
        // arrived later every galaxy's worldCenter would have been computed
        // for the wrong count and the nodes would pile up at the origin.
        // A group galaxy shows ONLY live rows — a tombstone is hidden for
        // every member, including the person who wrote it.
        let groupSpokes = syncManager.discoverGroupGalaxies()
        let attachedGroupIds = Set(groupSpokes.map(\.groupId))
        for spoke in groupSpokes where galaxyRegistry.galaxies[spoke.galaxyId] == nil {
            // Only draw a hierarchy line to a parent that is itself attached;
            // otherwise the line would point at a galaxy that isn't there.
            let parentGalaxyId = spoke.parentId.flatMap {
                attachedGroupIds.contains($0) ? "group:\($0.uuidString)" : nil
            }
            let galaxy = Galaxy(id: spoke.galaxyId, displayName: spoke.name,
                                lattice: spoke.ref,
                                hierarchyLevel: spoke.hierarchyLevel,
                                parentGalaxyId: parentGalaxyId)
            galaxyRegistry.register(galaxy)
        }

        // NOW start loading — worldCenter is already correct for all galaxies.
        if let personal = galaxyRegistry.galaxies["personal"] {
            Task {
                if let filter = personalFilter { personal.setNodeFilter(filter) }
                await personal.loadData()
                await personal.startObservers()
            }
        }
        if let synced = galaxyRegistry.galaxies["synced"], syncedRef != nil {
            Task {
                await synced.loadData()
                await synced.startObservers()
            }
        }
        for spoke in groupSpokes {
            guard let galaxy = galaxyRegistry.galaxies[spoke.galaxyId] else { continue }
            Task {
                galaxy.setNodeFilter(Self.groupGalaxyFilter)
                // effectiveProject (decision 13): resolve each author's
                // local folder name to the group's canonical project, so
                // one shared project clusters/labels as ONE project instead
                // of one per member. Built from the spoke's own map table —
                // rows sync live from other members.
                galaxy.setProjectResolver(Self.groupProjectResolver(for: spoke.ref))
                await galaxy.loadData()
                // Live animation comes free: the spoke is daemon-written, and
                // startObservers watches its AuditLog cross-process — the same
                // mechanism the synced galaxy already uses.
                await galaxy.startObservers()
            }
        }

        galaxyRegistry.syncManager = syncManager
        galaxyRegistry.setupSyncConfigObserver()
        // Group galaxies now exist, so personal/synced must stop claiming the
        // projects they own (precedence group > synced > personal).
        galaxyRegistry.rebuildNodeFilters()
    }

    /// Tombstoned rows are hidden for everyone, author included (decision 9).
    static let groupGalaxyFilter: @Sendable (Memory) -> Bool = { $0.deletedAt == nil }

    /// Snapshot the spoke's GroupProjectMap into a resolver closure.
    /// Snapshot rather than live query: the resolver runs on the observer's
    /// background callback path per node. The map is tiny (one row per
    /// member-project pair) and galaxies reload on membership churn, so a
    /// stale snapshot costs at most one session of an old name.
    static func groupProjectResolver(
        for ref: LatticeThreadSafeReference
    ) -> (@Sendable (UUID?, String) -> String)? {
        guard let lattice = ref.resolve() else { return nil }
        var map: [String: String] = [:]
        for row in lattice.objects(GroupProjectMap.self).snapshot() {
            map["\(row.memberUserId.uuidString)|\(row.localProject)"] = row.groupProject
        }
        guard !map.isEmpty else { return nil }
        let captured = map
        return { author, local in
            guard let author else { return local }
            return captured["\(author.uuidString)|\(local)"] ?? local
        }
    }

    /// Handle late-arriving synced galaxy when daemon connects.
    func handleSyncConnect() {
        syncDrainConfig()
        if let ref = syncManager.actor.syncedLatticeRef {
            galaxyRegistry.onLatticeAvailable(
                id: "synced", displayName: "Synced", latticeRef: ref
            )
        }
        // A group joined (or the daemon finished its first sync) after
        // launch: same idempotent late-attach path the synced galaxy uses.
        let groupSpokes = syncManager.discoverGroupGalaxies()
        let attachedGroupIds = Set(groupSpokes.map(\.groupId))
        for spoke in groupSpokes {
            galaxyRegistry.onLatticeAvailable(
                id: spoke.galaxyId, displayName: spoke.name, latticeRef: spoke.ref,
                hierarchyLevel: spoke.hierarchyLevel,
                parentGalaxyId: spoke.parentId.flatMap {
                    attachedGroupIds.contains($0) ? "group:\($0.uuidString)" : nil
                },
                nodeFilter: Self.groupGalaxyFilter,
                projectResolver: Self.groupProjectResolver(for: spoke.ref))
        }
        galaxyRegistry.rebuildNodeFilters()
    }

    // Node/edge change handlers and flush methods are now in GalaxyDataLoader.
    // GraphView delegates all data operations through the Galaxy pipeline.

    /// Publish before starting a load and from setting changes, not from a
    /// render tick: scalar Lattice config reads stay outside the hot path.
    func syncDrainConfig() {
        galaxyRegistry.updateDrainConfig(from: config, timeFilter: debouncedTimeSliderDate)
    }

    func recomputeFilteredData() {
        // Lattice-backed scalar getters must not issue one SQL read per row.
        let hiddenProjects = config.hiddenProjects
        let hiddenRelations = config.hiddenRelations
        let timeFilter = debouncedTimeSliderDate
        for galaxy in galaxyRegistry.galaxies.values {
            let store = galaxy.renderStore
            store.nodes = store.allNodes.values.filter { node in
                !hiddenProjects.contains(node.project) &&
                (timeFilter == nil || node.createdAt <= timeFilter!)
            }
            // Recompute hubs
            var hubs = Set<UUID>()
            for edge in store.allEdges.values where edge.relation == "part_of" {
                hubs.insert(edge.targetId)
            }
            store.hubs = hubs

            let nodeIds = Set(store.nodes.map(\.id))
            store.edges = store.allEdges.values.filter { edge in
                nodeIds.contains(edge.sourceId) && nodeIds.contains(edge.targetId) &&
                !hiddenRelations.contains(edge.relation)
            }
            store.filteredEdgeIds = Set(store.edges.map(\.id))
            galaxy.recomputeDerivedData()
            store.bumpTopology()
        }
    }

    func recomputeHubs() {
        for galaxy in galaxyRegistry.galaxies.values {
            var hubs = Set<UUID>()
            for edge in galaxy.renderStore.allEdges.values where edge.relation == "part_of" {
                hubs.insert(edge.targetId)
            }
            galaxy.renderStore.hubs = hubs
        }
    }

    func rebuildSimulationGraph() {
        for galaxy in galaxyRegistry.galaxies.values {
            let store = galaxy.renderStore
            let filtered = store.nodes
            let currentIds = Set(filtered.map(\.id))
            let edgePairs = store.edges.map { ($0.sourceId, $0.targetId) }
            var projectMap: [UUID: String] = [:]
            var topicMap: [UUID: String] = [:]
            for node in filtered {
                projectMap[node.id] = node.project
                topicMap[node.id] = node.topic
            }

            galaxy.simulation3D?.updateGraph(nodeIds: currentIds, edges: edgePairs,
                                              projectForNode: projectMap, topicForNode: topicMap)
        }

        // Mark embedding projection stale if topology changed while in embedding mode
        if config.layoutMode == .embedding {
            projectionTopologyVersion &+= 1
        }
    }

    // Flush methods moved to GalaxyDataLoader.

    func sendMemoryNotification(title: String, body: String, id: UUID) {
        if ProcessInfo.processInfo.environment["ENGRAM_TEST_NO_NOTIFY"] != nil { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["memoryId": id]
        let request = UNNotificationRequest(
            identifier: "memory-\(id)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        Task {
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
