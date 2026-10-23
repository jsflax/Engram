import Testing
import EngramKit
import EngramModels
import Lattice
import Foundation

// MARK: - Maintenance trigger: audit watermark semantics
//
// The advise hook decides whether to spawn the memory-maintenance subprocess
// by counting audit rows. It used to count `tableName == "Memory" AND
// timestamp > lastRun`, which on a 3.96M-row audit log takes 3.8s warm — on
// every prompt once past the cooldown, unbudgeted, inside the hook's window.
// It now counts above an initially seeded or completion PRIMARY KEY watermark,
// which the index can answer without visiting the table (0.05s on the same
// database).
//
// `Advise.spawnMaintenanceIfNeeded` lives in an executable target, so these
// tests pin the two Lattice query primitives it is built on — a silent change
// in either would change the spawn cadence with no other symptom.

@Suite("Maintenance audit watermark")
struct MaintenanceTriggerTests {

    private func makeLattice() throws -> Lattice {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "maintenance-watermark-\(UUID().uuidString).sqlite")
        return try Lattice(
            Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self,
            configuration: .init(fileURL: path))
    }

    /// `sortedBy(\.primaryKey, order: .reverse).first` must be the audit
    /// log's head. `Model.primaryKey` is not a macro-generated property, so
    /// it resolves through `_name(for:)`'s "id" fallback — if that ever
    /// stopped landing on the `id` column the watermark would anchor
    /// somewhere meaningless and maintenance would stop firing.
    @Test func auditHead_isTheMaxPrimaryKey() async throws {
        let lattice = try makeLattice()
        for i in 0..<20 {
            try lattice.add(Memory(content: "watermark probe \(i)", project: "WM"))
        }
        let all = lattice.objects(AuditLog.self).snapshot()
        try #require(!all.isEmpty, "no audit rows were written for 20 inserts")
        let expected = all.compactMap(\.primaryKey).max()

        let head = lattice.objects(AuditLog.self)
            .sortedBy(\.primaryKey, order: .reverse)
            .first?.primaryKey
        #expect(head == expected)
    }

    /// The trigger's predicate: rows ABOVE the watermark, on the Memory
    /// table, of local origin. All three clauses have to survive together —
    /// dropping the table filter counts every Edge/HookState write, and
    /// dropping the origin filter counts sync-applied rows, which is what
    /// would spawn a maintenance subprocess on every cooldown during a drain.
    @Test func watermarkDelta_countsOnlyLocalMemoryRowsAboveTheMark() async throws {
        let lattice = try makeLattice()

        // Below the watermark: must not be counted.
        for i in 0..<5 {
            try lattice.add(Memory(content: "pre-watermark \(i)", project: "WM"))
        }
        let watermark = try #require(
            lattice.objects(AuditLog.self)
                .sortedBy(\.primaryKey, order: .reverse)
                .first?.primaryKey)

        // Above it: 7 Memory writes plus non-Memory traffic.
        var gids: [UUID] = []
        for i in 0..<7 {
            let mem = Memory(content: "post-watermark \(i)", project: "WM")
            try lattice.add(mem)
            if let gid = mem.globalId { gids.append(gid) }
        }
        for i in 1..<gids.count {
            try lattice.add(Edge(sourceGlobalId: gids[0], targetGlobalId: gids[i],
                                 relation: .relatesTo))
        }
        try lattice.add(HookState(key: .maintenanceActive, value: "0"))

        let delta = lattice.objects(AuditLog.self)
            .where { $0.primaryKey > watermark && $0.tableName == "Memory" && $0.isFromRemote == false }
            .count

        // Cross-check against the same filter evaluated in Swift, so the test
        // fails on a predicate-translation change rather than on an
        // arithmetic assumption about how many audit rows one insert emits.
        let expected = lattice.objects(AuditLog.self).snapshot().filter {
            ($0.primaryKey ?? 0) > watermark && $0.tableName == "Memory" && !$0.isFromRemote
        }.count
        #expect(delta == expected)
        #expect(delta >= 7, "expected at least one audit row per post-watermark Memory insert")

        // And the watermark actually bounds it: the same count from zero has
        // to include the pre-watermark writes too.
        let fromZero = lattice.objects(AuditLog.self)
            .where { $0.primaryKey > Int64(0) && $0.tableName == "Memory" && $0.isFromRemote == false }
            .count
        #expect(fromZero > delta, "the watermark did not restrict the count")
    }
}
