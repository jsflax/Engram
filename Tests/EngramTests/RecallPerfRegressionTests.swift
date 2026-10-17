import Testing
import EngramKit
import EngramMemoryCore
import EngramModels
import Lattice
import MCP
import Foundation

// MARK: - Recall statement budget + access-stat + output-shape regressions
//
// Guards the 0.13.3 recall rewrite: materialized reads (row cache) collapse
// the old one-statement-per-field-per-memory pattern (~250-300 statements per
// depth-1 recall, each paying an O(WAL) scan — 228s observed in production)
// into O(K + C + F) statements, and the access-stat bumps move into ONE
// batched transaction on the objects' own connection.
//
// The statement counter is process-global, so this suite is serialized.

@Suite("Recall perf regression", .serialized)
struct RecallPerfRegressionTests {

    /// Build tools while keeping a handle on the backing lattice for
    /// post-recall DB assertions (makeTools() hides it).
    private func makeInspectableTools() async throws -> (MemoryTools, Lattice) {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "recall-perf-\(UUID().uuidString).sqlite")
        let lattice = try Lattice(
            Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self,
            configuration: .init(fileURL: path))
        let embedder = sharedEmbedder
        if await !embedder.isLoaded { await embedder.load() }
        return (MemoryTools(localRef: lattice.sendableReference, syncedRef: nil, embedder: embedder,
            identity: StaticIdentityProvider(.anonymous)), lattice)
    }

    @discardableResult
    private func remember(_ tools: MemoryTools, _ content: String,
                          project: String = "PerfProj") async throws -> String {
        let r = try await tools.handle(CallTool.Parameters(
            name: "remember",
            arguments: [
                "content": .string(content),
                "project": .string(project),
                "force": .bool(true),
            ]))
        let id = extractId(from: text(from: r))
        #expect(id != nil, "remember did not return an id")
        return id ?? ""
    }

    private func connect(_ tools: MemoryTools, from: String, to: String,
                         relation: String = "part_of") async throws {
        _ = try await tools.handle(CallTool.Parameters(
            name: "connect",
            arguments: [
                "from": .string(from),
                "to": .string(to),
                "relation": .string(relation),
            ]))
    }

    // 1. Statement budget: a depth-1 recall must be O(K+C+F) statements,
    //    not O(fields × memories).
    @Test func recall_statementBudget() async throws {
        let (tools, _) = try await makeInspectableTools()

        var ids: [String] = []
        for i in 0..<12 {
            ids.append(try await remember(tools,
                "Budget memory \(i): lattice recall performance instrumentation alpha beta gamma delta"))
        }
        for i in 1..<7 {
            try await connect(tools, from: ids[i], to: ids[0])
        }

        // The counter is process-global and OTHER suites run in parallel with
        // this one (.serialized only orders tests within the suite) — and
        // their pollution is SUSTAINED, not bursty, so no in-window trick is
        // reliable under a full parallel run. CI therefore skips this test in
        // the parallel invocation and runs it alone in a quiet second
        // invocation (release.yml). The min-of-3 below still guards against
        // incidental noise (daemons, etc.) in that quiet run. The recall is
        // async (thread-hopping), so the thread-local counter cannot be used.
        var used = UInt64.max
        var output = ""
        for _ in 0..<3 {
            let base = Lattice.totalSQLStatementCount
            let result = try await tools.handle(CallTool.Parameters(
                name: "recall",
                arguments: [
                    "query": .string("lattice recall performance instrumentation alpha"),
                    "project": .string("PerfProj"),
                    "limit": .int(5),
                    "depth": .int(1),
                ]))
            used = min(used, Lattice.totalSQLStatementCount - base)
            output = text(from: result)
        }

        #expect(output.contains("distance:"), "recall returned no results: \(output.prefix(200))")
        // Pre-rewrite, a recall of this shape issued ~250-300 statements
        // (one per field per direct + connected memory, content re-read 4x,
        // embedding BLOBs twice per traversal candidate).
        //
        // Recalibrated for embedding space v2 (Aug 2026): the wider v2
        // relevance bands admit more rows into traversal and the access-stat
        // bump, so the per-row sections grew with ROW COUNT, not with
        // per-field regressions. Measured breakdown at 160 total for this
        // fixture (12 direct / 6 connected / 11 bumped):
        //   KNN + snapshot hydration   ~25
        //   direct materialize          12   (1/row, by design)
        //   graph traversal             ~40  (edges + candidate hydration)
        //   access-stat bump txn        ~82  (~7.5/row — the known fat: each
        //        property set + increment issues its own statement cluster;
        //        a Lattice-side bulk UPDATE..WHERE IN would collapse this)
        //   everything else              ~0  (boost, capture, render ride
        //        the row caches)
        // Budget = measured + slack; still an order of magnitude under the
        // pre-rewrite O(fields × memories) failure mode this test guards.
        #expect(used <= 180, "recall issued \(used) SQL statements — statement-budget regression")
    }

    // 2. Access stats: every direct AND connected memory is bumped exactly
    //    once, through the batched transaction on the objects' own handle.
    //    (The old per-loop localLattice transaction silently wrapped nothing
    //    for attached-lattice objects.)
    @Test func recall_bumpsAccessStatsOnce() async throws {
        let (tools, lattice) = try await makeInspectableTools()

        let hub = try await remember(tools,
            "Hub memory about sqlite checkpoint truncation strategies and WAL maintenance")
        // Children with deliberately unrelated content: they must arrive via
        // the structural part_of edge, not as direct hits.
        let child1 = try await remember(tools, "Completely unrelated gardening note about tulip bulbs")
        let child2 = try await remember(tools, "Another unrelated note about sourdough hydration ratios")
        try await connect(tools, from: child1, to: hub)
        try await connect(tools, from: child2, to: hub)

        let before = Date()
        _ = try await tools.handle(CallTool.Parameters(
            name: "recall",
            arguments: [
                "query": .string("sqlite checkpoint truncation WAL maintenance"),
                "project": .string("PerfProj"),
                "limit": .int(1),
                "depth": .int(1),
            ]))

        let all = lattice.objects(Memory.self).snapshot()
        let byId = Dictionary(uniqueKeysWithValues: all.compactMap { m -> (String, Memory)? in
            guard let gid = m.globalId else { return nil }
            return (gid.uuidString, m)
        })
        for (label, id) in [("hub", hub), ("child1", child1), ("child2", child2)] {
            let m = try #require(byId[id.uppercased()] ?? byId[id], "\(label) missing")
            #expect(m.accessCount == 1, "\(label) accessCount == \(m.accessCount), expected exactly 1")
            #expect(m.lastAccessedAt >= before, "\(label) lastAccessedAt not bumped")
        }
    }

    // 3. Output shape for large connected memories: compact preview with
    //    section/char counts, 120-char first line, ellipsis — unchanged by
    //    the read-once rewrite.
    @Test func recall_outputParity_largeContent() async throws {
        let (tools, _) = try await makeInspectableTools()

        let hub = try await remember(tools,
            "Hub for parity: release train verification checklist for lattice")
        let firstLine = "Parity child first line: engraved summary of the release verification steps"
        let bigBody = firstLine + "\n" +
            (1...6).map { "## Section \($0)\n" + String(repeating: "detail \($0) ", count: 20) }
                   .joined(separator: "\n")
        #expect(bigBody.count > 500)
        let child = try await remember(tools, bigBody)
        try await connect(tools, from: child, to: hub)

        let result = try await tools.handle(CallTool.Parameters(
            name: "recall",
            arguments: [
                "query": .string("release train verification checklist lattice"),
                "project": .string("PerfProj"),
                "limit": .int(1),
                "depth": .int(1),
            ]))
        let output = text(from: result)

        #expect(output.contains("--- Connected (graph traversal, depth: 1) ---"),
                "connected section missing: \(output.prefix(300))")
        #expect(output.contains("6 sections, \(bigBody.count) chars"),
                "compact preview header changed")
        #expect(output.contains(String(firstLine.prefix(120))), "first-line preview changed")
        #expect(output.contains("..."), "ellipsis suffix missing for large content")
        #expect(!output.contains("## Section 3"),
                "large connected memory leaked full content instead of preview")
    }
}
