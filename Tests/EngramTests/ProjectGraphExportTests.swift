import EngramMemoryCore
import EngramModels
import Foundation
import Lattice
import Testing
@testable import EngramKit

private final class GraphExportIdentity: IdentityProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Principal
    init(_ value: Principal) { self.value = value }
    func currentPrincipal() -> Principal { lock.lock(); defer { lock.unlock() }; return value }
    func replace(_ value: Principal) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

private final class GraphExportAuthority: EngramGraphReadAuthorizing, @unchecked Sendable {
    let grant: EngramGraphReadGrant
    private let lock = NSLock()
    private var calls = 0
    private let rejectAt: Int?
    init(_ grant: EngramGraphReadGrant, rejectAt: Int? = nil) { self.grant = grant; self.rejectAt = rejectAt }
    func authorizeGraphRead(scope: EngramGraphScope, principal: Principal) throws -> EngramGraphReadGrant {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        if let rejectAt, calls >= rejectAt { throw EngramGraphExportError.notAuthorized }
        return grant
    }
}

private extension MemoryTools {
    func closeGraphFixtureHandles() {
        localLattice.close(); syncedLattice?.close()
        for spoke in groupSpokes { spoke.lattice.close() }
    }
    func graphFixtureProvenance() throws -> (ownLegacy: [String]?, localRows: Int, groupRows: Int) {
        let route = try prepareOperationReadLattice(for: "hud")
        let database = try validateOperationReadLattice(route, for: "hud")
        let local = database.dynamicObjects(Memory.entityName).where("_source = 'main'").count
        guard database.lastQueryError() == nil else { throw EngramGraphExportError.storageUnavailable }
        // This assertion uses the actual TEMP union label, including its identifier quotes.
        let group = database.dynamicObjects(Memory.entityName).where("_source = '\"group\"'").count
        guard database.lastQueryError() == nil else { throw EngramGraphExportError.storageUnavailable }
        return (route.ownLegacySourceLabels, local, group)
    }
}

@Suite("Authenticated project graph export", .serialized, .timeLimit(.minutes(1)))
@MainActor struct ProjectGraphExportTests {
    private struct NoEmbedding: Embedder {
        let dimension = 384
        func embed(text: String) async throws -> [Float]? { nil }
    }
    private struct Fixture {
        let directory: URL
        let local: Lattice
        let group: Lattice?
        let groupID: UUID?
        let groupURL: URL?
        let tools: MemoryTools
        let identity: GraphExportIdentity
        let scope: EngramGraphScope
        let grant: EngramGraphReadGrant
        func exporter(rejectAt: Int? = nil) -> EngramProjectGraphExporter {
            EngramProjectGraphExporter(trustedTools: tools, authority: GraphExportAuthority(grant, rejectAt: rejectAt))
        }
        func close() async {
            await tools.closeGraphFixtureHandles()
            local.close(); group?.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }
    private func fixture(group: Bool = false) throws -> Fixture {
        let configured = ProcessInfo.processInfo.environment["ENGRAM_ADOPTION_TEST_ROOT"]
        let root = configured.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("localdev/hud-scratch/engram-graph-export-tests", isDirectory: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func open(_ file: String) throws -> Lattice {
            var config = Lattice.Configuration(fileURL: directory.appendingPathComponent(file), migration: engramMigrations)
            config.busyTimeoutMs = 100
            return try Lattice(Memory.self, Edge.self, SyncConfig.self, configuration: config)
        }
        let local = try open("local.sqlite")
        let groupID = group ? UUID() : nil
        let groupURL = group ? directory.appendingPathComponent("group.sqlite") : nil
        let groupStore = group ? try open("group.sqlite") : nil
        let principal = Principal(id: UUID(), kind: .user, groupIds: groupID.map { [$0] } ?? [], scopes: ["viz-readonly"])
        let identity = GraphExportIdentity(principal)
        let refs = groupStore.map { store in [MemoryTools.GroupSpokeRef(groupId: groupID!, path: groupURL!.path, ref: store.sendableReference)] } ?? []
        let tools = MemoryTools(localRef: local.sendableReference, syncedRef: nil, groupRefs: refs,
                                embedder: NoEmbedding(), identity: identity)
        let scope = try EngramGraphScope(workspaceID: "fixture-account", project: "hud", topics: ["design"])
        let grant = try EngramGraphReadGrant(trustedConnectionID: UUID(), connectionGeneration: 1,
                                            authenticatedPrincipal: principal, authorizedScope: scope,
                                            approvedGroupIDs: Set(principal.groupIds))
        return Fixture(directory: directory, local: local, group: groupStore, groupID: groupID,
                       groupURL: groupURL, tools: tools, identity: identity, scope: scope, grant: grant)
    }
    private func memory(_ store: Lattice, content: String = "## Design note", project: String = "hud", topic: String = "design",
                        source: String = "private/source/path",
                        privateRow: Bool = false, expired: Bool = false, deleted: Bool = false,
                        id: UUID = UUID(), author: UUID? = nil) throws -> UUID {
        let row = Memory(content: content, topic: topic, project: project, source: source,
                         embedding: Vector<Float>([Float](repeating: 0.25, count: 384)),
                         createdAt: Date(timeIntervalSince1970: 1), lastAccessedAt: Date(timeIntervalSince1970: 2),
                         expiresAt: expired ? .distantPast : .distantFuture, importance: 2,
                         isPrivate: privateRow, authorUserId: author, deletedAt: deleted ? Date() : nil)
        try store.add(row, preservingGlobalId: id)
        return id
    }

    @Test func filtersBeforeExportAndIncludesOnlyVisibleEndpointsAndExistingHubSemantics() async throws {
        let f = try fixture()
        do {
            let a = try memory(f.local), b = try memory(f.local, content: "**Architecture**")
            let foreign = try memory(f.local, project: "other")
            _ = try memory(f.local, privateRow: true); _ = try memory(f.local, expired: true)
            _ = try memory(f.local, deleted: true); _ = try memory(f.local, topic: "outside")
            try f.local.add(Edge(sourceGlobalId: a, targetGlobalId: b, relation: .partOf))
            try f.local.add(Edge(sourceGlobalId: a, targetGlobalId: foreign, relation: .relatesTo))
            let result = try await f.exporter().projectGraph(f.scope)
            #expect(Set(result.nodes.map(\.id)) == [a, b])
            #expect(result.edges.count == 1 && result.edges[0].targetID == b)
            #expect(result.nodes.first(where: { $0.id == b })?.isHub == true)
            #expect(result.nodes.allSatisfy { $0.position == nil })
            let bytes = String(decoding: try result.encoded(), as: UTF8.self)
            #expect(!bytes.contains("embedding") && !bytes.contains("private/source/path") && !bytes.contains("authorUserId"))
            #expect(result.completeness == .complete)
        } catch { await f.close(); throw error }
        await f.close()
    }

    @Test func longContentKeepsNodeAsExplicitUnicodeSafeExcerptAndHugeSourceFails() async throws {
        let f = try fixture()
        do {
            _ = try memory(f.local, content: String(repeating: "🛰", count: 6_000))
            let exporter = f.exporter()
            let result = try await exporter.projectGraph(f.scope)
            let node = try #require(result.nodes.first)
            #expect(node.contentIsExcerpt && node.content.utf8.count <= 16 * 1024)
            #expect(!node.content.contains("�"))
            _ = try memory(f.local, content: String(repeating: "x", count: 1024 * 1024 + 1))
            await #expect(throws: EngramGraphExportError.capacity) { try await exporter.projectGraph(f.scope) }
        } catch { await f.close(); throw error }
        await f.close()
    }

    @Test func authorizationChangesAndForeignScopeNeverPublishASnapshot() async throws {
        let f = try fixture()
        do {
            _ = try memory(f.local)
            let wrong = try EngramGraphScope(workspaceID: "other-account", project: "hud", topics: ["design"])
            await #expect(throws: EngramGraphExportError.notAuthorized) { try await f.exporter().projectGraph(wrong) }
            await #expect(throws: EngramGraphExportError.notAuthorized) { try await f.exporter(rejectAt: 4).projectGraph(f.scope) }
            f.identity.replace(Principal(id: UUID(), kind: .user))
            await #expect(throws: EngramGraphExportError.notAuthorized) { try await f.exporter().projectGraph(f.scope) }
        } catch { await f.close(); throw error }
        await f.close()
    }

    @Test func everyCopyCanVetoRetractionAndConflictingCopiesFail() async throws {
        let f = try fixture(group: true)
        do {
            let group = try #require(f.group)
            let privateID = try memory(f.local)
            _ = try memory(group, privateRow: true, id: privateID)
            let allowed = try memory(f.local)
            let result = try await f.exporter().projectGraph(f.scope)
            #expect(result.nodes.map(\.id) == [allowed])
            _ = try memory(group, content: "Different copy", id: allowed)
            await #expect(throws: EngramGraphExportError.inconsistentRows) { try await f.exporter().projectGraph(f.scope) }
            #expect(result.nodes.count == 1) // prior immutable result remains usable
        } catch { await f.close(); throw error }
        await f.close()
    }

    @Test func missingGroupFailsStrictlyAndCancelledRequestsDoNotExport() async throws {
        let f = try fixture(group: true)
        do {
            _ = try memory(f.local)
            let exporter = f.exporter()
            let task = Task { try await exporter.projectGraph(f.scope) }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            let path = try #require(f.groupURL)
            try FileManager.default.moveItem(at: path, to: path.appendingPathExtension("revoked"))
            await #expect(throws: (any Error).self) { try await exporter.projectGraph(f.scope) }
        } catch { await f.close(); throw error }
        await f.close()
    }

    @Test func aggregateTextLimitIsExplicitAndGraphDoesNotWriteAccessStats() async throws {
        let f = try fixture()
        do {
            try f.local.withTransaction {
                for _ in 0..<257 { _ = try memory(f.local, content: String(repeating: "a", count: 16 * 1024)) }
            }
            let before = f.local.objects(Memory.self).first?.lastAccessedAt
            let result = try await f.exporter().projectGraph(f.scope)
            #expect(result.completeness == .limitReached && result.nodes.count < 257)
            #expect(f.local.objects(Memory.self).first?.lastAccessedAt == before)
        } catch { await f.close(); throw error }
        await f.close()
    }

    @Test func foreignContentPolicyRetainsOwnLegacyButNotUnattributedGroupRows() async throws {
        let f = try fixture(group: true)
        do {
            let own = try memory(f.local)
            _ = try memory(f.local, author: UUID())
            _ = try memory(try #require(f.group))
            let provenance = try await f.tools.graphFixtureProvenance()
            #expect(provenance.ownLegacy == ["main"] && provenance.localRows == 2 && provenance.groupRows == 1)
            await f.tools.setForeignContentPolicy(fence: false, exclude: true)
            let result = try await f.exporter().projectGraph(f.scope)
            #expect(result.nodes.map(\.id) == [own])
        } catch { await f.close(); throw error }
        await f.close()
    }

    @Test func oversizedIncidentalSourceAndClosedStorageCannotPublishEmptySuccess() async throws {
        let f = try fixture()
        do {
            // A valid vector dimension avoids failing in vec0 before the exporter is reached.
            _ = try memory(f.local, source: String(repeating: "x", count: 4_097))
            await #expect(throws: EngramGraphExportError.capacity) { try await f.exporter().projectGraph(f.scope) }
            try await f.tools.prepareStorage()
            await f.tools.closeGraphFixtureHandles()
            await #expect(throws: (any Error).self) { try await f.exporter().projectGraph(f.scope) }
        } catch { await f.close(); throw error }
        await f.close()
    }

}
