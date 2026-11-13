import Testing
import EngramKit
import EngramModels
import Lattice
import Foundation
import EngramTestSupport

// MARK: - Edge Migration V1 → V2 Tests

/// Helper: create a Lattice at a temp path for migration testing.
/// Supports both v1 (old schema) and v2 (new schema + migration).
private func migrationLattice(
    path: String,
    v1 types: any Model.Type...
) throws -> Lattice {
    try Lattice(
        for: types,
        configuration: .init(fileURL: EngramTestFixtureRoot.directory().appending(path: path))
    )
}

private func migrationLattice(
    path: String,
    v2 types: any Model.Type...
) throws -> Lattice {
    try Lattice(
        for: types,
        configuration: .init(fileURL: EngramTestFixtureRoot.directory().appending(path: path), migration: engramMigrations)
    )
}

@Suite("Edge Migration V1→V2")
struct EdgeMigrationTests {
    @Test func edgesGetUUIDReferences() throws {
        let dbPath = "engram_migration_\(UUID().uuidString).sqlite"
        let dbURL = try EngramTestFixtureRoot.directory().appending(path: dbPath)
        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }

        var globalIds: [Int64: UUID] = [:]

        try autoreleasepool {
            let lattice = try migrationLattice(path: dbPath, v1: Memory.self, V1.Edge.self, Checkpoint.self, HookState.self)

            let m1 = Memory(content: "Networking layer", project: "Test", embedding: Vector<Float>(Array(repeating: 0, count: 384)))
            let m2 = Memory(content: "Database schema", project: "Test", embedding: Vector<Float>(Array(repeating: 0, count: 384)))
            try lattice.add(m1)
            try lattice.add(m2)

            globalIds[m1.primaryKey!] = m1.globalId!
            globalIds[m2.primaryKey!] = m2.globalId!

            let edge = V1.Edge(sourceId: m1.primaryKey!, targetId: m2.primaryKey!, relation: "relates_to")
            try lattice.add(edge)
        }

        try autoreleasepool {
            let lattice = try migrationLattice(path: dbPath, v2: Memory.self, Edge.self, Checkpoint.self, HookState.self)

            let edges = lattice.objects(Edge.self)
            #expect(edges.count == 1)

            let edge = edges.first!
            #expect(edge.sourceGlobalId == globalIds.values.first { $0 == edge.sourceGlobalId })
            #expect(edge.targetGlobalId == globalIds.values.first { $0 == edge.targetGlobalId })
            #expect(edge.relation == .relatesTo)

            // Verify the UUIDs match the original memories
            let memories = lattice.objects(Memory.self)
            let m1 = memories.where { $0.content == "Networking layer" }.first!
            let m2 = memories.where { $0.content == "Database schema" }.first!
            #expect(edge.sourceGlobalId == m1.globalId)
            #expect(edge.targetGlobalId == m2.globalId)
        }
    }

    @Test func allRelationTypesPreserved() throws {
        let dbPath = "engram_migration_rel_\(UUID().uuidString).sqlite"
        let dbURL = try EngramTestFixtureRoot.directory().appending(path: dbPath)
        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }

        let relations = ["relates_to", "contradicts", "supersedes", "derived_from", "part_of", "summarized_by"]

        try autoreleasepool {
            let lattice = try migrationLattice(path: dbPath, v1: Memory.self, V1.Edge.self, Checkpoint.self, HookState.self)

            // Create pairs of memories for each relation type
            for (i, rel) in relations.enumerated() {
                let src = Memory(content: "Source \(i)", project: "RelTest", embedding: Vector<Float>(Array(repeating: 0, count: 384)))
                let tgt = Memory(content: "Target \(i)", project: "RelTest", embedding: Vector<Float>(Array(repeating: 0, count: 384)))
                try lattice.add(src)
                try lattice.add(tgt)
                try lattice.add(V1.Edge(sourceId: src.primaryKey!, targetId: tgt.primaryKey!, relation: rel))
            }
        }

        try autoreleasepool {
            let lattice = try migrationLattice(path: dbPath, v2: Memory.self, Edge.self, Checkpoint.self, HookState.self)

            let edges = lattice.objects(Edge.self)
            #expect(edges.count == relations.count)

            let expected: [Edge.Relation] = [.relatesTo, .contradicts, .supersedes, .derivedFrom, .partOf, .summarizedBy]
            for rel in expected {
                let matching = edges.where { $0.relation == rel }
                #expect(matching.count == 1, "Expected one edge with relation \(rel.rawValue)")
            }
        }
    }

    @Test func orphanEdgesGetSentinelUUID() throws {
        let dbPath = "engram_migration_orphan_\(UUID().uuidString).sqlite"
        let dbURL = try EngramTestFixtureRoot.directory().appending(path: dbPath)
        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }

        let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

        try autoreleasepool {
            let lattice = try migrationLattice(path: dbPath, v1: Memory.self, V1.Edge.self, Checkpoint.self, HookState.self)

            let mem = Memory(content: "Real memory", project: "OrphanTest", embedding: Vector<Float>(Array(repeating: 0, count: 384)))
            try lattice.add(mem)

            // Edge referencing non-existent memory (PK 99999)
            try lattice.add(V1.Edge(sourceId: mem.primaryKey!, targetId: 99999, relation: "relates_to"))
        }

        try autoreleasepool {
            let lattice = try migrationLattice(path: dbPath, v2: Memory.self, Edge.self, Checkpoint.self, HookState.self)

            let edges = lattice.objects(Edge.self)
            #expect(edges.count == 1)

            let edge = edges.first!
            #expect(edge.sourceGlobalId != zeroUUID) // source exists
            #expect(edge.targetGlobalId == zeroUUID) // target was orphaned
        }
    }

    @Test func emptyEdgeTableMigrates() throws {
        let dbPath = "engram_migration_empty_\(UUID().uuidString).sqlite"
        let dbURL = try EngramTestFixtureRoot.directory().appending(path: dbPath)
        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }

        try autoreleasepool {
            let lattice = try migrationLattice(path: dbPath, v1: Memory.self, V1.Edge.self, Checkpoint.self, HookState.self)
            try lattice.add(Memory(content: "Lonely", project: "EmptyTest", embedding: Vector<Float>(Array(repeating: 0, count: 384))))
        }

        try autoreleasepool {
            let lattice = try migrationLattice(path: dbPath, v2: Memory.self, Edge.self, Checkpoint.self, HookState.self)
            #expect(lattice.objects(Edge.self).count == 0)
            #expect(lattice.objects(Memory.self).count == 1)
        }
    }

    @Test func createdAtPreserved() throws {
        let dbPath = "engram_migration_date_\(UUID().uuidString).sqlite"
        let dbURL = try EngramTestFixtureRoot.directory().appending(path: dbPath)
        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }

        let specificDate = Date(timeIntervalSince1970: 1700000000)

        try autoreleasepool {
            let lattice = try migrationLattice(path: dbPath, v1: Memory.self, V1.Edge.self, Checkpoint.self, HookState.self)

            let m1 = Memory(content: "A", project: "DateTest", embedding: Vector<Float>(Array(repeating: 0, count: 384)))
            let m2 = Memory(content: "B", project: "DateTest", embedding: Vector<Float>(Array(repeating: 0, count: 384)))
            try lattice.add(m1)
            try lattice.add(m2)

            try lattice.add(V1.Edge(sourceId: m1.primaryKey!, targetId: m2.primaryKey!, relation: "supersedes", createdAt: specificDate))
        }

        try autoreleasepool {
            let lattice = try migrationLattice(path: dbPath, v2: Memory.self, Edge.self, Checkpoint.self, HookState.self)

            let edge = lattice.objects(Edge.self).first!
            #expect(Swift.abs(edge.createdAt.timeIntervalSince1970 - specificDate.timeIntervalSince1970) < 1.0)
            #expect(edge.relation == .supersedes)
        }
    }

    @Test func postMigrationOperationsWork() throws {
        let dbPath = "engram_migration_post_\(UUID().uuidString).sqlite"
        let dbURL = try EngramTestFixtureRoot.directory().appending(path: dbPath)
        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }

        try autoreleasepool {
            let lattice = try migrationLattice(path: dbPath, v1: Memory.self, V1.Edge.self, Checkpoint.self, HookState.self)

            let m1 = Memory(content: "Existing A", project: "PostTest", embedding: Vector<Float>(Array(repeating: 0, count: 384)))
            let m2 = Memory(content: "Existing B", project: "PostTest", embedding: Vector<Float>(Array(repeating: 0, count: 384)))
            try lattice.add(m1)
            try lattice.add(m2)

            try lattice.add(V1.Edge(sourceId: m1.primaryKey!, targetId: m2.primaryKey!, relation: "relates_to"))
        }

        try autoreleasepool {
            let lattice = try migrationLattice(path: dbPath, v2: Memory.self, Edge.self, Checkpoint.self, HookState.self)

            // Add a new memory and edge post-migration
            let m3 = Memory(content: "New memory", project: "PostTest", embedding: Vector<Float>(Array(repeating: 0, count: 384)))
            try lattice.add(m3)

            let m1 = lattice.objects(Memory.self).where { $0.content == "Existing A" }.first!
            let newEdge = Edge(sourceGlobalId: m1.globalId!, targetGlobalId: m3.globalId!, relation: .derivedFrom)
            try lattice.add(newEdge)

            #expect(lattice.objects(Edge.self).count == 2)

            let derived = lattice.objects(Edge.self).where { $0.relation == .derivedFrom }
            #expect(derived.count == 1)
            #expect(derived.first?.targetGlobalId == m3.globalId)
        }
    }

    @Test func unknownRelationDefaultsToRelatesTo() throws {
        let dbPath = "engram_migration_unk_\(UUID().uuidString).sqlite"
        let dbURL = try EngramTestFixtureRoot.directory().appending(path: dbPath)
        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }

        try autoreleasepool {
            let lattice = try migrationLattice(path: dbPath, v1: Memory.self, V1.Edge.self, Checkpoint.self, HookState.self)

            let m1 = Memory(content: "A", project: "UnkTest", embedding: Vector<Float>(Array(repeating: 0, count: 384)))
            let m2 = Memory(content: "B", project: "UnkTest", embedding: Vector<Float>(Array(repeating: 0, count: 384)))
            try lattice.add(m1)
            try lattice.add(m2)

            try lattice.add(V1.Edge(sourceId: m1.primaryKey!, targetId: m2.primaryKey!, relation: "some_future_relation"))
        }

        try autoreleasepool {
            let lattice = try migrationLattice(path: dbPath, v2: Memory.self, Edge.self, Checkpoint.self, HookState.self)
            #expect(lattice.objects(Edge.self).first?.relation == .relatesTo)
        }
    }

    @Test func largeGraphMigration() throws {
        let dbPath = "engram_migration_large_\(UUID().uuidString).sqlite"
        let dbURL = try EngramTestFixtureRoot.directory().appending(path: dbPath)
        defer { try? Lattice.delete(for: .init(fileURL: dbURL)) }

        try autoreleasepool {
            let lattice = try migrationLattice(path: dbPath, v1: Memory.self, V1.Edge.self, Checkpoint.self, HookState.self)

            var pks: [Int64] = []
            for i in 0..<10 {
                let m = Memory(content: "Node \(i)", project: "StressTest", embedding: Vector<Float>(Array(repeating: 0, count: 384)))
                try lattice.add(m)
                pks.append(m.primaryKey!)
            }

            // Fully connected: 10 choose 2 = 45 edges
            for i in 0..<10 {
                for j in (i+1)..<10 {
                    try lattice.add(V1.Edge(sourceId: pks[i], targetId: pks[j], relation: "relates_to"))
                }
            }
            #expect(lattice.objects(V1.Edge.self).count == 45)
        }

        try autoreleasepool {
            let lattice = try migrationLattice(path: dbPath, v2: Memory.self, Edge.self, Checkpoint.self, HookState.self)
            #expect(lattice.objects(Edge.self).count == 45)

            // Spot-check: all edges should have non-zero UUIDs
            let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            for edge in lattice.objects(Edge.self) {
                #expect(edge.sourceGlobalId != zeroUUID)
                #expect(edge.targetGlobalId != zeroUUID)
            }
        }
    }
}
