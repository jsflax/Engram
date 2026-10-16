@testable import EngramKit
import EngramMemoryCore
import EngramModels
import Foundation
import Lattice
import Testing

@Suite("Operation read route preparation", .serialized)
struct MemoryOperationReadRouteTests {
    private struct UnusedEmbedder: Embedder {
        var dimension: Int { 384 }
        func embed(text: String) async throws -> [Float]? { nil }
    }

    private struct Fixture {
        let tools: MemoryTools
        let local: Lattice
        let synced: Lattice
        let groups: [Lattice]
        let ids: Set<UUID>
        func close() { local.close(); synced.close(); groups.forEach { $0.close() } }
    }

    private func fixture(groups count: Int = 1) throws -> Fixture {
        let base = ProcessInfo.processInfo.environment["ENGRAM_ADOPTION_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("operation-route-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let local = try Lattice(Memory.self, Edge.self, SyncConfig.self,
                                configuration: .init(fileURL: directory.appendingPathComponent("local.sqlite"), busyTimeoutMs: 100))
        let synced = try Lattice(Memory.self, Edge.self,
                                 configuration: .init(fileURL: directory.appendingPathComponent("synced.sqlite"), busyTimeoutMs: 100))
        try local.add(SyncConfig(project: "RouteFixture", policy: .sync))
        var refs: [MemoryTools.GroupSpokeRef] = []
        var groups: [Lattice] = []
        for index in 0..<count {
            let path = directory.appendingPathComponent("group-\(index).sqlite")
            let group = try Lattice(Memory.self, Edge.self,
                                    configuration: .init(fileURL: path, busyTimeoutMs: 100))
            groups.append(group)
            refs.append(.init(groupId: UUID(), path: path.path, ref: group.sendableReference))
        }
        var ids: Set<UUID> = []
        for (index, database) in ([local, synced] + groups).enumerated() {
            let memory = Memory(content: "synthetic route \(index)", project: "RouteFixture")
            try database.add(memory)
            ids.insert(try #require(memory.globalId))
        }
        let tools = MemoryTools(localRef: local.sendableReference, syncedRef: synced.sendableReference,
                                groupRefs: refs, embedder: UnusedEmbedder(), identity: StaticIdentityProvider(.anonymous), enableLocalMutationOperations: true)
        return Fixture(tools: tools, local: local, synced: synced, groups: groups, ids: ids)
    }

    @Test func firstUncachedSyncedAndGroupRouteIsReadyBeforeWriterTransaction() async throws {
        let f = try fixture()
        defer { f.close() }
        let ids = try await f.tools.operationFixtureReadPreparedRoute(project: "RouteFixture")
        #expect(ids == f.ids)
        // Repeat also exercises the strict prepared-route cache.
        #expect(try await f.tools.operationFixtureReadPreparedRoute(project: "RouteFixture") == f.ids)
    }

    @Test func routePolicyChangeInsideTransactionRefusesInsteadOfOpeningOrFallingBack() async throws {
        let f = try fixture()
        defer { f.close() }
        await #expect(throws: MemoryOperationError.storageUnavailable) {
            try await f.tools.operationFixtureChangePreparedPolicy(project: "RouteFixture")
        }
        // The failed validation also rolled back the synthetic policy change.
        #expect(try await f.tools.operationFixtureReadPreparedRoute(project: "RouteFixture") == f.ids)
    }

    @Test func requiredAttachmentBudgetCannotSilentlyTruncate() async throws {
        let f = try fixture(groups: 8) // Synced + eight groups exceeds the total eight.
        defer { f.close() }
        await #expect(throws: MemoryOperationError.unsupportedTarget) {
            try await f.tools.operationFixtureReadPreparedRoute(project: "RouteFixture")
        }
    }

    @Test func vanishedRegisteredSpokeRefusesDurableRouteWhileLegacyRecallCanContinue() async throws {
        let f = try fixture()
        defer { f.close() }
        let path = try #require(f.groups.first).configuration.fileURL
        try FileManager.default.moveItem(at: path, to: path.appendingPathExtension("revoked"))
        await #expect(throws: MemoryOperationError.storageUnavailable) {
            try await f.tools.operationFixtureReadPreparedRoute(project: "RouteFixture")
        }
        #expect(try await f.tools.operationFixtureReadLegacyRoute(project: "RouteFixture").count == 2)
    }
}

private extension MemoryTools {
    func operationFixtureReadLegacyRoute(project: String) throws -> Set<UUID> {
        let database = readLattice(for: project)
        let rows = database.objects(Memory.self).snapshot()
        guard database.lastQueryError() == nil else { throw MemoryOperationError.storageUnavailable }
        return try Set(rows.map { try #require($0.materialize().globalId) })
    }

    func operationFixtureReadPreparedRoute(project: String) throws -> Set<UUID> {
        let context = try prepareOperationReadLattice(for: project)
        return try localLattice.withTransaction {
            let database = try validateOperationReadLattice(context, for: project)
            let rows = database.objects(Memory.self).snapshot()
            guard database.lastQueryError() == nil else { throw MemoryOperationError.storageUnavailable }
            return try Set(rows.map { memory in
                memory.materialize()
                return try #require(memory.globalId)
            })
        }
    }

    func operationFixtureChangePreparedPolicy(project: String) throws {
        let context = try prepareOperationReadLattice(for: project)
        try localLattice.withTransaction {
            let config = try #require(localLattice.objects(SyncConfig.self).where { $0.project == project }.first)
            config.policy = .local
            _ = try validateOperationReadLattice(context, for: project)
        }
    }
}
