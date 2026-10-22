@testable import EngramKit
import EngramModels
import Foundation
import Lattice
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
        // Legacy callers without the flag: the exact 1.000 sentinel is degraded too.
        guard case .skip(let sentinelReason) = SampleGateDecision.decide([excerpt("block", distance: 1.0)]) else {
            Issue.record("expected skip"); return
        }
        #expect(sentinelReason.hasPrefix("degraded"))
    }

    @Test func measuredNoveltySpawnsWithOnlyTheUsableExcerpts() {
        let usable = excerpt("a genuinely novel block", distance: 0.936)
        let far = excerpt("very novel block", distance: 1.21)
        let degraded = excerpt("unmeasured block", distance: 1.0, degraded: true)
        #expect(SampleGateDecision.decide([usable, degraded, far]) == .spawn(excerpts: [usable, far]))
    }
}
