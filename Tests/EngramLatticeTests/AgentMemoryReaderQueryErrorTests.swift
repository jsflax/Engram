import Foundation
import Testing
import Lattice
import EngramModels
import EngramLattice
#if canImport(SQLite3)
import SQLite3

/// Real SQLite prepare failures, not a mocked reader callback. The fixture
/// preserves Lattice's stored Swift schema while removing one owned table.
@Suite("Agent reader sealed query failures")
struct AgentMemoryReaderQueryErrorTests {
    private enum FixtureError: Error { case sqlite(Int32) }

    @Test(arguments: ["Memory", "Edge", "AgentMemoryGraph"])
    func compatibleStoredSchemaWithMissingTableFailsInsteadOfReturningCompleteGraph(table: String) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "engram-query-failure-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "owned-fixture.sqlite"), binding = AgentMemoryBinding(agentId: UUID())
        let db = try Lattice(for: AgentMemoryStore.schema, configuration: AgentMemoryStore.configuration(fileURL: file))
        try db.withTransaction {
            try db.add(AgentMemoryGraph(agentId: binding.agentId, graphId: binding.graphId))
            try db.add(Memory(content: "Synthetic content must not appear in error text"))
        }
        db.checkpoint(); db.close()
        try removeTable(table, file: file)
        let bytes = try Data(contentsOf: file)

        // Dynamic schema validation really passes from persisted metadata. Both
        // sealed query forms fail in SQLite and return an otherwise plausible
        // empty/zero result. A later successful query really erases that error.
        let raw = try Lattice.dynamic(fileURL: file)
        #expect(raw.dynamicSchema.contains { $0.name == table })
        #expect(raw.dynamicObjects(table).count == 0)
        #expect(raw.lastQueryError() != nil)
        #expect(raw.dynamicObjects(table).snapshot(limit: 1).isEmpty)
        #expect(raw.lastQueryError() != nil)
        if table != "AgentMemoryGraph" {
            #expect(raw.dynamicObjects("AgentMemoryGraph").snapshot(limit: 2).count == 1)
            #expect(raw.lastQueryError() == nil)
        }
        raw.close()

        // Exercise both public production entry points. Without checkedQuery,
        // readGraph returns an empty/full or missing-edge snapshot for Memory /
        // Edge; read() also silently accepts failed result queries. An owner
        // failure must be distinguishable from an actual wrong-owner record.
        for fullGraph in [false, true] {
            do {
                if fullGraph { _ = try AgentMemoryReader.readGraph(fileURL: file, binding: binding) }
                else { _ = try AgentMemoryReader.read(fileURL: file, binding: binding) }
                Issue.record("A failed SQLite query was accepted as a complete memory read")
            } catch let error as AgentMemoryReader.ReadError {
                guard case .queryFailed = error else {
                    Issue.record("Expected the reader's query-failure error, got \(error)")
                    continue
                }
                #expect(error.localizedDescription.contains("Refresh"))
                #expect(!error.localizedDescription.contains(directory.path))
                #expect(!error.localizedDescription.contains("Synthetic content"))
                #expect(!error.localizedDescription.contains("SELECT"))
            }
        }
        #expect(try Data(contentsOf: file) == bytes)
    }

    private func removeTable(_ name: String, file: URL) throws {
        guard ["Memory", "Edge", "AgentMemoryGraph"].contains(name) else { throw FixtureError.sqlite(SQLITE_MISUSE) }
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE, nil)
        guard opened == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw FixtureError.sqlite(opened)
        }
        defer { sqlite3_close(handle) }
        let result = sqlite3_exec(handle, "DROP TABLE \"" + name + "\"", nil, nil, nil)
        guard result == SQLITE_OK else { throw FixtureError.sqlite(result) }
    }
}
#endif
