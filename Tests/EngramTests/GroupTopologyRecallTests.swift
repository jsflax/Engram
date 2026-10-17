import Testing
import EngramKit
import EngramMemoryCore
import EngramModels
import Lattice
import MCP
import Foundation

// ============================================================================
// Graph-of-graphs recall — the battle-test for "groups are a graph of
// graphs". A member of several graphs (org tree + concept graph) recalls
// ONCE and sees every graph's contribution, attributed ([by:]) and
// provenanced ([via:]), with no duplicates and no cross-graph bleed.
//
// Unlike GroupReadLatticeTests (deliberately directory-less), this suite
// writes a groups.json fixture: names for [via:], members for [by:], and a
// selfUserId so own rows render clean. GroupDirectory.fileURL is
// process-global: serialize its writers here and save/restore every test.
// Other suites still run concurrently, so ordinary helpers pin their identity.
// ============================================================================

private struct TopologySpoke {
    let groupId: UUID
    let name: String
    let parentId: UUID?
    let path: String
    let lattice: Lattice
}

private struct TopologyContext {
    let tools: MemoryTools
    let local: Lattice
    let selfUserId: UUID
    let spokes: [String: TopologySpoke]  // by group name
}

/// Builds N spokes (one per (name, parentId) entry), a groups.json fixture
/// naming them (plus any spokeless groups like the org root), and
/// MemoryTools over the lot. Caller restores `GroupDirectory.fileURL`.
private func makeTopologyTools(
    spoked: [(name: String, parentId: UUID?)],
    spokeless: [(id: UUID, name: String, parentId: UUID?)] = [],
    members: [UUID: String] = [:],
    selfUserId: UUID
) async throws -> TopologyContext {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "engram-topology-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let local = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self,
                            SyncConfig.self,
                            configuration: .init(fileURL: dir.appending(path: "memory.sqlite")))

    var spokes: [String: TopologySpoke] = [:]
    var refs: [MemoryTools.GroupSpokeRef] = []
    var groupInfos: [GroupDirectory.GroupInfo] = []
    for entry in spoked {
        let gid = UUID()
        let path = dir.appending(path: "group-\(gid.uuidString).sqlite").path
        let lattice = try Lattice(Memory.self, Edge.self, GroupProjectMap.self,
                                  configuration: .init(fileURL: URL(fileURLWithPath: path)))
        spokes[entry.name] = TopologySpoke(groupId: gid, name: entry.name,
                                           parentId: entry.parentId,
                                           path: path, lattice: lattice)
        refs.append(.init(groupId: gid, path: path, ref: lattice.sendableReference))
        groupInfos.append(.init(id: gid, name: entry.name, parentId: entry.parentId,
                                myRole: "member", root: entry.parentId == nil))
    }
    for g in spokeless {
        groupInfos.append(.init(id: g.id, name: g.name, parentId: g.parentId,
                                myRole: "member", root: g.parentId == nil))
    }

    let file = GroupDirectory.GroupsFile(
        selfUserId: selfUserId,
        updatedAt: Date(),
        groups: groupInfos,
        members: members.reduce(into: [:]) { $0[$1.key.uuidString] = $1.value })
    let fileURL = dir.appending(path: "groups.json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601  // GroupDirectory decodes iso8601
    try encoder.encode(file).write(to: fileURL)
    GroupDirectory.fileURL = fileURL

    let embedder = sharedEmbedder
    if await !embedder.isLoaded { await embedder.load() }
    let tools = MemoryTools(localRef: local.sendableReference, syncedRef: nil,
                            groupRefs: refs, embedder: embedder)
    return TopologyContext(tools: tools, local: local,
                           selfUserId: selfUserId, spokes: spokes)
}

@discardableResult
private func addMemory(_ content: String, project: String, author: UUID?,
                       to lattice: Lattice) async throws -> UUID {
    let mem = Memory(
        content: content, topic: "general", project: project,
        embedding: Vector<Float>(try await sharedEmbedder.embed(text: content)!),
        authorUserId: author)
    try lattice.add(mem)
    return mem.globalId!
}

@Suite(.serialized)
struct GroupTopologyRecallTests {

    /// Directory writers share this serialized suite. Ordinary helpers must
    /// remain anonymous even when the ambient production identity changes.
    @Test(arguments: [false, true])
    func isolatedHelpersKeepAuthorshipAcrossDirectoryChanges(dualDatabase: Bool) async throws {
        let savedURL = GroupDirectory.fileURL
        defer { GroupDirectory.fileURL = savedURL }
        let directory = try testFixtureDirectory()
            .appending(path: "engram-helper-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        func useAmbientIdentity(_ id: UUID, revision: Int) throws {
            let file = GroupDirectory.GroupsFile(selfUserId: id, updatedAt: Date(),
                                                  groups: [], members: [:])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let url = directory.appending(path: "groups-\(revision).json")
            try encoder.encode(file).write(to: url)
            // The production cache currently keys by mtime, so establish
            // distinct versions without relying on sleeps or clock granularity.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_000_000_000 + Double(revision))],
                ofItemAtPath: url.path)
            GroupDirectory.fileURL = url
            try #require(GroupDirectoryIdentityProvider().currentPrincipal().id == id)
        }

        let ambientA = UUID(), ambientB = UUID()
        try useAmbientIdentity(ambientA, revision: 1)
        let tools: MemoryTools
        if dualDatabase { tools = try await makeDualDBTools().tools }
        else { tools = try await makeTools() }
        #expect(tools.principal == .anonymous)

        func remember(_ content: String) async throws -> UUID {
            let result = try await tools.handle(CallTool.Parameters(name: "remember", arguments: [
                "content": .string(content), "force": .bool(true)
            ]))
            try #require(result.isError != true)
            let id = try #require(extractId(from: text(from: result)).flatMap(UUID.init(uuidString:)))
            let stored = try await tools.graph(GraphRequest(id: id)).root
            #expect(stored.id == id && stored.authorUserId == nil)
            return id
        }

        let first = try await remember("Memory A for isolated helper identity")
        try useAmbientIdentity(ambientB, revision: 2)
        #expect(tools.principal == .anonymous)
        let second = try await remember("Memory B for isolated helper identity")
        let firstAfterChange = try await tools.graph(GraphRequest(id: first)).root
        #expect(firstAfterChange.authorUserId == nil)

        // This is an ordinary consolidation: no foreign-author override.
        let result = try await tools.handle(CallTool.Parameters(name: "consolidate", arguments: [
            "ids": .array([.string(first.uuidString), .string(second.uuidString)]),
            "content": .string("Combined isolated helper identity summary"), "importance": .int(5)
        ]))
        try #require(result.isError != true)
        #expect(text(from: result).contains("importance: 5"))
        let summaryID = try #require(extractId(from: text(from: result)).flatMap(UUID.init(uuidString:)))
        let summary = try await tools.graph(GraphRequest(id: summaryID)).root
        #expect(summary.importance == 5 && summary.authorUserId == nil)
        for id in [first, second] {
            let source = try await tools.graph(GraphRequest(id: id)).root
            #expect(source.importance == 0 && source.authorUserId == nil)
        }
    }

    /// One recall unions the org's teams AND the concept graph, with every
    /// graph attributed and provenanced — the founder's canary/mobile shape,
    /// expressed as user-level multi-membership.
    @Test func recall_unionsCanaryTeamsAndConceptGraphs() async throws {
        let savedURL = GroupDirectory.fileURL
        defer { GroupDirectory.fileURL = savedURL }

        let carol = UUID(), alice = UUID(), bob = UUID(), dave = UUID()
        let canaryId = UUID()
        let ctx = try await makeTopologyTools(
            spoked: [("team-ios", canaryId), ("team-web", canaryId), ("mobile", nil)],
            spokeless: [(canaryId, "canary", nil)],
            members: [alice: "Alice", bob: "Bob", dave: "Dave", carol: "Carol"],
            selfUserId: carol)

        try await addMemory("release checklist: carol's local step is signing the build",
                            project: "demo", author: carol, to: ctx.local)
        try await addMemory("release checklist: alice says ios needs a TestFlight pass first",
                            project: "demo", author: alice,
                            to: ctx.spokes["team-ios"]!.lattice)
        try await addMemory("release checklist: bob says web deploys behind the flag",
                            project: "demo", author: bob,
                            to: ctx.spokes["team-web"]!.lattice)
        try await addMemory("release checklist: dave says mobile ships both stores together",
                            project: "demo", author: dave,
                            to: ctx.spokes["mobile"]!.lattice)

        let out = text(from: try await ctx.tools.handle(CallTool.Parameters(
            name: "recall",
            arguments: ["query": .string("release checklist"), "project": .string("demo")])))

        // Every graph contributes to ONE response.
        #expect(out.contains("signing the build"))
        #expect(out.contains("TestFlight pass"), "team-ios graph missing")
        #expect(out.contains("behind the flag"), "team-web graph missing")
        #expect(out.contains("both stores together"), "concept graph missing")

        // Attribution resolves through the member directory…
        #expect(out.contains("[by:Alice]"))
        #expect(out.contains("[by:Bob]"))
        #expect(out.contains("[by:Dave]"))
        // …and provenance names the graph each row came from.
        #expect(out.contains("[via:team-ios]"))
        #expect(out.contains("[via:team-web]"))
        #expect(out.contains("[via:mobile]"))

        // Own local row: no badge, no via.
        let ownLine = out.split(separator: "\n").first { $0.contains("signing the build") }
        #expect(ownLine != nil)
        #expect(ownLine?.contains("[by:") == false, "own row must not carry a by-badge")
        #expect(ownLine?.contains("[via:") == false, "hub row must not carry a via-marker")

        // No memory rendered twice.
        for needle in ["signing the build", "TestFlight pass", "behind the flag",
                       "both stores together"] {
            #expect(out.components(separatedBy: needle).count == 2,
                    "'\(needle)' rendered more than once")
        }
    }

    /// decision 13 across TWO graphs: my mapping rows in both spokes plus a
    /// teammate's differently-named mapping in one of them chain into one
    /// resolved set, so recall/stats treat every alias as the same project.
    @Test func resolveQueryProjects_chainsAcrossTwoSpokes() async throws {
        let savedURL = GroupDirectory.fileURL
        defer { GroupDirectory.fileURL = savedURL }

        let carol = UUID(), teammate = UUID()
        let ctx = try await makeTopologyTools(
            spoked: [("team-ios", nil), ("mobile", nil)],
            members: [teammate: "Terry"],
            selfUserId: carol)

        // My rows: ios-app → Mobile in BOTH graphs I exposed it to.
        try ctx.spokes["team-ios"]!.lattice.add(GroupProjectMap(
            memberUserId: carol, localProject: "ios-app", groupProject: "Mobile"))
        try ctx.spokes["mobile"]!.lattice.add(GroupProjectMap(
            memberUserId: carol, localProject: "ios-app", groupProject: "Mobile"))
        // Teammate's local name for the SAME canonical project, in one graph.
        try ctx.spokes["mobile"]!.lattice.add(GroupProjectMap(
            memberUserId: teammate, localProject: "web-app", groupProject: "Mobile"))

        let resolved = await ctx.tools.resolveQueryProjects("ios-app")
        #expect(resolved.contains("ios-app"))
        #expect(resolved.contains("web-app"),
                "teammate's alias for the same canonical project must resolve")
    }

    /// KNN candidate identity across spokes (latticecore 1.2.6): colliding
    /// rowids in different graphs must NOT let one graph's candidate drag an
    /// unrelated row out of another graph with a borrowed distance. Red
    /// against latticecore ≤1.2.5 (the C++ red-first proof lives in
    /// AttachKnnCrossArmTests); this is the client-level guard that outlives
    /// core internals.
    @Test func recall_neverBorrowsDistancesAcrossSpokesWithCollidingRowids() async throws {
        let savedURL = GroupDirectory.fileURL
        defer { GroupDirectory.fileURL = savedURL }

        let me = UUID(), a = UUID(), b = UUID()
        let ctx = try await makeTopologyTools(
            spoked: [("graphics", nil), ("baking", nil)],
            members: [a: "Ada", b: "Blaise"],
            selfUserId: me)

        // Same rowids (1..3) in both spokes, disjoint topics.
        for text in ["quaternion camera interpolation eases the orbit",
                     "quaternion slerp keeps the camera path smooth",
                     "camera interpolation needs renormalized quaternions"] {
            try await addMemory(text, project: "demo", author: a,
                                to: ctx.spokes["graphics"]!.lattice)
        }
        for text in ["sourdough hydration ratios around seventy percent",
                     "sourdough starter needs consistent feeding",
                     "higher hydration makes an open sourdough crumb"] {
            try await addMemory(text, project: "demo", author: b,
                                to: ctx.spokes["baking"]!.lattice)
        }

        let out = text(from: try await ctx.tools.handle(CallTool.Parameters(
            name: "recall",
            arguments: ["query": .string("quaternion camera interpolation"),
                        "limit": .int(3)])))

        #expect(out.contains("quaternion"))
        #expect(!out.contains("sourdough"),
                "unrelated graph's rows surfaced — cross-arm rowid borrow")
    }

    /// A spoke hydrated purely by sync-apply has rows but NO vec index (the
    /// apply path never creates the vec0 tables or their maintenance
    /// triggers), so its arm contributes nothing to semantic recall. The
    /// from-scratch heal is red-first proven in latticecore
    /// (SyncOnlyVecReconcileTests: reconcile-on-open + vacuum_vec0); a
    /// client fixture cannot HOLD the dark state deterministically because
    /// stripping the index bumps the schema cookie, forcing the next open
    /// down the DDL path that rebuilds it. What THIS test guards end-to-end:
    /// the vacuum tool reaches group spokes (it historically only touched
    /// local + synced), and a spoke whose index was destroyed ends up fully
    /// recalled — [by:]/[via:] included — after open + vacuum.
    @Test func vacuum_coversGroupSpokes() async throws {
        let savedURL = GroupDirectory.fileURL
        defer { GroupDirectory.fileURL = savedURL }

        let me = UUID(), remy = UUID()
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "engram-spokeheal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let gid = UUID()
        let spokePath = dir.appending(path: "group-\(gid.uuidString).sqlite").path

        // Populate through a scoped handle (vec built by triggers), close it,
        // then strip every vec artifact — the exact on-disk state sync-apply
        // leaves behind.
        try await {
            let writer = try Lattice(Memory.self, Edge.self, GroupProjectMap.self,
                                     configuration: .init(fileURL: URL(fileURLWithPath: spokePath)))
            for text in ["beta rollout: remy says the spoke ships gradual rollout flags",
                         "beta rollout: remy wants the kill switch wired before launch"] {
                try await addMemory(text, project: "demo", author: remy, to: writer)
            }
            writer.checkpoint()
        }()
        try stripVecIndex(atPath: spokePath)

        let spoke = try Lattice(Memory.self, Edge.self, GroupProjectMap.self,
                                configuration: .init(fileURL: URL(fileURLWithPath: spokePath)))
        #expect(spoke.objects(Memory.self).count == 2, "rows must survive the strip")

        let local = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self,
                                SyncConfig.self,
                                configuration: .init(fileURL: dir.appending(path: "memory.sqlite")))
        try await addMemory("beta rollout: my local note about the flag dashboard",
                            project: "demo", author: me, to: local)

        let file = GroupDirectory.GroupsFile(
            selfUserId: me, updatedAt: Date(),
            groups: [.init(id: gid, name: "mobile", parentId: nil,
                           myRole: "member", root: true)],
            members: [remy.uuidString: "Remy"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let fileURL = dir.appending(path: "groups.json")
        try encoder.encode(file).write(to: fileURL)
        GroupDirectory.fileURL = fileURL

        let embedder = sharedEmbedder
        if await !embedder.isLoaded { await embedder.load() }
        let tools = MemoryTools(
            localRef: local.sendableReference, syncedRef: nil,
            groupRefs: [.init(groupId: gid, path: spokePath, ref: spoke.sendableReference)],
            embedder: embedder)

        // The vacuum surface must report spoke coverage…
        let healed = text(from: try await tools.handle(CallTool.Parameters(name: "vacuum")))
        #expect(healed.contains("1 group spoke(s) reindexed"))

        // …and the spoke whose index was destroyed is fully recalled.
        let lit = text(from: try await tools.handle(CallTool.Parameters(
            name: "recall",
            arguments: ["query": .string("beta rollout"), "project": .string("demo")])))
        #expect(lit.contains("flag dashboard"), "local arm must still function")
        #expect(lit.contains("gradual rollout"), "spoke must contribute to recall")
        #expect(lit.contains("kill switch wired"))
        #expect(lit.contains("[by:Remy]"))
        #expect(lit.contains("[via:mobile]"))
    }
}

/// Removes the vec0 virtual table, its shadow tables, and its maintenance
/// triggers from a closed lattice file — reproducing a spoke hydrated purely
/// by sync-apply, which INSERTs rows without ever creating the vec index.
/// Goes through the sqlite3 CLI: Apple's system SQLite has
/// SQLITE_DBCONFIG_DEFENSIVE on by default (blocking writable_schema), and
/// the escape hatch `sqlite3_db_config` is variadic — uncallable from Swift.
private func stripVecIndex(atPath path: String) throws {
    struct StripError: Error { let message: String }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    p.arguments = [
        path,
        ".dbconfig defensive off",
        #"PRAGMA writable_schema=ON; DELETE FROM sqlite_master WHERE name LIKE '\_Memory\_embedding\_vec%' ESCAPE '\'; PRAGMA writable_schema=OFF; VACUUM;"#,
    ]
    let err = Pipe()
    p.standardError = err
    p.standardOutput = Pipe()
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? "?"
        throw StripError(message: "sqlite3 exited \(p.terminationStatus): \(msg)")
    }
}
