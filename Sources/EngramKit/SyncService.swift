import EngramModels
import Foundation
import Combine
import Lattice

/// Data-layer sync logic extracted from the Visualizer's SyncManager.
/// Used by both the Visualizer and the standalone sync daemon.
public enum SyncService {

    /// Tables permitted to leave the personal relay, either for the cloud or
    /// back to the local hub. Use an explicit list even though this relay is
    /// normally opened with just these models: unregistered tables can survive
    /// a schema-subset reopen, and `nil` would upload those tables as well.
    /// Local operation identities and receipts must never become sync data.
    public static func buildPersonalRelaySyncFilter(from lattice: Lattice? = nil) -> Lattice.SyncFilter {
        guard let values = policyValues(from: lattice, group: nil) else { return denyPolicyFilter() }
        var filter = Lattice.SyncFilter()
        let eligible: @Sendable (Query<Memory>) -> Query<Bool> = { !$0.isPrivate && $0.derivationPolicy.in(values) }
        filter.include(Memory.self, where: eligible)
        filter.include(Edge.self) { edge in
            edge.sourceGlobalId.in(\Memory.globalId, where: eligible) && edge.targetGlobalId.in(\Memory.globalId, where: eligible)
        }
        filter.include(SyncConfig.self)
        return filter
    }

    /// Cold-open bootstrap admits only the explicit new-direct policy. The
    /// retained policy observer expands this to validated derived values.
    public static func buildGroupRelaySyncFilter(from lattice: Lattice? = nil, groupId: UUID? = nil) -> Lattice.SyncFilter {
        guard let values = policyValues(from: lattice, group: groupId, groupRequired: true) else { return denyPolicyFilter() }
        var filter = Lattice.SyncFilter()
        let eligible: @Sendable (Query<Memory>) -> Query<Bool> = { !$0.isPrivate && $0.derivationPolicy.in(values) }
        filter.include(Memory.self, where: eligible)
        filter.include(Edge.self) { edge in
            edge.sourceGlobalId.in(\Memory.globalId, where: eligible) && edge.targetGlobalId.in(\Memory.globalId, where: eligible)
        }
        filter.include(GroupProjectMap.self)
        return filter
    }

    /// Exact full-policy equality, never row IDs or substring membership. A
    /// tightened current row immediately unmatches any older allowlist unless
    /// its new policy independently permits this same destination. Unseen
    /// valid values are denied until the owned observer refreshes the filter.
    static let maximumPolicyValues = 4096
    private static func policyValues(from lattice: Lattice?, group: UUID?, groupRequired: Bool = false) -> [String?]? {
        guard let lattice else { return [MemoryDerivationPolicy.direct.rawValue] }
        let rows = lattice.objects(Memory.self).distinct(by: \.derivationPolicy).snapshot(limit: Int64(maximumPolicyValues + 1))
        guard lattice.lastQueryError() == nil, rows.count <= maximumPolicyValues else { return nil }
        var values = Set<String>()
        for row in rows.map({ $0.materialize() }) {
            guard let policy = MemoryDerivationPolicy(rawValue: row.derivationPolicy), !policy.privateFloor else { continue }
            if let group {
                guard policy.permits(group: group) else { continue }
            } else if groupRequired && policy.groupCeiling != nil { continue }
            values.insert(policy.rawValue)
        }
        // This is a known complete policy, not an inference from a legacy row.
        values.insert(MemoryDerivationPolicy.direct.rawValue)
        return values.sorted().map(Optional.some)
    }

    private static func policyConfigs(from lattice: Lattice) -> [SyncConfig]? {
        let rows = lattice.objects(SyncConfig.self).snapshot(limit: Int64(maximumPolicyValues + 1)).map { $0.materialize() }
        guard lattice.lastQueryError() == nil, rows.count <= maximumPolicyValues,
              Set(rows.map(\.project)).count == rows.count else { return nil }
        return rows
    }

    /// An EMPTY SyncFilter uploads everything in pinned Lattice. Explicit
    /// false predicate keeps it nonempty. Entries are a table whitelist, so
    /// omitting all other tables denies them without querying models absent
    /// from a hub/spoke's schema. Memory exists on every owned relay.
    public static func denyPolicyFilter() -> Lattice.SyncFilter {
        var filter = Lattice.SyncFilter()
        filter.include(Memory.self) { $0.globalId.in([UUID?]()) }
        return filter
    }

    public static func buildSyncFilter(from lattice: Lattice) -> Lattice.SyncFilter {
        guard let configs = policyConfigs(from: lattice), let values = policyValues(from: lattice, group: nil) else { return denyPolicyFilter() }
        let projects = configs.filter { $0.policy == .sync }.map(\.project)
        var filter = Lattice.SyncFilter()
        let eligible: @Sendable (Query<Memory>) -> Query<Bool> = {
            !$0.isPrivate && $0.project.in(projects) && $0.derivationPolicy.in(values)
        }
        filter.include(Memory.self, where: eligible)
        filter.include(Edge.self) { edge in
            edge.sourceGlobalId.in(\Memory.globalId, where: eligible) && edge.targetGlobalId.in(\Memory.globalId, where: eligible)
        }
        filter.include(SyncConfig.self)
        return filter
    }

    /// Busy timeout requested for the daemon hub and its sync connections.
    ///
    /// Match the MCP server's 2 s acquisition wait instead of inheriting
    /// Lattice's 30 s default. Core must carry this value into the dedicated
    /// WSS/IPC connections it creates; the real IPC contention fixture checks
    /// that behavior beyond the parent configuration. SQLite uses this budget
    /// for busy waits during BEGIN; it does not bound same-connection mutex
    /// admission, writer priority, lock-holding time or a whole delivery.
    /// The pinned Core retries a failed apply chunk once and
    /// acknowledges only committed entries. Cold-apply initialization runs
    /// before that chunk retry, so its failure behavior needs separate
    /// coverage from the warmed relay's BEGIN contention path.
    public static let daemonHubBusyTimeoutMs = 2_000

    /// The daemon's hub configuration: schema migrations, the per-destination
    /// IPC targets, and the interactive-parity busy timeout above.
    public static func daemonHubConfiguration(dbPath: String,
                                              ipcTargets: [Lattice.IPCSyncTarget]) -> Lattice.Configuration {
        var config = Lattice.Configuration(fileURL: URL(fileURLWithPath: dbPath), migration: engramMigrations)
        config.busyTimeoutMs = daemonHubBusyTimeoutMs
        config.ipcTargets = ipcTargets
        return config
    }

    /// Compact history before sync to reduce AuditLog entries.
    /// Uses slot-aware compaction — only deletes entries all synchronizers have confirmed.
    public static func compactBeforeSync(_ lattice: Lattice, log: (String) -> Void = { _ in }) {
        compactAndCheckpoint(lattice, context: "Startup compaction", log: log)
    }

    /// Preserve a sealed compaction failure before the next native call clears
    /// the thread-local error slot. A failed compaction returns nil, not a
    /// successful zero-row count. Lattice's -1 no-writer-slots result remains
    /// distinct; this helper never changes the compaction floor or retries it.
    @discardableResult
    public static func compactAndCheckpoint(_ lattice: Lattice, context: String,
                                             log: (String) -> Void = { _ in }) -> Int64? {
        let deleted = lattice.compactHistory()
        let compactionError = lattice.lastQueryError()
        // Keep the existing checkpoint attempt even if compaction failed.
        // Its bounded busy wait is appropriate while MCP and visualizer
        // readers are active; pinned frames can remain for a later pass.
        let checkpointed = lattice.checkpointBounded()
        let checkpointError = lattice.lastQueryError()

        if let compactionError {
            log("\(context): compaction failed: \(compactionError)")
        } else if deleted > 0 {
            log("\(context): compacted \(deleted) audit rows")
        } else if deleted < 0 {
            log("\(context): compaction skipped (no writer slots)")
        }
        if let checkpointError {
            log("\(context): bounded checkpoint failed: \(checkpointError)")
        } else if checkpointed < 0 {
            log("\(context): bounded checkpoint deferred (no frames checkpointed)")
        }
        return compactionError == nil ? deleted : nil
    }

    /// Self-heal for machines carrying the Aug 2026 audit-log explosion
    /// (4.7M rows / 11GB WAL observed). Runs at daemon startup so users
    /// who never run `memory-sync repair-audit` recover automatically:
    /// with the fixed core, compaction actually deletes (channel floors
    /// now advance), and the timestamp normalization repairs rows the old
    /// apply path minted as TEXT in the REAL column — invisible to every
    /// date-based query and to age-based compaction.
    ///
    /// Deliberately NOT vacuumed here: VACUUM needs exclusive access and
    /// only reclaims DISK; the freed pages are reused either way, so
    /// performance is restored without it. `repair-audit` (quiesced) is
    /// the tool for people who want the disk back.
    public static func healAuditLog(_ lattice: Lattice, log: (String) -> Void = { _ in }) {
        let before = lattice.objects(AuditLog.self).count
        if let error = lattice.lastQueryError() {
            log("Audit heal: could not count audit rows: \(error)")
            return
        }
        guard before > auditHealThreshold else { return }
        let normalized = lattice.normalizeAuditTimestamps()
        let normalizationError = lattice.lastQueryError()
        compactAndCheckpoint(lattice, context: "Audit heal", log: log)
        if let normalizationError {
            log("Audit heal: timestamp normalization failed: \(normalizationError)")
        } else {
            log("Audit heal: \(before) rows, normalized \(normalized) timestamps")
        }
    }

    /// Above this many audit rows, a database is carrying more history than
    /// healthy churn explains and the startup heal is worth its cost.
    /// (Healthy hubs sit in the low thousands between compactions.)
    static let auditHealThreshold = 100_000

    // MARK: - Groups (increment 3)

    /// IPC channel feeding one group's spoke. One channel per membership —
    /// they are independently filtered, which is precisely what Stage A1's
    /// per-sync_id sync set made safe.
    public static func groupChannel(_ groupId: UUID) -> String {
        "engram-group-\(groupId.uuidString)"
    }

    /// Daemon-owned spoke database for a group.
    public static func groupDbPath(claudeDir: String, groupId: UUID) -> String {
        // Reuse syncedDbPath's directory creation (700).
        let syncDir = (syncedDbPath(claudeDir: claudeDir) as NSString).deletingLastPathComponent
        return syncDir + "/group-\(groupId.uuidString).sqlite"
    }

    /// A revoked spoke is renamed rather than deleted: MCP discovery stops
    /// attaching it immediately, and the file survives for forensics.
    public static func revokedGroupDbPath(claudeDir: String, groupId: UUID) -> String {
        groupDbPath(claudeDir: claudeDir, groupId: groupId) + ".revoked"
    }

    /// Group spokes present on this machine, newest-synced first.
    ///
    /// The FILE is the feature flag: the daemon is the only writer, it
    /// renames a spoke to `.revoked` the moment a membership disappears, and
    /// reads are membership-scoped (plan decision 3), so "what spokes exist"
    /// is exactly "what groups may be read". Deliberately NOT intersected
    /// with groups.json — a stale or missing directory would silently
    /// blind every group recall, which is the failure this ordering avoids.
    ///
    /// Ordered by modification time descending so that when the attach cap
    /// bites (SQLITE_MAX_ATTACHED, risk 6) the groups that are actually
    /// moving are the ones that stay attached.
    public static func discoverGroupSpokes(claudeDir: String) -> [(groupId: UUID, path: String)] {
        let syncDir = (syncedDbPath(claudeDir: claudeDir) as NSString).deletingLastPathComponent
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: syncDir) else { return [] }
        var found: [(groupId: UUID, path: String, mtime: Date)] = []
        for name in names {
            // `.revoked` (and any other suffix) must not match: hasPrefix
            // alone would happily re-attach a quarantined spoke.
            guard name.hasPrefix("group-"), name.hasSuffix(".sqlite") else { continue }
            let idPart = String(name.dropFirst("group-".count).dropLast(".sqlite".count))
            guard let groupId = UUID(uuidString: idPart) else { continue }
            let path = syncDir + "/" + name
            let mtime = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date)
                .flatMap { $0 } ?? .distantPast
            found.append((groupId, path, mtime))
        }
        return found
            .sorted { $0.mtime > $1.mtime }
            .map { (groupId: $0.groupId, path: $0.path) }
    }

    /// HUB→SPOKE filter for one group channel: non-private memories of the
    /// projects this member exposed to THAT group, plus edges whose
    /// endpoints both qualify.
    ///
    /// Deliberately excludes SyncConfig (device preferences are personal,
    /// not group data) and GroupProjectMap (map rows are written straight
    /// into the spoke — see `MemoryTools`/`SyncManager`; the hub does not
    /// even carry that table).
    ///
    /// An empty exposure set yields a filter that matches NOTHING rather
    /// than everything — the difference between "this group gets nothing
    /// yet" and "this group gets your entire database".
    public static func buildGroupSyncFilter(from lattice: Lattice, groupId: UUID) -> Lattice.SyncFilter {
        guard let configs = policyConfigs(from: lattice), let values = policyValues(from: lattice, group: groupId) else { return denyPolicyFilter() }
        let projects = configs.filter { $0.exposedGroups.contains(groupId.uuidString) }.map(\.project)
        var filter = Lattice.SyncFilter()
        let eligible: @Sendable (Query<Memory>) -> Query<Bool> = {
            !$0.isPrivate && $0.project.in(projects) && $0.derivationPolicy.in(values)
        }
        filter.include(Memory.self, where: eligible)
        filter.include(Edge.self) { edge in
            edge.sourceGlobalId.in(\Memory.globalId, where: eligible) && edge.targetGlobalId.in(\Memory.globalId, where: eligible)
        }
        return filter
    }

    /// SPOKE→HUB upload filter — the cross-group leak firewall.
    ///
    /// The hub relays indiscriminately across its channels, so without this
    /// a teammate's row arriving in group A's spoke would flow up into the
    /// hub and back down into every OTHER group whose filter matches its
    /// project. Only rows authored by ME may travel spoke→hub, which keeps
    /// teammates' edits to MY memories converging into my personal copy
    /// while their own memories stay in the group they belong to.
    ///
    /// Memory-only by design: an Edge written in the spoke may reference
    /// memories that never transit the hub, so relaying it up would create
    /// a dangling edge. Edges flow hub→spoke only. GroupProjectMap likewise
    /// never leaves the spoke.
    public static func buildSpokeToHubFilter(me: UUID, from lattice: Lattice? = nil, groupId: UUID? = nil) -> Lattice.SyncFilter {
        guard let values = policyValues(from: lattice, group: groupId, groupRequired: true) else { return denyPolicyFilter() }
        var filter = Lattice.SyncFilter()
        filter.include(Memory.self) { !$0.isPrivate && $0.authorUserId == me && $0.derivationPolicy.in(values) }
        return filter
    }

    /// Open one group's spoke: WSS to that group's relay channel, IPC back
    /// to the hub with the authored-by-me firewall.
    ///
    /// - Parameter selfUserId: nil (signed out / directory not yet written)
    ///   makes the spoke→hub filter match NOTHING — safer than uploading
    ///   unattributed rows that could never converge back.
    public static func openGroupLattice(
        claudeDir: String,
        groupId: UUID,
        authToken: String,
        wssBase: URL,
        selfUserId: UUID?
    ) -> Lattice? {
        let dbPath = groupDbPath(claudeDir: claudeDir, groupId: groupId)
        let endpoint = wssBase
            .appendingPathComponent("sync")
            .appendingPathComponent("group")
            .appendingPathComponent(groupId.uuidString)

        var config = Lattice.Configuration(
            fileURL: URL(fileURLWithPath: dbPath),
            authorizationToken: authToken,
            wssEndpoint: endpoint,
            migration: engramMigrations,
            syncFilter: buildGroupRelaySyncFilter(groupId: groupId)
        )
        // Filter at CONFIGURATION time, not after open: a spoke that
        // connects before its filter lands would run unfiltered, which on a
        // group channel is a cross-group leak window (Stage A2).
        config.ipcTargets = [.init(
            channel: groupChannel(groupId),
            syncFilter: buildSpokeToHubFilter(
                me: selfUserId ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, groupId: groupId),
            // Stage A4: un-exposing a project must NOT delete rows the
            // group already has — narrowing here is bookkeeping-only and
            // the spoke stays a full mirror (reads are membership-scoped).
            narrowingEmitsRemovals: false)]
        return try? Lattice(
            Memory.self, Edge.self, GroupProjectMap.self,
            configuration: config
        )
    }

    /// Path to the synced database, in a daemon-owned subdirectory.
    /// The `sync/` directory is created with `700` permissions so only the owner
    /// can list/delete its contents, protecting against accidental deletion.
    public static func syncedDbPath(claudeDir: String) -> String {
        let syncDir = claudeDir + "/sync"
        let fm = FileManager.default
        if !fm.fileExists(atPath: syncDir) {
            try? fm.createDirectory(atPath: syncDir, withIntermediateDirectories: true)
            // 700 = owner rwx only
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: syncDir)
        }
        return syncDir + "/memory-synced.sqlite"
    }

    /// Open the synced lattice (relay endpoint) with WSS + IPC.
    ///
    /// - Parameters:
    ///   - claudeDir: Path to ~/.claude.
    ///   - authToken: WSS authorization token.
    ///   - wssEndpoint: WebSocket sync server URL.
    ///   - channel: IPC channel name (default: "engram-sync").
    /// - Returns: The opened synced Lattice, or nil on failure.
    public static func openSyncedLattice(
        claudeDir: String,
        authToken: String,
        wssEndpoint: URL,
        channel: String = "engram-sync"
    ) -> Lattice? {
        let dbPath = syncedDbPath(claudeDir: claudeDir)
        var syncedConfig = Lattice.Configuration(
            fileURL: URL(fileURLWithPath: dbPath),
            authorizationToken: authToken,
            wssEndpoint: wssEndpoint,
            migration: engramMigrations,
            syncFilter: buildPersonalRelaySyncFilter()
        )
        syncedConfig.ipcTargets = [.init(channel: channel,
                                        syncFilter: buildPersonalRelaySyncFilter())]
        return try? Lattice(
            Memory.self, Edge.self, SyncConfig.self,
            configuration: syncedConfig
        )
    }

    public enum PolicyRelay: Sendable {
        case hub(personalChannel: String, groupIds: [UUID])
        case personal(channel: String)
        case group(id: UUID, author: UUID?)
    }

    private static func policyTargets(_ lattice: Lattice, relay: PolicyRelay) -> [(String, Lattice.SyncFilter)] {
        switch relay {
        case .hub(let personal, let groups):
            return [(personal, buildSyncFilter(from: lattice))] + groups.map { (groupChannel($0), buildGroupSyncFilter(from: lattice, groupId: $0)) }
        case .personal(let channel):
            let filter = buildPersonalRelaySyncFilter(from: lattice)
            return [("", filter), (channel, filter)]
        case .group(let id, let author):
            return [("", buildGroupRelaySyncFilter(from: lattice, groupId: id)),
                    (groupChannel(id), buildSpokeToHubFilter(me: author ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, from: lattice, groupId: id))]
        }
    }

    /// The daemon retains this token, then cancels it before relay retirement.
    /// No observer registry, detached lifetime, credentials or source text.
    public final class PolicyObservation: @unchecked Sendable {
        private var lattice: Lattice?
        private let relay: PolicyRelay
        private let storageIdentity: String?
        private let queue = DispatchQueue(label: "engram.policy-refresh")
        private let lock = NSRecursiveLock()
        private var generation: UInt64 = 0
        private var scheduled = false
        private var cancelled = false
        private var observers: [AnyCancellable] = []
        // The native API only enqueues reconciliation; it provides no ACK.
        private var enqueued: [(String, Lattice.SyncFilter)] = []
        private var reconciliationRequested = false
        private var reconciliationTimer: DispatchWorkItem?
        private var reconciliationTicket: UInt64 = 0
        private var reconciliationStep = 0
        private var stableSignature: [(String, Lattice.SyncFilter)] = []
        private static let reconciliationDelays = [2, 4, 8, 16, 30, 60]
        var reconciliationBackoffStep: Int { lock.withLock { reconciliationStep } }
        // Internal deterministic race seam. Production construction never sets it.
        private var installHook: (@Sendable () -> Void)?
        var beforeInstall: (@Sendable () -> Void)? {
            get { lock.withLock { installHook } }
            set { lock.withLock { installHook = newValue } }
        }
        var hasPendingRefresh: Bool { lock.withLock { scheduled } }

        public init(lattice: Lattice, relay: PolicyRelay) {
            self.lattice = lattice; self.relay = relay
            storageIdentity = Self.currentStorageIdentity(lattice)
            observers = [lattice.observe(Memory.self) { [weak self] _ in self?.refresh() },
                         lattice.observe(SyncConfig.self) { [weak self] _ in self?.refresh() }]
            refresh()
        }

        public func refresh() { requestRefresh(reconcile: false) }

        private func requestRefresh(reconcile: Bool) {
            lock.lock()
            guard !cancelled else { lock.unlock(); return }
            generation &+= 1
            reconciliationRequested = reconciliationRequested || reconcile
            let start = !scheduled
            scheduled = true
            lock.unlock()
            if start { queue.async { [weak self] in self?.drain() } }
        }

        private func drain() {
            lock.lock()
            guard !cancelled, let lattice else { scheduled = false; lock.unlock(); return }
            let captured = generation
            let reconcile = reconciliationRequested
            let hook = installHook
            lock.unlock()
            guard storageIdentity != nil, Self.currentStorageIdentity(lattice) == storageIdentity else {
                cancel(); return
            }
            let first = SyncService.policyTargets(lattice, relay: relay)
            // A failed/overflowing read is sufficient to retire permission.
            // Never wait for notification quiescence before enqueueing denial.
            // Native installation is asynchronous, not acknowledged here.
            lock.lock()
            guard !cancelled else { scheduled = false; lock.unlock(); return }
            if first.contains(where: { $0.1 == SyncService.denyPolicyFilter() }) {
                enqueueDenial(on: lattice, targets: first)
            }
            lock.unlock()
            hook?()
            let latest = SyncService.policyTargets(lattice, relay: relay)
            guard Self.currentStorageIdentity(lattice) == storageIdentity else { cancel(); return }
            lock.lock()
            guard !cancelled else { scheduled = false; lock.unlock(); return }
            if latest.contains(where: { $0.1 == SyncService.denyPolicyFilter() }) {
                enqueueDenial(on: lattice, targets: latest)
            }
            // A callback generation and a second authoritative read both
            // fence delayed work. Retire while retrying a changing snapshot:
            // an old permissive filter must not survive a notification storm.
            if captured != generation || !Self.same(first, latest) {
                enqueueDenial(on: lattice, targets: latest)
                lock.unlock()
                queue.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in self?.drain() }
                return
            }
            if reconcile || !Self.same(enqueued, latest) {
                for (channel, filter) in latest { lattice.updateSyncFilter(filter, forChannel: channel) }
                enqueued = latest
            }
            if captured != generation {
                // An installation can synchronously cause an observation.
                // Do not lose that refresh just because this drain owned it.
                lock.unlock()
                queue.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in self?.drain() }
                return
            }
            let changed = !Self.same(stableSignature, latest)
            stableSignature = latest
            scheduleReconciliation(reset: changed)
            reconciliationRequested = false
            scheduled = false
            lock.unlock()
        }

        private static func currentStorageIdentity(_ lattice: Lattice) -> String? {
            switch lattice.configuration.storage {
            case .memory(let name): return "memory:" + name
            case .file(let url):
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      let device = attributes[.systemNumber] as? NSNumber,
                      let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
                return "file:" + device.stringValue + ":" + inode.stringValue
            }
        }

        /// Caller holds lock. Only a changed complete policy/exposure signature
        /// restarts backoff. Ordinary row notifications and our own queued
        /// reconciliation effects do not turn idle retry into continuous work.
        private func scheduleReconciliation(reset: Bool) {
            if reset {
                reconciliationTimer?.cancel(); reconciliationTimer = nil
                reconciliationTicket &+= 1
                reconciliationStep = 0
            }
            guard reconciliationTimer == nil else { return }
            let delay = Self.reconciliationDelays[min(reconciliationStep, Self.reconciliationDelays.count - 1)]
            reconciliationStep = min(reconciliationStep + 1, Self.reconciliationDelays.count)
            let ticket = reconciliationTicket
            let item = DispatchWorkItem { [weak self] in self?.reconcileAfterTimer(ticket: ticket) }
            reconciliationTimer = item
            queue.asyncAfter(deadline: .now() + .seconds(delay), execute: item)
        }

        private func reconcileAfterTimer(ticket: UInt64) {
            lock.lock()
            guard !cancelled, ticket == reconciliationTicket else { lock.unlock(); return }
            reconciliationTimer = nil
            lock.unlock()
            requestRefresh(reconcile: true)
        }

        /// Caller holds lock. Revocation is safe even when the read's
        /// generation is stale; only a stable current read may restore it.
        private func enqueueDenial(on lattice: Lattice, targets: [(String, Lattice.SyncFilter)]) {
            let denied = targets.map { ($0.0, SyncService.denyPolicyFilter()) }
            if !Self.same(enqueued, denied) {
                for (channel, filter) in denied { lattice.updateSyncFilter(filter, forChannel: channel) }
                enqueued = denied
            }
        }

        private static func same(_ a: [(String, Lattice.SyncFilter)], _ b: [(String, Lattice.SyncFilter)]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { pair in pair.0.0 == pair.1.0 && pair.0.1 == pair.1.1 }
        }

        public func cancel() {
            lock.lock()
            guard !cancelled else { lock.unlock(); return }
            cancelled = true; generation &+= 1; scheduled = false
            reconciliationTimer?.cancel(); reconciliationTimer = nil
            reconciliationTicket &+= 1
            reconciliationRequested = false
            let old = observers; observers = []
            if let lattice {
                let channels: [String]
                switch relay {
                case .hub(let personal, let groups): channels = [personal] + groups.map(SyncService.groupChannel)
                case .personal(let channel): channels = ["", channel]
                case .group(let id, _): channels = ["", SyncService.groupChannel(id)]
                }
                for channel in channels { lattice.updateSyncFilter(SyncService.denyPolicyFilter(), forChannel: channel) }
            }
            lattice = nil; installHook = nil
            lock.unlock()
            old.forEach { $0.cancel() }
        }
        deinit { cancel() }
    }
}
