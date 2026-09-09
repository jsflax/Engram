import Metal
import RealityKit
import Testing
@testable import EngramRealityKit

@Suite("Label mesh allocation", .enabled(if: MTLCreateSystemDefaultDevice() != nil))
@MainActor
struct LabelMeshAllocationTests {
    private enum AllocationFailure: Error { case injected }

    @Test("Failed initial mesh resource leaves no published capacity and retries unchanged input")
    func initialFailureRetries() {
        let scene = EngramRealityScene()
        let failed = LowLevelMeshFactory.ensureLabelBatchMesh(scene: scene, capacity: 1) { _ in
            throw AllocationFailure.injected
        }
        #expect(!failed)
        #expect(scene.labelBatchCapacity == 0)
        #expect(scene.labelBatchMesh == nil)
        #expect(scene.labelBatchEntity == nil)

        let retried = LowLevelMeshFactory.ensureLabelBatchMesh(scene: scene, capacity: 1)
        #expect(retried)
        #expect(scene.labelBatchCapacity >= 1)
        #expect(scene.labelBatchMesh != nil)
        #expect(scene.labelBatchEntity?.model != nil)
    }

    @Test("Failed mesh growth preserves the old visible mesh and retries the same requested size")
    func failedGrowthPreservesPreviousPublication() throws {
        let scene = EngramRealityScene()
        let initialized = LowLevelMeshFactory.ensureLabelBatchMesh(scene: scene, capacity: 1)
        try #require(initialized)
        let publishedMesh = try #require(scene.labelBatchMesh)
        let publishedEntity = try #require(scene.labelBatchEntity)
        let publishedResource = try #require(publishedEntity.model?.mesh)
        let publishedCapacity = scene.labelBatchCapacity
        let requestedCapacity = publishedCapacity + 1

        let failed = LowLevelMeshFactory.ensureLabelBatchMesh(scene: scene, capacity: requestedCapacity) { _ in
            throw AllocationFailure.injected
        }
        #expect(!failed)
        #expect(scene.labelBatchCapacity == publishedCapacity)
        #expect(scene.labelBatchMesh === publishedMesh)
        #expect(scene.labelBatchEntity === publishedEntity)
        #expect(scene.labelBatchEntity?.model?.mesh === publishedResource)

        let retried = LowLevelMeshFactory.ensureLabelBatchMesh(scene: scene, capacity: requestedCapacity)
        #expect(retried)
        #expect(scene.labelBatchCapacity >= requestedCapacity)
        #expect(scene.labelBatchMesh !== publishedMesh)
        #expect(scene.labelBatchEntity === publishedEntity)
        #expect(scene.labelBatchEntity?.model?.mesh !== publishedResource)
    }
}
