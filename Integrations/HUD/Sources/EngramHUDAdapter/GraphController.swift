import AppKit
import SwiftUI
import EngramMemoryCore
import EngramGraphSurface
import HUDNativeViewABI

/// ObjC/AppKit export only. No Swift values cross the separately loaded provider boundary.
/// applySnapshot admits a validated envelope; decoding may finish later and fail visibly.
@objc(EngramHUDGraphController)
@MainActor public final class EngramHUDGraphController: NSViewController {
    @objc public var identityIsCurrent: (() -> Bool)?
    @objc public var viewStateChanged: (() -> Void)?
    private let identity: [String: String]
    private let decoder: any GraphSnapshotDecoding
    private var saved: GraphSavedState?
    private(set) var session: EngramGraphSession?
    private var appearance = EngramGraphAppearance()
    private var hosting: NSHostingView<EngramGraphSurface>?
    private var visibility: EngramGraphVisibility = .suspended
    private var invalidated = false
    private var admittedRevision: UInt64?
    private var stateRevision: UInt64 = 0
    private var pending: GraphEnvelope?
    private var ticket: EngramGraphLoadTicket?
    private var decoding: Task<Void, Never>?
    // Deterministic test/qualification joining, not a polling or delivery mechanism.
    var currentDecodeTask: Task<Void, Never>? { decoding }

    @objc(initWithIdentity:savedState:error:)
    public convenience init(identity: [String: String], savedState: [String: Any]?) throws {
        try self.init(identity: identity, savedState: savedState, decoder: GraphSnapshotDecoder())
    }
    init(identity: [String: String], savedState: [String: Any]?, decoder: any GraphSnapshotDecoding) throws {
        guard identity["providerIdentifier"] == EngramHUDGraphWire.provider,
              identity["viewIdentifier"] == EngramHUDGraphWire.view,
              identity["workspaceIdentifier"] != nil else { throw GraphWireError.identityMismatch }
        for key in ["connectionIdentifier", "documentIdentifier", "documentLifetimeIdentifier", "instanceIdentifier",
                    "resourceIdentifier", "workspaceIdentifier"] {
            guard let value = identity[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= 256, !value.utf8.contains(0) else { throw GraphWireError.identityMismatch }
        }
        self.identity = identity; self.decoder = decoder
        if let savedState {
            let saved = try GraphSavedState(savedState)
            try EngramHUDGraphWire.require(saved.scope, identity: identity)
            self.saved = saved; stateRevision = saved.revision
        }
        super.init(nibName: nil, bundle: nil)
    }
    required public init?(coder: NSCoder) { nil }

    public override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        // The host may supply appearance before AppKit asks for the provider view.
        container.appearance = NSAppearance(named: appearance.colorScheme == .dark ? .darkAqua : .aqua)
        view = container
        if let session { installSurface(session) }
        else {
            let label = NSTextField(labelWithString: "Waiting for project graph")
            label.alignment = .center; label.frame = container.bounds
            label.autoresizingMask = [.width, .height]; container.addSubview(label)
        }
    }
    private func installSurface(_ session: EngramGraphSession) {
        guard isViewLoaded, hosting == nil else { return }
        view.subviews.forEach { $0.removeFromSuperview() }
        let hosting = NSHostingView(rootView: EngramGraphSurface(session: session, appearance: appearance))
        hosting.frame = view.bounds; hosting.autoresizingMask = [.width, .height]
        view.addSubview(hosting); self.hosting = hosting
    }
    private func requireCurrent() throws {
        guard !invalidated else { throw GraphWireError.invalidated }
        guard identityIsCurrent?() == true else { throw GraphWireError.identityMismatch }
        if let session { try EngramHUDGraphWire.require(session.identity.scope, identity: identity) }
    }

    @objc(admitSnapshot:error:)
    public func admitSnapshot(_ snapshot: [String: Any]) throws {
        try requireCurrent()
        let envelope = try GraphEnvelope(snapshot)
        try EngramHUDGraphWire.require(envelope.scope, identity: identity)
        if let admittedRevision, envelope.revision <= admittedRevision { throw GraphWireError.staleRevision }
        if let session, session.identity.scope != envelope.scope { throw GraphWireError.identityMismatch }
        if session == nil {
            let scoped = try EngramGraphSessionIdentity(connectionID: identity["connectionIdentifier"]!,
                documentID: identity["documentIdentifier"]!, documentLifetimeID: identity["documentLifetimeIdentifier"]!,
                instanceID: identity["instanceIdentifier"]!, scope: envelope.scope)
            let session = EngramGraphSession(identity: scoped, savedState: saved?.state)
            session.onStateChange = { [weak self] source, _ in
                guard let self, (try? self.requireCurrent()) != nil,
                      self.session?.identity == source, self.visibility == .visible else { return }
                guard self.stateRevision < EngramGraphLimits.maximumRevision else { return }
                self.stateRevision += 1
                self.viewStateChanged?()
            }
            self.session = session; saved = nil
            session.setVisibility(visibility)
            installSurface(session)
        }
        guard let session else { throw GraphWireError.unavailable }
        admittedRevision = envelope.revision
        pending = nil
        let ticket = try session.beginLoading(); self.ticket = ticket
        switch envelope.phase {
        case .loading: break
        case .failed: try session.loadingFailed(for: ticket, from: session.identity)
        case .ready: pending = envelope; startDecodeIfVisible()
        }
    }

    private func startDecodeIfVisible() {
        guard visibility == .visible, !invalidated, pending != nil, decoding == nil else { return }
        decoding = Task { [weak self] in
            guard let self else { return }
            defer { self.decoding = nil }
            // One current decode and one replaceable successor; no unbounded actor/task mailbox.
            while !Task.isCancelled, self.visibility == .visible, let next = self.pending,
                  let data = next.data, let ticket = self.ticket, let session = self.session {
                let result: Result<EngramGraphSnapshot, any Error>
                do { result = .success(try await self.decoder.decode(data)) }
                catch { result = .failure(error) }
                guard !Task.isCancelled, !self.invalidated else { return }
                guard (try? self.requireCurrent()) != nil else { self.invalidateGraph(); return }
                // A newer loading/failure envelope also cancels this exact graph publication.
                guard self.admittedRevision == next.revision, self.pending?.revision == next.revision,
                      self.ticket == ticket, self.session === session else { continue }
                guard self.visibility == .visible else { return } // Keep pending for explicit resume.
                self.pending = nil
                do {
                    let value = try result.get()
                    guard value.scope == next.scope else { throw GraphWireError.identityMismatch }
                    try EngramHUDGraphWire.require(value.scope, identity: self.identity)
                    try session.apply(value, from: session.identity, for: ticket)
                } catch {
                    // Failed/stale/mismatched data cannot replace the last valid graph.
                    try? session.loadingFailed(for: ticket, from: session.identity)
                }
            }
        }
    }

    @objc(applyNativeAppearance:error:)
    public func applyNativeAppearance(_ raw: [String: Any]) throws {
        try requireCurrent()
        var error: NSError?
        guard let copy = HUDNativeCopyAppearanceV1(raw, &error) else {
            throw error ?? GraphWireError.invalidEnvelope as NSError
        }
        appearance = NativeGraphAppearance.make(copy)
        if isViewLoaded {
            view.appearance = NSAppearance(named: appearance.colorScheme == .dark ? .darkAqua : .aqua)
        }
        if let session { hosting?.rootView = EngramGraphSurface(session: session, appearance: appearance) }
    }
    @objc(setNativeVisibility:)
    public func setNativeVisibility(_ raw: Int) {
        guard !invalidated else { return }
        guard (try? requireCurrent()) != nil else { invalidateGraph(); return }
        visibility = raw == 0 ? .visible : raw == 1 ? .hidden : .suspended
        session?.setVisibility(visibility)
        if visibility == .visible { startDecodeIfVisible() }
    }
    @objc(preferredNativeFocusViewForPurpose:)
    public func preferredNativeFocusView(forPurpose purpose: Int) -> NSView? {
        guard purpose == 1, visibility == .visible, (try? requireCurrent()) != nil else { return nil }
        return session?.preferredContentFocusView
    }
    @objc(captureNativeStateWithError:)
    public func captureNativeState() throws -> [String: Any] {
        try requireCurrent()
        if let session {
            return try GraphSavedState.envelope(scope: session.identity.scope, state: session.captureState(), revision: stateRevision)
        }
        if let saved { return try GraphSavedState.envelope(scope: saved.scope, state: saved.state, revision: stateRevision) }
        throw GraphWireError.unavailable
    }
    @objc public func invalidateGraph() {
        guard !invalidated else { return }
        invalidated = true; visibility = .suspended; pending = nil; ticket = nil; saved = nil
        decoding?.cancel()
        session?.onStateChange = nil; session?.invalidate()
        hosting?.removeFromSuperview(); hosting = nil; session = nil
        identityIsCurrent = nil; viewStateChanged = nil
        if isViewLoaded { view.subviews.forEach { $0.removeFromSuperview() } }
    }
}

private enum NativeGraphAppearance {
    static func make(_ raw: [String: Any]) -> EngramGraphAppearance {
        var result = EngramGraphAppearance()
        result.colorScheme = raw["colorScheme"] as? String == "dark" ? .dark : .light
        let colors = raw["colors"] as? [String: [NSNumber]] ?? [:]
        func color(_ key: String, fallback: Color) -> Color {
            guard let v = colors[key], v.count == 4 else { return fallback }
            return Color(.sRGB, red: v[0].doubleValue, green: v[1].doubleValue,
                         blue: v[2].doubleValue, opacity: v[3].doubleValue)
        }
        result.background = color("panelBase", fallback: result.colorScheme == .dark ? .black : .white)
        result.primaryText = color("primaryText", fallback: .primary)
        result.secondaryText = color("secondaryText", fallback: .secondary)
        result.accent = color("accent", fallback: .accentColor)
        let fonts = raw["fonts"] as? [String: [String: Any]] ?? [:]
        func font(_ key: String, fallback: Font) -> Font {
            guard let descriptor = fonts[key], let size = descriptor["pointSize"] as? NSNumber,
                  let family = descriptor["family"] as? String else { return fallback }
            let weight = (descriptor["weight"] as? NSNumber)?.doubleValue ?? 0
            let fontWeight: Font.Weight = weight >= 0.5 ? .bold : weight > 0 ? .semibold : weight < -0.3 ? .light : .regular
            if family == "system" {
                return .system(size: size.doubleValue, weight: fontWeight,
                    design: descriptor["monospaced"] as? Bool == true ? .monospaced : .default)
            }
            return .custom(family, size: size.doubleValue).weight(fontWeight)
        }
        result.headline = font("headline", fallback: .headline)
        result.caption = font("caption", fallback: .caption)
        if let radius = (raw["metrics"] as? [String: NSNumber])?["cardRadius"] { result.cardRadius = CGFloat(radius.doubleValue) }
        return result
    }
}
