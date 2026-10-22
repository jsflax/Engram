import EngramMemoryCore
import EngramModels
import Foundation
import Lattice

// MARK: - Recall access-stat bump (optional, bounded hub writes)

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
    /// The dedicated handle could not be opened (in-memory, read-only or
    /// removed store, or an open failure).
    case skippedNoHandle
    /// BEGIN lost the lock within the short budget; the recall result was
    /// already composed and is returned unchanged.
    case skippedBusy(waitedMs: Int)
    /// Some other non-fatal error.
    case skippedError(String)
}

extension MemoryTools {
    /// Busy timeout for the dedicated access-stat handle. Small on purpose:
    /// these are approximate ranking hints. This bounds a contended BEGIN,
    /// not the total time to open the handle, query, or commit the bump.
    static let accessStatBusyTimeoutMs = 75
    /// Bound both the IN parameters and optional writes, even when recall's
    /// graph traversal returns many more rows. Omitted stats are approximate.
    static let accessStatTargetLimit = 128
    /// Stop trying to open the dedicated handle after this many failures.
    static let accessStatOpenFailureLimit = 3

    private enum AccessStatError: Error { case queryFailed }

    nonisolated static func accessStatTargetIDs(_ ids: some Sequence<UUID>) -> [UUID] {
        var seen: Set<UUID> = []
        var result: [UUID] = []
        for id in ids where seen.insert(id).inserted {
            result.append(id)
            if result.count == accessStatTargetLimit { break }
        }
        return result
    }

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
        let gids = Self.accessStatTargetIDs(targets.lazy.compactMap(\.globalId))
        guard !gids.isEmpty else {
            lastAccessStatBump = .skippedNothing
            return
        }
        guard let handle = accessStatHandle() else {
            lastAccessStatBump = .skippedNoHandle
            sessionLog("[recall] access-stat bump skipped (no dedicated handle)")
            return
        }
        // This request-scoped snapshot can pin a WAL reader on the separate
        // stats connection. Retire it on every exit, including empty, busy,
        // and failed bumps, so an idle caller cannot block checkpointing.
        // Retirement latches future reads on this cached handle to unpinned
        // live reads, matching the request/response MCP handle policy.
        // Keep this here as direct service callers need the same cleanup as MCP.
        defer { handle.retireAllGenerations() }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            // Resolve rows on THIS handle in ONE statement: `increment` and the
            // setter must run on objects owned by the connection whose
            // transaction they join (RecallPerfRegressionTests budgets the
            // recall's total statement count).
            let rows = handle.objects(Memory.self)
                .where { $0.globalId.in(gids) && $0.deletedAt == nil && $0.expiresAt > now }
                .snapshot(limit: Int64(Self.accessStatTargetLimit))
            guard handle.lastQueryError() == nil else { throw AccessStatError.queryFailed }
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
        guard case .file(let url) = configuration.storage, !configuration.isReadOnly,
              FileManager.default.fileExists(atPath: url.path) else {
            accessStatOpenFailures = Self.accessStatOpenFailureLimit
            return nil
        }
        do {
            // A normal actor-isolated open retains this actor through its
            // scheduler. A plain nil-isolated open can share a cached native
            // connection with another caller. Use its reference to open an
            // independent, scheduler-free handle, as the primary stores do.
            // Deliberately do not inherit WSS credentials or IPC targets.
            let opener = try Lattice(
                isolation: nil, Memory.self,
                configuration: .init(fileURL: url, migration: configuration.migration,
                                     busyTimeoutMs: Self.accessStatBusyTimeoutMs))
            guard let handle = try opener.sendableReference.resolveIndependent() else { return nil }
            accessStatLattice = handle
            return handle
        } catch {
            accessStatOpenFailures += 1
            log("[recall] access-stat handle open failed (\(accessStatOpenFailures)/\(Self.accessStatOpenFailureLimit)): \(error)")
            return nil
        }
    }
}
