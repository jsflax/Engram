import Foundation
import Testing
@testable import EngramRealityKit

struct EdgeRenderLookupCacheTests {
    private func node(id: UUID = UUID(), project: String = "project") -> RKNodeSnapshot {
        RKNodeSnapshot(id: id, project: project, topic: "topic", label: "node", importance: 1, isHub: false)
    }

    private func edge(_ source: RKNodeSnapshot, _ target: RKNodeSnapshot, id: UUID = UUID()) -> RKEdgeSnapshot {
        RKEdgeSnapshot(id: id, sourceId: source.id, targetId: target.id, relation: "related")
    }

    @Test("Moving positions stay fresh without repeating endpoint/project resolution")
    func movingPositionsReuseOnlyMetadata() {
        let owner = NSObject(), a = node(project: "a"), b = node(project: "b"), c = node()
        let edges = [edge(a, b), edge(b, c), edge(c, a)]
        var cache = EdgeRenderLookupCache()
        for frame in 0..<32 {
            let change = cache.prepare(provider: owner, topology: 1, nodeVersion: 1,
                edgeVersion: 1, nodes: [a, b, c], edgeCount: edges.count)
            #expect(change == (frame == 0 ? .provider : .unchanged))
            let positions = [SIMD3<Float>(Float(frame), 1, 2), SIMD3<Float>(3, Float(frame), 4), .zero]
            for index in 0..<2 {
                let lookup = cache.lookup(at: index, edge: edges[index])
                let resolved = lookup.positions(for: edges[index], array: positions, fallback: [:])
                #expect(resolved?.source == positions[index])
                #expect(resolved?.target == positions[index + 1])
                #expect(lookup.sourceProject == (index == 0 ? "a" : "b"))
            }
        }
        #expect(cache.resolutionCount == 2) // The never-visible third edge remains unresolved.
    }

    @Test("Duplicate appends, project edits, insertion and removal preserve the latest renderer winner")
    func nodeChangesPreserveLatestDuplicate() {
        let owner = NSObject(), a = node(project: "original"), b = node(), c = node()
        let duplicate = node(id: a.id, project: "duplicate"), edited = node(id: a.id, project: "edited")
        let link = edge(a, b)
        let snapshots = [[a, b], [a, b, duplicate], [c, duplicate, b, a], [c, edited, b], [b]]
        let indices: [Int?] = [0, 2, 3, 1, nil]
        let projects: [String?] = ["original", "duplicate", "original", "edited", nil]
        var cache = EdgeRenderLookupCache()
        for index in snapshots.indices {
            cache.prepare(provider: owner, topology: UInt64(index + 1), nodeVersion: UInt64(index + 1),
                edgeVersion: 1, nodes: snapshots[index], edgeCount: 1)
            let lookup = cache.lookup(at: 0, edge: link)
            #expect(lookup.sourceIndex == indices[index])
            #expect(lookup.sourceProject == projects[index])
            #expect(lookup.targetIndex == snapshots[index].lastIndex(where: { $0.id == b.id }))
        }
        #expect(cache.resolutionCount == snapshots.count)
    }

    @Test("Same-ID endpoint edits, reordered rows and removal/recreation invalidate cached lookups")
    func edgeChangesAndRegrowth() {
        let owner = NSObject(), a = node(), b = node(), c = node()
        let first = edge(a, b), second = edge(b, c), edited = edge(c, a, id: first.id)
        var cache = EdgeRenderLookupCache()
        cache.prepare(provider: owner, topology: 1, nodeVersion: 1, edgeVersion: 1,
                      nodes: [a, b, c], edgeCount: 2)
        #expect(cache.lookup(at: 0, edge: first).sourceIndex == 0)
        #expect(cache.lookup(at: 1, edge: second).sourceIndex == 1)
        // An independently advanced edge revision also invalidates metadata.
        cache.prepare(provider: owner, topology: 1, nodeVersion: 1, edgeVersion: 2,
                      nodes: [a, b, c], edgeCount: 2)
        #expect(cache.lookup(at: 0, edge: second).sourceIndex == 1)
        let changed = cache.lookup(at: 1, edge: edited)
        #expect(changed.sourceIndex == 2 && changed.targetIndex == 0)
        cache.prepare(provider: owner, topology: 1, nodeVersion: 1, edgeVersion: 2,
                      nodes: [a, b, c], edgeCount: 0)
        cache.prepare(provider: owner, topology: 1, nodeVersion: 1, edgeVersion: 2,
                      nodes: [a, b, c], edgeCount: 2)
        #expect(cache.lookup(at: 0, edge: first).sourceIndex == 0)
        #expect(cache.lookup(at: 1, edge: second).targetIndex == 2)
        #expect(cache.resolutionCount == 6)
    }

    @Test("Missing endpoints resolve on node arrival and node revisions update projects independently")
    func lateNodeAndProjectRevision() {
        let owner = NSObject(), a = node(), late = node(), link = edge(a, late)
        var cache = EdgeRenderLookupCache()
        cache.prepare(provider: owner, topology: 1, nodeVersion: 1, edgeVersion: 1,
                      nodes: [a], edgeCount: 1)
        #expect(cache.lookup(at: 0, edge: link).targetIndex == nil)
        cache.prepare(provider: owner, topology: 1, nodeVersion: 1, edgeVersion: 1,
                      nodes: [a, late], edgeCount: 1)
        #expect(cache.lookup(at: 0, edge: link).targetIndex == 1)
        let edited = node(id: a.id, project: "new project")
        cache.prepare(provider: owner, topology: 1, nodeVersion: 2, edgeVersion: 1,
                      nodes: [edited, late], edgeCount: 1)
        #expect(cache.lookup(at: 0, edge: link).sourceProject == "new project")
        #expect(cache.resolutionCount == 3)
    }

    @Test("Cache does not retain its provider and replacement ignores equal revisions and counts")
    func providerReplacement() {
        var owner: NSObject? = NSObject()
        weak var weakOwner = owner
        let replacement = NSObject(), a = node(project: "a"), b = node(project: "b"), link = edge(a, b)
        var cache = EdgeRenderLookupCache()
        cache.prepare(provider: owner!, topology: 1, nodeVersion: 1, edgeVersion: 1,
                      nodes: [a, b], edgeCount: 1)
        #expect(cache.lookup(at: 0, edge: link).sourceIndex == 0)
        owner = nil
        #expect(weakOwner == nil)
        let change = cache.prepare(provider: replacement, topology: 1, nodeVersion: 1, edgeVersion: 1,
                                   nodes: [b, a], edgeCount: 1)
        #expect(change == .provider)
        let lookup = cache.lookup(at: 0, edge: link)
        #expect(lookup.sourceIndex == 1 && lookup.targetIndex == 0 && lookup.sourceProject == "a")
    }

    @Test("Position fallback uses both dictionary endpoints and preserves valid flat zero")
    func allOrNothingPositionFallback() {
        let owner = NSObject(), a = node(), b = node(), link = edge(a, b)
        var cache = EdgeRenderLookupCache()
        cache.prepare(provider: owner, topology: 1, nodeVersion: 1, edgeVersion: 1,
                      nodes: [a, b], edgeCount: 1)
        let lookup = cache.lookup(at: 0, edge: link)
        let mappedA = SIMD3<Float>(9, 8, 7), mappedB = SIMD3<Float>(6, 5, 4)
        let fallback = [a.id: mappedA, b.id: mappedB]
        let flat = lookup.positions(for: link, array: [.zero, SIMD3(1, 2, 3)], fallback: fallback)
        #expect(flat?.source == .zero && flat?.target == SIMD3(1, 2, 3))
        let partial = lookup.positions(for: link, array: [.zero], fallback: fallback)
        #expect(partial?.source == mappedA && partial?.target == mappedB)
        #expect(lookup.positions(for: link, array: [.zero], fallback: [b.id: mappedB]) == nil)
        // A missing node can still have a map position; preserve that legacy fallback.
        cache.prepare(provider: owner, topology: 2, nodeVersion: 2, edgeVersion: 1,
                      nodes: [a], edgeCount: 1)
        let missing = cache.lookup(at: 0, edge: link).positions(for: link, array: [.zero], fallback: fallback)
        #expect(missing?.source == mappedA && missing?.target == mappedB)
    }
}
