@testable import EngramKit
import EngramModels
import Foundation
import Lattice
import Testing

@Suite("Audit compaction diagnostics", .serialized)
struct AuditCompactionDiagnosticsTests {
    private struct Fixture {
        let directory: URL
        let path: URL
        let lattice: Lattice

        func close() {
            lattice.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func fixture() throws -> Fixture {
        let directory = try testFixtureDirectory()
            .appendingPathComponent("audit-compaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("memory.sqlite")
        let lattice = try Lattice(Memory.self,
            configuration: .init(fileURL: path, busyTimeoutMs: 25))
        try lattice.withTransaction {
            for index in 0..<3 {
                try lattice.add(Memory(content: "Compaction fixture row \(index)"))
            }
        }
        return Fixture(directory: directory, path: path, lattice: lattice)
    }

    private func auditSnapshot(_ lattice: Lattice) throws -> Data {
        let rows = lattice.objects(AuditLog.self).sortedBy(\.primaryKey).snapshot()
        #expect(lattice.lastQueryError() == nil)
        #expect(!rows.isEmpty)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(rows)
    }

    @Test func realBusyFailureSurvivesCheckpointAndHealthyRetryPreservesHistory() throws {
        let f = try fixture()
        defer { f.close() }
        let before = try auditSnapshot(f.lattice)
        let holder = try RawWriteLock(path: f.path.path)
        defer { holder.close() }
        let beforeCount = try holder.integer("SELECT COUNT(*) FROM AuditLog")
        let beforeHead = try holder.integer("SELECT MAX(id) FROM AuditLog")
        try holder.acquire()

        var logs: [String] = []
        let failed = SyncService.compactAndCheckpoint(f.lattice, context: "Fixture", log: { logs.append($0) })
        // The slot-aware compactor acquires BEGIN before inspecting writer
        // slots, so this is a real SQLite lock failure even on this fixture
        // with no network connections or synchronizers.
        #expect(failed == nil, "a sealed BEGIN failure must not become zero rows compacted")
        #expect(logs.contains { $0.contains("compaction failed: Failed to begin transaction: database is locked") })
        #expect(!logs.contains { $0.contains("compacted 0") || $0.contains("no writer slots") })
        // checkpointBounded has really run after the failed compaction and
        // cleared its error slot; the diagnostic above must outlive that call.
        #expect(f.lattice.lastQueryError() == nil)
        #expect(try holder.integer("SELECT COUNT(*) FROM AuditLog") == beforeCount)
        #expect(try holder.integer("SELECT MAX(id) FROM AuditLog") == beforeHead)
        #expect(try auditSnapshot(f.lattice) == before)

        holder.release()
        logs.removeAll()
        let healthy = SyncService.compactAndCheckpoint(f.lattice, context: "Fixture", log: { logs.append($0) })
        #expect(healthy == -1, "no writer slots is a valid no-op, distinct from a failed attempt")
        #expect(!logs.contains { $0.contains("failed") })
        #expect(logs.contains { $0.contains("no writer slots") })
        #expect(f.lattice.lastQueryError() == nil)
        #expect(try holder.integer("SELECT COUNT(*) FROM AuditLog") == beforeCount)
        #expect(try holder.integer("SELECT MAX(id) FROM AuditLog") == beforeHead)
        #expect(try auditSnapshot(f.lattice) == before)
    }

    @Test func startupCompactionReportsTheRealBusyFailure() throws {
        let f = try fixture()
        defer { f.close() }
        let holder = try RawWriteLock(path: f.path.path)
        defer { holder.close() }
        try holder.acquire()
        var logs: [String] = []
        SyncService.compactBeforeSync(f.lattice, log: { logs.append($0) })
        #expect(logs.contains { $0.hasPrefix("Startup compaction: compaction failed:") })
        #expect(f.lattice.lastQueryError() == nil)
    }
}
