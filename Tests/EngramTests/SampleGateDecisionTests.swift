@testable import EngramKit
import EngramModels
import Foundation
import Lattice
import SQLite3
import Testing

/// The sample gate's spawn decision (2026-10-21 contention workstream): a
/// degraded vector search must not read as novelty.
@Suite("Sample gate decision")
struct SampleGateDecisionTests {

    private func excerpt(_ text: String, distance: Double, degraded: Bool = false)
        -> TranscriptSampler.ScoredExcerpt {
        .init(text: text, minDistance: distance, charLength: text.count, isDegraded: degraded)
    }

    @Test func emptySamplerOutputSkips() {
        #expect(SampleGateDecision.decide([]) == .skip(reason: "no novel excerpts"))
    }

    @Test func degradedVectorSearchSkipsInsteadOfSpawning() {
        // Explicit degraded flag (populated store, KNN returned nothing).
        let flagged = [excerpt("block one", distance: 1.0, degraded: true),
                       excerpt("block two", distance: 1.0, degraded: true)]
        guard case .skip(let reason) = SampleGateDecision.decide(flagged) else {
            Issue.record("expected skip"); return
        }
        #expect(reason.hasPrefix("degraded"))
    }

    @Test func measuredNoveltySpawnsWithOnlyTheUsableExcerpts() {
        let usable = excerpt("a genuinely novel block", distance: 0.936)
        let far = excerpt("very novel block", distance: 1.21)
        let degraded = excerpt("unmeasured block", distance: 1.0, degraded: true)
        #expect(SampleGateDecision.decide([usable, degraded, far]) == .spawn(excerpts: [usable, far]))
    }

    @Test func emptyEligibleScopeCanBootstrapLearning() throws {
        try withStore { lattice in
            let now = Date()
            try expectNovel(lattice, now: now)
            // Rows outside recall's visibility scope must not stop bootstrap.
            try lattice.add(Memory(content: "expired", embedding: vector(0),
                                   expiresAt: now.addingTimeInterval(-1)))
            try lattice.add(Memory(content: "deleted", embedding: vector(0), deletedAt: now))
            try expectNovel(lattice, now: now)
        }
    }

    @Test func measuredDistanceExactlyOneCanSpawn() throws {
        try withStore { lattice in
            try lattice.add(Memory(content: "origin", embedding: vector(0)))
            let score = TranscriptSampler.NoveltySearch(lattice: lattice, now: Date()).score(vector(1))
            #expect(lattice.lastQueryError() == nil)
            #expect(score.distance == 1.0)
            #expect(!score.isDegraded)
            let block = excerpt("measured novelty", distance: score.distance, degraded: score.isDegraded)
            #expect(SampleGateDecision.decide([block]) == .spawn(excerpts: [block]))
        }
    }

    @Test func sealedVectorFailureDoesNotBecomeNovelty() throws {
        try withStore { lattice in
            try lattice.add(Memory(content: "indexed", embedding: vector(0)))
            let search = TranscriptSampler.NoveltySearch(lattice: lattice, now: Date())
            // Establish the real 384-dimensional vector index, then issue an
            // incompatible query through the same production scoring path.
            #expect(!search.score(vector(1)).isDegraded)
            let failed = search.score(Vector<Float>([1, 0]))
            #expect(lattice.lastQueryError() != nil)
            #expect(failed.isDegraded)
            guard case .skip = SampleGateDecision.decide([
                excerpt("failed search", distance: failed.distance, degraded: failed.isDegraded)
            ]) else { Issue.record("failed vector query admitted a learner"); return }
            #expect(!search.score(vector(1)).isDegraded, "a later healthy query can recover")
            #expect(lattice.lastQueryError() == nil)
        }
    }

    @Test func invalidDistancesAreNotUsable() {
        for distance in [Double.nan, Double.infinity, -1] {
            guard case .skip = SampleGateDecision.decide([excerpt("invalid", distance: distance)]) else {
                Issue.record("invalid distance admitted a learner"); continue
            }
        }
    }

    @Test func sealedCountFailureCannotBootstrapLearning() throws {
        try withStore { lattice in
            // Break only this synthetic fixture's schema. A failed COUNT is
            // sealed as zero by Core; it must not be treated as an empty store.
            var database: OpaquePointer?
            try #require(sqlite3_open(lattice.configuration.fileURL.path, &database) == SQLITE_OK)
            defer { sqlite3_close(database) }
            try #require(sqlite3_exec(database, "DROP TABLE Memory", nil, nil, nil) == SQLITE_OK)
            let search = TranscriptSampler.NoveltySearch(lattice: lattice, now: Date())
            #expect(lattice.lastQueryError() != nil)
            #expect(search.eligibleCount == nil)
            #expect(search.score(vector(1)).isDegraded)
        }
    }

    private func vector(_ first: Float) -> Vector<Float> {
        var values = [Float](repeating: 0, count: 384)
        values[0] = first
        return Vector<Float>(values)
    }

    private func expectNovel(_ lattice: Lattice, now: Date) throws {
        let search = TranscriptSampler.NoveltySearch(lattice: lattice, now: now)
        #expect(search.eligibleCount == 0)
        #expect(lattice.lastQueryError() == nil)
        let score = search.score(vector(1))
        #expect(!score.isDegraded)
        let block = excerpt("first knowledge", distance: score.distance, degraded: score.isDegraded)
        #expect(SampleGateDecision.decide([block]) == .spawn(excerpts: [block]))
    }

    private func withStore(_ body: (Lattice) throws -> Void) throws {
        let directory = try testFixtureDirectory().appendingPathComponent("sample-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lattice = try Lattice(Memory.self, configuration: .init(
            fileURL: directory.appendingPathComponent("memory.sqlite"), busyTimeoutMs: 100))
        defer { lattice.close() }
        try body(lattice)
    }
}
