import Foundation
import EngramSceneKit

/// Maintains flat edge endpoints while a graph arrives in batches. Provider
/// revisions avoid rechecking unchanged domains; changed edge prefixes and
/// callers without continuity still receive the compact-key validation.
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
    private weak var cachedProvider: AnyObject?
    private var cachedNodeVersion: UInt64?
    private var cachedEdgeVersion: UInt64?
    private var cachedAppendGeneration: UInt64?
    private(set) var nodeMetadataReadCount = 0
    private(set) var nodePrefixComparisonCount = 0
    private(set) var edgePrefixComparisonCount = 0
    private(set) var sourceIndices: [Int32] = []
    private(set) var targetIndices: [Int32] = []
    var nodeCount: Int { nodeIDs.count }

    @discardableResult
    mutating func update(
        nodes: [RKNodeSnapshot], edges: [RKEdgeSnapshot],
        provider: AnyObject? = nil, nodeVersion: UInt64? = nil,
        edgeVersion: UInt64? = nil, nodeAppendGeneration: UInt64? = nil,
        nodeInsertionReuse: NodeInsertionReuse? = nil
    ) -> UpdateKind {
        let sameProvider = provider != nil && cachedProvider === provider
        let unchangedNodes = sameProvider && nodeVersion != nil
            && cachedNodeVersion == nodeVersion && nodes.count == nodeIDs.count
        let certifiedAppend = sameProvider && nodeAppendGeneration != nil
            && cachedAppendGeneration == nodeAppendGeneration && nodes.count >= nodeIDs.count
        let unchangedEdges = sameProvider && edgeVersion != nil
            && cachedEdgeVersion == edgeVersion && edges.count == edgeKeys.count
        if sameProvider, let fromVersion = cachedNodeVersion, let toVersion = nodeVersion,
           let reuse = nodeInsertionReuse,
           reuse.matches(fromVersion: fromVersion, oldCount: nodeIDs.count,
                         toVersion: toVersion, newCount: nodes.count),
           nodeIndices.count == nodeIDs.count {
            // Existing duplicates can retain a historical resolved winner. New
            // duplicates can leave the UUID prefix unchanged even
            // when retained ranges shift. Preserve the legacy append/rebuild
            // classification and its already-resolved endpoint policy.
            var insertedIDs: [Int: UUID] = [:]
            var insertedSet: Set<UUID> = []
            var duplicateInserted = false
            for range in reuse.insertedRanges {
                for index in range {
                    let id = nodes[index].id
                    nodeMetadataReadCount += 1
                    insertedIDs[index] = id
                    if nodeIndices[id] != nil || !insertedSet.insert(id).inserted {
                        duplicateInserted = true
                    }
                }
            }
            if !duplicateInserted {
                let oldEdgeCount = edgeKeys.count
                let keepsEdges = edges.count >= oldEdgeCount && (unchangedEdges || edgeKeys.indices.allSatisfy {
                    edgePrefixComparisonCount += 1
                    return edgeKeys[$0] == EdgeKey(edges[$0])
                })
                nodeIDs = reuse.remap(nodeIDs) { insertedIDs[$0]! }!
                nodeIndices = nodeIndices.mapValues { Int32(reuse.newIndex(forOldIndex: Int($0))!) }
                for (index, id) in insertedIDs { nodeIndices[id] = Int32(index) }
                if keepsEdges {
                    unresolvedEdges.removeAll(keepingCapacity: true)
                    for index in edgeKeys.indices {
                        let key = edgeKeys[index]
                        sourceIndices[index] = sourceIndices[index] < 0
                            ? nodeIndices[key.source] ?? -1
                            : Int32(reuse.newIndex(forOldIndex: Int(sourceIndices[index]))!)
                        targetIndices[index] = targetIndices[index] < 0
                            ? nodeIndices[key.target] ?? -1
                            : Int32(reuse.newIndex(forOldIndex: Int(targetIndices[index]))!)
                        if sourceIndices[index] < 0 || targetIndices[index] < 0 { unresolvedEdges.append(index) }
                    }
                } else {
                    edgeKeys.removeAll(keepingCapacity: true)
                    unresolvedEdges.removeAll(keepingCapacity: true)
                    sourceIndices.removeAll(keepingCapacity: true)
                    targetIndices.removeAll(keepingCapacity: true)
                }
                appendEdges(edges)
                cachedProvider = provider
                cachedNodeVersion = nodeVersion
                cachedEdgeVersion = edgeVersion
                cachedAppendGeneration = nodeAppendGeneration
                if !keepsEdges { return .rebuilt }
                return reuse.oldCount == reuse.newCount && edges.count == oldEdgeCount ? .unchanged : .appended
            }
        }
        let providerChanged = provider != nil && !sameProvider
        let keepsPrefix = !providerChanged && nodes.count >= nodeIDs.count && edges.count >= edgeKeys.count
            && (unchangedNodes || certifiedAppend || nodeIDs.indices.allSatisfy {
                nodePrefixComparisonCount += 1
                return nodeIDs[$0] == nodes[$0].id
            })
            && (unchangedEdges || edgeKeys.indices.allSatisfy {
                edgePrefixComparisonCount += 1
                return edgeKeys[$0] == EdgeKey(edges[$0])
            })
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
            nodeMetadataReadCount += 1
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

        appendEdges(edges)
        cachedProvider = provider
        cachedNodeVersion = nodeVersion
        cachedEdgeVersion = edgeVersion
        cachedAppendGeneration = nodeAppendGeneration
        if !keepsPrefix { return .rebuilt }
        return nodes.count == oldNodeCount && edges.count == oldEdgeCount ? .unchanged : .appended
    }

    private mutating func appendEdges(_ edges: [RKEdgeSnapshot]) {
        for index in edgeKeys.count..<edges.count {
            let key = EdgeKey(edges[index])
            edgeKeys.append(key)
            let source = nodeIndices[key.source] ?? -1
            let target = nodeIndices[key.target] ?? -1
            sourceIndices.append(source)
            targetIndices.append(target)
            if source < 0 || target < 0 { unresolvedEdges.append(index) }
        }
    }

    /// The legacy value-only entry point remains available to conservative
    /// callers. Only a same-provider snapshot may supply insertion continuity.
    @MainActor
    @discardableResult
    mutating func update(
        nodes: [RKNodeSnapshot], edges: [RKEdgeSnapshot], dataProvider: SceneDataProvider,
        nodeVersion: UInt64?, edgeVersion: UInt64?, nodeAppendGeneration: UInt64?
    ) -> UpdateKind {
        let reuse = cachedProvider === dataProvider ? cachedNodeVersion.flatMap {
            dataProvider.nodeInsertionReuse(since: $0, count: nodeIDs.count)
        } : nil
        return update(nodes: nodes, edges: edges, provider: dataProvider, nodeVersion: nodeVersion,
                      edgeVersion: edgeVersion, nodeAppendGeneration: nodeAppendGeneration,
                      nodeInsertionReuse: reuse)
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
