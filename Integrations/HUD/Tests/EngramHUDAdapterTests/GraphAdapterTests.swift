import AppKit
import Foundation
import Testing
import EngramMemoryCore
import EngramGraphSurface
@testable import EngramHUDAdapter

private actor ControlledDecoder: GraphSnapshotDecoding {
    private var pending: [Int: CheckedContinuation<EngramGraphSnapshot, any Error>] = [:]
    private var arrivals: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var inputs: [Data] = []
    func decode(_ data: Data) async throws -> EngramGraphSnapshot {
        let index = inputs.count; inputs.append(data)
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation; arrivals.removeValue(forKey: index)?.resume()
        }
    }
    func arrived(_ index: Int) async {
        if pending[index] != nil { return }
        await withCheckedContinuation { arrivals[index] = $0 }
    }
    func finish(_ index: Int, _ result: Result<EngramGraphSnapshot, any Error>) {
        pending.removeValue(forKey: index)?.resume(with: result)
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor struct GraphAdapterTests {
    func scope(_ project: String = "hud", workspace: String = "owner", topics: [String] = ["design"]) throws -> EngramGraphScope {
        try EngramGraphScope(workspaceID: workspace, project: project, topics: topics)
    }
    func identity(_ scope: EngramGraphScope, instance: String = "instance-1") -> [String: String] {
        ["providerIdentifier": EngramHUDGraphWire.provider, "viewIdentifier": EngramHUDGraphWire.view,
         "connectionIdentifier": "connection-1", "documentIdentifier": "document-1", "documentLifetimeIdentifier": "lifetime-1",
         "instanceIdentifier": instance, "workspaceIdentifier": scope.workspaceID,
         "resourceIdentifier": EngramHUDGraphWire.resourceIdentifier(for: scope)]
    }
    func graph(_ scope: EngramGraphScope, _ revision: UInt64) throws -> EngramGraphSnapshot {
        try EngramGraphSnapshot(scope: scope, revision: revision, completeness: .complete, nodes: [], edges: [])
    }
    func envelope(_ scope: EngramGraphScope, _ revision: UInt64, phase: String = "ready", data: Data = Data([1])) -> [String: Any] {
        var values: [String: Any] = ["scope": EngramHUDGraphWire.scopeValues(scope), "phase": phase]
        if phase == "ready" { values["graphJSON"] = data }
        return ["schemaIdentifier": EngramHUDGraphWire.snapshotSchema, "schemaVersion": 1, "revision": revision, "values": values]
    }
    private func controller(_ scope: EngramGraphScope, decoder: ControlledDecoder, instance: String = "instance-1") throws -> EngramHUDGraphController {
        let value = try EngramHUDGraphController(identity: identity(scope, instance: instance), savedState: nil, decoder: decoder)
        value.identityIsCurrent = { true }; return value
    }

    @Test func selectorIsCanonicalAndExactWithoutGrantingAuthority() throws {
        #expect(EngramHUDGraphWire.provider == "engram")
        let a = try scope(topics: ["code", "design"]), b = try scope(topics: ["design", "code"])
        #expect(EngramHUDGraphWire.resourceIdentifier(for: a) == EngramHUDGraphWire.resourceIdentifier(for: b))
        let other = try scope(workspace: "other", topics: ["code", "design"])
        #expect(EngramHUDGraphWire.resourceIdentifier(for: a) != EngramHUDGraphWire.resourceIdentifier(for: other))
        #expect(throws: (any Error).self) { try EngramHUDGraphWire.require(other, identity: identity(a)) }
    }
    @Test func wireRejectsOversizedDataUnknownFieldsAndWrongSchema() throws {
        let scope = try scope()
        #expect(throws: (any Error).self) {
            try GraphEnvelope(envelope(scope, 1, data: Data(repeating: 0, count: EngramHUDGraphWire.maximumGraphBytes + 1)))
        }
        var extra = envelope(scope, 1); extra["url"] = "https://invalid.example"
        #expect(throws: (any Error).self) { try GraphEnvelope(extra) }
        var wrong = envelope(scope, 1); wrong["schemaVersion"] = 2
        #expect(throws: (any Error).self) { try GraphEnvelope(wrong) }
    }
    @Test(arguments: [false, true])
    func appearanceBeforeLoadAndLaterUpdatesStayLocalToTheProvider(_ dark: Bool) throws {
        let scope = try scope(), controller = try controller(scope, decoder: ControlledDecoder())
        defer { controller.invalidateGraph() }
        func appearance(_ dark: Bool) -> [String: Any] {
            ["appearanceVersion": 1, "presentation": "embedded", "colorScheme": dark ? "dark" : "light",
             "colors": [String: Any](), "fonts": [String: Any](), "metrics": [String: Any]()]
        }
        let initial: NSAppearance.Name = dark ? .darkAqua : .aqua
        let updated: NSAppearance.Name = dark ? .aqua : .darkAqua
        #expect(!controller.isViewLoaded)
        try controller.applyNativeAppearance(appearance(dark))
        try controller.admitSnapshot(envelope(scope, 1, phase: "loading"))
        #expect(!controller.isViewLoaded)

        // Match the real pre-load ABI call order, with an oppositely styled embedding host.
        let host = NSView(frame: .zero)
        host.appearance = NSAppearance(named: updated)
        let container = controller.view
        host.addSubview(container)
        let hosting = try #require(container.subviews.first)
        #expect(container.appearance?.name == initial)
        #expect(hosting.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == initial)
        #expect(host.appearance?.name == updated)

        try controller.applyNativeAppearance(appearance(!dark))
        #expect(container.appearance?.name == updated)
        #expect(hosting.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == updated)
        #expect(host.appearance?.name == updated)
        #expect(controller.session?.visibility == .suspended)
        #expect(controller.currentDecodeTask == nil)
    }
    @Test func startsSuspendedAndDecodesOnlyAfterVisible() async throws {
        let scope = try scope(), decoder = ControlledDecoder(), view = try controller(scope, decoder: decoder)
        defer { view.invalidateGraph() }
        try view.admitSnapshot(envelope(scope, 1))
        #expect(await decoder.inputs.isEmpty)
        #expect(view.session?.visibility == .suspended)
        #expect(view.preferredNativeFocusView(forPurpose: 1) == nil)
        view.setNativeVisibility(0)
        await decoder.arrived(0)
        let task = try #require(view.currentDecodeTask)
        await decoder.finish(0, .success(try graph(scope, 1))); await task.value
        #expect(view.session?.snapshot?.revision == 1)
        #expect(view.session?.loadState == .ready)
    }
    @Test func coalescesSuccessorsAndRejectsLateResultAndStaleEnvelope() async throws {
        let scope = try scope(), decoder = ControlledDecoder(), view = try controller(scope, decoder: decoder)
        defer { view.invalidateGraph() }
        view.setNativeVisibility(0); try view.admitSnapshot(envelope(scope, 1, data: Data([1])))
        await decoder.arrived(0)
        let task = try #require(view.currentDecodeTask)
        try view.admitSnapshot(envelope(scope, 2, data: Data([2])))
        try view.admitSnapshot(envelope(scope, 3, data: Data([3])))
        #expect(throws: (any Error).self) { try view.admitSnapshot(envelope(scope, 2)) }
        await decoder.finish(0, .success(try graph(scope, 1)))
        await decoder.arrived(1)
        #expect(view.session?.snapshot == nil)
        #expect(await decoder.inputs == [Data([1]), Data([3])])
        await decoder.finish(1, .success(try graph(scope, 3))); await task.value
        #expect(view.session?.snapshot?.revision == 3)
    }
    @Test func failedAndWrongScopeDecodePreserveLastValidGraph() async throws {
        let scope = try scope(), decoder = ControlledDecoder(), view = try controller(scope, decoder: decoder)
        defer { view.invalidateGraph() }
        view.setNativeVisibility(0); try view.admitSnapshot(envelope(scope, 1))
        await decoder.arrived(0); let first = try #require(view.currentDecodeTask)
        await decoder.finish(0, .success(try graph(scope, 1))); await first.value
        try view.admitSnapshot(envelope(scope, 2)); await decoder.arrived(1)
        let second = try #require(view.currentDecodeTask)
        await decoder.finish(1, .success(try graph(self.scope("other"), 2))); await second.value
        #expect(view.session?.snapshot?.revision == 1)
        #expect(view.session?.loadState == .failed)
        try view.admitSnapshot(envelope(scope, 3, phase: "failed"))
        #expect(view.session?.snapshot?.revision == 1)
        try view.admitSnapshot(envelope(scope, 4)); await decoder.arrived(2)
        let third = try #require(view.currentDecodeTask)
        await decoder.finish(2, .failure(GraphWireError.invalidEnvelope)); await third.value
        #expect(view.session?.snapshot?.revision == 1)
    }
    @Test func hiddenDecodeDoesNotPublishAndResumeUsesLatestPending() async throws {
        let scope = try scope(), decoder = ControlledDecoder(), view = try controller(scope, decoder: decoder)
        defer { view.invalidateGraph() }
        view.setNativeVisibility(0); try view.admitSnapshot(envelope(scope, 1))
        await decoder.arrived(0); let first = try #require(view.currentDecodeTask)
        view.setNativeVisibility(1)
        await decoder.finish(0, .success(try graph(scope, 1))); await first.value
        #expect(view.session?.snapshot == nil)
        #expect(view.preferredNativeFocusView(forPurpose: 1) == nil)
        try view.admitSnapshot(envelope(scope, 2)); view.setNativeVisibility(0)
        await decoder.arrived(1); let second = try #require(view.currentDecodeTask)
        await decoder.finish(1, .success(try graph(scope, 2))); await second.value
        #expect(view.session?.snapshot?.revision == 2)
    }
    @Test func contextMutationAndInvalidationFenceLateDecodeAndStateCapture() async throws {
        let scope = try scope(), decoder = ControlledDecoder(), view = try controller(scope, decoder: decoder)
        var current = true; view.identityIsCurrent = { current }
        view.setNativeVisibility(0); try view.admitSnapshot(envelope(scope, 1))
        await decoder.arrived(0); let task = try #require(view.currentDecodeTask)
        current = false
        #expect(throws: (any Error).self) { try view.captureNativeState() }
        await decoder.finish(0, .success(try graph(scope, 1))); await task.value
        #expect(view.session == nil)
        #expect(view.preferredNativeFocusView(forPurpose: 1) == nil)
        current = true
        #expect(throws: (any Error).self) { try view.admitSnapshot(envelope(scope, 2)) }
        view.invalidateGraph()
    }
    @Test func twoInstancesDoNotShareDecodeOrLifetime() async throws {
        let scope = try scope(), firstDecoder = ControlledDecoder(), secondDecoder = ControlledDecoder()
        let first = try controller(scope, decoder: firstDecoder), second = try controller(scope, decoder: secondDecoder, instance: "instance-2")
        defer { first.invalidateGraph(); second.invalidateGraph() }
        first.setNativeVisibility(0); second.setNativeVisibility(0)
        try first.admitSnapshot(envelope(scope, 1)); try second.admitSnapshot(envelope(scope, 1))
        await firstDecoder.arrived(0); await secondDecoder.arrived(0)
        let firstTask = try #require(first.currentDecodeTask), secondTask = try #require(second.currentDecodeTask)
        first.invalidateGraph()
        await firstDecoder.finish(0, .success(try graph(scope, 1)))
        await secondDecoder.finish(0, .success(try graph(scope, 1)))
        await firstTask.value; await secondTask.value
        #expect(first.session == nil)
        #expect(second.session?.identity.instanceID == "instance-2")
        #expect(second.session?.snapshot?.revision == 1)
    }
    @Test func restoredStorageDeliveryRevisionSeedsProviderWithoutChangingCamera() throws {
        let scope = try scope(), camera = try EngramGraphViewState(selectedNode: nil, azimuth: 0.25,
            elevation: 0.125, target: .init(x: 1, y: 2, z: 3), orbitRadius: 100)
        // The host stores exactly these camera values under a higher outer delivery revision.
        let saved = try GraphSavedState.envelope(scope: scope, state: camera, revision: 101)
        let controller = try EngramHUDGraphController(identity: identity(scope), savedState: saved)
        defer { controller.invalidateGraph() }
        controller.identityIsCurrent = { true }
        let before = try GraphSavedState(controller.captureNativeState())
        #expect(before.revision == 101 && before.state == camera)
        try controller.admitSnapshot(envelope(scope, 1, phase: "loading"))
        controller.setNativeVisibility(0)
        let session = try #require(controller.session)
        // Exercise the provider's actual state callback without a renderer/window or frame loop.
        session.onStateChange?(session.identity, try session.captureState())
        let after = try GraphSavedState(controller.captureNativeState())
        #expect(after.revision == 102 && after.scope == scope && after.state == camera)
    }
    @Test func boundedSavedCameraRoundTripsAndCannotWidenScope() throws {
        let scope = try scope(), camera = try EngramGraphViewState(selectedNode: nil, azimuth: 0.2,
            elevation: 0.1, target: .init(x: 1, y: 2, z: 3), orbitRadius: 100)
        let saved = try GraphSavedState.envelope(scope: scope, state: camera, revision: 2)
        let controller = try EngramHUDGraphController(identity: identity(scope), savedState: saved)
        defer { controller.invalidateGraph() }
        controller.identityIsCurrent = { true }
        let captured = try GraphSavedState(controller.captureNativeState())
        #expect(captured.state == camera && captured.scope == scope && captured.revision == 2)
        #expect(throws: (any Error).self) {
            try EngramHUDGraphController(identity: identity(self.scope("another")), savedState: saved)
        }
    }
}
