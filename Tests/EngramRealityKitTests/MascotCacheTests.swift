import Foundation
import Testing
@testable import EngramRealityKit

@Suite("Mascot graph and asynchronous card caches")
@MainActor
struct MascotCacheTests {
    private func node(_ id: UUID = UUID(), project: String) -> RKNodeSnapshot {
        RKNodeSnapshot(id: id, project: project, topic: "topic", label: "Node", importance: 1, isHub: false)
    }

    private func key(_ id: UUID = UUID(), content: String = "Content") -> MascotHoloKey {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return MascotHoloKey(nodeID: id, info: HoloTextureRenderer.NodeInfo(
            content: content, project: "Project", topic: "topic", importance: 1,
            createdAt: date, lastAccessedAt: date))
    }

    private func token(_ action: MascotHoloRequestCache.Action) -> UInt64 {
        guard case .render(let token) = action else {
            Issue.record("Expected a new render request")
            return 0
        }
        return token
    }

    @Test("Patrol groups and first-node lookup match original filtering")
    func projectRouting() {
        let owner = NSObject()
        let id = UUID()
        let nodes = [node(id, project: "A"), node(project: "B"), node(project: "A"), node(id, project: "B")]
        let index = MascotGraphIndex()
        index.update(nodes: nodes, topologyVersion: 1, provider: owner)
        #expect(index.projects == ["A", "B"])
        #expect(index.indicesByProject["A"] == [0, 2])
        #expect(index.indicesByProject["B"] == [1, 3])
        #expect(index.indexByID[id] == 0)
        index.update(nodes: nodes, topologyVersion: 1, provider: owner)
        #expect(index.indicesByProject["A"] == [0, 2])
    }

    @Test("Routing refreshes for same-count changes and provider replacement")
    func routingInvalidation() {
        let owner = NSObject()
        let replacement = NSObject()
        let id = UUID()
        let index = MascotGraphIndex()
        index.update(nodes: [node(id, project: "A")], topologyVersion: 1, provider: owner)
        index.update(nodes: [node(id, project: "B")], topologyVersion: 2, provider: owner)
        #expect(index.projects == ["B"])
        #expect(index.indicesByProject["A"] == nil)
        index.update(nodes: [node(id, project: "C")], topologyVersion: 2, provider: replacement)
        #expect(index.projects == ["C"])
        index.update(nodes: [], topologyVersion: 3, provider: replacement)
        #expect(index.projects.isEmpty)
        #expect(index.indexByID.isEmpty)
    }

    @Test("Identical requests coalesce and only successful cards become visible")
    func requestsCoalesce() {
        let cache = MascotHoloRequestCache()
        let card = key()
        let request = token(cache.request(card, for: "A"))
        for _ in 0..<100 { #expect(cache.request(card, for: "A") == .none) }
        #expect(!cache.isReady(nodeID: card.nodeID, for: "A"))
        #expect(cache.complete(request, for: "A"))
        #expect(cache.isReady(nodeID: card.nodeID, for: "A"))
        #expect(cache.request(card, for: "A") == .none)
    }

    @Test("New targets hide retained old cards and discard stale completions")
    func staleCompletion() {
        let cache = MascotHoloRequestCache()
        let original = key(), next = key(), newest = key()
        #expect(cache.complete(token(cache.request(original, for: "A")), for: "A"))
        let oldRequest = token(cache.request(next, for: "A"))
        #expect(!cache.isReady(nodeID: original.nodeID, for: "A"))
        #expect(!cache.isReady(nodeID: next.nodeID, for: "A"))
        let current = token(cache.request(newest, for: "A"))
        #expect(!cache.complete(oldRequest, for: "A"))
        #expect(cache.complete(current, for: "A"))
        #expect(cache.isReady(nodeID: newest.nodeID, for: "A"))
    }

    @Test("Failed raster/upload retries and same-ID content edits invalidate")
    func failureAndMetadataChange() {
        let cache = MascotHoloRequestCache()
        let card = key()
        let failed = token(cache.request(card, for: "A", now: 100))
        cache.failed(failed, for: "A", now: 100)
        #expect(!cache.isReady(nodeID: card.nodeID, for: "A"))
        #expect(cache.request(card, for: "A", now: 100.5) == .none)
        let retry = token(cache.request(card, for: "A", now: 101))
        #expect(retry != failed)
        #expect(cache.complete(retry, for: "A"))
        let edited = key(card.nodeID, content: "Updated content")
        let replacement = token(cache.request(edited, for: "A"))
        #expect(!cache.isReady(nodeID: card.nodeID, for: "A"))
        #expect(cache.complete(replacement, for: "A"))
        #expect(cache.isReady(nodeID: card.nodeID, for: "A"))
    }

    @Test("Retry cooldown never delays a different node or updated content")
    func newKeyBypassesCooldown() {
        let cache = MascotHoloRequestCache()
        let card = key()
        let failed = token(cache.request(card, for: "A", now: 100))
        cache.failed(failed, for: "A", now: 100)
        let edited = key(card.nodeID, content: "New content")
        let immediate = token(cache.request(edited, for: "A", now: 100.1))
        #expect(immediate != failed)
        #expect(cache.isCurrent(immediate, for: "A"))
    }

    @Test("Returning to a completed card cancels another pending target")
    func completedCardReuse() {
        let cache = MascotHoloRequestCache()
        let original = key(), other = key()
        #expect(cache.complete(token(cache.request(original, for: "A")), for: "A"))
        let pending = token(cache.request(other, for: "A"))
        #expect(cache.request(original, for: "A") == .cancel)
        #expect(cache.isReady(nodeID: original.nodeID, for: "A"))
        #expect(!cache.complete(pending, for: "A"))
    }

    @Test("Removed projects cannot accept old requests after re-creation")
    func removedProject() {
        let cache = MascotHoloRequestCache()
        let card = key()
        let original = token(cache.request(card, for: "A"))
        let otherProject = token(cache.request(card, for: "B"))
        cache.remove("A")
        let replacement = token(cache.request(card, for: "A"))
        #expect(!cache.complete(original, for: "A"))
        #expect(cache.complete(replacement, for: "A"))
        #expect(cache.complete(otherProject, for: "B"))
    }

    @Test("Actor-rendered cards preserve the original full-resolution format")
    func cardDimensions() async {
        let image = await HoloTextureRenderer.shared.render(info: key().info)
        #expect(image?.width == 1024)
        #expect(image?.height == 800)
        #expect(image?.bitsPerComponent == 8)
        #expect(image?.bytesPerRow == 4096)
    }
}
