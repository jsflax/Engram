import Foundation
import RealityKit
import XCTest
import simd
@testable import EngramRealityKit

@MainActor
private final class MascotVisibilityProvider: SceneDataProvider {
    var nodes: [RKNodeSnapshot] = []
    var edges: [RKEdgeSnapshot] = []
    var hubs: Set<UUID> = []
    var projectColorMap: [String: SIMD3<Float>] = [:]
    var positions: [UUID: SIMD3<Float>] = [:]
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

    init(_ projects: [(String, SIMD3<Float>)]) { replace(projects) }

    func replace(_ projects: [(String, SIMD3<Float>)]) {
        nodes = projects.map { name, _ in
            RKNodeSnapshot(id: UUID(), project: name, topic: "general", label: name,
                           importance: 1, isHub: false)
        }
        projectCentroids = Dictionary(uniqueKeysWithValues: projects)
        positions = Dictionary(uniqueKeysWithValues: zip(nodes, projects).map { ($0.0.id, $0.1.1) })
        topologyVersion &+= 1
        positionVersion &+= 1
    }

    func tick(dt: Float) {}
}

@MainActor
private final class HeldMascotFactory {
    private(set) var projects: [String] = []
    private(set) var completed: Set<Int> = []
    private var replies: [Int: CheckedContinuation<Entity, Never>] = [:]

    func make(_ project: String, _ tint: SIMD3<Float>) async -> Entity {
        let index = projects.count
        projects.append(project)
        let entity = await withCheckedContinuation { replies[index] = $0 }
        completed.insert(index)
        return entity
    }

    func complete(_ index: Int, with entity: Entity) {
        replies.removeValue(forKey: index)?.resume(returning: entity)
    }

    func finish() {
        let pending = replies
        replies.removeAll()
        for reply in pending.values { reply.resume(returning: Entity()) }
    }
}

@MainActor
final class MascotVisibilityTests: XCTestCase {
    private func camera(position: SIMD3<Float> = .zero,
                        right: SIMD3<Float> = [1, 0, 0], up: SIMD3<Float> = [0, 1, 0],
                        forward: SIMD3<Float> = [0, 0, -1], fov: Float = 90,
                        orientation: MascotVisibilityCamera.FieldOfViewOrientation = .vertical,
                        viewport: SIMD2<Float> = [1000, 1000], near: Float = 0.01,
                        far: Float = .infinity) -> MascotVisibilityCamera {
        .init(position: position, right: right, up: up, forward: forward,
              fieldOfViewInDegrees: fov, fieldOfViewOrientation: orientation,
              viewportSize: viewport, near: near, far: far)
    }

    private func visible(_ center: SIMD3<Float>, radius: Float = 1,
                         camera: MascotVisibilityCamera?, retained: Bool = false) -> Bool {
        MascotVisibilityPolicy.isVisible(center: center, radius: radius, camera: camera,
                                          wasVisible: retained)
    }

    private func group(_ project: String) -> Entity {
        let entity = Entity()
        entity.name = "Mascot_\(project)"
        let model = ModelEntity(mesh: .generateSphere(radius: 1))
        model.name = "MascotModel"
        entity.addChild(model)
        entity.components.set(MascotComponent(project: project))
        return entity
    }

    private func waitFor(_ condition: @MainActor () -> Bool,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        _ = try XCTUnwrap(condition() ? true : nil, "Mascot task did not reach the expected state", file: file, line: line)
    }

    private func update(_ system: RKMascotSystem, _ container: Entity,
                        _ provider: MascotVisibilityProvider, view: MascotVisibilityCamera?,
                        dt: Float = 0.1, scale: Float = 0.01) {
        system.update(container: container, dataProvider: provider, dt: dt, scaleFactor: scale,
                      visibilityCamera: view)
    }

    func testNearVisibleAndOffscreenOrSubpixelSpheresHaveDifferentEligibility() {
        let view = camera()
        XCTAssertTrue(visible([0, 0, -10], camera: view))
        XCTAssertFalse(visible([100, 0, -10], camera: view))
        XCTAssertFalse(visible([0, 0, -10_000], camera: view))
        XCTAssertFalse(visible([0, 0, 10], camera: view))
    }

    func testSphereIntersectingViewportEdgeRemainsVisibleWhenItsCenterIsOutside() {
        let view = camera()
        XCTAssertTrue(visible([10.5, 0, -10], camera: view))
        XCTAssertTrue(visible([-10.5, 0, -10], camera: view))
        XCTAssertTrue(visible([0, 10.5, -10], camera: view))
        XCTAssertTrue(visible([0, -10.5, -10], camera: view))
        XCTAssertFalse(visible([13, 0, -10], camera: view))
        XCTAssertFalse(visible([0, -13, -10], camera: view))
    }

    func testCameraInsideAndClippingPlaneIntersectionsRemainConservative() {
        let view = camera(near: 1, far: 20)
        XCTAssertTrue(visible(.zero, camera: view))
        XCTAssertTrue(visible([0, 0, 0.5], camera: view))
        XCTAssertFalse(visible([0, 0, 3], camera: view))
        XCTAssertTrue(visible([0, 0, -20.5], camera: view))
        XCTAssertFalse(visible([0, 0, -22], camera: view))
    }

    func testVerticalAndHorizontalFieldOfViewRespectPortraitAndLandscapeAspect() {
        let landscape: SIMD2<Float> = [2000, 1000], portrait: SIMD2<Float> = [1000, 2000]
        XCTAssertTrue(visible([15, 0, -10], radius: 0.1, camera: camera(viewport: landscape)))
        XCTAssertFalse(visible([15, 0, -10], radius: 0.1, camera: camera(viewport: portrait)))
        XCTAssertFalse(visible([0, 15, -10], radius: 0.1, camera: camera(viewport: landscape)))
        XCTAssertFalse(visible([0, 15, -10], radius: 0.1, camera: camera(viewport: portrait)))
        XCTAssertFalse(visible([0, 15, -10], radius: 0.1,
                               camera: camera(orientation: .horizontal, viewport: landscape)))
        XCTAssertTrue(visible([0, 15, -10], radius: 0.1,
                              camera: camera(orientation: .horizontal, viewport: portrait)))
        XCTAssertFalse(visible([15, 0, -10], radius: 0.1,
                               camera: camera(orientation: .horizontal, viewport: portrait)))
    }

    func testProjectedSizeHysteresisAndViewportChangesControlReentry() {
        let view = camera()
        // Diameter is about 1.43 points: below the 2 point admission threshold,
        // above the 1 point retention threshold, independent of model count.
        XCTAssertFalse(visible([0, 0, -700], camera: view))
        XCTAssertTrue(visible([0, 0, -700], camera: view, retained: true))
        XCTAssertFalse(visible([0, 0, -2000], camera: view, retained: true))
        XCTAssertTrue(visible([0, 0, -200], camera: view))
        XCTAssertTrue(visible([0, 0, -700], camera: camera(viewport: [4000, 4000])))
        // At a wide-FOV edge the off-axis silhouette is much larger than
        // the on-axis diameter estimate (about 0.88 points here).
        for center: SIMD3<Float> in [[1000, 0, -100], [-1000, 0, -100],
                                     [0, 1000, -100], [0, -1000, -100]] {
            XCTAssertTrue(visible(center, camera: camera(fov: 170)))
        }
        XCTAssertTrue(visible([1000, 0, -100], camera:
            camera(fov: 170, orientation: .horizontal, viewport: [2000, 1000])))
    }

    func testTranslatedRotatedCameraUsesItsActualBasis() {
        let origin = SIMD3<Float>(100, 25, -50)
        let view = camera(position: origin, right: [0, 0, 1], forward: [1, 0, 0])
        XCTAssertTrue(visible(origin + [10, 0, 0], camera: view))
        XCTAssertFalse(visible(origin + [-10, 0, 0], camera: view))
        XCTAssertFalse(visible(origin + [10, 0, 100], camera: view))
        XCTAssertTrue(visible(origin + [10, 0, 10.5], camera: view))
    }

    func testMissingOrInvalidProjectionDoesNotHideOtherwiseUnclassifiedMascots() {
        let outside = SIMD3<Float>(1_000_000, 0, -10)
        XCTAssertTrue(visible(outside, camera: nil))
        for view in [camera(fov: 0), camera(fov: 180), camera(fov: .nan),
                     camera(viewport: [0, 1000]), camera(viewport: [1000, .nan]),
                     camera(position: [.nan, 0, 0]), camera(forward: .zero),
                     camera(right: [0, 1, 0]), camera(near: 10, far: 1)] {
            XCTAssertTrue(visible(outside, camera: view))
        }
        XCTAssertTrue(visible([.nan, 0, -10], camera: camera()))
        XCTAssertTrue(visible([0, 0, -10], radius: .nan, camera: camera()))
    }

    func testActualGroupsReevaluateCameraAndViewportWithoutChangingIdentity() async throws {
        let provider = MascotVisibilityProvider([
            ("Near", [0, -50, -10_000]), ("Offscreen", [1_000_000, -50, -10_000]),
            ("Far", [0, -50, -10_000_000]), ("Boundary", [15_000, -50, -10_000]),
        ])
        let system = RKMascotSystem(makeMascot: { [self] project, _ in group(project) })
        let container = Entity()
        update(system, container, provider, view: nil, dt: 0)
        try await waitFor { container.children.count == 4 }
        let original = Dictionary(uniqueKeysWithValues: container.children.map { ($0.name, $0) })
        let near = try XCTUnwrap(original["Mascot_Near"])
        let outside = try XCTUnwrap(original["Mascot_Offscreen"])
        let far = try XCTUnwrap(original["Mascot_Far"])
        let boundary = try XCTUnwrap(original["Mascot_Boundary"])
        update(system, container, provider, view: camera())
        XCTAssertTrue(near.isEnabled)
        XCTAssertFalse(outside.isEnabled)
        XCTAssertFalse(far.isEnabled)
        XCTAssertFalse(boundary.isEnabled)
        update(system, container, provider, view: camera(viewport: [2000, 1000]))
        XCTAssertTrue(boundary.isEnabled, "A wider actual viewport admits the same retained group")
        update(system, container, provider, view: camera(viewport: [1000, 2000]))
        XCTAssertFalse(boundary.isEnabled)
        update(system, container, provider, view: camera(position: [10_000, 0, 0]))
        XCTAssertTrue(outside.isEnabled)
        XCTAssertFalse(near.isEnabled)
        container.position = [1000, 0, 0]
        update(system, container, provider, view: camera(position: [10_000, 0, 0]))
        XCTAssertFalse(outside.isEnabled, "Eligibility includes the scene container's world transform")
        update(system, container, provider, view: camera(position: [11_000, 0, 0]))
        XCTAssertTrue(outside.isEnabled)
        let replacement = Entity()
        replacement.position = [2000, 0, 0]
        update(system, replacement, provider, view: camera(position: [11_000, 0, 0]))
        XCTAssertTrue(container.children.isEmpty)
        XCTAssertEqual(replacement.children.count, 4)
        XCTAssertFalse(outside.isEnabled, "A retained group is classified against its replacement parent")
        update(system, replacement, provider, view: camera(position: [12_000, 0, 0]))
        XCTAssertTrue(outside.isEnabled)
        for entity in replacement.children { XCTAssertTrue(original[entity.name] === entity) }
        XCTAssertEqual(system.diagnosticCounts.tracked, 4)
    }

    func testDisabledEffectsAndAuthoredBoundsAreConservativeAcrossSceneScaleChanges() async throws {
        let provider = MascotVisibilityProvider([
            ("Body", [13_000, -50, -10_000]), ("Effect", [13_000, -50, -10_000]),
        ])
        let system = RKMascotSystem(makeMascot: { [self] project, _ in
            let entity = group(project)
            if project == "Effect" {
                let effect = ModelEntity(mesh: .generateSphere(radius: 5))
                effect.name = "ConservativeEffect"
                effect.position = [-40, 0, 0]
                effect.isEnabled = false
                entity.addChild(effect)
            }
            return entity
        })
        let container = Entity()
        update(system, container, provider, view: nil, dt: 0)
        try await waitFor { container.children.count == 2 }
        let body = try XCTUnwrap(container.findEntity(named: "Mascot_Body"))
        let effectGroup = try XCTUnwrap(container.findEntity(named: "Mascot_Effect"))
        let effect = try XCTUnwrap(effectGroup.findEntity(named: "ConservativeEffect"))
        update(system, container, provider, view: camera(), dt: 0)
        XCTAssertFalse(body.isEnabled)
        XCTAssertTrue(effectGroup.isEnabled, "A currently disabled effect still contributes its conservative envelope")
        XCTAssertFalse(effect.isEnabled)
        XCTAssertEqual(effectGroup.position, SIMD3<Float>(130, 0, -100))
        update(system, container, provider, view: camera(), dt: 0, scale: 0.1)
        XCTAssertFalse(effectGroup.isEnabled,
                       "Scene scale moves the group; it must not multiply the authored child/effect radius")
        XCTAssertEqual(effectGroup.position, SIMD3<Float>(130, 0, -100),
                       "An invisible root avoids transform writes while retaining the latest logical position")
        XCTAssertEqual(effect.position, SIMD3<Float>(-40, 0, 0))
        update(system, container, provider, view: camera(position: [1300, 0, -900]), dt: 0, scale: 0.1)
        XCTAssertTrue(effectGroup.isEnabled)
        XCTAssertEqual(effectGroup.position, SIMD3<Float>(1300, 0, -1000))
        update(system, container, provider, view: camera(), dt: 0)
        XCTAssertTrue(effectGroup.isEnabled)
        XCTAssertEqual(effectGroup.position, SIMD3<Float>(130, 0, -100))
        XCTAssertTrue(container.findEntity(named: "Mascot_Effect") === effectGroup)
    }

    func testHiddenBehaviorAdvancesNormallyWhileVisualWritesAndQueueRemainRetained() async throws {
        let provider = MascotVisibilityProvider([("A", [0, -50, -10_000])])
        let id = try XCTUnwrap(provider.nodes.first?.id)
        let system = RKMascotSystem(makeMascot: { [self] project, _ in group(project) })
        let container = Entity()
        system.enqueueTask(.create(nodeId: id, position: provider.positions[id]!), for: "A")
        system.enqueueTask(.react(nodeId: id, type: .headTurn), for: "A")
        update(system, container, provider, view: camera(), dt: 0)
        try await waitFor { container.children.count == 1 }
        let entity = try XCTUnwrap(container.children.first)
        // One deterministic target avoids random patrol membership; 31 seconds
        // exceeds the existing 12...30 second idle threshold without a test-only state setter.
        update(system, container, provider, view: camera(), dt: 31)
        update(system, container, provider, view: camera(), dt: 1)
        update(system, container, provider, view: camera(), dt: 1)
        let before = system.retainedState(for: "A")
        XCTAssertEqual(before.behavior, .hover(nodeId: id, timer: 0))
        let componentBefore = try XCTUnwrap(entity.components[MascotComponent.self])
        update(system, container, provider, view: camera(forward: [0, 0, 1]), dt: 0.25)
        XCTAssertFalse(entity.isEnabled)
        let hidden = system.retainedState(for: "A")
        XCTAssertEqual(hidden.animationTime, before.animationTime + 0.25)
        XCTAssertEqual(hidden.behavior, .hover(nodeId: id, timer: 0.25))
        XCTAssertEqual(hidden.queuedTaskCount, 2)
        XCTAssertEqual(entity.components[MascotComponent.self]?.animationTime, componentBefore.animationTime)
        XCTAssertEqual(entity.components[MascotComponent.self]?.state, componentBefore.state)
        update(system, container, provider, view: camera(), dt: 0.25)
        XCTAssertTrue(entity.isEnabled)
        XCTAssertTrue(container.children.first === entity)
        XCTAssertEqual(system.retainedState(for: "A").queuedTaskCount, 2)
        XCTAssertEqual(entity.components[MascotComponent.self]?.animationTime, before.animationTime + 0.5)
        XCTAssertEqual(entity.components[MascotComponent.self]?.state, .hover(nodeId: id, timer: 0.5))
    }

    func testLateFactoryCompletionUsesLatestCameraBeforeAttaching() async throws {
        let provider = MascotVisibilityProvider([("A", [0, -50, -10_000])])
        let factory = HeldMascotFactory()
        defer { factory.finish() }
        let system = RKMascotSystem(makeMascot: factory.make)
        let container = Entity()
        update(system, container, provider, view: camera(), dt: 0)
        try await waitFor { factory.projects.count == 1 }
        update(system, container, provider, view: camera(forward: [0, 0, 1]), dt: 0)
        let entity = group("A")
        factory.complete(0, with: entity)
        try await waitFor { container.children.count == 1 }
        XCTAssertTrue(container.children.first === entity)
        XCTAssertFalse(entity.isEnabled, "Late completion must not attach an enabled group for an obsolete camera")
        update(system, container, provider, view: camera(), dt: 0)
        XCTAssertTrue(entity.isEnabled)
        XCTAssertEqual(entity.position, SIMD3<Float>(0, 0, -100))
        XCTAssertTrue(container.children.first === entity)
    }

    func testRemovedThenReaddedProjectRejectsOldCompletionWithoutClearingNewLoad() async throws {
        let provider = MascotVisibilityProvider([("A", [0, -50, -10_000])])
        let factory = HeldMascotFactory()
        defer { factory.finish() }
        let system = RKMascotSystem(makeMascot: factory.make)
        let container = Entity()
        update(system, container, provider, view: camera(), dt: 0)
        try await waitFor { factory.projects.count == 1 }
        provider.replace([])
        update(system, container, provider, view: camera(), dt: 0)
        provider.replace([("A", [0, -50, -10_000])])
        update(system, container, provider, view: camera(), dt: 0)
        try await waitFor { factory.projects.count == 2 }
        let stale = group("Stale")
        factory.complete(0, with: stale)
        try await waitFor { factory.completed.contains(0) }
        XCTAssertTrue(container.children.isEmpty)
        XCTAssertNil(stale.parent)
        XCTAssertEqual(system.diagnosticCounts.loading, 1, "An old callback cannot clear the newer load token")
        let current = group("A")
        factory.complete(1, with: current)
        try await waitFor { container.children.count == 1 }
        XCTAssertTrue(container.children.first === current)
        XCTAssertTrue(current.isEnabled)
        XCTAssertEqual(system.diagnosticCounts.loading, 0)
    }

    func testProviderReplacementRejectsOldPendingModelAndUsesNewPosition() async throws {
        let first = MascotVisibilityProvider([("A", [0, -50, -10_000])])
        let replacement = MascotVisibilityProvider([("A", [1_000_000, -50, -10_000])])
        let factory = HeldMascotFactory()
        defer { factory.finish() }
        let system = RKMascotSystem(makeMascot: factory.make)
        let container = Entity()
        update(system, container, first, view: camera(), dt: 0)
        try await waitFor { factory.projects.count == 1 }
        update(system, container, replacement, view: camera(), dt: 0)
        try await waitFor { factory.projects.count == 2 }
        let stale = group("OldProvider")
        factory.complete(0, with: stale)
        try await waitFor { factory.completed.contains(0) }
        XCTAssertNil(stale.parent)
        XCTAssertTrue(container.children.isEmpty)
        XCTAssertEqual(system.diagnosticCounts.loading, 1)
        let current = group("A")
        factory.complete(1, with: current)
        try await waitFor { container.children.count == 1 }
        XCTAssertFalse(current.isEnabled)
        update(system, container, replacement, view: camera(position: [10_000, 0, 0]), dt: 0)
        XCTAssertTrue(current.isEnabled)
        XCTAssertEqual(current.position, SIMD3<Float>(10_000, 0, -100))
        XCTAssertTrue(container.children.first === current)
    }
}
