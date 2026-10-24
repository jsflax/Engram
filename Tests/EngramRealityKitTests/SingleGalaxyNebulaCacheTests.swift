import Foundation
import RealityKit
import Testing
import simd
@testable import EngramRealityKit

@MainActor
private final class NebulaTestProvider: SceneDataProvider {
    var nodes: [RKNodeSnapshot] = []
    var edges: [RKEdgeSnapshot] = []
    var hubs: Set<UUID> = []
    var projectColorMap: [String: SIMD3<Float>] = [:]
    var storedPositions: [UUID: SIMD3<Float>] = [:]
    var flatPositions: [SIMD3<Float>] = []
    var dictionaryReads = 0
    var flatReads = 0
    var positions: [UUID: SIMD3<Float>] { dictionaryReads += 1; return storedPositions }
    var positionArray: [SIMD3<Float>] { flatReads += 1; return flatPositions }
    var glowingNodes: [UUID: Float] = [:]
    var newNodeGlows: [UUID: Float] = [:]
    var dyingNodes: Set<UUID> = []
    var selectedNode: UUID?
    var expandedHubs: Set<UUID> = []
    var searchMatchIds: Set<UUID> = []
    var isSearchActive = false
    var projectCentroids: [String: SIMD3<Float>] = [:]
    var topologyVersion: UInt64 = 0
    var positionVersion: UInt64 = 0
    var galaxySnapshots: [RKGalaxySnapshot] = []
    func tick(dt: Float) {}
}

@Suite("Nebula transform updates")
@MainActor
struct NebulaTransformUpdateTests {
    @Test("Stationary, moved, and rescaled nebulae retain entities and follow current positions")
    func unchangedAndChangedPositions() throws {
        let provider = NebulaTestProvider()
        provider.nodes = (0..<2).map { _ in
            RKNodeSnapshot(id: UUID(), project: "A", topic: "topic", label: "A",
                           importance: 1, isHub: false)
        }
        func galaxy(_ id: String, center: SIMD3<Float>) -> RKGalaxySnapshot {
            RKGalaxySnapshot(id: id, displayName: id, worldCenter: center,
                             dominantColor: SIMD3<Float>(0.3, 0.5, 0.7), nodeCount: 2,
                             radius: 500, parentGalaxyId: nil)
        }
        func setInputs(cluster: SIMD3<Float>, personal: SIMD3<Float>, group: SIMD3<Float>) {
            provider.projectCentroids = ["A": cluster]
            provider.storedPositions = [provider.nodes[0].id: cluster + SIMD3<Float>(1, 0, 0),
                                        provider.nodes[1].id: cluster - SIMD3<Float>(1, 0, 0)]
            provider.galaxySnapshots = [galaxy("personal", center: personal), galaxy("group:test", center: group)]
        }
        var cluster = SIMD3<Float>(100, 20, -40)
        var personal = SIMD3<Float>(0, 50, 0)
        var group = SIMD3<Float>(1000, 200, 0)
        var scale: Float = 0.01
        setInputs(cluster: cluster, personal: personal, group: group)
        let system = NebulaBatchSystem()
        let container = Entity()
        func update() {
            system.update(container: container, dataProvider: provider, topologyChanged: false,
                          scaleFactor: scale, cameraPosition: .zero)
        }
        update()
        let entities = Dictionary(uniqueKeysWithValues: container.children.map { ($0.name, $0) })
        try #require(entities.count == 7, "One cluster, two galaxy masses, and four bridge emitters")
        let clusterEntity = try #require(entities["Nebula_main|A"])
        let personalEntity = try #require(entities["GalaxyGas_personal"])
        let groupEntity = try #require(entities["GalaxyGas_group:test"])
        let initialEmitter = try #require(clusterEntity.components[ParticleEmitterComponent.self])
        let initialBirthRate = initialEmitter.mainEmitter.birthRate
        let initialLifeSpan = initialEmitter.mainEmitter.lifeSpan
        func verify() throws {
            #expect(container.children.count == entities.count)
            for child in container.children { #expect(entities[child.name] === child) }
            #expect(clusterEntity.position == cluster * scale)
            #expect(personalEntity.position == personal * scale)
            #expect(groupEntity.position == group * scale)
            for step in 1...4 {
                let bridge = try #require(entities["Bridge_bridge|group:test|\(step)"])
                let expected = (personal + (group - personal) * (Float(step) / 5)) * scale
                #expect(bridge.position == expected)
            }
            let emitter = try #require(clusterEntity.components[ParticleEmitterComponent.self])
            #expect(emitter.mainEmitter.birthRate == initialBirthRate)
            #expect(emitter.mainEmitter.lifeSpan == initialLifeSpan)
        }
        try verify()
        for _ in 0..<4 { update(); try verify() }

        cluster += SIMD3<Float>(10, -5, 8)
        personal += SIMD3<Float>(-30, 10, 15)
        group += SIMD3<Float>(50, -20, -10)
        setInputs(cluster: cluster, personal: personal, group: group)
        update()
        try verify()
        scale = 0.02
        update()
        try verify()

        // Compare actual entity state, not only cached input: another owner
        // changing a transform must not prevent restoration on the next update.
        for entity in entities.values { entity.position = SIMD3<Float>(-999, -999, -999) }
        update()
        try verify()
    }
}

@Suite("Single-galaxy nebula aggregation caching")
@MainActor
struct SingleGalaxyNebulaCacheTests {
    private func node(_ project: String) -> RKNodeSnapshot {
        RKNodeSnapshot(id: UUID(), project: project, topic: "topic", label: project,
                       importance: 1, isHub: false)
    }

    @Test("Default aggregation scans once and preserves missing-position counts")
    func defaultAggregation() {
        let provider = NebulaTestProvider()
        provider.nodes = [node("A"), node("A"), node("B"), node("No centroid")]
        provider.projectCentroids = ["A": .zero, "B": SIMD3<Float>(100, 0, 0), "Empty": .zero]
        provider.storedPositions = [provider.nodes[0].id: SIMD3<Float>(3, 4, 0),
                                    provider.nodes[2].id: SIMD3<Float>(100, 0, 12)]
        let clusters = Dictionary(uniqueKeysWithValues: provider.nebulaClusters.map { ($0.project, $0) })
        #expect(provider.dictionaryReads == 1)
        #expect(provider.flatReads == 0)
        #expect(clusters["A"]?.count == 2)
        #expect(clusters["A"]?.radius == 45)
        #expect(clusters["B"]?.radius == 52)
        #expect(clusters["Empty"]?.count == 0)
        #expect(clusters["Empty"]?.radius == 40)
        #expect(clusters["No centroid"] == nil)
    }

    @Test("Stationary cache hits never materialize positions or rescan flat data")
    func stationaryInputs() {
        let provider = NebulaTestProvider()
        provider.nodes = [node("A"), node("A")]
        provider.projectCentroids = ["A": .zero]
        provider.flatPositions = [SIMD3<Float>(3, 4, 0), SIMD3<Float>(0, 0, 12)]
        let cache = SingleGalaxyNebulaCache()
        for _ in 0..<10 {
            #expect(cache.clusters(for: provider).first?.radius == 52)
        }
        #expect(provider.flatReads == 1)
        #expect(provider.dictionaryReads == 0)
    }

    @Test("Position changes and late centroid updates invalidate independently")
    func positionsAndDeferredCentroid() {
        let provider = NebulaTestProvider()
        provider.nodes = [node("A")]
        provider.projectCentroids = ["A": .zero]
        provider.flatPositions = [SIMD3<Float>(0, 0, 10)]
        let cache = SingleGalaxyNebulaCache()
        #expect(cache.clusters(for: provider).first?.radius == 50)
        provider.flatPositions[0] = SIMD3<Float>(0, 0, 20)
        provider.positionVersion += 1
        #expect(cache.clusters(for: provider).first?.radius == 60)
        provider.projectCentroids["A"] = SIMD3<Float>(0, 0, 15)
        #expect(cache.clusters(for: provider).first?.radius == 45)
        #expect(cache.clusters(for: provider).first?.centroid == SIMD3<Float>(0, 0, 15))
        #expect(provider.flatReads == 3)
    }

    @Test("Same-count project edits and node-count changes refresh clusters")
    func topologyAndCounts() {
        let provider = NebulaTestProvider()
        provider.nodes = [node("A")]
        provider.projectCentroids = ["A": .zero, "B": .zero]
        provider.flatPositions = [.zero]
        let cache = SingleGalaxyNebulaCache()
        _ = cache.clusters(for: provider)
        let id = provider.nodes[0].id
        provider.nodes[0] = RKNodeSnapshot(id: id, project: "B", topic: "topic", label: "B",
                                           importance: 1, isHub: false)
        provider.topologyVersion += 1
        let updated = Dictionary(uniqueKeysWithValues: cache.clusters(for: provider).map { ($0.project, $0.count) })
        #expect(updated["A"] == 0)
        #expect(updated["B"] == 1)
        provider.nodes.append(node("B"))
        provider.flatPositions.append(.zero)
        let appended = Dictionary(uniqueKeysWithValues: cache.clusters(for: provider).map { ($0.project, $0.count) })
        #expect(appended["B"] == 2)
        #expect(provider.flatReads == 3)
    }

    @Test("Provider identity prevents same-revision cache reuse")
    func providerReplacement() {
        let first = NebulaTestProvider()
        let second = NebulaTestProvider()
        for provider in [first, second] {
            provider.nodes = [node("A")]
            provider.projectCentroids = ["A": .zero]
        }
        first.flatPositions = [SIMD3<Float>(0, 0, 10)]
        second.flatPositions = [SIMD3<Float>(0, 0, 30)]
        let cache = SingleGalaxyNebulaCache()
        #expect(cache.clusters(for: first).first?.radius == 50)
        #expect(cache.clusters(for: second).first?.radius == 70)
    }

    @Test("Incomplete flat positions use one dictionary snapshot")
    func fallbackPositions() {
        let provider = NebulaTestProvider()
        provider.nodes = [node("A"), node("A")]
        provider.projectCentroids = ["A": .zero]
        provider.flatPositions = [.zero]
        provider.storedPositions[provider.nodes[0].id] = SIMD3<Float>(0, 0, 8)
        let cache = SingleGalaxyNebulaCache()
        #expect(cache.clusters(for: provider).first?.radius == 48)
        #expect(cache.clusters(for: provider).first?.count == 2)
        #expect(provider.dictionaryReads == 1)
    }
}

@Suite("Nebula LOD visibility")
@MainActor
struct NebulaLODVisibilityTests {
    private func provider() -> NebulaTestProvider {
        let provider = NebulaTestProvider()
        provider.nodes = (0..<2).map { _ in
            RKNodeSnapshot(id: UUID(), project: "A", topic: "topic", label: "A",
                           importance: 1, isHub: false)
        }
        setInputs(provider, center: .zero, spread: 100, galaxyRadius: 500)
        return provider
    }

    private func setInputs(_ provider: NebulaTestProvider, center: SIMD3<Float>,
                           spread: Float, galaxyRadius: Float) {
        provider.projectCentroids = ["A": center]
        provider.storedPositions = [
            provider.nodes[0].id: center + SIMD3<Float>(spread, 0, 0),
            provider.nodes[1].id: center - SIMD3<Float>(spread, 0, 0),
        ]
        // The default cluster provider uses galaxyId "main". Match that ID
        // so these tests exercise both sides of the actual near/far crossfade.
        provider.galaxySnapshots = [
            RKGalaxySnapshot(id: "main", displayName: "Main", worldCenter: center,
                             dominantColor: SIMD3<Float>(0.3, 0.5, 0.7), nodeCount: 2,
                             radius: galaxyRadius, parentGalaxyId: nil),
            RKGalaxySnapshot(id: "group:test", displayName: "Group",
                             worldCenter: center + SIMD3<Float>(1000, 0, 0),
                             dominantColor: SIMD3<Float>(0.7, 0.5, 0.3), nodeCount: 2,
                             radius: 500, parentGalaxyId: "main"),
        ]
    }

    private func update(_ system: NebulaBatchSystem, _ container: Entity,
                        _ provider: NebulaTestProvider, camera: SIMD3<Float>) {
        system.update(container: container, dataProvider: provider, topologyChanged: false,
                      scaleFactor: 0.01, cameraPosition: camera)
    }

    @Test("Initial near and far LOD disable only their fully transparent emitters")
    func initialNearAndFarVisibility() throws {
        for distance in [Float(0), Float(6000)] {
            let provider = self.provider()
            let system = NebulaBatchSystem()
            let container = Entity()
            update(system, container, provider, camera: SIMD3<Float>(distance, 0, 0))
            let cluster = try #require(container.children.first { $0.name == "Nebula_main|A" })
            let galaxy = try #require(container.children.first { $0.name == "GalaxyGas_main" })
            #expect(cluster.isEnabled == (distance == 0))
            #expect(galaxy.isEnabled == (distance != 0))
            #expect(cluster.components[OpacityComponent.self]?.opacity == (distance == 0 ? 1 : 0))
            #expect(galaxy.components[OpacityComponent.self]?.opacity == (distance == 0 ? 0 : 1))
            let bridges = container.children.filter { $0.name.hasPrefix("Bridge_") }
            #expect(bridges.count == 4)
            for bridge in bridges {
                #expect(bridge.isEnabled)
                #expect(bridge.components[OpacityComponent.self] == nil)
            }
        }
    }

    @Test("Exact fade endpoints and tiny reentry bypass the visible opacity deadband")
    func fadeEndpointsAndTinyReentry() throws {
        let provider = self.provider()
        let system = NebulaBatchSystem()
        let container = Entity()
        update(system, container, provider, camera: SIMD3<Float>(6000, 0, 0))
        let cluster = try #require(container.children.first { $0.name == "Nebula_main|A" })
        let galaxy = try #require(container.children.first { $0.name == "GalaxyGas_main" })

        // Re-enter near LOD at 0.97 and far LOD at 0.03, then hit the exact
        // endpoints. Both changes are smaller than the ordinary 0.05 deadband.
        update(system, container, provider, camera: SIMD3<Float>(2678, 0, 0))
        let near = try #require(cluster.components[OpacityComponent.self]?.opacity)
        let far = try #require(galaxy.components[OpacityComponent.self]?.opacity)
        #expect(abs(near - 0.97) < 0.0001)
        #expect(abs(far - 0.03) < 0.0001)
        #expect(cluster.isEnabled && galaxy.isEnabled)
        update(system, container, provider, camera: .zero)
        #expect(cluster.components[OpacityComponent.self]?.opacity == 1)
        #expect(galaxy.components[OpacityComponent.self]?.opacity == 0)
        #expect(cluster.isEnabled && !galaxy.isEnabled)

        // A positive value smaller than the deadband must still restore the
        // entity with positive opacity; it must not stay invisible at zero.
        update(system, container, provider, camera: SIMD3<Float>(2602.6, 0, 0))
        let tinyFar = try #require(galaxy.components[OpacityComponent.self]?.opacity)
        #expect(tinyFar > 0 && tinyFar < 0.005)
        #expect(galaxy.isEnabled)
        update(system, container, provider, camera: SIMD3<Float>(5200, 0, 0))
        #expect(!cluster.isEnabled && galaxy.isEnabled)
        #expect(cluster.components[OpacityComponent.self]?.opacity == 0)
        #expect(galaxy.components[OpacityComponent.self]?.opacity == 1)
        update(system, container, provider, camera: SIMD3<Float>(5197.4, 0, 0))
        let tinyNear = try #require(cluster.components[OpacityComponent.self]?.opacity)
        #expect(tinyNear > 0 && tinyNear < 0.005)
        #expect(cluster.isEnabled && galaxy.isEnabled)
        // Ordinary positive changes below the deadband retain the last value.
        update(system, container, provider, camera: SIMD3<Float>(5194.8, 0, 0))
        #expect(cluster.components[OpacityComponent.self]?.opacity == tinyNear)
        #expect(cluster.isEnabled && galaxy.isEnabled)
    }

    @Test("Hidden LOD retains live transforms and resizing and is removed and recreated with topology")
    func hiddenMovementResizeAndRecreation() throws {
        for distance in [Float(0), Float(6000)] {
            let provider = self.provider()
            let system = NebulaBatchSystem()
            let container = Entity()
            let camera = SIMD3<Float>(distance, 0, 0)
            update(system, container, provider, camera: camera)
            let name = distance == 0 ? "GalaxyGas_main" : "Nebula_main|A"
            let hidden = try #require(container.children.first { $0.name == name })
            #expect(!hidden.isEnabled)
            let originalEmitter = try #require(hidden.components[ParticleEmitterComponent.self])
            let center = SIMD3<Float>(20, 30, 40)
            setInputs(provider, center: center, spread: 500, galaxyRadius: 1000)
            update(system, container, provider, camera: center + camera)
            #expect(container.children.first { $0.name == name } === hidden)
            #expect(!hidden.isEnabled)
            #expect(hidden.position == center * 0.01)
            let resizedEmitter = try #require(hidden.components[ParticleEmitterComponent.self])
            #expect(resizedEmitter.emitterShapeSize.x > originalEmitter.emitterShapeSize.x)
            #expect(resizedEmitter.mainEmitter.lifeSpan == originalEmitter.mainEmitter.lifeSpan)
            for bridge in container.children where bridge.name.hasPrefix("Bridge_") {
                #expect(bridge.isEnabled)
            }

            provider.nodes.removeAll()
            provider.projectCentroids.removeAll()
            provider.storedPositions.removeAll()
            provider.galaxySnapshots.removeAll()
            update(system, container, provider, camera: camera)
            #expect(container.children.isEmpty)
            #expect(hidden.parent == nil)

            let replacement = self.provider()
            update(system, container, replacement, camera: camera)
            let recreated = try #require(container.children.first { $0.name == name })
            #expect(recreated !== hidden)
            #expect(!recreated.isEnabled)
            #expect(recreated.components[OpacityComponent.self]?.opacity == 0)
            let restoredEmitter = try #require(recreated.components[ParticleEmitterComponent.self])
            #expect(restoredEmitter.emitterShapeSize == originalEmitter.emitterShapeSize)
            #expect(restoredEmitter.mainEmitter.birthRate == originalEmitter.mainEmitter.birthRate)
        }
    }
}
