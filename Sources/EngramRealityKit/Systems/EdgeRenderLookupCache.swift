import Foundation

/// Resolves renderer metadata independently of moving positions and appearance.
/// Keep compact per-edge entries, not provider snapshots that would force copies
/// on the next graph append. Every metadata revision remains conservative.
struct EdgeRenderLookupCache {
    enum Change: Equatable { case unchanged, metadata, provider }

    struct Lookup {
        let sourceIndex: Int?
        let targetIndex: Int?
        let sourceProject: String?

        func positions(for edge: RKEdgeSnapshot, array: [SIMD3<Float>],
                       fallback: [UUID: SIMD3<Float>]) -> (source: SIMD3<Float>, target: SIMD3<Float>)? {
            if let sourceIndex, sourceIndex < array.count,
               let targetIndex, targetIndex < array.count {
                return (array[sourceIndex], array[targetIndex])
            }
            // The renderer uses the map for BOTH endpoints if either flat
            // endpoint is unavailable. In particular, a valid zero is not missing.
            guard let source = fallback[edge.sourceId], let target = fallback[edge.targetId] else { return nil }
            return (source, target)
        }
    }

    private struct Revision: Equatable {
        let topology: UInt64
        let nodes: UInt64
        let edges: UInt64
        let nodeCount: Int
        let edgeCount: Int
    }
    private struct Entry {
        var generation: UInt64 = 0
        var lookup = Lookup(sourceIndex: nil, targetIndex: nil, sourceProject: nil)
    }

    private weak var provider: AnyObject?
    private var revision: Revision?
    private var nodeLookup = EdgeNodeLookupCache()
    private var generation: UInt64 = 0
    private var entries: [Entry] = []
    private(set) var resolutionCount = 0

    @discardableResult
    mutating func prepare(provider: AnyObject, topology: UInt64, nodeVersion: UInt64,
                          edgeVersion: UInt64, nodes: [RKNodeSnapshot], edgeCount: Int) -> Change {
        let providerChanged = self.provider !== provider
        let next = Revision(topology: topology, nodes: nodeVersion, edges: edgeVersion,
                            nodeCount: nodes.count, edgeCount: edgeCount)
        guard providerChanged || next != revision else { return .unchanged }
        if providerChanged { nodeLookup = EdgeNodeLookupCache() }
        nodeLookup.update(nodes: nodes)
        generation &+= 1
        if generation == 0 {
            generation = 1
            entries.removeAll(keepingCapacity: true)
        }
        if edgeCount > entries.count {
            entries.append(contentsOf: repeatElement(Entry(), count: edgeCount - entries.count))
        } else if edgeCount < entries.count {
            entries.removeLast(entries.count - edgeCount)
        }
        self.provider = provider
        revision = next
        return providerChanged ? .provider : .metadata
    }

    mutating func lookup(at index: Int, edge: RKEdgeSnapshot) -> Lookup {
        if entries[index].generation != generation {
            // Use the renderer's latest duplicate winner, including after a
            // duplicate node append; the LOD endpoint cache has different reuse rules.
            entries[index] = Entry(generation: generation, lookup: Lookup(
                sourceIndex: nodeLookup.indices[edge.sourceId],
                targetIndex: nodeLookup.indices[edge.targetId],
                sourceProject: nodeLookup.projects[edge.sourceId]))
            resolutionCount += 1
        }
        return entries[index].lookup
    }
}
