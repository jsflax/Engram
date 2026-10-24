import Foundation
import Testing
import os
@testable import EngramSceneKit

@Suite("Opt-in GPU timing")
struct GPULogTests {
    private func timing(gpuStart: Double = 3, gpuEnd: Double = 5) -> GPULog.ForceTiming {
        GPULog.ForceTiming(
            id: 7, metadata: GPULog.ForceMetadata(nodes: 10), snapshotEdges: 12, status: 4,
            preparationStarted: 1, committed: 2, gpuStarted: gpuStart, gpuEnded: gpuEnd,
            completionEntered: 6, readbackStarted: 6.1, readbackEnded: 6.2,
            mainActorEnqueued: 6.3, mainActorEntered: 7)
    }

    private func row(_ timing: GPULog.ForceTiming) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(timing.jsonLine().utf8)) as? [String: Any])
    }

    @Test func disabledDiagnosticsDoNotReadClock() {
        var reads = 0
        let token = GPULog.start(writer: nil, id: 1) { reads += 1; return 10 }
        #expect(token == nil)
        #expect(reads == 0)
    }

    @Test func timestampsSeparateGPUReadbackAndActorDelivery() throws {
        let result = try row(timing())
        let intervals = try #require(result["intervalsMs"] as? [String: Double])
        #expect(result["gpuTimingValid"] as? Bool == true)
        #expect(intervals["preparation_to_commit"] == 1000)
        #expect(intervals["commit_to_gpu_start"] == 1000)
        #expect(intervals["gpu_execution"] == 2000)
        #expect(intervals["gpu_end_to_completion"] == 1000)
        #expect(abs(try #require(intervals["readback"]) - 100) < 0.0001)
        #expect(abs(try #require(intervals["mainactor_delivery"]) - 700) < 0.0001)
    }

    @Test func invalidOrIncompatibleGPUTimeIsUnavailable() throws {
        for (start, end) in [(0.0, 0.0), (.nan, 5), (3, .infinity), (5, 3), (1, 5), (3, 7)] {
            let result = try row(timing(gpuStart: start, gpuEnd: end))
            let intervals = try #require(result["intervalsMs"] as? [String: Double])
            #expect(result["gpuTimingValid"] as? Bool == false)
            #expect(intervals["gpu_execution"] == nil)
            #expect(intervals["commit_to_gpu_start"] == nil)
            #expect(intervals["gpu_end_to_completion"] == nil)
            #expect(intervals["readback"] != nil, "CPU readback remains independently observable")
        }
        #expect(GPULog.ForceTiming.milliseconds(1, .greatestFiniteMagnitude) == nil)
        #expect(GPULog.ForceTiming.milliseconds(2, 2) == 0, "A valid zero duration is distinct from absent timestamps")
    }

    @Test func tokenPublishesCommitAndImmutableMetadata() throws {
        let queue = DispatchQueue(label: "gpu-log-test.token")
        let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
        let writer = GPULog.Writer(queue: queue) { line in lines.withLock { $0.append(line) } }
        let token = try #require(GPULog.start(writer: writer, id: 7, clock: { 1 }))
        #expect(token.committed == 0, "A token cannot fabricate a submission timestamp")
        token.willCommit(clock: { 2 })
        #expect(token.committed == 2)
        var metadata = GPULog.ForceMetadata(nodes: 10)
        metadata.charge = .bruteForce
        metadata.structural = true
        let original = GPULog.ForceTiming(id: 7, metadata: metadata, snapshotEdges: 12, status: 4,
            preparationStarted: token.preparationStarted, committed: token.committed,
            gpuStarted: 3, gpuEnded: 5, completionEntered: 6, mainActorEnqueued: 6.5)
        metadata.nodes = 99
        token.finish(original, clock: { 7 })
        queue.sync {}
        let line = try #require(lines.withLock { $0.first })
        let saved = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let savedMetadata = try #require(saved["metadata"] as? [String: Any])
        #expect(savedMetadata["nodes"] as? Int == 10)
        #expect(savedMetadata["charge"] as? String == "bruteForce")
        #expect(savedMetadata["integrationRequested"] as? Bool == false)
    }

    @Test func slowSinkDropsRecordsWithoutBlockingSubmission() throws {
        let queue = DispatchQueue(label: "gpu-log-test.bounded")
        let lines = OSAllocatedUnfairLock<[(String, Bool)]>(initialState: [])
        let writer = GPULog.Writer(capacity: 2, queue: queue) { line in
            lines.withLock { $0.append((line, Thread.isMainThread)) }
        }
        queue.suspend()
        let first = writer.submit(.message("first"))
        let second = writer.submit(.message("second"))
        let overflow = writer.submit(.message("overflow"))
        queue.resume()
        queue.sync {}
        #expect(first && second && !overflow)
        let saved = lines.withLock { $0 }
        #expect(saved.map(\.0) == ["{\"kind\":\"dropped\",\"records\":1}", "first", "second"])
        #expect(saved.allSatisfy { !$0.1 })
        let next = writer.submit(.message("next"))
        queue.sync {}
        #expect(next, "Draining releases bounded capacity")
        #expect(lines.withLock { $0.last?.0 } == "next")
    }

    @Test func failedSinkStopsWritesAndReleasesCapacity() {
        enum Failure: Error { case sink }
        let queue = DispatchQueue(label: "gpu-log-test.failure")
        let attempts = OSAllocatedUnfairLock<Int>(initialState: 0)
        let writer = GPULog.Writer(capacity: 2, queue: queue) { _ in
            attempts.withLock { $0 += 1 }
            throw Failure.sink
        }
        queue.suspend()
        let first = writer.submit(.message("first"))
        let second = writer.submit(.message("second"))
        queue.resume()
        queue.sync {}
        let next = writer.submit(.message("next"))
        queue.sync {}
        #expect(first && second && next)
        #expect(attempts.withLock { $0 } == 1)
    }
}
