import Testing
import EngramKit
import EngramModels
import Lattice
import Foundation

// ============================================================================
// Increment 3 — the daemon's group sync surface. These filters ARE the
// security boundary: the hub→spoke filter decides what leaves this machine
// for a given group, and the spoke→hub filter is the cross-group firewall.
// Both are asserted through real Lattice IPC relays, not by inspecting
// predicates.
// ============================================================================

private func tempDir() -> String {
    // Foundation's macOS temporaryDirectory can ignore TMPDIR. Honor the
    // native-validation fixture root explicitly, as the other memory tests do.
    let root = ProcessInfo.processInfo.environment["ENGRAM_TEST_ROOT"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory
    let dir = root.appending(path: "engram-groupsync-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
}

private func makeHub(_ claudeDir: String) throws -> Lattice {
    try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self,
                SessionState.self, SyncConfig.self,
                configuration: .init(fileURL: URL(fileURLWithPath: claudeDir + "/memory.sqlite"),
                                     migration: engramMigrations))
}

private func waitUntil(_ timeout: TimeInterval = 15, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return condition()
}

// MARK: - Naming / paths

@Test func groupChannelAndPathsAreCollisionFree() {
    let claudeDir = tempDir()
    let a = UUID(), b = UUID()
    #expect(SyncService.groupChannel(a) != SyncService.groupChannel(b))
    #expect(SyncService.groupChannel(a).hasPrefix("engram-group-"))
    // Group spokes live beside the personal spoke but can never collide
    // with it (or each other).
    let personal = SyncService.syncedDbPath(claudeDir: claudeDir)
    let spokeA = SyncService.groupDbPath(claudeDir: claudeDir, groupId: a)
    let spokeB = SyncService.groupDbPath(claudeDir: claudeDir, groupId: b)
    #expect(spokeA != personal && spokeB != personal && spokeA != spokeB)
    #expect((spokeA as NSString).deletingLastPathComponent
            == (personal as NSString).deletingLastPathComponent)
    // Retirement is a rename in place, not a delete.
    #expect(SyncService.revokedGroupDbPath(claudeDir: claudeDir, groupId: a).hasPrefix(spokeA))
}

// MARK: - Hub → spoke: exposure gates what leaves this machine

@Test func hubToSpokeRelaysOnlyExposedNonPrivateProjects() async throws {
    let claudeDir = tempDir()
    let groupId = UUID()
    let hub = try makeHub(claudeDir)

    // "shared" is exposed to THIS group; "other-group-only" to a different
    // one; "local" to none.
    try hub.add(SyncConfig(project: "shared", policy: .local,
                           exposedTeams: [groupId.uuidString]))
    try hub.add(SyncConfig(project: "other-group-only", policy: .local,
                           exposedTeams: [UUID().uuidString]))
    try hub.add(SyncConfig(project: "local", policy: .local))

    try hub.add(Memory(content: "shared knowledge", topic: "t", project: "shared"))
    try hub.add(Memory(content: "private in shared", topic: "t", project: "shared",
                       isPrivate: true))
    try hub.add(Memory(content: "belongs to another group", topic: "t",
                       project: "other-group-only"))
    try hub.add(Memory(content: "never leaves", topic: "t", project: "local"))

    // Hub fans out on this group's channel with the group filter.
    var hubConfig = Lattice.Configuration(
        fileURL: URL(fileURLWithPath: claudeDir + "/memory.sqlite"),
        migration: engramMigrations)
    hubConfig.ipcTargets = [.init(
        channel: SyncService.groupChannel(groupId),
        syncFilter: SyncService.buildGroupSyncFilter(from: hub, groupId: groupId),
        narrowingEmitsRemovals: false)]
    let hubWithIPC = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self,
                                 SessionState.self, SyncConfig.self, configuration: hubConfig)
    _ = hubWithIPC

    // Spoke on the same channel (no WSS in this test).
    var spokeConfig = Lattice.Configuration(
        fileURL: URL(fileURLWithPath: SyncService.groupDbPath(claudeDir: claudeDir, groupId: groupId)),
        migration: engramMigrations)
    spokeConfig.ipcTargets = [.init(channel: SyncService.groupChannel(groupId))]
    let spoke = try Lattice(Memory.self, Edge.self, GroupProjectMap.self, configuration: spokeConfig)

    #expect(await waitUntil { spoke.objects(Memory.self).contains { $0.content == "shared knowledge" } })
    // Everything else must NOT be there. Give the relay a moment so this
    // isn't just "hasn't arrived yet".
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    let contents = Set(spoke.objects(Memory.self).map(\.content))
    #expect(!contents.contains("private in shared"))        // isPrivate never leaves
    #expect(!contents.contains("belongs to another group"))  // other group's exposure
    #expect(!contents.contains("never leaves"))              // unexposed project
    // SyncConfig is personal-device state, not group data.
    #expect(spoke.objects(Memory.self).count == 1)
}

@Test func unexposedGroupGetsNothingRatherThanEverything() async throws {
    let claudeDir = tempDir()
    let groupId = UUID()
    let hub = try makeHub(claudeDir)
    // No exposure rows at all for this group.
    try hub.add(SyncConfig(project: "p", policy: .sync))
    try hub.add(Memory(content: "should stay home", topic: "t", project: "p"))

    var hubConfig = Lattice.Configuration(
        fileURL: URL(fileURLWithPath: claudeDir + "/memory.sqlite"),
        migration: engramMigrations)
    hubConfig.ipcTargets = [.init(
        channel: SyncService.groupChannel(groupId),
        syncFilter: SyncService.buildGroupSyncFilter(from: hub, groupId: groupId),
        narrowingEmitsRemovals: false)]
    // RETAINED. This was `_ = try Lattice(...)`, which released the hub's
    // IPC handle immediately: nothing ever relayed, so the assertion below
    // passed no matter what the filter said. An "empty means unfiltered"
    // regression sailed straight through it.
    let hubWithIPC = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self,
                                 SessionState.self, SyncConfig.self, configuration: hubConfig)

    var spokeConfig = Lattice.Configuration(
        fileURL: URL(fileURLWithPath: SyncService.groupDbPath(claudeDir: claudeDir, groupId: groupId)),
        migration: engramMigrations)
    spokeConfig.ipcTargets = [.init(channel: SyncService.groupChannel(groupId))]
    let spoke = try Lattice(Memory.self, Edge.self, GroupProjectMap.self, configuration: spokeConfig)

    try? await Task.sleep(nanoseconds: 2_000_000_000)
    // The empty-exposure filter must match NOTHING — an "empty means
    // unfiltered" bug here would ship the user's entire database.
    #expect(spoke.objects(Memory.self).isEmpty)

    // POSITIVE CONTROL. Expose the project and push the rebuilt filter down
    // the SAME channel: the row must now arrive. Without this, an empty
    // spoke is indistinguishable from a relay that never started, which is
    // exactly how this test used to fail open.
    if let config = hub.objects(SyncConfig.self).where({ $0.project == "p" }).first {
        config.exposedGroups = [groupId.uuidString]
    }
    hubWithIPC.updateSyncFilter(
        SyncService.buildGroupSyncFilter(from: hub, groupId: groupId),
        forChannel: SyncService.groupChannel(groupId))
    #expect(await waitUntil {
        spoke.objects(Memory.self).contains { $0.content == "should stay home" }
    }, "positive control failed: the relay was never live, so the emptiness asserted above proves nothing")
}

// MARK: - Spoke → hub: the cross-group firewall

@Test func spokeToHubUploadsOnlyMyOwnMemories() async throws {
    let claudeDir = tempDir()
    let groupId = UUID()
    let me = UUID(), teammate = UUID()
    let hub = try makeHub(claudeDir)
    try hub.add(SyncConfig(project: "shared", policy: .local,
                           exposedTeams: [groupId.uuidString]))

    var hubConfig = Lattice.Configuration(
        fileURL: URL(fileURLWithPath: claudeDir + "/memory.sqlite"),
        migration: engramMigrations)
    hubConfig.ipcTargets = [.init(
        channel: SyncService.groupChannel(groupId),
        syncFilter: SyncService.buildGroupSyncFilter(from: hub, groupId: groupId),
        narrowingEmitsRemovals: false)]
    let hubWithIPC = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self,
                                 SessionState.self, SyncConfig.self, configuration: hubConfig)

    // Spoke carries the authored-by-me firewall, exactly as
    // openGroupLattice configures it.
    var spokeConfig = Lattice.Configuration(
        fileURL: URL(fileURLWithPath: SyncService.groupDbPath(claudeDir: claudeDir, groupId: groupId)),
        migration: engramMigrations)
    spokeConfig.ipcTargets = [.init(
        channel: SyncService.groupChannel(groupId),
        syncFilter: SyncService.buildSpokeToHubFilter(me: me),
        narrowingEmitsRemovals: false)]
    let spoke = try Lattice(Memory.self, Edge.self, GroupProjectMap.self, configuration: spokeConfig)

    // Simulate the relay delivering a teammate's row plus an edit of mine.
    try spoke.add(Memory(content: "teammate memory", topic: "t", project: "shared",
                         authorUserId: teammate))
    try spoke.add(Memory(content: "my memory back from the group", topic: "t",
                         project: "shared", authorUserId: me))
    // A group-only edge (endpoints may not exist in the hub at all).
    try spoke.add(Edge(sourceGlobalId: UUID(), targetGlobalId: UUID(), relation: .relatesTo,
                       authorUserId: me))
    try spoke.add(GroupProjectMap(memberUserId: me, localProject: "shared",
                                  groupProject: "shared"))

    #expect(await waitUntil {
        hubWithIPC.objects(Memory.self).contains { $0.content == "my memory back from the group" }
    })
    try? await Task.sleep(nanoseconds: 1_500_000_000)

    // The teammate's memory must NOT reach the hub — otherwise the hub's
    // other group channels would re-export it (the cross-group leak).
    #expect(!hubWithIPC.objects(Memory.self).contains { $0.content == "teammate memory" })
    // Edges never travel spoke→hub (they would dangle) and the map table
    // isn't even in the hub's schema.
    let hubEdgeAuthors = hubWithIPC.objects(Edge.self).compactMap(\.authorUserId)
    #expect(!hubEdgeAuthors.contains(me) || hubWithIPC.objects(Edge.self).isEmpty)
}

// MARK: - Directory file

@Test func groupsJsonRoundTripsThroughGroupDirectory() throws {
    let claudeDir = tempDir()
    let selfId = UUID(), teammate = UUID()
    let groupId = UUID(), childId = UUID()
    let snapshot = GroupDirectorySync.Snapshot(
        selfUserId: selfId,
        groups: [
            .init(id: groupId, name: "canary", parentId: nil, myRole: "owner", root: true),
            .init(id: childId, name: "team-ios", parentId: groupId, myRole: "member", root: false),
        ],
        members: [teammate.uuidString: "Ada Lovelace", selfId.uuidString: "Me"])
    try GroupDirectorySync.write(snapshot, claudeDir: claudeDir)

    let path = (SyncService.syncedDbPath(claudeDir: claudeDir) as NSString)
        .deletingLastPathComponent + "/groups.json"
    // 0600: the readers are short-lived hook processes, and this is the
    // file that says who you are.
    let perms = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber
    #expect(perms?.int16Value == 0o600)

    // The consumer side (hooks/MCP) must read exactly what the daemon wrote.
    let file = GroupDirectory.load(from: URL(fileURLWithPath: path))
    #expect(file?.selfUserId == selfId)
    #expect(file?.groups.count == 2)
    #expect(file?.groups.first { $0.id == childId }?.parentId == groupId)
    #expect(file?.members[teammate.uuidString] == "Ada Lovelace")
}

@Test func groupsJsonCarriesLinkProvenanceAndToleratesItsAbsence() throws {
    let claudeDir = tempDir()
    let selfId = UUID(), team = UUID(), concept = UUID()
    let snapshot = GroupDirectorySync.Snapshot(
        selfUserId: selfId,
        groups: [
            .init(id: team, name: "team-ios", parentId: nil, myRole: "member", root: true),
            .init(id: concept, name: "mobile", parentId: nil, myRole: "member",
                  root: true, viaLink: true, linkedFrom: [team]),
        ],
        members: [:])
    try GroupDirectorySync.write(snapshot, claudeDir: claudeDir)
    let path = (SyncService.syncedDbPath(claudeDir: claudeDir) as NSString)
        .deletingLastPathComponent + "/groups.json"

    let file = GroupDirectory.load(from: URL(fileURLWithPath: path))
    let mobile = file?.groups.first { $0.id == concept }
    #expect(mobile?.viaLink == true)
    #expect(mobile?.linkedFrom == [team])
    // Tree-membership entries stay unmarked.
    #expect(file?.groups.first { $0.id == team }?.viaLink == nil)

    // Legacy file WITHOUT the new keys still decodes (old daemon, new hooks).
    let legacy = """
    {"selfUserId":"\(selfId.uuidString)","updatedAt":"2026-08-05T12:00:00Z",
     "groups":[{"id":"\(team.uuidString)","name":"team-ios","root":true}],
     "members":{}}
    """
    let legacyURL = URL(fileURLWithPath: path + ".legacy")
    try legacy.data(using: .utf8)!.write(to: legacyURL)
    let legacyFile = GroupDirectory.load(from: legacyURL)
    #expect(legacyFile?.groups.first?.viaLink == nil)
    #expect(legacyFile?.groups.first?.name == "team-ios")
}

@Test func refreshMarkerIsConsumedExactlyOnce() throws {
    let claudeDir = tempDir()
    let syncDir = (SyncService.syncedDbPath(claudeDir: claudeDir) as NSString)
        .deletingLastPathComponent
    #expect(!GroupDirectorySync.consumeRefreshRequest(claudeDir: claudeDir))
    FileManager.default.createFile(atPath: syncDir + "/groups-refresh-requested", contents: Data())
    #expect(GroupDirectorySync.consumeRefreshRequest(claudeDir: claudeDir))
    // Consumed — a second poll must not re-trigger.
    #expect(!GroupDirectorySync.consumeRefreshRequest(claudeDir: claudeDir))
}
