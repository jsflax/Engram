import Foundation
import Lattice
import Observation
import os

/// Tab presentation belongs to the app, not the drawer's lifetime or a database
/// setter. One drain saves the latest pending selection while the UI stays live.
@MainActor @Observable
final class SidebarSelection {
    private(set) var selectedTab: SidebarTab
    private(set) var persistenceError: String?
    private(set) var isPersisting = false

    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var pending: Request?
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private let persist: @Sendable (SidebarTab) async throws -> Void
    private static let logger = Logger(subsystem: "io.engram.app", category: "SidebarPreference")

    private struct Request {
        let tab: SidebarTab
        let revision: UInt64
    }

    init(initialTab: SidebarTab,
         persist: @escaping @Sendable (SidebarTab) async throws -> Void) {
        selectedTab = initialTab
        self.persist = persist
    }

    convenience init(config: VisualizerConfig, lattice: Lattice) {
        let writer = SidebarPreferenceWriter(lattice: lattice.sendableReference,
                                             config: config.sendableReference)
        self.init(initialTab: config.selectedTab) { tab in
            try await writer.save(tab)
        }
    }

    /// This path only mutates memory. It never reads or writes a Lattice model.
    func select(_ tab: SidebarTab) {
        guard selectedTab != tab else { return }
        selectedTab = tab
        enqueue(tab)
    }

    func retryPersistence() {
        guard persistenceError != nil else { return }
        enqueue(selectedTab)
    }

    private func enqueue(_ tab: SidebarTab) {
        revision &+= 1
        pending = Request(tab: tab, revision: revision)
        persistenceError = nil
        guard drainTask == nil else { return }
        isPersisting = true
        // Capture the save operation separately. In particular, do not retain
        // self across its suspension: the app may disappear during a busy write.
        let persist = persist
        drainTask = Task { @MainActor [weak self, persist] in
            while !Task.isCancelled, let request = self?.takePending() {
                do {
                    try await persist(request.tab)
                    self?.didSave(request)
                } catch {
                    self?.didFail(request, error: error)
                }
            }
            self?.drainTask = nil
            self?.isPersisting = false
        }
    }

    private func takePending() -> Request? {
        defer { pending = nil }
        return pending
    }

    private func didSave(_ request: Request) {
        // An old completion acknowledges persistence only. It must never put
        // the UI back on a tab the user has already left.
        if request.revision == revision { persistenceError = nil }
    }

    private func didFail(_ request: Request, error: Error) {
        Self.logger.error("Could not save sidebar tab: \(error.localizedDescription, privacy: .public)")
        // Continue draining a newer pending selection after an older failure.
        // The current failure stays visible until an explicit retry/new choice.
        if request.revision == revision { persistenceError = error.localizedDescription }
    }

    deinit { drainTask?.cancel() }
}

/// Owns its Lattice and model on one actor. Neither the live UI model nor its
/// connection crosses isolation, and checked transactions report failed writes.
actor SidebarPreferenceWriter {
    private let latticeReference: LatticeThreadSafeReference
    private let configReference: ModelThreadSafeReference<VisualizerConfig>
    private var lattice: Lattice?

    init(lattice: LatticeThreadSafeReference, config: ModelThreadSafeReference<VisualizerConfig>) {
        latticeReference = lattice
        configReference = config
    }

    func save(_ tab: SidebarTab) throws {
        try Task.checkCancellation()
        let connection: Lattice
        if let lattice {
            connection = lattice
        } else {
            // Independent handles preserve the original schema/configuration
            // without retaining an actor scheduler. This actor serializes use;
            // a scheduler-bound handle would retain its owning actor in a cycle.
            guard let resolved = try latticeReference.resolveIndependent() else { throw SaveError.databaseUnavailable }
            lattice = resolved
            connection = resolved
        }
        // No suspension may occur inside a synchronous Lattice transaction.
        try connection.withTransaction {
            guard let config = configReference.resolve(on: connection) else { throw SaveError.configMissing }
            config.selectedTab = tab
        }
    }

    private enum SaveError: LocalizedError {
        case databaseUnavailable, configMissing

        var errorDescription: String? {
            switch self {
            case .databaseUnavailable: "The preferences database could not be opened."
            case .configMissing: "The saved visualizer preferences could not be found."
            }
        }
    }
}
