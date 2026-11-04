import AppKit
import Foundation
import Testing
import simd
import EngramMemoryCore
@testable import EngramRealityKit
import EngramSceneKit
import EngramGraphContract
@testable import EngramGraphSurface
// Explicit imports prove the legacy public aliases exist despite the module/view name collision.
import typealias EngramGraphSurface.EngramGraphViewState
import typealias EngramGraphSurface.EngramGraphSurfaceError

@Suite("Scoped native graph session", .serialized) @MainActor
struct GraphSessionTests {
    @Test func exactIdentityScopeAndRequestGenerationFenceEveryPublication() throws {
        let identity = try makeIdentity(), session = EngramGraphSession(identity: identity)
        let first = try session.beginLoading(), current = try session.beginLoading()
        let value = try makeSnapshot(identity.scope, revision: 1, nodes: [makeNode()])
        #expect(throws: EngramGraphSurfaceError.staleRequest) { try session.apply(value, from: identity, for: first) }
        let other = try makeIdentity(connection: "other", scope: identity.scope)
        #expect(throws: EngramGraphSurfaceError.identityMismatch) { try session.apply(value, from: other, for: current) }
        let wider = try EngramGraphScope(workspaceID: "workspace", project: "project")
        #expect(throws: EngramGraphSurfaceError.identityMismatch) {
            try session.apply(makeSnapshot(wider, revision: 1, nodes: value.nodes), from: identity, for: current)
        }
        #expect(session.snapshot == nil)
        try session.apply(value, from: identity, for: current)
        #expect(session.snapshot == value)
        let duplicate = try session.beginLoading()
        #expect(throws: EngramGraphSurfaceError.staleRevision) { try session.apply(value, from: identity, for: duplicate) }
        let independent = EngramGraphSession(identity: identity)
        #expect(throws: EngramGraphSurfaceError.staleRequest) { try independent.apply(value, from: identity, for: duplicate) }
        #expect(independent.snapshot == nil)
    }

    @Test func refreshFailureAndCancellationKeepLastAuthorizedGraph() throws {
        let identity = try makeIdentity(), session = EngramGraphSession(identity: identity)
        let value = try makeSnapshot(identity.scope, revision: 1, nodes: [makeNode()])
        try session.apply(value, from: identity, for: session.beginLoading())
        let failed = try session.beginLoading()
        #expect(session.snapshot == value && session.loadState == .loading)
        try session.loadingFailed(for: failed, from: identity)
        #expect(session.snapshot == value && session.loadState == .failed)
        let cancelled = try session.beginLoading()
        session.cancelLoading(cancelled)
        #expect(throws: EngramGraphSurfaceError.staleRequest) {
            try session.apply(makeSnapshot(identity.scope, revision: 2, nodes: []), from: identity, for: cancelled)
        }
        #expect(session.snapshot == value && session.loadState == .ready)
        #expect(session.scene == nil) // No Metal/audio creation for loading or DTO publication.
    }

    @Test func revisionOnlyRefreshKeepsCachedTopologyAndLayoutWhileMetadataUpdatesDoNotRelayout() throws {
        let identity = try makeIdentity(), session = EngramGraphSession(identity: identity)
        let nodes = [makeNode(), makeNode()]
        try session.apply(makeSnapshot(identity.scope, revision: 1, nodes: nodes), from: identity, for: session.beginLoading())
        let data = session.data, positions = data.positions
        let versions = [data.nodeVersion, data.edgeVersion, data.hubVersion, data.positionVersion, data.topologyVersion]
        let order = data.simulation.nodeOrderVersion
        #expect(session.requiresForceResources)
        #expect(positions.count == 2 && positions.values.contains { $0 != .zero })
        try session.apply(makeSnapshot(identity.scope, revision: 2, nodes: nodes), from: identity, for: session.beginLoading())
        #expect([data.nodeVersion, data.edgeVersion, data.hubVersion, data.positionVersion, data.topologyVersion] == versions)
        #expect(data.simulation.nodeOrderVersion == order && data.positions == positions)
        #expect(session.requiresForceResources)
        let edited = makeNode(id: nodes[0].id, label: "Changed label", content: "Changed text")
        try session.apply(makeSnapshot(identity.scope, revision: 3, nodes: [edited, nodes[1]]), from: identity, for: session.beginLoading())
        #expect(data.nodeVersion == versions[0] + 1 && data.nodes[0].label == "Changed label")
        #expect(data.simulation.nodeOrderVersion == order && data.positions == positions)
    }

    @Test func exactEdgesDetermineHubsAndSuppliedPositionsRemainStable() throws {
        let identity = try makeIdentity(), session = EngramGraphSession(identity: identity)
        let a = makeNode(position: try .init(x: 10, y: 20, z: 30))
        let b = makeNode(position: try .init(x: -10, y: -20, z: -30))
        let edge = EngramGraphEdge(id: UUID(), sourceID: a.id, targetID: b.id, relation: "part_of")
        try session.apply(makeSnapshot(identity.scope, revision: 1, nodes: [a, b], edges: [edge]), from: identity, for: session.beginLoading())
        #expect(session.data.hubs == [b.id])
        #expect(session.data.nodes.first { $0.id == b.id }?.isHub == true)
        #expect(session.data.positions[a.id] == SIMD3(10, 20, 30))
        #expect(!session.data.needsLayout && !session.data.simulation.isActive)
        #expect(!session.requiresForceResources)
        let order = session.data.simulation.nodeOrderVersion
        let relationOnly = EngramGraphEdge(id: edge.id, sourceID: a.id, targetID: b.id, relation: "related_to")
        try session.apply(makeSnapshot(identity.scope, revision: 2, nodes: [a, b], edges: [relationOnly]), from: identity, for: session.beginLoading())
        #expect(session.data.hubs.isEmpty && session.data.simulation.nodeOrderVersion == order)
        try session.apply(makeSnapshot(identity.scope, revision: 3, nodes: [a]), from: identity, for: session.beginLoading())
        #expect(session.data.positions[b.id] == nil && session.data.edges.isEmpty)
    }

    @Test func mixedLayoutKeepsSuppliedCoordinatesAndSingletonDoesNotJumpAfterFit() throws {
        let scope = try makeIdentity().scope, data = GraphSceneData()
        let fixed = makeNode(position: try .init(x: 10, y: 20, z: 30)), automatic = makeNode()
        data.publish(try makeSnapshot(scope, revision: 1, nodes: [fixed, automatic]))
        let proposed = ForceResult(positions: data.simulation.nodeIds.map { _ in SIMD3<Float>(111, 222, 333) })
        data.simulation.applyGPUForces(data.preservingSuppliedPositions(in: proposed),
                                       expectedNodeOrderVersion: data.simulation.nodeOrderVersion)
        data.refreshPositions()
        #expect(data.positions[fixed.id] == SIMD3(10, 20, 30))
        #expect(data.positions[automatic.id] == SIMD3(111, 222, 333))

        // Removing an explicit coordinate changes the result-admission generation even though
        // node IDs, order and edge topology are unchanged.
        #expect(data.publish(try makeSnapshot(scope, revision: 2, nodes: [makeNode(id: fixed.id), automatic])))
        data.simulation.applyGPUForces(data.preservingSuppliedPositions(in: proposed),
                                       expectedNodeOrderVersion: data.simulation.nodeOrderVersion)
        data.refreshPositions()
        #expect(data.positions[fixed.id] == SIMD3(111, 222, 333))

        data.publish(try makeSnapshot(scope, revision: 3, nodes: [automatic]))
        let fittedPosition = data.positions[automatic.id]
        data.isLayoutPrepared = true; data.isActive = true
        data.tick(dt: 1 / 60)
        #expect(data.positions[automatic.id] == fittedPosition)
    }

    @Test func savedStateIsBoundedAndRestoresSelectionOnlyWithinSnapshot() throws {
        let identity = try makeIdentity(), node = makeNode()
        let state = try EngramGraphViewState(selectedNode: node.id, azimuth: 0.2, elevation: 0.3,
            target: .init(x: 1, y: 2, z: 3), orbitRadius: 500)
        let portable: EngramGraphContract.EngramGraphViewState = state
        let legacy: EngramGraphViewState = portable
        let error: EngramGraphContract.EngramGraphSurfaceError = EngramGraphSurfaceError.invalidState
        #expect(legacy == state && error == .invalidState)
        #expect(try EngramGraphViewState.decode(state.encoded()) == state)
        #expect(throws: EngramGraphSurfaceError.invalidState) {
            try EngramGraphViewState(selectedNode: nil, azimuth: .infinity, elevation: 0,
                                    target: .init(x: 0, y: 0, z: 0), orbitRadius: 10)
        }
        let decodedState = try JSONSerialization.jsonObject(with: state.encoded())
        var json = try #require(decodedState as? [String: Any])
        json["orbitRadius"] = -1
        #expect(throws: EngramGraphSurfaceError.invalidState) {
            try EngramGraphViewState.decode(JSONSerialization.data(withJSONObject: json))
        }
        #expect(throws: EngramGraphSurfaceError.invalidState) { try EngramGraphViewState.decode(Data(repeating: 32, count: 2049)) }
        let session = EngramGraphSession(identity: identity, savedState: state)
        #expect(try session.captureState().selectedNode == node.id)
        try session.apply(makeSnapshot(identity.scope, revision: 1, nodes: [node]), from: identity, for: session.beginLoading())
        #expect(session.selectedNode == node.id)
        #expect(try session.captureState().selectedNode == node.id)
        #expect(session.camera.targetCameraPos == SIMD3(1, 2, 3) && session.camera.orbitRadius == 500)
        try session.apply(makeSnapshot(identity.scope, revision: 2, nodes: []), from: identity, for: session.beginLoading())
        #expect(session.selectedNode == nil)
        #expect(try session.captureState().selectedNode == nil)
        let missing = EngramGraphSession(identity: identity, savedState: state)
        try missing.apply(makeSnapshot(identity.scope, revision: 1, nodes: []), from: identity, for: missing.beginLoading())
        #expect(try missing.captureState().selectedNode == nil)
    }

    @Test func invalidationClearsContentAndCannotBeReactivatedOrRevivedByLateLoad() throws {
        let identity = try makeIdentity(), session = EngramGraphSession(identity: identity)
        let value = try makeSnapshot(identity.scope, revision: 1, nodes: [makeNode()])
        try session.apply(value, from: identity, for: session.beginLoading())
        let late = try session.beginLoading()
        session.invalidate(); session.invalidate(); session.setVisibility(.visible)
        #expect(session.snapshot == nil && session.data.nodes.isEmpty && session.data.positions.isEmpty)
        #expect(session.loadState == .revoked && !session.isRenderingActive && !session.data.simulation.isActive)
        #expect(session.preferredContentFocusView == nil)
        #expect(throws: EngramGraphSurfaceError.revoked) { try session.apply(value, from: identity, for: late) }
        #expect(throws: EngramGraphSurfaceError.revoked) { try session.beginLoading() }
        #expect(throws: EngramGraphSurfaceError.revoked) { try session.captureState() }
    }

    /// Uses unshown AppKit windows only; it does not create a RealityScene, Metal work or a store.
    @Test func visibilityAndReattachmentFenceLateGPUPositionsAndOnlyOneSurfaceCanMount() throws {
        _ = NSApplication.shared
        let identity = try makeIdentity(), session = EngramGraphSession(identity: identity)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: window.contentView!.bounds), token = UUID()
        window.contentView = view
        defer { session.invalidate(); session.detachSurface(token); window.close() }
        try session.attachSurface(token, view: view)
        session.setVisibility(.visible)
        #expect(session.scenePreparationKey == .sceneOnly)
        try session.apply(makeSnapshot(identity.scope, revision: 1, nodes: [makeNode(), makeNode()]),
                          from: identity, for: session.beginLoading())
        #expect(session.scenePreparationKey == .forceLayout)
        #expect(session.isRenderingActive && session.data.simulation.isActive)
        #expect(session.preferredContentFocusView === view && session.scene == nil)
        #expect(throws: EngramGraphSurfaceError.alreadyMounted) { try session.attachSurface(UUID(), view: NSView()) }
        let generation = session.activityGeneration, order = session.data.simulation.nodeOrderVersion
        let oldPositions = session.data.positions
        session.setVisibility(.hidden)
        #expect(!session.data.simulation.isActive && session.preferredContentFocusView == nil)
        #expect(session.scenePreparationKey == .inactive)
        session.setVisibility(.visible)
        let changed = ForceResult(positions: [SIMD3(1, 2, 3), SIMD3(4, 5, 6)])
        session.acceptForces(changed, generation: generation, nodeOrder: order)
        #expect(session.data.positions == oldPositions)
        session.acceptForces(changed, generation: session.activityGeneration, nodeOrder: order)
        #expect(Set(session.data.positions.values.map { $0.x }) == [1, 4])
        window.contentView = nil; session.surfaceWindowChanged(token)
        #expect(!session.isRenderingActive && !session.data.simulation.isActive)
        session.detachSurface(UUID()) // A stale disappear cannot detach the current instance.
        #expect(session.isMounted)
        session.detachSurface(token)
        #expect(!session.isMounted)
    }
    @Test(arguments: [false, true])
    func initialAutomaticCameraContainsMovingBoundsThenStopsAtSettlement(portrait: Bool) async throws {
        let fixture = try await makeInitialCameraFixture(portrait: portrait)
        let session = fixture.session
        defer { session.detachSurface(fixture.mount); withExtendedLifetime(fixture.window) {} }
        var saves = 0
        session.onStateChange = { _, _ in saves += 1 }
        session.acceptLabelLayout(fixture.layout)
        let seeded = try session.captureState()
        let order = session.data.simulation.nodeOrderVersion
        let generation = session.activityGeneration
        session.acceptForces(ForceResult(positions: [SIMD3(2000, 100, 0), SIMD3(2040, 120, 5), SIMD3(2020, 80, 10)]),
                             generation: generation, nodeOrder: order)
        session.acceptForces(ForceResult(positions: [SIMD3(-4000, -200, 0), SIMD3(-3900, -150, 20), SIMD3(-3950, -250, 40)]),
                             generation: generation, nodeOrder: order)
        #expect(try session.captureState() == seeded) // Deliveries coalesce at the existing frame boundary.
        session.refineInitialCamera()
        let moving = try session.captureState()
        #expect(moving != seeded)
        expectInitialGraphInsideCamera(session, layout: fixture.layout, size: fixture.size)
        session.refineInitialCamera()
        #expect(try session.captureState() == moving) // No repeated work for an unchanged position revision.

        // Exercise the real alpha/settlement state without preparing a GPU or renderer.
        session.data.isLayoutPrepared = true
        for _ in 0..<1200 where !session.data.simulation.isSettled { session.data.tick(dt: 1 / 60) }
        #expect(session.data.simulation.isSettled)
        session.refineInitialCamera()
        let settled = try session.captureState()
        #expect(settled.orbitRadius <= moving.orbitRadius)
        expectInitialGraphInsideCamera(session, layout: fixture.layout, size: fixture.size)
        session.updateViewport(CGSize(width: 200, height: 300)); session.updateHeaderHeight(90)
        session.refineInitialCamera()
        #expect(try session.captureState() == settled) // Later resize retains the completed camera.
        #expect(saves == 0 && session.scene == nil)
    }

    @Test(arguments: ["restored", "drag", "scroll", "keyboard", "fit"])
    func userOrRestoredCameraPermanentlyEndsInitialTracking(control: String) async throws {
        let saved = control == "restored" ? (try EngramGraphViewState(selectedNode: nil, azimuth: 0.2,
            elevation: 0.3, target: .init(x: 50, y: 60, z: 70), orbitRadius: 800)) : nil
        let fixture = try await makeInitialCameraFixture(saved: saved)
        let session = fixture.session
        defer { session.detachSurface(fixture.mount); withExtendedLifetime(fixture.window) {} }
        session.acceptLabelLayout(fixture.layout)
        switch control {
        case "drag": session.drag(dx: 20, dy: 10); session.endDrag()
        case "scroll": session.camera.pan(dx: 20, dy: 10)
        case "keyboard": session.camera.heldKeys.insert("d"); session.camera.pollKeyboard(dt: 0.1)
        case "fit": session.fitGraph()
        default: break
        }
        let owned = try session.captureState()
        session.acceptForces(ForceResult(positions: [SIMD3(5000, 100, 0), SIMD3(5040, 120, 5), SIMD3(5020, 80, 10)]),
                             generation: session.activityGeneration, nodeOrder: session.data.simulation.nodeOrderVersion)
        session.refineInitialCamera()
        session.finishInitialLayout()
        session.updateViewport(CGSize(width: 200, height: 300))
        #expect(try session.captureState() == owned)
        #expect(session.scene == nil)
    }

    @Test(arguments: [false, true])
    func unavailableForceFallbackOnlyResumesAnUntouchedAutomaticCamera(userTookControl: Bool) async throws {
        let fixture = try await makeInitialCameraFixture()
        let session = fixture.session
        defer { session.detachSurface(fixture.mount); withExtendedLifetime(fixture.window) {} }
        session.acceptLabelLayout(fixture.layout)
        // This is the same completion path used by a known nil force-preparation result.
        session.finishInitialLayout(staticFallback: true)
        let fallback = try session.captureState()
        session.updateViewport(CGSize(width: 500, height: 700))
        session.refineInitialCamera()
        #expect(try session.captureState() == fallback)
        if userTookControl { session.fitGraph() }
        let beforeRecovery = try session.captureState()
        session.resumeInitialLayoutAfterStaticFallback()
        session.acceptForces(ForceResult(positions: [SIMD3(-5000, 100, 0), SIMD3(-5040, 120, 5), SIMD3(-5020, 80, 10)]),
                             generation: session.activityGeneration, nodeOrder: session.data.simulation.nodeOrderVersion)
        session.refineInitialCamera()
        let recovered = try session.captureState()
        if userTookControl { #expect(recovered == beforeRecovery) }
        else {
            #expect(recovered != beforeRecovery)
            expectInitialGraphInsideCamera(session, layout: fixture.layout, size: CGSize(width: 500, height: 700))
        }
        #expect(session.scene == nil)
    }

    @Test(arguments: [false, true])
    func compactFitContainsRenderedNodeAndLabelExtentsInActualViewport(portrait: Bool) async throws {
        let identity = try makeIdentity(), session = EngramGraphSession(identity: identity)
        let (window, mount) = try mountForFit(session)
        defer { session.detachSurface(mount); withExtendedLifetime(window) {} }
        let nodes = [makeNode(label: "A memory label wider than its node", position: try .init(x: -12, y: 0, z: 0)),
                     makeNode(label: "Second memory", position: try .init(x: 12, y: 3, z: 0)),
                     makeNode(label: "Third memory", position: try .init(x: 0, y: -7, z: 8))]
        let edge = EngramGraphEdge(id: UUID(), sourceID: nodes[0].id, targetID: nodes[2].id, relation: "part_of")
        try session.apply(makeSnapshot(identity.scope, revision: 1, nodes: nodes, edges: [edge]),
                          from: identity, for: session.beginLoading())
        #expect(session.camera.orbitRadius == 4800) // No invented viewport or GPU creation.
        session.updateViewport(CGSize(width: 0, height: 0))
        #expect(session.camera.orbitRadius == 4800)
        let size = portrait ? CGSize(width: 420, height: 720) : CGSize(width: 1100, height: 420)
        let positions = session.data.positions
        session.updateViewport(size)
        #expect(session.camera.orbitRadius == 4800) // Wait for actual header layout as well.
        session.updateHeaderHeight(60)
        #expect(session.camera.orbitRadius == 4800) // No synchronous text measurement on Main.
        var savedChanges = 0
        session.onStateChange = { _, _ in savedChanges += 1 }
        if portrait { session.fitGraph() } // An explicit pending Fit survives another geometry callback.
        session.updateViewport(size)
        let atlasInput = AtlasRequest(nodes: session.data.nodes, hubs: session.data.hubs,
            projects: ["project"], topics: ["architecture"])
        let rasterValue = await Task.detached { AtlasRasterizer.render(atlasInput) }.value
        let raster = try #require(rasterValue)
        let layout = try #require(raster.layout)
        session.acceptLabelLayout(layout)
        #expect(session.camera.orbitRadius < 4800 && session.scene == nil)
        #expect(savedChanges == (portrait ? 1 : 0))
        #expect(session.data.positions == positions)
        let camera = session.camera.state
        let matrix = camera.projectionMatrix(aspect: Float(size.width / size.height)) * camera.viewMatrix()
        func inside(_ point: SIMD3<Float>) {
            let scaled = point * camera.scaleFactor
            let clip = matrix * SIMD4(scaled.x, scaled.y, scaled.z, 1)
            #expect(clip.w > 0)
            #expect(abs(clip.x / clip.w) <= 1 - 64 / Float(size.width) + 0.0001)
            #expect(abs(clip.y / clip.w) <= 1 - 184 / Float(size.height) + 0.0001)
        }
        // Independently project rendered rectangle corners from real raster UVs;
        // this checks the fit result rather than repeating its distance calculation.
        func label(_ anchor: SIMD3<Float>, _ rect: EngramRealityKit.AtlasRect, height: Float) {
            let width = height * (rect.u1 - rect.u0) / (rect.v1 - rect.v0) * raster.aspectCorrection
            for x in [Float(-1), 1] {
                for y in [Float(-1), 1] { inside(anchor + camera.right * (x * width) + camera.up * (y * height)) }
            }
        }
        for node in session.data.nodes {
            let position = try #require(positions[node.id]), rect = try #require(raster.nodeRects[node.id])
            let radius: Float = node.isHub ? 12 : 8
            for x in [Float(-1), 1] {
                for y in [Float(-1), 1] {
                    for z in [Float(-1), 1] {
                        inside(position + (camera.right * x + camera.up * y - camera.forward * z) * radius)
                    }
                }
            }
            label(position + SIMD3<Float>(0, 12, 0), rect, height: node.isHub ? 2.5 : 2)
        }
        let center = positions.values.reduce(SIMD3<Float>.zero, +) / 3
        let projectRect = try #require(raster.projectRects["project"])
        let topicRect = try #require(raster.topicRects["architecture"])
        label(SIMD3<Float>(center.x, 43, center.z), projectRect, height: 4)
        label(SIMD3<Float>(center.x, 28, center.z), topicRect, height: 3)
        let fitted = try session.captureState()
        session.updateViewport(CGSize(width: 200, height: 300))
        session.updateHeaderHeight(90)
        let resized = try session.captureState()
        #expect(resized == fitted) // Resize does not override the retained camera.
        session.fitGraph()
        #expect(session.camera.orbitRadius > Float(fitted.orbitRadius))
        #expect(session.data.positions == positions && session.identity == identity)
    }

    @Test func compactViewportNeverReplacesRestoredScopeCameraWithoutExplicitFit() async throws {
        let identity = try makeIdentity(), node = makeNode(position: try .init(x: 0, y: 0, z: 0))
        let saved = try EngramGraphViewState(selectedNode: node.id, azimuth: 0.2, elevation: 0.3,
            target: .init(x: 100, y: 200, z: 300), orbitRadius: 700)
        let session = EngramGraphSession(identity: identity, savedState: saved)
        let (window, mount) = try mountForFit(session)
        defer { session.detachSurface(mount); withExtendedLifetime(window) {} }
        let restored = try session.captureState()
        session.updateViewport(CGSize(width: 700, height: 500))
        try session.apply(makeSnapshot(identity.scope, revision: 1, nodes: [node]), from: identity, for: session.beginLoading())
        session.updateViewport(CGSize(width: 300, height: 700))
        session.updateHeaderHeight(70)
        let atlasInput = AtlasRequest(nodes: session.data.nodes, hubs: [], projects: ["project"], topics: ["architecture"])
        let rasterValue = await Task.detached { AtlasRasterizer.render(atlasInput) }.value
        let raster = try #require(rasterValue)
        let layout = try #require(raster.layout)
        session.acceptLabelLayout(layout)
        session.updateDetailHeight(500, for: UUID()) // Late measurement from an old card is ignored.
        let beforeDetail = try session.captureState()
        #expect(beforeDetail == restored)
        session.updateDetailHeight(180, for: node.id)
        let afterReadAndResize = try session.captureState()
        #expect(afterReadAndResize == restored)
        session.fitGraph()
        #expect(session.camera.targetCameraPos != SIMD3(100, 200, 300))
        let camera = session.camera.state
        let matrix = camera.projectionMatrix(aspect: Float(300) / 700) * camera.viewMatrix()
        let rect = try #require(raster.projectRects["project"])
        let width = 4 * (rect.u1 - rect.u0) / (rect.v1 - rect.v0) * raster.aspectCorrection
        for x in [Float(-1), 1] {
            for y in [Float(-1), 1] {
                let point = (SIMD3<Float>(0, 40, 0) + camera.right * (x * width) + camera.up * (y * 4)) * camera.scaleFactor
                let clip = matrix * SIMD4(point.x, point.y, point.z, 1)
                #expect(clip.w > 0 && abs(clip.y / clip.w) <= 1 - Float(424) / 700 + 0.0001)
            }
        }
        #expect(session.camera.targetAzimuth == Float(saved.azimuth) && session.camera.targetElevation == Float(saved.elevation))
        #expect(session.identity == identity && session.snapshot?.scope == identity.scope && session.scene == nil)
    }

    @Test(arguments: ["graph", "camera", "hidden", "revoked"])
    func delayedAtlasFitCannotOverrideNewGraphCameraOrLifetime(change: String) async throws {
        let identity = try makeIdentity(), session = EngramGraphSession(identity: identity)
        let (window, mount) = try mountForFit(session)
        defer { session.detachSurface(mount); withExtendedLifetime(window) {} }
        let node = makeNode(label: "Original", position: try .init(x: 0, y: 0, z: 0))
        try session.apply(makeSnapshot(identity.scope, revision: 1, nodes: [node]), from: identity, for: session.beginLoading())
        session.updateViewport(CGSize(width: 600, height: 500)); session.updateHeaderHeight(60)
        session.fitGraph() // Retained request waits for the existing atlas publication.
        let input = AtlasRequest(nodes: session.data.nodes, hubs: [], projects: ["project"], topics: ["architecture"])
        let value = await Task.detached { AtlasRasterizer.render(input) }.value
        let raster = try #require(value)
        let layout = try #require(raster.layout)
        switch change {
        case "graph":
            let replacement = makeNode(label: "Replacement", position: try .init(x: 300, y: 0, z: 0))
            try session.apply(makeSnapshot(identity.scope, revision: 2, nodes: [replacement]), from: identity, for: session.beginLoading())
        case "camera":
            session.drag(dx: 20, dy: 10) // Real existing interaction cancels pending automatic Fit.
            session.endDrag()
        case "hidden": session.setVisibility(.hidden)
        default: session.invalidate()
        }
        let before = session.camera.state
        session.acceptLabelLayout(layout) // Deliberately late, even if a worker ignored cancellation.
        let after = session.camera.state
        #expect(after.azimuth == before.azimuth && after.elevation == before.elevation)
        #expect(after.cameraTarget == before.cameraTarget && after.orbitRadius == before.orbitRadius)
        #expect(session.scene == nil)
    }

}

@MainActor
private func makeInitialCameraFixture(saved: EngramGraphViewState? = nil, portrait: Bool = false) async throws
    -> (session: EngramGraphSession, window: NSWindow, mount: UUID, layout: RKLabelLayout, size: CGSize) {
    let identity = try makeIdentity(), session = EngramGraphSession(identity: identity, savedState: saved)
    let (window, mount) = try mountForFit(session)
    let nodes = [makeNode(label: "A label wider than its memory"), makeNode(label: "Second memory"), makeNode(label: "Third memory")]
    try session.apply(makeSnapshot(identity.scope, revision: 1, nodes: nodes), from: identity, for: session.beginLoading())
    let size = portrait ? CGSize(width: 420, height: 720) : CGSize(width: 1100, height: 420)
    session.updateViewport(size); session.updateHeaderHeight(60)
    let input = AtlasRequest(nodes: session.data.nodes, hubs: [], projects: ["project"], topics: ["architecture"])
    let rasterValue = await Task.detached { AtlasRasterizer.render(input) }.value
    let raster = try #require(rasterValue), layout = try #require(raster.layout)
    return (session, window, mount, layout, size)
}

@MainActor
private func expectInitialGraphInsideCamera(_ session: EngramGraphSession, layout: RKLabelLayout, size: CGSize) {
    let camera = session.camera.state
    let matrix = camera.projectionMatrix(aspect: Float(size.width / size.height)) * camera.viewMatrix()
    func inside(_ point: SIMD3<Float>) {
        let scaled = point * camera.scaleFactor
        let clip = matrix * SIMD4(scaled.x, scaled.y, scaled.z, 1)
        #expect(clip.w > 0)
        #expect(abs(clip.x / clip.w) <= 1 - 64 / Float(size.width) + 0.0001)
        #expect(abs(clip.y / clip.w) <= 1 - 184 / Float(size.height) + 0.0001)
    }
    func label(_ anchor: SIMD3<Float>, aspect: Float?, height: Float) {
        guard let aspect else { return }
        for x in [Float(-1), 1] {
            for y in [Float(-1), 1] { inside(anchor + camera.right * (x * height * aspect) + camera.up * (y * height)) }
        }
    }
    for node in session.data.nodes {
        guard let position = session.data.positions[node.id] else { Issue.record("Missing rendered position"); continue }
        for x in [Float(-1), 1] {
            for y in [Float(-1), 1] {
                for z in [Float(-1), 1] { inside(position + (camera.right * x + camera.up * y - camera.forward * z) * 8) }
            }
        }
        label(position + SIMD3(0, 12, 0), aspect: layout.nodeAspects[node.id], height: 2)
    }
    let positions = Array(session.data.positions.values)
    guard let top = positions.map(\.y).max(), !positions.isEmpty else { Issue.record("Missing graph bounds"); return }
    let center = positions.reduce(SIMD3<Float>.zero, +) / Float(positions.count)
    label(SIMD3(center.x, top + 40, center.z), aspect: layout.projectAspects["project"], height: 4)
    label(SIMD3(center.x, top + 25, center.z), aspect: layout.topicAspects["architecture"], height: 3)
}

@MainActor
private func mountForFit(_ session: EngramGraphSession) throws -> (NSWindow, UUID) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.borderless],
                          backing: .buffered, defer: true)
    let view = NSView(frame: window.contentView!.bounds), token = UUID()
    window.contentView = view
    session.setVisibility(.visible)
    try session.attachSurface(token, view: view)
    return (window, token)
}

private func makeIdentity(connection: String = "connection", scope: EngramGraphScope? = nil) throws -> EngramGraphSessionIdentity {
    try .init(connectionID: connection, documentID: "document", documentLifetimeID: "lifetime", instanceID: "instance",
              scope: scope ?? EngramGraphScope(workspaceID: "workspace", project: "project", topics: ["architecture"]))
}
private func makeNode(id: UUID = UUID(), label: String = "Memory", content: String = "Content",
                      position: EngramGraphPosition? = nil) -> EngramGraphNode {
    .init(id: id, project: "project", topic: "architecture", label: label, content: content,
          importance: 3, isHub: false, position: position)
}
private func makeSnapshot(_ scope: EngramGraphScope, revision: UInt64, nodes: [EngramGraphNode],
                          edges: [EngramGraphEdge] = []) throws -> EngramGraphSnapshot {
    try .init(scope: scope, revision: revision, completeness: .complete, nodes: nodes, edges: edges)
}
