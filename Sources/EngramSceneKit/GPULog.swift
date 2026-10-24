import Foundation
import QuartzCore
import os

/// Explicit opt-in diagnostics. File writes and force-record formatting run on
/// one bounded background queue; a slow sink drops records instead of stalling
/// rendering. This is not a crash-safe log: an abrupt exit can lose its tail.
public enum GPULog {
    private static let configured = OSAllocatedUnfairLock<Writer?>(initialState: nil)
    @MainActor private static var forceWriter: Writer?
    @MainActor private static var nextDispatch: UInt64 = 0
    private static let requested = !(ProcessInfo.processInfo.environment["ENGRAM_GPU_LOG"] ?? "").isEmpty

    /// Configure once before scene work, in both the ordinary and preview apps.
    @MainActor public static func configure(path: String) {
        guard !path.isEmpty, forceWriter == nil else { return }
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil) else { return }
        }
        guard let file = FileHandle(forWritingAtPath: path),
              (try? file.seekToEnd()) != nil else { return }
        let writer = Writer { line in try file.write(contentsOf: Data((line + "\n").utf8)) }
        forceWriter = writer
        configured.withLock { $0 = writer }
        writer.submit(.message("--- GPU diagnostics v1; host clock is mach time in seconds ---"))
    }

    /// Disabled calls do not evaluate interpolations or read a clock.
    public nonisolated static func log(_ message: @autoclosure () -> String) {
        guard requested, let writer = configured.withLock({ $0 }) else { return }
        writer.submit(.message(message()))
    }

    static func hostTime() -> Double { CACurrentMediaTime() }

    @MainActor static func beginForce(writer: Writer? = nil, clock: () -> Double = CACurrentMediaTime) -> Token? {
        guard let writer = writer ?? forceWriter else { return nil }
        nextDispatch &+= 1
        return start(writer: writer, id: nextDispatch, clock: clock)
    }

    // Injectable boundary for deterministic disabled-path coverage.
    static func start(writer: Writer?, id: UInt64, clock: () -> Double) -> Token? {
        guard let writer else { return nil }
        return Token(writer: writer, id: id, preparationStarted: clock())
    }

    public struct ForceMetadata: Sendable, Encodable, Equatable {
        public enum Charge: String, Sendable, Encodable { case none, barnesHut, bruteForce }
        public var nodes: Int
        public var csrEdges: Int?
        public var projects: Int?
        public var topics: Int?
        public var galaxies: Int?
        public var charge: Charge = .none
        public var treeNodes: Int?
        public var structural = false
        public var integrationRequested = false
    }

    struct Token: Sendable {
        let writer: Writer
        let id: UInt64
        let preparationStarted: Double
        // Shared only between the commit caller and its completion handler.
        private let commitTime = OSAllocatedUnfairLock<Double?>(initialState: nil)

        init(writer: Writer, id: UInt64, preparationStarted: Double) {
            self.writer = writer
            self.id = id
            self.preparationStarted = preparationStarted
        }

        func willCommit(clock: () -> Double = CACurrentMediaTime) {
            let now = clock()
            commitTime.withLock { $0 = now }
        }

        var committed: Double { commitTime.withLock { $0 ?? 0 } }

        func finish(_ timing: ForceTiming, clock: () -> Double = CACurrentMediaTime) {
            var row = timing
            row.mainActorEntered = clock()
            writer.submit(.force(row))
        }
    }

    /// Raw host timestamps and derived wall intervals. Missing/invalid Metal
    /// timestamps are unavailable, never a measured zero. GPU execution is not
    /// an occupancy percentage; commit-to-start also includes driver/dependency
    /// work. MainActor delivery starts after completion processing, including
    /// readback when available (errors can deliver without readback).
    struct ForceTiming: Sendable {
        let id: UInt64
        let metadata: ForceMetadata?
        let snapshotEdges: Int
        let status: Int
        let preparationStarted: Double
        let committed: Double
        let gpuStarted: Double
        let gpuEnded: Double
        let completionEntered: Double
        var readbackStarted: Double?
        var readbackEnded: Double?
        var mainActorEnqueued: Double?
        var mainActorEntered: Double?

        static func valid(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value > 0 else { return nil }
            return value
        }

        static func milliseconds(_ start: Double?, _ end: Double?) -> Double? {
            guard let start = valid(start), let end = valid(end), end >= start else { return nil }
            let value = (end - start) * 1000
            return value.isFinite ? value : nil
        }

        // Metal and CACurrentMediaTime both use mach host time. Require the
        // entire GPU range inside its host submission/completion envelope;
        // nonzero but incompatible clock values must not look like measurements.
        var gpuTimingValid: Bool {
            guard let prepared = Self.valid(preparationStarted),
                  let commit = Self.valid(committed), let start = Self.valid(gpuStarted),
                  let end = Self.valid(gpuEnded), let completion = Self.valid(completionEntered),
                  prepared <= commit, commit <= start, start <= end, end <= completion else { return false }
            return Self.milliseconds(commit, completion) != nil
        }

        func jsonLine() -> String {
            struct Row: Encodable {
                let kind = "force"
                let version = 1
                let id: UInt64
                let metadata: ForceMetadata?
                let snapshotEdges: Int
                let status: Int
                let gpuTimingValid: Bool
                let hostSeconds: [String: Double]
                let intervalsMs: [String: Double]
            }
            let stamps: [String: Double?] = [
                "preparation_started": preparationStarted, "committed": committed,
                "gpu_started": gpuStarted, "gpu_ended": gpuEnded,
                "completion_entered": completionEntered, "readback_started": readbackStarted,
                "readback_ended": readbackEnded, "mainactor_enqueued": mainActorEnqueued,
                "mainactor_entered": mainActorEntered
            ]
            let intervals: [String: Double?] = [
                "preparation_to_commit": Self.milliseconds(preparationStarted, committed),
                "commit_to_gpu_start": gpuTimingValid ? Self.milliseconds(committed, gpuStarted) : nil,
                "gpu_execution": gpuTimingValid ? Self.milliseconds(gpuStarted, gpuEnded) : nil,
                "gpu_end_to_completion": gpuTimingValid ? Self.milliseconds(gpuEnded, completionEntered) : nil,
                "readback": Self.milliseconds(readbackStarted, readbackEnded),
                "mainactor_delivery": Self.milliseconds(mainActorEnqueued, mainActorEntered)
            ]
            let row = Row(id: id, metadata: metadata, snapshotEdges: snapshotEdges, status: status, gpuTimingValid: gpuTimingValid,
                          hostSeconds: stamps.compactMapValues(Self.valid),
                          intervalsMs: intervals.compactMapValues { $0 })
            // Only bounded numeric data is encoded. Invalid timestamps were
            // removed above; retain an explicit diagnostic if encoding fails.
            guard let data = try? JSONEncoder().encode(row), let line = String(data: data, encoding: .utf8) else {
                return "{\"kind\":\"encoding_error\",\"id\":\(id)}"
            }
            return line
        }
    }

    enum Entry: Sendable {
        case message(String), force(ForceTiming)
        func line() -> String {
            switch self {
            case .message(let message): return message
            case .force(let timing): return timing.jsonLine()
            }
        }
    }

    /// At most `capacity` closures/records can wait for the writer. Submission
    /// uses a nonblocking permit and a short dropped-counter lock on overflow;
    /// it never waits for the sink or formats a force record.
    final class Writer: @unchecked Sendable {
        private let queue: DispatchQueue
        private let slots: DispatchSemaphore
        private let dropped = OSAllocatedUnfairLock<UInt64>(initialState: 0)
        private let write: @Sendable (String) throws -> Void
        // Accessed only on queue. A failed sink stays failed for this launch.
        private var failed = false

        init(capacity: Int = 256, queue: DispatchQueue = DispatchQueue(label: "engram.gpu-log", qos: .utility),
             write: @escaping @Sendable (String) throws -> Void) {
            precondition(capacity > 0)
            self.queue = queue
            slots = DispatchSemaphore(value: capacity)
            self.write = write
        }

        @discardableResult func submit(_ entry: Entry) -> Bool {
            guard slots.wait(timeout: .now()) == .success else {
                dropped.withLock { if $0 != .max { $0 += 1 } }
                return false
            }
            queue.async { [self] in
                defer { slots.signal() }
                guard !failed else { return }
                let lost = dropped.withLock { let value = $0; $0 = 0; return value }
                do {
                    if lost > 0 { try write("{\"kind\":\"dropped\",\"records\":\(lost)}") }
                    try write(entry.line())
                } catch { failed = true }
            }
            return true
        }
    }
}
