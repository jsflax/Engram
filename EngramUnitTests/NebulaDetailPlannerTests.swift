import Foundation
import XCTest
@testable import EngramRealityKit

final class NebulaDetailPlannerTests: XCTestCase {
    private typealias Candidate = NebulaDetailPlanner.Candidate
    private typealias Allocation = NebulaDetailPlanner.Allocation

    private func candidates(_ count: Int, rate: Float = 15) -> [Candidate] {
        (0..<count).map { index in
            Candidate(key: String(format: "main|P%03d", index), galaxyId: "main",
                      desiredOpacity: 1, priority: 1, birthRate: rate)
        }
    }

    private func positive(_ allocations: [String: Allocation]) -> [String: Allocation] {
        allocations.filter { $0.value.opacity > 0 }
    }

    private func assertBound(_ allocations: [String: Allocation], emitters: Int = 24,
                             births: Float = 240, file: StaticString = #filePath, line: UInt = #line) {
        let active = positive(allocations)
        XCTAssertLessThanOrEqual(active.count, emitters, file: file, line: line)
        XCTAssertLessThanOrEqual(active.values.reduce(0) { $0 + $1.birthRate }, births + 0.0001,
                                 "Positive opacity pays the whole emitter cost", file: file, line: line)
        for value in allocations.values {
            XCTAssertTrue(value.opacity.isFinite && (0...1).contains(value.opacity), file: file, line: line)
        }
    }

    func testOverlapping166ProjectsRespectEmitterAndBirthBudgets() {
        var planner = NebulaDetailPlanner()
        let inputs = candidates(166)
        var result: [String: Allocation] = [:]
        for _ in 0..<60 {
            result = planner.update(candidates: inputs, deltaTime: 1 / 60)
            assertBound(result)
        }
        XCTAssertEqual(positive(result).count, 16, "The rate budget binds before the 24-emitter budget")
        XCTAssertEqual(Set(positive(result).keys), Set(inputs.prefix(16).map(\.key)))
    }

    func testGalaxiesShareOneGlobalBudget() {
        var planner = NebulaDetailPlanner()
        let inputs = (0..<60).map { index in
            Candidate(key: String(format: "%@|P%03d", index.isMultiple(of: 2) ? "first" : "second", index),
                      galaxyId: index.isMultiple(of: 2) ? "first" : "second",
                      desiredOpacity: 1, priority: Float(index), birthRate: 5)
        }
        var result: [String: Allocation] = [:]
        for _ in 0..<60 {
            result = planner.update(candidates: inputs, deltaTime: 1 / 60)
            assertBound(result)
        }
        let keys = Set(positive(result).keys)
        XCTAssertEqual(keys.count, 24)
        XCTAssertTrue(keys.contains { $0.hasPrefix("first|") })
        XCTAssertTrue(keys.contains { $0.hasPrefix("second|") })
    }

    func testOutgoingPositiveOpacityRemainsChargedThroughoutReplacement() {
        var planner = NebulaDetailPlanner(budget: .init(maxEmitters: 4, maxBirthRate: 40, fadeDuration: 0.25))
        func inputs(reversed: Bool) -> [Candidate] {
            (0..<8).map { index in
                let first = index < 4
                return Candidate(key: "P\(index)", galaxyId: "main", desiredOpacity: 1,
                                 priority: first == !reversed ? 0 : 100, birthRate: 10)
            }
        }
        var result: [String: Allocation] = [:]
        for _ in 0..<60 { result = planner.update(candidates: inputs(reversed: false), deltaTime: 1 / 60) }
        XCTAssertEqual(Set(positive(result).keys), Set((0..<4).map { "P\($0)" }))
        var observedOutgoingFade = false
        for _ in 0..<60 {
            result = planner.update(candidates: inputs(reversed: true), deltaTime: 1 / 60)
            assertBound(result, emitters: 4, births: 40)
            observedOutgoingFade = observedOutgoingFade || result.contains {
                (0..<4).map { "P\($0)" }.contains($0.key) && $0.value.opacity > 0 && $0.value.opacity < 1
            }
        }
        XCTAssertTrue(observedOutgoingFade, "Membership eviction fades instead of an immediate disappearance")
        XCTAssertEqual(Set(positive(result).keys), Set((4..<8).map { "P\($0)" }))
    }

    func testOrderingAndSmallPriorityJitterDoNotChurnButCloserDetailWins() {
        let inputs = candidates(30, rate: 5)
        var forward = NebulaDetailPlanner(), reversed = NebulaDetailPlanner()
        var baseline: [String: Allocation] = [:]
        var reordered: [String: Allocation] = [:]
        for _ in 0..<60 {
            baseline = forward.update(candidates: inputs, deltaTime: 1 / 60)
            reordered = reversed.update(candidates: Array(inputs.reversed()), deltaTime: 1 / 60)
        }
        let retained = Set(positive(baseline).keys)
        XCTAssertEqual(retained, Set(positive(reordered).keys), "Input enumeration order cannot decide ties")
        for frame in 0..<60 {
            let jittered = inputs.reversed().map {
                Candidate(key: $0.key, galaxyId: $0.galaxyId, desiredOpacity: 1,
                          priority: retained.contains($0.key) ? 1.001 : 0.999 + Float(frame % 2) * 0.0001,
                          birthRate: 5)
            }
            baseline = forward.update(candidates: jittered, deltaTime: 1 / 60)
            assertBound(baseline)
            XCTAssertEqual(Set(positive(baseline).keys), retained)
        }
        let challenger = inputs.last!.key
        for _ in 0..<60 {
            let moved = inputs.map {
                Candidate(key: $0.key, galaxyId: $0.galaxyId, desiredOpacity: 1,
                          priority: $0.key == challenger ? 0.1 : 1, birthRate: 5)
            }
            baseline = forward.update(candidates: moved, deltaTime: 1 / 60)
            assertBound(baseline)
        }
        XCTAssertTrue(positive(baseline).keys.contains(challenger), "Retention cannot indefinitely exclude materially closer detail")
    }

    func testPendingRateGrowthCannotOvercommitExistingEmitters() {
        var planner = NebulaDetailPlanner()
        var result: [String: Allocation] = [:]
        for _ in 0..<60 { result = planner.update(candidates: candidates(30, rate: 5), deltaTime: 1 / 60) }
        XCTAssertEqual(positive(result).count, 24)
        for _ in 0..<90 {
            result = planner.update(candidates: candidates(30, rate: 15), deltaTime: 1 / 60)
            assertBound(result)
        }
        XCTAssertEqual(positive(result).count, 16)
        XCTAssertTrue(positive(result).values.allSatisfy { $0.birthRate == 15 },
                      "Pending emitter replacements eventually apply once their full cost fits")
    }

    func testInvalidInputsCannotAdvanceTransitionsAndRemovedDetailReleasesCapacity() {
        var planner = NebulaDetailPlanner(budget: .init(maxEmitters: 1, maxBirthRate: 15, fadeDuration: 0.25))
        let original = Candidate(key: "old", galaxyId: "main", desiredOpacity: 1, priority: 0, birthRate: 15)
        let waiting = Candidate(key: "new", galaxyId: "main", desiredOpacity: 1, priority: 10, birthRate: 15)
        var result = planner.update(candidates: [original, waiting], deltaTime: 0.25)
        let before = positive(result)
        let replacement = [
            Candidate(key: "old", galaxyId: "main", desiredOpacity: 1, priority: 10, birthRate: 15),
            Candidate(key: "new", galaxyId: "main", desiredOpacity: 1, priority: 0, birthRate: 15),
        ]
        for delta: Float in [-0.1, .nan, .infinity] {
            result = planner.update(candidates: replacement, deltaTime: delta)
            assertBound(result, emitters: 1, births: 15)
            XCTAssertEqual(positive(result), before, "Invalid elapsed time cannot advance eviction or admission")
        }
        let invalid = [
            Candidate(key: "opacity", galaxyId: "main", desiredOpacity: .nan, priority: 0, birthRate: 5),
            Candidate(key: "priority", galaxyId: "main", desiredOpacity: 1, priority: .infinity, birthRate: 5),
            Candidate(key: "negative-rate", galaxyId: "main", desiredOpacity: 1, priority: 0, birthRate: -1),
            Candidate(key: "nan-rate", galaxyId: "main", desiredOpacity: 1, priority: 0, birthRate: .nan),
        ]
        XCTAssertTrue(positive(planner.update(candidates: invalid, deltaTime: 0.25)).isEmpty,
                      "Removed and invalid detail cannot retain budget or visible particles")
        for opacity: Float in [1, 0.03, 0, 0.001, 1] {
            let single = Candidate(key: "single", galaxyId: "main", desiredOpacity: opacity, priority: 0, birthRate: 15)
            result = planner.update(candidates: [single], deltaTime: 0)
            XCTAssertEqual(result["single"]?.opacity, opacity, "An unconstrained scene preserves exact spatial endpoints and tiny reentry")
        }
        XCTAssertTrue(planner.update(candidates: [], deltaTime: 0).isEmpty)
    }
}
