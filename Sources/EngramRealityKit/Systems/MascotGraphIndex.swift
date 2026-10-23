import Foundation
import EngramSceneKit

/// Shared routing for patrol selection and holo lookups; never retains a second
/// node snapshot or rebuilds project subsets during a mascot's animation tick.
@MainActor
final class MascotGraphIndex {
    private weak var cachedProvider: AnyObject?
    private var nodeVersion: UInt64 = .max
    private var appendGeneration: UInt64?
    private var nodeCount = -1
    private(set) var projects: Set<String> = []
    private(set) var indicesByProject: [String: [Int]] = [:]
    private(set) var indexByID: [UUID: Int] = [:]
    private(set) var nodesVisited = 0
    /// Retained project slots and UUID slots translated during interior insertion.
    private(set) var retainedIndexRemapCount = 0

    /// Callers without a node-domain contract retain the full rebuild behavior.
    func update(nodes: [RKNodeSnapshot], topologyVersion: UInt64, provider: AnyObject) {
        update(nodes: nodes, nodeVersion: topologyVersion, nodeAppendGeneration: nil, provider: provider)
    }

    func update(nodes: [RKNodeSnapshot], nodeVersion: UInt64,
                nodeAppendGeneration: UInt64?, provider: AnyObject,
                nodeInsertionReuse: NodeInsertionReuse? = nil) {
        let sameProvider = cachedProvider === provider
        guard !sameProvider || self.nodeVersion != nodeVersion
                || nodeCount != nodes.count || appendGeneration != nodeAppendGeneration else { return }
        let offeredReuse = nodeInsertionReuse ?? (provider as? any SceneDataProvider)?
            .nodeInsertionReuse(since: self.nodeVersion, count: nodeCount)
        if sameProvider, let reuse = offeredReuse,
           reuse.matches(fromVersion: self.nodeVersion, oldCount: nodeCount,
                         toVersion: nodeVersion, newCount: nodes.count) {
            let preservesExistingIndices = reuse.preservesExistingIndices
            if !preservesExistingIndices {
                indicesByProject = indicesByProject.mapValues { indices in
                    indices.map {
                        retainedIndexRemapCount += 1
                        return reuse.newIndex(forOldIndex: $0)!
                    }
                }
                indexByID = indexByID.mapValues {
                    retainedIndexRemapCount += 1
                    return reuse.newIndex(forOldIndex: $0)!
                }
            }
            var insertedByProject: [String: [Int]] = [:]
            for range in reuse.insertedRanges {
                for index in range {
                    let node = nodes[index]
                    nodesVisited += 1
                    projects.insert(node.project)
                    if preservesExistingIndices {
                        indicesByProject[node.project, default: []].append(index)
                    } else {
                        insertedByProject[node.project, default: []].append(index)
                    }
                    // An inserted duplicate before the previous winner becomes
                    // the first match; later copies must not replace it.
                    if index < (indexByID[node.id] ?? Int.max) { indexByID[node.id] = index }
                }
            }
            for (project, inserted) in insertedByProject {
                indicesByProject[project] = Self.merge(indicesByProject[project] ?? [], inserted)
            }
        } else {
            let keepsPrefix = sameProvider && nodeAppendGeneration != nil
                && appendGeneration == nodeAppendGeneration && nodes.count >= nodeCount
            if !keepsPrefix {
                indicesByProject.removeAll(keepingCapacity: true)
                indexByID.removeAll(keepingCapacity: true)
                projects.removeAll(keepingCapacity: true)
                nodeCount = 0
            }
            indexByID.reserveCapacity(nodes.count)
            for index in nodeCount..<nodes.count {
                let node = nodes[index]
                nodesVisited += 1
                indicesByProject[node.project, default: []].append(index)
                projects.insert(node.project)
                // Match the old first(where:) lookup if a provider contains copies.
                if indexByID[node.id] == nil { indexByID[node.id] = index }
            }
        }
        cachedProvider = provider
        self.nodeVersion = nodeVersion
        appendGeneration = nodeAppendGeneration
        nodeCount = nodes.count
    }

    private static func merge(_ old: [Int], _ inserted: [Int]) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(old.count + inserted.count)
        var oldIndex = 0, newIndex = 0
        while oldIndex < old.count && newIndex < inserted.count {
            if old[oldIndex] < inserted[newIndex] {
                result.append(old[oldIndex]); oldIndex += 1
            } else {
                result.append(inserted[newIndex]); newIndex += 1
            }
        }
        result.append(contentsOf: old.dropFirst(oldIndex))
        result.append(contentsOf: inserted.dropFirst(newIndex))
        return result
    }

    /// Point lights share the guarded first-match lookup. Colors remain live:
    /// changing the palette does not require a node topology revision.
    func projectColor(for nodeID: UUID, dataProvider: SceneDataProvider) -> SIMD3<Float> {
        let nodes = dataProvider.nodes
        update(nodes: nodes, nodeVersion: dataProvider.nodeVersion,
               nodeAppendGeneration: dataProvider.nodeAppendGeneration, provider: dataProvider)
        guard let index = indexByID[nodeID] else { return SIMD3<Float>(repeating: 0.5) }
        return dataProvider.projectColorMap[nodes[index].project] ?? SIMD3<Float>(repeating: 0.5)
    }
}
