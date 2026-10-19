import Foundation

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

    /// Callers without a node-domain contract retain the full rebuild behavior.
    func update(nodes: [RKNodeSnapshot], topologyVersion: UInt64, provider: AnyObject) {
        update(nodes: nodes, nodeVersion: topologyVersion, nodeAppendGeneration: nil, provider: provider)
    }

    func update(nodes: [RKNodeSnapshot], nodeVersion: UInt64,
                nodeAppendGeneration: UInt64?, provider: AnyObject) {
        let sameProvider = cachedProvider === provider
        guard !sameProvider || self.nodeVersion != nodeVersion
                || nodeCount != nodes.count else { return }
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
        cachedProvider = provider
        self.nodeVersion = nodeVersion
        appendGeneration = nodeAppendGeneration
        nodeCount = nodes.count
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
