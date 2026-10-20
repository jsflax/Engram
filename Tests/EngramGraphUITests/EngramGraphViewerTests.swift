import Foundation
import Testing
import Observation
import Synchronization
import simd
import EngramSceneKit
import EngramRealityKit
@testable import EngramGraphUI

@Suite @MainActor
struct EngramGraphViewerTests {
    private func memory(_ id: UUID = UUID(), content: String = "Stored memory", project: String = "project",
                        embedding: [Float]? = nil) -> EngramGraphMemory {
        EngramGraphMemory(id: id, content: content, project: project, topic: "general", importance: 2,
            createdAt: Date(timeIntervalSince1970: 10), lastAccessedAt: Date(timeIntervalSince1970: 20),
            accessCount: 3, source: "fixture", embedding: embedding)
    }
    private func snapshot(_ rows: [EngramGraphMemory], edges: [EngramGraphEdge] = [], scope: String = "scope",
                          graphID: UUID = UUID()) -> EngramGraphSnapshot {
        EngramGraphSnapshot(scopeID: scope, graphID: graphID, ownerID: UUID(), revisionID: UUID().uuidString,
            title: "Exact fixture graph", memories: rows, edges: edges,
            coverage: EngramGraphCoverage(totalMemoryCount: rows.count, totalEdgeCount: edges.count))
    }

    @Test func constructionAndInspectionNeverCreateRendererOrDiscoverAnotherGraph() throws {
        let controller = EngramGraphViewerController()
        #expect(controller.snapshot == nil)
        #expect(controller.sceneManager == nil)
        let row = memory(content: "# Existing header\nFull stored content")
        try controller.replaceSnapshot(snapshot([row]))
        controller.select(row.id)
        #expect(controller.selectedMemory?.content == row.content)
        #expect(controller.selectedMemory?.source == "fixture")
        #expect(controller.adapter.nodes.first?.label == "Existing header")
        #expect(controller.adapter.galaxySnapshots.count == 1)
        #expect(controller.adapter.galaxySnapshots.first?.id == controller.snapshot?.graphID.uuidString.lowercased())
        #expect(controller.sceneManager == nil)
    }

    @Test func projectRelationFiltersPreserveRealHubEdgesAndNebulaIdentity() throws {
        let hub = memory(project: "a"), child = memory(project: "a"), other = memory(project: "b")
        let edge = EngramGraphEdge(id: UUID(), sourceID: child.id, targetID: hub.id, relation: "part_of")
        let controller = EngramGraphViewerController()
        try controller.replaceSnapshot(snapshot([hub, child, other], edges: [edge]))
        #expect(controller.adapter.hubs == [hub.id])
        #expect(controller.adapter.nebulaClusters.count == 2)
        controller.toggleProject("b")
        #expect(controller.visibleMemoryCount == 2)
        #expect(controller.visibleEdgeCount == 1)
        controller.toggleRelation("part_of")
        #expect(controller.visibleEdgeCount == 0)
        #expect(controller.adapter.hubs.isEmpty)
        controller.toggleRelation("part_of")
        #expect(controller.adapter.edges.first?.id == edge.id)
    }

    @Test func connectedNavigationCyclesTheOriginalNeighbors() throws {
        let anchor = memory(), first = memory(), second = memory()
        let edges = [first, second].map { EngramGraphEdge(id: UUID(), sourceID: anchor.id, targetID: $0.id, relation: "relates_to") }
        let controller = EngramGraphViewerController()
        try controller.replaceSnapshot(snapshot([anchor, first, second], edges: edges))
        controller.select(anchor.id)
        controller.cycleConnectedMemory()
        let selectedFirst = controller.selectedMemoryID
        controller.cycleConnectedMemory()
        #expect(controller.selectedMemoryID != selectedFirst)
        #expect(controller.selectedMemoryID != anchor.id)
        controller.cycleConnectedMemory()
        #expect(controller.selectedMemoryID == selectedFirst)
    }

    @Test func coverageObservationFollowsCompletedFilterTopologyAndClear() throws {
        let first = memory(project: "a"), second = memory(project: "b")
        let edge = EngramGraphEdge(id: UUID(), sourceID: first.id, targetID: second.id, relation: "derived_from")
        let controller = EngramGraphViewerController()
        try controller.replaceSnapshot(snapshot([first, second], edges: [edge]))

        @MainActor func expectCoverageChange(memories: Int, edges: Int, _ change: () -> Void) {
            let notified = Atomic(false)
            // Observe exactly what coverage renders, without accidentally reading
            // the filter sets, snapshot or search state that hide this defect.
            withObservationTracking {
                _ = controller.visibleMemoryCount
                _ = controller.visibleEdgeCount
            } onChange: { notified.store(true, ordering: .sequentiallyConsistent) }
            change()
            let didNotify = notified.load(ordering: .sequentiallyConsistent)
            #expect(didNotify)
            #expect(controller.visibleMemoryCount == memories)
            #expect(controller.visibleEdgeCount == edges)
        }
        expectCoverageChange(memories: 2, edges: 0) { controller.toggleRelation("derived_from") }
        expectCoverageChange(memories: 2, edges: 1) { controller.toggleRelation("derived_from") }
        expectCoverageChange(memories: 1, edges: 0) { controller.toggleProject("b") }
        expectCoverageChange(memories: 2, edges: 1) { controller.focus(second.id) }
        expectCoverageChange(memories: 0, edges: 0) { controller.clear() }
        #expect(controller.sceneManager == nil)
    }

    @Test func sameSizeReplacementNotifiesSelectedDetailAndConnectionConsumers() throws {
        let hub = memory(content: "Original", project: "a"), child = memory(project: "a"), other = memory(project: "a")
        let edge = EngramGraphEdge(id: UUID(), sourceID: child.id, targetID: hub.id, relation: "part_of")
        let value = snapshot([hub, child, other], edges: [edge])
        let controller = EngramGraphViewerController()
        try controller.replaceSnapshot(value)
        controller.select(hub.id)
        #expect(controller.connectedCount == 1 && controller.selectionIsHub)
        let detailChanged = Atomic(false), connectionsChanged = Atomic(false), hubChanged = Atomic(false)
        withObservationTracking { _ = controller.selectedMemory?.content }
            onChange: { detailChanged.store(true, ordering: .sequentiallyConsistent) }
        withObservationTracking { _ = controller.connectedCount }
            onChange: { connectionsChanged.store(true, ordering: .sequentiallyConsistent) }
        withObservationTracking { _ = controller.selectionIsHub }
            onChange: { hubChanged.store(true, ordering: .sequentiallyConsistent) }
        let replacement = EngramGraphSnapshot(scopeID: value.scopeID, graphID: value.graphID,
            ownerID: value.ownerID, revisionID: "replacement", title: value.title,
            memories: [memory(hub.id, content: "Updated", project: "a"), child, other],
            edges: [EngramGraphEdge(id: UUID(), sourceID: child.id, targetID: other.id, relation: "relates_to")],
            coverage: value.coverage)
        try controller.replaceSnapshot(replacement)
        let didChangeDetail = detailChanged.load(ordering: .sequentiallyConsistent)
        let didChangeConnections = connectionsChanged.load(ordering: .sequentiallyConsistent)
        let didChangeHub = hubChanged.load(ordering: .sequentiallyConsistent)
        #expect(didChangeDetail)
        #expect(didChangeConnections)
        #expect(didChangeHub)
        #expect(controller.visibleMemoryCount == 3 && controller.visibleEdgeCount == 1)
        #expect(controller.selectedMemory?.content == "Updated")
        #expect(controller.connectedCount == 0 && !controller.selectionIsHub)
        #expect(controller.sceneManager == nil)
    }

    @Test func searchCoversBeyondFirstPageAndHiddenProjects() async throws {
        let rows = (0..<700).map { index in memory(content: "Entry \(index)" + (index == 699 ? " UNIQUE NEEDLE" : ""), project: index == 699 ? "hidden" : "visible") }
        let controller = EngramGraphViewerController()
        try controller.replaceSnapshot(snapshot(rows))
        controller.toggleProject("hidden")
        controller.setQuery("unique needle")
        await controller.drainRetiredWork()
        #expect(controller.searchMatches == [rows[699].id])
        #expect(controller.visibleMemoryCount == 699)
        controller.focus(rows[699].id)
        #expect(controller.visibleMemoryCount == 700)
        #expect(controller.selectedMemoryID == rows[699].id)
    }

    @Test func clearWithdrawsSelectionAndLateSearchCannotRestoreIt() async throws {
        let controller = EngramGraphViewerController()
        let rows = (0..<2_000).map { _ in memory(content: "private needle") }
        try controller.replaceSnapshot(snapshot(rows))
        controller.select(rows[0].id); controller.setQuery("needle")
        await controller.clearAndDrain()
        #expect(controller.selectedMemory == nil)
        #expect(controller.snapshot == nil)
        #expect(controller.searchMatches.isEmpty)
        #expect(controller.adapter.nodes.isEmpty)
        #expect(controller.sceneManager == nil)
        let fresh = memory(content: "different graph")
        try controller.replaceSnapshot(snapshot([fresh], scope: "replacement"))
        #expect(controller.adapter.nodes.map(\.id) == [fresh.id])
        #expect(controller.query.isEmpty)
    }

    @Test func malformedIdentityAndMissingEndpointsFailClosed() throws {
        let controller = EngramGraphViewerController(), row = memory()
        try controller.replaceSnapshot(snapshot([row]))
        let invalid = snapshot([row], edges: [EngramGraphEdge(id: UUID(), sourceID: row.id, targetID: UUID(), relation: "part_of")])
        #expect(throws: EngramGraphViewerError.self) { try controller.replaceSnapshot(invalid) }
        #expect(controller.snapshot == nil)
        #expect(throws: EngramGraphViewerError.self) { try controller.replaceSnapshot(snapshot([row, row])) }
    }

    @Test func semanticProjectionUsesOneFiniteDimensionAndDisclosesBound() {
        var rows = (0..<1_205).map { _ in memory(embedding: [1, 0, 0]) }
        rows.append(memory(embedding: [0, 1]))
        rows.append(memory(embedding: [.nan, 0, 1]))
        rows.append(memory(embedding: []))
        rows.append(memory())
        let selection = EngramGraphViewerController.semanticSelection(rows)
        #expect(selection.dimension == 3)
        #expect(selection.rows.count == 1_200)
        #expect(selection.rows.allSatisfy { $0.embedding?.count == 3 && $0.embedding!.allSatisfy(\.isFinite) })
    }

    @Test func clearingProjectionDrainsKernelAndFencesQueuedProgress() async throws {
        let controller = EngramGraphViewerController()
        let rows: [EngramGraphMemory] = (0..<200).map { (index: Int) -> EngramGraphMemory in
            let first = Float(index + 1)
            let second = Float((index * 7) % 17)
            let embedding: [Float] = [first, second, 1]
            return memory(embedding: embedding)
        }
        try controller.replaceSnapshot(snapshot(rows))
        controller.setLayout(.embedding)
        await Task.yield()
        await controller.clearAndDrain()
        await Task.yield()
        #expect(controller.snapshot == nil)
        #expect(controller.projectionProgress == nil)
        #expect(controller.adapter.semanticPositions == nil)
        #expect(controller.layout == .forceDirected)
    }

    @Test func replacingExpandedGraphAndFilteringRestoreRenderedBasePositions() {
        let hub = memory(project: "kept"), child = memory(project: "kept"), other = memory(project: "other")
        let edge = EngramGraphEdge(id: UUID(), sourceID: child.id, targetID: hub.id, relation: "part_of")
        let value = snapshot([hub, child, other], edges: [edge])
        let adapter = EngramGraphDataAdapter()
        adapter.replace(snapshot: value, hiddenProjects: [], hiddenRelations: [])
        let base: [UUID: SIMD3<Float>] = [hub.id: .zero, child.id: SIMD3(10, 20, 30), other.id: SIMD3(50, 60, 70)]
        adapter.simulation.setPositions(base)
        adapter.simulation.isActive = false
        adapter.isActive = true
        adapter.tick(dt: 0)
        adapter.toggleHub(hub.id); adapter.tick(dt: 1)
        #expect(adapter.expandedHubs == [hub.id])
        #expect(adapter.positions[child.id] != base[child.id])
        adapter.replace(snapshot: value, hiddenProjects: [], hiddenRelations: [])
        #expect(adapter.expandedHubs.isEmpty)
        #expect(adapter.hubExpansion.preExpansionPositions.isEmpty)
        #expect(adapter.positions == base)
        adapter.toggleHub(hub.id); adapter.tick(dt: 1)
        #expect(adapter.expandedHubs == [hub.id])
        adapter.replace(snapshot: value, hiddenProjects: ["other"], hiddenRelations: [])
        #expect(adapter.expandedHubs.isEmpty)
        #expect(Set(adapter.positions.keys) == [hub.id, child.id])
        #expect(adapter.positions[child.id] == base[child.id])
        #expect(adapter.positions[hub.id] == base[hub.id])
        #expect(adapter.edges.map(\.id) == [edge.id])
    }

    @Test func sharedHubAnimationRestoresOriginalPositions() {
        let hub = UUID(), child = UUID()
        let expansion = EngramGraphHubExpansionController()
        var positions: [UUID: SIMD3<Float>] = [hub: .zero, child: SIMD3(10, 20, 30)]
        let original = positions
        let edges = [(sourceId: child, targetId: hub, relation: "part_of")]
        expansion.toggleHubExpansion(hubId: hub, positions: positions, edges: edges)
        expansion.updateExpansions(dt: 1, positions: &positions, edges: edges)
        #expect(expansion.expandedHubs == [hub])
        #expect(abs(simd_length(positions[child]!) - 80) < 0.01)
        expansion.toggleHubExpansion(hubId: hub, positions: positions, edges: edges)
        expansion.updateExpansions(dt: 1, positions: &positions, edges: edges)
        #expect(expansion.expandedHubs.isEmpty)
        #expect(positions == original)
    }

    @Test func sharedKernelProducesFiniteExistingIDProjection() async {
        let ids = (0..<4).map { _ in UUID() }
        let input = EngramGraphTSNEKernel.Input(embeddings: [[1,0,0],[0.9,0.1,0],[0,1,0],[0,0,1]],
            ids: ids, perplexity: 1, maxIterations: 20, initialPositions: nil, outputDims: 3)
        let output = await EngramGraphTSNEKernel.compute(input, progress: { _ in })
        #expect(Set(output.positions.map(\.id)) == Set(ids))
        #expect(output.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(output.zValues?.allSatisfy(\.isFinite) == true)
    }

    @Test func cancelledKernelReturnsWithoutPublishingPositions() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let input = EngramGraphTSNEKernel.Input(embeddings: [[1,0],[0,1]], ids: [UUID(), UUID()],
                perplexity: 1, maxIterations: 1_000, initialPositions: nil)
            return await EngramGraphTSNEKernel.compute(input, progress: { _ in Issue.record("Cancelled projection published progress") })
        }
        #expect(await task.value.positions.isEmpty)
    }
}


extension EngramGraphViewerTests {
    @Test func initialViewportFitsWithoutMovingCameraOnKeyboardOrResize() async throws {
        let controller = EngramGraphViewerController()
        var rows: [EngramGraphMemory] = []
        for index in 0..<32 { rows.append(memory(content: "Framing fixture \(index)")) }
        try controller.replaceSnapshot(snapshot(rows))
        controller.setActive(true)
        let camera = try #require(controller.sceneManager?.camera)
        controller.setViewportSize(CGSize(width: 900, height: 450))
        let fittedRadius = camera.orbitRadius
        #expect(fittedRadius < 4200)
        camera.pan(dx: 20, dy: 10)
        let pannedTarget = camera.targetCameraPos
        controller.setViewportSize(CGSize(width: 393, height: 852))
        #expect(camera.orbitRadius == fittedRadius)
        #expect(camera.targetCameraPos == pannedTarget)
        controller.centerGraph()
        #expect(camera.orbitRadius > fittedRadius)
        #expect(camera.targetCameraPos != pannedTarget)
        await controller.clearAndDrain()
    }
}


extension EngramGraphViewerTests {
    private func framingFixture() -> EngramGraphSnapshot {
        let rows = (0..<32).map { memory(content: "Initial layout fixture \($0)") }
        return snapshot(rows)
    }

    private func publishFramingPositions(_ controller: EngramGraphViewerController, radius: Float) {
        let count = controller.adapter.simulation.nodeCount
        var positions: [SIMD3<Float>] = []
        for index in 0..<count {
            let angle = Float(index) * 2 * Float.pi / Float(count)
            positions.append(SIMD3<Float>(radius * cos(angle) + 80, radius * sin(angle) - 20, 30))
        }
        // Deliver through the actual force-result publication/revision path.
        controller.adapter.simulation.applyGPUForces(ForceResult(positions: positions))
        for _ in 0..<30 { controller.adapter.tick(dt: 1.0 / 60.0) }
    }

    private func requireVisibleProjection(_ controller: EngramGraphViewerController,
                                          viewport: CGSize, overlayBottom: CGFloat, phase: String) throws {
        let camera = try #require(controller.sceneManager?.camera)
        for _ in 0..<120 { camera.updateCamera(dt: 1.0 / 60.0) }
        #expect(!camera.isAutomaticallyFraming)
        let points = try controller.adapter.positionArray.map {
            try #require(camera.project(point3D: $0, viewSize: viewport))
        }
        #expect(points.count == 32)
        let minX = try #require(points.map(\.x).min()), maxX = try #require(points.map(\.x).max())
        let minY = try #require(points.map(\.y).min()), maxY = try #require(points.map(\.y).max())
        #expect(minX >= 0 && maxX <= viewport.width)
        #expect(minY >= overlayBottom && maxY <= viewport.height)
        let visibleHeight = viewport.height - overlayBottom
        #expect(max((maxX - minX) / viewport.width, (maxY - minY) / visibleHeight) > 0.45)
        print("INITIAL_LAYOUT_BOUNDS phase=\(phase) width=\(viewport.width) height=\(viewport.height) overlayBottom=\(overlayBottom) orbit=\(camera.orbitRadius) minX=\(minX) maxX=\(maxX) minY=\(minY) maxY=\(maxY)")
    }

    @Test("Initial framing follows expanding force results into the measured visible area",
          arguments: [CGSize(width: 900, height: 418), CGSize(width: 393, height: 852)])
    func initialExpandingAndSettledProjectedBounds(viewport: CGSize) async throws {
        let controller = EngramGraphViewerController()
        try controller.replaceSnapshot(framingFixture())
        controller.setActive(true)
        controller.setViewportSize(viewport)
        // These are synthetic measured overlay values, not production constants.
        let overlayBottom: CGFloat = viewport.width > viewport.height ? 128 : 228
        controller.setOverlayBottom(overlayBottom)
        let dictionaryBuilds = controller.adapter.work.dictionaryBuilds
        publishFramingPositions(controller, radius: 100)
        try requireVisibleProjection(controller, viewport: viewport, overlayBottom: overlayBottom, phase: "initial")
        let initialRadius = try #require(controller.sceneManager?.camera.orbitRadius)
        publishFramingPositions(controller, radius: 420)
        try requireVisibleProjection(controller, viewport: viewport, overlayBottom: overlayBottom, phase: "expanding")
        publishFramingPositions(controller, radius: 680)
        for _ in 0..<1_000 { controller.adapter.tick(dt: 1.0 / 60.0) }
        #expect(controller.adapter.simulation.isSettled)
        #expect(controller.adapter.onFramingUpdate == nil)
        try requireVisibleProjection(controller, viewport: viewport, overlayBottom: overlayBottom, phase: "settled")
        #expect((controller.sceneManager?.camera.orbitRadius ?? 0) > initialRadius * 6)
        #expect(controller.adapter.work.dictionaryBuilds == dictionaryBuilds)
        #expect(controller.adapter.work.aggregateRows == controller.adapter.work.aggregatePasses * 32 * 2)
        let aggregatePasses = controller.adapter.work.aggregatePasses
        for _ in 0..<120 { controller.adapter.tick(dt: 1.0 / 60.0) }
        #expect(controller.adapter.work.aggregatePasses == aggregatePasses)
        await controller.clearAndDrain()
    }

    @Test("Settling cannot retire framing before the final real GPU result is applied")
    func finalGPUResultIsIncludedBeforeFramingStops() async throws {
        let controller = EngramGraphViewerController()
        try controller.replaceSnapshot(framingFixture())
        controller.setActive(true)
        controller.setViewportSize(CGSize(width: 900, height: 418))
        controller.setOverlayBottom(128)
        let manager = try #require(controller.sceneManager)
        // Encode the real packaged force kernel. Its MainActor completion cannot
        // run until this synchronous settling loop yields; no timing sleep needed.
        manager.scene.onFrameCallback?(1.0 / 60.0)
        #expect(manager.hasPendingForce)
        for _ in 0..<1_000 { controller.adapter.tick(dt: 1.0 / 60.0) }
        #expect(controller.adapter.simulation.isSettled)
        #expect(controller.adapter.onFramingUpdate != nil)
        await manager.drain()
        #expect(!manager.hasPendingForce)
        #expect(manager.completedForcePassCount == 1)
        #expect(controller.adapter.framingBounds?.forceRevision != controller.adapter.simulation.positionRevision)
        controller.adapter.tick(dt: 0)
        #expect(controller.adapter.framingBounds?.forceRevision == controller.adapter.simulation.positionRevision)
        #expect(controller.adapter.onFramingUpdate == nil)
        try requireVisibleProjection(controller, viewport: CGSize(width: 900, height: 418),
                                     overlayBottom: 128, phase: "last-gpu-delivery")
        await controller.clearAndDrain()
    }

    @Test("Camera and selection intent stop initial fitting before a later force delivery",
          arguments: ["pan", "look-start", "selection", "filter", "layout", "resize", "overlay"])
    func interactionPreventsLateAutomaticCameraChanges(action: String) async throws {
        let controller = EngramGraphViewerController()
        let value = framingFixture()
        try controller.replaceSnapshot(value)
        controller.setActive(true)
        controller.setViewportSize(CGSize(width: 900, height: 418))
        controller.setOverlayBottom(128)
        publishFramingPositions(controller, radius: 100)
        let camera = try #require(controller.sceneManager?.camera)
        switch action {
        case "pan": camera.pan(dx: 23, dy: 11)
        case "look-start": _ = camera.captureLookState()
        case "selection": controller.select(value.memories[0].id)
        case "filter": controller.toggleRelation("unused relation")
        case "layout": controller.setLayout(.forceDirected)
        case "resize": controller.setViewportSize(CGSize(width: 900, height: 300))
        case "overlay": controller.setOverlayBottom(180)
        default: Issue.record("Unexpected fixture action")
        }
        #expect(controller.adapter.onFramingUpdate == nil)
        let radius = camera.orbitRadius, target = camera.targetCameraPos
        publishFramingPositions(controller, radius: 680)
        #expect(camera.orbitRadius == radius)
        #expect(camera.targetCameraPos == target)
        try controller.replaceSnapshot(value) // Same graph does not rearm camera following.
        publishFramingPositions(controller, radius: 840)
        #expect(camera.orbitRadius == radius && camera.targetCameraPos == target)
        controller.centerGraph() // Explicit Center still uses current positions and viewport.
        #expect(camera.orbitRadius > radius)
        try controller.replaceSnapshot(framingFixture()) // A new exact scope gets its own initial fit.
        #expect(controller.adapter.onFramingUpdate != nil)
        camera.pan(dx: 1, dy: 1) // A retired scene cannot cancel the successor's initial framing.
        #expect(controller.adapter.onFramingUpdate != nil)
        await controller.clearAndDrain()
    }
}


extension EngramGraphViewerTests {
    @Test("Identical final force coordinates retire framing without another aggregate pass")
    func identicalFinalDeliveryAcknowledgesBoundsWithoutRescanning() async throws {
        let controller = EngramGraphViewerController()
        try controller.replaceSnapshot(framingFixture())
        controller.setActive(true)
        controller.setViewportSize(CGSize(width: 900, height: 418))
        controller.setOverlayBottom(128)
        let simulation = controller.adapter.simulation
        let positions = simulation.nodeIds.indices.map { SIMD3(simulation.posX[$0], simulation.posY[$0], simulation.posZ[$0]) }
        // Cooling alone does not call the adapter or finish its framing callback.
        for _ in 0..<1_000 { simulation.tick() }
        #expect(simulation.isSettled)
        #expect(controller.adapter.onFramingUpdate != nil)
        let before = controller.adapter.work
        let rendered = controller.adapter.positionArray
        simulation.applyGPUForces(ForceResult(positions: positions))
        #expect(controller.adapter.framingBounds?.forceRevision != simulation.positionRevision)
        controller.adapter.tick(dt: 0)
        #expect(controller.adapter.framingBounds?.forceRevision == simulation.positionRevision)
        #expect(controller.adapter.onFramingUpdate == nil)
        #expect(controller.adapter.positionArray == rendered)
        #expect(controller.adapter.work.aggregatePasses == before.aggregatePasses)
        #expect(controller.adapter.work.dictionaryBuilds == before.dictionaryBuilds)
        await controller.clearAndDrain()
    }
}


extension EngramGraphViewerTests {
    @Test("Embedded graph hides duplicate galaxy titles and cancels a moving fit on selection")
    func embeddedTitleAndSelectionDuringFit() async throws {
        let controller = EngramGraphViewerController()
        let value = framingFixture()
        try controller.replaceSnapshot(value)
        controller.setActive(true)
        controller.setViewportSize(CGSize(width: 900, height: 418))
        controller.setOverlayBottom(120)
        let manager = try #require(controller.sceneManager)
        #expect(!manager.scene.showsGalaxyTitles)
        manager.scene.update(dt: 1.0 / 60.0)
        #expect(manager.scene.galaxyTitleContainer.children.isEmpty)
        // Opting back in uses the unchanged desktop title system and real text.
        manager.scene.showsGalaxyTitles = true
        manager.scene.update(dt: 1.0 / 60.0)
        #expect(!manager.scene.galaxyTitleContainer.children.isEmpty)
        #expect(manager.scene.galaxyTitleContainer.isEnabled)
        manager.scene.showsGalaxyTitles = false
        #expect(!manager.scene.galaxyTitleContainer.isEnabled)
        publishFramingPositions(controller, radius: 680)
        #expect(manager.camera.isAutomaticallyFraming)
        manager.camera.updateCamera(dt: 1.0 / 60.0)
        let radius = manager.camera.orbitRadius, target = manager.camera.cameraTarget
        controller.select(value.memories[0].id)
        #expect(!manager.camera.isAutomaticallyFraming)
        for _ in 0..<120 { manager.camera.updateCamera(dt: 1.0 / 60.0) }
        #expect(manager.camera.orbitRadius == radius && manager.camera.cameraTarget == target)
        await controller.clearAndDrain()
    }
}


extension EngramGraphViewerTests {
    @Test("Embedded cluster anchors fit phone and narrow Mac viewports; input still retires fitting",
          arguments: [CGSize(width: 393, height: 650), CGSize(width: 600, height: 600)])
    func clusterAnchorsAndUserCameraLifetime(viewport: CGSize) async throws {
        let rows = [memory(project: "a"), memory(project: "a"), memory(project: "b")]
        let controller = EngramGraphViewerController()
        try controller.replaceSnapshot(snapshot(rows))
        controller.setActive(true)
        let manager = try #require(controller.sceneManager)
        #expect(manager.scene.usesViewportBoundedClusterLabels)
        controller.setViewportSize(viewport); controller.setOverlayBottom(176)
        #expect(manager.scene.clusterLabelViewportSize == viewport)
        let sim = controller.adapter.simulation
        let indices = Dictionary(uniqueKeysWithValues: sim.nodeIds.enumerated().map { ($0.element, $0.offset) })
        var positions = Array(repeating: SIMD3<Float>.zero, count: rows.count)
        positions[try #require(indices[rows[0].id])] = SIMD3(-10, 0, 0)
        positions[try #require(indices[rows[1].id])] = SIMD3(10, 0, 0)
        positions[try #require(indices[rows[2].id])] = SIMD3(0, -10, 0)
        sim.applyGPUForces(ForceResult(positions: positions))
        let bounds = try #require(controller.adapter.currentFramingBounds())
        #expect(bounds.clusterAnchors.count == 3) // Two projects plus the shared two-or-more-member topic.
        let projectAnchors = bounds.clusterAnchors.filter { $0.kind == .project }.map(\.position)
        #expect(projectAnchors.contains(SIMD3(0, 40, 0)))
        #expect(projectAnchors.contains(SIMD3(0, 30, 0)))
        #expect(bounds.clusterAnchors.filter { $0.kind == .topic }.map(\.position) == [SIMD3(0, 25, 0)])
        for _ in 0..<120 { manager.camera.updateCamera(dt: 1.0 / 60.0) }
        #expect(controller.adapter.onFramingUpdate != nil)
        func requireLabelBounds(_ bounds: EngramGraphDataAdapter.FramingBounds, in viewport: CGSize) throws {
            for label in bounds.clusterAnchors {
                let point = try #require(manager.camera.project(point3D: label.position, viewSize: viewport))
                let size = label.kind.maximumPointSize(in: viewport)
                #expect(point.x - size.width / 2 >= 0 && point.x + size.width / 2 <= viewport.width)
                #expect(point.y - size.height / 2 >= 176 && point.y + size.height / 2 <= viewport.height)
            }
        }
        try requireLabelBounds(bounds, in: viewport)
        let dictionaryBuilds = controller.adapter.work.dictionaryBuilds
        let aggregatePasses = controller.adapter.work.aggregatePasses
        sim.applyGPUForces(ForceResult(positions: positions))
        _ = controller.adapter.currentFramingBounds()
        #expect(controller.adapter.work.aggregatePasses == aggregatePasses)
        #expect(controller.adapter.work.dictionaryBuilds == dictionaryBuilds)
        manager.camera.pan(dx: 7, dy: 4)
        let radius = manager.camera.orbitRadius, target = manager.camera.targetCameraPos
        sim.applyGPUForces(ForceResult(positions: positions.map { $0 * 8 }))
        let expanded = try #require(controller.adapter.currentFramingBounds())
        #expect(expanded.renderedRevision != bounds.renderedRevision)
        #expect(controller.adapter.onFramingUpdate == nil)
        #expect(manager.camera.orbitRadius == radius && manager.camera.targetCameraPos == target)
        // Mac resize updates render sizing without taking over the manual camera.
        let resized = CGSize(width: viewport.width - 40, height: viewport.height - 40)
        controller.setViewportSize(resized)
        #expect(manager.scene.clusterLabelViewportSize == resized)
        #expect(manager.camera.orbitRadius == radius && manager.camera.targetCameraPos == target)
        // An explicit Center uses the same newly measured annotation bounds.
        controller.centerGraph()
        #expect(manager.camera.targetCameraPos != target)
        for _ in 0..<120 { manager.camera.updateCamera(dt: 1.0 / 60.0) }
        try requireLabelBounds(expanded, in: resized)
        await controller.clearAndDrain()
    }
}


extension EngramGraphViewerTests {
    private func adaptiveViewportFixture() throws -> (EngramGraphViewerController, UUID) {
        let first = memory(content: "First viewport memory", project: "Memory browser review")
        let second = memory(content: "Second viewport memory", project: first.project)
        let controller = EngramGraphViewerController()
        try controller.replaceSnapshot(snapshot([first, second]))
        controller.setActive(true)
        let manager = try #require(controller.sceneManager)
        manager.scene.usesViewportBoundedClusterLabels = true
        controller.adapter.simulation.applyGPUForces(ForceResult(positions:
            controller.adapter.simulation.nodeIds.map { $0 == first.id ? SIMD3<Float>(-20, 0, 0) : SIMD3<Float>(20, 0, 0) }))
        _ = controller.adapter.currentFramingBounds()
        return (controller, first.id)
    }

    private func requireAdaptiveGraphBounds(_ controller: EngramGraphViewerController,
                                            viewport: CGSize) throws {
        let camera = try #require(controller.sceneManager?.camera)
        for _ in 0..<120 { camera.updateCamera(dt: 1.0 / 60.0) }
        let rect = try #require(controller.visibleFramingRect)
        let bounds = try #require(controller.adapter.currentFramingBounds())
        for position in controller.adapter.positionArray {
            let point = try #require(camera.project(point3D: position, viewSize: viewport))
            #expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(point))
        }
        for label in bounds.clusterAnchors {
            let point = try #require(camera.project(point3D: label.position, viewSize: viewport))
            let size = label.kind.maximumPointSize(in: viewport)
            #expect(point.x - size.width / 2 >= rect.minX - 0.01)
            #expect(point.x + size.width / 2 <= rect.maxX + 0.01)
            #expect(point.y - size.height / 2 >= rect.minY - 0.01)
            #expect(point.y + size.height / 2 <= rect.maxY + 0.01)
        }
        print("ADAPTIVE_VIEWPORT full=\(viewport) usable=\(rect) orbit=\(camera.orbitRadius) labels=\(bounds.clusterAnchors.count)")
    }

    @Test("Automatic and explicit framing follow actual top chrome and inline inspector geometry")
    func automaticViewportFitsInspectorAndLandscape() async throws {
        let (controller, id) = try adaptiveViewportFixture()
        let portrait = CGSize(width: 393, height: 700)
        controller.setViewportSize(portrait, adaptingToOcclusion: true)
        controller.setOverlayBottom(190)
        try requireAdaptiveGraphBounds(controller, viewport: portrait)
        controller.select(id)
        controller.setInspectorTop(430)
        #expect(controller.visibleFramingRect == CGRect(x: 0, y: 190, width: 393, height: 240))
        try requireAdaptiveGraphBounds(controller, viewport: portrait)
        let landscape = CGSize(width: 760, height: 280)
        controller.setViewportSize(landscape, adaptingToOcclusion: true)
        controller.setOverlayBottom(96)
        controller.setInspectorTop(nil) // Compact detail is a native sheet, not an inline panel.
        try requireAdaptiveGraphBounds(controller, viewport: landscape)
        #expect(controller.selectedMemoryID == id)
        controller.centerGraph()
        try requireAdaptiveGraphBounds(controller, viewport: landscape)
        await controller.clearAndDrain()
    }

    @Test("Manual pan and zoom retain placement through resize and selection inspector changes")
    func manualCameraSurvivesAdaptiveOcclusionUntilExplicitCenter() async throws {
        let (controller, id) = try adaptiveViewportFixture()
        let viewport = CGSize(width: 393, height: 700)
        controller.setViewportSize(viewport, adaptingToOcclusion: true)
        controller.setOverlayBottom(180)
        try requireAdaptiveGraphBounds(controller, viewport: viewport)
        let camera = try #require(controller.sceneManager?.camera)
        camera.pan(dx: 35, dy: 19)
        controller.zoom(12)
        let target = camera.targetCameraPos, radius = camera.orbitRadius
        controller.select(id)
        controller.setInspectorTop(420)
        controller.setOverlayBottom(210)
        controller.setViewportSize(CGSize(width: 760, height: 280), adaptingToOcclusion: true)
        controller.setInspectorTop(nil)
        controller.setOverlayBottom(96)
        #expect(camera.targetCameraPos == target && camera.orbitRadius == radius)
        #expect(controller.selectedMemoryID == id)
        controller.centerGraph()
        #expect(camera.targetCameraPos != target)
        try requireAdaptiveGraphBounds(controller, viewport: CGSize(width: 760, height: 280))
        await controller.clearAndDrain()
    }

    @Test("Explicit focus uses the unobscured center and a usable node scale on short viewports",
          arguments: [CGSize(width: 393, height: 700), CGSize(width: 760, height: 280)])
    func focusUsesMeasuredViewportAndRetainsSearch(viewport: CGSize) async throws {
        let (controller, id) = try adaptiveViewportFixture()
        controller.setViewportSize(viewport, adaptingToOcclusion: true)
        controller.setOverlayBottom(viewport.width > viewport.height ? 96 : 190)
        controller.setQuery("First viewport")
        await controller.drainRetiredWork()
        controller.focus(id)
        if viewport.width < viewport.height { controller.setInspectorTop(430) }
        let camera = try #require(controller.sceneManager?.camera)
        for _ in 0..<120 { camera.updateCamera(dt: 1.0 / 60.0) }
        let rect = try #require(controller.visibleFramingRect)
        let position = try #require(controller.adapter.positions[id])
        let point = try #require(camera.project(point3D: position, viewSize: viewport))
        #expect(abs(point.x - rect.midX) < 0.01 && abs(point.y - rect.midY) < 0.01)
        let top = try #require(camera.project(point3D: position + camera.up * 8, viewSize: viewport))
        let bottom = try #require(camera.project(point3D: position - camera.up * 8, viewSize: viewport))
        let diameter = abs(top.y - bottom.y)
        #expect(diameter > rect.height * 0.1 && diameter < rect.height * 0.55)
        #expect(controller.selectedMemoryID == id)
        #expect(controller.query == "First viewport" && controller.searchMatches == [id])
        print("ADAPTIVE_FOCUS viewport=\(viewport) usable=\(rect) center=\(point) diameter=\(diameter)")
        await controller.clearAndDrain()
    }

    @Test("Invalid or fully obscured geometry cannot corrupt the camera and valid geometry recovers")
    func adaptiveEmptyAndInvalidViewportPreserveCamera() async throws {
        let (controller, _) = try adaptiveViewportFixture()
        controller.setViewportSize(CGSize(width: 393, height: 700), adaptingToOcclusion: true)
        controller.setOverlayBottom(190)
        let camera = try #require(controller.sceneManager?.camera)
        for _ in 0..<120 { camera.updateCamera(dt: 1.0 / 60.0) }
        let target = camera.targetCameraPos, radius = camera.orbitRadius
        controller.setInspectorTop(CGFloat.nan)
        controller.setOverlayBottom(CGFloat.infinity)
        controller.setViewportSize(CGSize(width: 0, height: 0), adaptingToOcclusion: true)
        #expect(camera.targetCameraPos == target && camera.orbitRadius == radius)
        controller.setInspectorTop(100)
        #expect(controller.visibleFramingRect?.height == 0)
        #expect(camera.targetCameraPos == target && camera.orbitRadius == radius)
        controller.setInspectorTop(430)
        try requireAdaptiveGraphBounds(controller, viewport: CGSize(width: 393, height: 700))
        await controller.clearAndDrain()
    }
}


extension EngramGraphViewerTests {
    @Test("Same-ID label, hub and project/topic updates survive debounce in the current scene",
          arguments: ["text", "hub", "project-topic"])
    func sameSceneAtlasUpdatesAfterDebounce(kind: String) async throws {
        let first = memory(content: "Short"), second = memory(content: "Neighbor")
        let edge = EngramGraphEdge(id: UUID(), sourceID: second.id, targetID: first.id, relation: "derived_from")
        let value = snapshot([first, second], edges: [edge])
        let controller = EngramGraphViewerController()
        try controller.replaceSnapshot(value)
        controller.setActive(true)
        let manager = try #require(controller.sceneManager)
        let scene = manager.scene
        @MainActor func frame() async {
            scene.update(dt: 1.0 / 60.0)
            await manager.drain()
        }
        await frame()
        let initial = scene.renderDiagnosticSnapshot()
        #expect(initial.atlasCreations == 1)
        let oldRect = try #require(scene.labelAtlasGenerator.nodeRects[first.id])
        for _ in 0..<10 { await frame() }
        #expect(scene.renderDiagnosticSnapshot().atlasCreations == initial.atlasCreations)
        #expect(scene.renderDiagnosticSnapshot().labelMaterialAssignments == initial.labelMaterialAssignments)

        let rows = [first, second].map { row in
            EngramGraphMemory(id: row.id,
                content: kind == "text" && row.id == first.id ? String(repeating: "W", count: 40) : row.content,
                project: kind == "project-topic" ? "Updated project" : row.project,
                topic: kind == "project-topic" ? "Updated topic" : row.topic,
                importance: row.importance, createdAt: row.createdAt, lastAccessedAt: row.lastAccessedAt,
                accessCount: row.accessCount, source: row.source, embedding: row.embedding)
        }
        let updatedEdge = EngramGraphEdge(id: edge.id, sourceID: edge.sourceID, targetID: edge.targetID,
            relation: kind == "hub" ? "part_of" : edge.relation)
        let updated = EngramGraphSnapshot(scopeID: value.scopeID, graphID: value.graphID,
            ownerID: value.ownerID, revisionID: "updated", title: value.title,
            memories: rows, edges: [updatedEdge], coverage: value.coverage)
        try controller.replaceSnapshot(updated)
        #expect(controller.sceneManager === manager)
        await frame() // Consume the scene's one-frame topologyChanged flag during cooldown.
        #expect(scene.renderDiagnosticSnapshot().atlasCreations == initial.atlasCreations)
        while scene.renderDiagnosticSnapshot().frame < initial.frame + 60 { await frame() }
        #expect(scene.renderDiagnosticSnapshot().atlasCreations == initial.atlasCreations)
        await frame()
        let refreshed = scene.renderDiagnosticSnapshot()
        #expect(refreshed.atlasCreations == initial.atlasCreations + 1)
        #expect(refreshed.labelMaterialAssignments == initial.labelMaterialAssignments + 1)
        #expect(refreshed.resources["scene"] == initial.resources["scene"])
        #expect(refreshed.resources["labelAtlas"] != initial.resources["labelAtlas"])
        if kind == "project-topic" {
            #expect(scene.labelAtlasGenerator.projectRects["Updated project"] != nil)
            #expect(scene.labelAtlasGenerator.topicRects["Updated topic"] != nil)
            #expect(scene.labelAtlasGenerator.projectRects[first.project] == nil)
            #expect(scene.labelAtlasGenerator.topicRects[first.topic] == nil)
        } else {
            let rect = try #require(scene.labelAtlasGenerator.nodeRects[first.id])
            #expect(rect.u1 - rect.u0 != oldRect.u1 - oldRect.u0 || rect.v1 - rect.v0 != oldRect.v1 - oldRect.v0)
            if kind == "hub" { #expect(controller.adapter.hubs.contains(first.id)) }
        }
        for _ in 0..<75 { await frame() }
        #expect(scene.renderDiagnosticSnapshot().atlasCreations == refreshed.atlasCreations)
        #expect(scene.renderDiagnosticSnapshot().labelMaterialAssignments == refreshed.labelMaterialAssignments)
        // A new topology version with the exact same raster inputs does no native
        // texture creation or material assignment, then remains idle across frames.
        try controller.replaceSnapshot(updated)
        for _ in 0..<65 { await frame() }
        let reused = scene.renderDiagnosticSnapshot()
        #expect(reused.atlasCreations == refreshed.atlasCreations)
        #expect(reused.labelMaterialAssignments == refreshed.labelMaterialAssignments)
        #expect(reused.resources["labelAtlas"] == refreshed.resources["labelAtlas"])
        print("ATLAS_REFRESH kind=\(kind) frames=\(reused.frame) creations=\(reused.atlasCreations) materialUpdates=\(reused.labelMaterialAssignments)")
        await controller.clearAndDrain()
    }
}
