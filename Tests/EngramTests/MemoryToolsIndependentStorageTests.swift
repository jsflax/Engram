@testable import EngramKit
@testable import Lattice
import EngramMemoryCore
import EngramModels
import Foundation
import MCP
import Testing

private struct ActorStorageSnapshot: Equatable, Sendable {
    let local: Int64
    let synced: Int64?
    let groups: [UUID: Int64]
    let localCount: Int
    let syncedCount: Int?
    let groupCounts: [UUID: Int]
    let liveGroups: Set<UUID>
}

private final class ActorStorageWeakBackend: @unchecked Sendable {
    weak var value: (any LatticeBackend)?
    init(_ value: any LatticeBackend) { self.value = value }
}

private final class ActorStorageLifetimeProbe: @unchecked Sendable {
    weak var tools: MemoryTools?
    let backends: [ActorStorageWeakBackend]
    init(tools: MemoryTools, backends: [ActorStorageWeakBackend]) {
        self.tools = tools
        self.backends = backends
    }
}

private extension MemoryTools {
    func actorStorageSnapshot() -> ActorStorageSnapshot {
        ActorStorageSnapshot(
            local: localLattice.backend.identityHash,
            synced: syncedLattice?.backend.identityHash,
            groups: Dictionary(uniqueKeysWithValues: groupSpokes.map { ($0.groupId, $0.lattice.backend.identityHash) }),
            localCount: localLattice.objects(Memory.self).count,
            syncedCount: syncedLattice?.objects(Memory.self).count,
            groupCounts: Dictionary(uniqueKeysWithValues: groupSpokes.map { ($0.groupId, $0.lattice.objects(Memory.self).count) }),
            liveGroups: Set(liveGroupSpokes().map(\.groupId)))
    }

    func actorStorageLifetimeProbe() -> ActorStorageLifetimeProbe {
        let databases = [localLattice] + (syncedLattice.map { [$0] } ?? []) + groupSpokes.map(\.lattice)
        return ActorStorageLifetimeProbe(tools: self, backends: databases.map { ActorStorageWeakBackend($0.backend) })
    }

    func closeActorStorageFixture() {
        localLattice.close()
        syncedLattice?.close()
        for spoke in groupSpokes { spoke.lattice.close() }
    }
}

@Suite("MemoryTools independent storage", .serialized)
struct MemoryToolsIndependentStorageTests {
    private struct UnusedEmbedder: Embedder {
        let dimension = 384
        func embed(text: String) async throws -> [Float]? { nil }
    }

    private struct Fixture {
        let directory: URL
        let local: Lattice
        let synced: Lattice?
        let groups: [(id: UUID, path: URL, lattice: Lattice)]

        func tools() -> MemoryTools {
            MemoryTools(localRef: local.sendableReference,
                        syncedRef: synced?.sendableReference,
                        groupRefs: groups.map {
                            MemoryTools.GroupSpokeRef(groupId: $0.id, path: $0.path.path,
                                                      ref: $0.lattice.sendableReference)
                        },
                        embedder: UnusedEmbedder(),
                        identity: StaticIdentityProvider(.anonymous),
                        enableLocalMutationOperations: true)
        }

        func close() {
            local.close()
            synced?.close()
            for group in groups { group.lattice.close() }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func fixture(optionalStores: Bool) throws -> Fixture {
        let root = ProcessInfo.processInfo.environment["ENGRAM_ADOPTION_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let directory = root
            .appendingPathComponent("actor-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func config(_ name: String) -> Lattice.Configuration {
            var value = Lattice.Configuration(fileURL: directory.appendingPathComponent(name), migration: engramMigrations)
            value.busyTimeoutMs = 100
            return value
        }
        let localPath = directory.appendingPathComponent("memory.sqlite")
        try MemoryOperationLedger.preflightLocalStore(at: localPath)
        let local = try Lattice(
            for: [Memory.self, Edge.self, Checkpoint.self, HookState.self, SessionState.self, SyncConfig.self]
                + MemoryOperationLedger.localModels,
            configuration: config("memory.sqlite"))
        try MemoryOperationLedger(lattice: local).bootstrapStoreID()
        guard optionalStores else { return Fixture(directory: directory, local: local, synced: nil, groups: []) }
        let synced = try Lattice(Memory.self, Edge.self, SyncConfig.self,
                                 configuration: config("memory-synced.sqlite"))
        let sharedVector = Vector<Float>([1] + [Float](repeating: 0, count: 383))
        try synced.add(Memory(content: "synthetic synced fixture", topic: "fixture", project: "ActorStorage",
                              embedding: sharedVector))
        var groups: [(id: UUID, path: URL, lattice: Lattice)] = []
        for index in 0..<2 {
            let id = UUID(), name = "group-\(index).sqlite"
            let group = try Lattice(Memory.self, Edge.self, GroupProjectMap.self, configuration: config(name))
            try group.add(Memory(content: "synthetic group fixture \(index)", topic: "fixture", project: "ActorStorage",
                                 embedding: sharedVector))
            groups.append((id, directory.appendingPathComponent(name), group))
        }
        return Fixture(directory: directory, local: local, synced: synced, groups: groups)
    }

    @Test func writerIsDistinctFromDetachedReferenceAndOtherToolsActor() async throws {
        let fixture = try fixture(optionalStores: false)
        defer { fixture.close() }
        let first = fixture.tools(), second = fixture.tools()
        var firstPrepared = false, secondPrepared = false
        do {
            try await first.prepareStorage()
            firstPrepared = true
            try await second.prepareStorage()
            secondPrepared = true
            let firstSnapshot = await first.actorStorageSnapshot()
            let firstAgain = await first.actorStorageSnapshot()
            let secondSnapshot = await second.actorStorageSnapshot()
            let reference = fixture.local.sendableReference
            let backgroundIdentity = try await Task.detached(priority: .background) {
                let background = try #require(reference.resolve())
                return background.backend.identityHash
            }.value
            #expect(firstSnapshot.local != backgroundIdentity)
            #expect(secondSnapshot.local != backgroundIdentity)
            #expect(firstSnapshot.local != secondSnapshot.local)
            #expect(firstSnapshot == firstAgain)
            #expect(firstSnapshot.localCount == 0)
            #expect(firstSnapshot.synced == nil && firstSnapshot.groups.isEmpty)
            await first.closeActorStorageFixture()
            await second.closeActorStorageFixture()
        } catch {
            if firstPrepared { await first.closeActorStorageFixture() }
            if secondPrepared { await second.closeActorStorageFixture() }
            throw error
        }
    }

    @Test func optionalHandlesRemainActorLocalCachedAndMembershipChecked() async throws {
        let fixture = try fixture(optionalStores: true)
        defer { fixture.close() }
        let first = fixture.tools(), second = fixture.tools()
        var firstPrepared = false, secondPrepared = false
        do {
            try await first.prepareStorage()
            firstPrepared = true
            try await second.prepareStorage()
            secondPrepared = true
            let before = await first.actorStorageSnapshot()
            let other = await second.actorStorageSnapshot()
            #expect(before.synced != fixture.synced?.backend.identityHash)
            #expect(before.synced != other.synced)
            #expect(before.groups.count == 2 && before.liveGroups.count == 2)
            #expect(before.localCount == 0 && before.syncedCount == 1)
            for group in fixture.groups {
                #expect(before.groups[group.id] != group.lattice.backend.identityHash)
                #expect(before.groups[group.id] != other.groups[group.id])
                #expect(before.groupCounts[group.id] == 1)
            }
            #expect(await first.actorStorageSnapshot() == before)
            let revoked = try #require(fixture.groups.first)
            let revokedPath = revoked.path.appendingPathExtension("revoked")
            try FileManager.default.moveItem(at: revoked.path, to: revokedPath)
            let whileRevoked = await first.actorStorageSnapshot()
            #expect(!whileRevoked.liveGroups.contains(revoked.id))
            #expect(whileRevoked.groups == before.groups, "Revocation filters reads without reopening cached handles")
            try FileManager.default.moveItem(at: revokedPath, to: revoked.path)
            #expect(await first.actorStorageSnapshot() == before)
            await first.closeActorStorageFixture()
            await second.closeActorStorageFixture()
        } catch {
            if firstPrepared { await first.closeActorStorageFixture() }
            if secondPrepared { await second.closeActorStorageFixture() }
            throw error
        }
    }

    @Test func preparedActorAndIndependentBackendsReleaseWithoutExplicitClose() async throws {
        let fixture = try fixture(optionalStores: true)
        defer { fixture.close() }
        func prepareAndRelease() async throws -> ActorStorageLifetimeProbe {
            let tools = fixture.tools()
            try await tools.prepareStorage()
            return await tools.actorStorageLifetimeProbe()
        }
        let probe = try await prepareAndRelease()
        #expect(probe.backends.count == 4)
        #expect(probe.tools == nil, "Storage must not retain its owning actor")
        #expect(probe.backends.allSatisfy { $0.value == nil }, "Weak caches must not retain independent backends")
    }

    @Test func missingOptionalStoresAreSkippedBeforePreparation() async throws {
        let fixture = try fixture(optionalStores: true)
        defer { fixture.close() }
        let tools = fixture.tools()
        let synced = try #require(fixture.synced)
        synced.close()
        try Lattice.delete(for: synced.configuration)
        let missing = try #require(fixture.groups.first)
        missing.lattice.close()
        try Lattice.delete(for: missing.lattice.configuration)
        try await tools.prepareStorage()
        let snapshot = await tools.actorStorageSnapshot()
        #expect(snapshot.synced == nil)
        #expect(snapshot.groups.count == 1)
        #expect(snapshot.groups[missing.id] == nil)
        #expect(!FileManager.default.fileExists(atPath: synced.configuration.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: missing.path.path))
        await tools.closeActorStorageFixture()
    }

    @Test func failedPreparationDoesNotCachePartialBundle() async throws {
        let fixture = try fixture(optionalStores: true)
        defer { fixture.close() }
        let tools = fixture.tools()
        let blocked = try #require(fixture.groups.first)
        blocked.lattice.close()
        let backup = blocked.path.appendingPathExtension("fixture-backup")
        try FileManager.default.moveItem(at: blocked.path, to: backup)
        try FileManager.default.createDirectory(at: blocked.path, withIntermediateDirectories: true)
        // Local and synced opens precede this group's failure.
        await #expect(throws: (any Error).self) { try await tools.prepareStorage() }
        await #expect(throws: MemoryOperationError.storageUnavailable) { try await tools.operationScope() }
        let failedOperation = try await tools.handle(CallTool.Parameters(name: "operation_scope", arguments: [:]))
        #expect(failedOperation.isError == true)
        #expect(MemoryTools.text(from: failedOperation).contains("storage_unavailable"))
        // The operation transport still validates requests before touching
        // storage and emits its structured error rather than throwing.
        let invalidOperation = try await tools.handle(CallTool.Parameters(name: "operation_scope", arguments: [
            "unexpected": .bool(true),
        ]))
        #expect(invalidOperation.isError == true)
        #expect(MemoryTools.text(from: invalidOperation).contains("invalid_request"))
        try FileManager.default.removeItem(at: blocked.path)
        try FileManager.default.moveItem(at: backup, to: blocked.path)

        // Replace the disposable local store after failure. A cached partial
        // bundle would keep using the old connection and miss the new row.
        let localConfig = fixture.local.configuration
        var retainedLocalIdentities: [Int64] = []
        try Lattice._delete(for: localConfig) { backend in
            retainedLocalIdentities.append(backend.identityHash)
            backend.close()
        }
        #expect(retainedLocalIdentities == [fixture.local.backend.identityHash],
                "Only the original fixture backend may remain after the partial bundle failed")
        let replacement = try Lattice(
            for: [Memory.self, Edge.self, Checkpoint.self, HookState.self, SessionState.self, SyncConfig.self]
                + MemoryOperationLedger.localModels,
            configuration: localConfig)
        defer { replacement.close() }
        try replacement.add(Memory(content: "replacement after failed preparation", topic: "fixture", project: "ActorStorage",
                                   embedding: Vector<Float>([1] + [Float](repeating: 0, count: 383))))
        try await tools.prepareStorage()
        let snapshot = await tools.actorStorageSnapshot()
        #expect(snapshot.localCount == 1)
        #expect(snapshot.syncedCount == 1 && snapshot.groups.count == 2)
        #expect(await tools.actorStorageSnapshot() == snapshot)
        await tools.closeActorStorageFixture()
    }

    @Test func missingLocalStoreFailsPreparationWithoutRecreation() async throws {
        let fixture = try fixture(optionalStores: false)
        defer { fixture.close() }
        let tools = fixture.tools()
        fixture.local.close()
        try Lattice.delete(for: fixture.local.configuration)
        await #expect(throws: LatticeError.self) { try await tools.prepareStorage() }
        #expect(!FileManager.default.fileExists(atPath: fixture.local.configuration.fileURL.path))
    }

}
