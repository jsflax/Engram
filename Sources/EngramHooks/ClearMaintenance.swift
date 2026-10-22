import ArgumentParser
import EngramMemoryCore
#if canImport(EngramKit)
import EngramKit
import Lattice
#endif

/// Clears the maintenance-active flag. Called by the shell wrapper after
/// the maintenance subprocess finishes.
///
/// Also re-anchors the maintenance audit watermark at the current head, so
/// the agent's OWN writes (consolidate/organize/merge produce dozens of
/// Memory audit rows) never count toward the next trigger. Before this the
/// cooldown was the only thing standing between one maintenance run and the
/// next; with a 15-minute cooldown and a threshold of 50 the agent's output
/// re-armed the trigger by itself.
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
        setHookState(lattice, key: .maintenanceAuditWatermark, value: String(headId))
        hookLog("ClearMaintenance: set maintenanceActive=0, re-anchored audit watermark at \(headId)")
        #else
        hookLog("ClearMaintenance: no-op (remote backend — server owns maintenance)")
        #endif
    }
}
