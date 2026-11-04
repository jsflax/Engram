import Foundation
import Lattice
import Observation
import os

struct SidebarDatabaseMaintenanceResult: Sendable {
    let message: String
    let isIncomplete: Bool
    let diagnostics: [String]

    static func summarize(historyRemoved: Int64, historyError: String?,
                          vacuumSucceeded: Bool, vacuumError: String?,
                          checkpointedFrames: Int64, checkpointError: String?) -> Self {
        var messages: [String] = []
        var diagnostics: [String] = []
        var incomplete = false
        if let historyError {
            messages.append("History cleanup failed.")
            diagnostics.append("History cleanup: \(historyError)")
            incomplete = true
        } else if historyRemoved == -1 {
            // No writer replication slots: compactHistory deliberately keeps
            // all history. Do not substitute a different retention policy.
            messages.append("History was preserved.")
        } else if historyRemoved < 0 {
            messages.append("History cleanup could not be confirmed.")
            incomplete = true
        }
        if vacuumSucceeded && vacuumError == nil {
            messages.append("Database compacted.")
        } else {
            messages.append("Database compaction failed.")
            diagnostics.append("Database compaction: \(vacuumError ?? "VACUUM returned false")")
            incomplete = true
        }
        if let checkpointError {
            messages.append("Final cleanup could not finish.")
            diagnostics.append("Final cleanup: \(checkpointError)")
            incomplete = true
        } else if checkpointedFrames < 0 {
            messages.append("Final cleanup was deferred.")
            incomplete = true
        }
        // A bounded checkpoint may fall back to PASSIVE. A nonnegative frame
        // count does not establish WAL truncation, so make no such claim.
        return Self(message: messages.joined(separator: " "),
                    isIncomplete: incomplete, diagnostics: diagnostics)
    }
}

/// A separate serial executor owns the maintenance connection. Only Lattice's
/// supported Sendable reference crosses from the UI; its live handle does not.
actor SidebarDatabaseMaintenanceWorker {
    typealias Operation = @Sendable (LatticeThreadSafeReference) -> SidebarDatabaseMaintenanceResult
    private let operation: Operation

    init() {
        operation = Self.perform
    }

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    func run(_ reference: LatticeThreadSafeReference) -> SidebarDatabaseMaintenanceResult {
        operation(reference)
    }

    private nonisolated static func perform(_ reference: LatticeThreadSafeReference) -> SidebarDatabaseMaintenanceResult {
        do {
            // Preserves the existing schema/configuration/migrations, and does
            // not cache or retain this actor's scheduler. Never create a blank
            // replacement if the original store has been removed.
            guard let connection = try reference.resolveIndependent() else {
                return .init(message: "The database is no longer available.",
                             isIncomplete: true, diagnostics: [])
            }
            defer { connection.close() }

            let historyRemoved = connection.compactHistory()
            let historyError = connection.lastQueryError()
            let vacuumSucceeded = connection.vacuum()
            let vacuumError = connection.lastQueryError()
            // A full checkpoint can hold the shared writer gate for 30s,
            // indirectly blocking UI getters even from this worker actor.
            let checkpointedFrames = connection.checkpointBounded()
            let checkpointError = connection.lastQueryError()
            return .summarize(historyRemoved: historyRemoved, historyError: historyError,
                              vacuumSucceeded: vacuumSucceeded, vacuumError: vacuumError,
                              checkpointedFrames: checkpointedFrames, checkpointError: checkpointError)
        } catch {
            return .init(message: "Couldn't open the database for compaction.",
                         isIncomplete: true, diagnostics: [String(describing: error)])
        }
    }
}

/// Shared across drawer recreation so closing/reopening the sidebar cannot
/// queue a second compaction while the first one is still running.
@MainActor @Observable
final class SidebarDatabaseMaintenance {
    static let shared = SidebarDatabaseMaintenance()
    private(set) var isRunning = false
    private(set) var result: SidebarDatabaseMaintenanceResult?
    @ObservationIgnored private let worker: SidebarDatabaseMaintenanceWorker
    private static let logger = Logger(subsystem: "io.engram.app", category: "DatabaseMaintenance")

    init(worker: SidebarDatabaseMaintenanceWorker = .init()) {
        self.worker = worker
    }

    func start(_ reference: LatticeThreadSafeReference) {
        guard !isRunning else { return }
        isRunning = true
        result = nil
        Task {
            let outcome = await worker.run(reference)
            result = outcome
            isRunning = false
            if outcome.isIncomplete {
                Self.logger.error("\(outcome.message, privacy: .public)")
                for diagnostic in outcome.diagnostics {
                    Self.logger.error("\(diagnostic, privacy: .private)")
                }
            }
        }
    }
}
