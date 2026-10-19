import Foundation
import RealityKit
import Testing
@testable import EngramRealityKit

@Suite("Mascot graph and asynchronous card caches")
@MainActor
struct MascotCacheTests {
    @Test("Concurrent mascot requests prepare once and return independent recursive clones")
    func prototypeRequestsCoalesce() async throws {
        let gate = PrototypeLoader()
        defer { gate.finish() }
        let cache = MascotModelPrototypeCache(load: gate.load)
        let first = Task { await cache.clone() }
        try await gate.started.wait()
        let secondStarted = Signal()
        let second = Task { @MainActor in
            secondStarted.signal()
            return await cache.clone()
        }
        try await secondStarted.wait()
        #expect(gate.calls == 1)
        first.cancel() // A canceled waiter must not cancel the shared asset load.

        let prototype = Entity()
        let child = ModelEntity(mesh: .generateSphere(radius: 1), materials: [PhysicallyBasedMaterial()])
        child.name = "Child"
        prototype.addChild(child)
        let animation = try AnimationResource.generate(with: FromToByAnimation<Transform>(
            name: "test", from: .identity, to: .identity, duration: 1, bindTarget: .transform))
        child.components.set(AnimationLibraryComponent(animations: ["test": animation]))
        gate.complete(prototype)
        let a = try #require(await first.value)
        let b = try #require(await second.value)
        let c = try #require(await cache.clone())
        #expect(gate.calls == 1)
        #expect(a !== b && b !== c && a !== prototype)
        let ac = try #require(a.findEntity(named: "Child") as? ModelEntity)
        let bc = try #require(b.findEntity(named: "Child") as? ModelEntity)
        #expect(ac !== bc && ac !== child)
        #expect(ac.availableAnimations.count == child.availableAnimations.count)
        #expect(ac.availableAnimations.count == 1)
        #expect(ac.model?.mesh.bounds == child.model?.mesh.bounds)
        ac.position = [8, 9, 10]
        ac.model?.materials = [UnlitMaterial()]
        ac.removeFromParent()
        #expect(bc.position == .zero)
        #expect(child.position == .zero)
        #expect(bc.model?.materials.first is PhysicallyBasedMaterial)
        #expect(child.parent === prototype)
        #expect(c.findEntity(named: "Child") != nil)
    }

    @Test("A failed shared mascot load remains retryable without old waiter interference")
    func failedPrototypeRetries() async throws {
        let gate = PrototypeLoader()
        defer { gate.finish() }
        let cache = MascotModelPrototypeCache(load: gate.load)
        let first = Task { await cache.clone() }
        try await gate.started.wait()
        let waiterStarted = Signal()
        let oldWaiter = Task { @MainActor in
            waiterStarted.signal()
            return await cache.clone()
        }
        try await waiterStarted.wait()
        #expect(gate.calls == 1)
        gate.complete(nil)
        #expect(await first.value == nil)

        let retry = Task { await cache.clone() }
        try await gate.started.wait()
        #expect(await oldWaiter.value == nil)
        #expect(gate.calls == 2)
        let prototype = Entity()
        prototype.name = "Recovered"
        gate.complete(prototype)
        let recovered = try #require(await retry.value)
        let cached = try #require(await cache.clone())
        #expect(gate.calls == 2)
        #expect(recovered.name == "Recovered" && cached.name == "Recovered")
        #expect(recovered !== cached && cached !== prototype)
    }

    @Test("Packaged mascot clones retain skeletons and share geometry with independent project effects")
    func packagedPrototypeAndEffectParity() async throws {
        let a = await MascotEntityFactory.createMascotGroup(project: "A", tint: [1, 0, 0])
        let b = await MascotEntityFactory.createMascotGroup(project: "B", tint: [0, 0, 1])
        #expect(a.name == "Mascot_A" && b.name == "Mascot_B")
        #expect(a.components[MascotComponent.self]?.project == "A")
        #expect(b.components[MascotComponent.self]?.tint == SIMD3<Float>(0, 0, 1))
        let am = try #require(a.findEntity(named: "MascotModel"))
        let bm = try #require(b.findEntity(named: "MascotModel"))
        #expect(am.scale == SIMD3<Float>(repeating: 10))
        let left = descendants(am), right = descendants(bm)
        #expect(left.count == right.count)
        var joints = 0
        for (x, y) in zip(left, right) {
            #expect(x !== y)
            #expect(x.name == y.name && x.transform == y.transform)
            #expect(x.availableAnimations.count == y.availableAnimations.count)
            if let xm = x.components[ModelComponent.self] {
                let ym = try #require(y.components[ModelComponent.self])
                #expect(xm.mesh.bounds == ym.mesh.bounds)
                #expect(xm.mesh.expectedMaterialCount == ym.mesh.expectedMaterialCount)
                #expect(xm.materials.count == ym.materials.count)
                for material in xm.materials {
                    if let pbr = material as? PhysicallyBasedMaterial {
                        #expect(pbr.roughness.scale >= 2)
                        #expect(pbr.specular.scale == 0.2 && pbr.clearcoat.scale == 0)
                    }
                }
            }
            if let x = x as? ModelEntity {
                let y = try #require(y as? ModelEntity)
                #expect(x.jointNames == y.jointNames)
                #expect(x.jointTransforms == y.jointTransforms)
                joints += x.jointNames.count
                if !x.jointTransforms.isEmpty {
                    let original = y.jointTransforms
                    var edited = x.jointTransforms
                    edited[0].translation.x += 1
                    x.jointTransforms = edited
                    #expect(y.jointTransforms == original)
                }
            }
        }
        #expect(joints > 0)
        for name in ["ArcaneCircle", "ConjureOrb", "HoloScreen"] {
            let x = try #require(a.findEntity(named: name) as? ModelEntity)
            let y = try #require(b.findEntity(named: name) as? ModelEntity)
            #expect(x !== y && !x.isEnabled && !y.isEnabled)
            #expect(x.transform == y.transform)
            #expect(x.model?.mesh.bounds == y.model?.mesh.bounds)
            if name == "HoloScreen" {
                let red = try #require(x.model?.materials.first as? UnlitMaterial)
                let blue = try #require(y.model?.materials.first as? UnlitMaterial)
                #expect(red.color.tint != blue.color.tint)
            } else {
                let red = try #require(x.model?.materials.first as? PhysicallyBasedMaterial)
                let blue = try #require(y.model?.materials.first as? PhysicallyBasedMaterial)
                #expect(red.emissiveColor.color != blue.emissiveColor.color)
            }
            x.isEnabled = true
            x.position.x += 100
            x.model?.materials = [UnlitMaterial()]
            #expect(!y.isEnabled && y.position.x == 0)
            if name != "HoloScreen" {
                let material = try #require(y.model?.materials.first as? PhysicallyBasedMaterial)
                #expect(material.emissiveIntensity == (name == "ArcaneCircle" ? 3 : 8))
            }
        }
        let c = await MascotEntityFactory.createMascotGroup(project: "C", tint: [0, 1, 0])
        #expect(c.findEntity(named: "MascotModel")?.scale == SIMD3<Float>(repeating: 10))
        #expect(c.findEntity(named: "ArcaneCircle")?.isEnabled == false)
    }

    private func descendants(_ entity: Entity) -> [Entity] {
        [entity] + entity.children.flatMap { descendants($0) }
    }

    @MainActor
    private final class Signal {
        private var ready = false
        func signal() { ready = true }
        func wait() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !ready && ContinuousClock.now < deadline { await Task.yield() }
            try #require(ready, "Mascot test task did not reach its load gate within five seconds")
            ready = false
        }
    }

    @MainActor
    private final class PrototypeLoader {
        let started = Signal()
        private(set) var calls = 0
        private var replies: [CheckedContinuation<Entity?, Never>] = []
        private var finished = false
        func load() async -> Entity? {
            guard !finished else { return nil }
            calls += 1
            return await withCheckedContinuation {
                replies.append($0)
                started.signal()
            }
        }
        func complete(_ entity: Entity?) {
            let replies = replies
            self.replies.removeAll()
            for reply in replies { reply.resume(returning: entity) }
        }
        func finish() {
            finished = true
            complete(nil)
        }
    }

    @Test
    func routingDomainsExtendOnlyCertifiedNodeSuffixes() {
        let owner = NSObject()
        let first = node(project: "A"), second = node(project: "B")
        let duplicate = node(first.id, project: "B"), fourth = node(project: "C")
        let index = MascotGraphIndex()
        index.update(nodes: [first], nodeVersion: 1, nodeAppendGeneration: 7, provider: owner)
        index.update(nodes: [first, second], nodeVersion: 2, nodeAppendGeneration: 7, provider: owner)
        index.update(nodes: [first, second, duplicate, fourth], nodeVersion: 4,
                     nodeAppendGeneration: 7, provider: owner)
        for _ in 0..<100 {
            index.update(nodes: [first, second, duplicate, fourth], nodeVersion: 4,
                         nodeAppendGeneration: 7, provider: owner)
        }
        #expect(index.nodesVisited == 4)
        #expect(index.projects == ["A", "B", "C"])
        #expect(index.indicesByProject["B"] == [1, 2])
        #expect(index.indexByID[first.id] == 0)
        #expect(index.indexByID[fourth.id] == 3)
    }

    @Test
    func routingDomainsRebuildForEditsRemovalAndReplacement() {
        let owner = NSObject(), replacement = NSObject()
        let a = node(project: "A"), b = node(project: "B"), c = node(project: "C")
        let index = MascotGraphIndex()
        index.update(nodes: [a, b], nodeVersion: 1, nodeAppendGeneration: 1, provider: owner)
        let edited = node(a.id, project: "changed")
        let cases = [[edited, b, c], [c, b, edited], [b], []]
        for (offset, nodes) in cases.enumerated() {
            let revision = UInt64(offset + 2)
            index.update(nodes: nodes, nodeVersion: revision,
                         nodeAppendGeneration: revision, provider: owner)
            #expect(index.projects == Set(nodes.map(\.project)))
            for project in index.projects {
                #expect(index.indicesByProject[project] == nodes.indices.filter { nodes[$0].project == project })
            }
            #expect(index.indexByID.count == nodes.count)
            for (i, node) in nodes.enumerated() { #expect(index.indexByID[node.id] == i) }
        }
        index.update(nodes: [a, b], nodeVersion: 10, nodeAppendGeneration: 10, provider: owner)
        index.update(nodes: [c, edited], nodeVersion: 10, nodeAppendGeneration: 10, provider: replacement)
        #expect(index.projects == ["C", "changed"])
        #expect(index.indexByID[b.id] == nil)
        #expect(index.indexByID[a.id] == 1)
    }

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
