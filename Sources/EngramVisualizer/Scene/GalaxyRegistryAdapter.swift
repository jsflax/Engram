import Foundation
import simd
import AppKit
import EngramRealityKit
import EngramSceneKit

/// Maps a validated render-node prefix to the simulation's authoritative
/// indices. Append-only loading visits only new or previously missing nodes.
@MainActor
struct SimulationIndexCache {
    private(set) var indices: [Int] = []
    private var unresolved: [Int] = []
    private weak var indexedSimulation: ForceSimulation3D?
    private var indexGeneration: UInt64 = .max
    private var nodeOrderVersion: UInt64 = .max

    mutating func refresh(nodeCount: Int, preservingPrefix: Bool,
                          simulation: ForceSimulation3D,
                          nodeID: (Int) -> UUID) -> Bool {
        let reset = !preservingPrefix || indices.count > nodeCount
            || indexedSimulation !== simulation
            || indexGeneration != simulation.nodeIndexGeneration
        var changed = reset
        if reset {
            indices.removeAll(keepingCapacity: true)
            unresolved.removeAll(keepingCapacity: true)
        } else if nodeOrderVersion != simulation.nodeOrderVersion, !unresolved.isEmpty {
            // Valid indices survive append. Only earlier misses can change.
            var remaining: [Int] = []
            for index in unresolved {
                if let resolved = simulation.index(for: nodeID(index)) {
                    indices[index] = resolved
                    changed = true
                } else {
                    remaining.append(index)
                }
            }
            unresolved = remaining
        }
        if indices.count < nodeCount {
            if indices.capacity < nodeCount {
                indices.reserveCapacity(max(nodeCount, max(64, indices.capacity * 2)))
            }
            for index in indices.count..<nodeCount {
                let resolved = simulation.index(for: nodeID(index)) ?? -1
                indices.append(resolved)
                if resolved < 0 { unresolved.append(index) }
            }
            changed = true
        }
        indexedSimulation = simulation
        indexGeneration = simulation.nodeIndexGeneration
        nodeOrderVersion = simulation.nodeOrderVersion
        return changed
    }
}

/// Resolves static group membership once per node revision. Position reductions
/// use dense slots, so neither of the two numeric passes hashes UUIDs/strings or
/// constructs cluster keys. Missing simulation indices remain excluded.
@MainActor
struct CentroidMembershipCache {
    private struct Member {
        let project: Int
        let galaxy: Int
        let cluster: Int
        let galaxyProject: Int
    }
    private struct Project {
        let name: String
        var sum: SIMD3<Float> = .zero
        var count = 0
    }
    private struct Cluster {
        var sum: SIMD3<Float> = .zero
        var centroid: SIMD3<Float> = .zero
        var count = 0
        var radius: Float = 0
        var lastMember = 0
    }
    private struct GalaxyGroup {
        let name: String
        var center: SIMD3<Float>?
        var count = 0
        var radius: Float = 0
        var projectCounts: [String: Int] = [:]
    }
    private struct GalaxyProject: Hashable {
        let galaxy: Int
        let project: Int
    }
    private var members: [Member] = []
    private var projects: [Project] = []
    private var clusters: [Cluster] = []
    private var galaxies: [GalaxyGroup] = []
    private var galaxyProjects: [GalaxyProject] = []
    private var galaxyProjectCounts: [Int] = []
    private var projectSlots: [String: Int] = [:]
    private var clusterSlots: [String: Int] = [:]
    private var galaxySlots: [String: Int] = [:]
    private var galaxyProjectSlots: [GalaxyProject: Int] = [:]
    private weak var provider: AnyObject?
    private var nodeVersion: UInt64 = .max
    private var appendGeneration: UInt64 = .max

    mutating func refresh(nodeCount: Int, nodeVersion: UInt64, appendGeneration: UInt64,
                          provider: AnyObject,
                          membership: (Int) -> (project: String, galaxy: String)) {
        let reset = self.provider !== provider || self.appendGeneration != appendGeneration
            || members.count > nodeCount
        if !reset, self.nodeVersion == nodeVersion, members.count == nodeCount { return }
        if reset {
            members.removeAll(keepingCapacity: true)
            projects.removeAll(keepingCapacity: true)
            clusters.removeAll(keepingCapacity: true)
            galaxies.removeAll(keepingCapacity: true)
            galaxyProjects.removeAll(keepingCapacity: true)
            galaxyProjectCounts.removeAll(keepingCapacity: true)
            projectSlots.removeAll(keepingCapacity: true)
            clusterSlots.removeAll(keepingCapacity: true)
            galaxySlots.removeAll(keepingCapacity: true)
            galaxyProjectSlots.removeAll(keepingCapacity: true)
        }
        if members.capacity < nodeCount {
            members.reserveCapacity(max(nodeCount, max(64, members.capacity * 2)))
        }
        for index in members.count..<nodeCount {
            let names = membership(index)
            let project = projectSlots[names.project] ?? projects.count
            if project == projects.count {
                projectSlots[names.project] = project
                projects.append(Project(name: names.project))
            }
            let galaxy = galaxySlots[names.galaxy] ?? galaxies.count
            if galaxy == galaxies.count {
                galaxySlots[names.galaxy] = galaxy
                galaxies.append(GalaxyGroup(name: names.galaxy))
            }
            // Keep the existing concatenated-key grouping, including delimiter
            // collisions. Exact galaxy/project counts use a separate pair slot.
            let key = "\(names.galaxy)|\(names.project)"
            let cluster = clusterSlots[key] ?? clusters.count
            if cluster == clusters.count {
                clusterSlots[key] = cluster
                clusters.append(Cluster())
            }
            let pair = GalaxyProject(galaxy: galaxy, project: project)
            let galaxyProject = galaxyProjectSlots[pair] ?? galaxyProjects.count
            if galaxyProject == galaxyProjects.count {
                galaxyProjectSlots[pair] = galaxyProject
                galaxyProjects.append(pair)
                galaxyProjectCounts.append(0)
            }
            members.append(Member(project: project, galaxy: galaxy,
                                  cluster: cluster, galaxyProject: galaxyProject))
        }
        self.provider = provider
        self.nodeVersion = nodeVersion
        self.appendGeneration = appendGeneration
    }

    mutating func reduce(positions: [SIMD3<Float>], simulationIndices: [Int],
                         galaxyCenters: [String: SIMD3<Float>]) {
        for index in projects.indices {
            projects[index].sum = .zero
            projects[index].count = 0
        }
        for index in clusters.indices { clusters[index] = Cluster() }
        for index in galaxies.indices {
            galaxies[index].center = galaxyCenters[galaxies[index].name]
            galaxies[index].count = 0
            galaxies[index].radius = 0
            galaxies[index].projectCounts.removeAll(keepingCapacity: true)
        }
        for index in galaxyProjectCounts.indices { galaxyProjectCounts[index] = 0 }
        for index in members.indices {
            guard simulationIndices[index] >= 0 else { continue }
            let member = members[index], position = positions[index]
            projects[member.project].sum += position
            projects[member.project].count += 1
            clusters[member.cluster].sum += position
            clusters[member.cluster].count += 1
            // Baseline cluster labels follow the last usable member when two
            // galaxy/project pairs share the same concatenated key.
            clusters[member.cluster].lastMember = index
            galaxies[member.galaxy].count += 1
            galaxyProjectCounts[member.galaxyProject] += 1
        }
        for index in clusters.indices where clusters[index].count > 0 {
            clusters[index].centroid = clusters[index].sum / Float(clusters[index].count)
        }
        // Moving positions and downward extents are recomputed every publication.
        for index in members.indices {
            guard simulationIndices[index] >= 0 else { continue }
            let member = members[index], position = positions[index]
            clusters[member.cluster].radius = max(clusters[member.cluster].radius,
                simd_length(position - clusters[member.cluster].centroid))
            if let center = galaxies[member.galaxy].center {
                galaxies[member.galaxy].radius = max(galaxies[member.galaxy].radius,
                                                    simd_length(position - center))
            }
        }
        // Resolve names once per occupied pair, rather than once per node.
        for index in galaxyProjects.indices where galaxyProjectCounts[index] > 0 {
            let pair = galaxyProjects[index]
            galaxies[pair.galaxy].projectCounts[projects[pair.project].name] = galaxyProjectCounts[index]
        }
    }

    var projectCentroids: [String: SIMD3<Float>] {
        var result: [String: SIMD3<Float>] = [:]
        for project in projects where project.count > 0 {
            result[project.name] = project.sum / Float(project.count)
        }
        return result
    }

    var nebulaClusters: [RKNebulaCluster] {
        clusters.compactMap { cluster in
            guard cluster.count > 0 else { return nil }
            let last = members[cluster.lastMember]
            return RKNebulaCluster(galaxyId: galaxies[last.galaxy].name,
                                   project: projects[last.project].name,
                                   centroid: cluster.centroid, count: cluster.count,
                                   radius: cluster.radius + 40)
        }
    }

    func galaxyAggregate(for id: String) -> (count: Int, radius: Float?, dominantProject: String?) {
        guard let slot = galaxySlots[id] else { return (0, nil, nil) }
        let group = galaxies[slot]
        return (group.count, group.count > 0 && group.center != nil ? group.radius : nil,
                group.projectCounts.max(by: { $0.value < $1.value })?.key)
    }
}

/// Bridges GalaxyRegistry data to SceneDataProvider for EngramRealityKit.
///
/// Reads from GalaxyRegistry's merged data each frame, converting NodeData/EdgeData
/// to RKNodeSnapshot/RKEdgeSnapshot without depending on EngramKit types in the library.
@MainActor
final class GalaxyRegistryAdapter: SceneDataProvider {
    weak var registry: GalaxyRegistry? {
        didSet {
            guard registry !== oldValue else { return }
            // Equal revision counters from another provider cannot validate
            // this provider's snapshots, routing, or first centroid preview.
            lastTopologyVersion = .max
            lastColorMapVersion = .max
            lastNodesVersion = .max
            lastEdgesVersion = .max
            lastHubsVersion = .max
            preservesIndexPrefix = false
            centroidsTopologyVersion = .max
            centroidPositionVersion = .max
            frameCentroids.removeAll(keepingCapacity: true)
            frameNebulaClusters.removeAll(keepingCapacity: true)
            frameGalaxySnapshots.removeAll(keepingCapacity: true)
        }
    }

    // Each snapshot follows its own domain; edge/status/color updates do not
    // validate every node again. Hub membership is a node-snapshot dependency.
    private var cachedNodes: [RKNodeSnapshot] = []
    private var cachedNodeIndices: [UUID: Int] = [:]
    private var cachedNodeIDsAreUnique = true
    private var cachedEdges: [RKEdgeSnapshot] = []
    private var cachedHubs: Set<UUID> = []
    private var cachedColorMap: [String: SIMD3<Float>] = [:]
    private var lastTopologyVersion: UInt64 = 0
    private var lastColorMapVersion: UInt64 = 0
    private var lastNodesVersion: UInt64 = .max
    private var lastEdgesVersion: UInt64 = .max
    private var lastHubsVersion: UInt64 = .max
    private(set) var nodePrefixComparisonCount: UInt64 = 0
    private(set) var nodeSnapshotBuildCount: UInt64 = 0
    private(set) var edgePrefixComparisonCount: UInt64 = 0
    private(set) var edgeSnapshotBuildCount: UInt64 = 0

    // Visual state — elapsed times tracked per-frame
    private var glowStartTimes: [UUID: Date] = [:]
    private var newNodeStartTimes: [UUID: Date] = [:]

    // Per-frame caches, refreshed once in tick(). The batch systems read
    // these properties several times per frame; computed accessors rebuilt
    // dicts/arrays on every access (positionArray alone was 4×O(n) per
    // frame — the production analog of the preview's V0 hot path).
    private var framePositionArray: [SIMD3<Float>] = []
    private var frameGlowing: [UUID: Float] = [:]
    private var frameNewGlows: [UUID: Float] = [:]
    private var frameCentroids: [String: SIMD3<Float>] = [:]
    private var simulationIndices = SimulationIndexCache()
    private var centroidMembership = CentroidMembershipCache()
    private var preservesIndexPrefix = true
    private var cachedPositionVersion: UInt64 = .max
    private var centroidPositionVersion: UInt64 = .max

    init(registry: GalaxyRegistry) {
        self.registry = registry
    }

    // MARK: - SceneDataProvider

    var nodes: [RKNodeSnapshot] { cachedNodes }
    var edges: [RKEdgeSnapshot] { cachedEdges }
    var hubs: Set<UUID> { cachedHubs }
    var projectColorMap: [String: SIMD3<Float>] { cachedColorMap }

    var positions: [UUID: SIMD3<Float>] {
        registry?.mergedPositions ?? [:]
    }

    func position(for id: UUID) -> SIMD3<Float>? {
        guard let simulation = registry?.unifiedSimulation,
              let index = simulation.index(for: id) else { return nil }
        // Resolve the current simulation slot on every call. Render slots can
        // differ, and appends, removal or provider replacement can move indices.
        return SIMD3(simulation.posX[index], simulation.posY[index], simulation.posZ[index])
    }

    /// Flat positions parallel to `nodes`, refreshed once per tick from the
    /// unified simulation's flat arrays (no UUID hashing on access).
    var positionArray: [SIMD3<Float>] { framePositionArray }
    var positionVersion: UInt64 { registry?.unifiedSimulation.positionVersion ?? 0 }

    var glowingNodes: [UUID: Float] { frameGlowing }

    var newNodeGlows: [UUID: Float] { frameNewGlows }

    var dyingNodes: Set<UUID> {
        guard let registry else { return [] }
        return Set(registry.mergedDyingNodes.keys)
    }

    var selectedNode: UUID? {
        get { _selectedNode }
        set { _selectedNode = newValue }
    }
    private var _selectedNode: UUID?

    var expandedHubs: Set<UUID> {
        // Hub expansion is managed by the input handler
        []
    }

    var searchMatchIds: Set<UUID> {
        registry?.mergedSearchMatchIds ?? []
    }

    var isSearchActive: Bool {
        registry?.mergedIsSearchActive ?? false
    }

    var projectCentroids: [String: SIMD3<Float>] { frameCentroids }

    var topologyVersion: UInt64 {
        registry?.mergedTopologyVersion ?? 0
    }
    var nodeVersion: UInt64 { registry?.mergedNodesVersion ?? 0 }
    var hubVersion: UInt64 { registry?.mergedHubsVersion ?? 0 }
    var edgeVersion: UInt64 { registry?.mergedEdgesVersion ?? 0 }
    var nodeAppendGeneration: UInt64 { registry?.mergedNodeAppendGeneration ?? 0 }

    func tick(dt: Float) {
        guard let registry else { return }
        drain(registry)
        registry.unifiedSimulation.tick()
        registry.mergeRenderData()
        rebuildIfNeeded(registry)
        syncGlowState()
        refreshFrameCaches()
    }

    /// Separate opt-in path: ordinary ticks do not read clocks or allocate
    /// timing records. Both paths execute the same stage bodies in order.
    func tickWithTimings(dt: Float) -> ProviderTickTimings? {
        guard let registry else { return nil }
        let start = DispatchTime.now().uptimeNanoseconds
        drain(registry)
        let afterDrain = DispatchTime.now().uptimeNanoseconds
        registry.unifiedSimulation.tick()
        let afterSimulation = DispatchTime.now().uptimeNanoseconds
        registry.mergeRenderData()
        let afterMerge = DispatchTime.now().uptimeNanoseconds
        rebuildIfNeeded(registry)
        let afterRebuild = DispatchTime.now().uptimeNanoseconds
        syncGlowState()
        refreshFrameCaches()
        let afterCache = DispatchTime.now().uptimeNanoseconds
        return ProviderTickTimings(drainNanoseconds: afterDrain - start,
                                   simulationNanoseconds: afterSimulation - afterDrain,
                                   mergeNanoseconds: afterMerge - afterSimulation,
                                   rebuildNanoseconds: afterRebuild - afterMerge,
                                   cacheNanoseconds: afterCache - afterRebuild)
    }

    @inline(__always)
    private func drain(_ registry: GalaxyRegistry) {
        // Drain pending updates from all galaxies
        let drainConfig = registry.currentDrainConfig
        let perGalaxyBudget = 0.002 / Double(max(1, registry.galaxies.count))
        for galaxy in registry.galaxies.values {
            galaxy.drainPendingUpdate(config: drainConfig, workBudget: perGalaxyBudget)
        }
    }

    @inline(__always)
    private func rebuildIfNeeded(_ registry: GalaxyRegistry) {
        // Rebuild snapshots on topology change
        let currentTopology = registry.mergedTopologyVersion
        if currentTopology != lastTopologyVersion {
            lastTopologyVersion = currentTopology
            rebuildSnapshots()
            #if ENGRAM_INSTRUMENTATION
            print("[adapter] topology v\(currentTopology): \(cachedNodes.count) nodes, \(cachedEdges.count) edges, mergedEdges=\(registry.mergedEdges.count), positions=\(registry.mergedPositions.count)")
            #endif
        }

        // Rebuild color map if needed
        let currentColorVersion = registry.mergedColorMapVersion
        if currentColorVersion != lastColorMapVersion {
            lastColorMapVersion = currentColorVersion
            rebuildColorMap()
        }
    }

    /// Once-per-frame snapshot of everything the batch systems poll.
    private func refreshFrameCaches() {
        guard let registry else { return }
        let sim = registry.unifiedSimulation

        // Reuse indices for the validated render prefix. The simulation owns
        // the UUID lookup; no duplicate full-graph dictionary is needed here.
        let n = cachedNodes.count
        let nodes = cachedNodes
        let indicesChanged = simulationIndices.refresh(
            nodeCount: n, preservingPrefix: preservesIndexPrefix, simulation: sim
        ) { nodes[$0].id }
        preservesIndexPrefix = true
        if framePositionArray.count != n {
            framePositionArray = [SIMD3<Float>](repeating: .zero, count: n)
        }
        if indicesChanged || cachedPositionVersion != sim.positionVersion {
            let px = sim.posX, py = sim.posY, pz = sim.posZ
            simulationIndices.indices.withUnsafeBufferPointer { simIdx in
                for i in 0..<n {
                    let si = simIdx[i]
                    framePositionArray[i] = si >= 0 && si < px.count ?
                        SIMD3<Float>(px[si], py[si], pz[si]) : .zero
                }
            }
            cachedPositionVersion = sim.positionVersion
        }

        // Glow elapsed times — one Date() call, one dict build per frame.
        let now = Date()
        frameGlowing.removeAll(keepingCapacity: true)
        for (id, start) in glowStartTimes {
            frameGlowing[id] = Float(now.timeIntervalSince(start))
        }
        frameNewGlows.removeAll(keepingCapacity: true)
        for (id, start) in newNodeStartTimes {
            frameNewGlows[id] = Float(now.timeIntervalSince(start))
        }

        // Project centroids — publish the first preview, then throttle loading
        // and position drift to every 30 frames. Completed/live topology changes
        // refresh immediately. Both streaming chunks and legacy bulk draining
        // are loading; streaming does not populate loadingUpdate. This refresh
        // also builds (galaxy, project) nebula clusters and per-galaxy aggregates.
        // Membership slots follow the registry's node/ownership revisions;
        // both O(n) numeric passes reuse them while positions remain fresh.
        frameCounter &+= 1
        let isLoading = registry.galaxies.values.contains {
            $0.isDrainingInitialSnapshot || $0.loadStatus == .loading
        }
        let topologyNeedsCentroids = lastTopologyVersion != centroidsTopologyVersion
            && (!isLoading || frameCentroids.isEmpty || frameCounter % 30 == 0)
        if topologyNeedsCentroids
            || (frameCounter % 30 == 0 && centroidPositionVersion != sim.positionVersion) {
            centroidMembership.refresh(
                nodeCount: cachedNodes.count, nodeVersion: registry.mergedNodesVersion,
                appendGeneration: registry.mergedNodeAppendGeneration, provider: registry
            ) { index in
                let node = cachedNodes[index]
                return (node.project, registry.nodeToGalaxy[node.id] ?? "personal")
            }
            centroidMembership.reduce(positions: framePositionArray,
                                      simulationIndices: simulationIndices.indices,
                                      galaxyCenters: registry.galaxies.mapValues { $0.worldCenter })
            frameCentroids = centroidMembership.projectCentroids
            frameNebulaClusters = centroidMembership.nebulaClusters

            frameGalaxySnapshots = registry.galaxies.values.map { galaxy in
                // Dominant color = largest project's color in THIS galaxy.
                let aggregate = centroidMembership.galaxyAggregate(for: galaxy.id)
                let color = aggregate.dominantProject.flatMap { cachedColorMap[$0] }
                    ?? SIMD3<Float>(0.5, 0.5, 0.6)
                return RKGalaxySnapshot(
                    id: galaxy.id,
                    displayName: galaxy.displayName,
                    worldCenter: galaxy.worldCenter,
                    dominantColor: color,
                    nodeCount: aggregate.count,
                    radius: aggregate.radius ?? 300,
                    parentGalaxyId: galaxy.parentGalaxyId)
            }
            centroidsTopologyVersion = lastTopologyVersion
            centroidPositionVersion = sim.positionVersion
        }
    }
    private var centroidsTopologyVersion: UInt64 = .max
    private var frameCounter: UInt64 = 0
    private var frameNebulaClusters: [RKNebulaCluster] = []
    private var frameGalaxySnapshots: [RKGalaxySnapshot] = []

    var nebulaClusters: [RKNebulaCluster] { frameNebulaClusters }
    var galaxySnapshots: [RKGalaxySnapshot] { frameGalaxySnapshots }

    // MARK: - Snapshot Rebuilding

    private func rebuildSnapshots() {
        guard let registry else { return }

        let mergedHubs = registry.mergedHubs
        let hubsChanged = lastHubsVersion != registry.mergedHubsVersion
        if lastNodesVersion != registry.mergedNodesVersion {
            let nodes = registry.mergedNodes
            // Only store-certified continuity can bypass comparisons. Arbitrary
            // edits, missed publications and replacement retain complete node
            // metadata validation. Independent hub flags are patched below.
            let prefix = registry.preservedNodePrefix(
                since: lastNodesVersion, count: cachedNodes.count)
            let canAppendNodes = prefix == nil && nodes.count >= cachedNodes.count
                && cachedNodes.indices.allSatisfy { index in
                    nodePrefixComparisonCount &+= 1
                    let old = cachedNodes[index], node = nodes[index]
                    return old.id == node.id && old.project == node.project
                        && old.topic == node.topic && old.label == node.label
                        && old.content == node.content && old.importance == node.importance
                        && old.createdAt == node.createdAt && old.lastAccessedAt == node.lastAccessedAt
                }
            let retained = prefix ?? (canAppendNodes ? cachedNodes.count : 0)
            if retained < cachedNodes.count {
                preservesIndexPrefix = false
                if cachedNodeIDsAreUnique {
                    for node in cachedNodes.dropFirst(retained) {
                        cachedNodeIndices.removeValue(forKey: node.id)
                    }
                }
                cachedNodes.removeSubrange(retained...)
                if !cachedNodeIDsAreUnique {
                    cachedNodeIndices.removeAll(keepingCapacity: true)
                    cachedNodeIDsAreUnique = true
                    for (index, node) in cachedNodes.enumerated() {
                        if cachedNodeIndices.updateValue(index, forKey: node.id) != nil {
                            cachedNodeIDsAreUnique = false
                        }
                    }
                }
            }
            if cachedNodes.capacity < nodes.count {
                cachedNodes.reserveCapacity(max(nodes.count, max(64, cachedNodes.capacity * 2)))
            }
            for node in nodes.dropFirst(cachedNodes.count) {
                nodeSnapshotBuildCount &+= 1
                if cachedNodeIndices.updateValue(cachedNodes.count, forKey: node.id) != nil {
                    cachedNodeIDsAreUnique = false
                }
                cachedNodes.append(RKNodeSnapshot(
                    id: node.id,
                    project: node.project,
                    topic: node.topic,
                    label: node.label,
                    content: node.content,
                    importance: node.importance,
                    isHub: mergedHubs.contains(node.id),
                    createdAt: node.createdAt,
                    lastAccessedAt: node.lastAccessedAt
                ))
            }
            lastNodesVersion = registry.mergedNodesVersion
        }

        if lastEdgesVersion != registry.mergedEdgesVersion {
            let edges = registry.mergedEdges
            let canAppendEdges = edges.count >= cachedEdges.count
                && cachedEdges.indices.allSatisfy { index in
                    edgePrefixComparisonCount &+= 1
                    let old = cachedEdges[index], edge = edges[index]
                    return old.id == edge.id && old.sourceId == edge.sourceId
                        && old.targetId == edge.targetId && old.relation == edge.relation
                }
            if !canAppendEdges { cachedEdges.removeAll(keepingCapacity: true) }
            if cachedEdges.capacity < edges.count {
                cachedEdges.reserveCapacity(max(edges.count, max(64, cachedEdges.capacity * 2)))
            }
            for edge in edges.dropFirst(cachedEdges.count) {
                edgeSnapshotBuildCount &+= 1
                cachedEdges.append(RKEdgeSnapshot(
                    id: edge.id,
                    sourceId: edge.sourceId,
                    targetId: edge.targetId,
                    relation: edge.relation
                ))
            }
            lastEdgesVersion = registry.mergedEdgesVersion
        }

        // Do not pin the mutable render store's Set storage via this cache or
        // LOD's retained prior hub set while the next loading batch inserts.
        if hubsChanged {
            let changed = cachedHubs.symmetricDifference(mergedHubs)
            if cachedNodeIDsAreUnique {
                for id in changed {
                    if let index = cachedNodeIndices[id] {
                        updateCachedHub(at: index, isHub: mergedHubs.contains(id))
                    }
                }
            } else {
                // Registry merging deduplicates normal multi-galaxy inputs.
                // An arbitrary single-store replacement may contain duplicates;
                // preserve all of its rows rather than choosing one cached slot.
                for index in cachedNodes.indices where changed.contains(cachedNodes[index].id) {
                    updateCachedHub(at: index, isHub: mergedHubs.contains(cachedNodes[index].id))
                }
            }
            cachedHubs = Set(mergedHubs.map { $0 })
            lastHubsVersion = registry.mergedHubsVersion
        }
    }

    private func updateCachedHub(at index: Int, isHub: Bool) {
        let node = cachedNodes[index]
        guard node.isHub != isHub else { return }
        nodeSnapshotBuildCount &+= 1
        cachedNodes[index] = RKNodeSnapshot(
            id: node.id, project: node.project, topic: node.topic,
            label: node.label, content: node.content, importance: node.importance,
            isHub: isHub, createdAt: node.createdAt, lastAccessedAt: node.lastAccessedAt
        )
    }

    private func rebuildColorMap() {
        guard let registry else { return }
        var colorMap: [String: SIMD3<Float>] = [:]
        for (project, color) in registry.mergedColorMap {
            let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            nsColor.getRed(&r, green: &g, blue: &b, alpha: &a)
            colorMap[project] = SIMD3<Float>(Float(r), Float(g), Float(b))
        }
        cachedColorMap = colorMap
    }

    private func syncGlowState() {
        guard let registry else { return }

        // Preserve restarted timestamps as well as membership. A second recall
        // during an active glow must restart the animation immediately.
        glowStartTimes = registry.mergedGlowingNodes
        newNodeStartTimes = registry.mergedNewNodeGlows
    }
}
