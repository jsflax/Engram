import Testing
import Foundation
import Metal
import RealityKit
import simd
import EngramSceneKit
import EngramMetalShaders
@testable import EngramRealityKit

@MainActor private final class EmbeddedFixtureGraph: SceneDataProvider {
    let id = UUID()
    var ticks = 0
    var nodes: [RKNodeSnapshot] { [.init(id: id, project: "Owned fixture", topic: "Synthetic", label: "Fixture", importance: 3, isHub: false)] }
    var edges: [RKEdgeSnapshot] { [] }
    var hubs: Set<UUID> { [] }
    var projectColorMap: [String: SIMD3<Float>] { ["Owned fixture": SIMD3(0, 0.8, 1)] }
    var positions: [UUID: SIMD3<Float>] { [id: .zero] }
    var glowingNodes: [UUID: Float] { [:] }
    var newNodeGlows: [UUID: Float] { [:] }
    var dyingNodes: Set<UUID> { [] }
    var selectedNode: UUID?
    var expandedHubs: Set<UUID> { [] }
    var searchMatchIds: Set<UUID> { [] }
    var isSearchActive: Bool { false }
    var projectCentroids: [String: SIMD3<Float>] { ["Owned fixture": .zero] }
    var topologyVersion: UInt64 { 1 }
    func tick(dt: Float) { ticks += 1 }
}

@MainActor private final class HeldMascot {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var finishWaiter: CheckedContinuation<Entity, Never>?
    func load() async -> Entity {
        await withCheckedContinuation { continuation in
            finishWaiter = continuation; started = true
            startWaiter?.resume(); startWaiter = nil
        }
    }
    func waitForStart() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() { finishWaiter?.resume(returning: Entity()); finishWaiter = nil }
}

@MainActor private final class ForceCompletionProbe {
    var resultSeen = false
    var settledAfterResult = false
    var settledCount = 0
    var command: MTLCommandBuffer?
}

@MainActor private final class MascotStartProbe { var calls = 0 }


@MainActor private final class EdgeTextureFixtureGraph: SceneDataProvider {
    let a = UUID(), b = UUID(), c = UUID()
    var showsNodes = true
    var colorMultiplier: Float = 1
    var positionShift: Float = 0
    var nodes: [RKNodeSnapshot] { showsNodes ? [
        .init(id: a, project: "Red", topic: "Fixture", label: "A", importance: 3, isHub: false),
        .init(id: b, project: "Green", topic: "Fixture", label: "B", importance: 3, isHub: false),
        .init(id: c, project: "Blue", topic: "Fixture", label: "C", importance: 3, isHub: false)
    ] : [] }
    var edges: [RKEdgeSnapshot] = []
    var hubs: Set<UUID> { [] }
    var projectColorMap: [String: SIMD3<Float>] {
        ["Red": SIMD3(colorMultiplier, 0, 0), "Green": SIMD3(0, colorMultiplier, 0), "Blue": SIMD3(0, 0, colorMultiplier)]
    }
    var positions: [UUID: SIMD3<Float>] { [a: SIMD3(-10 + positionShift, 0, 0), b: SIMD3(positionShift, 10, 0), c: SIMD3(10 + positionShift, 0, 0)] }
    var glowingNodes: [UUID: Float] = [:]
    var newNodeGlows: [UUID: Float] = [:]
    var dyingNodes: Set<UUID> { [] }
    var selectedNode: UUID?
    var expandedHubs: Set<UUID> { [] }
    var searchMatchIds: Set<UUID> = []
    var isSearchActive = false
    var projectCentroids: [String: SIMD3<Float>] { [:] }
    var topologyVersion: UInt64 = 1
    func tick(dt: Float) {}
    init(count: Int) {
        edges = (0..<count).map { slot in
            // Unique colors on both sides of the row boundary and at the end
            // distinguish a correct second-row upload from row-zero aliasing.
            let source = slot == 8192 ? b : (slot == count - 1 ? c : a)
            return .init(id: UUID(), sourceId: source, targetId: source == c ? a : c, relation: "fixture")
        }
    }
}

@Suite("Embedded Engram renderer lifetime", .serialized) @MainActor
struct EmbeddedRendererLifecycleTests {
    @Test(.timeLimit(.minutes(1)), arguments: [3, 4, 8000, 16384])
    @available(macOS 26, iOS 26, *)
    func sameCommandGPUTransformsInitializeFullCapacityAndPreservePairing(capacity: Int) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let data = try LowLevelInstanceData(instanceCount: 0, instanceCapacity: capacity)
        let collapsed = simd_float4x4(diagonal: SIMD4<Float>(0, 0, 0, 1))
        // Establish the actual public CPU span at the production capacities.
        // Only callback-provided indices are written; no draw is attached here.
        var initialSpan = -1
        data.replaceMutableTransforms { destination in
            initialSpan = destination.count
            for index in destination.indices { destination[index] = collapsed }
        }
        #expect(initialSpan == capacity && data.instanceCount == 0)
        print("ENGRAM_INSTANCE_SPAN capacity=\(capacity) count=0 callback=\(initialSpan)")
        let texture = try LowLevelTexture(descriptor: .init(textureType: .type2D,
            pixelFormat: .rgba16Float, width: 4, height: 1, textureUsage: [.shaderRead]))
        let mesh = MeshResource.generateBox(size: 0.01)
        let entity = ModelEntity(mesh: mesh, materials: [SimpleMaterial()])
        entity.components.set(try MeshInstancesComponent(mesh: mesh, instances: data))
        let retainedPart = try #require(entity.components[MeshInstancesComponent.self]?[partIndex: 0]?.data)
        let pool = TextureUploadStagingPool(), state = InstanceUploadState()
        let colors = [SIMD4<Float16>(1, 0, 0, 0.25), SIMD4<Float16>(0, 1, 0, 0.5), .zero, .zero]

        @MainActor func uploadAndRead(_ transforms: [simd_float4x4], colors: [SIMD4<Float16>]) async throws
            -> (matrices: [simd_float4x4], colors: [SIMD4<Float16>], completionOwnsLease: Bool) {
            let slot = try #require(pool.reserve())
            var completionOwnsLease = false
            defer { if !completionOwnsLease { slot.release() } }
            let command = try #require(queue.makeCommandBuffer())
            defer { if command.status == .notEnqueued { command.commit() } }
            completionOwnsLease = try #require(state.publish(transforms: transforms, colors: colors,
                entity: entity, data: data, texture: texture, device: device, command: command, upload: slot))
            let transformBytes = capacity * MemoryLayout<simd_float4x4>.stride
            let matrices = try #require(device.makeBuffer(length: transformBytes, options: .storageModeShared))
            let pixels = try #require(device.makeBuffer(length: 256, options: .storageModeShared))
            let source = data.read(using: command)
            let blit = try #require(command.makeBlitCommandEncoder())
            blit.copy(from: source, sourceOffset: 0, to: matrices, destinationOffset: 0, size: transformBytes)
            blit.copy(from: texture.read(), sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: .init(x: 0, y: 0, z: 0), sourceSize: .init(width: 4, height: 1, depth: 1),
                to: pixels, destinationOffset: 0, destinationBytesPerRow: 256, destinationBytesPerImage: 256)
            blit.endEncoding()
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                command.addCompletedHandler { _ in done.resume() }; command.commit()
            }
            #expect(command.status == .completed)
            #expect(data.instanceCount == transforms.count && retainedPart.instanceCount == transforms.count)
            return (Array(UnsafeBufferPointer(start: matrices.contents().assumingMemoryBound(to: simd_float4x4.self), count: capacity)),
                Array(UnsafeBufferPointer(start: pixels.contents().assumingMemoryBound(to: SIMD4<Float16>.self), count: 4)), completionOwnsLease)
        }
        var first = matrix_identity_float4x4, second = matrix_identity_float4x4
        first.columns.3 = SIMD4(11, 12, 13, 1); second.columns.3 = SIMD4(21, 22, 23, 1)
        let initial = try await uploadAndRead([first, second], colors: colors)
        #expect(Array(initial.matrices.prefix(2)) == [first, second])
        #expect(initial.matrices.dropFirst(2).allSatisfy { $0 == collapsed })
        #expect(initial.colors == colors && initial.completionOwnsLease)
        first.columns.3.x = 91
        let moved = try await uploadAndRead([first, second], colors: colors)
        #expect(moved.matrices[0] == first && moved.matrices[1] == second)
        #expect(moved.colors == colors && moved.completionOwnsLease)
        #expect(state.statistics == .init(transforms: 2, colors: 1, counts: 1))
        let reduced = try await uploadAndRead([first], colors: colors)
        #expect(reduced.matrices[0] == first && reduced.matrices.dropFirst().allSatisfy { $0 == collapsed })
        #expect(reduced.colors == colors)
        state.hide(data)
        let restored = try await uploadAndRead([first], colors: colors)
        #expect(restored.matrices == reduced.matrices && restored.colors == colors)
        #expect(!restored.completionOwnsLease)
        #expect(state.statistics == .init(transforms: 3, colors: 1, counts: 4))
        let recolored = try await uploadAndRead([first], colors: Array(colors.reversed()))
        #expect(recolored.matrices == reduced.matrices && recolored.colors == Array(colors.reversed()))
        #expect(recolored.completionOwnsLease)
        #expect(state.statistics == .init(transforms: 3, colors: 2, counts: 4))
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["node", "edge"])
    @available(macOS 26, iOS 26, *)
    func unchangedInstancePayloadAvoidsWritesAndTracksVisibleChanges(path: String) async throws {
        let scene = try EngramRealityScene.makeValidated(requireMascot: false)
        defer { scene.teardown() }
        scene.lodSystem.maxNodeInstances = 4
        scene.lodSystem.maxEdgeInstances = 4
        let graph = EdgeTextureFixtureGraph(count: 3)
        let isNode = path == "node"
        let collapsed = simd_float4x4(diagonal: SIMD4<Float>(0, 0, 0, 1))
        @MainActor func stats() -> InstanceUploadState.Statistics {
            isNode ? scene.nodeBatchSystem.instanceUploadStatistics : scene.edgeBatchSystem.instanceUploadStatistics
        }
        @MainActor func update(_ indices: [Int], scale: Float = 1) async throws -> ([simd_float4x4], [SIMD4<Float16>]) {
            let command = try #require(scene.commandQueue.makeCommandBuffer())
            if isNode {
                scene.nodeBatchSystem.update(scene: scene, dataProvider: graph,
                    visibleSet: .init(nearNodes: indices), topologyChanged: false,
                    animationTime: Float(stats().transforms + 1), scaleFactor: scale, commandBuffer: command)
            } else {
                scene.edgeBatchSystem.update(scene: scene, dataProvider: graph,
                    visibleSet: .init(visibleEdgeIndices: indices), topologyChanged: false,
                    scaleFactor: scale, commandBuffer: command)
            }
            let data = try #require(isNode ? scene.nodeInstanceData : scene.edgeInstanceData)
            let texture = try #require(isNode ? scene.nodeInstanceTexture : scene.edgeInstanceTexture)
            let width = texture.descriptor.width, height = texture.descriptor.height
            let rowBytes = width * MemoryLayout<SIMD4<Float16>>.stride
            let bytes = try #require(scene.device.makeBuffer(length: rowBytes * height, options: .storageModeShared))
            let blit = try #require(command.makeBlitCommandEncoder())
            blit.copy(from: texture.read(), sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: .init(x: 0, y: 0, z: 0), sourceSize: .init(width: width, height: height, depth: 1),
                to: bytes, destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height)
            blit.endEncoding()
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                command.addCompletedHandler { _ in done.resume() }; command.commit()
            }
            #expect(command.status == .completed)
            var transforms: [simd_float4x4] = []
            data.withTransforms { transforms = Array($0) }
            let pixels = Array(UnsafeBufferPointer(start: bytes.contents().assumingMemoryBound(to: SIMD4<Float16>.self), count: width * height))
            return (transforms, pixels)
        }
        let initial = try await update([0, 1, 2])
        #expect(stats() == .init(transforms: 1, colors: 1, counts: 1))
        #expect(initial.0.count == 4 && initial.0[3] == collapsed)
        for _ in 0..<20 {
            let unchanged = try await update([0, 1, 2])
            #expect(unchanged.0 == initial.0 && unchanged.1 == initial.1)
        }
        #expect(stats() == .init(transforms: 1, colors: 1, counts: 1))

        graph.positionShift = 31
        let moved = try await update([0, 1, 2])
        #expect(moved.0 != initial.0 && moved.1 == initial.1)
        #expect(stats() == .init(transforms: 2, colors: 1, counts: 1))
        let scaled = try await update([0, 1, 2], scale: 2)
        #expect(scaled.0 != moved.0 && scaled.1 == moved.1)
        #expect(stats() == .init(transforms: 3, colors: 1, counts: 1))
        graph.selectedNode = graph.a
        let selected = try await update([0, 1, 2], scale: 2)
        #expect(selected.0 == scaled.0 && selected.1 != scaled.1)
        #expect(stats() == .init(transforms: 3, colors: 2, counts: 1))
        if isNode {
            graph.newNodeGlows[graph.a] = 0.15
            let glow1 = try await update([0, 1, 2], scale: 2)
            graph.newNodeGlows[graph.a] = 0.30
            let glow2 = try await update([0, 1, 2], scale: 2)
            #expect(glow1.0 == glow2.0 && glow1.1 != glow2.1)
            #expect(stats().transforms == 3 && stats().colors == 4)
        }
        graph.isSearchActive = true; graph.searchMatchIds = [graph.b]
        let beforeSearch = stats()
        _ = try await update([0, 1, 2], scale: 2)
        #expect(stats().colors == beforeSearch.colors + 1 && stats().transforms == beforeSearch.transforms)

        let beforeHole = stats()
        let hole = try await update([0, 2], scale: 2)
        #expect(hole.0[1] == collapsed && hole.1[1] == .zero)
        #expect(stats().transforms == beforeHole.transforms + 1 && stats().colors == beforeHole.colors + 1)
        #expect(stats().counts == beforeHole.counts) // high-water count stays three

        // A same-count remap must change slot payloads even without moving data.
        let beforeRemap = stats()
        graph.topologyVersion += 1
        let remapped = try await update([2, 1, 0], scale: 2)
        #expect(remapped.1[0].z > remapped.1[0].x && remapped.1[2].x > remapped.1[2].z)
        #expect(stats().transforms == beforeRemap.transforms + 1 && stats().colors == beforeRemap.colors + 1)
        #expect(stats().counts == beforeRemap.counts)
        let beforeHide = stats()
        _ = try await update([])
        let data = try #require(isNode ? scene.nodeInstanceData : scene.edgeInstanceData)
        #expect(data.instanceCount == 0)
        _ = try await update([2, 1, 0], scale: 2)
        #expect(data.instanceCount == 3)
        #expect(stats() == .init(transforms: beforeHide.transforms, colors: beforeHide.colors, counts: beforeHide.counts + 2))
        let entity = try #require(isNode ? scene.nodeTemplateEntity : scene.edgeTemplateEntity)
        #expect(entity.isEnabled)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["node", "edge"], [2, 4])
    @available(macOS 26, iOS 26, *)
    func instancePayloadCacheFollowsResourceAndCapacityReplacement(path: String, replacementCapacity: Int) async throws {
        let first = try EngramRealityScene.makeValidated(requireMascot: false)
        let second = try EngramRealityScene.makeValidated(requireMascot: false)
        defer { first.teardown(); second.teardown() }
        first.lodSystem.maxNodeInstances = 4; first.lodSystem.maxEdgeInstances = 4
        second.lodSystem.maxNodeInstances = replacementCapacity; second.lodSystem.maxEdgeInstances = replacementCapacity
        let graph = EdgeTextureFixtureGraph(count: 3)
        let nodes = NodeBatchSystem(), edges = EdgeBatchSystem()
        let isNode = path == "node"
        for scene in [first, second] {
            let command = try #require(scene.commandQueue.makeCommandBuffer())
            if isNode {
                nodes.update(scene: scene, dataProvider: graph, visibleSet: .init(nearNodes: [0, 1, 2]),
                    topologyChanged: false, animationTime: 0, scaleFactor: 1, commandBuffer: command)
            } else {
                edges.update(scene: scene, dataProvider: graph, visibleSet: .init(visibleEdgeIndices: [0, 1, 2]),
                    topologyChanged: false, scaleFactor: 1, commandBuffer: command)
            }
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                command.addCompletedHandler { _ in done.resume() }; command.commit()
            }
            #expect(command.status == .completed)
        }
        let old = try #require(isNode ? first.nodeInstanceData : first.edgeInstanceData)
        let current = try #require(isNode ? second.nodeInstanceData : second.edgeInstanceData)
        #expect(old !== current && current.instanceCapacity == replacementCapacity)
        #expect(current.instanceCount == min(3, replacementCapacity))
        var transforms: [simd_float4x4] = []
        current.withTransforms { transforms = Array($0) }
        #expect(transforms[0].columns.3.x == (isNode ? -10 : 0))
        let stats = isNode ? nodes.instanceUploadStatistics : edges.instanceUploadStatistics
        #expect(stats == .init(transforms: 2, colors: 2, counts: 2))
    }

    @Test
    func instancePayloadComparisonDoesNotTreatNaNAsUnchanged() {
        var transform = matrix_identity_float4x4
        transform.columns.3.x = .nan
        let transforms = [transform]
        let colors = [SIMD4<Float16>(.nan, 0, 0, 0)]
        #expect(!InstanceUploadState.sameTransforms(transforms, transforms))
        #expect(!InstanceUploadState.sameColors(colors, colors))
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["node", "edge"])
    @available(macOS 26, iOS 26, *)
    func instanceGroupIsCompleteAtAttachmentAndKeepsIdentityThroughEmptyUpdates(path: String) async throws {
        let scene = try EngramRealityScene.makeValidated(requireMascot: false)
        defer { scene.teardown() }
        scene.spatialAudioSystem.isEnabled = false
        let isNode = path == "node"
        let originalChildCount = scene.rootEntity.children.count
        @MainActor func ensure() {
            if isNode { scene.ensureNodeInstanceResources(capacity: 1) }
            else { scene.ensureEdgeInstanceResources(capacity: 1) }
        }
        // Deferred setup publishes nothing and can be attempted again once
        // capacity becomes available. This is not an allocator-failure mock.
        scene.lodSystem.maxNodeInstances = 0
        scene.lodSystem.maxEdgeInstances = 0
        ensure()
        #expect(scene.nodeInstanceData == nil && scene.edgeInstanceData == nil)
        #expect(scene.nodeInstanceTexture == nil && scene.edgeInstanceTexture == nil)
        #expect(scene.nodeTemplateEntity == nil && scene.edgeTemplateEntity == nil)
        #expect(scene.rootEntity.children.count == originalChildCount)

        scene.lodSystem.maxNodeInstances = 4
        scene.lodSystem.maxEdgeInstances = 4
        ensure()
        let entity = try #require(isNode ? scene.nodeTemplateEntity : scene.edgeTemplateEntity)
        let data = try #require(isNode ? scene.nodeInstanceData : scene.edgeInstanceData)
        let texture = try #require(isNode ? scene.nodeInstanceTexture : scene.edgeInstanceTexture)
        let component = try #require(entity.components[MeshInstancesComponent.self])
        // This exercises the actual throwing RealityKit constructor at zero
        // instances, before either batch system has performed its first update.
        #expect(data.instanceCount == 0 && data.instanceCapacity == 4)
        let componentData = try #require(component[partIndex: 0]?.data)
        #expect(componentData.instanceCount == 0 && componentData.instanceCapacity == 4)
        #expect(entity.parent === scene.rootEntity)
        #expect(scene.rootEntity.children.count == originalChildCount + 1)

        let graph = EdgeTextureFixtureGraph(count: 1)
        var previousPopulatedTransform: simd_float4x4?
        @MainActor func requireSameResources() throws {
            #expect((isNode ? scene.nodeTemplateEntity : scene.edgeTemplateEntity) === entity)
            #expect((isNode ? scene.nodeInstanceData : scene.edgeInstanceData) === data)
            #expect((isNode ? scene.nodeInstanceTexture : scene.edgeInstanceTexture) === texture)
            #expect(entity.parent === scene.rootEntity)
            #expect(scene.rootEntity.children.count == originalChildCount + 1)
            let current = try #require(entity.components[MeshInstancesComponent.self])
            let currentData = try #require(current[partIndex: 0]?.data)
            // Component conversion may vend a new Swift wrapper. The wrapper
            // retained before any update and a fresh getter must both continue
            // to observe the original data's mutable native storage.
            #expect(componentData.instanceCount == data.instanceCount)
            #expect(currentData.instanceCount == data.instanceCount)
            #expect(componentData.instanceCapacity == data.instanceCapacity)
            #expect(currentData.instanceCapacity == data.instanceCapacity)
            if data.instanceCount > 0 {
                var source: simd_float4x4?, retained: simd_float4x4?, fresh: simd_float4x4?
                data.withTransforms { source = $0.first }
                componentData.withTransforms { retained = $0.first }
                currentData.withTransforms { fresh = $0.first }
                let transform = try #require(source)
                #expect(try #require(retained) == transform)
                #expect(try #require(fresh) == transform)
                if let previousPopulatedTransform { #expect(transform != previousPopulatedTransform) }
                previousPopulatedTransform = transform
            }
        }
        @MainActor func update(visible: Bool) async throws {
            if visible { graph.positionShift += 10 }
            let command = try #require(scene.commandQueue.makeCommandBuffer())
            let set = VisibleSet(nearNodes: visible ? [0] : [], visibleEdgeIndices: visible ? [0] : [])
            if isNode {
                scene.nodeBatchSystem.update(scene: scene, dataProvider: graph, visibleSet: set,
                    topologyChanged: true, animationTime: 0, scaleFactor: 1, commandBuffer: command)
            } else {
                scene.edgeBatchSystem.update(scene: scene, dataProvider: graph, visibleSet: set,
                    topologyChanged: true, scaleFactor: 1, commandBuffer: command)
            }
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                command.addCompletedHandler { _ in done.resume() }; command.commit()
            }
            #expect(command.status == .completed)
            #expect(data.instanceCount == (visible ? 1 : 0))
            #expect(entity.isEnabled == visible)
            try requireSameResources()
        }
        ensure()
        try requireSameResources()
        try await update(visible: true)
        try await update(visible: false)
        try await update(visible: true)
        scene.teardown()
        await scene.drainPendingWork()
    }

    @Test(.timeLimit(.minutes(1)))
    func idleLightPoolSkipsWritesAndStillAnimatesThenDisablesDepartedLights() async throws {
        let scene = try EngramRealityScene.makeValidated(requireMascot: false)
        defer { scene.teardown() }
        let graph = EdgeTextureFixtureGraph(count: 0)
        for _ in 0..<120 { scene.updatePointLights(dataProvider: graph) }
        #expect(scene.diagnosticPointLightWrites == 0)
        #expect(scene.pointLightPool.allSatisfy { $0.components[PointLightComponent.self]?.intensity == 0 })

        graph.glowingNodes = [graph.a: 0.3, graph.b: 0.4]
        scene.updatePointLights(dataProvider: graph)
        #expect(scene.diagnosticPointLightWrites == 2)
        let firstPosition = scene.pointLightPool[0].position
        let firstIntensity = try #require(scene.pointLightPool[0].components[PointLightComponent.self]).intensity
        #expect(firstIntensity > 0)
        graph.positionShift = 20
        graph.glowingNodes = [graph.a: 1.0, graph.b: 1.0]
        scene.updatePointLights(dataProvider: graph)
        #expect(scene.diagnosticPointLightWrites == 4)
        #expect(scene.pointLightPool[0].position != firstPosition)
        #expect(scene.pointLightPool[0].components[PointLightComponent.self]?.intensity != firstIntensity)

        graph.glowingNodes = [:]; graph.newNodeGlows = [graph.c: 0.4]
        scene.updatePointLights(dataProvider: graph)
        #expect(scene.diagnosticPointLightWrites == 6)
        #expect(scene.pointLightPool[0].position == graph.positions[graph.c]! * scene.scaleFactor)
        #expect(try #require(scene.pointLightPool[0].components[PointLightComponent.self]).intensity > 0)
        #expect(scene.pointLightPool.dropFirst().allSatisfy { $0.components[PointLightComponent.self]?.intensity == 0 })

        graph.newNodeGlows = [:]
        scene.updatePointLights(dataProvider: graph)
        #expect(scene.diagnosticPointLightWrites == 7)
        for _ in 0..<120 { scene.updatePointLights(dataProvider: graph) }
        #expect(scene.diagnosticPointLightWrites == 7)
        #expect(scene.pointLightPool.allSatisfy { $0.components[PointLightComponent.self]?.intensity == 0 })
        graph.glowingNodes = [graph.a: 1.0]
        scene.updatePointLights(dataProvider: graph)
        #expect(scene.diagnosticPointLightWrites == 8)
        #expect(try #require(scene.pointLightPool[0].components[PointLightComponent.self]).intensity > 0)
        scene.teardown(); await scene.drainPendingWork()
    }

    @Test(.timeLimit(.minutes(1)))
    func unchangedCameraSkipsWritesButMotionProjectionAndExternalChangesResync() {
        let system = CameraSystem(), camera = PerspectiveCamera()
        var state = CameraState(azimuth: 0.4, elevation: 0.2, cameraTarget: SIMD3(2, 3, 4),
            orbitRadius: 300, scaleFactor: 0.005, fovDegrees: 57)
        system.update(camera: camera, state: state, scaleFactor: 0.005)
        let initialTransformWrites = system.diagnosticTransformWrites
        let initialFOVWrites = system.diagnosticFieldOfViewWrites
        let initial = camera.transform
        #expect(initialTransformWrites == 1 && initialFOVWrites == 1)
        for _ in 0..<120 { system.update(camera: camera, state: state, scaleFactor: 0.005) }
        #expect(system.diagnosticTransformWrites == initialTransformWrites)
        #expect(system.diagnosticFieldOfViewWrites == initialFOVWrites)
        #expect(camera.transform == initial)

        state.cameraTarget.x += 10
        system.update(camera: camera, state: state, scaleFactor: 0.005)
        #expect(system.diagnosticTransformWrites == initialTransformWrites + 1)
        #expect(camera.position == state.cameraPosition * 0.005)
        #expect(system.diagnosticFieldOfViewWrites == initialFOVWrites)
        state.fovDegrees = 71
        system.update(camera: camera, state: state, scaleFactor: 0.005)
        #expect(system.diagnosticTransformWrites == initialTransformWrites + 1)
        #expect(system.diagnosticFieldOfViewWrites == initialFOVWrites + 1)
        #expect(camera.camera.fieldOfViewInDegrees == 71)

        let expected = camera.transform
        camera.position = SIMD3(50, 60, 70)
        camera.camera.fieldOfViewInDegrees = 25
        system.update(camera: camera, state: state, scaleFactor: 0.005)
        #expect(camera.transform == expected && camera.camera.fieldOfViewInDegrees == 71)
        let replacement = PerspectiveCamera()
        system.update(camera: replacement, state: state, scaleFactor: 0.005)
        #expect(replacement.transform == expected && replacement.camera.fieldOfViewInDegrees == 71)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["node", "edge"], [false, true])
    @available(macOS 26, iOS 26, *)
    func textureUploadsKeepSubmittedBytesAndBoundInFlightUpdates(path: String, transformOnly: Bool) async throws {
        let scene = try EngramRealityScene.makeValidated(requireMascot: false)
        defer { scene.teardown() }
        scene.spatialAudioSystem.isEnabled = false
        let graph = EdgeTextureFixtureGraph(count: 3)
        var commands: [MTLCommandBuffer] = [], readbacks: [(pixels: MTLBuffer, transforms: MTLBuffer)] = []
        defer { for command in commands where command.status == .notEnqueued { command.commit() } }
        let expectedRed: [Float16] = transformOnly
            ? Array(repeating: path == "node" ? Float16(0.1) : Float16(0.29), count: 3)
            : (path == "node" ? [0.1, 0.2, 0.3] : [0.29, 0.43, 0.57])
        @MainActor func update(_ command: MTLCommandBuffer, indices: [Int]) {
            let set = VisibleSet(nearNodes: indices, visibleEdgeIndices: indices)
            if path == "node" {
                scene.nodeBatchSystem.update(scene: scene, dataProvider: graph, visibleSet: set,
                    topologyChanged: false, animationTime: 0, scaleFactor: 1, commandBuffer: command)
            } else {
                scene.edgeBatchSystem.update(scene: scene, dataProvider: graph, visibleSet: set,
                    topologyChanged: false, scaleFactor: 1, commandBuffer: command)
            }
        }
        @MainActor func instanceData() throws -> LowLevelInstanceData {
            try #require(path == "node" ? scene.nodeInstanceData : scene.edgeInstanceData)
        }
        @MainActor func capture(_ command: MTLCommandBuffer) throws -> (pixels: MTLBuffer, transforms: MTLBuffer) {
            let data = try instanceData()
            let transformBytes = data.instanceCapacity * MemoryLayout<simd_float4x4>.stride
            let matrices = try #require(scene.device.makeBuffer(length: transformBytes, options: .storageModeShared))
            let source = data.read(using: command)
            let texture = try #require(path == "node" ? scene.nodeInstanceTexture : scene.edgeInstanceTexture)
            let width = texture.descriptor.width, height = texture.descriptor.height
            let rowBytes = width * MemoryLayout<SIMD4<Float16>>.stride
            let buffer = try #require(scene.device.makeBuffer(length: rowBytes * height, options: .storageModeShared))
            let blit = try #require(command.makeBlitCommandEncoder())
            blit.copy(from: source, sourceOffset: 0, to: matrices, destinationOffset: 0, size: transformBytes)
            blit.copy(from: texture.read(), sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: .init(x: 0, y: 0, z: 0), sourceSize: .init(width: width, height: height, depth: 1),
                to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height)
            blit.endEncoding(); return (buffer, matrices)
        }
        if transformOnly {
            // Establish colors first. The following three submissions change
            // transforms only and must still hold all three staging leases.
            graph.colorMultiplier = 0.1; graph.positionShift = -20
            let prime = try #require(scene.commandQueue.makeCommandBuffer())
            commands.append(prime)
            update(prime, indices: [0, 1, 2])
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                prime.addCompletedHandler { _ in done.resume() }; prime.commit()
            }
            #expect(prime.status == .completed)
            commands.removeAll()
        }
        // None of these commands has been committed. Later CPU writes therefore
        // must not alter any of the earlier uploads' source bytes.
        for index in 0..<3 {
            graph.colorMultiplier = transformOnly ? 0.1 : Float(index + 1) / 10
            graph.positionShift = Float(index * 20)
            let command = try #require(scene.commandQueue.makeCommandBuffer())
            update(command, indices: [0, 1, 2])
            commands.append(command); readbacks.append(try capture(command))
        }
        let data = try instanceData()
        let entity = try #require(path == "node" ? scene.nodeTemplateEntity : scene.edgeTemplateEntity)
        let submittedCount = data.instanceCount
        let submittedStatistics = path == "node" ? scene.nodeBatchSystem.instanceUploadStatistics : scene.edgeBatchSystem.instanceUploadStatistics
        graph.colorMultiplier = 0.9; graph.positionShift = 900
        let saturated = try #require(scene.commandQueue.makeCommandBuffer())
        update(saturated, indices: [2])
        commands.append(saturated)
        let saturatedReadback = try capture(saturated)
        #expect(data.instanceCount == submittedCount)
        #expect(submittedStatistics == (path == "node" ? scene.nodeBatchSystem.instanceUploadStatistics : scene.edgeBatchSystem.instanceUploadStatistics))
        #expect(entity.isEnabled && submittedCount == 3)
        for command in commands {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                command.addCompletedHandler { _ in done.resume() }; command.commit()
            }
            #expect(command.status == .completed)
        }
        for (index, buffer) in readbacks.enumerated() {
            let pixels = buffer.pixels.contents().assumingMemoryBound(to: SIMD4<Float16>.self)
            #expect(pixels[0].x == expectedRed[index])
            let first = buffer.transforms.contents().load(as: simd_float4x4.self)
            #expect(first.columns.3.x == Float(index * 20) + (path == "node" ? -10 : 0))
        }
        let matrixCount = data.instanceCapacity
        let submittedTransforms = Array(UnsafeBufferPointer(
            start: readbacks[2].transforms.contents().assumingMemoryBound(to: simd_float4x4.self), count: matrixCount))
        let saturatedTransforms = Array(UnsafeBufferPointer(
            start: saturatedReadback.transforms.contents().assumingMemoryBound(to: simd_float4x4.self), count: matrixCount))
        #expect(submittedTransforms == saturatedTransforms)
        if transformOnly { #expect(submittedStatistics.colors == 1 && submittedStatistics.transforms == 4) }
        // Completion frees a slot. The next entire update is admitted, including
        // transforms, topology holes, texture, and the original component owner.
        let resumed = try #require(scene.commandQueue.makeCommandBuffer())
        commands.append(resumed)
        update(resumed, indices: [2])
        let resumedPixels = try capture(resumed)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            resumed.addCompletedHandler { _ in done.resume() }; resumed.commit()
        }
        #expect(resumed.status == .completed)
        var resumedTransforms: [simd_float4x4] = []
        data.withTransforms { resumedTransforms = Array($0) }
        #expect(resumedTransforms != submittedTransforms)
        #expect(entity === (path == "node" ? scene.nodeTemplateEntity : scene.edgeTemplateEntity))
        let pixels = resumedPixels.pixels.contents().assumingMemoryBound(to: SIMD4<Float16>.self)
        #expect(pixels[0] == .zero && pixels[1] == .zero && pixels[2].z > 0)
        scene.teardown(); await scene.drainPendingWork()
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["node", "edge", "label"])
    func synchronousMeshReplacementReachesGPUAndClearsCapacityTail(path: String) async throws {
        let scene = try EngramRealityScene.makeValidated(requireMascot: false)
        defer { scene.teardown() }
        scene.spatialAudioSystem.isEnabled = false
        let graph = EdgeTextureFixtureGraph(count: 3)
        var frame: UInt64 = 120

        @MainActor func writeAndRead(_ count: Int) async throws -> (LowLevelMesh, [UInt8], Int) {
            let indices = Array(0..<count)
            let set = VisibleSet(nearNodes: indices, visibleEdgeIndices: indices, visibleLabelIndices: indices)
            let mesh: LowLevelMesh, bufferIndex: Int, usedBytes: Int, totalBytes: Int
            switch path {
            case "node":
                // Exercise the real legacy path even on macOS/iOS 26; the public
                // availability dispatch is unchanged and no feature flag is added.
                scene.nodeBatchSystem.updateWithTwoBufferMesh(scene: scene, dataProvider: graph,
                    visibleSet: set, animationTime: 0, scaleFactor: 1)
                mesh = try #require(scene.nodeBatchMesh); bufferIndex = 1
                let stride = MemoryLayout<LowLevelMeshFactory.NodeInstanceAttribs>.stride
                usedBytes = count * scene.vertsPerSphere * stride
                totalBytes = scene.nodeBatchCapacity * scene.vertsPerSphere * stride
            case "edge":
                scene.edgeBatchSystem.updateCurrentApproach(scene: scene, dataProvider: graph,
                    visibleSet: set, scaleFactor: 1)
                mesh = try #require(scene.edgeBatchMesh); bufferIndex = 0
                usedBytes = count * 12 * MemoryLayout<EngramRealityKit.BatchVertex>.stride
                totalBytes = scene.edgeBatchCapacity * 12 * MemoryLayout<EngramRealityKit.BatchVertex>.stride
            default:
                scene.labelBatchSystem.update(scene: scene, dataProvider: graph, visibleSet: set,
                    topologyChanged: true, cameraPosition: SIMD3(0, 0, 500), scaleFactor: 1,
                    frameCount: frame)
                frame += 120
                mesh = try #require(scene.labelBatchMesh); bufferIndex = 0
                // Fixture has one topic label and no project centroid labels.
                usedBytes = (count + 1) * 4 * MemoryLayout<EngramRealityKit.BatchVertex>.stride
                totalBytes = scene.labelBatchCapacity * 4 * MemoryLayout<EngramRealityKit.BatchVertex>.stride
            }
            let command = try #require(scene.commandQueue.makeCommandBuffer())
            let source = mesh.read(bufferIndex: bufferIndex, using: command)
            let destination = try #require(scene.device.makeBuffer(length: totalBytes, options: .storageModeShared))
            let blit = try #require(command.makeBlitCommandEncoder())
            blit.copy(from: source, sourceOffset: 0, to: destination, destinationOffset: 0, size: totalBytes)
            blit.endEncoding()
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                command.addCompletedHandler { _ in done.resume() }; command.commit()
            }
            #expect(command.status == .completed)
            let bytes = Array(UnsafeBufferPointer(start: destination.contents().assumingMemoryBound(to: UInt8.self), count: totalBytes))
            #expect(bytes.prefix(usedBytes).contains { $0 != 0 })
            #expect(bytes.dropFirst(usedBytes).allSatisfy { $0 == 0 })
            return (mesh, bytes, usedBytes)
        }
        let (mesh, populated, populatedBytes) = try await writeAndRead(3)
        let (sameMesh, reduced, reducedBytes) = try await writeAndRead(1)
        #expect(mesh === sameMesh && populated.count == reduced.count)
        #expect(populated[reducedBytes..<populatedBytes].contains { $0 != 0 })
        #expect(reduced[reducedBytes..<populatedBytes].allSatisfy { $0 == 0 })
        let (restoredMesh, restored, _) = try await writeAndRead(3)
        #expect(restoredMesh === mesh && restored == populated)
        scene.teardown(); await scene.drainPendingWork()
    }

    @Test(.timeLimit(.minutes(1)))
    @available(macOS 26, iOS 26, *)
    func emptyFiltersHideAndRestoreExistingBatchesAndInvalidateFlowEdges() async throws {
        let scene = try EngramRealityScene.makeValidated(requireMascot: false)
        defer { scene.teardown() }
        scene.spatialAudioSystem.isEnabled = false
        let graph = EdgeTextureFixtureGraph(count: 1)
        let originalEdges = graph.edges
        graph.selectedNode = graph.a
        let flow = RKFlowParticleSystem()

        @MainActor func render(_ visible: Bool) async throws {
            let set = VisibleSet(nearNodes: visible ? [0, 1, 2] : [],
                visibleEdgeIndices: visible ? [0] : [], visibleLabelIndices: visible ? [0, 1, 2] : [])
            let command = try #require(scene.commandQueue.makeCommandBuffer())
            scene.nodeBatchSystem.update(scene: scene, dataProvider: graph, visibleSet: set,
                topologyChanged: true, animationTime: 0, scaleFactor: 1, commandBuffer: command)
            scene.edgeBatchSystem.update(scene: scene, dataProvider: graph, visibleSet: set,
                topologyChanged: true, scaleFactor: 1, commandBuffer: command)
            scene.labelBatchSystem.update(scene: scene, dataProvider: graph, visibleSet: set,
                topologyChanged: true, cameraPosition: SIMD3(0, 0, 500), scaleFactor: 1,
                frameCount: graph.topologyVersion * 120, commandBuffer: command)
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                command.addCompletedHandler { _ in done.resume() }; command.commit()
            }
            #expect(command.status == .completed)
            // A selected node remains selected as its last edge is filtered out.
            // The old cached index would subscript the now-empty edge array here.
            flow.update(scene: scene, dataProvider: graph, dt: 0.5, scaleFactor: 1)
        }

        try await render(true)
        let nodes = try #require(scene.nodeTemplateEntity)
        let edges = try #require(scene.edgeTemplateEntity)
        let labels = try #require(scene.labelBatchEntity)
        #expect(scene.nodeInstanceData?.instanceCount == 3)
        #expect(scene.edgeInstanceData?.instanceCount == 1)
        for _ in 0..<2 {
            graph.showsNodes = false; graph.edges = []; graph.topologyVersion += 1
            try await render(false)
            #expect(!nodes.isEnabled && !edges.isEnabled && !labels.isEnabled)
            #expect(scene.nodeInstanceData?.instanceCount == 0 && scene.edgeInstanceData?.instanceCount == 0)
            graph.showsNodes = true; graph.edges = originalEdges; graph.topologyVersion += 1
            try await render(true)
            #expect(nodes.isEnabled && edges.isEnabled && labels.isEnabled)
            #expect(scene.nodeTemplateEntity === nodes && scene.edgeTemplateEntity === edges)
            #expect(scene.labelBatchEntity === labels)
            #expect(scene.nodeInstanceData?.instanceCount == 3 && scene.edgeInstanceData?.instanceCount == 1)
        }
        scene.teardown()
        await scene.drainPendingWork()
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["missing-endpoint", "zero-length"])
    @available(macOS 26, iOS 26, *)
    func invalidEdgesReplacePriorGeometryWithCollapsedGPUTransforms(kind: String) async throws {
        let scene = try EngramRealityScene.makeValidated(requireMascot: false)
        defer { scene.teardown() }
        scene.spatialAudioSystem.isEnabled = false
        let graph = EdgeTextureFixtureGraph(count: 1)
        let original = graph.edges[0]
        let batch = EdgeBatchSystem()
        let collapsed = simd_float4x4(diagonal: SIMD4<Float>(0, 0, 0, 1))

        @MainActor func uploadAndRead() async throws -> (simd_float4x4, SIMD4<Float16>) {
            let command = try #require(scene.commandQueue.makeCommandBuffer())
            defer { if command.status == .notEnqueued { command.commit() } }
            batch.update(scene: scene, dataProvider: graph,
                visibleSet: .init(visibleEdgeIndices: [0]), topologyChanged: true,
                scaleFactor: 1, commandBuffer: command)
            let data = try #require(scene.edgeInstanceData)
            let texture = try #require(scene.edgeInstanceTexture)
            #expect(data.instanceCount == 1)
            let transforms = data.read(using: command)
            let matrixBytes = MemoryLayout<simd_float4x4>.stride
            let matrixReadback = try #require(scene.device.makeBuffer(length: matrixBytes, options: .storageModeShared))
            let pixelReadback = try #require(scene.device.makeBuffer(length: 256, options: .storageModeShared))
            let blit = try #require(command.makeBlitCommandEncoder())
            blit.copy(from: transforms, sourceOffset: 0, to: matrixReadback, destinationOffset: 0, size: matrixBytes)
            blit.copy(from: texture.read(), sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: .init(x: 0, y: 0, z: 0), sourceSize: .init(width: 1, height: 1, depth: 1),
                to: pixelReadback, destinationOffset: 0, destinationBytesPerRow: 256, destinationBytesPerImage: 256)
            blit.endEncoding()
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                command.addCompletedHandler { _ in done.resume() }; command.commit()
            }
            #expect(command.status == .completed)
            return (matrixReadback.contents().load(as: simd_float4x4.self),
                    pixelReadback.contents().load(as: SIMD4<Float16>.self))
        }

        let valid = try await uploadAndRead()
        #expect(valid.0 != collapsed && valid.1.w > 0)
        // Keep the edge identity/occupied slot while its geometry becomes invalid.
        graph.edges = [.init(id: original.id, sourceId: kind == "missing-endpoint" ? UUID() : graph.a,
                            targetId: graph.a, relation: original.relation)]
        graph.topologyVersion += 1
        let hidden = try await uploadAndRead()
        #expect(hidden.0 == collapsed)
        #expect(hidden.1 == .zero)
        graph.edges = [original]; graph.topologyVersion += 1
        let restored = try await uploadAndRead()
        #expect(restored.0 == valid.0 && restored.1 == valid.1)
        scene.teardown(); await scene.drainPendingWork()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [8192, 8193, 16384])
    @available(macOS 26, iOS 26, *)
    func edgeTextureRowsPreserveCapacityAndUploadedSlotIdentity(capacity: Int) async throws {
        let scene = try EngramRealityScene.makeValidated(requireMascot: false)
        defer { scene.teardown() }
        scene.spatialAudioSystem.isEnabled = false
        scene.lodSystem.maxEdgeInstances = capacity
        let graph = EdgeTextureFixtureGraph(count: capacity)
        let batch = EdgeBatchSystem()

        @MainActor func uploadAndRead(_ indices: [Int]) async throws -> [SIMD4<Float16>] {
            let command = try #require(scene.commandQueue.makeCommandBuffer())
            batch.update(scene: scene, dataProvider: graph,
                visibleSet: .init(visibleEdgeIndices: indices), topologyChanged: true,
                scaleFactor: 1, commandBuffer: command)
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                command.addCompletedHandler { _ in done.resume() }
                command.commit()
            }
            #expect(command.status == .completed)
            let texture = try #require(scene.edgeInstanceTexture)
            let width = texture.descriptor.width, height = texture.descriptor.height
            let rowBytes = width * MemoryLayout<SIMD4<Float16>>.stride
            let buffer = try #require(scene.device.makeBuffer(length: rowBytes * height, options: .storageModeShared))
            let read = try #require(scene.commandQueue.makeCommandBuffer())
            let blit = try #require(read.makeBlitCommandEncoder())
            blit.copy(from: texture.read(), sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: .init(x: 0, y: 0, z: 0), sourceSize: .init(width: width, height: height, depth: 1),
                to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height)
            blit.endEncoding()
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                read.addCompletedHandler { _ in done.resume() }
                read.commit()
            }
            #expect(read.status == .completed)
            return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: SIMD4<Float16>.self), count: width * height))
        }

        let pixels = try await uploadAndRead(Array(0..<capacity))
        let data = try #require(scene.edgeInstanceData)
        let texture = try #require(scene.edgeInstanceTexture)
        #expect(data.instanceCapacity == capacity && data.instanceCount == capacity)
        #expect(texture.descriptor.width == 8192)
        #expect(texture.descriptor.height == (capacity == 8192 ? 1 : 2))
        #expect(scene.edgeInstanceTextureWidth == texture.descriptor.width)
        #expect(scene.edgeTemplateEntity?.name == "edge_instanced")
        try scene.validateResources()
        let red = SIMD4<Float16>(1, Float16(0.15), Float16(0.15), Float16(0.35))
        let green = SIMD4<Float16>(Float16(0.15), 1, Float16(0.15), Float16(0.35))
        let blue = SIMD4<Float16>(Float16(0.15), Float16(0.15), 1, Float16(0.35))
        #expect(pixels[0] == red)
        #expect(pixels[8191] == (capacity == 8192 ? blue : red))
        if capacity > 8192 { #expect(pixels[8192] == green) }
        if capacity > 8193 { #expect(pixels[capacity - 1] == blue) }
        #expect(pixels.dropFirst(capacity).allSatisfy { $0 == .zero })
        // Stable slots remain associated with edges after LOD removal. A hole
        // in row zero must not clear or move the live row-one slot.
        if capacity > 8192 {
            let retained = Array((0..<capacity).filter { $0 != 8191 })
            let withHole = try await uploadAndRead(retained)
            #expect(withHole[8191] == .zero && withHole[8192] == green)
        }
        scene.teardown()
        await scene.drainPendingWork()
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationBeforeLoaderStartsDoesNotBeginNativeAssetWork() async {
        let probe = MascotStartProbe(), graph = EmbeddedFixtureGraph(), container = Entity()
        let system = RKMascotSystem(loadMascot: { _, _ in probe.calls += 1; return Entity() })
        system.update(container: container, dataProvider: graph, dt: 0.016, scaleFactor: 1)
        // No actor suspension has occurred since task creation: cancellation
        // deterministically precedes entry into the injected native boundary.
        system.teardown()
        await system.drainPendingLoads()
        #expect(probe.calls == 0 && container.children.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func nativeForceCompletionSettlesAfterItsResultWithoutLateHandlerRegistration() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let library = try EngramMetalShaders.makePackagedLibrary(device: device)
        let compute = try #require(MetalForceCompute(device: device, library: library))
        let engine = ForceEngine(forceCompute: compute)
        let probe = ForceCompletionProbe()
        let snapshot = ForceEngine.SimulationSnapshot(
            nodeCount: 2, isSettled: false, posX: [-1, 1], posY: [0, 0], posZ: [0, 0],
            projectGroups: [0, 0], topicGroups: [0, 0], topicProjectGroup: [0],
            galaxyGroups: [0, 0], galaxyCenters: [.zero], edgeIndices: [(0, 1)], topologyDirty: true,
            chargeStrength: 1, crossChargeMultiplier: 1, sameTopicChargeScale: 1, sameProjectChargeScale: 1,
            springLength: 2, crossProjectSpringLength: 2, springStrength: 0.1,
            cohesionStrength: 0.1, centroidRepulsion: 0.1, topicCohesionStrength: 0.1,
            topicCentroidRepulsion: 0.1, centerStrength: 0.1, alpha: 0.5, damping: 0.78, maxSpeed: 12)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            probe.command = engine.encodeForcePass(queue: queue, snapshot: snapshot, onSettled: {
                probe.settledAfterResult = probe.resultSeen && !engine.isInFlight
                probe.settledCount += 1; continuation.resume()
            }, onComplete: { _ in probe.resultSeen = true })
            if probe.command == nil { continuation.resume() }
        }
        let command = try #require(probe.command)
        #expect(command.status == .completed)
        #expect(probe.settledCount == 1 && probe.settledAfterResult)
    }

    @Test(.timeLimit(.minutes(1)))
    func pausedAndTornDownSceneCannotTickOrResurrectItsProvider() async throws {
        try #require(MTLCreateSystemDefaultDevice() != nil)
        let graph = EmbeddedFixtureGraph(), scene = EngramRealityScene(), camera = CameraController()
        defer { scene.teardown() }
        scene.dataProvider = graph; scene.cameraProvider = camera
        scene.spatialAudioSystem.isEnabled = false
        var callbacks = 0, stoppedSubscriptions = 0
        scene.onFrameCallback = { _ in callbacks += 1 }
        scene.stopFrameSubscription = { stoppedSubscriptions += 1 }
        scene.setActive(false)
        scene.update(dt: 0.016)
        #expect(graph.ticks == 0 && callbacks == 0 && !scene.rootEntity.isEnabled)
        scene.setActive(true)
        scene.update(dt: 0.016)
        #expect(graph.ticks == 1 && callbacks == 1)
        scene.teardown()
        await scene.drainPendingWork()
        #expect(scene.isTornDown && scene.dataProvider == nil && scene.cameraProvider == nil)
        #expect(scene.rootEntity.children.isEmpty && stoppedSubscriptions == 2)
        scene.dataProvider = graph; scene.setActive(true); scene.update(dt: 0.016)
        #expect(graph.ticks == 1 && callbacks == 1 && !scene.isActive)
    }

    @Test(.timeLimit(.minutes(1)))
    func lateMascotCompletionCannotRepopulateTornDownGraph() async {
        let held = HeldMascot(), graph = EmbeddedFixtureGraph(), container = Entity()
        let system = RKMascotSystem(loadMascot: { _, _ in await held.load() })
        system.update(container: container, dataProvider: graph, dt: 0.016, scaleFactor: 1)
        await held.waitForStart()
        system.teardown()
        held.release()
        await system.drainPendingLoads()
        #expect(container.children.isEmpty)
        system.setActive(true)
        system.update(container: container, dataProvider: graph, dt: 0.016, scaleFactor: 1)
        #expect(container.children.isEmpty)
    }

    /// Run through Xcode with the actual resource bundles; raw copied .metal
    /// files or the legacy PBR fallback cannot satisfy this acceptance test.
    @Test(.timeLimit(.minutes(1)))
    func packagedShadersAndMascotDecodeThroughTheRealRenderer() async throws {
        let scene = try EngramRealityScene.makeValidated()
        defer { scene.teardown() }
        #expect(scene.resourceDiagnostics.shadersReady && scene.resourceDiagnostics.bundledMascotAvailable)
        try await scene.validateMascotResource()
        let graph = EmbeddedFixtureGraph(), camera = CameraController()
        scene.dataProvider = graph; scene.cameraProvider = camera
        scene.spatialAudioSystem.isEnabled = false
        _ = scene.setup(); scene.update(dt: 0.016)
        try scene.validateResources()
        #expect(scene.materialFallbacks.isEmpty)
        scene.teardown()
        await scene.drainPendingWork()
    }
    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    @available(macOS 26, iOS 26, *)
    func terminalRetirementDetachesBeforeDrainingRealGPUWrites(hosted: Bool) async throws {
        let scene = try EngramRealityScene.makeValidated(requireMascot: false)
        scene.spatialAudioSystem.isEnabled = false
        let graph = EdgeTextureFixtureGraph(count: 1)
        scene.dataProvider = graph
        let root = scene.setup(), host = Entity()
        var detachCalls = 0
        if hosted {
            host.addChild(root)
            _ = try #require(scene.registerContentHost {
                detachCalls += 1
                root.removeFromParent()
            })
        }
        let event = try #require(scene.device.makeSharedEvent())
        let blocker = try #require(scene.commandQueue.makeCommandBuffer())
        // A real queue dependency holds the renderer's following native writes.
        // No CPU wait/sleep or resource lifetime substitute is used.
        blocker.encodeWaitForEvent(event, value: 1)
        blocker.commit()
        defer { event.signaledValue = 1; scene.teardown() }
        scene.update(dt: 1 / 60)
        #expect(scene.pendingFrameSubmissionCount > 0)
        #expect(scene.nodeInstanceTexture != nil && scene.edgeInstanceTexture != nil)
        #expect(scene.nodeInstanceData != nil && scene.edgeInstanceData != nil && scene.labelBatchMesh != nil)
        scene.teardown()
        #expect(scene.isTornDown && !scene.isActive && !root.isEnabled)
        #expect(scene.dataProvider == nil && scene.cameraProvider == nil)
        #expect(host.children.isEmpty && scene.attachedContentHostCount == 0)
        #expect(detachCalls == (hosted ? 1 : 0))
        let completion = RetirementCompletionProbe()
        let drain = Task { @MainActor in await scene.drainPendingWork(); completion.returned = true }
        for _ in 0..<10 { await Task.yield() }
        #expect(!completion.returned && !scene.resourcesReleased)
        #expect(scene.nodeInstanceTexture != nil && scene.edgeInstanceTexture != nil)
        #expect(scene.nodeInstanceData != nil && scene.edgeInstanceData != nil && scene.labelBatchMesh != nil)
        drain.cancel()
        for _ in 0..<10 { await Task.yield() }
        #expect(!completion.returned && !scene.resourcesReleased)
        event.signaledValue = 1
        await drain.value
        #expect(blocker.status == .completed)
        #expect(completion.returned && scene.resourcesReleased && scene.pendingFrameSubmissionCount == 0)
        #expect(scene.nodeInstanceTexture == nil && scene.edgeInstanceTexture == nil)
        #expect(scene.nodeInstanceData == nil && scene.edgeInstanceData == nil && scene.labelBatchMesh == nil)
        #expect(root.children.isEmpty)
        scene.teardown(); await scene.drainPendingWork()
        #expect(detachCalls == (hosted ? 1 : 0))
    }

    @Test(.timeLimit(.minutes(1)))
    func contentAttachmentCanReappearButLateTerminalRegistrationOnlyDetaches() async throws {
        let scene = try EngramRealityScene.makeValidated(requireMascot: false)
        scene.spatialAudioSystem.isEnabled = false
        var detachCalls = 0
        let first = try #require(scene.registerContentHost { detachCalls += 1 })
        scene.removeContentHost(first); scene.removeContentHost(first)
        #expect(detachCalls == 1 && scene.attachedContentHostCount == 0 && !scene.isTornDown)
        let second = try #require(scene.registerContentHost { detachCalls += 1 })
        #expect(second != first && scene.attachedContentHostCount == 1)
        scene.teardown()
        #expect(detachCalls == 2 && scene.attachedContentHostCount == 0)
        let late = scene.registerContentHost { detachCalls += 1 }
        #expect(late == nil && detachCalls == 3 && scene.attachedContentHostCount == 0)
        await scene.drainPendingWork()
        #expect(scene.resourcesReleased)
        scene.setActive(true)
        #expect(!scene.isActive)
    }

}

@MainActor private final class RetirementCompletionProbe { var returned = false }
