import AppKit
import SwiftUI

/// Monotonic-clock diagnostic phases. `begin` is the recorder call, which may
/// follow an action's live guard; it is deliberately not labeled action entry.
struct PanelResponsePhases: Sendable {
    let eventToBeginMilliseconds: Double
    let beginToMutationReturnMilliseconds: Double?
    let mutationReturnToDrawMilliseconds: Double?
    let beginToDrawMilliseconds: Double

    init(eventTimestamp: TimeInterval, beginTimestamp: TimeInterval,
         mutationReturnTimestamp: TimeInterval?, drawTimestamp: TimeInterval) {
        eventToBeginMilliseconds = (beginTimestamp - eventTimestamp) * 1000
        beginToMutationReturnMilliseconds = mutationReturnTimestamp.map { ($0 - beginTimestamp) * 1000 }
        mutationReturnToDrawMilliseconds = mutationReturnTimestamp.map { (drawTimestamp - $0) * 1000 }
        beginToDrawMilliseconds = (drawTimestamp - beginTimestamp) * 1000
    }

    var csvValues: String {
        let values: [Double?] = [eventToBeginMilliseconds, beginToMutationReturnMilliseconds,
                                 mutationReturnToDrawMilliseconds, beginToDrawMilliseconds]
        return values
            .map { value in value.map { String(format: "%.3f", $0) } ?? "" }
            .joined(separator: ",")
    }
}

/// Records event-to-first-draw latency, excluding XCTest's accessibility polling.
/// Enabled only when the profiling harness supplies its own output path.
@MainActor
enum PanelResponseRecorder {
    private static let outputPath = ProcessInfo.processInfo.environment["ENGRAM_PANEL_STATS"]
    static var isEnabled: Bool { outputPath != nil }
    private struct Start {
        let timestamp: TimeInterval
        let clockOrigin: String
        let beginTimestamp: TimeInterval
        var mutationReturnTimestamp: TimeInterval?
    }
    private static var pending: [String: Start] = [:]
    private static let writer = DispatchQueue(label: "engram.panel-response-csv", qos: .utility)

    static func begin(_ name: String) {
        guard isEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let event = NSApp.currentEvent, event.timestamp > 0, event.timestamp <= now,
           [.leftMouseDown, .leftMouseUp, .keyDown, .keyUp, .mouseMoved,
            .mouseEntered, .mouseExited, .cursorUpdate].contains(event.type) {
            // NSEvent timestamps and systemUptime are both seconds since boot.
            // Do not cap old timestamps: a queued input delayed by a long main
            // thread stall must retain its full measured latency.
            pending[name] = Start(timestamp: event.timestamp, clockOrigin: "event", beginTimestamp: now)
        } else {
            // Programmatic appearance has no valid input latency. Keep a draw
            // measurement, but mark it so the strict UI gate cannot count it.
            pending[name] = Start(timestamp: now, clockOrigin: "callback", beginTimestamp: now)
        }
    }

    static func mutationReturned(_ name: String) {
        guard isEnabled, var start = pending[name] else { return }
        start.mutationReturnTimestamp = ProcessInfo.processInfo.systemUptime
        pending[name] = start
    }

    static func didDraw(_ name: String) {
        guard let path = outputPath, let start = pending.removeValue(forKey: name) else { return }
        let drawTimestamp = ProcessInfo.processInfo.systemUptime
        let elapsed = (drawTimestamp - start.timestamp) * 1000
        let line = "\(name),\(String(format: "%.3f", elapsed)),\(start.clockOrigin)\n"
        let phases = PanelResponsePhases(eventTimestamp: start.timestamp,
                                         beginTimestamp: start.beginTimestamp,
                                         mutationReturnTimestamp: start.mutationReturnTimestamp,
                                         drawTimestamp: drawTimestamp)
        let clockOrigin = start.clockOrigin
        writer.async {
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: Data("action,response_ms,clock_origin\n".utf8))
            }
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch { }

            // Keep the original CSV and gate unchanged; diagnostic phases are
            // separately identifiable and optional for non-mutation actions.
            let phasePath = path + ".phases.csv"
            if !FileManager.default.fileExists(atPath: phasePath) {
                let header = "action,clock_origin,event_to_begin_ms,begin_to_mutation_return_ms,mutation_return_to_draw_ms,begin_to_draw_ms\n"
                FileManager.default.createFile(atPath: phasePath, contents: Data(header.utf8))
            }
            guard let phaseHandle = FileHandle(forWritingAtPath: phasePath) else { return }
            defer { try? phaseHandle.close() }
            do {
                try phaseHandle.seekToEnd()
                try phaseHandle.write(contentsOf: Data("\(name),\(clockOrigin),\(phases.csvValues)\n".utf8))
            } catch { }
        }
    }

    static func cancel(_ name: String) {
        pending.removeValue(forKey: name)
    }
}

private struct PanelResponseView: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> ProbeView { ProbeView(name: name) }
    func updateNSView(_ view: ProbeView, context: Context) {
        view.name = name
        view.needsDisplay = true
    }

    final class ProbeView: NSView {
        var name: String
        init(name: String) {
            self.name = name
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) { PanelResponseRecorder.didDraw(name) }
    }
}

extension View {
    @MainActor @ViewBuilder
    func panelResponseProbe(_ name: String) -> some View {
        if PanelResponseRecorder.isEnabled {
            background(PanelResponseView(name: name).allowsHitTesting(false))
        } else {
            self
        }
    }
}
