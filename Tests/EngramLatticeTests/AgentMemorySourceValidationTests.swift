import Foundation
import Testing
import Lattice
import EngramModels
import EngramLattice

@Suite("Shared memory source validation")
struct AgentMemorySourceValidationTests {
    @Test(arguments: [false, true])
    func legacyAndCurrentGraphsRemainByteUnchanged(current: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("engram-validation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("collection.sqlite")
        let source: Lattice
        if current {
            source = try Lattice(for: AgentMemoryStore.schema,
                                 configuration: AgentMemoryStore.configuration(fileURL: file))
            try source.add(Memory(content: "Current collection"))
        } else {
            source = try Lattice(MemorySchemaV3.Memory.self, Edge.self,
                                 configuration: .init(fileURL: file, migration: [3: Migration()]))
            try source.add(MemorySchemaV3.Memory(content: "Legacy collection"))
        }
        source.checkpoint()
        source.close()
        let before = try Data(contentsOf: file)
        try AgentMemorySourceValidation.validate(fileURL: file)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func unrelatedSQLiteAndMissingFileAreRejectedWithoutCreation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("engram-validation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("unrelated.sqlite")
        let source = try Lattice(HookState.self, configuration: .init(fileURL: file))
        source.checkpoint()
        source.close()
        let before = try Data(contentsOf: file)
        #expect(throws: AgentMemorySourceValidation.ValidationError.self) {
            try AgentMemorySourceValidation.validate(fileURL: file)
        }
        #expect(try Data(contentsOf: file) == before)
        let missing = directory.appendingPathComponent("missing.sqlite")
        #expect(throws: AgentMemorySourceValidation.ValidationError.self) {
            try AgentMemorySourceValidation.validate(fileURL: missing)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}
