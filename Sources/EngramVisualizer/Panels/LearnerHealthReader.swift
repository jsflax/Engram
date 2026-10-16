import Foundation
import Darwin

/// A projection of the shared, versioned Python read model. No health decisions
/// are inferred from timestamps, pause reasons, or receipt counts in the UI.
struct LearnerHealthSnapshot: Decodable, Sendable {
    struct Learner: Decodable, Sendable { let health: Health }
    struct State: Decodable, Sendable { let state: String }
    struct Policy: Decodable, Sendable { let state: String; let mode: String? }
    struct Activity: Decodable, Sendable {
        let state: String
        let pendingPauseReason: String?
    }
    struct Hold: Decodable, Sendable {
        let kind: String
        let runId: String?
        let reason: String?
    }
    struct Backlog: Decodable, Sendable { let state: String; let bytes: Int64? }
    struct Interval: Decodable, Sendable {
        let evidence: String
        let runId: String?
        let startOffset: Int64?
        let endOffset: Int64?
        let endedAt: String?

        enum CodingKeys: String, CodingKey { case evidence, runId, startOffset, endOffset, endedAt }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            evidence = try values.decode(String.self, forKey: .evidence)
            runId = try values.decodeIfPresent(String.self, forKey: .runId)
            endOffset = try values.decodeIfPresent(Int64.self, forKey: .endOffset)
            endedAt = try values.decodeIfPresent(String.self, forKey: .endedAt)
            if !values.contains(.startOffset) || (try? values.decodeNil(forKey: .startOffset)) == true {
                startOffset = nil
            } else if let offset = try? values.decode(Int64.self, forKey: .startOffset) {
                startOffset = offset
            } else if (try? values.decode(String.self, forKey: .startOffset)) == "not_recorded" {
                // The existing legacy receipt projection uses this exact value.
                startOffset = nil
            } else {
                throw DecodingError.dataCorruptedError(forKey: .startOffset, in: values,
                                                       debugDescription: "Invalid interval start")
            }
        }
    }
    struct Progress: Decodable, Sendable {
        let backlog: Backlog
        let lastCompletedInterval: Interval
        let cursorOffset: Int64?
        let enrollmentFrontierOffset: Int64?
        let pendingSnapshotOffset: Int64?
        let lastSuccessTimestampClaim: String?
    }
    struct Failure: Decodable, Sendable {
        let category: String
        let diagnosticErrorCount: Int?
        enum CodingKeys: String, CodingKey {
            case category = "class", diagnosticErrorCount
        }
    }
    struct Recovery: Decodable, Sendable { let action: String }
    struct WriteCounts: Decodable, Sendable {
        let attemptedWriteCalls: Int?
        let appliedWriteCalls: Int?
        let unchangedWriteCalls: Int?
    }
    struct NativeAcknowledgement: Decodable, Sendable {
        let state: String
        let attemptedWriteCalls: Int?
        let appliedWriteCalls: Int?
        let unchangedWriteCalls: Int?
    }
    struct SourceInterval: Decodable, Sendable { let startOffset: Int64; let endOffset: Int64 }
    struct SettlementReceipt: Decodable, Sendable {
        let status: String
        let reason: String
        let runId: String
        let source: SourceInterval
        let attemptedWriteCalls: Int
        let appliedWriteCalls: Int
        let unchangedWriteCalls: Int
    }
    struct RecordedSettlement: Decodable, Sendable {
        let state: String
        let receipt: SettlementReceipt?
    }
    struct Outcomes: Decodable, Sendable {
        let queue: State
        let providerCompletion: State
        let nativeAcknowledgement: NativeAcknowledgement
        let writeAttempts: WriteCounts?
        let recordedSettlement: RecordedSettlement?
        let independentReadback: State
    }
    struct Health: Decodable, Sendable {
        let schemaVersion: Int
        let headline: String
        let policy: Policy
        let activity: Activity
        let holds: [Hold]
        let progress: Progress
        let failure: Failure
        let recovery: Recovery
        let outcomes: Outcomes

        var title: String {
            switch headline {
            case "reconciliation_required": "Held for reconciliation"
            case "identity_migration_hold": "Held for identity migration"
            case "publication_recovery_pending": "Progress update needs recovery"
            case "processing_unverified": "Processing marker — activity unverified"
            case "failed": "Needs inspection"
            case "disabled": "Disabled"
            case "backoff": "Waiting before retry"
            case "batch_limit": "Paused at batch limit"
            case "paused": "Paused"
            case "queued": "Queued"
            case "idle": "Idle"
            default: "Health unknown"
            }
        }

        var recoveryText: String {
            switch recovery.action {
            case "reconcile_held_run": "Reconcile the held run before resuming."
            case "review_identity_migration": "Review the identity migration hold."
            case "recover_publication": "Recover the unfinished progress update before learning from this task again."
            case "inspect_processing_attempt": "Inspect the recorded processing attempt before retrying."
            case "wait_for_backoff_then_resume": "Wait for backoff to expire, then resume the pending request."
            case "resume_pending": "The pending request needs a supported resume."
            case "inspect_failure": "Inspect the failure before resuming."
            case "enable_policy": "Enable the learner policy to allow future work."
            case "none": "No recovery action reported."
            default: "Inspect the learner metadata."
            }
        }
    }

    let status: String
    let sessionId: String
    let learner: Learner

    static func decode(_ data: Data, sessionID: String) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let snapshot = try? decoder.decode(Self.self, from: data),
              snapshot.status == "ok", snapshot.sessionId.lowercased() == sessionID.lowercased(),
              snapshot.learner.health.schemaVersion == 1 else {
            throw LearnerHealthReadError.invalidReport
        }
        return snapshot
    }
}

enum LearnerHealthReadError: Error, LocalizedError, Equatable {
    case invalidSession, invalidHome, missingReader, missingPython, unavailable, timeout, outputLimit, invalidReport

    var errorDescription: String? {
        switch self {
        case .invalidSession: "Enter a complete Codex task UUID."
        case .invalidHome: "CODEX_HOME must be an absolute path without parent-directory components."
        case .missingReader: "The health reader is missing from this app bundle. Install an updated Engram build."
        case .missingPython: "Python 3 is required by the bundled hook metadata reader."
        case .unavailable: "The learner metadata reader could not complete."
        case .timeout: "The metadata read timed out. Try refreshing again."
        case .outputLimit: "The metadata response exceeded its size limit."
        case .invalidReport: "Learner health is unavailable or uses an unsupported report version."
        }
    }
}

enum LearnerHealthReader {
    static var codexHome: String {
        ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
    }

    static func read(sessionID: String, codexHome: String) throws -> LearnerHealthSnapshot {
        guard let resources = Bundle.main.resourceURL else { throw LearnerHealthReadError.missingReader }
        let script = resources.appendingPathComponent("cli/codex/hook_status.py")
        guard FileManager.default.isReadableFile(atPath: script.path) else { throw LearnerHealthReadError.missingReader }
        guard let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw LearnerHealthReadError.missingPython
        }
        return try run(script: script, python: URL(fileURLWithPath: python),
                       sessionID: sessionID, codexHome: codexHome)
    }

    /// Synchronous work runs off the main actor. Both output and wall time are
    /// bounded; stderr is discarded, and no raw subprocess errors reach the UI.
    static func run(script: URL, python: URL, sessionID: String, codexHome: String,
                    timeout: TimeInterval = 4, outputLimit: Int = 49_153) throws -> LearnerHealthSnapshot {
        guard sessionID.count == 36, let uuid = UUID(uuidString: sessionID),
              uuid.uuidString.lowercased() == sessionID.lowercased() else {
            throw LearnerHealthReadError.invalidSession
        }
        guard codexHome.hasPrefix("/"), !codexHome.split(separator: "/").contains("..") else {
            throw LearnerHealthReadError.invalidHome
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = python
        // Isolated mode excludes user site packages, PYTHONPATH, and the current
        // working directory from import resolution. The reader uses stdlib only.
        process.arguments = ["-I", "-B", script.path, "--session-id", uuid.uuidString.lowercased()]
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                               "CODEX_HOME": codexHome, "PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let handle = output.fileHandleForReading
        defer { try? handle.close(); try? output.fileHandleForWriting.close() }
        let descriptor = handle.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else { throw LearnerHealthReadError.unavailable }
        do { try process.run() } catch { throw LearnerHealthReadError.unavailable }
        try? output.fileHandleForWriting.close()
        defer {
            if process.isRunning {
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.1
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var reachedEOF = false
        while true {
            // Checking the deadline on every read also bounds a writer that
            // continuously keeps the pipe readable.
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw LearnerHealthReadError.timeout }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard data.count + count <= outputLimit else { throw LearnerHealthReadError.outputLimit }
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 { reachedEOF = true }
            if count < 0 && errno != EAGAIN && errno != EINTR { throw LearnerHealthReadError.unavailable }
            if reachedEOF && !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard process.terminationStatus == 0 else { throw LearnerHealthReadError.unavailable }
        return try LearnerHealthSnapshot.decode(data, sessionID: uuid.uuidString)
    }
}
