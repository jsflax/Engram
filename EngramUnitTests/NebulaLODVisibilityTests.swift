import Foundation
import RealityKit
import XCTest
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
    var explicitClusters: [RKNebulaCluster]?
    var nebulaClusters: [RKNebulaCluster] {
        explicitClusters ?? deriveSingleGalaxyNebulaClusters(
            nodes: nodes, centroids: projectCentroids,
            positionArray: [], positions: { positions })
    }
    func tick(dt: Float) {}
}

@MainActor
final class NebulaLODVisibilityTests: XCTestCase {
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
                        _ provider: NebulaTestProvider, camera: SIMD3<Float>,
                        scaleFactor: Float = 0.01, deltaTime: Float = 1 / 60) {
        system.update(container: container, dataProvider: provider, topologyChanged: false,
                      scaleFactor: scaleFactor, cameraPosition: camera, deltaTime: deltaTime)
    }

    private func cluster(_ index: Int, galaxy: String = "main", center: SIMD3<Float> = .zero,
                         radius: Float = 300) -> RKNebulaCluster {
        .init(galaxyId: galaxy, project: String(format: "P%03d", index), centroid: center,
              count: 2, radius: radius)
    }

    private func galaxy(_ id: String, center: SIMD3<Float> = .zero, radius: Float = 1000,
                        count: Int = 332) -> RKGalaxySnapshot {
        .init(id: id, displayName: id, worldCenter: center, dominantColor: SIMD3(0.3, 0.5, 0.7),
              nodeCount: count, radius: radius, parentGalaxyId: nil)
    }

    @discardableResult
    private func assertActualDetailBudget(_ container: Entity) throws -> [Entity] {
        let details = container.children.filter { $0.name.hasPrefix("Nebula_") }
        let enabled = details.filter(\.isEnabled)
        XCTAssertTrue((enabled.count) <= (24))
        var births: Float = 0
        for entity in details {
            let opacity = try XCTUnwrap(entity.components[OpacityComponent.self]?.opacity)
            XCTAssertTrue((entity.isEnabled) == (opacity > 0))
            if entity.isEnabled {
                births += try XCTUnwrap(entity.components[ParticleEmitterComponent.self])
                    .mainEmitter.birthRate
            }
        }
        XCTAssertTrue((births) <= (240.0001) , "Count configured emission, without discounting faded opacity")
        return enabled
    }

    func testOverlapping166ProjectsBoundActualEnabledEntitiesAndPreserveAggregateCoverage() throws {
        let provider = NebulaTestProvider()
        let inputs = (0..<166).map { index in
            RKNebulaCluster(galaxyId: "main", project: String(format: "P%03d", index), centroid: .zero,
                           count: index < 5 ? (index + 1) * 10 : 2, radius: 300)
        }
        provider.explicitClusters = inputs
        let totalWeight = inputs.reduce(0) { $0 + $1.count }
        provider.galaxySnapshots = [galaxy("main", count: totalWeight)]
        let system = NebulaBatchSystem(), container = Entity()
        for _ in 0..<60 {
            update(system, container, provider, camera: .zero)
            try assertActualDetailBudget(container)
        }
        let details = container.children.filter { $0.name.hasPrefix("Nebula_") }
        XCTAssertTrue((details.count) == (166))
        XCTAssertTrue((details.filter(\.isEnabled).count) == (16))
        let aggregate = try XCTUnwrap(container.children.first { $0.name == "GalaxyGas_main" })
        let byName = Dictionary(uniqueKeysWithValues: details.map { ($0.name, $0) })
        let detailCoverage = inputs.reduce(Float(0)) {
            $0 + Float($1.count) * (byName["Nebula_\($1.key)"]?.components[OpacityComponent.self]?.opacity ?? 0)
        }
        XCTAssertTrue(abs((try XCTUnwrap(aggregate.components[OpacityComponent.self]?.opacity)) - (1 - detailCoverage / Float(totalWeight))) <= 0.05 , "Applied coarse coverage retains the existing 0.05 opacity write deadband")
        XCTAssertTrue(aggregate.isEnabled , "The coarse cloud represents detail withheld by the budget")
        let retained = Dictionary(uniqueKeysWithValues: container.children.map { ($0.name, $0) })
        let opacities = Dictionary(uniqueKeysWithValues: container.children.map { ($0.name, $0.components[OpacityComponent.self]?.opacity) })
        for _ in 0..<5 { update(system, container, provider, camera: .zero) }
        for entity in container.children {
            XCTAssertTrue(retained[entity.name] === entity)
            XCTAssertTrue((entity.components[OpacityComponent.self]?.opacity) == (opacities[entity.name]!))
        }
    }

    func testGlobalBudgetIncludesOutgoingEntitiesDuringCameraTeleportAndRateGrowth() throws {
        let provider = NebulaTestProvider()
        let secondCenter = SIMD3<Float>(2000, 0, 0)
        func clusters(radius: Float) -> [RKNebulaCluster] {
            (0..<40).map { cluster($0, galaxy: "first", radius: radius) }
                + (0..<40).map { cluster($0, galaxy: "second", center: secondCenter, radius: radius) }
        }
        provider.explicitClusters = clusters(radius: 100)
        provider.galaxySnapshots = [galaxy("first", count: 80), galaxy("second", center: secondCenter, count: 80)]
        let system = NebulaBatchSystem(), container = Entity()
        for _ in 0..<60 {
            update(system, container, provider, camera: .zero)
            try assertActualDetailBudget(container)
        }
        let original = Set(try assertActualDetailBudget(container).map(\.name))
        XCTAssertTrue((original.count) == (24))
        XCTAssertTrue(original.allSatisfy { $0.hasPrefix("Nebula_first|") })
        var sawOutgoingFade = false
        for _ in 0..<60 {
            update(system, container, provider, camera: secondCenter)
            let enabled = try assertActualDetailBudget(container)
            sawOutgoingFade = sawOutgoingFade || enabled.contains {
                original.contains($0.name) && ($0.components[OpacityComponent.self]?.opacity ?? 1) < 1
            }
        }
        XCTAssertTrue(sawOutgoingFade)
        XCTAssertTrue(try assertActualDetailBudget(container).allSatisfy { $0.name.hasPrefix("Nebula_second|") })
        provider.explicitClusters = clusters(radius: 300)
        for _ in 0..<90 {
            update(system, container, provider, camera: secondCenter)
            try assertActualDetailBudget(container)
        }
        let grown = try assertActualDetailBudget(container)
        XCTAssertTrue((grown.count) == (16))
        for entity in grown {
            XCTAssertTrue((try XCTUnwrap(entity.components[ParticleEmitterComponent.self]).mainEmitter.birthRate) == (15))
        }
    }

    func testWorldSpaceSelectionSurvivesScaleChangesAndRespondsToClusterGeometry() throws {
        let provider = NebulaTestProvider()
        let center = SIMD3<Float>(10_000, 4000, -5000)
        let distant = center + SIMD3<Float>(6000, 0, 0)
        provider.explicitClusters = [cluster(0, center: center, radius: 100), cluster(1, center: distant, radius: 100)]
        provider.galaxySnapshots = [galaxy("main", center: center, radius: 20_000, count: 4)]
        let system = NebulaBatchSystem(), container = Entity()
        update(system, container, provider, camera: center, scaleFactor: 0.005)
        let nearby = try XCTUnwrap(container.children.first { $0.name == "Nebula_main|P000" })
        let remote = try XCTUnwrap(container.children.first { $0.name == "Nebula_main|P001" })
        XCTAssertTrue(nearby.isEnabled)
        XCTAssertTrue(!(remote.isEnabled) , "Being inside a large galaxy does not admit a distant individual cluster")
        let originalSize = try XCTUnwrap(nearby.components[ParticleEmitterComponent.self]).emitterShapeSize
        update(system, container, provider, camera: center, scaleFactor: 0.02)
        XCTAssertTrue(container.children.first { $0.name == nearby.name } === nearby)
        XCTAssertTrue(nearby.isEnabled)
        XCTAssertTrue(!(remote.isEnabled))
        XCTAssertTrue((nearby.position) == (center * 0.02))
        XCTAssertTrue((remote.position) == (distant * 0.02))
        XCTAssertTrue((try XCTUnwrap(nearby.components[ParticleEmitterComponent.self]).emitterShapeSize) == (originalSize * 4))
        let beforeJitter = try XCTUnwrap(nearby.components[ParticleEmitterComponent.self])
        provider.explicitClusters = [cluster(0, center: center, radius: 110), cluster(1, center: distant, radius: 100)]
        update(system, container, provider, camera: center, scaleFactor: 0.02)
        let afterJitter = try XCTUnwrap(nearby.components[ParticleEmitterComponent.self])
        XCTAssertTrue((afterJitter.emitterShapeSize) == (beforeJitter.emitterShapeSize))
        XCTAssertTrue((afterJitter.mainEmitter.birthRate) == (beforeJitter.mainEmitter.birthRate) , "Subthreshold live-radius jitter must not rewrite particle configuration through rate admission")
        provider.explicitClusters = [cluster(0, center: center, radius: 110), cluster(1, center: distant, radius: 10_000)]
        update(system, container, provider, camera: center, scaleFactor: 0.02)
        XCTAssertTrue(remote.isEnabled , "Radius changes refresh local desire even without a topology change")
        try assertActualDetailBudget(container)
    }

    func testMissingGalaxySnapshotGetsBoundedDetailsAndRetainedCoarseFallback() throws {
        let provider = NebulaTestProvider()
        let center = SIMD3<Float>(1000, -100, 50)
        provider.explicitClusters = (0..<166).map { cluster($0, center: center) }
        let system = NebulaBatchSystem(), container = Entity()
        for _ in 0..<60 {
            update(system, container, provider, camera: center)
            try assertActualDetailBudget(container)
        }
        let aggregate = try XCTUnwrap(container.children.first { $0.name == "GalaxyGas_main" })
        XCTAssertTrue(aggregate.isEnabled)
        XCTAssertTrue((aggregate.position) == (center * 0.01))
        XCTAssertTrue((try XCTUnwrap(aggregate.components[OpacityComponent.self]?.opacity)) > (0.8))
        update(system, container, provider, camera: center + SIMD3<Float>(6000, 0, 0))
        XCTAssertTrue(container.children.first { $0.name == "GalaxyGas_main" } === aggregate)
        XCTAssertTrue(try assertActualDetailBudget(container).isEmpty)
        XCTAssertTrue((aggregate.components[OpacityComponent.self]?.opacity) == (1))
    }

    func testInitialNearAndFarVisibility() throws {
        for distance in [Float(0), Float(6000)] {
            let provider = self.provider()
            let system = NebulaBatchSystem()
            let container = Entity()
            update(system, container, provider, camera: SIMD3<Float>(distance, 0, 0))
            let cluster = try XCTUnwrap(container.children.first { $0.name == "Nebula_main|A" })
            let galaxy = try XCTUnwrap(container.children.first { $0.name == "GalaxyGas_main" })
            XCTAssertTrue(cluster.isEnabled == (distance == 0))
            XCTAssertTrue(galaxy.isEnabled == (distance != 0))
            XCTAssertTrue(cluster.components[OpacityComponent.self]?.opacity == (distance == 0 ? 1 : 0))
            XCTAssertTrue(galaxy.components[OpacityComponent.self]?.opacity == (distance == 0 ? 0 : 1))
            let bridges = container.children.filter { $0.name.hasPrefix("Bridge_") }
            XCTAssertTrue(bridges.count == 4)
            for bridge in bridges {
                XCTAssertTrue(bridge.isEnabled)
                XCTAssertTrue(bridge.components[OpacityComponent.self] == nil)
            }
        }
    }

    func testFadeEndpointsAndTinyReentry() throws {
        let provider = self.provider()
        let system = NebulaBatchSystem()
        let container = Entity()
        update(system, container, provider, camera: SIMD3<Float>(6000, 0, 0))
        let cluster = try XCTUnwrap(container.children.first { $0.name == "Nebula_main|A" })
        let galaxy = try XCTUnwrap(container.children.first { $0.name == "GalaxyGas_main" })

        // Re-enter near LOD at 0.97 and far LOD at 0.03, then hit the exact
        // endpoints. Both changes are smaller than the ordinary 0.05 deadband.
        update(system, container, provider, camera: SIMD3<Float>(2678, 0, 0))
        let near = try XCTUnwrap(cluster.components[OpacityComponent.self]?.opacity)
        let far = try XCTUnwrap(galaxy.components[OpacityComponent.self]?.opacity)
        XCTAssertTrue(abs(near - 0.97) < 0.0001)
        XCTAssertTrue(abs(far - 0.03) < 0.0001)
        XCTAssertTrue(cluster.isEnabled && galaxy.isEnabled)
        update(system, container, provider, camera: .zero)
        XCTAssertTrue(cluster.components[OpacityComponent.self]?.opacity == 1)
        XCTAssertTrue(galaxy.components[OpacityComponent.self]?.opacity == 0)
        XCTAssertTrue(cluster.isEnabled && !galaxy.isEnabled)

        // A positive value smaller than the deadband must still restore the
        // entity with positive opacity; it must not stay invisible at zero.
        update(system, container, provider, camera: SIMD3<Float>(2602.6, 0, 0))
        let tinyFar = try XCTUnwrap(galaxy.components[OpacityComponent.self]?.opacity)
        XCTAssertTrue(tinyFar > 0 && tinyFar < 0.005)
        XCTAssertTrue(galaxy.isEnabled)
        update(system, container, provider, camera: SIMD3<Float>(5200, 0, 0))
        XCTAssertTrue(!cluster.isEnabled && galaxy.isEnabled)
        XCTAssertTrue(cluster.components[OpacityComponent.self]?.opacity == 0)
        XCTAssertTrue(galaxy.components[OpacityComponent.self]?.opacity == 1)
        update(system, container, provider, camera: SIMD3<Float>(5197.4, 0, 0))
        let tinyNear = try XCTUnwrap(cluster.components[OpacityComponent.self]?.opacity)
        XCTAssertTrue(tinyNear > 0 && tinyNear < 0.005)
        XCTAssertTrue(cluster.isEnabled && galaxy.isEnabled)
        // Ordinary positive changes below the deadband retain the last value.
        update(system, container, provider, camera: SIMD3<Float>(5194.8, 0, 0))
        XCTAssertTrue(cluster.components[OpacityComponent.self]?.opacity == tinyNear)
        XCTAssertTrue(cluster.isEnabled && galaxy.isEnabled)
    }

    func testHiddenMovementResizeAndRecreation() throws {
        for distance in [Float(0), Float(6000)] {
            let provider = self.provider()
            let system = NebulaBatchSystem()
            let container = Entity()
            let camera = SIMD3<Float>(distance, 0, 0)
            update(system, container, provider, camera: camera)
            let name = distance == 0 ? "GalaxyGas_main" : "Nebula_main|A"
            let hidden = try XCTUnwrap(container.children.first { $0.name == name })
            XCTAssertTrue(!hidden.isEnabled)
            let originalEmitter = try XCTUnwrap(hidden.components[ParticleEmitterComponent.self])
            let center = SIMD3<Float>(20, 30, 40)
            setInputs(provider, center: center, spread: 500, galaxyRadius: 1000)
            update(system, container, provider, camera: center + camera)
            XCTAssertTrue(container.children.first { $0.name == name } === hidden)
            XCTAssertTrue(!hidden.isEnabled)
            XCTAssertTrue(hidden.position == center * 0.01)
            let resizedEmitter = try XCTUnwrap(hidden.components[ParticleEmitterComponent.self])
            XCTAssertTrue(resizedEmitter.emitterShapeSize.x > originalEmitter.emitterShapeSize.x)
            XCTAssertTrue(resizedEmitter.mainEmitter.lifeSpan == originalEmitter.mainEmitter.lifeSpan)
            for bridge in container.children where bridge.name.hasPrefix("Bridge_") {
                XCTAssertTrue(bridge.isEnabled)
            }

            provider.nodes.removeAll()
            provider.projectCentroids.removeAll()
            provider.storedPositions.removeAll()
            provider.galaxySnapshots.removeAll()
            update(system, container, provider, camera: camera)
            XCTAssertTrue(container.children.isEmpty)
            XCTAssertTrue(hidden.parent == nil)

            let replacement = self.provider()
            update(system, container, replacement, camera: camera)
            let recreated = try XCTUnwrap(container.children.first { $0.name == name })
            XCTAssertTrue(recreated !== hidden)
            XCTAssertTrue(!recreated.isEnabled)
            XCTAssertTrue(recreated.components[OpacityComponent.self]?.opacity == 0)
            let restoredEmitter = try XCTUnwrap(recreated.components[ParticleEmitterComponent.self])
            XCTAssertTrue(restoredEmitter.emitterShapeSize == originalEmitter.emitterShapeSize)
            XCTAssertTrue(restoredEmitter.mainEmitter.birthRate == originalEmitter.mainEmitter.birthRate)
        }
    }
}
