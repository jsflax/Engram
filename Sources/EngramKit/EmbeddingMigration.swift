import EngramModels
import Foundation
import Lattice

/// The embedding-space version of STORED vectors.
///
/// v1 — the original bundled CoreML export, which was CLS-pooled
///      (`co.swiftlm.pooling_strategy: "cls"`): a defective space with weak
///      discrimination (unrelated pairs at ~0.73 cosine) that diverged from
///      faithful implementations (TEI, transformers.js) at 0.33–0.51.
/// v2 — the mean-pooled re-export, parity-locked to TEI/transformers.js at
///      cosine ≥ 0.999 (EmbedderParityTests).
///
/// The marker rides IN the database (HookState) — it describes the rows, so
/// it must travel with them, not with any one device.
public enum EmbeddingSpace {
    public static let currentVersion = 2
}

/// Re-embeds every Memory row with the current bundled model.
///
/// Runs from the daemon at startup (hub opens WITH ipcTargets, so the
/// updated vectors relay to spokes/server like any field update) and from
/// `memory-sync migrate-embeddings` for manual/off-path databases.
///
/// Idempotent: re-embedding a current-space row produces the same vector,
/// and the version marker is written only after a COMPLETE pass — a crash
/// mid-sweep just re-runs. Batched: embedding happens outside transactions
/// (it awaits the model), writes land in per-batch transactions.
public enum EmbeddingMigration {

    public struct Report: Sendable {
        public var reembedded = 0
        public var failed = 0
        public var skipped = false
    }

    public enum MigrationError: Error {
        case embedderUnavailable
    }

    public static func storedVersion(in lattice: Lattice) -> Int {
        guard let row = lattice.objects(HookState.self)
            .where({ $0.key == .embeddingSpaceVersion }).first,
            let version = Int(row.value) else { return 1 }
        return version
    }

    public static func setStoredVersion(_ version: Int, in lattice: Lattice) throws {
        if let row = lattice.objects(HookState.self)
            .where({ $0.key == .embeddingSpaceVersion }).first {
            try lattice.transaction {
                row.value = "\(version)"
                row.updatedAt = Date()
            }
        } else {
            try lattice.add(HookState(key: .embeddingSpaceVersion, value: "\(version)"))
        }
    }

    /// Sweep `lattice` if its stored space version is behind. `force` runs
    /// the sweep regardless of the marker (calibration / repair).
    /// `useMarker: false` = markerless mode for GROUP SPOKES: their schema
    /// is [Memory, Edge, GroupProjectMap] and must stay that way — opening
    /// them with HookState would create the table locally, and the group
    /// relay's write-policy DENIES unlisted tables, nacking the entry and
    /// wedging the spoke's upload channel. Markerless sweeps always run.
    @discardableResult
    public static func runIfNeeded(
        on lattice: Lattice,
        embedder: EmbeddingService? = nil,
        force: Bool = false,
        useMarker: Bool = true,
        batchSize: Int = 64,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Report {
        // This handle is independent of foreground MemoryTools handles.
        // Their request cleanup cannot release this migration's keepers.
        defer { lattice.retireAllGenerations() }
        var report = Report()
        let stored = useMarker ? storedVersion(in: lattice) : 1
        // A marker lookup creates a read generation even when no row exists.
        // Retire after that read, before model loading can suspend. Calling
        // retire before the first read would not latch a new coordinator.
        lattice.retireAllGenerations()
        guard force || !useMarker || stored < EmbeddingSpace.currentVersion else {
            report.skipped = true
            return report
        }

        let service = embedder ?? EmbeddingService()
        await service.load()
        guard await service.isLoaded else {
            // NEVER mark migrated without doing the work — a missing model
            // must fail loudly, not strand rows in the old space.
            throw MigrationError.embedderUnavailable
        }

        let rows = lattice.objects(Memory.self).snapshot()
        // Markerless spokes first acquire their coordinator here. The rows
        // are materialized; no keeper may span the per-row embedding awaits.
        lattice.retireAllGenerations()
        let total = rows.count
        log("Embedding migration: \(total) rows → space v\(EmbeddingSpace.currentVersion) (stored v\(stored)\(force ? ", forced" : ""))")

        var batch: [(Memory, [Float])] = []
        var processed = 0
        var batchesSinceCheckpoint = 0
        func flush() throws {
            guard !batch.isEmpty else { return }
            let pending = batch
            try lattice.transaction {
                for (mem, floats) in pending {
                    mem.embedding = Vector<Float>(floats)
                }
            }
            report.reembedded += pending.count
            batch.removeAll(keepingCapacity: true)
            // Keep the WAL bounded DURING the sweep: each batch rewrites
            // full rows (embedding blobs + audit payloads), and readers
            // (visualizer galaxy scans, hook recalls) pay O(WAL) per
            // statement — the un-checkpointed sweep starved the visualizer
            // for the whole migration window (Aug 2026 field report).
            // Bounded variant: fails fast under a held reader instead of
            // stalling the sweep on the writer gate.
            batchesSinceCheckpoint += 1
            if batchesSinceCheckpoint >= 8 {  // ~512 rows ≈ 8-16MB of WAL
                lattice.checkpointBounded()
                batchesSinceCheckpoint = 0
            }
        }

        for mem in rows {
            processed += 1
            if let floats = try await service.embed(text: mem.content) {
                batch.append((mem, floats))
            } else {
                report.failed += 1
            }
            if batch.count >= batchSize { try flush() }
            if processed % 512 == 0 {
                log("Embedding migration: \(processed)/\(total) (\(report.failed) failed)")
            }
        }
        try flush()

        // Marker only after a complete pass; failures leave it unset so the
        // next run retries (re-embedding completed rows is idempotent).
        if report.failed == 0 {
            if useMarker { try setStoredVersion(EmbeddingSpace.currentVersion, in: lattice) }
        } else {
            log("Embedding migration: \(report.failed) rows failed — marker NOT advanced; next run retries")
        }

        // The vector index was built over the old distribution — rebuild it.
        lattice._vacuumVec0(Memory(), for: \.embedding)
        // Startup migration runs alongside foreground writes and retained read
        // generations. Bound the final checkpoint so readers cannot make it
        // hold the writer gate for the connection's full busy timeout.
        lattice.checkpointBounded()
        log("Embedding migration: complete — \(report.reembedded) re-embedded, vec index rebuilt")
        return report
    }
}
