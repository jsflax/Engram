import Darwin
import EngramKit
import EngramMemoryCore
import Foundation
import Lattice
import MCP
import Testing

struct MCPRuntimeInfoTests {
    private struct UnusedEmbedder: Embedder {
        let dimension = 384
        func embed(text: String) async throws -> [Float]? {
            Issue.record("runtime_info must not invoke the embedder")
            return nil
        }
    }

    private func fixture() throws -> (MemoryTools, Lattice) {
        let path = try testFixtureDirectory().appendingPathComponent("runtime-info-\(UUID().uuidString).sqlite")
        let db = try Lattice(Memory.self, configuration: .init(fileURL: path))
        let tools = MemoryTools(localRef: db.sendableReference, syncedRef: nil,
                                embedder: UnusedEmbedder(), identity: StaticIdentityProvider(.anonymous))
        return (tools, db)
    }

    @Test func testRuntimeInfoReturnsServingProcessPID() async throws {
        let (tools, db) = try fixture()
        defer {
            db.close()
            try? Lattice.delete(for: db.configuration)
        }
        for arguments: [String: Value]? in [nil, [:]] {
            let result = try await tools.handle(.init(name: "runtime_info", arguments: arguments))
            #expect(result.isError == false)
            #expect(result.content.count == 1)
            let value = try JSONDecoder().decode([String: Int].self, from: Data(text(from: result).utf8))
            #expect(value == ["pid": Int(getpid())])
            #expect(try #require(value["pid"]) > 0)
        }
    }

    @Test func testRuntimeInfoAdvertisesReadOnlyAndRejectsArguments() async throws {
        let (tools, db) = try fixture()
        defer {
            db.close()
            try? Lattice.delete(for: db.configuration)
        }
        let definitions = await tools.definitions
        let matches = definitions.filter { $0.name == "runtime_info" }
        #expect(matches.count == 1)
        let definition = try #require(matches.first)
        #expect(definition.annotations.readOnlyHint == true)
        #expect(definition.inputSchema == .object([
            "type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false),
        ]))
        await #expect(throws: MCPError.invalidParams("runtime_info takes no arguments.")) {
            try await tools.handle(.init(name: "runtime_info", arguments: ["pid": .int(1)]))
        }
    }

    @Test func testRuntimeInfoDoesNotOpenMissingStorage() async throws {
        let (tools, db) = try fixture()
        db.close()
        try Lattice.delete(for: db.configuration)
        let path = db.configuration.fileURL.path
        #expect(!FileManager.default.fileExists(atPath: path))

        let result = try await tools.handle(.init(name: "runtime_info", arguments: [:]))
        let value = try JSONDecoder().decode([String: Int].self, from: Data(text(from: result).utf8))
        #expect(value == ["pid": Int(getpid())])
        #expect(result.isError == false)
        // The same unresolved reference fails real storage preparation; the
        // diagnostic succeeded without opening or recreating that store.
        await #expect(throws: LatticeError.self) { try await tools.prepareStorage() }
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
