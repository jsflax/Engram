import Foundation
import simd

/// Manages hub expand/collapse orbit animations.
/// Extracted from MetalSceneManager — owns the expansion state and lerps
/// child node positions each frame when a hub is expanded or collapsing.
@MainActor
public final class EngramGraphHubExpansionController {
    public init() {}

    public var expandedHubs: Set<UUID> = []
    public var expansionProgress: [UUID: Float] = [:]
    public var expansionDirection: [UUID: Bool] = [:]
    public var preExpansionPositions: [UUID: SIMD3<Float>] = [:]
    public var expandedChildPositions: [UUID: SIMD3<Float>] = [:]
    public var pendingHubToggles: [(hubId: UUID, expanding: Bool)] = []


    // Exact-graph renderer fast path. Legacy dictionary APIs below remain available
    // to desktop wrappers. Topology is indexed once, never rediscovered each frame.
    struct IndexedWork: Equatable {
        var topologyEdges = 0
        var orbitOffsets = 0
        var hubVisits = 0
        var childVisits = 0
        var positionWrites = 0
    }
    private(set) var indexedWork = IndexedWork()
    private struct IndexedChild {
        let id: UUID
        let index: Int
        let offset: SIMD3<Float>
    }
    private struct IndexedHub {
        let index: Int
        let children: [IndexedChild]
    }
    private var indexedHubs: [UUID: IndexedHub] = [:]
    private var lastIndexedCenter: [UUID: SIMD3<Float>] = [:]
    private var lastIndexedProgress: [UUID: Float] = [:]
    private var animatingIndexedHubs: Set<UUID> = []
    var isIndexedAnimating: Bool { !animatingIndexedHubs.isEmpty }

    func installTopology(edges: [(sourceId: UUID, targetId: UUID, relation: String)],
                         nodeIndices: [UUID: Int]) {
        indexedHubs.removeAll(keepingCapacity: true)
        lastIndexedCenter.removeAll(keepingCapacity: true)
        lastIndexedProgress.removeAll(keepingCapacity: true)
        animatingIndexedHubs.removeAll(keepingCapacity: true)
        var children: [UUID: [UUID]] = [:]
        for edge in edges {
            indexedWork.topologyEdges += 1
            guard edge.relation == "part_of", nodeIndices[edge.sourceId] != nil,
                  nodeIndices[edge.targetId] != nil else { continue }
            children[edge.targetId, default: []].append(edge.sourceId)
        }
        for (hub, ids) in children {
            guard let index = nodeIndices[hub] else { continue }
            let indexed = ids.enumerated().compactMap { offset, id -> IndexedChild? in
                guard let childIndex = nodeIndices[id] else { return nil }
                indexedWork.orbitOffsets += 1
                return IndexedChild(id: id, index: childIndex,
                    offset: Self.orbitOffset(index: offset, count: ids.count))
            }
            indexedHubs[hub] = IndexedHub(index: index, children: indexed)
        }
    }

    func indexedChildren(of hub: UUID) -> [UUID] {
        indexedHubs[hub]?.children.map(\.id) ?? []
    }

    func toggleIndexed(hub: UUID, positions: [SIMD3<Float>]) {
        guard let layout = indexedHubs[hub] else { return }
        if expandedHubs.contains(hub) {
            expansionDirection[hub] = false
        } else {
            expandedHubs.insert(hub)
            for child in layout.children { preExpansionPositions[child.id] = positions[child.index] }
            expansionProgress[hub] = 0
            expansionDirection[hub] = true
        }
        animatingIndexedHubs.insert(hub)
    }

    /// Only changed/animated hubs visit their cached children. A changed force buffer
    /// must reapply overlays even if the hub center itself stayed still.
    @discardableResult
    func updateIndexed(dt: Float, positions: inout [SIMD3<Float>], baseChanged: Bool,
                       onCollapsed: (UUID, SIMD3<Float>) -> Void) -> Bool {
        var removed: [UUID] = []
        var changed = false
        for hub in expandedHubs {
            indexedWork.hubVisits += 1
            guard let layout = indexedHubs[hub] else { continue }
            let expanding = expansionDirection[hub] ?? true
            let previous = expansionProgress[hub] ?? 0
            let delta = max(0, dt) * 3
            let progress = expanding ? min(1, previous + delta) : max(0, previous - delta)
            expansionProgress[hub] = progress
            let center = positions[layout.index]
            let collapsingFinished = !expanding && progress == 0
            guard baseChanged || lastIndexedCenter[hub] != center || lastIndexedProgress[hub] != progress || collapsingFinished else { continue }
            lastIndexedCenter[hub] = center; lastIndexedProgress[hub] = progress
            let t = progress * progress * (3 - 2 * progress)
            for child in layout.children {
                indexedWork.childVisits += 1
                let start = preExpansionPositions[child.id] ?? positions[child.index]
                let next = start + (center + child.offset - start) * t
                if positions[child.index] != next {
                    positions[child.index] = next
                    indexedWork.positionWrites += 1
                    changed = true
                }
                if collapsingFinished {
                    preExpansionPositions.removeValue(forKey: child.id)
                    expandedChildPositions.removeValue(forKey: child.id)
                    onCollapsed(child.id, start)
                } else {
                    expandedChildPositions[child.id] = next
                }
            }
            if progress == 1 && expanding { animatingIndexedHubs.remove(hub) }
            if collapsingFinished { removed.append(hub) }
        }
        for hub in removed {
            expandedHubs.remove(hub); expansionProgress.removeValue(forKey: hub)
            expansionDirection.removeValue(forKey: hub); animatingIndexedHubs.remove(hub)
            lastIndexedCenter.removeValue(forKey: hub); lastIndexedProgress.removeValue(forKey: hub)
        }
        return changed
    }

    private static func orbitOffset(index: Int, count: Int) -> SIMD3<Float> {
        let radius: Float = 80
        let goldenRatio: Float = (1 + sqrt(5)) / 2
        let i = Float(index)
        let theta = acos(1 - 2 * (i + 0.5) / Float(count))
        let phi = 2 * Float.pi * i / goldenRatio
        return SIMD3(radius * sin(theta) * cos(phi), radius * sin(theta) * sin(phi), radius * cos(theta))
    }

    // MARK: - Queries

    public func childrenOfHub(
        _ hubId: UUID,
        edges: [(sourceId: UUID, targetId: UUID, relation: String)]
    ) -> [UUID] {
        edges.filter { $0.relation == "part_of" && $0.targetId == hubId }.map(\.sourceId)
    }

    public func computeOrbitPositions(
        hubId: UUID,
        children: [UUID],
        positions: [UUID: SIMD3<Float>]
    ) -> [UUID: SIMD3<Float>] {
        guard let hubPos = positions[hubId] else { return [:] }
        var result: [UUID: SIMD3<Float>] = [:]
        guard !children.isEmpty else { return result }
        for (index, child) in children.enumerated() {
            result[child] = hubPos + Self.orbitOffset(index: index, count: children.count)
        }
        return result
    }

    // MARK: - Toggle

    public func toggleHubExpansion(
        hubId: UUID,
        positions: [UUID: SIMD3<Float>],
        edges: [(sourceId: UUID, targetId: UUID, relation: String)]
    ) {
        if expandedHubs.contains(hubId) {
            expansionDirection[hubId] = false
        } else {
            expandedHubs.insert(hubId)
            let children = childrenOfHub(hubId, edges: edges)
            for childId in children {
                preExpansionPositions[childId] = positions[childId] ?? .zero
            }
            expansionProgress[hubId] = 0
            expansionDirection[hubId] = true
        }
    }

    // MARK: - Per-frame update

    /// Advance all active expansions/collapses and write lerped positions
    /// into both `positions` (in-out) and `expandedChildPositions`.
    public func updateExpansions(
        dt: Float,
        positions: inout [UUID: SIMD3<Float>],
        edges: [(sourceId: UUID, targetId: UUID, relation: String)]
    ) {
        var toRemove: [UUID] = []
        var allExpandedPositions: [UUID: SIMD3<Float>] = [:]

        for hubId in expandedHubs {
            let expanding = expansionDirection[hubId] ?? true
            var progress = expansionProgress[hubId] ?? 0

            if expanding { progress = min(1.0, progress + dt * 3.0) }
            else { progress = max(0.0, progress - dt * 3.0) }
            expansionProgress[hubId] = progress

            let t = progress * progress * (3 - 2 * progress)
            let children = childrenOfHub(hubId, edges: edges)
            let orbitPositions = computeOrbitPositions(hubId: hubId, children: children, positions: positions)

            for childId in children {
                let startPos = preExpansionPositions[childId] ?? positions[childId] ?? .zero
                let endPos = orbitPositions[childId] ?? startPos
                let lerpedPos = startPos + (endPos - startPos) * t
                positions[childId] = lerpedPos
                allExpandedPositions[childId] = lerpedPos
            }

            if !expanding && progress <= 0 {
                toRemove.append(hubId)
                for childId in children {
                    if let original = preExpansionPositions[childId] {
                        positions[childId] = original
                    }
                    preExpansionPositions.removeValue(forKey: childId)
                }
            }
        }

        expandedChildPositions = allExpandedPositions
        for hubId in toRemove {
            expandedHubs.remove(hubId)
            expansionProgress.removeValue(forKey: hubId)
            expansionDirection.removeValue(forKey: hubId)
        }
    }
}
