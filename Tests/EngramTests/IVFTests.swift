import Testing
import EngramKit
import EngramMemoryCore
import EngramModels
import Lattice
import MCP
import Foundation

/// Tests suffixed with the prod-DB variants open the LIVE ~/.claude databases
/// and several write to them; gate them behind ENGRAM_ALLOW_PROD_DB_TESTS=1 so
/// a plain `swift test` never mutates real user data.
private let allowProdDBTests = ProcessInfo.processInfo.environment["ENGRAM_ALLOW_PROD_DB_TESTS"] == "1"

// MARK: - IVF Vector Index Tests

@Test func ivf_trainAndRecallPattern() async throws {
    let tools = try await makeTools()

    // Insert 50 memories with embeddings (like production)
    for i in 0..<50 {
        _ = try await tools.handle(CallTool.Parameters(
            name: "remember",
            arguments: [
                "content": .string("Test memory number \(i) about topic \(i % 5)"),
                "topic": .string("test-ivf"),
                "project": .string("test"),
            ]
        ))
    }

    // Train IVF
    let trainResult = try await tools.handle(CallTool.Parameters(
        name: "train_vectors",
        arguments: [:]
    ))
    let trainOutput = text(from: trainResult)
    #expect(trainOutput.contains("trained"), "Should report training complete")

    // Recall — this does nearest() → read properties → write accessCount/lastAccessedAt
    let recallResult = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: [
            "query": .string("test memory about topic"),
            "project": .string("test"),
            "limit": .int(5),
        ]
    ))
    let recallOutput = text(from: recallResult)
    #expect(!recallOutput.contains("No memories"), "Recall should find results after IVF training")
}

@Test(.enabled(if: allowProdDBTests)) func ivf_productionDB_recallPerformance() async throws {
    let localPath = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: ".claude/memory.sqlite")
    let syncedPath = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: ".claude/sync/memory-synced.sqlite")
    guard FileManager.default.fileExists(atPath: localPath.path(percentEncoded: false)) else { return }

    let localLattice = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self,
                                   configuration: .init(fileURL: localPath, migration: engramMigrations))

    // Open synced DB if it exists (same as production MCP server)
    var syncedLattice: Lattice? = nil
    if FileManager.default.fileExists(atPath: syncedPath.path(percentEncoded: false)) {
        syncedLattice = try Lattice(Memory.self, Edge.self, SyncConfig.self,
                                    configuration: .init(fileURL: syncedPath, migration: engramMigrations))
    }

    let embedder = sharedEmbedder
    if await !embedder.isLoaded { await embedder.load() }

    // Use the MCP tool path — creates MemoryTools with dual DB, calls recall
    let toolsStart = ContinuousClock.now
    let tools = MemoryTools(
        localRef: localLattice.sendableReference,
        syncedRef: syncedLattice?.sendableReference,
        embedder: embedder,
        identity: GroupDirectoryIdentityProvider()
    )
    let toolsElapsed = ContinuousClock.now - toolsStart
    print("MemoryTools init: \(Double(toolsElapsed.components.seconds)*1000 + Double(toolsElapsed.components.attoseconds)/1e15) ms")

    // Test without project filter (no attaching)
    let start1 = ContinuousClock.now
    let result1 = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: [
            "query": .string("Lattice IVF vector search implementation"),
            "limit": .int(5),
        ]
    ))
    let elapsed1 = ContinuousClock.now - start1

    // Test WITH project filter (triggers attaching for synced projects)
    let start2 = ContinuousClock.now
    let result2 = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: [
            "query": .string("Lattice IVF vector search implementation"),
            "project": .string("Lattice"),
            "limit": .int(5),
        ]
    ))
    let elapsed2 = ContinuousClock.now - start2

    func ms(_ d: Duration) -> String {
        String(format: "%.0f", Double(d.components.seconds) * 1000.0 + Double(d.components.attoseconds) / 1e15)
    }

    let output = text(from: result2)
    print("=== Engram MCP Recall (production DB) ===")
    print("  no project filter:   \(ms(elapsed1)) ms")
    print("  with project filter: \(ms(elapsed2)) ms")
    print("  output: \(output.prefix(200))...")
    #expect(!output.contains("No memories"))
}

/// Verify that Collection.map on nearest results doesn't crash with index out of bounds.
/// endIndex must match the actual number of results snapshot() returns.
@Test(.enabled(if: allowProdDBTests)) func ivf_productionDB_collectionMapSafe() async throws {
    let localPath = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: ".claude/memory.sqlite")
    guard FileManager.default.fileExists(atPath: localPath.path(percentEncoded: false)) else { return }
    let lattice = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self,
                              configuration: .init(fileURL: localPath, migration: engramMigrations))

    let dims = 384
    let query = Vector<Float>((0..<dims).map { _ in Float.random(in: -1...1) })
    let nearest = lattice.objects(Memory.self)
        .nearest(to: query, on: \.embedding, limit: 15)

    // This is what handleRecall does — .map on the nearest results
    // If endIndex > actual results, this crashes with index out of bounds
    let mapped = nearest.map { match -> (object: Memory, distance: Double) in
        (object: match.object, distance: match.distance)
    }
    print("count=\(nearest.count), mapped=\(mapped.count)")
    #expect(nearest.count == mapped.count, "count and map should agree")
}

@Test(.enabled(if: allowProdDBTests)) func ivf_productionDB_plainObjectsWrite() async throws {
    let path = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: ".claude/memory.sqlite")
    guard FileManager.default.fileExists(atPath: path.path(percentEncoded: false)) else { return }

    let lattice = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self,
                              configuration: .init(fileURL: path, migration: engramMigrations))

    // No nearest/IVF — just plain objects query + write
    let memories = lattice.objects(Memory.self).snapshot(limit: 10, offset: 0)
    for (i, m) in memories.enumerated() {
        print("Writing \(i): pk=\(m.primaryKey ?? -1)")
        m.lastAccessedAt = Date()
        m.accessCount += 1
        print("  ok")
    }
}

@Test(.enabled(if: allowProdDBTests)) func ivf_productionDB_basicReadWrite() async throws {
    let path = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: ".claude/memory.sqlite")
    guard FileManager.default.fileExists(atPath: path.path(percentEncoded: false)) else { return }

    let lattice = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self,
                              configuration: .init(fileURL: path, migration: engramMigrations))

    // Step 1: basic count
    let count = lattice.objects(Memory.self).count
    print("Production DB has \(count) memories")
    #expect(count > 0)

    // Step 2: read one object
    let first = lattice.objects(Memory.self).first!
    let title = first.content
    let ac = first.accessCount
    print("First memory: content=\(title.prefix(50)), accessCount=\(ac)")

    // Step 3: write accessCount (this is what crashes in hooks)
    first.accessCount = ac + 1
    #expect(first.accessCount == ac + 1)

    // Step 4: write date
    first.lastAccessedAt = Date()
    print("Write succeeded")
}

@Test(.enabled(if: allowProdDBTests)) func ivf_recallOnProductionDB() async throws {
    let path = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: ".claude/memory.sqlite")
    guard FileManager.default.fileExists(atPath: path.path(percentEncoded: false)) else {
        print("Skipping: production DB not found at \(path.path(percentEncoded: false))")
        return
    }
    let lattice = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self,
                              configuration: .init(fileURL: path, migration: engramMigrations))

    let dims = 384
    let query = Vector<Float>((0..<dims).map { _ in Float.random(in: -1...1) })
    let nearest = lattice.objects(Memory.self)
        .nearest(to: query, on: \.embedding, limit: 10)
    let snapshot = nearest.snapshot()
    #expect(snapshot.count > 0)

    // Write each one individually to isolate which crashes
    for (i, match) in snapshot.enumerated() {
        let m = match.object
        print("Writing \(i): pk=\(m.primaryKey ?? -1) ac=\(m.accessCount)")
        m.lastAccessedAt = Date()
        m.accessCount += 1
        print("  ok")
    }
}

@Test(.enabled(if: allowProdDBTests)) func ivf_dualDB_recallAfterTraining() async throws {
    let localPath = FileManager.default.temporaryDirectory
        .appending(path: "ivf-dual-local-\(UUID().uuidString).sqlite")
    let syncedPath = FileManager.default.temporaryDirectory
        .appending(path: "ivf-dual-synced-\(UUID().uuidString).sqlite")

    let localLattice = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self,
                                   configuration: .init(fileURL: localPath))
    let syncedLattice = try Lattice(Memory.self, Edge.self, SyncConfig.self,
                                    configuration: .init(fileURL: syncedPath))

    let embedder = sharedEmbedder
    if await !embedder.isLoaded { await embedder.load() }

    let dims = 384
    // Insert into local
    for i in 0..<20 {
        let mem = Memory(content: "Local memory \(i)")
        mem.embedding = Vector<Float>((0..<dims).map { _ in Float.random(in: -1...1) })
        try localLattice.add(mem)
    }
    // Insert into synced
    for i in 0..<20 {
        let mem = Memory(content: "Synced memory \(i)")
        mem.embedding = Vector<Float>((0..<dims).map { _ in Float.random(in: -1...1) })
        try syncedLattice.add(mem)
    }

    // Train both
    localLattice.trainVectorIndexes()
    syncedLattice.trainVectorIndexes()

    // Create tools with dual DB (mimics production Engram)
    let tools = MemoryTools(
        localRef: localLattice.sendableReference,
        syncedRef: syncedLattice.sendableReference,
        embedder: embedder,
        identity: StaticIdentityProvider(.anonymous)
    )

    // Recall through the MCP tool (uses attaching internally)
    let result = try await tools.handle(CallTool.Parameters(
        name: "recall",
        arguments: [
            "query": .string("memory about something"),
            "limit": .int(5),
        ]
    ))
    let output = text(from: result)
    #expect(!output.contains("No memories"), "Dual-DB recall should find results after IVF training")
}
