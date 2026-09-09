import Testing
import EngramKit
import Lattice
import MCP
import Foundation
import os

// MARK: - IPC Relay Sync Tests
//
// These tests verify the Lattice IPC relay pattern that replaces the old
// migration-based sync. The architecture:
//
//   localLattice (memory.db, IPC target + sync filter)
//       ↓ (IPC relay, filtered)
//   syncedLattice (memory_synced.db, IPC target)
//       ↓ (WSS — not tested here)
//   cloud

@Suite("IPC Relay Sync", .serialized)
struct IPCRelaySyncTests {

    /// Create an observer config from an IPC config by stripping ipcTargets.
    /// Opens a plain DB connection (no new IPC endpoints) to the same file.
    private func observerConfig(from config: Lattice.Configuration) -> Lattice.Configuration {
        var c = config
        c.ipcTargets = nil
        return c
    }

    /// Wait for a specific table+operation to arrive on a Lattice DB via changeStream.
    /// Opens a read-only view (no IPC targets) to avoid creating new IPC connections.
    private func waitForChange(
        on config: Lattice.Configuration,
        table: String,
        operation: AuditLog.Operation,
        count: Int = 1
    ) async -> Task<Void, any Error> {
        let readConfig = observerConfig(from: config)
        var task: Task<Void, any Error>!
        await withCheckedContinuation { continuation in
            task = Task.detached {
                let db = try await Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: readConfig)
                let stream = db.changeStream
                continuation.resume(returning: ())
                var seenRowIds = Set<Int64>()
                for try await changes in stream {
                    let resolved = changes.compactMap { $0.resolve(on: db) }
                    for r in resolved where r.tableName == table && r.operation == operation {
                        seenRowIds.insert(r.rowId)
                    }
                    if seenRowIds.count >= count {
                        return
                    }
                }
            }
        }
        return task
    }

    // MARK: - Test 1: Basic IPC relay (memory.db → synced.db)

    @Test(.timeLimit(.minutes(1)))
    func ipcRelay_memoryAppearsOnSyncedSide() async throws {
        let channel = "engram-relay-\(UUID().uuidString.prefix(8))"

        let hubURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-hub-\(UUID().uuidString).sqlite")
        let syncedURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-synced-\(UUID().uuidString).sqlite")

        defer {
            try? Lattice.delete(for: .init(fileURL: hubURL))
            try? Lattice.delete(for: .init(fileURL: syncedURL))
        }

        // Hub: memory.db with IPC target (no filter — sync everything)
        var hubConfig = Lattice.Configuration(fileURL: hubURL)
        hubConfig.ipcTargets = [.init(channel: channel)]
        let hub = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: hubConfig)

        try await Task.sleep(for: .milliseconds(100))

        // Synced: memory_synced.db with same IPC channel
        var syncedConfig = Lattice.Configuration(fileURL: syncedURL)
        syncedConfig.ipcTargets = [.init(channel: channel)]
        let synced = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: syncedConfig)

        try await Task.sleep(for: .milliseconds(200))

        let task = await waitForChange(on: syncedConfig, table: "Memory", operation: .insert)

        // Write a memory on the hub side (simulates MCP server write)
        try hub.add(Memory(
            content: "Test memory for IPC relay",
            topic: "testing",
            project: "Engram",
            embedding: Vector<Float>([Float](repeating: 0.1, count: 384))
        ))

        try await task.value

        let syncedMemories = synced.objects(Memory.self)
        #expect(syncedMemories.count == 1)
        #expect(syncedMemories.first?.content == "Test memory for IPC relay")
        #expect(syncedMemories.first?.project == "Engram")
    }

    // MARK: - Regression: sync-state collapse (passive pending count drains)

    /// After a relay round-trip completes and ACKs flow back, the per-sync
    /// state rows must collapse to AuditLog.isSynchronized=1 — otherwise the
    /// passive pending count (the sync progress UI) grows forever. Historic
    /// binaries compared against a stale config snapshot instead of the live
    /// replication-slot registry and never collapsed (production accumulated
    /// 1,800+ orphaned state rows and a permanently wedged "0/365" IPC row).
    @Test(.timeLimit(.minutes(1)))
    func ipcRelay_syncStateCollapses_pendingCountDrains() async throws {
        let channel = "engram-relay-\(UUID().uuidString.prefix(8))"
        let hubURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-hub-\(UUID().uuidString).sqlite")
        let syncedURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-synced-\(UUID().uuidString).sqlite")
        defer {
            try? Lattice.delete(for: .init(fileURL: hubURL))
            try? Lattice.delete(for: .init(fileURL: syncedURL))
        }

        var hubConfig = Lattice.Configuration(fileURL: hubURL)
        hubConfig.ipcTargets = [.init(channel: channel)]
        let hub = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: hubConfig)
        try await Task.sleep(for: .milliseconds(100))

        var syncedConfig = Lattice.Configuration(fileURL: syncedURL)
        syncedConfig.ipcTargets = [.init(channel: channel)]
        let synced = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: syncedConfig)
        try await Task.sleep(for: .milliseconds(200))

        let deliveryTask = await waitForChange(on: syncedConfig, table: "Memory", operation: .insert)

        try hub.add(Memory(
            content: "Collapse regression memory",
            topic: "testing",
            project: "Engram",
            embedding: Vector<Float>([Float](repeating: 0.1, count: 384))
        ))

        try await deliveryTask.value
        #expect(synced.objects(Memory.self).count == 1)

        // The ACK collapse (UPDATE AuditLog SET isSynchronized=1) deliberately
        // emits no observer events, so poll briefly: acks land within
        // milliseconds of delivery in-process.
        var pending = hub.pendingSyncEntryCount
        for _ in 0..<100 where pending != 0 {
            try await Task.sleep(for: .milliseconds(50))
            pending = hub.pendingSyncEntryCount
        }
        #expect(
            pending == 0,
            "state rows must collapse after every registered slot ACKs — pending stuck at \(pending)")

        withExtendedLifetime((hub, synced)) {}
    }

    // MARK: - Test 2: Filtered IPC relay (only synced projects replicate)

    @Test(.timeLimit(.minutes(1)))
    func ipcRelay_filterBlocksUnsyncedProjects() async throws {
        let channel = "engram-filt-\(UUID().uuidString.prefix(8))"

        let hubURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-filt-hub-\(UUID().uuidString).sqlite")
        let syncedURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-filt-synced-\(UUID().uuidString).sqlite")

        defer {
            try? Lattice.delete(for: .init(fileURL: hubURL))
            try? Lattice.delete(for: .init(fileURL: syncedURL))
        }

        // Build a sync filter: only non-private memories from "SyncedProject"
        var filter = Lattice.SyncFilter()
        filter.include(Memory.self) { mem in
            mem.isPrivate == false && mem.project == "SyncedProject"
        }
        filter.include(Edge.self)
        filter.include(SyncConfig.self)

        var hubConfig = Lattice.Configuration(fileURL: hubURL)
        hubConfig.ipcTargets = [.init(channel: channel, syncFilter: filter)]
        let hub = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: hubConfig)

        try await Task.sleep(for: .milliseconds(100))

        var syncedConfig = Lattice.Configuration(fileURL: syncedURL)
        syncedConfig.ipcTargets = [.init(channel: channel)]
        let synced = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: syncedConfig)

        try await Task.sleep(for: .milliseconds(200))

        let task = await waitForChange(on: syncedConfig, table: "Memory", operation: .insert)

        // Write a synced-project memory (should replicate)
        try hub.add(Memory(
            content: "This should sync",
            topic: "testing",
            project: "SyncedProject",
            embedding: Vector<Float>([Float](repeating: 0.1, count: 384))
        ))

        // Write a local-only memory (should NOT replicate)
        try hub.add(Memory(
            content: "This stays local",
            topic: "testing",
            project: "LocalProject",
            embedding: Vector<Float>([Float](repeating: 0.2, count: 384))
        ))

        // Wait for the synced-project insert
        try await task.value

        // Give extra time to confirm no straggler arrives
        try await Task.sleep(for: .milliseconds(500))

        // Only the synced-project memory should appear
        let syncedMemories = synced.objects(Memory.self)
        #expect(syncedMemories.count == 1)
        #expect(syncedMemories.first?.content == "This should sync")
    }

    // MARK: - Test 3: Private memories blocked by filter

    @Test(.timeLimit(.minutes(1)))
    func ipcRelay_privateMemoriesBlocked() async throws {
        let channel = "engram-priv-\(UUID().uuidString.prefix(8))"

        let hubURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-priv-hub-\(UUID().uuidString).sqlite")
        let syncedURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-priv-synced-\(UUID().uuidString).sqlite")

        defer {
            try? Lattice.delete(for: .init(fileURL: hubURL))
            try? Lattice.delete(for: .init(fileURL: syncedURL))
        }

        var filter = Lattice.SyncFilter()
        filter.include(Memory.self) { mem in
            mem.isPrivate == false && mem.project == "MyProject"
        }

        var hubConfig = Lattice.Configuration(fileURL: hubURL)
        hubConfig.ipcTargets = [.init(channel: channel, syncFilter: filter)]
        let hub = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: hubConfig)

        try await Task.sleep(for: .milliseconds(100))

        var syncedConfig = Lattice.Configuration(fileURL: syncedURL)
        syncedConfig.ipcTargets = [.init(channel: channel)]
        let synced = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: syncedConfig)

        try await Task.sleep(for: .milliseconds(200))

        let task = await waitForChange(on: syncedConfig, table: "Memory", operation: .insert)

        // Public memory — should sync
        try hub.add(Memory(
            content: "Public knowledge",
            topic: "testing",
            project: "MyProject",
            embedding: Vector<Float>([Float](repeating: 0.1, count: 384)),
            isPrivate: false
        ))

        // Private memory — should NOT sync
        try hub.add(Memory(
            content: "Secret stuff",
            topic: "testing",
            project: "MyProject",
            embedding: Vector<Float>([Float](repeating: 0.3, count: 384)),
            isPrivate: true
        ))

        try await task.value
        try await Task.sleep(for: .milliseconds(500))

        let syncedMemories = synced.objects(Memory.self)
        #expect(syncedMemories.count == 1)
        #expect(syncedMemories.first?.content == "Public knowledge")
    }

    // MARK: - Test 4: Bidirectional relay (synced → hub flows back)

    @Test(.timeLimit(.minutes(1)))
    func ipcRelay_bidirectionalSync() async throws {
        let channel = "engram-bidi-\(UUID().uuidString.prefix(8))"

        let hubURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-bidi-hub-\(UUID().uuidString).sqlite")
        let syncedURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-bidi-synced-\(UUID().uuidString).sqlite")

        defer {
            try? Lattice.delete(for: .init(fileURL: hubURL))
            try? Lattice.delete(for: .init(fileURL: syncedURL))
        }

        var hubConfig = Lattice.Configuration(fileURL: hubURL)
        hubConfig.ipcTargets = [.init(channel: channel)]
        let hub = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: hubConfig)

        try await Task.sleep(for: .milliseconds(100))

        var syncedConfig = Lattice.Configuration(fileURL: syncedURL)
        syncedConfig.ipcTargets = [.init(channel: channel)]
        let synced = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: syncedConfig)

        try await Task.sleep(for: .milliseconds(200))

        // Phase 1: Hub → Synced
        let task1 = await waitForChange(on: syncedConfig, table: "Memory", operation: .insert)
        try hub.add(Memory(
            content: "From MCP server",
            project: "Engram",
            embedding: Vector<Float>([Float](repeating: 0.1, count: 384))
        ))
        try await task1.value
        #expect(synced.objects(Memory.self).count == 1)

        // Phase 2: Synced → Hub (simulates cloud download arriving via WSS)
        print("[test4] Phase 2: setting up waitForChange on hub")
        let task2 = await waitForChange(on: hubConfig, table: "Memory", operation: .insert)
        print("[test4] Phase 2: adding memory on synced")
        try synced.add(Memory(
            content: "From cloud",
            project: "Engram",
            embedding: Vector<Float>([Float](repeating: 0.2, count: 384))
        ))
        print("[test4] Phase 2: waiting for task2")
        try await task2.value
        print("[test4] Phase 2: task2 completed, hub count = \(hub.objects(Memory.self).count)")

        #expect(hub.objects(Memory.self).count == 2)
        let contents = hub.objects(Memory.self).map(\.content).sorted()
        #expect(contents == ["From MCP server", "From cloud"])
    }

    // MARK: - Test 5: Edge replication alongside memories

    @Test(.timeLimit(.minutes(1)))
    func ipcRelay_edgesReplicateWithMemories() async throws {
        let channel = "engram-edge-\(UUID().uuidString.prefix(8))"

        let hubURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-edge-hub-\(UUID().uuidString).sqlite")
        let syncedURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-edge-synced-\(UUID().uuidString).sqlite")

        defer {
            try? Lattice.delete(for: .init(fileURL: hubURL))
            try? Lattice.delete(for: .init(fileURL: syncedURL))
        }

        var filter = Lattice.SyncFilter()
        filter.include(Memory.self) { $0.isPrivate == false }
        filter.include(Edge.self)

        var hubConfig = Lattice.Configuration(fileURL: hubURL)
        hubConfig.ipcTargets = [.init(channel: channel, syncFilter: filter)]
        let hub = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: hubConfig)

        try await Task.sleep(for: .milliseconds(100))

        var syncedConfig = Lattice.Configuration(fileURL: syncedURL)
        syncedConfig.ipcTargets = [.init(channel: channel)]
        let synced = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: syncedConfig)

        try await Task.sleep(for: .milliseconds(200))

        // Add two memories, wait for both to arrive
        let memTask = await waitForChange(on: syncedConfig, table: "Memory", operation: .insert, count: 2)

        let m1 = Memory(
            content: "Architecture decision",
            project: "Engram",
            embedding: Vector<Float>([Float](repeating: 0.1, count: 384))
        )
        let m2 = Memory(
            content: "Implementation detail",
            project: "Engram",
            embedding: Vector<Float>([Float](repeating: 0.2, count: 384))
        )
        try hub.add(m1)
        try hub.add(m2)

        try await memTask.value
        #expect(synced.objects(Memory.self).count == 2)

        // Add an edge connecting them
        let edgeTask = await waitForChange(on: syncedConfig, table: "Edge", operation: .insert)
        let edge = Edge(sourceGlobalId: m1.globalId!, targetGlobalId: m2.globalId!, relation: .partOf)
        try hub.add(edge)

        try await edgeTask.value

        #expect(synced.objects(Memory.self).count == 2)
        #expect(synced.objects(Edge.self).count == 1)

        let syncedEdge = synced.objects(Edge.self).first!
        #expect(syncedEdge.relation == .partOf)
        #expect(syncedEdge.sourceGlobalId == m1.globalId)
        #expect(syncedEdge.targetGlobalId == m2.globalId)
    }

    // MARK: - Test 6: Dynamic filter update via updateSyncFilter

    @Test(.timeLimit(.minutes(1)))
    func ipcRelay_dynamicFilterUpdate() async throws {
        let channel = "engram-dynfilt-\(UUID().uuidString.prefix(8))"

        let hubURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-dyn-hub-\(UUID().uuidString).sqlite")
        let syncedURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-dyn-synced-\(UUID().uuidString).sqlite")

        defer {
            try? Lattice.delete(for: .init(fileURL: hubURL))
            try? Lattice.delete(for: .init(fileURL: syncedURL))
        }

        // Start with filter for "ProjectA" only
        var filter = Lattice.SyncFilter()
        filter.include(Memory.self) { $0.project == "ProjectA" && $0.isPrivate == false }
        filter.include(Edge.self)
        filter.include(SyncConfig.self)

        var hubConfig = Lattice.Configuration(fileURL: hubURL)
        hubConfig.ipcTargets = [.init(channel: channel, syncFilter: filter)]
        let hub = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: hubConfig)

        try await Task.sleep(for: .milliseconds(100))

        var syncedConfig = Lattice.Configuration(fileURL: syncedURL)
        syncedConfig.ipcTargets = [.init(channel: channel)]
        let synced = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: syncedConfig)

        try await Task.sleep(for: .milliseconds(200))

        // Wait for ProjectA insert
        let task1 = await waitForChange(on: syncedConfig, table: "Memory", operation: .insert)

        // Add memories for both projects
        try hub.add(Memory(
            content: "ProjectA memory",
            project: "ProjectA",
            embedding: Vector<Float>([Float](repeating: 0.1, count: 384))
        ))
        try hub.add(Memory(
            content: "ProjectB memory",
            project: "ProjectB",
            embedding: Vector<Float>([Float](repeating: 0.2, count: 384))
        ))

        // Wait for ProjectA to arrive
        try await task1.value
        try await Task.sleep(for: .milliseconds(500))

        // Only ProjectA should have synced
        #expect(synced.objects(Memory.self).count == 1)
        #expect(synced.objects(Memory.self).first?.content == "ProjectA memory")

        // Update filter to include both projects (simulates toggleProject)
        var newFilter = Lattice.SyncFilter()
        newFilter.include(Memory.self) { mem in
            (mem.project == "ProjectA" || mem.project == "ProjectB") && mem.isPrivate == false
        }
        newFilter.include(Edge.self)
        newFilter.include(SyncConfig.self)

        // Wait for the reconciliation insert
        let task2 = await waitForChange(on: syncedConfig, table: "Memory", operation: .insert)

        hub.updateSyncFilter(newFilter)

        // reconcile_sync_filter should catch up ProjectB
        try await task2.value

        #expect(synced.objects(Memory.self).count == 2)
        let contents = synced.objects(Memory.self).map(\.content).sorted()
        #expect(contents == ["ProjectA memory", "ProjectB memory"])
    }

    // MARK: - Test 7: Filter narrowing sends synthetic DELETEs
    //
    // Mirrors production: hub (memory.db) and synced (memory_synced.db) are
    // separate DBs connected by IPC. Multiple projects synced, one toggled off.
    // Uses .in([projects]) predicate like SyncManager.buildSyncFilter.
    // No sleeps — tests whether IPC handshake races with data flow.

    @Test(.timeLimit(.minutes(1)))
    func ipcRelay_filterNarrowingSendsDeletes() async throws {
        let channel = "engram-narrow-\(UUID().uuidString.prefix(8))"

        let hubURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-narrow-hub-\(UUID().uuidString).sqlite")
        let syncedURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-narrow-synced-\(UUID().uuidString).sqlite")

        defer {
            try? Lattice.delete(for: .init(fileURL: hubURL))
            try? Lattice.delete(for: .init(fileURL: syncedURL))
        }

        // Initial filter: Lattice + engram-server + ComoHotels all synced
        let syncedProjects = ["Lattice", "engram-server", "ComoHotels"]
        var filter = Lattice.SyncFilter()
        filter.include(Memory.self) { mem in
            mem.isPrivate == false && mem.project.in(syncedProjects)
        }
        filter.include(Edge.self)
        filter.include(SyncConfig.self)

        var hubConfig = Lattice.Configuration(fileURL: hubURL)
        hubConfig.ipcTargets = [.init(channel: channel, syncFilter: filter)]
        let hub = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: hubConfig)

        var syncedConfig = Lattice.Configuration(fileURL: syncedURL)
        syncedConfig.ipcTargets = [.init(channel: channel)]
        let synced = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: syncedConfig)

        // Add memories across all 3 projects, wait for all 5 to arrive on synced
        let insertTask = await waitForChange(on: syncedConfig, table: "Memory", operation: .insert, count: 5)

        try hub.add(Memory(
            content: "Lattice arch decision",
            project: "Lattice",
            embedding: Vector<Float>([Float](repeating: 0.1, count: 384))
        ))
        try hub.add(Memory(
            content: "engram-server deploy note",
            project: "engram-server",
            embedding: Vector<Float>([Float](repeating: 0.2, count: 384))
        ))
        try hub.add(Memory(
            content: "ComoHotels drag fix",
            project: "ComoHotels",
            embedding: Vector<Float>([Float](repeating: 0.3, count: 384))
        ))
        try hub.add(Memory(
            content: "ComoHotels chat jitter",
            project: "ComoHotels",
            embedding: Vector<Float>([Float](repeating: 0.4, count: 384))
        ))
        try hub.add(Memory(
            content: "ComoHotels payment flow",
            project: "ComoHotels",
            embedding: Vector<Float>([Float](repeating: 0.5, count: 384))
        ))

        try await insertTask.value
        #expect(synced.objects(Memory.self).count == 5)

        // Narrow filter: toggle ComoHotels to local, keep Lattice + engram-server
        let remainingProjects = ["Lattice", "engram-server"]
        var newFilter = Lattice.SyncFilter()
        newFilter.include(Memory.self) { mem in
            mem.isPrivate == false && mem.project.in(remainingProjects)
        }
        newFilter.include(Edge.self)
        newFilter.include(SyncConfig.self)

        // Wait for synthetic DELETEs of the 3 ComoHotels rows on synced side
        let deleteTask = await waitForChange(on: syncedConfig, table: "Memory", operation: .delete, count: 3)

        hub.updateSyncFilter(newFilter)

        // reconcile_sync_filter should synthesize DELETE audit entries
        // for the 3 ComoHotels rows that no longer match the narrowed filter
        try await deleteTask.value

        // Only Lattice + engram-server memories should remain
        let remaining = synced.objects(Memory.self)
        #expect(remaining.count == 2)
        let projects = Set(remaining.map(\.project))
        #expect(projects == ["Lattice", "engram-server"])
    }

    // MARK: - Test 8: Filter narrowing must NOT delete from source (relay loop proof)
    //
    // Proves the critical data-loss bug: when localLattice narrows its sync filter,
    // synthetic DELETEs sent to syncedLattice must NOT relay back and delete from
    // localLattice (the source of truth). IPC is bidirectional, so the DELETE
    // AuditLog entry on syncedLattice is visible to syncedLattice's IPC synchronizer
    // unless properly marked.

    @Test(.timeLimit(.minutes(1)))
    func ipcRelay_filterNarrowingDoesNotDeleteFromSource() async throws {
        let channel = "engram-nodelete-\(UUID().uuidString.prefix(8))"

        let localURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-nodelete-local-\(UUID().uuidString).sqlite")
        let syncedURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-nodelete-synced-\(UUID().uuidString).sqlite")

        defer {
            try? Lattice.delete(for: .init(fileURL: localURL))
            try? Lattice.delete(for: .init(fileURL: syncedURL))
        }

        // Initial filter: projects A, B, C all synced
        let syncedProjects = ["ProjectA", "ProjectB", "ProjectC"]
        var filter = Lattice.SyncFilter()
        filter.include(Memory.self) { mem in
            mem.isPrivate == false && mem.project.in(syncedProjects)
        }
        filter.include(Edge.self)
        filter.include(SyncConfig.self)

        // localLattice = source of truth (memory.sqlite analog)
        var localConfig = Lattice.Configuration(fileURL: localURL)
        localConfig.ipcTargets = [.init(channel: channel, syncFilter: filter)]
        let local = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: localConfig)

        try await Task.sleep(for: .milliseconds(100))

        // syncedLattice = relay target (memory-synced.sqlite analog)
        // Also has IPC target on same channel — bidirectional, like production
        var syncedConfig = Lattice.Configuration(fileURL: syncedURL)
        syncedConfig.ipcTargets = [.init(channel: channel)]
        let synced = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: syncedConfig)

        try await Task.sleep(for: .milliseconds(200))

        // Add memories across all 3 projects to localLattice
        let insertTask = await waitForChange(on: syncedConfig, table: "Memory", operation: .insert, count: 5)

        try local.add(Memory(content: "A knowledge", project: "ProjectA",
            embedding: Vector<Float>([Float](repeating: 0.1, count: 384))))
        try local.add(Memory(content: "B knowledge", project: "ProjectB",
            embedding: Vector<Float>([Float](repeating: 0.2, count: 384))))
        try local.add(Memory(content: "C item 1", project: "ProjectC",
            embedding: Vector<Float>([Float](repeating: 0.3, count: 384))))
        try local.add(Memory(content: "C item 2", project: "ProjectC",
            embedding: Vector<Float>([Float](repeating: 0.4, count: 384))))
        try local.add(Memory(content: "C item 3", project: "ProjectC",
            embedding: Vector<Float>([Float](repeating: 0.5, count: 384))))

        try await insertTask.value
        #expect(synced.objects(Memory.self).count == 5)
        #expect(local.objects(Memory.self).count == 5, "Precondition: local has all 5 memories")

        // Narrow filter: remove ProjectC (simulates toggleProject to local)
        let remainingProjects = ["ProjectA", "ProjectB"]
        var newFilter = Lattice.SyncFilter()
        newFilter.include(Memory.self) { mem in
            mem.isPrivate == false && mem.project.in(remainingProjects)
        }
        newFilter.include(Edge.self)
        newFilter.include(SyncConfig.self)

        let deleteTask = await waitForChange(on: syncedConfig, table: "Memory", operation: .delete, count: 3)
        local.updateSyncFilter(newFilter)

        // Wait for DELETEs to arrive and be applied on synced side
        try await deleteTask.value

        // Synced should lose the 3 ProjectC rows (correct behavior)
        #expect(synced.objects(Memory.self).count == 2, "synced should have 2 remaining")

        // *** CRITICAL ASSERTION ***
        // localLattice must STILL have all 5 memories.
        // If the relay loop exists, the synthetic DELETEs will have been relayed
        // back from syncedLattice → localLattice, deleting from the source of truth.
        #expect(local.objects(Memory.self).count == 5,
            "DATA LOSS BUG: local lost memories due to DELETE relay loop")

        // Give extra time for any async relay to propagate
        try await Task.sleep(for: .seconds(2))

        // Check again — the relay might be delayed
        #expect(local.objects(Memory.self).count == 5,
            "DATA LOSS BUG (delayed): local lost memories due to DELETE relay loop")

        // Verify the correct memories survived on each side
        let localProjects = Set(local.objects(Memory.self).map(\.project))
        #expect(localProjects == ["ProjectA", "ProjectB", "ProjectC"],
            "local should retain all projects including the un-synced one")

        let syncedProjects2 = Set(synced.objects(Memory.self).map(\.project))
        #expect(syncedProjects2 == ["ProjectA", "ProjectB"],
            "synced should only have the still-synced projects")
    }

    // MARK: - Test 9: Full 3-hop relay chain (local → synced → cloud → synced → local)
    //
    // Simulates production topology:
    //   localLattice ←IPC:ch1→ syncedLattice ←IPC:ch2→ cloudLattice
    //
    // After filter narrowing, synthetic DELETEs flow local → synced → cloud.
    // The cloud (in production, the WSS server) might echo them back.
    // Verifies that localLattice retains its data through the full chain.

    @Test(.timeLimit(.minutes(2)))
    func ipcRelay_fullRelayChainDoesNotDeleteFromSource() async throws {
        let ch1 = "engram-chain1-\(UUID().uuidString.prefix(8))"
        let ch2 = "engram-chain2-\(UUID().uuidString.prefix(8))"

        let localURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-chain-local-\(UUID().uuidString).sqlite")
        let syncedURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-chain-synced-\(UUID().uuidString).sqlite")
        let cloudURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-chain-cloud-\(UUID().uuidString).sqlite")

        defer {
            try? Lattice.delete(for: .init(fileURL: localURL))
            try? Lattice.delete(for: .init(fileURL: syncedURL))
            try? Lattice.delete(for: .init(fileURL: cloudURL))
        }

        // localLattice: source of truth with filtered IPC sync on ch1
        let syncedProjects = ["ProjectA", "ProjectB", "ProjectC"]
        var filter = Lattice.SyncFilter()
        filter.include(Memory.self) { mem in
            mem.isPrivate == false && mem.project.in(syncedProjects)
        }
        filter.include(Edge.self)
        filter.include(SyncConfig.self)

        var localConfig = Lattice.Configuration(fileURL: localURL)
        localConfig.ipcTargets = [.init(channel: ch1, syncFilter: filter)]
        let local = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: localConfig)

        try await Task.sleep(for: .milliseconds(100))

        // syncedLattice: relay node with IPC on both ch1 (to local) and ch2 (to cloud)
        var syncedConfig = Lattice.Configuration(fileURL: syncedURL)
        syncedConfig.ipcTargets = [
            .init(channel: ch1),  // bidirectional with local
            .init(channel: ch2),  // bidirectional with cloud (simulates WSS)
        ]
        let synced = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: syncedConfig)

        try await Task.sleep(for: .milliseconds(100))

        // cloudLattice: simulates cloud server with IPC on ch2
        var cloudConfig = Lattice.Configuration(fileURL: cloudURL)
        cloudConfig.ipcTargets = [.init(channel: ch2)]
        let cloud = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: cloudConfig)

        try await Task.sleep(for: .milliseconds(300))

        // Add 5 memories to localLattice, wait for them to propagate all the way to cloud
        let syncedInsertTask = await waitForChange(on: syncedConfig, table: "Memory", operation: .insert, count: 5)
        let cloudInsertTask = await waitForChange(on: cloudConfig, table: "Memory", operation: .insert, count: 5)

        try local.add(Memory(content: "A knowledge", project: "ProjectA",
            embedding: Vector<Float>([Float](repeating: 0.1, count: 384))))
        try local.add(Memory(content: "B knowledge", project: "ProjectB",
            embedding: Vector<Float>([Float](repeating: 0.2, count: 384))))
        try local.add(Memory(content: "C item 1", project: "ProjectC",
            embedding: Vector<Float>([Float](repeating: 0.3, count: 384))))
        try local.add(Memory(content: "C item 2", project: "ProjectC",
            embedding: Vector<Float>([Float](repeating: 0.4, count: 384))))
        try local.add(Memory(content: "C item 3", project: "ProjectC",
            embedding: Vector<Float>([Float](repeating: 0.5, count: 384))))

        try await syncedInsertTask.value
        try await cloudInsertTask.value

        #expect(local.objects(Memory.self).count == 5, "Precondition: local has 5")
        #expect(synced.objects(Memory.self).count == 5, "Precondition: synced has 5")
        #expect(cloud.objects(Memory.self).count == 5, "Precondition: cloud has 5")

        // Narrow filter: remove ProjectC
        let remainingProjects = ["ProjectA", "ProjectB"]
        var newFilter = Lattice.SyncFilter()
        newFilter.include(Memory.self) { mem in
            mem.isPrivate == false && mem.project.in(remainingProjects)
        }
        newFilter.include(Edge.self)
        newFilter.include(SyncConfig.self)

        // Stage A4 semantics: narrowing emits MARKED filter-removal DELETEs
        // that clear exactly ONE mirror (the first IPC hop) and stop dead —
        // recorded synced-for-all-sync_ids on arrival, so the second hop
        // never even hears about them. This test used to wait for the
        // deletes to reach the CLOUD hop, which A4 deliberately prevents
        // (un-syncing a project must not delete it from the cloud copy —
        // the March data-loss incident's exact mechanism), so it hung
        // forever. Only the first hop's deletes are awaited now.
        let syncedDeleteTask = await waitForChange(on: syncedConfig, table: "Memory", operation: .delete, count: 3)

        local.updateSyncFilter(newFilter)

        try await syncedDeleteTask.value

        // Give time for any (incorrect) onward relay to propagate before
        // asserting its absence.
        try await Task.sleep(for: .seconds(3))

        // The first hop obeys the narrowed filter and clears its mirror.
        #expect(synced.objects(Memory.self).count == 2, "synced should have 2")

        // *** CRITICAL ASSERTIONS ***
        // The marked deletes stop at the first hop: the cloud keeps every
        // row (narrowing is "stop syncing", never a remote delete)…
        let cloudCount = cloud.objects(Memory.self).count
        #expect(cloudCount == 5,
            "A4 violation: narrowing deletes relayed PAST the first hop — cloud has \(cloudCount) instead of 5")
        // …and nothing boomerangs into the source.
        let localCount = local.objects(Memory.self).count
        #expect(localCount == 5,
            "DATA LOSS: local has \(localCount) instead of 5 — DELETE relayed back through chain")

        let localProjects = Set(local.objects(Memory.self).map(\.project))
        #expect(localProjects == ["ProjectA", "ProjectB", "ProjectC"],
            "local should retain ALL projects including the un-synced one")
    }

    // MARK: - Test 10: Fresh sync DB should only receive filtered data
    //
    // Reproduces the production scenario: user deletes the synced DB and restarts.
    // The app reconnects with the same filtered IPC (using .in([projects]) predicate
    // like SyncManager.buildSyncFilter). The fresh synced DB should receive ONLY
    // the filtered rows — not the entire audit log.
    //
    // Uses .in() predicate to match SyncManager production filter shape:
    //   filter.include(Memory.self) { !$0.isPrivate && $0.project.in(syncedProjects) }
    //
    // Verifies:
    //   1. Fresh synced DB receives only filtered projects (correctness)
    //   2. Non-filtered projects don't leak through (filter respect)
    //   3. Upload volume is proportional to filtered data, not entire audit log

    @Test(.timeLimit(.minutes(2)))
    func ipcRelay_freshSyncDbRespectsFilter() async throws {
        let channel = "engram-filtfresh-\(UUID().uuidString.prefix(8))"

        let localURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-filtfresh-local-\(UUID().uuidString).sqlite")
        let syncedURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-filtfresh-synced-\(UUID().uuidString).sqlite")

        defer {
            try? Lattice.delete(for: .init(fileURL: localURL))
            try? Lattice.delete(for: .init(fileURL: syncedURL))
        }

        // === Phase 1: Initial sync with .in() filter ===
        // Filter: only Lattice + engram-server (not ComoHotels, not LocalOnly)
        // Uses same .in() predicate shape as SyncManager.buildSyncFilter
        let syncedProjects = ["Lattice", "engram-server"]
        let memoryPredicate: @Sendable (Query<Memory>) -> Query<Bool> = { mem in
            return mem.isPrivate == false && mem.project.in(syncedProjects)
        }
        var filter = Lattice.SyncFilter()
        filter.include(Memory.self, where: memoryPredicate)
        filter.include(Edge.self) { edge in
            edge.sourceGlobalId.in(\Memory.globalId, where: memoryPredicate)
                && edge.targetGlobalId.in(\Memory.globalId, where: memoryPredicate)
        }
        filter.include(SyncConfig.self)

        var localConfig = Lattice.Configuration(fileURL: localURL)
        localConfig.ipcTargets = [.init(channel: channel, syncFilter: filter)]
        var local: Lattice! = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: localConfig)

        try await Task.sleep(for: .milliseconds(100))

        var syncedConfig = Lattice.Configuration(fileURL: syncedURL)
        syncedConfig.ipcTargets = [.init(channel: channel)]
        var synced: Lattice! = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: syncedConfig)

        try await Task.sleep(for: .milliseconds(200))

        // Write memories across 4 projects: 2 filtered, 2 not
        let insertTask = await waitForChange(on: syncedConfig, table: "Memory", operation: .insert, count: 3)

        // Filtered (should sync)
        try local.add(Memory(content: "Lattice arch", project: "Lattice",
            embedding: Vector<Float>([Float](repeating: 0.1, count: 384))))
        try local.add(Memory(content: "engram-server deploy", project: "engram-server",
            embedding: Vector<Float>([Float](repeating: 0.2, count: 384))))
        try local.add(Memory(content: "Lattice bugfix", project: "Lattice",
            embedding: Vector<Float>([Float](repeating: 0.3, count: 384))))
        await Task.yield()

        // NOT filtered (should NOT sync)
        try local.add(Memory(content: "ComoHotels drag fix", project: "ComoHotels",
            embedding: Vector<Float>([Float](repeating: 0.4, count: 384))))
        try local.add(Memory(content: "ComoHotels payment", project: "ComoHotels",
            embedding: Vector<Float>([Float](repeating: 0.5, count: 384))))
        try local.add(Memory(content: "LocalOnly secret", project: "LocalOnly",
            embedding: Vector<Float>([Float](repeating: 0.6, count: 384)),
            isPrivate: true))

        try await insertTask.value
        try await Task.sleep(for: .milliseconds(500))

        // Preconditions
        #expect(local.objects(Memory.self).count == 6, "local has all 6 memories")
        #expect(synced.objects(Memory.self).count == 3, "synced has only 3 filtered memories")
        let phase1Projects = Set(synced.objects(Memory.self).map(\.project))
        #expect(phase1Projects == ["Lattice", "engram-server"],
            "Phase 1: only filtered projects on synced")

        // Wait for ACKs (eager cleanup will delete _lattice_sync_state rows)
        try await Task.sleep(for: .seconds(1))

        // === Phase 2: Delete synced DB, reconnect with SAME filter ===
        // Match production flow: SyncManager.compactBeforeSync() + connectSync()
        local = nil
        synced = nil
        try await Task.sleep(for: .milliseconds(500))

        try? Lattice.delete(for: .init(fileURL: syncedURL))

        // Recreate local WITHOUT IPC first (to compact like production)
        var compactConfig = Lattice.Configuration(fileURL: localURL)
        let compactLocal = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: compactConfig)

        // Match production: compactBeforeSync() runs before connectSync()
        // This creates NEW AuditLog entries with isSynchronized=0
        compactLocal.forceCompactHistory()
        compactLocal.vacuum()
        compactLocal.checkpoint()

        #expect(compactLocal.objects(Memory.self).count == 6,
            "Phase 2 precondition: local still has 6 after compaction")

        // Reconnect local with the SAME filter + IPC target
        var localConfig2 = Lattice.Configuration(fileURL: localURL)
        localConfig2.ipcTargets = [.init(channel: channel, syncFilter: filter)]
        let local2 = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: localConfig2)

        #expect(local2.objects(Memory.self).count == 6,
            "Phase 2 precondition: local still has 6 before IPC connects")

        try await Task.sleep(for: .milliseconds(100))

        // Track sync progress from the hub
        // Lattice 1.x: progress is an AsyncStream, not a callback.
        nonisolated(unsafe) var lastProgress: Lattice.SyncProgress?
        let progressStream = local2.syncProgressStream
        let progressTask = Task.detached {
            for await p in progressStream { lastProgress = p }
        }
        defer { progressTask.cancel() }

        // Create fresh synced DB — triggers IPC connection
        var syncedConfig2 = Lattice.Configuration(fileURL: syncedURL)
        syncedConfig2.ipcTargets = [.init(channel: channel)]
        let synced2 = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: syncedConfig2)

        // Reconnection can finish before an event observer subscribes. Await
        // the resulting state with a deadline in this task, so cancellation
        // cannot leave a detached changeStream watcher running forever.
        let syncDeadline = ContinuousClock.now + .seconds(30)
        while synced2.objects(Memory.self).count < 3 {
            try Task.checkCancellation()
            guard ContinuousClock.now < syncDeadline else {
                throw NSError(domain: "IPCRelaySyncTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Fresh synced database did not receive three memories within 30 seconds"])
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
        try await Task.sleep(for: .seconds(2))

        // === Assertions ===

        // 1. Correctness: only filtered memories on fresh synced DB
        let syncedMemories = synced2.objects(Memory.self)
        let syncedProjectSet = Set(syncedMemories.map(\.project))
        #expect(syncedProjectSet == ["Lattice", "engram-server"],
            "FILTER BUG: synced has projects \(syncedProjectSet) — expected only Lattice + engram-server")

        // 2. Exact count: only the 3 filtered memories (2 Lattice + 1 engram-server)
        #expect(syncedMemories.count == 3,
            "FILTER BUG: synced has \(syncedMemories.count) memories — expected 3")

        // 3. Non-filtered projects must NOT appear
        let comoCount = syncedMemories.filter { $0.project == "ComoHotels" }.count
        #expect(comoCount == 0,
            "FILTER LEAK: \(comoCount) ComoHotels memories leaked through to fresh synced DB")

        let localOnlyCount = syncedMemories.filter { $0.project == "LocalOnly" }.count
        #expect(localOnlyCount == 0,
            "FILTER LEAK: \(localOnlyCount) LocalOnly memories leaked through to fresh synced DB")

        // 4. Upload volume: should be ≤ 3 (only filtered memories), not 6+ (entire audit log)
        // After compaction, the AuditLog has entries for ALL 6 memories (compacted state).
        // upload_pending_changes should only process/send the 3 filtered ones.
        // If totalUpload > 3, the entire audit log is being replayed regardless of filter.
        if let progress = lastProgress {
            #expect(progress.totalUpload <= 3,
                "AUDIT LOG REPLAY: upload_pending_changes processed \(progress.totalUpload) entries — expected ≤ 3 (only filtered). Entire audit log is being sent on fresh sync DB.")
        }

        // 5. Local must retain all data
        #expect(local2.objects(Memory.self).count == 6,
            "DATA LOSS: local lost memories during fresh sync reconnect")
    }

    // MARK: - Test 11: Delete synced DB and start fresh with narrower filter (data loss check)
    //
    // Reproduces the production data-loss scenario:
    // 1. Sync data through IPC (all projects, ACKs trigger eager cleanup)
    // 2. Delete the synced DB (user starts fresh)
    // 3. Reconnect with narrower filter (ComoHotels toggled to local)
    // 4. upload_pending_changes re-uploads entire AuditLog (eager cleanup
    //    deleted _lattice_sync_state rows, so entries look "pending" again)
    // 5. Verify localLattice retains ALL its data

    @Test(.timeLimit(.minutes(2)))
    func ipcRelay_deleteSyncedDbAndStartFresh() async throws {
        let channel = "engram-fresh-\(UUID().uuidString.prefix(8))"

        let localURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-fresh-local-\(UUID().uuidString).sqlite")
        let syncedURL = FileManager.default.temporaryDirectory
            .appending(path: "relay-fresh-synced-\(UUID().uuidString).sqlite")

        defer {
            try? Lattice.delete(for: .init(fileURL: localURL))
            try? Lattice.delete(for: .init(fileURL: syncedURL))
        }

        // === Phase 1: Normal sync with wide filter ===
        let allProjects = ["ProjectA", "ProjectB", "ComoHotels"]
        var wideFilter = Lattice.SyncFilter()
        wideFilter.include(Memory.self) { mem in
            mem.isPrivate == false && mem.project.in(allProjects)
        }
        wideFilter.include(Edge.self)
        wideFilter.include(SyncConfig.self)

        var localConfig = Lattice.Configuration(fileURL: localURL)
        localConfig.ipcTargets = [.init(channel: channel, syncFilter: wideFilter)]
        var local: Lattice! = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: localConfig)

        try await Task.sleep(for: .milliseconds(100))

        var syncedConfig = Lattice.Configuration(fileURL: syncedURL)
        syncedConfig.ipcTargets = [.init(channel: channel)]
        var synced: Lattice! = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: syncedConfig)

        try await Task.sleep(for: .milliseconds(200))

        // Sync 5 memories
        let insertTask = await waitForChange(on: syncedConfig, table: "Memory", operation: .insert, count: 5)

        try local.add(Memory(content: "A knowledge", project: "ProjectA",
            embedding: Vector<Float>([Float](repeating: 0.1, count: 384))))
        try local.add(Memory(content: "B knowledge", project: "ProjectB",
            embedding: Vector<Float>([Float](repeating: 0.2, count: 384))))
        try local.add(Memory(content: "Como item 1", project: "ComoHotels",
            embedding: Vector<Float>([Float](repeating: 0.3, count: 384))))
        try local.add(Memory(content: "Como item 2", project: "ComoHotels",
            embedding: Vector<Float>([Float](repeating: 0.4, count: 384))))
        try local.add(Memory(content: "Como item 3", project: "ComoHotels",
            embedding: Vector<Float>([Float](repeating: 0.5, count: 384))))

        try await insertTask.value
        #expect(synced.objects(Memory.self).count == 5, "Phase 1: synced has all 5")

        // Wait for ACKs to arrive and trigger eager cleanup on local
        try await Task.sleep(for: .seconds(1))

        #expect(local.objects(Memory.self).count == 5, "Phase 1: local still has 5")

        // === Phase 2: Tear down and delete synced DB ===
        local = nil
        synced = nil
        try await Task.sleep(for: .milliseconds(500))

        // Delete the synced DB entirely (user starts fresh)
        try? Lattice.delete(for: .init(fileURL: syncedURL))

        // === Phase 3: Reconnect with narrower filter ===
        let narrowProjects = ["ProjectA", "ProjectB"]
        var narrowFilter = Lattice.SyncFilter()
        narrowFilter.include(Memory.self) { mem in
            mem.isPrivate == false && mem.project.in(narrowProjects)
        }
        narrowFilter.include(Edge.self)
        narrowFilter.include(SyncConfig.self)

        // Recreate local with the narrow filter
        var localConfig2 = Lattice.Configuration(fileURL: localURL)
        localConfig2.ipcTargets = [.init(channel: channel, syncFilter: narrowFilter)]
        let local2 = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: localConfig2)

        // Precondition: local still has all 5 before IPC connects
        #expect(local2.objects(Memory.self).count == 5,
            "Phase 3 precondition: local still has 5 before IPC connects")

        try await Task.sleep(for: .milliseconds(100))

        // Create fresh synced DB — triggers IPC connection
        var syncedConfig2 = Lattice.Configuration(fileURL: syncedURL)
        syncedConfig2.ipcTargets = [.init(channel: channel)]
        let synced2 = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: syncedConfig2)

        // Wait for the full re-upload + reconciliation to complete
        // (the entire AuditLog will be re-processed due to eager cleanup bug)
        try await Task.sleep(for: .seconds(5))

        // *** CRITICAL: localLattice must retain ALL 5 memories ***
        let localCount = local2.objects(Memory.self).count
        print("[test10] local has \(localCount) memories")
        #expect(localCount == 5,
            "DATA LOSS: local has \(localCount) instead of 5 — delete synced + fresh start lost data")

        let localProjects = Set(local2.objects(Memory.self).map(\.project))
        #expect(localProjects == ["ProjectA", "ProjectB", "ComoHotels"],
            "local should retain all projects including ComoHotels")

        // Synced should ONLY have ProjectA + ProjectB (filter applied)
        let syncedCount = synced2.objects(Memory.self).count
        let syncedProjects = Set(synced2.objects(Memory.self).map(\.project))
        print("[test10] synced has \(syncedCount) memories, projects: \(syncedProjects)")
        for mem in synced2.objects(Memory.self) {
            print("[test10]   synced memory: project=\(mem.project ?? "nil") content=\(mem.content)")
        }
        #expect(syncedCount == 2,
            "FILTER BUG: synced has \(syncedCount) instead of 2 — filter not applied on re-upload")
        #expect(syncedProjects == ["ProjectA", "ProjectB"],
            "FILTER BUG: synced has projects \(syncedProjects) — ComoHotels should be excluded")
    }

    // MARK: - Test: Safe compact during active sync doesn't cause re-sync storm

    @Test(.timeLimit(.minutes(1)))
    func test_compactDuringActiveSync_noResyncStorm() async throws {
        let localURL = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 30)).sqlite")
        let syncedURL = FileManager.default.temporaryDirectory
            .appending(path: "\(String.random(length: 30)).sqlite")
        defer {
            try? Lattice.delete(for: .init(fileURL: localURL))
            try? Lattice.delete(for: .init(fileURL: syncedURL))
        }

        let channel = "compact-active-\(String.random(length: 8))"

        // Set up IPC relay
        var localConfig = Lattice.Configuration(fileURL: localURL)
        localConfig.ipcTargets = [.init(channel: channel)]
        let local = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: localConfig)

        var syncedConfig = Lattice.Configuration(fileURL: syncedURL)
        syncedConfig.ipcTargets = [.init(channel: channel)]
        let synced = try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: syncedConfig)

        // Write initial batch and sync
        let task1 = await waitForChange(on: syncedConfig, table: "Memory", operation: .insert, count: 3)
        for i in 1...3 {
            let m = Memory()
            m.content = "pre-compact-\(i)"
            m.project = "test"
            try local.add(m)
        }
        try await task1.value

        #expect(synced.objects(Memory.self).count == 3, "Initial sync should deliver 3 memories")

        // Wait for ACKs so replication slots advance
        try await Task.sleep(for: .seconds(1))

        // Safe compact while sync is active — should not break anything
        let deleted = local.compactHistory()
        // deleted >= 0 means slots exist; deleted might be 0 if cursor hasn't advanced enough
        #expect(deleted >= 0, "Safe compact should work during active sync")

        // Write more data AFTER compaction
        let task2 = await waitForChange(on: syncedConfig, table: "Memory", operation: .insert, count: 2)
        for i in 4...5 {
            let m = Memory()
            m.content = "post-compact-\(i)"
            m.project = "test"
            try local.add(m)
        }
        try await task2.value

        // Synced side should have only the NEW entries (not re-synced old ones)
        let syncedCount = synced.objects(Memory.self).count
        #expect(syncedCount == 5,
            "Synced should have 5 memories total (3 pre + 2 post), got \(syncedCount) — re-sync storm if > 5")
    }
}
