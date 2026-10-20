import Foundation
import Testing
import Lattice
import EngramModels
import EngramLattice
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite)
import CSQLite
#endif

@Suite("Read-only selected agent memory browser")
struct AgentMemoryReaderTests {
    @Test func oversizedStoredRowsAreExcludedBeforeGraphMaterialization() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "engram-reader-budget-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binding = AgentMemoryBinding(agentId: UUID()), visibleID = UUID(), hugeID = UUID(), oversizedVectorID = UUID()
        let file = directory.appending(path: "graph.sqlite")
        let db = try Lattice(for: AgentMemoryStore.schema, configuration: AgentMemoryStore.configuration(fileURL: file))
        try db.withTransaction {
            try db.add(AgentMemoryGraph(agentId: binding.agentId, graphId: binding.graphId))
            try db.add(Memory(content: "Readable memory"), preservingGlobalId: visibleID)
            try db.add(Memory(content: String(repeating: "x", count: 1_048_577)), preservingGlobalId: hugeID)
            // Establish a real valid vector schema before introducing the damaged
            // legacy BLOB below. vec0 correctly refuses 300,000 dimensions.
            try db.add(Memory(content: "Oversized stored vector", embedding: Vector<Float>([1, 0, 1])), preservingGlobalId: oversizedVectorID)
            try db.add(Edge(sourceGlobalId: visibleID, targetGlobalId: hugeID, relation: .relatesTo))
        }
        db.checkpoint(); db.close()
        try replaceOwnedFixtureEmbedding(file: file, memoryID: oversizedVectorID,
            blob: Vector<Float>(Array(repeating: 1, count: 300_000)).toData())
        let bytes = try Data(contentsOf: file)
        let value = try AgentMemoryReader.readGraph(fileURL: file, binding: binding)
        #expect(value.memories.map(\.id) == [visibleID])
        #expect(value.totalMemoryCount == 3 && value.oversizedMemoryCount == 2)
        #expect(value.truncation == [.oversizedRecords])
        #expect(value.edges.isEmpty && value.embeddings.isEmpty)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func fullGraphCrossesPageBoundariesAndReadsOnlyExistingCurrentVectors() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "engram-full-reader-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binding = AgentMemoryBinding(agentId: UUID())
        let file = directory.appending(path: "graph.sqlite")
        let db = try Lattice(for: AgentMemoryStore.schema, configuration: AgentMemoryStore.configuration(fileURL: file))
        let ids = (0..<520).map { _ in UUID() }
        let pending = UUID(), invalid = UUID(), gone = UUID()
        try db.withTransaction {
            try db.add(AgentMemoryGraph(agentId: binding.agentId, graphId: binding.graphId))
            for (index, id) in ids.enumerated() {
                try db.add(Memory(content: "Graph memory \(index)", project: "Orbital",
                                  embedding: Vector<Float>([1, 0, Float(index)]), accessCount: 7), preservingGlobalId: id)
                if index > 0 { try db.add(Edge(sourceGlobalId: ids[0], targetGlobalId: id, relation: .relatesTo)) }
            }
            try db.add(Memory(content: "Vector pending", embedding: Vector<Float>([1, 0, 1]), embeddingPending: true), preservingGlobalId: pending)
            try db.add(Memory(content: "Invalid vector", embedding: Vector<Float>([1, 0, 1])), preservingGlobalId: invalid)
            try db.add(Memory(content: "Tombstone", deletedAt: Date()), preservingGlobalId: gone)
            try db.add(Edge(sourceGlobalId: ids[0], targetGlobalId: gone, relation: .partOf))
        }
        db.checkpoint(); db.close()
        // Ordinary vec0 admission rejects NaN. Model an already stored damaged
        // row without weakening either normal admission or the reader checks.
        try replaceOwnedFixtureEmbedding(file: file, memoryID: invalid, blob: Vector<Float>([.nan, 0, 1]).toData())
        let bytes = try Data(contentsOf: file)
        let snapshot = try AgentMemoryReader.readGraph(fileURL: file, binding: binding)
        #expect(snapshot.totalMemoryCount == 522)
        #expect(snapshot.memories.count == 522)
        #expect(Set(snapshot.memories.map(\.id)) == Set(ids + [pending, invalid]))
        #expect(snapshot.edges.count == 519)
        #expect(snapshot.embeddings.count == 520)
        #expect(snapshot.embeddings[ids[519]] == [1, 0, 519])
        #expect(snapshot.embeddings[pending] == nil && snapshot.embeddings[invalid] == nil)
        #expect(snapshot.invalidEmbeddingCount == 1 && snapshot.omittedEmbeddingCount == 1)
        #expect(snapshot.truncation.isEmpty)
        #expect(snapshot.memories.first(where: { $0.id == ids[519] })?.accessCount == 7)
        #expect(try Data(contentsOf: file) == bytes)

        let limited = try AgentMemoryReader.readGraph(fileURL: file, binding: binding,
            limits: .init(memories: 4, edges: 2, embeddingBytes: 0))
        #expect(limited.memories.count == 4 && limited.totalMemoryCount == 522)
        #expect(limited.truncation.contains(.memories) && limited.truncation.contains(.edges))
        #expect(limited.embeddings.isEmpty && limited.truncation.contains(.embeddingBytes))
        let visible = Set(limited.memories.map(\.id))
        #expect(limited.edges.allSatisfy { visible.contains($0.sourceId) && visible.contains($0.targetId) })
        let tiny = try AgentMemoryReader.readGraph(fileURL: file, binding: binding, limits: .init(contentBytes: 1))
        #expect(tiny.memories.isEmpty && tiny.truncation == [.contentBytes])
        let tinyEdges = try AgentMemoryReader.readGraph(fileURL: file, binding: binding, limits: .init(edgeBytes: 1))
        #expect(tinyEdges.memories.count == 522 && tinyEdges.edges.isEmpty)
        #expect(tinyEdges.truncation == [.edgeBytes])
        #expect(try Data(contentsOf: file) == bytes)
        #expect(throws: AgentMemoryReader.ReadError.self) {
            try AgentMemoryReader.readGraph(fileURL: file, binding: .init(agentId: UUID(), graphId: binding.graphId))
        }
    }

    @Test func searchConnectionsAndDetailLeaveGraphByteUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "engram-reader-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let graphID = UUID(), agentID = UUID(), a = UUID(), b = UUID(), gone = UUID()
        let file = directory.appending(path: graphID.uuidString.lowercased() + ".sqlite")
        let db = try Lattice(for: AgentMemoryStore.schema, configuration: AgentMemoryStore.configuration(fileURL: file))
        try db.withTransaction {
            try db.add(AgentMemoryGraph(agentId: agentID, graphId: graphID), preservingGlobalId: graphID)
            try db.add(Memory(content: "Quoted 'Avocado' memory", project: "Engram", accessCount: 9), preservingGlobalId: a)
            try db.add(Memory(content: "Related detail with full content", project: "Orbital"), preservingGlobalId: b)
            try db.add(Memory(content: "Hidden tombstone", deletedAt: Date()), preservingGlobalId: gone)
            try db.add(Edge(sourceGlobalId: a, targetGlobalId: b, relation: .derivedFrom))
            try db.add(Edge(sourceGlobalId: a, targetGlobalId: gone, relation: .relatesTo))
            try db.add(Edge(sourceGlobalId: b, targetGlobalId: a, relation: .contradicts, deletedAt: Date()))
        }
        db.checkpoint(); db.close()
        let bytes = try Data(contentsOf: file)
        let binding = AgentMemoryBinding(agentId: agentID, graphId: graphID)
        let page = try AgentMemoryReader.read(fileURL: file, binding: binding)
        #expect(Set(page.memories.map(\.id)) == [a, b])
        #expect(page.edges.count == 1)
        #expect(page.edges.first?.relation == "derived_from")
        #expect(page.memories.first(where: { $0.id == a })?.accessCount == 9)
        let search = try AgentMemoryReader.read(fileURL: file, binding: binding, query: "AVOCADO")
        #expect(search.memories.map(\.id) == [a])
        #expect(try AgentMemoryReader.read(fileURL: file, binding: binding, query: "' OR 1=1 --").memories.isEmpty)
        let detail = try AgentMemoryReader.read(fileURL: file, binding: binding, focusedID: a)
        #expect(detail.memories.first?.id == a)
        #expect(detail.memories.first(where: { $0.id == b })?.content == "Related detail with full content")
        #expect(detail.edges.count == 1)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(throws: AgentMemoryReader.ReadError.self) {
            try AgentMemoryReader.read(fileURL: file, binding: .init(agentId: UUID(), graphId: graphID))
        }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func missingGraphNeverCreatesAReplacementAndPageIsBounded() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "engram-reader-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binding = AgentMemoryBinding(agentId: UUID())
        let file = directory.appending(path: "missing.sqlite")
        #expect(throws: AgentMemoryReader.ReadError.self) { try AgentMemoryReader.read(fileURL: file, binding: binding) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let db = try Lattice(for: AgentMemoryStore.schema, configuration: AgentMemoryStore.configuration(fileURL: file))
        let ids = (0..<5).map { _ in UUID() }
        try db.withTransaction {
            try db.add(AgentMemoryGraph(agentId: binding.agentId, graphId: binding.graphId), preservingGlobalId: binding.graphId)
            for index in 0..<5 {
                try db.add(Memory(content: "Memory \(index)"), preservingGlobalId: ids[index])
                if index > 0 { try db.add(Edge(sourceGlobalId: ids[0], targetGlobalId: ids[index], relation: .partOf)) }
            }
        }
        db.checkpoint(); db.close()
        let first = try AgentMemoryReader.read(fileURL: file, binding: binding, limit: 2)
        let second = try AgentMemoryReader.read(fileURL: file, binding: binding, offset: 2, limit: 2)
        #expect(first.memories.count == 2 && first.hasMoreMemories)
        #expect(second.memories.count == 2 && second.hasMoreMemories)
        #expect(Set(first.memories.map(\.id)).isDisjoint(with: second.memories.map(\.id)))
        let focused = try AgentMemoryReader.read(fileURL: file, binding: binding, limit: 2, focusedID: ids[0])
        #expect(focused.memories.count == 2 && focused.hasMoreMemories)
        #expect(focused.memories.first?.id == ids[0])
        #expect(focused.edges.count == 1)
        #expect(throws: AgentMemoryReader.ReadError.self) { try AgentMemoryReader.read(fileURL: file, binding: binding, limit: 121) }
    }

    private enum FixtureFailure: Error {
        case sqlite(operation: String, code: Int32, message: String)
        case invariant(String)
        case sqliteUnavailable
    }

    /// Deliberately damage only an owned disposable fixture's scalar BLOB. The
    /// typed Lattice writer correctly refuses these invalid vectors. Temporarily
    /// remove just the embedding UPDATE trigger (not insert/delete/index/schema),
    /// then restore its exact stored SQL before committing. Reader invocations
    /// start only after this fixture connection is checkpointed and closed.
    private func replaceOwnedFixtureEmbedding(file: URL, memoryID: UUID, blob: Data) throws {
        #if canImport(SQLite3) || canImport(CSQLite)
        var opened: OpaquePointer?
        let openCode = sqlite3_open_v2(file.path, &opened, SQLITE_OPEN_READWRITE, nil)
        guard openCode == SQLITE_OK, let db = opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "No handle"
            if let opened { sqlite3_close(opened) }
            throw FixtureFailure.sqlite(operation: "open owned fixture", code: openCode, message: message)
        }
        defer { sqlite3_close(db) }
        func check(_ code: Int32, _ operation: String, expected: Int32 = SQLITE_OK) throws {
            guard code == expected else {
                throw FixtureFailure.sqlite(operation: operation, code: code, message: String(cString: sqlite3_errmsg(db)))
            }
        }
        func execute(_ sql: String) throws { try check(sqlite3_exec(db, sql, nil, nil, nil), sql) }
        func triggerSQL() throws -> String {
            let sql = "SELECT sql FROM sqlite_master WHERE type='trigger' AND name='_Memory_embedding_vec_update' AND tbl_name='Memory'"
            var statement: OpaquePointer?
            try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), "read exact vector update trigger")
            defer { sqlite3_finalize(statement) }
            try check(sqlite3_step(statement), "find exact vector update trigger", expected: SQLITE_ROW)
            guard let text = sqlite3_column_text(statement, 0) else { throw FixtureFailure.invariant("Missing trigger SQL") }
            let result = String(cString: text)
            try check(sqlite3_step(statement), "unique vector update trigger", expected: SQLITE_DONE)
            return result
        }
        try check(sqlite3_busy_timeout(db, 5_000), "set fixture timeout")
        try check(sqlite3_create_function(db, "sync_disabled", 0, SQLITE_UTF8, nil,
            { context, _, _ in sqlite3_result_int(context, 1) }, nil, nil), "register fixture audit suppression")
        let originalTrigger = try triggerSQL()
        try execute("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
        try execute("DROP TRIGGER _Memory_embedding_vec_update")
        do {
            var statement: OpaquePointer?
            try check(sqlite3_prepare_v2(db, "UPDATE Memory SET embedding=? WHERE globalId=?", -1, &statement, nil), "prepare damaged scalar update")
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            try blob.withUnsafeBytes { bytes in
                try check(sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), transient), "bind damaged vector bytes")
            }
            try memoryID.uuidString.withCString { value in
                try check(sqlite3_bind_text(statement, 2, value, -1, transient), "bind owned memory identity")
            }
            try check(sqlite3_step(statement), "write damaged scalar BLOB", expected: SQLITE_DONE)
            guard sqlite3_changes(db) == 1 else { throw FixtureFailure.invariant("Expected exactly one owned fixture row") }
        }
        do {
            var statement: OpaquePointer?
            try check(sqlite3_prepare_v2(db, "SELECT embedding FROM Memory WHERE globalId=?", -1, &statement, nil), "prepare damaged BLOB readback")
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            try memoryID.uuidString.withCString { value in
                try check(sqlite3_bind_text(statement, 1, value, -1, transient), "bind readback memory identity")
            }
            try check(sqlite3_step(statement), "read damaged scalar BLOB", expected: SQLITE_ROW)
            guard sqlite3_column_type(statement, 0) == SQLITE_BLOB,
                  Int(sqlite3_column_bytes(statement, 0)) == blob.count,
                  let bytes = sqlite3_column_blob(statement, 0), Data(bytes: bytes, count: blob.count) == blob else {
                throw FixtureFailure.invariant("Damaged fixture bytes did not round-trip exactly")
            }
            try check(sqlite3_step(statement), "unique damaged scalar BLOB", expected: SQLITE_DONE)
        }
        try execute(originalTrigger)
        guard try triggerSQL() == originalTrigger else { throw FixtureFailure.invariant("Vector trigger was not restored exactly") }
        try execute("COMMIT"); committed = true
        try check(sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil), "checkpoint damaged fixture")
        #else
        // Keep the existing cases declared and fail explicitly if a test target
        // lacks SQLite bindings; never silently skip their reader assertions.
        throw FixtureFailure.sqliteUnavailable
        #endif
    }

}
