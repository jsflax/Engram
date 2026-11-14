import Foundation
import RealityKit
import OSLog
import Darwin

/// Scalar-only observations for an explicitly requested synthetic diagnostic.
/// Identity strings describe only this process incarnation and retain no resources.
/// Stored reference objects only: ModelComponent.mesh may return temporary wrappers
/// whose addresses neither identify nor establish replacement of the GPU resource.
/// Frame callbacks are evidence of hosted updates, not a GPU presentation fence.
public struct EngramRenderDiagnosticSnapshot: Codable, Sendable {
    public var frame: UInt64
    public var topology: UInt64
    public var resources: [String: String]
    public var counts: [String: Int]
    public var flags: [String: Bool]
    public var atlasCreations: UInt64
    public var labelMaterialAssignments: UInt64
}

@MainActor public extension EngramRealityScene {
    func renderDiagnosticSnapshot() -> EngramRenderDiagnosticSnapshot {
        func identity(_ value: AnyObject?) -> String {
            value.map { String(describing: ObjectIdentifier($0)) } ?? "absent"
        }
        var resources = ["scene": identity(self), "sceneGeneration": diagnosticGeneration, "root": identity(rootEntity),
            "nodeEntity": identity(nodeTemplateEntity ?? nodeBatchEntity),
            "edgeEntity": identity(edgeTemplateEntity ?? edgeBatchEntity),
            "labelEntity": identity(labelBatchEntity),
            "labelLowLevelMesh": identity(labelBatchMesh),
            "nodeTexture": identity(nodeInstanceTexture), "edgeTexture": identity(edgeInstanceTexture),
            "labelAtlas": identity(labelAtlasGenerator.atlasTexture)]
        var counts = ["nodes": dataProvider?.nodes.count ?? 0, "edges": dataProvider?.edges.count ?? 0,
            "visibleNodes": visibleSet.nearNodes.count + visibleSet.midNodes.count + visibleSet.farNodes.count,
            "visibleEdges": visibleSet.visibleEdgeIndices.count, "visibleLabels": visibleSet.visibleLabelIndices.count,
            "labelCapacity": labelBatchCapacity,
            "pendingFrameSubmissions": pendingFrameSubmissionCount,
            "attachedContentHosts": attachedContentHostCount]
        if #available(macOS 26, iOS 26, *) {
            resources["nodeInstances"] = identity(nodeInstanceData)
            resources["edgeInstances"] = identity(edgeInstanceData)
            counts["nodeInstanceCount"] = nodeInstanceData?.instanceCount ?? 0
            counts["edgeInstanceCount"] = edgeInstanceData?.instanceCount ?? 0
            counts["nodeInstanceCapacity"] = nodeInstanceData?.instanceCapacity ?? 0
            counts["edgeInstanceCapacity"] = edgeInstanceData?.instanceCapacity ?? 0
        }
        return .init(frame: frameCount, topology: dataProvider?.topologyVersion ?? 0,
            resources: resources, counts: counts,
            flags: ["active": isActive, "tornDown": isTornDown,
                "resourcesReleased": resourcesReleased,
                "rootEnabled": rootEntity.isEnabled,
                "nodeEnabled": (nodeTemplateEntity ?? nodeBatchEntity)?.isEnabled ?? false,
                "edgeEnabled": (edgeTemplateEntity ?? edgeBatchEntity)?.isEnabled ?? false,
                "labelEnabled": labelBatchEntity?.isEnabled ?? false],
            atlasCreations: labelAtlasGenerator.diagnosticAtlasCreations,
            labelMaterialAssignments: labelBatchSystem.diagnosticMaterialAssignments)
    }
}


/// Opt-in, fixed/scalar-only lifecycle evidence. No graph identifiers/content,
/// buffer reads, new Metal work, timers, or retained rendering resource objects.
/// The private file is synchronous crash evidence, not a renderer completion fence.
@MainActor public enum EngramRenderLifecycleDiagnostic {
    public static let isEnabled = ProcessInfo.processInfo.environment["ENGRAM_RENDER_LIFECYCLE_DIAGNOSTIC"] == "1"
    public enum Event: String {
        case browserAppeared, browserDisappearing, browserActivity, browserScenePhase, browserScopeChanged
        case browserLoadStarting, browserLoadFinished, browserAccessInfoChanged, browserAccessInfoAppeared, browserAccessInfoDisappeared
        case controllerClearStarting, controllerClearFinished, controllerActivity, controllerCreatedRenderer
        case selectionChanged, filtersChanged
        case graphAppeared, graphDisappearing, graphGeometry, graphChrome, graphInspector
        case mobileSheetChanged, mobileSheetAppeared, mobileSheetDisappeared
        case realityAppeared, realityDisappearing, realitySynchronized
        case sceneCreated, sceneSetupCompleted, sceneActivity, contentAttached, contentDetaching, contentDetached
        case teardownStarting, retirementWaiting, resourcesReleasing, resourcesReleased
        case resourceGenerationChanged, framePulse, eventLimitReached
    }
    private struct Entry: Encodable {
        let version = 1
        let pid: Int32
        let runID: String
        let sequence: Int
        let uptimeNanoseconds: UInt64
        let event: String
        let fileName: String
        let snapshot: EngramRenderDiagnosticSnapshot?
        let values: [String: Double]
        let flags: [String: Bool]
    }
    private static let runID = UUID().uuidString.lowercased()
    private static let fileName = "engram-render-lifecycle-" + String(getpid()) + "-" + runID + ".jsonl"
    private static let logger = Logger(subsystem: "io.engram.renderer", category: "lifecycle")
    private static var sequence = 0
    private static var reportedIOFailure = false
    private static var lastGeometryEmission: [String: UInt64] = [:]
    private static let limit = 512
    private static let sink: FileHandle? = {
        guard isEnabled else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { return nil }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }()

    public static func record(_ event: Event,
        snapshot: @autoclosure () -> EngramRenderDiagnosticSnapshot? = nil,
        values: [String: Double] = [:], flags: [String: Bool] = [:]) {
        guard isEnabled, sequence <= limit else { return }
        let tick = DispatchTime.now().uptimeNanoseconds
        if event == .graphGeometry || event == .graphChrome || event == .graphInspector {
            if let previous = lastGeometryEmission[event.rawValue], tick - previous < 100_000_000 { return }
            lastGeometryEmission[event.rawValue] = tick
        }
        let limited = sequence == limit
        sequence += 1
        let entry = Entry(pid: getpid(), runID: runID, sequence: sequence,
            uptimeNanoseconds: tick,
            event: (limited ? Event.eventLimitReached : event).rawValue, fileName: fileName,
            snapshot: limited ? nil : snapshot(),
            values: limited ? [:] : values.filter { $0.value.isFinite }, flags: limited ? [:] : flags)
        guard let data = try? JSONEncoder().encode(entry), data.count <= 8192 else { return }
        var line = data; line.append(0x0a)
        do {
            guard let sink else { throw CocoaError(.fileWriteUnknown) }
            try sink.write(contentsOf: line)
            try sink.synchronize()
        } catch {
            if !reportedIOFailure {
                reportedIOFailure = true
                logger.error("ENGRAM_RENDER_LIFECYCLE_IO_FAILED")
            }
        }
        // One full line per event; stderr may be absent from xcresult, so retain
        // both the owned file and public scalar unified-log fallback.
        try? FileHandle.standardError.write(contentsOf: line)
        logger.notice("ENGRAM_RENDER_LIFECYCLE \(String(decoding: data, as: UTF8.self), privacy: .public)")
    }
}
