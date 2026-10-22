import ArgumentParser
import EngramMemoryCore
#if canImport(EngramKit)
import EngramKit
import Lattice
#endif

/// Clears the maintenance-active flag. Called by the shell wrapper after
/// the maintenance subprocess finishes.
///
/// Also best-effort re-anchors the maintenance audit watermark at the current
/// head. This excludes maintenance's own writes and any concurrent writes
/// observed through that head from the next trigger. AuditLog does not carry
/// a writer origin, so this is an approximate baseline, not attribution.
/// A failed head query preserves the old watermark for a later evaluation.
struct ClearMaintenance: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear-maintenance",
        abstract: "Clear the maintenance-active flag"
    )

    func run() {
        #if canImport(EngramKit)
        guard let lattice = openLattice() else {
            hookLog("ClearMaintenance: no database — nothing to clear")
            return
        }
        setHookState(lattice, key: .maintenanceActive, value: "0")
        let headId = lattice.objects(AuditLog.self)
            .sortedBy(\.primaryKey, order: .reverse)
            .first?.primaryKey ?? 0
        if let error = lattice.lastQueryError() {
            hookLog("ClearMaintenance: attempted active-flag cleanup; preserved audit watermark after query failure: \(error)")
            return
        }
        setHookState(lattice, key: .maintenanceAuditWatermark, value: String(headId))
        hookLog("ClearMaintenance: attempted active-flag cleanup and audit-watermark update to \(headId)")
        #else
        hookLog("ClearMaintenance: no-op (remote backend — server owns maintenance)")
        #endif
    }
}
