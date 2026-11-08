import Testing
@testable import EngramKit
import EngramModels
import Lattice
import Foundation
import SQLite3

@Suite("DerivationRestrictionSync", .serialized)
struct DerivationRestrictionSyncTests {
    private func directory() throws -> URL {
        let result = try testFixtureDirectory().appendingPathComponent("restriction-relay-\(UUID())")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
    private func wait(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
    private func store(_ path: URL, target: Lattice.IPCSyncTarget? = nil) throws -> Lattice {
        var config = Lattice.Configuration(fileURL: path, migration: engramMigrations, busyTimeoutMs: 100)
        if var target {
            target.socketPath = try testFixtureDirectory().appendingPathComponent("r-\(target.channel.suffix(12)).sock").path
            #expect(target.socketPath!.utf8.count < 104)
            config.ipcTargets = [target]
        }
        return try Lattice(Memory.self, Edge.self, SyncConfig.self, GroupProjectMap.self, configuration: config)
    }
    private func put(_ db: Lattice, _ name: String, policy: String? = MemoryDerivationPolicy.direct.rawValue,
                     author: UUID? = nil) throws -> UUID {
        let row = Memory(content: name, project: "p", authorUserId: author, derivationPolicy: policy)
        try db.add(row)
        return try #require(row.globalId)
    }
    private func contains(_ db: Lattice, _ name: String) -> Bool { db.objects(Memory.self).contains { $0.content == name } }
    private func policy(_ groups: Set<String> = [], privateValue: Bool = false) throws -> String {
        try #require(MemoryDerivationPolicy.derived(privateFloor: privateValue, groupCeiling: groups)).rawValue
    }
    private func sql(_ path: URL, _ command: String) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let code = sqlite3_exec(db, command, nil, nil, nil)
        guard code == SQLITE_OK else { throw RawWriteLock.Failure.sqlite(code, "synthetic policy SQL") }
    }

    @Test(arguments: ["group", "personal", "group-relay", "author-return"])
    func actualRelayRejectsMissingMalformedPrivateAndWrongAudience(_ mode: String) async throws {
        let path = try directory(), a = UUID(), b = UUID(), author = UUID()
        let seed = try store(path.appendingPathComponent("hub.sqlite"))
        try seed.add(SyncConfig(project: "p", policy: .sync, exposedTeams: [a.uuidString]))
        let direct = try put(seed, "direct", author: author)
        let scoped = try put(seed, "scope-a", policy: policy([a.uuidString]), author: author)
        _ = try put(seed, "scope-b", policy: policy([b.uuidString]), author: author)
        _ = try put(seed, "empty", policy: policy(), author: author)
        _ = try put(seed, "floor", policy: policy(privateValue: true), author: author) // stored isPrivate is deliberately false
        _ = try put(seed, "legacy", policy: nil, author: author)
        _ = try put(seed, "malformed", policy: "engram-policy:1:derived:0:\(a.uuidString),bad", author: author)
        _ = try put(seed, "unknown", policy: "engram-policy:2:direct", author: author)
        _ = try put(seed, "foreign", author: UUID())
        try seed.add(Edge(sourceGlobalId: direct, targetGlobalId: scoped, relation: .relatesTo))
        let legacy = try #require(seed.objects(Memory.self).where { $0.content == "legacy" }.first?.globalId)
        try seed.add(Edge(sourceGlobalId: direct, targetGlobalId: legacy, relation: .relatesTo))
        let filter: Lattice.SyncFilter
        switch mode {
        case "personal": filter = SyncService.buildSyncFilter(from: seed)
        case "group-relay": filter = SyncService.buildGroupRelaySyncFilter(from: seed, groupId: a)
        case "author-return": filter = SyncService.buildSpokeToHubFilter(me: author, from: seed, groupId: a)
        default: filter = SyncService.buildGroupSyncFilter(from: seed, groupId: a)
        }
        let channel = "restriction-\(UUID())"
        let sender = try store(seed.configuration.fileURL, target: .init(channel: channel, syncFilter: filter, narrowingEmitsRemovals: false))
        let receiver = try store(path.appendingPathComponent("receiver.sqlite"), target: .init(channel: channel))
        #expect(await wait { contains(receiver, "direct") && contains(receiver, "scope-a") })
        try await Task.sleep(for: .milliseconds(350))
        for name in ["floor", "legacy", "malformed", "unknown"] { #expect(!contains(receiver, name)) }
        #expect(contains(receiver, "scope-b") == (mode == "personal"))
        #expect(contains(receiver, "empty") == (mode == "personal"))
        #expect(contains(receiver, "foreign") == (mode != "author-return"))
        #expect(receiver.objects(Edge.self).count == (mode == "author-return" ? 0 : 1))
        let copy = try #require(receiver.objects(Memory.self).where { $0.content == "scope-a" }.first)
        #expect(copy.derivationPolicy == (try policy([a.uuidString])))
        withExtendedLifetime(sender) {}
    }

    @Test func latePolicyArrivalRefreshesThenCancellationRetiresChannel() async throws {
        let path = try directory(), a = UUID(), b = UUID()
        let seed = try store(path.appendingPathComponent("hub.sqlite"))
        try seed.add(SyncConfig(project: "p", policy: .local, exposedTeams: [a.uuidString]))
        _ = try put(seed, "initial")
        let channel = SyncService.groupChannel(a)
        let sender = try store(seed.configuration.fileURL, target: .init(channel: channel,
            syncFilter: SyncService.buildGroupSyncFilter(from: seed, groupId: a), narrowingEmitsRemovals: false))
        let receiver = try store(path.appendingPathComponent("receiver.sqlite"), target: .init(channel: channel))
        var observer: SyncService.PolicyObservation? = .init(lattice: sender, relay: .hub(personalChannel: "unused", groupIds: [a]))
        weak var weakObserver = observer
        #expect(await wait { contains(receiver, "initial") && observer?.hasPendingRefresh == false })
        let newID = try put(seed, "late-policy", policy: policy([a.uuidString, b.uuidString]))
        #expect(await wait { contains(receiver, "late-policy") })
        // Changing current policy unmatches an old allowlist immediately.
        let row = try #require(seed.objects(Memory.self).where { $0.globalId == newID }.first)
        row.derivationPolicy = try policy(privateValue: true)
        #expect(await wait { !contains(receiver, "late-policy") })
        observer?.cancel(); observer?.refresh(); observer = nil
        #expect(await wait { weakObserver == nil })
        _ = try put(seed, "after-retirement")
        // Cross the first periodic-retry deadline after cancelling/releasing.
        try await Task.sleep(for: .milliseconds(2500))
        #expect(!contains(receiver, "after-retirement"))
        withExtendedLifetime(sender) {}
    }

    private final class Gate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var first = true
        func run() {
            let block = lock.withLock { if !first { return false }; first = false; return true }
            if block { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        }
        private func blockingWait() -> Bool { entered.wait(timeout: .now() + 5) == .success }
        func waitForEntry() async -> Bool { await Task.detached { self.blockingWait() }.value }
    }
    @Test func delayedRefreshCannotOverwriteNewExposureAndCancelCannotResurrect() async throws {
        let path = try directory(), a = UUID(), b = UUID()
        let seed = try store(path.appendingPathComponent("hub.sqlite"))
        try seed.add(SyncConfig(project: "p", policy: .local, exposedTeams: [a.uuidString]))
        _ = try put(seed, "initial")
        let channel = SyncService.groupChannel(a)
        let sender = try store(seed.configuration.fileURL, target: .init(channel: channel,
            syncFilter: SyncService.buildGroupSyncFilter(from: seed, groupId: a), narrowingEmitsRemovals: false))
        let receiver = try store(path.appendingPathComponent("receiver.sqlite"), target: .init(channel: channel))
        let observer = SyncService.PolicyObservation(lattice: sender, relay: .hub(personalChannel: "unused", groupIds: [a]))
        defer { observer.cancel() }
        #expect(await wait { contains(receiver, "initial") && !observer.hasPendingRefresh })
        let gate = Gate(); observer.beforeInstall = { gate.run() }
        _ = try put(seed, "delayed", policy: policy([a.uuidString, b.uuidString]))
        #expect(await gate.waitForEntry())
        let exposure = try #require(seed.objects(SyncConfig.self).first)
        exposure.exposedGroups = []
        observer.refresh()
        gate.release.signal()
        #expect(await wait { !observer.hasPendingRefresh })
        #expect(!contains(receiver, "delayed"))
        observer.beforeInstall = nil
        exposure.exposedGroups = [a.uuidString]
        #expect(await wait { contains(receiver, "delayed") })
        let cancelGate = Gate(); observer.beforeInstall = { cancelGate.run() }
        observer.refresh()
        #expect(await cancelGate.waitForEntry())
        observer.cancel(); cancelGate.release.signal()
        _ = try put(seed, "cancelled-pending")
        try await Task.sleep(for: .milliseconds(350))
        #expect(!contains(receiver, "cancelled-pending"))
        withExtendedLifetime(sender) {}
    }

    // The existing Gate stays unchanged for every other test. This copy only
    // records the result of the same one-shot five-second semaphore wait.
    private final class RefreshTraceGate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var first = true
        private var recordedOutcome: UInt64 = 0
        var outcome: UInt64 { lock.withLock { recordedOutcome } }
        func run() {
            let block = lock.withLock { if !first { return false }; first = false; return true }
            if block {
                entered.signal()
                let result = release.wait(timeout: .now() + 5)
                lock.withLock { recordedOutcome = result == .success ? 1 : 2 }
            }
        }
        private func blockingWait() -> Bool { entered.wait(timeout: .now() + 5) == .success }
        func waitForEntry() async -> Bool { await Task.detached { self.blockingWait() }.value }
    }

    // Counts visits after the first read and early denial, not drain starts.
    // The counter lock never encloses an observer read or the one-shot gate.
    private final class RefreshTraceHookEntries: @unchecked Sendable {
        private let lock = NSLock()
        private var count: UInt64 = 0
        private var overflow = false
        func record() {
            lock.withLock {
                if count < 65_535 { count += 1 } else { overflow = true }
            }
        }
        var sample: (count: UInt64, overflow: Bool) { lock.withLock { (count, overflow) } }
    }

    @Test func readFailureAndCatalogOverflowDenyInsteadOfRetainingAnAllowlist() async throws {
        let path = try directory(), a = UUID()
        let seed = try store(path.appendingPathComponent("hub.sqlite"))
        try seed.add(SyncConfig(project: "p", policy: .local, exposedTeams: [a.uuidString]))
        _ = try put(seed, "initial")
        let channel = SyncService.groupChannel(a)
        let sender = try store(seed.configuration.fileURL, target: .init(channel: channel,
            syncFilter: SyncService.buildGroupSyncFilter(from: seed, groupId: a), narrowingEmitsRemovals: false))
        let receiver = try store(path.appendingPathComponent("receiver.sqlite"), target: .init(channel: channel))
        let observer = SyncService.PolicyObservation(lattice: sender, relay: .hub(personalChannel: "unused", groupIds: [a]))
        // One bounded numeric trace, emitted after the original cancellation.
        // V2 rows retain the first eight fields: phase, event, elapsed ms,
        // polls, result, pending, gate, wait ms. Appended fields: generation,
        // reconcile, backoff step, hook entries after first read, hook overflow.
        // Observer state is locked together; counter/gate/time are separate samples.
        let traceStart = DispatchTime.now().uptimeNanoseconds
        var tracePhase: UInt64 = 0
        var traceRows: [[UInt64]] = []
        var traceOverflow = false
        var traceGate: RefreshTraceGate?
        let traceHookEntries = RefreshTraceHookEntries()
        func elapsedMilliseconds(_ start: UInt64) -> UInt64 {
            min((DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000, 3_600_000)
        }
        func recordTrace(_ event: UInt64, polls: UInt64 = 0, result: Bool = false, waitMilliseconds: UInt64 = 0) {
            guard traceRows.count < 32 else { traceOverflow = true; return }
            let elapsed = elapsedMilliseconds(traceStart)
            let state = observer.refreshTraceState
            let gateOutcome = traceGate?.outcome ?? 0
            let hookEntriesAfterFirstRead = traceHookEntries.sample
            traceRows.append([tracePhase, event, elapsed, polls,
                              result ? 1 : 0, state.scheduled ? 1 : 0,
                              gateOutcome, waitMilliseconds, state.generation,
                              state.reconcile ? 1 : 0, UInt64(state.backoffStep),
                              hookEntriesAfterFirstRead.count, hookEntriesAfterFirstRead.overflow ? 1 : 0])
        }
        func beginTrace(_ phase: UInt64) { tracePhase = phase; recordTrace(1) }
        func wait(_ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(10)
            let started = DispatchTime.now().uptimeNanoseconds
            var polls: UInt64 = 0
            var result = false
            defer { recordTrace(2, polls: polls, result: result, waitMilliseconds: elapsedMilliseconds(started)) }
            while Date() < deadline {
                polls = min(polls + 1, 65_535)
                if condition() { result = true; return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            polls = min(polls + 1, 65_535)
            result = condition()
            return result
        }
        defer {
            recordTrace(3)
            print("RESTRICTION_REFRESH_TRACE_V2 overflow=\(traceOverflow) rows=\(traceRows)")
        }
        defer { observer.cancel() }
        beginTrace(1)
        #expect(await wait { contains(receiver, "initial") && !observer.hasPendingRefresh })
        beginTrace(2)
        try sql(seed.configuration.fileURL, "ALTER TABLE SyncConfig RENAME TO HeldSyncConfig")
        #expect(SyncService.buildGroupSyncFilter(from: seed, groupId: a) == SyncService.denyPolicyFilter())
        observer.refresh()
        beginTrace(3)
        #expect(await wait { !observer.hasPendingRefresh })
        beginTrace(4)
        _ = try put(seed, "during-read-failure")
        try await Task.sleep(for: .milliseconds(300))
        #expect(!contains(receiver, "during-read-failure"))
        beginTrace(5)
        try sql(seed.configuration.fileURL, "ALTER TABLE HeldSyncConfig RENAME TO SyncConfig")
        observer.refresh()
        beginTrace(6)
        #expect(await wait { contains(receiver, "during-read-failure") })
        // Hold an older successful read across the overflow. Its eventual
        // completion must not reinstall that old permissive policy catalog.
        beginTrace(7)
        let staleSuccess = RefreshTraceGate(); traceGate = staleSuccess
        observer.beforeInstall = {
            traceHookEntries.record()
            staleSuccess.run()
        }
        observer.refresh()
        #expect(await staleSuccess.waitForEntry())
        beginTrace(8)
        try LatticeBeginRetry.run(on: seed) {
            for index in 0...SyncService.maximumPolicyValues {
                _ = try put(seed, "overflow-\(index)", policy: "unknown-\(index)")
            }
        }
        beginTrace(9)
        #expect(SyncService.buildGroupSyncFilter(from: seed, groupId: a) == SyncService.denyPolicyFilter())
        observer.refresh()
        staleSuccess.release.signal()
        // Keep a counter-only continuation after the original one-shot release.
        observer.beforeInstall = { traceHookEntries.record() }
        beginTrace(10)
        #expect(await wait { !observer.hasPendingRefresh })
        beginTrace(11)
        _ = try put(seed, "during-overflow")
        try await Task.sleep(for: .milliseconds(300))
        #expect(!contains(receiver, "during-overflow"))
        beginTrace(12)
        seed.delete(Memory.self, where: { $0.content.hasPrefix("overflow-") })
        observer.refresh()
        beginTrace(13)
        let recovered = await wait { contains(receiver, "during-overflow") }
        if !recovered {
            print("RESTRICTION_RECOVERY pending=\(observer.hasPendingRefresh) currentDenies=\(SyncService.buildGroupSyncFilter(from: seed, groupId: a) == SyncService.denyPolicyFilter()) rows=\(seed.objects(Memory.self).count) received=\(receiver.objects(Memory.self).count)")
        }
        #expect(recovered)
        beginTrace(14)
        withExtendedLifetime(sender) {}
    }
    @Test func stableReadFailureRecoversWithoutAnotherNotificationAndDelayedReadCannotUndoIt() async throws {
        let path = try directory(), a = UUID()
        let seed = try store(path.appendingPathComponent("hub.sqlite"))
        try seed.add(SyncConfig(project: "p", policy: .local, exposedTeams: [a.uuidString]))
        _ = try put(seed, "silent-recovery")
        let channel = SyncService.groupChannel(a)
        let sender = try store(seed.configuration.fileURL, target: .init(channel: channel,
            syncFilter: SyncService.denyPolicyFilter(), narrowingEmitsRemovals: false))
        let receiver = try store(path.appendingPathComponent("receiver.sqlite"), target: .init(channel: channel))
        try sql(seed.configuration.fileURL, "ALTER TABLE SyncConfig RENAME TO HeldSyncConfig")
        // Register after all model writes, so no queued write notification can
        // accidentally wake this observer after the raw schema is restored.
        let observer = SyncService.PolicyObservation(lattice: sender, relay: .hub(personalChannel: "unused", groupIds: [a]))
        defer { observer.cancel() }
        #expect(await wait { !observer.hasPendingRefresh })
        #expect(!contains(receiver, "silent-recovery"))
        try sql(seed.configuration.fileURL, "ALTER TABLE HeldSyncConfig RENAME TO SyncConfig")
        // Raw schema restoration emits no Lattice Memory/SyncConfig event.
        // There is deliberately no refresh(), write, or reopened handle here.
        let recovered = await wait { contains(receiver, "silent-recovery") }
        print("RESTRICTION_SILENT_RECOVERY recovered=\(recovered) pending=\(observer.hasPendingRefresh)")
        #expect(recovered)

        // Hold an older denied read over the next recovery. Once released it
        // must validate the latest schema and cannot leave an old denial stuck.
        try sql(seed.configuration.fileURL, "ALTER TABLE SyncConfig RENAME TO HeldSyncConfig")
        observer.refresh()
        #expect(await wait { !observer.hasPendingRefresh })
        try await Task.sleep(for: .milliseconds(300))
        _ = try put(seed, "delayed-silent-recovery")
        observer.refresh()
        #expect(await wait { !observer.hasPendingRefresh })
        #expect(!contains(receiver, "delayed-silent-recovery"))
        let oldRead = Gate(); observer.beforeInstall = { oldRead.run() }
        observer.refresh()
        #expect(await oldRead.waitForEntry())
        try sql(seed.configuration.fileURL, "ALTER TABLE HeldSyncConfig RENAME TO SyncConfig")
        oldRead.release.signal()
        observer.beforeInstall = nil
        #expect(await wait { contains(receiver, "delayed-silent-recovery") && !observer.hasPendingRefresh })
        withExtendedLifetime(sender) {}
    }

    @Test func failedReconciliationRecoversAfterWriterReleaseWithoutAnotherMutation() async throws {
        let path = try directory(), a = UUID()
        let seed = try store(path.appendingPathComponent("hub.sqlite"))
        try seed.add(SyncConfig(project: "p", policy: .local, exposedTeams: [a.uuidString]))
        _ = try put(seed, "queued-before-writer")
        let channel = SyncService.groupChannel(a)
        let sender = try store(seed.configuration.fileURL, target: .init(channel: channel,
            syncFilter: SyncService.denyPolicyFilter(), narrowingEmitsRemovals: false))
        let receiver = try store(path.appendingPathComponent("receiver.sqlite"), target: .init(channel: channel))
        try await Task.sleep(for: .milliseconds(300))
        #expect(!contains(receiver, "queued-before-writer"))
        let writer = try RawWriteLock(path: seed.configuration.fileURL.path)
        try writer.acquire()
        defer { writer.release() }
        let observer = SyncService.PolicyObservation(lattice: sender, relay: .hub(personalChannel: "unused", groupIds: [a]))
        defer { observer.cancel() }
        // Policy reads can succeed in WAL mode while reconciliation's writes
        // encounter the real held SQLite writer. No model mutation follows it.
        #expect(await wait { !observer.hasPendingRefresh })
        // Enqueue completion is not native completion. Keep the writer held
        // beyond the configured 100ms busy wait so the queued native job runs.
        try await Task.sleep(for: .seconds(1))
        #expect(!contains(receiver, "queued-before-writer"))
        writer.release()
        let recovered = await wait { contains(receiver, "queued-before-writer") }
        print("RESTRICTION_RECONCILE_RECOVERY recovered=\(recovered) pending=\(observer.hasPendingRefresh)")
        #expect(recovered)
        withExtendedLifetime(sender) {}
    }

    @Test func ordinaryNotificationsDoNotResetReconciliationBackoff() async throws {
        let path = try directory(), a = UUID()
        let seed = try store(path.appendingPathComponent("hub.sqlite"))
        try seed.add(SyncConfig(project: "p", policy: .local, exposedTeams: [a.uuidString]))
        let id = try put(seed, "initial")
        let channel = SyncService.groupChannel(a)
        let sender = try store(seed.configuration.fileURL, target: .init(channel: channel,
            syncFilter: SyncService.buildGroupSyncFilter(from: seed, groupId: a), narrowingEmitsRemovals: false))
        let receiver = try store(path.appendingPathComponent("receiver.sqlite"), target: .init(channel: channel))
        let observer = SyncService.PolicyObservation(lattice: sender, relay: .hub(personalChannel: "unused", groupIds: [a]))
        defer { observer.cancel() }
        #expect(await wait { contains(receiver, "initial") && observer.reconciliationBackoffStep == 2 && !observer.hasPendingRefresh })
        let row = try #require(seed.objects(Memory.self).where { $0.globalId == id }.first)
        row.content = "ordinary edit, same policy"
        observer.refresh()
        #expect(await wait { contains(receiver, "ordinary edit, same policy") && !observer.hasPendingRefresh })
        #expect(observer.reconciliationBackoffStep >= 2)
        let exposure = try #require(seed.objects(SyncConfig.self).first)
        exposure.exposedGroups = []
        observer.refresh()
        #expect(await wait { !observer.hasPendingRefresh && observer.reconciliationBackoffStep == 1 })
        withExtendedLifetime(sender) {}
    }

    @Test func storeRetirementCancelsRetryAndRestorationCannotResurrectIt() async throws {
        let path = try directory(), a = UUID()
        let url = path.appendingPathComponent("hub.sqlite")
        let retired = path.appendingPathComponent("hub.retired.sqlite")
        let seed = try store(url)
        try seed.add(SyncConfig(project: "p", policy: .local, exposedTeams: [a.uuidString]))
        _ = try put(seed, "initial")
        let channel = SyncService.groupChannel(a)
        let sender = try store(url, target: .init(channel: channel,
            syncFilter: SyncService.buildGroupSyncFilter(from: seed, groupId: a), narrowingEmitsRemovals: false))
        let receiver = try store(path.appendingPathComponent("receiver.sqlite"), target: .init(channel: channel))
        let observer = SyncService.PolicyObservation(lattice: sender, relay: .hub(personalChannel: "unused", groupIds: [a]))
        defer { observer.cancel() }
        #expect(await wait { contains(receiver, "initial") && !observer.hasPendingRefresh })
        let retiredRead = Gate(); observer.beforeInstall = { retiredRead.run() }
        try FileManager.default.moveItem(at: url, to: retired)
        observer.refresh()
        #expect(await wait { !observer.hasPendingRefresh })
        try FileManager.default.moveItem(at: retired, to: url)
        // Do not write through a SQLite handle whose backing file was moved:
        // pinned Lattice may invalidate its schema-registration state. Instead
        // prove the observer never reads/reenqueues again after restoration.
        observer.refresh()
        try await Task.sleep(for: .milliseconds(2500))
        #expect(retiredRead.lock.withLock { retiredRead.first })
        #expect(!observer.hasPendingRefresh)
        withExtendedLifetime(sender) {}
    }

    @Test(arguments: [false, true])
    func minimalOwnedSchemasDenyEveryTableWithoutQueryingAbsentModels(_ group: Bool) async throws {
        let path = try directory(), channel = "minimal-\(UUID())"
        let socket = try testFixtureDirectory().appendingPathComponent("r-\(channel.suffix(12)).sock").path
        #expect(socket.utf8.count < 104)
        let models: [any Model.Type] = group
            ? [Memory.self, Edge.self, GroupProjectMap.self]
            : [Memory.self, Edge.self, Checkpoint.self, HookState.self, SessionState.self, SyncConfig.self]
        var sourceConfig = Lattice.Configuration(fileURL: path.appendingPathComponent("hub.sqlite"), busyTimeoutMs: 100)
        sourceConfig.ipcTargets = [.init(channel: channel, syncFilter: SyncService.denyPolicyFilter(), socketPath: socket)]
        let source = try Lattice(for: models, configuration: sourceConfig)
        var receiverConfig = Lattice.Configuration(fileURL: path.appendingPathComponent("receiver.sqlite"), busyTimeoutMs: 100)
        receiverConfig.ipcTargets = [.init(channel: channel, socketPath: socket)]
        let receiver = try Lattice(for: models, configuration: receiverConfig)
        func populate(_ prefix: String) throws {
            let a = try put(source, prefix + "-a"), b = try put(source, prefix + "-b")
            try source.add(Edge(sourceGlobalId: a, targetGlobalId: b, relation: .relatesTo))
            if group {
                try source.add(GroupProjectMap(memberUserId: UUID(), localProject: prefix, groupProject: prefix))
            } else {
                try source.add(SyncConfig(project: prefix, policy: .sync))
                try source.add(Checkpoint(title: prefix))
                try source.add(HookState(key: .maintenanceActive, value: prefix))
                try source.add(SessionState(sessionId: prefix))
            }
        }
        try populate("denied")
        _ = try put(receiver, "reverse-control")
        // Reverse transport proves the actual connection is established while
        // the tested source side remains denied, rather than merely offline.
        #expect(await wait { contains(source, "reverse-control") })
        source.updateSyncFilter(SyncService.denyPolicyFilter(), forChannel: channel)
        try populate("also-denied")
        try await Task.sleep(for: .milliseconds(500))
        #expect(receiver.objects(Memory.self).count == 1)
        #expect(receiver.objects(Edge.self).count == 0)
        if group {
            #expect(receiver.objects(GroupProjectMap.self).count == 0)
        } else {
            #expect(receiver.objects(SyncConfig.self).count == 0)
            #expect(receiver.objects(Checkpoint.self).count == 0)
            #expect(receiver.objects(HookState.self).count == 0)
            #expect(receiver.objects(SessionState.self).count == 0)
        }
        source.updateSyncFilter(nil, forChannel: channel)
        try populate("positive")
        #expect(await wait {
            guard contains(receiver, "positive-a"), receiver.objects(Edge.self).count > 0 else { return false }
            if group { return receiver.objects(GroupProjectMap.self).count > 0 }
            return receiver.objects(SyncConfig.self).count > 0 && receiver.objects(Checkpoint.self).count > 0
                && receiver.objects(HookState.self).count > 0 && receiver.objects(SessionState.self).count > 0
        })
        withExtendedLifetime(source) {}
    }

}
