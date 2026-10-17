import Testing
import EngramKit
import EngramModels
import Lattice
import MCP
import Foundation

/// These tests open the LIVE production databases (~/.claude/memory.sqlite
/// and the synced DB) and several WRITE to them. A plain `swift test` must
/// never mutate real user data, so they are disabled unless the developer
/// explicitly opts in with ENGRAM_ALLOW_PROD_DB_TESTS=1 (and ideally points
/// HOME at a scratch copy). Without the flag Swift Testing skips them.
private let allowProdDBTests = ProcessInfo.processInfo.environment["ENGRAM_ALLOW_PROD_DB_TESTS"] == "1"

/// Reproduce the hooks crash: getField on objects from attached UNION ALL view
@Test(.enabled(if: allowProdDBTests)) func attachedView_propertyAccess() async throws {
    let localPath = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: ".claude/memory.sqlite")
    let syncedPath = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: ".claude/sync/memory-synced.sqlite")
    guard FileManager.default.fileExists(atPath: localPath.path(percentEncoded: false)),
          FileManager.default.fileExists(atPath: syncedPath.path(percentEncoded: false)) else { return }

    let localLattice = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self,
                                   configuration: .init(fileURL: localPath, migration: engramMigrations))
    let syncedLattice = try Lattice(Memory.self, Edge.self, SyncConfig.self,
                                    configuration: .init(fileURL: syncedPath, migration: engramMigrations))

    let combined = try localLattice.attaching(lattice: syncedLattice)

    // This is exactly what handleRecall does — nearest then read properties
    let embedder = sharedEmbedder
    if await !embedder.isLoaded { await embedder.load() }
    let queryEmbedding = try await embedder.embed(text: "Lattice architecture")!
    let embedding = Vector<Float>(queryEmbedding)

    // Try many different queries to trigger the crash
    let queries = [
        "Lattice architecture",
        "vec0 IVF vector search performance",
        "Swift Observable crash setter",
        "sync WebSocket relay",
        "memory maintenance consolidation",
        "debugging crash SIGTRAP",
        "EngramSceneKit GPU force simulation",
        "Claude Code hooks advise",
        "SQLite WAL checkpoint busy",
        "Darwin notification cross-process",
    ]

    for (qi, q) in queries.enumerated() {
        let qEmbed = try await embedder.embed(text: q)!
        let embedding = Vector<Float>(qEmbed)
        let nearest = combined.objects(Memory.self)
            .distinct(by: \.globalId)
            .where { $0.expiresAt > Date() }
            .nearest(to: embedding, on: \.embedding, limit: 15, distance: .l2)

        let snapshot = nearest.snapshot()
        for (i, match) in snapshot.enumerated() {
            let m = match.object
            let ac = m.accessCount
            let imp = m.importance
            let la = m.lastAccessedAt
            let proj = m.project
            _ = m.topic
            _ = m.content
            if qi == 0 && i < 3 {
                print("  q[\(qi)] \(i): ac=\(ac) imp=\(imp) proj=\(proj) la=\(la)")
            }
        }
        print("Query \(qi) (\(q.prefix(20))...): \(snapshot.count) results, all properties read OK")
    }
}

/// Simulate the hooks pattern: open DB, quick property read/write, close, repeat rapidly
@Test(.timeLimit(.minutes(1)), .enabled(if: allowProdDBTests))
func hooks_rapidOpenAndWrite() async throws {
    let localPath = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: ".claude/memory.sqlite")
    guard FileManager.default.fileExists(atPath: localPath.path(percentEncoded: false)) else { return }

    for i in 0..<20 {
        // Each iteration simulates a hooks process opening and closing the DB
        let lattice = try Lattice(
            Memory.self, Edge.self, Checkpoint.self, HookState.self, SessionState.self,
            configuration: .init(fileURL: localPath, migration: engramMigrations))

        // Quick read — like getSessionState or getHookState
        if let state = lattice.objects(HookState.self).first {
            _ = state.value
            _ = state.key
        }

        // Quick write — like setHookState
        if let state = lattice.objects(HookState.self).where({ $0.key == .maintenanceActive }).first {
            state.updatedAt = Date()
        }

        print("Iteration \(i): open + read + write OK")
        // lattice dropped here — simulates hooks process exit
    }
}

/// Test the exact hooks crash: write to SessionState.toolCallCount and HookState.updatedAt
@Test(.enabled(if: allowProdDBTests)) func hooks_sessionStateAndHookStateWrites() async throws {
    let localPath = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: ".claude/memory.sqlite")
    guard FileManager.default.fileExists(atPath: localPath.path(percentEncoded: false)) else { return }

    for i in 0..<20 {
        let lattice = try Lattice(
            Memory.self, Edge.self, Checkpoint.self, HookState.self, SessionState.self,
            configuration: .init(fileURL: localPath, migration: engramMigrations))

        // Exactly what throttledLearningNudge does
        let sessionId = "test-\(UUID().uuidString)"
        let state = SessionState(sessionId: sessionId)
        try lattice.add(state)
        state.toolCallCount += 1
        state.updatedAt = Date()
        print("SessionState write \(i) OK: toolCallCount=\(state.toolCallCount)")

        // Exactly what setHookState does
        let hook = HookState(key: .maintenanceActive, value: "test-\(i)")
        try lattice.add(hook)
        hook.updatedAt = Date()
        hook.value = "updated-\(i)"
        print("HookState write \(i) OK: value=\(hook.value)")

        // Clean up
        lattice.delete(state)
        lattice.delete(hook)
    }
}

/// Reproduce the exact throttledLearningNudge path on the production DB.
/// openLattice → getSessionState → toolCallCount += 1
@Test(.enabled(if: allowProdDBTests)) func hooks_throttledLearningNudge_productionDB() async throws {
    let dbPath = NSHomeDirectory() + "/.claude/memory.sqlite"
    guard FileManager.default.fileExists(atPath: dbPath) else { return }

    for i in 0..<20 {
        // Exactly what openLattice() does
        let lattice = try Lattice(
            Memory.self, Edge.self, Checkpoint.self, HookState.self, SessionState.self,
            configuration: .init(fileURL: URL(fileURLWithPath: dbPath), migration: engramMigrations))

        // Exactly what getSessionState() does
        let sessionId = "test-hooks-\(i)"
        let state: SessionState
        if let existing = lattice.objects(SessionState.self).where({ $0.sessionId == sessionId }).first {
            state = existing
        } else {
            state = SessionState(sessionId: sessionId)
            try lattice.add(state)
        }

        // Exactly what throttledLearningNudge() does — THIS is the crash site
        state.toolCallCount += 1
        state.updatedAt = Date()
        let tc = state.toolCallCount
        let lnl = state.learningNudgeLastToolCount
        print("Iter \(i): toolCallCount=\(tc), lastNudge=\(lnl)")

        // Clean up test session state
        lattice.delete(state)
    }
}

/// Simulate concurrent hooks + MCP server on same DB
@Test(.timeLimit(.minutes(1)), .enabled(if: allowProdDBTests))
func hooks_concurrentOpenAndRecall() async throws {
    let localPath = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: ".claude/memory.sqlite")
    guard FileManager.default.fileExists(atPath: localPath.path(percentEncoded: false)) else { return }

    let embedder = sharedEmbedder
    if await !embedder.isLoaded { await embedder.load() }

    // Open a "long-lived" lattice like the MCP server would
    let mcp = try Lattice(
        Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self,
        configuration: .init(fileURL: localPath, migration: engramMigrations))

    // Concurrent: hooks opens/closes rapidly while MCP does a recall
    await withTaskGroup(of: Void.self) { group in
        // MCP recall task
        group.addTask {
            let qEmbed = try! await embedder.embed(text: "test query")!
            let embedding = Vector<Float>(qEmbed)
            let nearest = mcp.objects(Memory.self)
                .nearest(to: embedding, on: \.embedding, limit: 10)
            for match in nearest.snapshot() {
                _ = match.object.accessCount
                _ = match.object.project
                match.object.accessCount += 1
            }
            print("MCP recall done")
        }

        // Hooks task — rapid open/close
        group.addTask {
            for i in 0..<5 {
                let hooks = try! Lattice(
                    Memory.self, Edge.self, Checkpoint.self, HookState.self, SessionState.self,
                    configuration: .init(fileURL: localPath, migration: engramMigrations))
                if let state = hooks.objects(SessionState.self).first {
                    state.toolCallCount += 1
                }
                print("Hooks iteration \(i) done")
            }
        }
    }
    print("All concurrent tasks done")
}

/// Reproduce the MCP recall crash: repeated attaching + writes on production DBs.
@Test(.timeLimit(.minutes(1)), .enabled(if: allowProdDBTests))
func attachRace_productionDB_repeatedRecall() async throws {
    let localPath = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: ".claude/memory.sqlite")
    let syncedPath = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: ".claude/sync/memory-synced.sqlite")
    guard FileManager.default.fileExists(atPath: localPath.path(percentEncoded: false)),
          FileManager.default.fileExists(atPath: syncedPath.path(percentEncoded: false)) else { return }

    let localLattice = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self,
                                   configuration: .init(fileURL: localPath, migration: engramMigrations))
    let syncedLattice = try Lattice(Memory.self, Edge.self, SyncConfig.self,
                                    configuration: .init(fileURL: syncedPath, migration: engramMigrations))

    let embedder = sharedEmbedder
    if await !embedder.isLoaded { await embedder.load() }

    let tools = MemoryTools(
        localRef: localLattice.sendableReference,
        syncedRef: syncedLattice.sendableReference,
        embedder: embedder,
        identity: GroupDirectoryIdentityProvider()
    )

    // Rapid-fire recall — each creates a temporary attached Lattice
    for i in 0..<10 {
        let result = try await tools.handle(CallTool.Parameters(
            name: "recall",
            arguments: [
                "query": .string("Lattice architecture and patterns"),
                "project": .string("Lattice"),
                "limit": .int(3),
            ]
        ))
        let output = text(from: result)
        print("Recall \(i): \(output.prefix(80))...")
    }
}
