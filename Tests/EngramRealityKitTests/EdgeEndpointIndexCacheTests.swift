import Foundation
import Testing
@testable import EngramRealityKit

struct EdgeEndpointIndexCacheTests {
    private func node(id: UUID = UUID(), project: String = "project") -> RKNodeSnapshot {
        RKNodeSnapshot(id: id, project: project, topic: "topic", label: "label", importance: 1, isHub: false)
    }

    private func edge(_ source: RKNodeSnapshot, _ target: RKNodeSnapshot, id: UUID = UUID()) -> RKEdgeSnapshot {
        RKEdgeSnapshot(id: id, sourceId: source.id, targetId: target.id, relation: "related_to")
    }

    @Test("Verified node and edge prefixes extend existing endpoint indices")
    func appendOnly() {
        var cache = EdgeEndpointIndexCache()
        let nodes = (0..<4).map { _ in node() }
        let edges = [edge(nodes[0], nodes[1]), edge(nodes[1], nodes[2]), edge(nodes[2], nodes[3])]
        cache.update(nodes: Array(nodes.prefix(2)), edges: Array(edges.prefix(1)))
        let result = cache.update(nodes: nodes, edges: edges)
        #expect(result == .appended)
        #expect(cache.sourceIndices == [0, 1, 2])
        #expect(cache.targetIndices == [1, 2, 3])
        let unchanged = cache.update(nodes: nodes, edges: edges)
        #expect(unchanged == .unchanged)
    }

    @Test("Count growth cannot hide replaced or reordered node identities")
    func replacedNodePrefixDuringGrowth() {
        var cache = EdgeEndpointIndexCache()
        let a = node(), b = node(), c = node()
        let first = edge(a, b)
        cache.update(nodes: [a, b], edges: [first])
        let result = cache.update(nodes: [c, b, a], edges: [first, edge(c, a)])
        #expect(result == .rebuilt)
        #expect(cache.sourceIndices == [2, 0])
        #expect(cache.targetIndices == [1, 2])
    }

    @Test("An endpoint edit during growth invalidates the old edge prefix")
    func editedEndpointDuringGrowth() {
        var cache = EdgeEndpointIndexCache()
        let a = node(), b = node(), c = node()
        let original = edge(a, b)
        cache.update(nodes: [a, b], edges: [original])
        let edited = edge(a, c, id: original.id)
        let result = cache.update(nodes: [a, b, c], edges: [edited, edge(b, c)])
        #expect(result == .rebuilt)
        #expect(cache.sourceIndices == [0, 1])
        #expect(cache.targetIndices == [2, 2])
    }

    @Test("Edge identity changes and reorders invalidate even with unchanged counts")
    func replacedAndReorderedEdges() {
        var cache = EdgeEndpointIndexCache()
        let a = node(), b = node(), c = node()
        let first = edge(a, b), second = edge(b, c)
        cache.update(nodes: [a, b, c], edges: [first, second])
        let replacement = edge(a, b)
        let replaced = cache.update(nodes: [a, b, c], edges: [replacement, second])
        #expect(replaced == .rebuilt)
        let reordered = cache.update(nodes: [a, b, c], edges: [second, replacement])
        #expect(reordered == .rebuilt)
        #expect(cache.sourceIndices == [1, 0])
        #expect(cache.targetIndices == [2, 1])
    }

    @Test("Removals discard obsolete indices and missing endpoints can later resolve")
    func removalsAndLateEndpoints() {
        var cache = EdgeEndpointIndexCache()
        let a = node(), b = node(), c = node()
        let first = edge(a, b), second = edge(b, c)
        cache.update(nodes: [a, b, c], edges: [first, second])
        let removed = cache.update(nodes: [a], edges: [first])
        #expect(removed == .rebuilt)
        #expect(cache.sourceIndices == [0])
        #expect(cache.targetIndices == [-1])
        let appended = cache.update(nodes: [a, b], edges: [first])
        #expect(appended == .appended)
        #expect(cache.targetIndices == [1])
        let cleared = cache.update(nodes: [], edges: [])
        #expect(cleared == .rebuilt)
        #expect(cache.sourceIndices.isEmpty)
        #expect(cache.targetIndices.isEmpty)
    }

    @Test("Source-color lookup handles append, replacement, project edits, and removal")
    func nodeLookupChanges() {
        var cache = EdgeNodeLookupCache()
        let a = node(project: "a"), b = node(project: "b"), c = node(project: "c")
        cache.update(nodes: [a])
        cache.update(nodes: [a, b])
        #expect(cache.indices[a.id] == 0)
        #expect(cache.indices[b.id] == 1)
        cache.update(nodes: [c, b, a])
        #expect(cache.indices[c.id] == 0)
        #expect(cache.indices[a.id] == 2)
        let renamed = node(id: b.id, project: "renamed")
        cache.update(nodes: [c, renamed, a])
        #expect(cache.projects[b.id] == "renamed")
        cache.update(nodes: [renamed])
        #expect(cache.indices == [b.id: 0])
        #expect(cache.projects == [b.id: "renamed"])
    }
}
