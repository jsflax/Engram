import Foundation

/// Maintains flat edge endpoints while a graph arrives in batches. Verifying
/// compact UUID prefixes is much cheaper than hashing every endpoint again.
/// Keep compact keys rather than retaining the provider arrays: a retained
/// snapshot would force those arrays to copy on their next append.
struct EdgeEndpointIndexCache {
    enum UpdateKind: Equatable { case unchanged, appended, rebuilt }

    private struct EdgeKey: Equatable {
        let id: UUID
        let source: UUID
        let target: UUID

        init(_ edge: RKEdgeSnapshot) {
            id = edge.id
            source = edge.sourceId
            target = edge.targetId
        }
    }

    private var nodeIDs: [UUID] = []
    private var edgeKeys: [EdgeKey] = []
    private var nodeIndices: [UUID: Int32] = [:]
    private var unresolvedEdges: [Int] = []
    private(set) var sourceIndices: [Int32] = []
    private(set) var targetIndices: [Int32] = []
    var nodeCount: Int { nodeIDs.count }

    @discardableResult
    mutating func update(nodes: [RKNodeSnapshot], edges: [RKEdgeSnapshot]) -> UpdateKind {
        let keepsPrefix = nodes.count >= nodeIDs.count && edges.count >= edgeKeys.count
            && nodeIDs.indices.allSatisfy { nodeIDs[$0] == nodes[$0].id }
            && edgeKeys.indices.allSatisfy { edgeKeys[$0] == EdgeKey(edges[$0]) }
        if !keepsPrefix {
            nodeIDs.removeAll(keepingCapacity: true)
            edgeKeys.removeAll(keepingCapacity: true)
            nodeIndices.removeAll(keepingCapacity: true)
            unresolvedEdges.removeAll(keepingCapacity: true)
            sourceIndices.removeAll(keepingCapacity: true)
            targetIndices.removeAll(keepingCapacity: true)
        }

        let oldNodeCount = nodeIDs.count
        let oldEdgeCount = edgeKeys.count
        for index in oldNodeCount..<nodes.count {
            let id = nodes[index].id
            nodeIDs.append(id)
            nodeIndices[id] = Int32(index)
        }

        // An edge may precede one of its nodes. Appending that node must repair
        // the existing edge, even when no edge identities/endpoints changed.
        if nodes.count > oldNodeCount && !unresolvedEdges.isEmpty {
            var stillUnresolved: [Int] = []
            for index in unresolvedEdges {
                let key = edgeKeys[index]
                sourceIndices[index] = nodeIndices[key.source] ?? -1
                targetIndices[index] = nodeIndices[key.target] ?? -1
                if sourceIndices[index] < 0 || targetIndices[index] < 0 {
                    stillUnresolved.append(index)
                }
            }
            unresolvedEdges = stillUnresolved
        }

        for index in oldEdgeCount..<edges.count {
            let key = EdgeKey(edges[index])
            edgeKeys.append(key)
            let source = nodeIndices[key.source] ?? -1
            let target = nodeIndices[key.target] ?? -1
            sourceIndices.append(source)
            targetIndices.append(target)
            if source < 0 || target < 0 { unresolvedEdges.append(index) }
        }
        if !keepsPrefix { return .rebuilt }
        return nodes.count == oldNodeCount && edges.count == oldEdgeCount ? .unchanged : .appended
    }
}

/// The edge renderer additionally needs the source project's color. Project
/// edits invalidate this prefix even when node identities remain unchanged.
struct EdgeNodeLookupCache {
    private var nodeIDs: [UUID] = []
    private var nodeProjects: [String] = []
    private(set) var indices: [UUID: Int] = [:]
    private(set) var projects: [UUID: String] = [:]

    mutating func update(nodes: [RKNodeSnapshot]) {
        let keepsPrefix = nodes.count >= nodeIDs.count && nodeIDs.indices.allSatisfy {
            nodeIDs[$0] == nodes[$0].id && nodeProjects[$0] == nodes[$0].project
        }
        if !keepsPrefix {
            nodeIDs.removeAll(keepingCapacity: true)
            nodeProjects.removeAll(keepingCapacity: true)
            indices.removeAll(keepingCapacity: true)
            projects.removeAll(keepingCapacity: true)
        }
        for index in nodeIDs.count..<nodes.count {
            let node = nodes[index]
            nodeIDs.append(node.id)
            nodeProjects.append(node.project)
            indices[node.id] = index
            projects[node.id] = node.project
        }
    }
}
