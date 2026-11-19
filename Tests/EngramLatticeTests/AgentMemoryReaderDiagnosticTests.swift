import Foundation
import EngramTestSupport
import Testing
import Lattice
import EngramModels
@testable import EngramLattice

@Suite("Content-free reader compatibility diagnostics")
struct AgentMemoryReaderDiagnosticTests {
    @Test func schemaReasonsNameOnlyRequiredFields() throws {
        let owner = ObjectSchema(name: "AgentMemoryGraph", properties: [
            .init(name: "agentId", kind: .primitive, columnType: .text),
            .init(name: "graphId", kind: .primitive, columnType: .text)
        ])
        try expectRefusal("check=schema table=AgentMemoryGraph field=none reason=missing_table kind=absent") {
            try AgentMemoryReader.validateSchema([.init(name: "private-schema-name", properties: [])])
        }
        try expectRefusal("check=schema table=AgentMemoryGraph field=graphId reason=missing_field kind=absent") {
            try AgentMemoryReader.validateSchema([.init(name: owner.name, properties: [owner.properties[0]])])
        }
        var nonScalar = owner
        nonScalar.properties[1].kind = .list
        try expectRefusal("check=schema table=AgentMemoryGraph field=graphId reason=non_scalar kind=non_scalar") {
            try AgentMemoryReader.validateSchema([nonScalar])
        }
        // The existing admission only requires scalars, not specific scalar
        // types. Integer owner metadata still advances to the next table.
        var scalar = owner
        scalar.properties[1].columnType = .integer
        try expectRefusal("check=schema table=Memory field=none reason=missing_table kind=absent") {
            try AgentMemoryReader.validateSchema([scalar])
        }
    }

    @Test func decodeReasonsNeverIncludeValuesOrReflectedTypes() throws {
        try expectRefusal("check=decode table=Memory field=content reason=absent kind=absent") {
            _ = try AgentMemoryReader.requiredString(nil, table: "Memory", field: "content")
        }
        try expectRefusal("check=decode table=Memory field=content reason=wrong_type kind=blob") {
            _ = try AgentMemoryReader.requiredString(Data("private memory".utf8), table: "Memory", field: "content")
        }
        try expectRefusal("check=decode table=Memory field=globalId reason=invalid_uuid kind=string") {
            _ = try AgentMemoryReader.requiredUUID("private invalid identifier", table: "Memory", field: "globalId")
        }
        try expectRefusal("check=decode table=Edge field=sourceGlobalId reason=absent kind=absent") {
            _ = try AgentMemoryReader.requiredUUID(nil, table: "Edge", field: "sourceGlobalId")
        }
        try expectRefusal("check=decode table=Edge field=targetGlobalId reason=wrong_type kind=other") {
            _ = try AgentMemoryReader.requiredUUID(UUID(), table: "Edge", field: "targetGlobalId")
        }
        try expectRefusal("check=decode table=Edge field=relation reason=wrong_type kind=integer") {
            _ = try AgentMemoryReader.requiredString(Int64(42), table: "Edge", field: "relation")
        }
        try expectRefusal("check=decode table=Memory field=createdAt reason=absent kind=absent") {
            _ = try AgentMemoryReader.requiredDate(nil, table: "Memory", field: "createdAt")
        }
        try expectRefusal("check=decode table=Memory field=createdAt reason=wrong_type kind=string") {
            _ = try AgentMemoryReader.requiredDate("private timestamp", table: "Memory", field: "createdAt")
        }
        for seconds in [Double.infinity, -Double.infinity, Double.nan] {
            try expectRefusal("check=decode table=Edge field=createdAt reason=nonfinite_date kind=real") {
                _ = try AgentMemoryReader.requiredDate(seconds, table: "Edge", field: "createdAt")
            }
        }
    }

    @Test func validRequiredValuesDoNotEmitDiagnostics() throws {
        let recorder = ReaderCompatibilityRecorder(), id = UUID()
        try AgentMemoryReader.$compatibilityLog.withValue({ recorder.append($0) }) {
            let string = try AgentMemoryReader.requiredString("", table: "Memory", field: "content")
            let uuid = try AgentMemoryReader.requiredUUID(id.uuidString, table: "Edge", field: "globalId")
            let date = try AgentMemoryReader.requiredDate(0.0, table: "Memory", field: "createdAt")
            #expect(string == "")
            #expect(uuid == id)
            #expect(date == Date(timeIntervalSince1970: 0))
        }
        #expect(recorder.snapshot().isEmpty)
    }

    @Test func publicReadReportsTheMissingTableAndPreservesTheError() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "private-fixture.sqlite")
        let writer = try Lattice(Memory.self, configuration: .init(fileURL: file))
        defer { writer.close() }
        try writer.add(Memory(content: "private fixture content"))
        try expectRefusal("check=schema table=AgentMemoryGraph field=none reason=missing_table kind=absent") {
            _ = try AgentMemoryReader.read(fileURL: file, binding: .init(agentId: UUID()))
        }
        #expect(writer.objects(Memory.self).count == 1)
    }

    @Test(arguments: [false, true])
    func publicReadReportsTheRejectingMemoryOrEdgeDate(edge: Bool) throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "private-fixture.sqlite")
        let binding = AgentMemoryBinding(agentId: UUID()), first = UUID(), second = UUID()
        let writer = try Lattice(for: AgentMemoryStore.schema, configuration: AgentMemoryStore.configuration(fileURL: file))
        defer { writer.close() }
        try writer.withTransaction {
            try writer.add(AgentMemoryGraph(agentId: binding.agentId, graphId: binding.graphId))
            try writer.add(Memory(content: "private first memory", createdAt: edge ? Date() : Date(timeIntervalSince1970: .infinity)),
                           preservingGlobalId: first)
            try writer.add(Memory(content: "private second memory"), preservingGlobalId: second)
            if edge {
                try writer.add(Edge(sourceGlobalId: first, targetGlobalId: second, relation: .relatesTo,
                                    createdAt: Date(timeIntervalSince1970: .infinity)))
            }
        }
        if edge {
            let row = try #require(writer.objects(Edge.self).first)
            #expect(!row.createdAt.timeIntervalSince1970.isFinite)
        } else {
            let row = try #require(writer.objects(Memory.self).where { $0.globalId == first }.first)
            #expect(!row.createdAt.timeIntervalSince1970.isFinite)
        }
        // Use the ordinary writer; no raw-SQL corruption, forced checkpoint or
        // copied sidecars. The public reader must emit at the actual guard.
        try expectRefusal("check=decode table=\(edge ? "Edge" : "Memory") field=createdAt reason=nonfinite_date kind=real") {
            _ = try AgentMemoryReader.read(fileURL: file, binding: binding)
        }
        #expect(writer.objects(Memory.self).count == 2)
        #expect(writer.objects(Edge.self).count == (edge ? 1 : 0))
    }

    @Test func pagedReadWithRetainedOrdinaryWritersStaysSilent() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binding = AgentMemoryBinding(agentId: UUID()), recorder = ReaderCompatibilityRecorder()
        // Report the fixed diagnostic even if the read throws before returning
        // a snapshot; this is the concurrent-owner regression's useful oracle.
        defer { #expect(recorder.snapshot().isEmpty) }
        let first = try AgentMemoryStore.open(binding: binding, directory: directory)
        let saved = try await first.remember(.init(content: "private first fixture"))
        let second = try AgentMemoryStore.open(binding: binding, directory: directory)
        let file = AgentMemoryStore.fileURL(binding: binding, directory: directory)
        let firstPage = try await Task.detached {
            try AgentMemoryReader.$compatibilityLog.withValue({ recorder.append($0) }) {
                try AgentMemoryReader.read(fileURL: file, binding: binding)
            }
        }.value
        #expect(firstPage.memories.map(\.id) == [saved.id])
        #expect(firstPage.matchingMemoryCount == 1 && firstPage.pendingEmbeddingCount == 1)
        #expect(recorder.snapshot().isEmpty)
        try AgentMemoryReader.$compatibilityLog.withValue({ recorder.append($0) }) {
            do {
                _ = try AgentMemoryReader.read(fileURL: file, binding: .init(agentId: UUID(), graphId: binding.graphId))
                Issue.record("A different owner was admitted")
            } catch let error as AgentMemoryReader.ReadError {
                guard case .wrongOwner = error else {
                    Issue.record("Owner refusal was changed to a compatibility failure")
                    return
                }
            }
        }
        #expect(recorder.snapshot().isEmpty)
        let another = try await first.remember(.init(content: "private second fixture"))
        let page = try await Task.detached {
            try AgentMemoryReader.$compatibilityLog.withValue({ recorder.append($0) }) {
                try AgentMemoryReader.read(fileURL: file, binding: binding)
            }
        }.value
        #expect(Set(page.memories.map(\.id)) == [saved.id, another.id])
        #expect(page.matchingMemoryCount == 2 && page.pendingEmbeddingCount == 2)
        #expect(recorder.snapshot().isEmpty)
        // Both services remain live across the detached read. There is no
        // cold-reopen, checkpoint or simultaneous-write timing assumption.
        #expect(await first.agentMemoryStatus().memoryCount == 2)
        #expect(await second.agentMemoryStatus().memoryCount == 2)
    }

    private func directory() throws -> URL {
        let value = try EngramTestFixtureRoot.directory()
            .appending(path: "reader-diagnostic-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    private func expectRefusal(_ fields: String, operation: () throws -> Void) throws {
        let recorder = ReaderCompatibilityRecorder()
        try AgentMemoryReader.$compatibilityLog.withValue({ recorder.append($0) }) {
            do {
                try operation()
                Issue.record("Expected the existing compatibility refusal")
            } catch let error as AgentMemoryReader.ReadError {
                guard case .incompatible = error else {
                    Issue.record("The compatibility refusal changed its error case")
                    return
                }
                #expect(error.localizedDescription == "This memory graph is not compatible with the viewer.")
            }
        }
        #expect(recorder.snapshot() == ["[AgentMemoryReader] incompatible " + fields])
    }
}

/// Every access is locked; the sink also crosses the detached reader boundary.
private final class ReaderCompatibilityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
    }

    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}
