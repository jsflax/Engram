import Combine
import EngramMemoryCore
import EngramKit
import EngramModels
import Foundation
import Lattice
import Observation

/// Manages cloud sync observation in the Visualizer.
///
/// The sync daemon (`memory-sync`) owns the WSS connection and IPC relay.
/// The Visualizer opens both databases as plain read-only observers:
/// - `localLattice`: memory.db — the app's primary Lattice
/// - `syncedLattice`: memory-synced.db — opened plain for cross-process progress observation
///
/// Sync progress is observed cross-process via Lattice's AuditLog-based fallback.
@Observable
@MainActor
final class SyncManager {
    /// Fires once when sync connects (syncedLattice becomes non-nil).
    let didConnect = PassthroughSubject<Void, Never>()
    
    /// Path to the primary database file.
    var dbPath: String?

    actor Actor {
        @MainActor weak var parent: SyncManager?
        init(parent: SyncManager) {
            self.parent = parent
        }
        
        /// The app's primary Lattice (memory.db).
        var localLattice: Lattice?
        /// memory-synced.db opened as a plain Lattice (no WSS, no IPC) for observation.
        /// Exposed (internal) for GalaxyRegistry to create a synced galaxy.
        private(set) var syncedLattice: Lattice?
        /// Path to the primary database file.
        var dbPath: String?
        
        @MainActor var localLatticeRef: LatticeThreadSafeReference?
        
        func setLocalLattice(_ ref: LatticeThreadSafeReference?) {
            localLattice = ref?.resolve()
            dbPath = localLattice?.configuration.fileURL.path()
            Task { @MainActor in localLatticeRef = ref }
        }
        
        @MainActor var syncedLatticeRef: LatticeThreadSafeReference?
        
        // MARK: - Sync Lifecycle

        /// Set up sync observation. The daemon owns the actual WSS + IPC connections.
        /// The Visualizer just opens the synced DB for progress observation and
        /// starts the daemon if it isn't already running.
        func connectSync(wssEndpoint: URL, authToken: String) {
            guard let dbPath, let localLattice else { return }
            print("connecting to sync")
            // Open synced DB as a plain Lattice (no WSS, no IPC) for observation.
            // The synced DB lives in the daemon-owned sync/ directory.
            let claudeDir = (dbPath as NSString).deletingLastPathComponent
            let syncedDbPath = SyncService.syncedDbPath(claudeDir: claudeDir)
            syncedLattice = try? Lattice(
                Memory.self, Edge.self, SyncConfig.self,
                configuration: .init(
                    fileURL: URL(fileURLWithPath: syncedDbPath),
                    migration: engramMigrations
                )
            )
            syncedLattice?.onQueryError { message in
                print("[lattice] synced query failed (degraded to empty result): \(message)")
            }

            wireSyncProgress()
            CLIInstaller.startDaemon()
            
            Task { @MainActor [ref = syncedLattice?.sendableReference] in
                syncedLatticeRef = ref
                parent?.statusMessage = "Connected to sync server"
                parent?.didConnect.send()
            }
        }

        /// Tear down sync: stop daemon, delete synced DB so next sign-in starts fresh.
        func disconnectSync() {
            CLIInstaller.stopDaemon()
            syncedLattice = nil

            // Delete the synced DB (closes connections, removes DB + WAL + SHM),
            // but ONLY after the daemon has actually released it. stopDaemon()
            // signals the daemon; it isn't synchronous. Deleting while the
            // daemon still holds the DB open serves the deleted inode and
            // leaves -wal/-shm orphans. Probe the daemon's process flock: if
            // we can take it, the daemon is gone; if not within the timeout,
            // SKIP deletion rather than corrupt an in-use DB.
            if let dbPath {
                let claudeDir = (dbPath as NSString).deletingLastPathComponent
                let syncedDbPath = SyncService.syncedDbPath(claudeDir: claudeDir)
                if Self.waitForDaemonExit(claudeDir: claudeDir, timeout: 5.0) {
                    let config = Lattice.Configuration(fileURL: URL(fileURLWithPath: syncedDbPath))
                    try? Lattice.delete(for: config)
                } else {
                    NSLog("[SyncManager] daemon still holds sync lock after 5s — skipping synced-DB deletion")
                }
            }

            // Clear sync state on local DB so next sign-in does a full re-sync.
            // Without this, the local DB thinks rows are already synced to a DB that no longer exists.
            localLattice?.updateSyncFilter(nil)
            
            Task { @MainActor in
                parent?.statusMessage = nil
                parent?.ipcProgress = nil
                parent?.wssProgress = nil
            }
        }
        
        
        
        /// Poll the daemon's process flock until it's free (daemon exited) or
        /// the timeout elapses. Non-destructive: acquiring the lock proves the
        /// daemon released it; we immediately release again. Returns false if
        /// the daemon is still holding it — the caller must not delete the DB.
        static func waitForDaemonExit(claudeDir: String, timeout: TimeInterval) -> Bool {
            let lockPath = claudeDir + "/engram-sync.lock"
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                let fd = open(lockPath, O_RDWR)
                if fd < 0 { return true }  // no lock file → no daemon
                let got = flock(fd, LOCK_EX | LOCK_NB) == 0
                if got { flock(fd, LOCK_UN) }
                close(fd)
                if got { return true }
                Thread.sleep(forTimeInterval: 0.1)
            } while Date() < deadline
            return false
        }

        // MARK: - Sync Progress

        private func wireSyncProgress() {
            // Lattice 1.x: progress is an AsyncStream, not a callback
            // registration. Consume each in a detached task; the streams end
            // when their lattice goes away, ending the task with them.
            // IPC progress: cross-process observation of memory.db's IPC relay
            if let ipcStream = localLattice?.syncProgressStream {
                Task.detached { [weak self] in
                    for await progress in ipcStream {
                        await MainActor.run { self?.parent?.ipcProgress = progress }
                    }
                }
            }
            // WSS progress: cross-process observation of synced.db's WSS upload
            if let wssStream = syncedLattice?.syncProgressStream {
                Task.detached { [weak self] in
                    for await progress in wssStream {
                        await MainActor.run { self?.parent?.wssProgress = progress }
                    }
                }
            }
        }
        
        /// Current sync policy for a project (defaults to `.local`).
        func syncPolicy(for project: String) -> SyncConfig.Policy {
            guard let localLattice else { return .local }
            if let config = localLattice.objects(SyncConfig.self)
                .where({ $0.project == project }).first {
                return config.policy
            }
            return .local
        }
        
        /// Toggle a project's sync policy and update the IPC relay filter.
        func toggleProject(_ project: String) {
            guard let localLattice else { return }

            let current = syncPolicy(for: project)
            let newPolicy: SyncConfig.Policy = current == .sync ? .local : .sync

            // Update SyncConfig row in memory.db
            if let existing = localLattice.objects(SyncConfig.self)
                .where({ $0.project == project }).first {
                existing.policy = newPolicy
                existing.updatedAt = Date()
            } else {
                do { try localLattice.add(SyncConfig(project: project, policy: newPolicy)) }
                catch { print("[SyncManager] toggleProject: SyncConfig insert failed: \(error)"); return }
            }

            // Rebuild filter and push to localLattice — Lattice's reconcile_sync_filter handles catch-up
            let filter = SyncService.buildSyncFilter(from: localLattice)
            localLattice.updateSyncFilter(filter)
            
            Task { @MainActor in
                parent?.statusMessage = newPolicy == .sync
                ? "Syncing \(project)"
                : "Stopped syncing \(project)"
                
                if newPolicy == .sync {
                    SyncManager.spawnReconciliationAgent(project: project)
                }
            }
        }

        /// Expose/un-expose a project to a group (decision 5: per-member,
        /// per-project, multi-group; exposure gates WRITES only).
        ///
        /// Writes the SyncConfig row — the daemon's SyncConfig observer owns
        /// pushing per-group hub filters (increment 3), so there is no
        /// filter push here (the personal channel's filter doesn't reference
        /// exposedGroups). On expose it also backfills authorUserId on the
        /// project's nil-author rows (rows about to relay must be
        /// attributed; the daemon-start sweep is the recurring backstop) and
        /// upserts the member's GroupProjectMap row into the group spoke
        /// when the daemon has created it.
        func setGroupExposure(project: String, groupId: UUID, exposed: Bool) {
            guard let localLattice else { return }
            let gid = groupId.uuidString

            if let existing = localLattice.objects(SyncConfig.self)
                .where({ $0.project == project }).first {
                var groups = existing.exposedGroups
                if exposed { groups.insert(gid) } else { groups.remove(gid) }
                existing.exposedGroups = groups
                existing.updatedAt = Date()
            } else if exposed {
                do {
                    try localLattice.add(SyncConfig(project: project, policy: .local,
                                                    exposedTeams: [gid]))
                } catch {
                    print("[SyncManager] setGroupExposure: SyncConfig insert failed: \(error)")
                    return
                }
            }

            guard exposed else { return }
            if let me = GroupDirectory.currentUserId() {
                // .snapshot() materializes BEFORE mutating: the live cursor
                // paginates by re-running the WHERE with a moving OFFSET, so
                // writing authorUserId inside iteration shrinks the match
                // set under the cursor and silently skips alternating
                // batch-size blocks of rows.
                for memory in localLattice.objects(Memory.self)
                    .where({ $0.project == project && $0.authorUserId == nil })
                    .snapshot() {
                    memory.authorUserId = me
                }
                writeGroupProjectMap(groupId: groupId, localProject: project, me: me)
            }
        }

        /// Upsert this member's local→group project mapping into the group
        /// spoke (decision 13's default: group project named after the local
        /// project; the registry entry is created server-side by the
        /// caller). The spoke is daemon-created — absent before the daemon's
        /// first multi-spoke run, and that's fine: exposure is recorded in
        /// SyncConfig and the daemon's spoke-open backstop writes the map
        /// row when the spoke appears (GroupProjectMapWriter is the shared
        /// path — visualizer, `memory-sync expose`, and the daemon).
        private func writeGroupProjectMap(groupId: UUID, localProject: String, me: UUID) {
            let spokePath = NSHomeDirectory()
                + "/.claude/sync/group-\(groupId.uuidString).sqlite"
            GroupProjectMapWriter.upsert(spokePath: spokePath, me: me,
                                         localProject: localProject) {
                print("[SyncManager] \($0)")
            }
        }
    }
    
    var actor: Actor!
    init() {
        actor = Actor(parent: self)
    }
    
    func initialize(lattice: Lattice) {
        self.dbPath = lattice.configuration.fileURL.path()
        Task { [ref = lattice.sendableReference] in
            await actor.setLocalLattice(ref)
        }
    }
    
    func connectSync(wssEndpoint: URL, authToken: String) {
        guard !PerformanceLaunch.isIsolated else { return }
        Task {
            await actor.connectSync(wssEndpoint: wssEndpoint, authToken: authToken)
        }
    }

    /// Start the sync daemon for a signed-in user REGARDLESS of personal
    /// subscription state.
    ///
    /// The daemon is the only thing that opens group spokes, and group seats
    /// are billed on the group's own subscription — so gating its launch on
    /// a personal subscription (which is what `connectSync` does, since it
    /// is reachable only via `syncWebSocketURL`) left a paid group member
    /// with no sync at all. The daemon itself decides what it may run:
    /// personal spoke only when entitled, group spokes per membership, and
    /// idle when neither applies.
    func startDaemonIfSignedIn() {
        guard !PerformanceLaunch.isIsolated else { return }
        CLIInstaller.startDaemon()
    }
    func disconnectSync() {
        Task {
            await actor.disconnectSync()
        }
    }
    /// groupId → read-only spoke Lattice, populated when group galaxies
    /// attach (increment 6); spoke files are daemon-owned, never deleted or
    /// written here beyond GroupProjectMap upserts.
    var groupLattices: [String: Lattice] = [:]
    var statusMessage: String?

    /// One group's spoke, resolved into everything a galaxy needs.
    struct GroupGalaxySpoke: Identifiable {
        let groupId: UUID
        let name: String
        let parentId: UUID?
        let ref: LatticeThreadSafeReference
        /// Height above the deepest attached descendant: a leaf team is 1,
        /// its org 2, and so on. Personal/synced sit at 0, so a team's nodes
        /// float directly above the user's own graph.
        let hierarchyLevel: Int
        var id: UUID { groupId }
        var galaxyId: String { "group:\(groupId.uuidString)" }
    }

    /// Open every group spoke on this machine and describe it as a galaxy.
    ///
    /// Spoke FILES are the source of truth for which groups may be rendered
    /// (the daemon renames a spoke `.revoked` the moment a membership goes
    /// away); groups.json supplies only the display name and the parent
    /// chain, so a stale directory costs a nice label, never visibility.
    /// Idempotent — reuses any lattice already open.
    func discoverGroupGalaxies() -> [GroupGalaxySpoke] {
        guard !PerformanceLaunch.isIsolated else { return [] }
        let claudeDir = NSHomeDirectory() + "/.claude"
        let spokes = SyncService.discoverGroupSpokes(claudeDir: claudeDir)
        guard !spokes.isEmpty else { return [] }

        let directory = GroupDirectory.load()
        let infoById = Dictionary(uniqueKeysWithValues:
            (directory?.groups ?? []).map { ($0.id, $0) })
        let present = Set(spokes.map(\.groupId))

        let levels = GroupHierarchy.levels(
            present: present,
            parentOf: infoById.mapValues(\.parentId))

        var result: [GroupGalaxySpoke] = []
        for spoke in spokes {
            let lattice: Lattice
            if let existing = groupLattices[spoke.groupId.uuidString] {
                lattice = existing
            } else {
                guard let opened = try? Lattice(
                    Memory.self, Edge.self, GroupProjectMap.self,
                    configuration: .init(fileURL: URL(fileURLWithPath: spoke.path),
                                         migration: engramMigrations)
                ) else {
                    log("Group galaxy: could not open spoke at \(spoke.path)")
                    continue
                }
                opened.onQueryError { [gid = spoke.groupId] message in
                    print("[lattice] group \(gid) query failed (degraded to empty result): \(message)")
                }
                groupLattices[spoke.groupId.uuidString] = opened
                lattice = opened
            }
            let info = infoById[spoke.groupId]
            result.append(GroupGalaxySpoke(
                groupId: spoke.groupId,
                name: info?.name ?? "Group",
                parentId: info?.parentId,
                ref: lattice.sendableReference,
                hierarchyLevel: levels[spoke.groupId] ?? 1))
        }
        return result
    }

    /// Expose/un-expose a project to a group. See Actor.setGroupExposure.
    func setGroupExposure(project: String, groupId: UUID, exposed: Bool) {
        Task {
            await actor.setGroupExposure(project: project, groupId: groupId, exposed: exposed)
            statusMessage = exposed
                ? "Sharing \(project) with group"
                : "Stopped sharing \(project) — already-shared memories remain"
        }
    }

    /// Whether sync is configured (daemon may or may not be running).
    var isSyncing: Bool { actor.syncedLatticeRef != nil }

    /// IPC sync progress (memory.db → synced.db via daemon's IPC relay).
    var ipcProgress: Lattice.SyncProgress?

    /// WSS sync progress (synced.db → cloud via daemon's WebSocket).
    /// Cross-process: derived from AuditLog observation.
    var wssProgress: Lattice.SyncProgress?

    /// Daemon health read from ~/.claude/sync-daemon-status.json (written by
    /// memory-sync on every state transition). Progress rows alone can't show
    /// connection failures: "nothing pending" looks identical to "the WSS has
    /// been rejected with 401 for three months" — which happened.
    struct DaemonHealth {
        let state: String        // connected/disconnected/error/waiting_for_auth/idle/...
        let detail: String?
        let lastSyncAt: String?
        let updatedAt: Date?
        /// Per-group spoke states written by the daemon.
        let groups: [GroupSpokeHealth]
        var isHealthy: Bool { state == "connected" || state == "starting" }
        var isStale: Bool {
            guard let updatedAt else { return true }
            return Date().timeIntervalSince(updatedAt) > 180
        }
    }

    /// One group spoke's state. `payment_required` is deliberately NOT an
    /// error: the group's subscription lapsed, which is a billing prompt
    /// (with a checkout path for owners), not a failure the user can fix by
    /// retrying.
    struct GroupSpokeHealth: Identifiable {
        let id: String          // group UUID string
        let name: String
        let state: String       // connected / past_due / payment_required / error
        let detail: String?
        var needsBilling: Bool { state == "payment_required" || state == "past_due" }
    }
    var daemonHealth: DaemonHealth?

    func refreshDaemonHealth() {
        guard !PerformanceLaunch.isIsolated else { return }
        let path = NSHomeDirectory() + "/.claude/sync-daemon-status.json"
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = obj["state"] as? String else {
            daemonHealth = nil  // old daemon binary or daemon not running
            return
        }
        let iso = ISO8601DateFormatter()
        var spokes: [GroupSpokeHealth] = []
        if let groups = obj["groups"] as? [String: [String: Any]] {
            for (groupId, entry) in groups {
                spokes.append(GroupSpokeHealth(
                    id: groupId,
                    name: entry["name"] as? String ?? "group",
                    state: entry["state"] as? String ?? "unknown",
                    detail: entry["detail"] as? String))
            }
            spokes.sort { $0.name < $1.name }
        }
        daemonHealth = DaemonHealth(
            state: state,
            detail: obj["detail"] as? String,
            lastSyncAt: obj["lastSyncAt"] as? String,
            updatedAt: (obj["updatedAt"] as? String).flatMap { iso.date(from: $0) },
            groups: spokes
        )
    }

    // MARK: - Sync Policy

    /// Current sync policy for a project (defaults to `.local`).
    func syncPolicy(for project: String) -> SyncConfig.Policy {
        guard let localLattice = actor.localLatticeRef?.resolve() else { return .local }
        if let config = localLattice.objects(SyncConfig.self)
            .where({ $0.project == project }).first {
            return config.policy
        }
        return .local
    }

    /// Toggle a project's sync policy and update the IPC relay filter.
    func toggleProject(_ project: String) {
        Task {
            await actor.toggleProject(project)
        }
    }

    /// Project names currently configured for sync. Used by GalaxyRegistry to build
    /// the local galaxy's node filter (complement: exclude synced non-private memories).
    var syncedProjectNames: Set<String> {
        guard let localLattice = actor.localLatticeRef?.resolve() else {
            return []
        }
        var result = Set<String>()
        for config in localLattice.objects(SyncConfig.self).where({ $0.policy == .sync }) {
            result.insert(config.project)
        }
        return result
    }

    // MARK: - Reconciliation Subprocess

    private static let reconciliationLogPath = NSHomeDirectory() + "/.claude/sync-reconciliation.log"

    private static let reconciliationSystemPrompt: String = loadAgentSystemPrompt(
        name: "sync-reconciliation", bundle: engramKitResourceBundle,
        fallback: """
        You are a sync reconciliation agent. Reconcile duplicate and conflicting memories after cross-device sync.
        1. Run find_clusters(project, distance_threshold: 12, min_cluster_size: 2). If none, exit.
        2. For each cluster: recall full content, then consolidate true duplicates, connect contradictions, link related.
        3. Run a global pass with find_clusters(project: "global").
        4. Report what changed.
        Safety: always consolidate (never forget/merge), always recall before consolidating, never auto-resolve contradictions.
        """
    )

    private static func spawnReconciliationAgent(project: String) {
        let prompt = """
        Reconcile memories for project "\(project)" after sync migration.

        Follow your system prompt workflow: assess with stats + find_clusters, reconcile each cluster, \
        global pass, then report. If no clusters are found, exit immediately.
        """

        do {
            try spawnClaudeSubprocess(
                prompt: prompt,
                systemPrompt: reconciliationSystemPrompt,
                allowedTools: "mcp__memory__*",
                model: "sonnet",
                envGuard: (key: "CLAUDE_MEMORY_SYNC_RECONCILIATION", value: "1"),
                logPath: reconciliationLogPath
            )
        } catch {
            // Best-effort — don't block the UI for reconciliation failures
        }
    }
}
