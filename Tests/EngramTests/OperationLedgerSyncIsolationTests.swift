import EngramMemoryCore
import EngramModels
import Foundation
import Lattice
import Testing
@testable import EngramKit

/// Exercise the production upload filters against real IPC. Registering the
/// ledger on the receiving test handle is intentional: an omitted production
/// model must not make accidental export invisible to the test.
@Suite("Operation ledger sync isolation", .serialized)
struct OperationLedgerSyncIsolationTests {
    enum Route: String, CaseIterable, Sendable {
        case personalHub, groupHub, personalRelay, groupRelay, spokeToHub
        case unfilteredControl

        func filter(from source: Lattice, groupID: UUID, authorID: UUID) -> Lattice.SyncFilter? {
            switch self {
            case .personalHub: SyncService.buildSyncFilter(from: source)
            case .groupHub: SyncService.buildGroupSyncFilter(from: source, groupId: groupID)
            case .personalRelay: SyncService.buildPersonalRelaySyncFilter()
            case .groupRelay: SyncService.buildGroupRelaySyncFilter()
            case .spokeToHub: SyncService.buildSpokeToHubFilter(me: authorID)
            case .unfilteredControl: nil
            }
        }
    }

    private var fixtureModels: [any Model.Type] {
        [Memory.self, Edge.self, SyncConfig.self, GroupProjectMap.self]
            + MemoryOperationLedger.localModels
    }

    private func waitForMemory(_ id: UUID, in lattice: Lattice) async -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if lattice.objects(Memory.self).where({ $0.globalId == id }).first != nil { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return lattice.objects(Memory.self).where({ $0.globalId == id }).first != nil
    }

    private func ledgerCounts(in lattice: Lattice) throws -> (stores: Int, receipts: Int) {
        let stores = lattice.objects(EngramOperationStoreV1.self).count
        try #require(lattice.lastQueryError() == nil, "Store count query failed")
        let receipts = lattice.objects(EngramOperationReceiptV1.self).count
        try #require(lattice.lastQueryError() == nil, "Receipt count query failed")
        return (stores, receipts)
    }

    private func waitForAcknowledgements(_ source: Lattice, _ target: Lattice) async -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if source.pendingSyncEntryCount == 0 && target.pendingSyncEntryCount == 0 { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return source.pendingSyncEntryCount == 0 && target.pendingSyncEntryCount == 0
    }

    /// The memory and real receipt commit together, followed by a later audit
    /// row. Observing that later row is the relay's positive progress control.
    private func seedOperation(in source: Lattice, authorID: UUID) throws -> UUID {
        let ledger = MemoryOperationLedger(lattice: source)
        try ledger.bootstrapStoreID()
        let principal = Principal(id: authorID, kind: .user)
        let scope = try ledger.scope(principal: principal)
        let provenance = try MemoryOperationProvenance(
            host: "sync-isolation-test", sessionID: "fixture", runID: UUID().uuidString,
            source: MemoryOperationSourceInterval(
                startOffset: 1, endOffset: 2,
                excerptDigest: MemoryOperationDigest(sha256: String(repeating: "a", count: 64))))
        let prepared = try MemoryOperationCanonicalPayload.prepare(MemoryOperationRequest(
            operationID: UUID(), expectedScope: scope, provenance: provenance,
            mutation: .remember(RememberRequest(content: "shared fixture", topic: "testing", project: "shared"))))
        let memory = Memory(content: "shared fixture", topic: "testing", project: "shared",
                            authorUserId: authorID)
        let commit = try ledger.withOperation(prepared, principal: { principal }) {
            try source.add(memory)
            return .init(outcome: .applied, memoryIDs: [try #require(memory.globalId)])
        }
        #expect(!commit.isReplay)
        let barrier = Memory(content: "after receipt", topic: "testing", project: "shared",
                             authorUserId: authorID)
        try source.add(barrier)
        return try #require(barrier.globalId)
    }

    @Test(.timeLimit(.minutes(1)), arguments: Route.allCases)
    func productionFiltersExcludeEvidenceWhileUnfilteredControlExportsIt(_ route: Route) async throws {
        let directory = try testFixtureDirectory().appending(path: "lsi-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appending(path: "source.sqlite")
        let targetURL = directory.appending(path: "target.sqlite")
        let socket = directory.appending(path: "ipc.sock").path
        // Keep every runtime artifact in the configured fixture directory,
        // including the socket (whose Darwin sockaddr path is bounded).
        try #require(socket.utf8.count < 104, "Choose a shorter ENGRAM_TEST_ROOT for IPC fixtures")
        defer {
            try? Lattice.delete(for: .init(fileURL: sourceURL))
            try? Lattice.delete(for: .init(fileURL: targetURL))
            try? FileManager.default.removeItem(at: directory)
        }

        try MemoryOperationLedger.preflightLocalStore(at: sourceURL)
        try MemoryOperationLedger.preflightLocalStore(at: targetURL)
        let source = try Lattice(for: fixtureModels,
                                 configuration: .init(fileURL: sourceURL, busyTimeoutMs: 100))
        let groupID = UUID(), authorID = UUID()
        try source.add(SyncConfig(project: "shared", policy: .sync,
                                  exposedTeams: [groupID.uuidString]))
        let firstBarrier = try seedOperation(in: source, authorID: authorID)
        let channel = "ledger-\(UUID().uuidString.prefix(8))"
        var sourceConfig = Lattice.Configuration(fileURL: sourceURL, busyTimeoutMs: 100)
        sourceConfig.ipcTargets = [.init(
            channel: channel,
            syncFilter: route.filter(from: source, groupID: groupID, authorID: authorID),
            socketPath: socket, narrowingEmitsRemovals: false)]
        try MemoryOperationLedger.preflightLocalStore(at: sourceURL)
        let sourceRelay = try Lattice(for: fixtureModels, configuration: sourceConfig)
        var targetConfig = Lattice.Configuration(fileURL: targetURL, busyTimeoutMs: 100)
        targetConfig.ipcTargets = [.init(
            channel: channel, syncFilter: SyncService.buildPersonalRelaySyncFilter(),
            socketPath: socket, narrowingEmitsRemovals: false)]
        let target = try Lattice(for: fixtureModels, configuration: targetConfig)

        try #require(await waitForMemory(firstBarrier, in: target), "Startup relay positive control failed")
        try #require(await waitForAcknowledgements(sourceRelay, target), "Startup relay did not drain")
        // The unfiltered control must actually export the evidence; otherwise
        // zero rows on the filtered routes could merely mean that this fixture
        // never exercised export of the ledger's tables.
        let expectedStoreCount = route == .unfilteredControl ? 1 : 0
        let firstTargetCounts = try ledgerCounts(in: target)
        #expect(firstTargetCounts.stores == expectedStoreCount)
        #expect(firstTargetCounts.receipts == expectedStoreCount)
        #expect(try ledgerCounts(in: source).receipts == 1)

        sourceRelay.updateSyncFilter(
            route.filter(from: source, groupID: groupID, authorID: authorID), forChannel: channel)
        let secondBarrier = try seedOperation(in: source, authorID: authorID)
        try #require(await waitForMemory(secondBarrier, in: target), "Refreshed relay positive control failed")
        try #require(await waitForAcknowledgements(sourceRelay, target), "Refreshed relay did not drain")
        let secondTargetCounts = try ledgerCounts(in: target)
        #expect(secondTargetCounts.stores == expectedStoreCount)
        #expect(secondTargetCounts.receipts == expectedStoreCount * 2)
        let sourceCounts = try ledgerCounts(in: source)
        #expect(sourceCounts.stores == 1)
        #expect(sourceCounts.receipts == 2)
    }
}
