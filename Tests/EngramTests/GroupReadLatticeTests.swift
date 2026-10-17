import Testing
import EngramKit
import EngramMemoryCore
import EngramModels
import Lattice
import MCP
import Foundation

// ============================================================================
// Increment 4 — the READ surface. Group spokes join every recall because
// reads are MEMBERSHIP-scoped (decision 3): exposure gates only what leaves
// this machine. These tests drive the real MCP handlers over real spoke
// files, because the failure modes here are invisible to predicate
// inspection — a teammate's memory that doesn't surface looks exactly like a
// teammate who wrote nothing.
//
// Pin an anonymous identity without writing groups.json: parallel directory
// fixtures cannot change currentUserId. Any non-nil author is foreign, and
// nil-author rows exercise the residency arm directly.
// ============================================================================

private struct GroupToolsContext {
    let tools: MemoryTools
    let local: Lattice
    let spokes: [(id: UUID, path: String, lattice: Lattice)]
}

private func makeGroupTools(spokeCount: Int = 1) async throws -> GroupToolsContext {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "engram-groupread-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let local = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self,
                            SyncConfig.self,
                            configuration: .init(fileURL: dir.appending(path: "memory.sqlite")))

    var spokes: [(id: UUID, path: String, lattice: Lattice)] = []
    var refs: [MemoryTools.GroupSpokeRef] = []
    for _ in 0..<spokeCount {
        let gid = UUID()
        let path = dir.appending(path: "group-\(gid.uuidString).sqlite").path
        let lattice = try Lattice(Memory.self, Edge.self, GroupProjectMap.self,
                                  configuration: .init(fileURL: URL(fileURLWithPath: path)))
        spokes.append((gid, path, lattice))
        refs.append(.init(groupId: gid, path: path, ref: lattice.sendableReference))
    }

    let embedder = sharedEmbedder
    if await !embedder.isLoaded { await embedder.load() }
    let tools = MemoryTools(localRef: local.sendableReference, syncedRef: nil,
                            groupRefs: refs, embedder: embedder,
                            identity: StaticIdentityProvider(.anonymous))
    return GroupToolsContext(tools: tools, local: local, spokes: spokes)
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

// MARK: - Membership-scoped union

@Test func recall_surfacesTeammateMemoriesFromEverySpoke() async throws {
    let ctx = try await makeGroupTools(spokeCount: 2)
    let alice = UUID(), bob = UUID()

    try await addMemory("the retry budget is exhausted after three attempts",
                        project: "engram", author: nil, to: ctx.local)
    try await addMemory("alice found the retry budget resets on reconnect",
                        project: "engram", author: alice, to: ctx.spokes[0].lattice)
    try await addMemory("bob found the retry budget is per-channel",
                        project: "engram", author: bob, to: ctx.spokes[1].lattice)

    let out = text(from: try await ctx.tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("retry budget"), "project": .string("engram")])))

    #expect(out.contains("exhausted after three attempts"))
    #expect(out.contains("resets on reconnect"), "spoke 1 memory missing from the union")
    #expect(out.contains("per-channel"), "spoke 2 memory missing from the union")
}

@Test func recall_withoutProject_stillReadsSpokes() async throws {
    // Exposure is irrelevant to reads, and so is a project filter: the
    // project-less early return that used to skip the synced DB must not
    // strand group memories.
    let ctx = try await makeGroupTools()
    try await addMemory("the nebula emitter budget is about seventy",
                        project: "engram", author: UUID(), to: ctx.spokes[0].lattice)

    let out = text(from: try await ctx.tools.handle(CallTool.Parameters(
        name: "recall", arguments: ["query": .string("nebula emitter budget")])))
    #expect(out.contains("about seventy"))
}

// NOTE: the local⊎spoke duplicate case (my own memory echoed back from the
// group under the SAME globalId) is covered by recall's `.distinct(by:
// \.globalId)`, exercised by the dual-DB suite — it can't be staged here
// because `globalId` has an internal setter, so a test can't forge the
// collision that the relay produces naturally.

// MARK: - Revocation reaches the next recall

@Test func revokedSpokeDropsOutOfTheUnionWithoutRestart() async throws {
    let ctx = try await makeGroupTools()
    try await addMemory("the kicked member must stop seeing this",
                        project: "engram", author: UUID(), to: ctx.spokes[0].lattice)

    var out = text(from: try await ctx.tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("kicked member"), "project": .string("engram")])))
    #expect(out.contains("stop seeing this"))

    // The daemon quarantines a revoked spoke by RENAMING it. The per-read
    // stat() guard is what makes revocation latency "next recall" rather
    // than "whenever this MCP process happens to exit".
    try FileManager.default.moveItem(atPath: ctx.spokes[0].path,
                                     toPath: ctx.spokes[0].path + ".revoked")
    defer {
        try? FileManager.default.moveItem(atPath: ctx.spokes[0].path + ".revoked",
                                          toPath: ctx.spokes[0].path)
    }

    out = text(from: try await ctx.tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("kicked member"), "project": .string("engram")])))
    #expect(!out.contains("stop seeing this"),
            "a revoked spoke kept serving group memories")
}

@Test func discoveryIgnoresRevokedAndMalformedSpokeFiles() throws {
    let claudeDir = FileManager.default.temporaryDirectory
        .appending(path: "engram-discovery-\(UUID().uuidString)").path
    let syncDir = (SyncService.syncedDbPath(claudeDir: claudeDir) as NSString)
        .deletingLastPathComponent
    let live = UUID()
    let fm = FileManager.default
    fm.createFile(atPath: syncDir + "/group-\(live.uuidString).sqlite", contents: Data())
    fm.createFile(atPath: syncDir + "/group-\(UUID().uuidString).sqlite.revoked", contents: Data())
    fm.createFile(atPath: syncDir + "/group-not-a-uuid.sqlite", contents: Data())
    fm.createFile(atPath: syncDir + "/memory-synced.sqlite", contents: Data())

    let found = SyncService.discoverGroupSpokes(claudeDir: claudeDir)
    #expect(found.map(\.groupId) == [live],
            "discovery returned \(found.map(\.groupId))")
}

// MARK: - Attribution: nil author on a spoke row is FOREIGN, never self

@Test func nilAuthorInSpokeIsForeign_nilAuthorInHubIsNot() async throws {
    let ctx = try await makeGroupTools()
    // Unstamped teammate row (wrote before their client stamped authorship).
    try await addMemory("an unattributed teammate note about vector indexes",
                        project: "engram", author: nil, to: ctx.spokes[0].lattice)
    // My own legacy row — same nil author, but hub-resident.
    try await addMemory("my own legacy note about vector indexes",
                        project: "engram", author: nil, to: ctx.local)

    let out = text(from: try await ctx.tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("vector indexes"), "project": .string("engram")])))

    // The spoke row must be badged; nil resolves to "unknown", never to a
    // silent unlabelled line that would inject as if it were the user's own.
    let teammateLine = out.components(separatedBy: "\n\n")
        .first { $0.contains("unattributed teammate note") }
    let ownLine = out.components(separatedBy: "\n\n")
        .first { $0.contains("my own legacy note") }
    #expect(teammateLine?.contains("[by:unknown]") == true,
            "spoke-resident nil-author row rendered without a badge: \(teammateLine ?? "missing")")
    #expect(ownLine?.contains("[by:") == false,
            "own legacy row was badged as foreign: \(ownLine ?? "missing")")
}

@Test func badgeKeepsTheRecallLineParseable() async throws {
    // logRecalledMemories anchors on `[id:` and the FIRST bracket pair after
    // it, so the badge must never land between them.
    let ctx = try await makeGroupTools()
    try await addMemory("badge placement must not break the parser",
                        project: "engram", author: UUID(), to: ctx.spokes[0].lattice)

    let out = text(from: try await ctx.tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("badge placement parser"), "project": .string("engram")])))
    let line = out.components(separatedBy: "\n\n").first { $0.contains("badge placement") }
    let trimmed = try #require(line?.trimmingCharacters(in: .whitespacesAndNewlines))
    #expect(trimmed.hasPrefix("[id:"))
    let afterId = trimmed[trimmed.index(after: trimmed.firstIndex(of: "]")!)...]
    let ptStart = try #require(afterId.firstIndex(of: "["))
    let ptEnd = try #require(afterId.firstIndex(of: "]"))
    let projTopic = String(afterId[afterId.index(after: ptStart)..<ptEnd])
    #expect(projTopic == "engram/general", "parser would read '\(projTopic)' as project/topic")
}

// MARK: - Access stats never write into a group DB

@Test func recallDoesNotBumpAccessStatsOnSpokeRows() async throws {
    let ctx = try await makeGroupTools()
    let gid = try await addMemory("a bump here would fan out to every member",
                                  project: "engram", author: UUID(),
                                  to: ctx.spokes[0].lattice)
    let localGid = try await addMemory("a bump here is purely local",
                                       project: "engram", author: nil, to: ctx.local)

    _ = try await ctx.tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("bump fan out member local"),
                    "project": .string("engram")]))

    let spokeRow = ctx.spokes[0].lattice.objects(Memory.self)
        .where { $0.globalId == gid }.first
    #expect(spokeRow?.accessCount == 0,
            "recall wrote access stats into a group DB — that is an O(members) WSS fan-out per recall")
    let hubRow = ctx.local.objects(Memory.self).where { $0.globalId == localGid }.first
    #expect((hubRow?.accessCount ?? 0) > 0, "hub-resident rows should still be bumped")
}

// MARK: - Group project registry (decision 13)

@Test func resolveQueryProjectsMapsAcrossMembersLocalNames() async throws {
    let ctx = try await makeGroupTools()
    // The REAL signed-in id when ~/.claude/sync/groups.json exists on this
    // machine (the daemon writes it): resolveQueryProjects filters map rows
    // by currentUserId, so a fabricated id would be correctly REJECTED by
    // the code under test. Random only when no directory exists.
    let me = GroupDirectory.currentUserId() ?? UUID(), teammate = UUID()
    // I call it "engram"; the group calls it "Engram"; my teammate's folder
    // is "engram-fork".
    try ctx.spokes[0].lattice.add(GroupProjectMap(memberUserId: me,
                                                  localProject: "engram",
                                                  groupProject: "Engram"))
    try ctx.spokes[0].lattice.add(GroupProjectMap(memberUserId: teammate,
                                                  localProject: "engram-fork",
                                                  groupProject: "Engram"))
    // An unrelated repo that happens to share nobody's name.
    try ctx.spokes[0].lattice.add(GroupProjectMap(memberUserId: teammate,
                                                  localProject: "other",
                                                  groupProject: "Other"))

    let resolved = await ctx.tools.resolveQueryProjects("engram")
    #expect(resolved.contains("engram"))
    #expect(resolved.contains("engram-fork"),
            "a teammate's local name for the same group project was not resolved")
    #expect(!resolved.contains("other"),
            "an unrelated group project leaked into the query scope")
}

@Test func unmappedProjectResolvesToItselfOnly() async throws {
    let ctx = try await makeGroupTools()
    let resolved = await ctx.tools.resolveQueryProjects("solo")
    #expect(resolved == ["solo"])
}

@Test func recallBoostsATeammatesDifferentlyNamedCopyOfTheSameProject() async throws {
    let ctx = try await makeGroupTools()
    // The REAL signed-in id when ~/.claude/sync/groups.json exists on this
    // machine (the daemon writes it): resolveQueryProjects filters map rows
    // by currentUserId, so a fabricated id would be correctly REJECTED by
    // the code under test. Random only when no directory exists.
    let me = GroupDirectory.currentUserId() ?? UUID(), teammate = UUID()
    try ctx.spokes[0].lattice.add(GroupProjectMap(memberUserId: me,
                                                  localProject: "engram",
                                                  groupProject: "Engram"))
    try ctx.spokes[0].lattice.add(GroupProjectMap(memberUserId: teammate,
                                                  localProject: "engram-fork",
                                                  groupProject: "Engram"))
    // Same subject, three projects. Only the mapped one should rank with
    // the same-project boost.
    try await addMemory("sqlite attaches are capped at ten databases",
                        project: "engram-fork", author: teammate, to: ctx.spokes[0].lattice)
    try await addMemory("sqlite attaches are capped at ten databases here too",
                        project: "unrelated", author: teammate, to: ctx.spokes[0].lattice)

    let out = text(from: try await ctx.tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("sqlite attach cap"), "project": .string("engram"),
                    "limit": .int(2)])))
    let mappedIdx = try #require(out.range(of: "engram-fork/general")).lowerBound
    let unrelatedIdx = try #require(out.range(of: "unrelated/general")).lowerBound
    #expect(mappedIdx < unrelatedIdx,
            "the teammate's copy of MY project did not outrank an unrelated project")
}

// MARK: - Attach ceiling

@Test func moreSpokesThanSQLiteAllowsStillServesReads() async throws {
    // SQLITE_MAX_ATTACHED is 10. Nine spokes must degrade to a capped union
    // that still WORKS — the failure mode to avoid is readLattice throwing
    // and every read silently falling back to local-only.
    let ctx = try await makeGroupTools(spokeCount: 9)
    for (index, spoke) in ctx.spokes.enumerated() {
        try await addMemory("spoke number \(index) recorded the checkpoint cadence",
                            project: "engram", author: UUID(), to: spoke.lattice)
    }
    let out = text(from: try await ctx.tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: ["query": .string("checkpoint cadence"), "project": .string("engram"),
                    "limit": .int(20)])))
    let seen = (0..<9).filter { out.contains("spoke number \($0) ") }
    #expect(seen.count == MemoryTools.maxAttachments,
            "expected exactly the attach budget to be served, saw \(seen.count)")
}
