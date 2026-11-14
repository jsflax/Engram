import Foundation
import RealityKit
import EngramMetalShaders
import EngramRealityKit

/// Current rendered scene evidence. Obtaining this does not discover a store,
/// switch graphs, create embeddings or authorize any workspace access.
public struct EngramGraphResourceProbeResult: Sendable {
    public let renderedFrames: Int
    public let completedForcePasses: Int
    public let memoryCount: Int
    public let edgeCount: Int
    public let nodeGeometryPresent: Bool
    public let edgeGeometryPresent: Bool
    public let labelGeometryPresent: Bool
}

public enum EngramGraphResourceProbeError: Error {
    case inactive, replaced, timedOut
}

@MainActor public extension EngramGraphViewerController {
    /// Call on an already mounted synthetic viewer. A frame alone is insufficient:
    /// require successful GPU force delivery, actual node/edge/label geometry and
    /// the renderer's post-frame material checks. The caller owns clearAndDrain.
    /// The deadline bounds the frame wait. Native asset decoding is awaited to
    /// completion even after cancellation; a late return is reported as timeout.
    func validateRenderedResources(timeout: Duration = .seconds(30)) async throws -> EngramGraphResourceProbeResult {
        guard isActive, let manager = sceneManager else { throw EngramGraphResourceProbeError.inactive }
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            guard manager === sceneManager, snapshot != nil else { throw EngramGraphResourceProbeError.replaced }
            if rendererError != nil { throw EngramGraphViewerError.rendererUnavailable }
            let scene = manager.scene
            let node = scene.nodeBatchEntity?.model != nil
                || (scene.rootEntity.findEntity(named: "node_instanced") as? ModelEntity)?.model != nil
            let edge = scene.edgeBatchEntity?.model != nil
                || (scene.rootEntity.findEntity(named: "edge_instanced") as? ModelEntity)?.model != nil
            let label = scene.labelBatchEntity?.model != nil
            if manager.validatedRenderedFrameCount > 0, manager.completedForcePassCount > 0, node, edge, label {
                _ = try EngramMetalShaders.makePackagedLibrary(device: scene.device)
                try scene.validateResources()
                try await scene.validateMascotResource()
                try Task.checkCancellation()
                guard manager === sceneManager, snapshot != nil else { throw EngramGraphResourceProbeError.replaced }
                guard clock.now < deadline else { throw EngramGraphResourceProbeError.timedOut }
                try scene.validateResources()
                return .init(renderedFrames: manager.validatedRenderedFrameCount,
                    completedForcePasses: manager.completedForcePassCount,
                    memoryCount: visibleMemoryCount, edgeCount: visibleEdgeCount,
                    nodeGeometryPresent: node, edgeGeometryPresent: edge, labelGeometryPresent: label)
            }
            guard clock.now < deadline else { throw EngramGraphResourceProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor public extension EngramGraphViewerController {
    /// Only fixed event names, flags and numeric geometry cross the host boundary.
    func recordLifecycleDiagnostic(_ event: EngramRenderLifecycleDiagnostic.Event,
        values: [String: Double] = [:], flags: [String: Bool] = [:]) {
        guard EngramRenderLifecycleDiagnostic.isEnabled else { return }
        var facts = flags
        var geometry = values
        if let size = sceneManager?.scene.clusterLabelViewportSize {
            geometry["viewportWidth"] = Double(size.width)
            geometry["viewportHeight"] = Double(size.height)
        }
        facts["controllerActive"] = isActive
        facts["hasSnapshot"] = snapshot != nil
        EngramRenderLifecycleDiagnostic.record(event, snapshot: try? renderedDiagnosticSnapshot(), values: geometry, flags: facts)
    }

    /// No buffer reads, new command buffers, or retained resource objects.
    func renderedDiagnosticSnapshot() throws -> EngramRenderDiagnosticSnapshot {
        guard let manager = sceneManager, snapshot != nil else { throw EngramGraphResourceProbeError.replaced }
        var value = manager.scene.renderDiagnosticSnapshot()
        value.counts["validatedFrames"] = manager.validatedRenderedFrameCount
        value.counts["completedForcePasses"] = manager.completedForcePassCount
        value.counts["selectedMemories"] = selectedMemoryID == nil ? 0 : 1
        value.flags["forcePending"] = manager.hasPendingForce
        value.flags["controllerActive"] = isActive
        value.flags["rendererFailed"] = rendererError != nil
        return value
    }
}
