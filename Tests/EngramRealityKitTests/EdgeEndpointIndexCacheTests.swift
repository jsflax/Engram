import Foundation
import EngramSceneKit
import Testing
@testable import EngramRealityKit

struct EdgeEndpointIndexCacheTests {

    @Test("Certified interior edge insertions reuse retained endpoints and repair later missing nodes")
    func certifiedEdgeInsertionsAvoidHistoricalReads() {
        let owner = NSObject(), a = node(), b = node(), c = node(), late = node()
        let nodes = [a, b, c]
        let old = (0..<2048).map { index in
            edge(nodes[index % 3], index % 17 == 0 ? late : nodes[(index + 1) % 3])
        }
        // A new row may share an edge ID while having different endpoints;
        // the proof retains the old row, not a global edge-ID dictionary.
        let inserted = [edge(c, a, id: old[0].id), edge(late, b), edge(b, a), edge(a, c)]
        let next = [inserted[0]] + Array(old.prefix(1000))
            + [inserted[1], inserted[2]] + Array(old.dropFirst(1000)) + [inserted[3]]
        let proof = EdgeInsertionReuse(fromVersion: 1, toVersion: 4,
            oldCount: old.count, newCount: next.count, retainedRanges: [
                .init(oldRange: 0..<1000, newStart: 1),
                .init(oldRange: 1000..<old.count, newStart: 1003),
            ])!
        var actual = EdgeEndpointIndexCache(), reference = EdgeEndpointIndexCache()
        actual.update(nodes: nodes, edges: old, provider: owner,
            nodeVersion: 1, edgeVersion: 1, nodeAppendGeneration: 1, edgeAppendGeneration: 1)
        reference.update(nodes: nodes, edges: old)
        let oldSources = actual.sourceIndices, oldTargets = actual.targetIndices
        let nodeReads = actual.nodeMetadataReadCount, edgeReads = actual.edgeMetadataReadCount
        let result = actual.update(nodes: nodes, edges: next, provider: owner,
            nodeVersion: 1, edgeVersion: 4, nodeAppendGeneration: 1,
            edgeAppendGeneration: 2, edgeInsertionReuse: proof)
        reference.update(nodes: nodes, edges: next)
        #expect(result == .appended)
        #expect(actual.sourceIndices == reference.sourceIndices)
        #expect(actual.targetIndices == reference.targetIndices)
        #expect(actual.nodeMetadataReadCount == nodeReads)
        #expect(actual.edgeMetadataReadCount - edgeReads == inserted.count)
        #expect(actual.nodePrefixComparisonCount == 0 && actual.edgePrefixComparisonCount == 0)
        #expect(Array(actual.sourceIndices[1..<1001]) == Array(oldSources.prefix(1000)))
        #expect(Array(actual.targetIndices[1003..<2051]) == Array(oldTargets.dropFirst(1000)))
        // Retained result arrays remain value snapshots after the remap.
        #expect(oldSources.count == old.count && oldTargets[0] == -1)
        actual.update(nodes: nodes + [late], edges: next, provider: owner,
            nodeVersion: 2, edgeVersion: 4, nodeAppendGeneration: 1, edgeAppendGeneration: 2)
        reference.update(nodes: nodes + [late], edges: next)
        #expect(actual.sourceIndices == reference.sourceIndices)
        #expect(actual.targetIndices == reference.targetIndices)
        #expect(actual.sourceIndices[1001] == 3 && actual.targetIndices[1] == 3)
        #expect(oldTargets[0] == -1)
    }

    @Test("Invalid or unavailable edge insertion continuity keeps conservative endpoint behavior")
    func edgeInsertionFallbacksMatchConservativeIndexing() {
        let a = node(), b = node(), c = node()
        for mode in 0..<10 {
            var owner: NSObject? = NSObject()
            let replacement = NSObject()
            let original = [edge(a, b), edge(b, c)]
            var nextNodes = [a, b, c]
            var next = [edge(c, a)] + original
            var nodeRevision: UInt64 = 1
            if mode == 5 { nextNodes.swapAt(0, 2); nodeRevision = 2 }
            if mode == 6 { nextNodes.append(node()); nodeRevision = 2 }
            if mode == 7 { next = [original[1]] } // deletion
            if mode == 8 { next = [original[1], original[0]] } // reorder
            let proof = EdgeInsertionReuse(fromVersion: mode == 1 ? 2 : 1,
                toVersion: mode == 2 ? 5 : 4, oldCount: 2,
                newCount: mode == 3 ? 4 : 3,
                retainedRanges: [.init(oldRange: 0..<2, newStart: 1)])
            var actual = EdgeEndpointIndexCache(), reference = EdgeEndpointIndexCache()
            actual.update(nodes: [a, b, c], edges: original, provider: owner,
                nodeVersion: 1, edgeVersion: 1, nodeAppendGeneration: 1, edgeAppendGeneration: 1)
            reference.update(nodes: [a, b, c], edges: original)
            if mode == 9 { owner = nil } // A proof cannot retain its provider.
            actual.update(nodes: nextNodes, edges: next,
                provider: mode == 0 || mode == 9 ? replacement : owner,
                nodeVersion: nodeRevision, edgeVersion: 4, nodeAppendGeneration: nodeRevision,
                edgeAppendGeneration: 2, edgeInsertionReuse: mode == 4 ? nil : proof)
            reference.update(nodes: nextNodes, edges: next)
            #expect(actual.sourceIndices == reference.sourceIndices)
            #expect(actual.targetIndices == reference.targetIndices)
        }
        // Structurally invalid proofs are rejected before reaching a consumer.
        #expect(EdgeInsertionReuse(fromVersion: 1, toVersion: 2, oldCount: 2,
            newCount: 3, retainedRanges: []) == nil)
        // Empty and true-tail proofs retain the existing append/no-op path.
        let owner = NSObject()
        var empty = EdgeEndpointIndexCache()
        empty.update(nodes: [a, b], edges: [], provider: owner, nodeVersion: 1, edgeVersion: 1)
        let zero = EdgeInsertionReuse(fromVersion: 1, toVersion: 2,
            oldCount: 0, newCount: 0, retainedRanges: [])!
        let unchanged = empty.update(nodes: [a, b], edges: [], provider: owner,
            nodeVersion: 1, edgeVersion: 2, edgeInsertionReuse: zero)
        #expect(unchanged == .unchanged)
        let tail = EdgeInsertionReuse(fromVersion: 2, toVersion: 3,
            oldCount: 0, newCount: 1, retainedRanges: [])!
        let appended = empty.update(nodes: [a, b], edges: [edge(a, b)], provider: owner,
            nodeVersion: 1, edgeVersion: 3, edgeInsertionReuse: tail)
        #expect(appended == .appended)
        #expect(empty.sourceIndices == [0] && empty.targetIndices == [1])
    }

    @Test("Interior edge insertion retains conservative duplicate-node winner semantics")
    func edgeInsertionWithDuplicateNodeHistoryFallsBack() {
        let owner = NSObject(), a = node(), b = node(), duplicate = node(id: a.id)
        let first = edge(a, b), second = edge(b, a), inserted = edge(a, a)
        var actual = EdgeEndpointIndexCache(), reference = EdgeEndpointIndexCache()
        for (version, nodes, edges) in [
            (UInt64(1), [a, b], [first]),
            (UInt64(2), [a, b, duplicate], [first, second]),
        ] {
            actual.update(nodes: nodes, edges: edges, provider: owner,
                nodeVersion: version, edgeVersion: version, nodeAppendGeneration: 1, edgeAppendGeneration: 1)
            reference.update(nodes: nodes, edges: edges)
        }
        #expect(actual.sourceIndices == [0, 1])
        let proof = EdgeInsertionReuse(fromVersion: 2, toVersion: 3,
            oldCount: 2, newCount: 3, retainedRanges: [.init(oldRange: 0..<2, newStart: 1)])!
        let result = actual.update(nodes: [a, b, duplicate], edges: [inserted, first, second], provider: owner,
            nodeVersion: 2, edgeVersion: 3, nodeAppendGeneration: 1,
            edgeAppendGeneration: 2, edgeInsertionReuse: proof)
        reference.update(nodes: [a, b, duplicate], edges: [inserted, first, second])
        #expect(result == .rebuilt)
        #expect(actual.sourceIndices == [2, 2, 1] && actual.targetIndices == [2, 1, 2])
        #expect(actual.sourceIndices == reference.sourceIndices)
        #expect(actual.targetIndices == reference.targetIndices)
    }
    @Test("Certified edge tails read only new rows across skipped revisions and node insertion")
    func certifiedEdgeTailsAvoidHistoricalReads() {
        let owner = NSObject(), a = node(), b = node(), c = node()
        let first = edge(a, b), second = edge(b, a), third = edge(a, c)
        var cache = EdgeEndpointIndexCache()
        cache.update(nodes: [a, b], edges: [first], provider: owner,
            nodeVersion: 1, edgeVersion: 1, nodeAppendGeneration: 1, edgeAppendGeneration: 1)
        let reads = cache.edgeMetadataReadCount
        cache.update(nodes: [a, b, c], edges: [first, second, third], provider: owner,
            nodeVersion: 3, edgeVersion: 4, nodeAppendGeneration: 1, edgeAppendGeneration: 1)
        #expect(cache.edgeMetadataReadCount - reads == 2)
        #expect(cache.edgePrefixComparisonCount == 0)
        #expect(cache.sourceIndices == [0, 1, 0] && cache.targetIndices == [1, 0, 2])
        let d = node(), fourth = edge(d, a)
        let reuse = NodeInsertionReuse(fromVersion: 3, toVersion: 4, oldCount: 3, newCount: 4,
            retainedRanges: [.init(oldRange: 0..<3, newStart: 1)])!
        cache.update(nodes: [d, a, b, c], edges: [first, second, third, fourth], provider: owner,
            nodeVersion: 4, edgeVersion: 5, nodeAppendGeneration: 2,
            nodeInsertionReuse: reuse, edgeAppendGeneration: 1)
        #expect(cache.edgeMetadataReadCount - reads == 3)
        #expect(cache.edgePrefixComparisonCount == 0)
        #expect(cache.sourceIndices == [1, 2, 1, 0] && cache.targetIndices == [2, 1, 3, 1])
    }

    @Test("Edge continuity requires the same live provider and nonshrinking unchanged generation")
    func edgeTailFallbacksMatchConservativeIndexing() {
        let a = node(), b = node(), c = node(), first = edge(a, b), extra = edge(b, c)
        for mode in 0..<5 {
            var owner: NSObject? = NSObject()
            let replacement = NSObject()
            var cache = EdgeEndpointIndexCache(), reference = EdgeEndpointIndexCache()
            cache.update(nodes: [a, b, c], edges: [first, extra], provider: owner,
                nodeVersion: 1, edgeVersion: 1, nodeAppendGeneration: 1, edgeAppendGeneration: 1)
            let next = mode == 2 ? [edge(c, a, id: first.id)]
                : [edge(c, a, id: first.id), extra, edge(a, c)]
            if mode == 4 { owner = nil } // The cache must not retain its origin.
            cache.update(nodes: [a, b, c], edges: next,
                provider: mode == 1 || mode == 4 ? replacement : owner,
                nodeVersion: 1, edgeVersion: 2, nodeAppendGeneration: 1,
                edgeAppendGeneration: mode == 0 ? 2 : mode == 3 ? nil : 1)
            reference.update(nodes: [a, b, c], edges: next)
            #expect(cache.sourceIndices == reference.sourceIndices)
            #expect(cache.targetIndices == reference.targetIndices)
        }
    }

    @Test
    func revisionDomainsPreserveLateEndpointsAndSkipUnchangedPrefixes() {
        let owner = NSObject()
        var cache = EdgeEndpointIndexCache()
        let a = node(), b = node(), c = node()
        let late = edge(a, c)
        cache.update(nodes: [a], edges: [late], provider: owner,
                     nodeVersion: 1, edgeVersion: 1, nodeAppendGeneration: 1)
        #expect(cache.targetIndices == [-1])
        cache.update(nodes: [a, b], edges: [late], provider: owner,
                     nodeVersion: 2, edgeVersion: 1, nodeAppendGeneration: 1)
        cache.update(nodes: [a, b, c], edges: [late], provider: owner,
                     nodeVersion: 4, edgeVersion: 1, nodeAppendGeneration: 1)
        #expect(cache.sourceIndices == [0])
        #expect(cache.targetIndices == [2])
        #expect(cache.nodePrefixComparisonCount == 0)
        #expect(cache.edgePrefixComparisonCount == 0)
        let edges = [late, edge(b, c)]
        cache.update(nodes: [a, b, c], edges: edges, provider: owner,
                     nodeVersion: 4, edgeVersion: 2, nodeAppendGeneration: 1)
        #expect(cache.sourceIndices == [0, 1])
        #expect(cache.targetIndices == [2, 2])
        #expect(cache.nodePrefixComparisonCount == 0)
        #expect(cache.edgePrefixComparisonCount == 1)
        for _ in 0..<100 {
            cache.update(nodes: [a, b, c], edges: edges, provider: owner,
                         nodeVersion: 4, edgeVersion: 2, nodeAppendGeneration: 1)
        }
        #expect(cache.edgePrefixComparisonCount == 1)
        #expect(cache.targetIndices == [2, 2])
    }

    @Test
    func revisionFallbacksMatchConservativeEndpointResults() {
        let owner = NSObject(), replacement = NSObject()
        let a = node(), b = node(), c = node(), d = node()
        let ab = edge(a, b), bc = edge(b, c)
        let cases: [([RKNodeSnapshot], [RKEdgeSnapshot])] = [
            ([a, b], [ab]),
            ([c, b, a], [ab, bc]), // prefix edit during growth
            ([a, b, c], [edge(c, b, id: ab.id), bc]), // same-count reorder/endpoint edit
            ([b], [ab]), // shrink/deletion leaves a missing endpoint
            ([b, d], [edge(d, b, id: ab.id)]),
            ([], []),
        ]
        var actual = EdgeEndpointIndexCache(), reference = EdgeEndpointIndexCache()
        for (offset, pair) in cases.enumerated() {
            let revision = UInt64(offset + 1)
            reference.update(nodes: pair.0, edges: pair.1)
            actual.update(nodes: pair.0, edges: pair.1, provider: owner,
                          nodeVersion: revision, edgeVersion: revision, nodeAppendGeneration: revision)
            #expect(actual.sourceIndices == reference.sourceIndices)
            #expect(actual.targetIndices == reference.targetIndices)
        }
        actual.update(nodes: [a, b], edges: [ab], provider: owner,
                      nodeVersion: 10, edgeVersion: 10, nodeAppendGeneration: 10)
        actual.update(nodes: [b, a], edges: [ab], provider: replacement,
                      nodeVersion: 10, edgeVersion: 10, nodeAppendGeneration: 10)
        #expect(actual.sourceIndices == [1])
        #expect(actual.targetIndices == [0])
    }

    @Test
    func duplicateAppendPreservesExistingEndpointPolicy() {
        let owner = NSObject()
        var actual = EdgeEndpointIndexCache(), reference = EdgeEndpointIndexCache()
        let a = node(), b = node(), duplicate = node(id: a.id, project: "copy")
        let first = edge(a, b), second = edge(b, duplicate)
        reference.update(nodes: [a, b], edges: [first])
        actual.update(nodes: [a, b], edges: [first], provider: owner,
                      nodeVersion: 1, edgeVersion: 1, nodeAppendGeneration: 1)
        reference.update(nodes: [a, b, duplicate], edges: [first, second])
        actual.update(nodes: [a, b, duplicate], edges: [first, second], provider: owner,
                      nodeVersion: 2, edgeVersion: 2, nodeAppendGeneration: 1)
        // Existing resolved edges retain their index; newly indexed endpoints
        // use the last duplicate, exactly as the conservative append path does.
        #expect(actual.sourceIndices == [0, 1])
        #expect(actual.targetIndices == [1, 2])
        #expect(actual.sourceIndices == reference.sourceIndices)
        #expect(actual.targetIndices == reference.targetIndices)
        reference.update(nodes: [a, duplicate, b], edges: [first, second])
        actual.update(nodes: [a, duplicate, b], edges: [first, second], provider: owner,
                      nodeVersion: 3, edgeVersion: 2, nodeAppendGeneration: 2)
        #expect(actual.sourceIndices == reference.sourceIndices)
        #expect(actual.targetIndices == reference.targetIndices)
        #expect(actual.sourceIndices == [1, 2])
        #expect(actual.targetIndices == [2, 1])
    }

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
    @Test("Insertion certificates rebase resolved endpoints, repair missing nodes and retain duplicate last wins")
    func insertionEndpointsMatchFullRebuild() {
        let a = node(), b = node(), late = node(), x = node()
        let links = [edge(a, b), edge(late, a)]
        for duplicates in [false, true] {
            let owner = NSObject()
            let old = duplicates ? [a, b, a] : [a, b]
            let next = duplicates ? [a, a, late, b, a, a] : [x, a, late, b]
            let reuse = NodeInsertionReuse(fromVersion: 1, toVersion: 2, oldCount: old.count, newCount: next.count,
                retainedRanges: [.init(oldRange: 0..<1, newStart: 1), .init(oldRange: 1..<old.count, newStart: 3)])
            var cache = EdgeEndpointIndexCache(), reference = EdgeEndpointIndexCache()
            cache.update(nodes: old, edges: links, provider: owner, nodeVersion: 1, edgeVersion: 1, nodeAppendGeneration: 1)
            let reads = cache.nodeMetadataReadCount
            cache.update(nodes: next, edges: links, provider: owner, nodeVersion: 2, edgeVersion: 1,
                         nodeAppendGeneration: 2, nodeInsertionReuse: reuse)
            reference.update(nodes: next, edges: links)
            #expect(cache.sourceIndices == reference.sourceIndices)
            #expect(cache.targetIndices == reference.targetIndices)
            #expect(cache.sourceIndices == [duplicates ? 5 : 1, 2])
            #expect(cache.targetIndices == [3, duplicates ? 5 : 1])
            if !duplicates {
                #expect(cache.nodeMetadataReadCount - reads == next.count - old.count)
                #expect(cache.nodePrefixComparisonCount == 0 && cache.edgePrefixComparisonCount == 0)
            }
        }
    }

    @Test("Insertion endpoints fall back on stale certificates, replacement, removal and edge edits")
    func insertionEndpointFallbacksMatchFullRebuild() {
        let a = node(), b = node(), c = node(), original = edge(a, b)
        for mode in 0..<5 {
            let owner = NSObject(), replacement = NSObject()
            var cache = EdgeEndpointIndexCache(), reference = EdgeEndpointIndexCache()
            cache.update(nodes: [a, b], edges: [original], provider: owner,
                         nodeVersion: 1, edgeVersion: 1, nodeAppendGeneration: 1)
            let next = mode == 3 ? [b] : mode == 2 ? [a, b, c] : [c, a, b]
            let links = mode == 2 ? [edge(c, a, id: original.id)] : [original]
            let reuse = NodeInsertionReuse(fromVersion: mode == 0 || mode == 4 ? 2 : 1, toVersion: 3,
                oldCount: 2, newCount: 3,
                retainedRanges: [.init(oldRange: 0..<2, newStart: mode == 2 ? 0 : 1)])
            cache.update(nodes: next, edges: links, provider: mode == 1 ? replacement : owner,
                         nodeVersion: 3, edgeVersion: mode == 2 ? 2 : 1, nodeAppendGeneration: 3,
                         nodeInsertionReuse: mode == 4 ? nil : reuse)
            reference.update(nodes: next, edges: links)
            #expect(cache.sourceIndices == reference.sourceIndices)
            #expect(cache.targetIndices == reference.targetIndices)
        }
    }


    @Test("Duplicate insertions preserve conservative resolved and unresolved endpoint policy")
    func insertionDuplicateCompatibility() {
        let a = node(), b = node(), late = node(), x = node()
        let links = [edge(a, b), edge(a, late), edge(a, a)]
        let cases: [([RKNodeSnapshot], [RKNodeSnapshot], [NodeInsertionReuse.RetainedRange], UInt64)] = [
            ([a, b], [a, b, a, late], [.init(oldRange: 0..<2, newStart: 0)], 1),
            ([a, b], [a, b, a, late], [.init(oldRange: 0..<2, newStart: 0)], 2),
            ([a, a], [a, a, a], [.init(oldRange: 0..<2, newStart: 1)], 2),
            ([a, b], [a, a, b, late], [.init(oldRange: 0..<2, newStart: 1)], 2),
            ([a, b, a], [a, a, b, a, late], [.init(oldRange: 0..<3, newStart: 1)], 2),
            ([a, b], [x, x, a, b], [.init(oldRange: 0..<2, newStart: 2)], 2),
        ]
        for (old, next, ranges, generation) in cases {
            let owner = NSObject()
            var cache = EdgeEndpointIndexCache(), reference = EdgeEndpointIndexCache()
            cache.update(nodes: old, edges: links, provider: owner,
                         nodeVersion: 1, edgeVersion: 1, nodeAppendGeneration: 1)
            reference.update(nodes: old, edges: links, provider: owner,
                             nodeVersion: 1, edgeVersion: 1, nodeAppendGeneration: 1)
            let reuse = NodeInsertionReuse(fromVersion: 1, toVersion: 2,
                oldCount: old.count, newCount: next.count, retainedRanges: ranges)!
            let nextLinks = links + [edge(a, b)]
            let result = cache.update(nodes: next, edges: nextLinks, provider: owner,
                nodeVersion: 2, edgeVersion: 2, nodeAppendGeneration: generation, nodeInsertionReuse: reuse)
            let expected = reference.update(nodes: next, edges: nextLinks, provider: owner,
                nodeVersion: 2, edgeVersion: 2, nodeAppendGeneration: generation)
            #expect(result == expected)
            #expect(cache.sourceIndices == reference.sourceIndices)
            #expect(cache.targetIndices == reference.targetIndices)
        }
        // A prior duplicate tail append leaves a resolved winner older than
        // the lookup winner. A later unique interior insertion must rebuild it.
        let owner = NSObject()
        var cache = EdgeEndpointIndexCache(), reference = EdgeEndpointIndexCache()
        let retained = [edge(a, b)]
        for (version, nodes) in [[a, b], [a, b, a]].enumerated() {
            cache.update(nodes: nodes, edges: retained, provider: owner,
                nodeVersion: UInt64(version + 1), edgeVersion: 1, nodeAppendGeneration: 1)
            reference.update(nodes: nodes, edges: retained, provider: owner,
                nodeVersion: UInt64(version + 1), edgeVersion: 1, nodeAppendGeneration: 1)
        }
        #expect(cache.sourceIndices == [0])
        let reuse = NodeInsertionReuse(fromVersion: 2, toVersion: 3,
            oldCount: 3, newCount: 4, retainedRanges: [.init(oldRange: 0..<3, newStart: 1)])!
        let result = cache.update(nodes: [x, a, b, a], edges: retained, provider: owner,
            nodeVersion: 3, edgeVersion: 1, nodeAppendGeneration: 2, nodeInsertionReuse: reuse)
        let expected = reference.update(nodes: [x, a, b, a], edges: retained, provider: owner,
            nodeVersion: 3, edgeVersion: 1, nodeAppendGeneration: 2)
        #expect(result == expected && result == .rebuilt)
        #expect(cache.sourceIndices == reference.sourceIndices && cache.sourceIndices == [3])
        #expect(cache.targetIndices == reference.targetIndices)

    }

    @Test("No visible node or edge growth retains the unchanged update kind")
    func insertionWithoutGrowthIsUnchanged() {
        let a = node(), b = node()
        for nodes in [[], [a, b]] {
            let owner = NSObject(), links = [edge(a, b)]
            var cache = EdgeEndpointIndexCache()
            cache.update(nodes: nodes, edges: links, provider: owner,
                         nodeVersion: 1, edgeVersion: 1, nodeAppendGeneration: 1)
            let source = cache.sourceIndices, target = cache.targetIndices
            let reuse = NodeInsertionReuse(fromVersion: 1, toVersion: 2,
                oldCount: nodes.count, newCount: nodes.count,
                retainedRanges: nodes.isEmpty ? [] : [.init(oldRange: 0..<nodes.count, newStart: 0)])!
            let result = cache.update(nodes: nodes, edges: links, provider: owner,
                nodeVersion: 2, edgeVersion: 1, nodeAppendGeneration: 1, nodeInsertionReuse: reuse)
            #expect(result == .unchanged)
            #expect(cache.sourceIndices == source && cache.targetIndices == target)
        }
    }

}
