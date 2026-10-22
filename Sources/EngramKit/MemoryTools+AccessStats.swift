import EngramMemoryCore
import EngramModels
import Foundation
import Lattice

// MARK: - Recall access-stat bump (best effort, off the hot path)

/// What a recall did about `lastAccessedAt` / `accessCount`.
enum AccessStatBumpOutcome: Equatable, Sendable {
    /// No recall has run yet on this instance.
    case none
    /// Rows were bumped in one transaction.
    case bumped(rows: Int)
    /// The caller (hook path) opted out.
    case skippedOptOut
    /// Nothing hub-resident to bump.
    case skippedNothing
    /// The dedicated handle could not be opened (in-memory store, or the
    /// open itself lost the lock repeatedly).
    case skippedNoHandle
    /// BEGIN lost the lock within the short budget; the recall result was
    /// already composed and is returned unchanged.
    case skippedBusy(waitedMs: Int)
    /// Some other non-fatal error.
    case skippedError(String)
}

extension MemoryTools {
    /// Busy timeout for the dedicated access-stat handle. Small on purpose:
    /// these are approximate ranking hints, and the bump must never make a
    /// recall wait on another session's write.
    static let accessStatBusyTimeoutMs = 75
    /// Stop trying to open the dedicated handle after this many failures.
    static let accessStatOpenFailureLimit = 3

    /// Bump access stats for `targets` on a dedicated hub handle with a short
    /// busy timeout. Never throws; the outcome is recorded in
    /// `lastAccessStatBump` and logged.
    ///
    /// Only hub-resident rows reach here (the caller already excluded spoke
    /// rows). Rows that live solely in the personal synced mirror are not
    /// bumped — they are not found on the hub handle — which keeps the
    /// daemon-owned synced database free of per-recall writes. Stats are
    /// approximate by design.
    func bumpAccessStatsBestEffort(_ targets: [Memory], now: Date) {
        let gids = targets.compactMap(\.globalId)
        guard !gids.isEmpty else {
            lastAccessStatBump = .skippedNothing
            return
        }
        guard let handle = accessStatHandle() else {
            lastAccessStatBump = .skippedNoHandle
            sessionLog("[recall] access-stat bump skipped (no dedicated handle)")
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            // Resolve rows on THIS handle: `increment` and the setter must run
            // on objects owned by the connection whose transaction they join.
            var rows: [Memory] = []
            rows.reserveCapacity(gids.count)
            for gid in gids {
                if let row = handle.objects(Memory.self).where({ $0.globalId == gid }).first {
                    rows.append(row)
                }
            }
            guard !rows.isEmpty else {
                lastAccessStatBump = .skippedNothing
                return
            }
            try handle.withTransaction {
                for m in rows {
                    m.lastAccessedAt = now
                    m.increment("accessCount")
                }
            }
            lastAccessStatBump = .bumped(rows: rows.count)
        } catch {
            let waitedMs = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            if LatticeBeginRetry.isBeginContention(error) {
                lastAccessStatBump = .skippedBusy(waitedMs: waitedMs)
                log("[recall] access-stat bump skipped (hub busy after \(waitedMs) ms; non-fatal)")
                sessionLog("[recall] access-stat bump skipped (busy, \(waitedMs) ms)")
            } else {
                lastAccessStatBump = .skippedError("\(error)")
                log("[recall] access-stat bump skipped: \(error)")
                sessionLog("[recall] access-stat bump skipped (non-fatal)")
            }
        }
    }

    /// The dedicated handle, opened lazily. Separate from `localLattice` so it
    /// can carry its own (short) busy timeout — Lattice fixes the timeout at
    /// open time and the server's main handle keeps its 2 s contract for
    /// real writes. In-memory stores have no second connection to open.
    private func accessStatHandle() -> Lattice? {
        if let accessStatLattice { return accessStatLattice }
        guard accessStatOpenFailures < Self.accessStatOpenFailureLimit else { return nil }
        let configuration = localLattice.configuration
        guard case .file(let url) = configuration.storage else {
            accessStatOpenFailures = Self.accessStatOpenFailureLimit
            return nil
        }
        do {
            let handle = try Lattice(
                Memory.self,
                configuration: .init(fileURL: url, migration: engramMigrations,
                                     busyTimeoutMs: Self.accessStatBusyTimeoutMs))
            accessStatLattice = handle
            return handle
        } catch {
            accessStatOpenFailures += 1
            log("[recall] access-stat handle open failed (\(accessStatOpenFailures)/\(Self.accessStatOpenFailureLimit)): \(error)")
            return nil
        }
    }
}
