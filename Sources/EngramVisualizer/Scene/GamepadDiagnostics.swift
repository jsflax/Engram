import Foundation

struct GamepadControllerDescription: Codable, Sendable {
    let productCategory: String
    let vendorName: String?
    let controllerClass: String
    let extendedProfileClass: String?
}

struct GamepadEnumerationDiagnostics: Codable, Sendable {
    let connectedCount: Int
    let supportedCount: Int
    let connected: [GamepadControllerDescription]
    let current: GamepadControllerDescription?
    let selected: GamepadControllerDescription?
    let selection: String
    let currentConnectedIndex: Int?
    let selectedConnectedIndex: Int?
}

struct GamepadInputReading {
    let state: GamepadInputState?
    let enumeration: GamepadEnumerationDiagnostics?
}

struct GamepadDiagnosticConfiguration {
    let url: URL
    let duration: TimeInterval

    init?(environment: [String: String]) {
        guard let path = environment["ENGRAM_CONTROLLER_STATS"], path.hasPrefix("/"),
              !path.hasSuffix("/") else { return nil }
        url = URL(fileURLWithPath: path)
        let requested = environment["ENGRAM_CONTROLLER_STATS_SECONDS"].flatMap(Double.init) ?? 120
        duration = requested.isFinite && requested > 0 ? min(600, max(1, requested)) : 120
    }
}

/// One initial waiting row, then <=1 Hz after the graph's first active key
/// window, and one terminal row. Focus rejection does not prevent arming.
struct GamepadDiagnosticCadence {
    enum Phase: String, Codable, Sendable { case waiting, capturing, finished }
    let duration: TimeInterval
    private(set) var armedAt: TimeInterval?
    private(set) var finished = false
    private var lastRecordAt: TimeInterval?

    init(duration: TimeInterval) {
        self.duration = duration.isFinite && duration > 0 ? min(600, max(1, duration)) : 120
    }

    mutating func next(now: TimeInterval, armReady: Bool) -> Phase? {
        guard !finished, now.isFinite else { return nil }
        if armedAt == nil, armReady {
            armedAt = now
            lastRecordAt = now
            return .capturing
        }
        guard let armedAt else {
            guard lastRecordAt == nil else { return nil }
            lastRecordAt = now
            return .waiting
        }
        if now - armedAt >= duration {
            finished = true
            lastRecordAt = now
            return .finished
        }
        guard now - (lastRecordAt ?? now) >= 1 else { return nil }
        lastRecordAt = now
        return .capturing
    }
}

struct GamepadGateDiagnostics: Codable, Sendable {
    let graphHostVisible: Bool
    let hostAppearsActive: Bool?
    let mascotChatVisible: Bool?
    let graphInputActive: Bool
    let appActive: Bool
    let keyWindowNumber: Int?
    let attachedSheet: Bool
    let firstResponderClass: String?
    let firstResponderIsTextView: Bool
    /// Nil when the graph gate short-circuited this closure.
    let applicationGateAccepted: Bool?
    let inputAccepted: Bool
}

struct GamepadInputSummary: Codable, Sendable {
    let hasState: Bool
    let nonzeroAnalog: Bool
    let movementPastDeadzone: Bool
    let actionButtonPressed: Bool
    let sprintPressed: Bool

    init(_ state: GamepadInputState?) {
        hasState = state != nil
        guard let state else {
            nonzeroAnalog = false; movementPastDeadzone = false
            actionButtonPressed = false; sprintPressed = false
            return
        }
        nonzeroAnalog = state.leftX != 0 || state.leftY != 0 || state.rightX != 0
            || state.rightY != 0 || state.leftTrigger != 0 || state.rightTrigger != 0
        movementPastDeadzone = abs(state.leftX) > 0.1 || abs(state.leftY) > 0.1
            || abs(state.rightX) > 0.1 || abs(state.rightY) > 0.1
            || state.leftTrigger > 0.05 || state.rightTrigger > 0.05
        actionButtonPressed = !state.buttons.isEmpty
        sprintPressed = state.sprint
    }

    var nonNeutral: Bool { nonzeroAnalog || actionButtonPressed || sprintPressed }
}

struct GamepadDiagnosticCounts: Codable, Sendable {
    var frames = 0
    var framesWithState = 0
    var framesWithNonNeutralInput = 0
    var framesWithMovementPastDeadzone = 0
    var framesWithAcceptedMovementInput = 0
    var framesWithAcceptedGate = 0
    var framesWithCameraTargetChange = 0
    var framesWithCameraLookChange = 0
}

struct GamepadDiagnosticRecord: Codable, Sendable {
    let schemaVersion: Int
    let processID: Int32
    let phase: GamepadDiagnosticCadence.Phase
    let uptime: TimeInterval
    let captureElapsed: TimeInterval?
    let captureDuration: TimeInterval
    let enumeration: GamepadEnumerationDiagnostics?
    let input: GamepadInputSummary
    let gate: GamepadGateDiagnostics
    let sincePreviousRecord: GamepadDiagnosticCounts
}

@MainActor
final class GamepadDiagnosticRecorder {
    private var cadence: GamepadDiagnosticCadence
    private var counts = GamepadDiagnosticCounts()
    private let emit: (GamepadDiagnosticRecord) -> Void

    init(configuration: GamepadDiagnosticConfiguration,
         emit: @escaping (GamepadDiagnosticRecord) -> Void) {
        cadence = GamepadDiagnosticCadence(duration: configuration.duration)
        self.emit = emit
    }

    static func fromEnvironment() -> GamepadDiagnosticRecorder? {
        guard let configuration = GamepadDiagnosticConfiguration(environment: ProcessInfo.processInfo.environment)
        else { return nil }
        let writer = GamepadDiagnosticFileWriter(url: configuration.url)
        return GamepadDiagnosticRecorder(configuration: configuration) { writer.append($0) }
    }

    var isFinished: Bool { cadence.finished }

    /// Decide before polling whether this frame needs product/profile metadata.
    func nextPhase(now: TimeInterval, armReady: Bool) -> GamepadDiagnosticCadence.Phase? {
        cadence.next(now: now, armReady: armReady)
    }

    func observe(now: TimeInterval, phase: GamepadDiagnosticCadence.Phase?,
                 reading: GamepadInputReading, gate: GamepadGateDiagnostics?,
                 inputAccepted: Bool, cameraTargetChanged: Bool, cameraLookChanged: Bool) {
        let summary = GamepadInputSummary(reading.state)
        counts.frames += 1
        if summary.hasState { counts.framesWithState += 1 }
        if summary.nonNeutral { counts.framesWithNonNeutralInput += 1 }
        if summary.movementPastDeadzone {
            counts.framesWithMovementPastDeadzone += 1
            if inputAccepted { counts.framesWithAcceptedMovementInput += 1 }
        }
        if inputAccepted { counts.framesWithAcceptedGate += 1 }
        if cameraTargetChanged { counts.framesWithCameraTargetChange += 1 }
        if cameraLookChanged { counts.framesWithCameraLookChange += 1 }
        guard let phase, let gate else { return }
        emit(GamepadDiagnosticRecord(schemaVersion: 1, processID: ProcessInfo.processInfo.processIdentifier,
            phase: phase, uptime: now, captureElapsed: cadence.armedAt.map { now - $0 },
            captureDuration: cadence.duration, enumeration: reading.enumeration,
            input: summary, gate: gate, sincePreviousRecord: counts))
        counts = GamepadDiagnosticCounts()
    }
}

/// All encoding/file access stays on this serial queue. A fresh file is
/// required; never mix a new process's diagnostics into an old capture.
private final class GamepadDiagnosticFileWriter: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "engram.controller-diagnostics", qos: .utility)
    private var handle: FileHandle?
    private var failed = false

    init(url: URL) { self.url = url }

    func append(_ record: GamepadDiagnosticRecord) {
        queue.async { [self] in
            guard !failed else { return }
            do {
                var line = try JSONEncoder().encode(record)
                line.append(0x0a)
                if let handle {
                    try handle.write(contentsOf: line)
                } else {
                    try line.write(to: url, options: .withoutOverwriting)
                    handle = try FileHandle(forWritingTo: url)
                    try handle?.seekToEnd()
                }
                if record.phase == .finished {
                    try handle?.close()
                    handle = nil
                }
            } catch {
                failed = true
                try? handle?.close()
                handle = nil
            }
        }
    }

    deinit { try? handle?.close() }
}
