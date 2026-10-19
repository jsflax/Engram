import Foundation

/// Fixed-size, numeric-only diagnostics for MainActor work between scene updates.
/// These process-wide counters are not render phases and must not be added to
/// nested tick timings. One weak scene owner drains them; other scenes cannot
/// steal its interval. A new owner starts with an explicitly incomplete interval.
@MainActor
public final class FrameGapDiagnostics {
    public nonisolated static let isEnabled = enabled(forPath: ProcessInfo.processInfo.environment["ENGRAM_FRAME_STATS"])
    public static let shared = FrameGapDiagnostics(enabled: isEnabled)
    public let enabled: Bool

    public nonisolated static func enabled(forPath path: String?) -> Bool {
        if let path { return !path.isEmpty }
        return false
    }

    /// Disabled production paths do not read the clock. The clock argument also
    /// lets deterministic controls exercise this boundary without sleeping.
    public nonisolated static func timestamp(
        enabled: Bool = isEnabled,
        clock: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) -> UInt64? {
        enabled ? clock() : nil
    }

    public enum ForceOutcome: Sendable {
        case positionsApplied, rejected, rawFallback
    }

    public struct Work: Sendable {
        public fileprivate(set) var count: UInt64 = 0
        public fileprivate(set) var acceptedCount: UInt64 = 0
        public fileprivate(set) var rejectedCount: UInt64 = 0
        public fileprivate(set) var fallbackCount: UInt64 = 0
        public fileprivate(set) var rows: UInt64 = 0
        public fileprivate(set) var durationNanoseconds: UInt64 = 0
        public fileprivate(set) var maximumDurationNanoseconds: UInt64 = 0
        public fileprivate(set) var queueSamples: UInt64 = 0
        public fileprivate(set) var queueNanoseconds: UInt64 = 0
        public fileprivate(set) var maximumQueueNanoseconds: UInt64 = 0

        fileprivate mutating func record(queuedAt: UInt64?, startedAt: UInt64, endedAt: UInt64) {
            count = Self.add(count, 1)
            let elapsed = endedAt >= startedAt ? endedAt - startedAt : 0
            durationNanoseconds = Self.add(durationNanoseconds, elapsed)
            maximumDurationNanoseconds = max(maximumDurationNanoseconds, elapsed)
            // An absent/future enqueue stamp is unavailable, not measured zero.
            if let queuedAt, queuedAt <= startedAt {
                let queued = startedAt - queuedAt
                queueSamples = Self.add(queueSamples, 1)
                queueNanoseconds = Self.add(queueNanoseconds, queued)
                maximumQueueNanoseconds = max(maximumQueueNanoseconds, queued)
            }
        }

        fileprivate static func add(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
            let (sum, overflow) = lhs.addingReportingOverflow(rhs)
            return overflow ? .max : sum
        }
    }

    public struct Sample: Sendable {
        public let sequence: UInt64
        public let previousSequence: UInt64
        public let hasPreviousCallback: Bool
        public let entryIntervalNanoseconds: UInt64
        public let outsideCallbackNanoseconds: UInt64
        public let previousLoggerTailNanoseconds: UInt64
        public let load: Work
        public let force: Work
    }

    // Flags: 1 = this scene owns the process counters, 2 = prior callback is
    // complete. Queue sample counts separately distinguish unknown from zero.
    // Work spans end between callback entries; queue waits can overlap each
    // other and are not additional CPU time. GPU errors/missing readbacks never
    // reach applyGPUForces and are outside these application outcome counts.
    public static let csvHeader = [
        "gap_flags", "gap_callback", "gap_previous_callback", "callback_entry_dt_ms",
        "callback_outside_ms", "previous_logger_tail_ms",
        "load_count", "load_accepted", "load_rejected", "load_rows",
        "load_apply_ms", "load_apply_max_ms", "load_queue_samples", "load_queue_ms", "load_queue_max_ms",
        "force_apply_count", "force_applied", "force_rejected", "force_raw_fallback",
        "force_apply_ms", "force_apply_max_ms", "force_queue_samples", "force_queue_ms", "force_queue_max_ms"
    ].joined(separator: ",")

    public static func csvValues(_ sample: Sample?) -> String {
        guard let sample else { return Array(repeating: "0", count: 24).joined(separator: ",") }
        func ms(_ nanoseconds: UInt64) -> String { String(format: "%.3f", Double(nanoseconds) / 1_000_000) }
        let load = sample.load, force = sample.force
        return [
            sample.hasPreviousCallback ? "3" : "1", String(sample.sequence), String(sample.previousSequence),
            ms(sample.entryIntervalNanoseconds), ms(sample.outsideCallbackNanoseconds),
            ms(sample.previousLoggerTailNanoseconds),
            String(load.count), String(load.acceptedCount), String(load.rejectedCount), String(load.rows),
            ms(load.durationNanoseconds), ms(load.maximumDurationNanoseconds), String(load.queueSamples),
            ms(load.queueNanoseconds), ms(load.maximumQueueNanoseconds),
            String(force.count), String(force.acceptedCount), String(force.rejectedCount), String(force.fallbackCount),
            ms(force.durationNanoseconds), ms(force.maximumDurationNanoseconds), String(force.queueSamples),
            ms(force.queueNanoseconds), ms(force.maximumQueueNanoseconds)
        ].joined(separator: ",")
    }

    private weak var owner: AnyObject?
    private var sequence: UInt64 = 0
    private var entry: UInt64?
    private var exit: UInt64?
    private var loggerTail: UInt64 = 0
    private var load = Work()
    private var force = Work()

    public init(enabled: Bool) { self.enabled = enabled }

    public func recordLoad(rows: Int, accepted: Bool, queuedAt: UInt64?, startedAt: UInt64, endedAt: UInt64) {
        guard enabled else { return }
        load.record(queuedAt: queuedAt, startedAt: startedAt, endedAt: endedAt)
        load.rows = Work.add(load.rows, UInt64(max(0, rows)))
        if accepted { load.acceptedCount = Work.add(load.acceptedCount, 1) }
        else { load.rejectedCount = Work.add(load.rejectedCount, 1) }
    }

    public func recordForce(outcome: ForceOutcome, queuedAt: UInt64?, startedAt: UInt64, endedAt: UInt64) {
        guard enabled else { return }
        force.record(queuedAt: queuedAt, startedAt: startedAt, endedAt: endedAt)
        switch outcome {
        case .positionsApplied: force.acceptedCount = Work.add(force.acceptedCount, 1)
        case .rejected: force.rejectedCount = Work.add(force.rejectedCount, 1)
        case .rawFallback: force.fallbackCount = Work.add(force.fallbackCount, 1)
        }
    }

    /// Called once at update entry, before measured render work. The first drain
    /// includes any startup work but hasPreviousCallback=false: no full interval
    /// or prior logger tail exists yet. Draining resets counts/sums/max together.
    public func beginCallback(owner candidate: AnyObject, at now: UInt64) -> Sample? {
        guard enabled else { return nil }
        if let owner {
            guard owner === candidate else { return nil }
        } else {
            owner = candidate
            entry = nil
            exit = nil
            loggerTail = 0
        }
        let previous = sequence
        sequence = Work.add(sequence, 1)
        let complete = entry != nil && exit != nil && now >= exit! && exit! >= entry!
        let sample = Sample(sequence: sequence, previousSequence: complete ? previous : 0,
            hasPreviousCallback: complete,
            entryIntervalNanoseconds: complete ? now - entry! : 0,
            outsideCallbackNanoseconds: complete ? now - exit! : 0,
            previousLoggerTailNanoseconds: complete ? loggerTail : 0,
            load: load, force: force)
        load = Work()
        force = Work()
        entry = now
        exit = nil
        loggerTail = 0
        return sample
    }

    /// Sample exit after formatting/append/any synchronous flush. Emit this tail
    /// on the next row, not the row whose formatting and write it measures.
    public func finishCallback(owner candidate: AnyObject, bodyEndedAt: UInt64, exitedAt: UInt64) {
        guard enabled, owner === candidate, let entry,
              bodyEndedAt >= entry, exitedAt >= bodyEndedAt else { return }
        exit = exitedAt
        loggerTail = exitedAt - bodyEndedAt
    }
}
