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
                        _ provider: NebulaTestProvider, camera: SIMD3<Float>) {
        system.update(container: container, dataProvider: provider, topologyChanged: false,
                      scaleFactor: 0.01, cameraPosition: camera)
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
