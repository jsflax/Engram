import Foundation
import RealityKit
import EngramTestSupport
import Testing
@testable import EngramRealityKit

@Suite("Embedded resource lifetime")
@MainActor
struct EmbeddedResourceLifetimeTests {
    @Test(.timeLimit(.minutes(1)))
    func retiredQueuedMascotLoadNeverEntersNativeLoader() async {
        let gate = ResourceLoadGate(), graph = ResourceFixtureGraph(), container = Entity()
        let system = RKMascotSystem(loadMascot: { _, _ in
            gate.calls += 1
            return Entity()
        })
        system.update(container: container, dataProvider: graph, dt: 0.016, scaleFactor: 1)
        system.teardown() // No suspension: the queued loader has not entered yet.
        await system.drainPendingLoads()
        #expect(gate.calls == 0)
        #expect(container.children.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func lateSharedNativeLoadIsJoinedWithoutPublishing(retirePermanently: Bool) async throws {
        let gate = ResourceLoadGate(), graph = ResourceFixtureGraph(), container = Entity()
        defer { gate.complete(nil) }
        let cache = MascotModelPrototypeCache(load: gate.load)
        let system = RKMascotSystem(loadMascot: { _, _ in await cache.clone() ?? Entity() })
        defer { system.teardown() }
        system.update(container: container, dataProvider: graph, dt: 0.016, scaleFactor: 1)
        try await waitUntil { gate.calls == 1 }
        if retirePermanently { system.teardown() } else { system.setActive(false) }
        let drain = Task { @MainActor in
            gate.drainStarted = true
            await system.drainPendingLoads()
            gate.drainFinished = true
        }
        try await waitUntil { gate.drainStarted }
        #expect(!gate.drainFinished)
        drain.cancel() // Cancellation cannot substitute for joining native completion.
        await Task.yield()
        #expect(!gate.drainFinished)
        let prototype = Entity()
        prototype.name = "Late fixture model"
        gate.complete(prototype)
        await drain.value
        #expect(gate.drainFinished)
        #expect(container.children.isEmpty)

        system.setActive(true)
        system.update(container: container, dataProvider: graph, dt: 0.016, scaleFactor: 1)
        await system.drainPendingLoads()
        #expect(gate.calls == 1) // A retired waiter did not cancel or discard the shared cache.
        #expect(container.children.count == (retirePermanently ? 0 : 1))
    }

    @Test(.timeLimit(.minutes(1)))
    func audioTeardownRemovesOnlyItsInjectedTemporaryFiles() throws {
        let directory = try EngramTestFixtureRoot.directory()
            .appendingPathComponent("embedded-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let retained = directory.appendingPathComponent("retained.txt")
        try Data("fixture-owned marker".utf8).write(to: retained)
        let audio = RKSpatialAudioSystem(temporaryDirectory: directory)
        defer { audio.teardown() }
        audio.playsStartupDiagnosticTone = false
        let initial = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let generated = initial.filter { $0.hasPrefix("engram_tone_") && $0.hasSuffix(".wav") }
        #expect(!generated.isEmpty)
        audio.isEnabled = false
        let paused = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(Set(paused) == Set(initial))
        audio.isEnabled = true
        audio.teardown()
        audio.teardown()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(remaining == ["retained.txt"])
        #expect(try Data(contentsOf: retained) == Data("fixture-owned marker".utf8))
        audio.isEnabled = true
        let entity = Entity()
        audio.attachThrusterAudio(to: entity, project: "Retired")
        #expect(entity.components[SpatialAudioComponent.self] == nil)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(predicate(), "Resource fixture did not reach its boundary within five seconds")
    }
}

@MainActor
private final class ResourceLoadGate {
    var calls = 0
    var drainStarted = false
    var drainFinished = false
    private var pending: CheckedContinuation<Entity?, Never>?

    func load() async -> Entity? {
        calls += 1
        return await withCheckedContinuation { pending = $0 }
    }

    func complete(_ entity: Entity?) {
        pending?.resume(returning: entity)
        pending = nil
    }
}

@MainActor
private final class ResourceFixtureGraph: SceneDataProvider {
    private let id = UUID()
    var nodes: [RKNodeSnapshot] {
        [.init(id: id, project: "Fixture", topic: "Synthetic", label: "Fixture", importance: 3, isHub: false)]
    }
    var edges: [RKEdgeSnapshot] { [] }
    var hubs: Set<UUID> { [] }
    var projectColorMap: [String: SIMD3<Float>] { ["Fixture": SIMD3(0, 0.8, 1)] }
    var positions: [UUID: SIMD3<Float>] { [id: .zero] }
    var glowingNodes: [UUID: Float] { [:] }
    var newNodeGlows: [UUID: Float] { [:] }
    var dyingNodes: Set<UUID> { [] }
    var selectedNode: UUID?
    var expandedHubs: Set<UUID> { [] }
    var searchMatchIds: Set<UUID> { [] }
    var isSearchActive: Bool { false }
    var projectCentroids: [String: SIMD3<Float>] { ["Fixture": .zero] }
    var topologyVersion: UInt64 { 1 }
    var positionVersion: UInt64 { 1 }
    func tick(dt: Float) {}
}
