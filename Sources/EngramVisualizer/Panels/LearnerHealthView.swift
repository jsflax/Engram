import SwiftUI

struct LearnerHealthView: View {
    @AppStorage("learnerHealth.selectedSessionID") private var sessionID = ""
    @State private var snapshot: LearnerHealthSnapshot?
    @State private var refreshedAt: Date?
    @State private var errorMessage: String?
    @State private var isReading = false
    private let codexHome = LearnerHealthReader.codexHome

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Inspect one Codex task on this Mac. Paste its UUID from the task link.")
                .foregroundStyle(.secondary)
            TextField("Codex task UUID", text: $sessionID)
                .textFieldStyle(.roundedBorder)
                .disabled(isReading)
                .accessibilityIdentifier("learner-health.session-id")
                .onChange(of: sessionID) {
                    snapshot = nil
                    refreshedAt = nil
                    errorMessage = nil
                }
            Button(action: refresh) {
                Label(isReading ? "Reading metadata…" : "Check learner health", systemImage: "arrow.clockwise")
            }
            .disabled(isReading || sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("learner-health.refresh")

            if let errorMessage { Text(errorMessage).foregroundStyle(.orange) }
            if let snapshot {
                healthDetails(snapshot.learner.health)
                if let refreshedAt {
                    Text("Snapshot: \(refreshedAt.formatted(date: .abbreviated, time: .standard))")
                        .foregroundStyle(.secondary)
                }
                Text("Recorded metadata only. Worker activity and stored memories are not independently checked.")
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup("Metadata location") {
                Text(codexHome).textSelection(.enabled).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func refresh() {
        let selectedID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedHome = codexHome
        isReading = true
        errorMessage = nil
        snapshot = nil
        refreshedAt = nil
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try LearnerHealthReader.read(sessionID: selectedID, codexHome: selectedHome) }
            }.value
            // AppStorage can change from another window while this read runs.
            guard sessionID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == selectedID.lowercased() else {
                isReading = false
                return
            }
            switch result {
            case .success(let value):
                snapshot = value
                refreshedAt = Date()
            case .failure(let error):
                errorMessage = (error as? LearnerHealthReadError)?.errorDescription
                    ?? LearnerHealthReadError.unavailable.errorDescription
            }
            isReading = false
        }
    }

    @ViewBuilder
    private func healthDetails(_ health: LearnerHealthSnapshot.Health) -> some View {
        Text(health.title).fontWeight(.semibold)
            .accessibilityIdentifier("learner-health.headline")
        row("Policy", label(health.policy.state))
        row("Activity", label(health.activity.state))
        row("Queue", label(health.outcomes.queue.state))
        row("Provider", label(health.outcomes.providerCompletion.state))
        row("Native writes", label(health.outcomes.nativeAcknowledgement.state))
        if let settlement = health.outcomes.recordedSettlement {
            row("Run verification", label(settlement.state))
        }
        row("Readback", label(health.outcomes.independentReadback.state))
        Text(health.recoveryText).foregroundStyle(.secondary)

        DisclosureGroup("Progress and receipts") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(health.holds.enumerated()), id: \.offset) { _, hold in
                    Text("Hold: \(label(hold.kind))")
                    if let run = hold.runId { Text("Run: \(run)").textSelection(.enabled) }
                }
                if let bytes = health.progress.backlog.bytes {
                    row("Snapshot backlog", "\(bytes.formatted()) bytes")
                } else {
                    row("Snapshot backlog", label(health.progress.backlog.state))
                }
                Text("Backlog uses the pending snapshot; newer transcript content is not inspected.")
                if let cursor = health.progress.cursorOffset { row("Cursor", cursor.formatted()) }
                if let frontier = health.progress.enrollmentFrontierOffset { row("Enrollment frontier", frontier.formatted()) }
                let interval = health.progress.lastCompletedInterval
                if let start = interval.startOffset, let end = interval.endOffset {
                    row("Completed interval", "\(start.formatted())–\(end.formatted())")
                    row("Interval evidence", label(interval.evidence))
                } else if let end = interval.endOffset {
                    row("Completed end", "\(end.formatted()) (legacy receipt)")
                } else {
                    row("Completed interval", "No qualifying receipt in this window")
                }
                if let counts = health.outcomes.writeAttempts,
                   counts.attemptedWriteCalls != nil || counts.appliedWriteCalls != nil || counts.unchangedWriteCalls != nil {
                    Text("Run receipt counts").fontWeight(.semibold)
                    writeCounts(attempted: counts.attemptedWriteCalls, applied: counts.appliedWriteCalls,
                                unchanged: counts.unchangedWriteCalls)
                }
                if let settlement = health.outcomes.recordedSettlement, let receipt = settlement.receipt {
                    Text("Saved run receipt counts").fontWeight(.semibold)
                    row("Task link", label(settlement.state))
                    row("Recorded outcome", label(receipt.status))
                    writeCounts(attempted: receipt.attemptedWriteCalls, applied: receipt.appliedWriteCalls,
                                unchanged: receipt.unchangedWriteCalls)
                    Text("This saved receipt is not an independent check of the stored memories.")
                }
                if let timestamp = health.progress.lastSuccessTimestampClaim {
                    Text("Historical success timestamp: \(timestamp)")
                    Text("This timestamp does not establish current health.")
                }
                row("Failure class", label(health.failure.category))
                if let count = health.failure.diagnosticErrorCount {
                    Text("\(count) aggregate diagnostic errors across provider, gateway, and transport; this is not a count of distinct failed writes.")
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func writeCounts(attempted: Int?, applied: Int?, unchanged: Int?) -> some View {
        if let attempted { row("Attempted writes", attempted.formatted()) }
        if let applied { row("Applied writes", applied.formatted()) }
        if let unchanged { row("Unchanged writes", unchanged.formatted()) }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(name).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing)
        }
    }

    /// Presentation of the reader's enums only; never derives a health state.
    private func label(_ code: String) -> String {
        switch code {
        case "processing_unverified", "processing_marker": "Processing recorded; activity unverified"
        case "publication_recovery_pending": "Unfinished progress update"
        case "session_hash_match": "Linked to this task"
        case "recorded_in_anchored_settlement": "Recorded in linked receipt"
        case "anchored_settlement_receipt": "Run receipt linked to this task"
        case "unanchored": "No matching task link"
        case "hash_mismatch": "Does not match this task"
        case "completed_in_run_receipt": "Completed (receipt)"
        case "not_completed_in_run_receipt": "Incomplete (receipt)"
        case "acknowledged_in_run_receipt": "Acknowledged (receipt)"
        case "not_performed": "Not independently checked"
        case "none_recorded": "None recorded"
        case "known_at_pending_snapshot": "Known at pending snapshot"
        default: code.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
