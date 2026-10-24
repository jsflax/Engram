import Foundation

/// Standalone checks: compile the actual reader without the app's large graphics
/// and Lattice dependency graph. All generated files go in the supplied scratch.
@main
enum LearnerHealthReaderChecks {
    static let sessionID = "11111111-2222-4333-8444-555555555555"

    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else { fatalError("Expected fixture, Python, and scratch paths") }
        let fixture = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        let python = URL(fileURLWithPath: arguments[2])
        let scratch = URL(fileURLWithPath: arguments[3], isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let report = try LearnerHealthSnapshot.decode(fixture, sessionID: sessionID)
        let health = report.learner.health
        require(health.title == "Held for reconciliation", "A held task must stay held despite old success")
        require(health.policy.state == "enabled", "Enabled policy is separate from current activity")
        require(health.activity.state == "held", "Activity comes from the shared schema")
        require(health.progress.lastSuccessTimestampClaim != nil, "Historical success stays historical")
        require(health.failure.diagnosticErrorCount == 3, "Aggregate diagnostics must decode")
        require(health.outcomes.providerCompletion.state == "completed_in_run_receipt", "Provider completion is separate")
        require(health.outcomes.independentReadback.state == "not_performed", "A write receipt is not independent readback")

        var object = try JSONSerialization.jsonObject(with: fixture) as! [String: Any]
        var learner = object["learner"] as! [String: Any]
        var model = learner["health"] as! [String: Any]
        require(health.workerAdmission == nil, "Older reports without launch metadata remain readable")
        model["headline"] = "admission_deferred"
        model["recovery"] = ["action": "wait_for_eligible_event"]
        var launch: [String: Any] = ["state": "deferred", "reason": "load",
            "candidate_binding": "selected_pending_request", "age_seconds": 10, "freshness": "recent",
            "decision": ["schema_version": 1, "reason": "load", "load_average": 50.36, "load_limit": 32],
            "next_attempt": ["policy": "not_established_by_admission_receipt", "scheduled_at": NSNull()]]
        model["worker_admission"] = launch
        learner["health"] = model
        object["learner"] = learner
        let deferred = try LearnerHealthSnapshot.decode(JSONSerialization.data(withJSONObject: object), sessionID: sessionID).learner.health
        require(deferred.title == "Waiting to start", "Launch deferral must be visible")
        require(deferred.workerAdmission?.decision?.loadAverage == 50.36, "Recorded load must decode")
        require(deferred.workerAdmission?.decision?.loadLimit == 32, "The actual recorded limit must decode")
        require(deferred.workerAdmission?.scopeText == "This task's current queued request", "Exact request scope must be visible")
        require(deferred.workerAdmission?.ageSeconds == 10, "Recorded age must decode")
        require(deferred.recoveryText.contains("No timed retry"), "An eligible event is not a promised timer")
        model["headline"] = "queued"
        model["recovery"] = ["action": "none"]
        launch["candidate_binding"] = "other_session"
        launch["freshness"] = "stale"
        model["worker_admission"] = launch
        learner["health"] = model
        object["learner"] = learner
        let advisory = try LearnerHealthSnapshot.decode(JSONSerialization.data(withJSONObject: object), sessionID: sessionID).learner.health
        require(advisory.title == "Queued", "Advisory launch evidence cannot override the shared health decision")
        require(advisory.workerAdmission?.scopeText == "Another task", "Other task scope must remain explicit")
        require(advisory.workerAdmission?.freshness == "stale", "Stale evidence must remain distinguishable")
        launch["state"] = "historical_advisory"
        launch["next_attempt"] = ["eligible_after": 1_792_734_000, "eligibility": "not_before"]
        model["worker_admission"] = launch
        learner["health"] = model
        object["learner"] = learner
        let cooldown = try LearnerHealthSnapshot.decode(JSONSerialization.data(withJSONObject: object), sessionID: sessionID).learner.health
        require(cooldown.workerAdmission?.state == "historical_advisory", "Historical checks must remain explicit")
        require(cooldown.workerAdmission?.nextAttempt?.eligibleAfter == 1_792_734_000, "Actual cooldown time must decode")
        require(cooldown.workerAdmission?.nextAttempt?.eligibilityTimeText?.isEmpty == false, "Cooldown time must have a display value")
        launch["next_attempt"] = ["eligible_after": 9_007_199_254_740_992.0]
        model["worker_admission"] = launch
        learner["health"] = model
        object["learner"] = learner
        let distant = try LearnerHealthSnapshot.decode(JSONSerialization.data(withJSONObject: object), sessionID: sessionID).learner.health
        require(distant.workerAdmission?.nextAttempt?.eligibilityTimeText == "Recorded time is outside the display range", "Out-of-range dates cannot be formatted as real eligibility times")
        model.removeValue(forKey: "worker_admission")
        model["headline"] = "processing_unverified"
        learner["health"] = model
        object["learner"] = learner
        let processing = try LearnerHealthSnapshot.decode(JSONSerialization.data(withJSONObject: object), sessionID: sessionID)
        require(processing.learner.health.title.contains("unverified"), "A processing marker cannot prove running")
        model["headline"] = "publication_recovery_pending"
        model["recovery"] = ["action": "recover_publication", "automatic_replay_authorized": false]
        var outcomes = model["outcomes"] as! [String: Any]
        outcomes["native_acknowledgement"] = ["state": "recorded_in_anchored_settlement",
            "attempted_write_calls": 3, "applied_write_calls": 2, "unchanged_write_calls": 1]
        outcomes["write_attempts"] = ["evidence": "run_receipt_only", "attempted_write_calls": 3,
                                      "applied_write_calls": 2, "unchanged_write_calls": 1]
        outcomes["recorded_settlement"] = ["state": "session_hash_match", "receipt": [
            "status": "succeeded", "reason": "verified_completion", "run_id": "fixture-run",
            "source": ["start_offset": 10, "end_offset": 20],
            "attempted_write_calls": 3, "applied_write_calls": 2, "unchanged_write_calls": 1]]
        model["outcomes"] = outcomes
        var progress = model["progress"] as! [String: Any]
        progress["last_completed_interval"] = ["evidence": "anchored_settlement_receipt", "run_id": "fixture-run",
                                              "start_offset": 10, "end_offset": 20]
        model["progress"] = progress
        learner["health"] = model
        object["learner"] = learner
        let publication = try LearnerHealthSnapshot.decode(JSONSerialization.data(withJSONObject: object), sessionID: sessionID).learner.health
        require(publication.title == "Progress update needs recovery", "An unfinished publication must be visible")
        require(publication.recoveryText.contains("Recover the unfinished progress update"), "Recovery action must be explicit")
        require(publication.progress.lastCompletedInterval.startOffset == 10, "Recorded interval start must decode")
        require(publication.progress.lastCompletedInterval.endOffset == 20, "Recorded interval end must decode")
        require(publication.outcomes.recordedSettlement?.receipt?.appliedWriteCalls == 2, "Applied writes remain distinct")
        require(publication.outcomes.recordedSettlement?.receipt?.unchangedWriteCalls == 1, "Unchanged writes remain distinct")
        require(publication.outcomes.writeAttempts?.attemptedWriteCalls == 3, "Run attempts remain separate from settlement")
        require(publication.outcomes.nativeAcknowledgement.attemptedWriteCalls == 3, "Recorded native counts must decode")
        require(publication.outcomes.independentReadback.state == "not_performed", "Settlement is not independent readback")
        progress["last_completed_interval"] = ["evidence": "receipt_only", "start_offset": "not_recorded", "end_offset": 20]
        model["progress"] = progress
        learner["health"] = model
        object["learner"] = learner
        let legacy = try LearnerHealthSnapshot.decode(JSONSerialization.data(withJSONObject: object), sessionID: sessionID)
        require(legacy.learner.health.progress.lastCompletedInterval.startOffset == nil, "Legacy unknown start remains unknown")
        progress["last_completed_interval"] = ["evidence": "anchored_settlement_receipt", "start_offset": "private invalid offset", "end_offset": 20]
        model["progress"] = progress
        learner["health"] = model
        object["learner"] = learner
        expect(.invalidReport) { _ = try LearnerHealthSnapshot.decode(JSONSerialization.data(withJSONObject: object), sessionID: sessionID) }
        progress["last_completed_interval"] = ["evidence": "not_available_in_window"]
        model["progress"] = progress
        model["headline"] = "batch_limit"
        outcomes["provider_completion"] = ["state": "completed_in_run_receipt", "run_status": "failed"]
        outcomes["legacy_reconciliation"] = ["state": "recorded_completed",
            "historical_run_status": "failed", "historical_execution_sealed": false,
            "source_binding_grade": "current_bounded_reconstruction", "native_mutations_performed": 0]
        outcomes["independent_readback"] = ["state": "not_performed"]
        model["outcomes"] = outcomes
        progress["last_reconciled_interval"] = ["evidence": "recorded_legacy_reconciliation",
            "legacy_run_id": "legacy-failed-run", "start_offset": 100, "end_offset": 200]
        model["progress"] = progress
        learner["health"] = model
        object["learner"] = learner
        let reconciled = try LearnerHealthSnapshot.decode(JSONSerialization.data(withJSONObject: object), sessionID: sessionID).learner.health
        require(reconciled.title == "Paused at batch limit", "Reconciliation cannot erase a current pause")
        require(reconciled.progress.lastCompletedInterval.endOffset == nil, "A legacy review cannot create successful coverage")
        require(reconciled.progress.lastReconciledInterval?.startOffset == 100, "Reconciled start must remain separate")
        require(reconciled.progress.lastReconciledInterval?.endOffset == 200, "Reconciled end must remain separate")
        require(reconciled.progress.lastReconciledInterval?.legacyRunId == "legacy-failed-run", "Historical run link must survive")
        require(reconciled.outcomes.providerCompletion.runStatus == "failed", "Original provider failure remains visible")
        require(reconciled.outcomes.legacyReconciliation?.historicalExecutionSealed == false, "Historical seal cannot be invented")
        require(reconciled.outcomes.legacyReconciliation?.nativeMutationsPerformed == 0, "Review records no new mutation")
        require(reconciled.outcomes.legacyReconciliation?.title == "Recorded review; no new memory write", "Review presentation must avoid a success claim")
        require(reconciled.outcomes.legacyReconciliation?.qualification.contains("original provider run remains failed") == true, "Qualification must retain the original failure")
        require(reconciled.outcomes.independentReadback.state == "not_performed", "Review is not independent readback")
        outcomes["legacy_reconciliation"] = ["state": "recovery_pending"]
        model["outcomes"] = outcomes
        model["headline"] = "publication_recovery_pending"
        learner["health"] = model
        object["learner"] = learner
        let unfinishedReview = try LearnerHealthSnapshot.decode(JSONSerialization.data(withJSONObject: object), sessionID: sessionID).learner.health
        require(unfinishedReview.title == "Progress update needs recovery", "Missing review receipt stays recoverable")
        require(unfinishedReview.outcomes.legacyReconciliation?.title == "Review receipt needs recovery", "The missing legacy receipt stays distinct")
        outcomes["legacy_reconciliation"] = ["state": "absent"]
        model["outcomes"] = outcomes
        learner["health"] = model
        object["learner"] = learner
        let noReview = try LearnerHealthSnapshot.decode(JSONSerialization.data(withJSONObject: object), sessionID: sessionID)
        require(noReview.learner.health.outcomes.legacyReconciliation?.title == "None recorded", "Absent review remains absent")
        outcomes["residual_reconciliation"] = ["state": "recorded_completed", "historical_run_status": "failed",
            "provider_invoked": false, "applied_write_count": 5, "unchanged_write_count": 0]
        model["outcomes"] = outcomes
        learner["health"] = model
        object["learner"] = learner
        let residual = try LearnerHealthSnapshot.decode(JSONSerialization.data(withJSONObject: object), sessionID: sessionID).learner.health
        require(residual.outcomes.residualReconciliation?.appliedWriteCount == 5, "Residual writes remain separate from old provider counts")
        require(residual.outcomes.residualReconciliation?.providerInvoked == false, "Residual recovery does not invent a provider run")
        require(residual.outcomes.residualReconciliation?.title == "Recorded review with residual writes", "Residual review has a distinct label")
        require(residual.outcomes.providerCompletion.runStatus == "failed", "Residual recovery retains the historical provider failure")
        require(residual.outcomes.independentReadback.state == "not_performed", "Residual receipt is not independent readback")
        require(residual.progress.lastCompletedInterval.endOffset == nil, "Residual review cannot create modern successful coverage")
        outcomes["residual_reconciliation"] = ["state": "recovery_pending"]
        model["outcomes"] = outcomes
        learner["health"] = model
        object["learner"] = learner
        let residualPending = try LearnerHealthSnapshot.decode(JSONSerialization.data(withJSONObject: object), sessionID: sessionID).learner.health
        require(residualPending.outcomes.residualReconciliation?.title == "Residual review receipt needs recovery", "Missing residual receipt remains visible")
        model["schema_version"] = 2
        learner["health"] = model
        object["learner"] = learner
        expect(.invalidReport) { _ = try LearnerHealthSnapshot.decode(JSONSerialization.data(withJSONObject: object), sessionID: sessionID) }
        expect(.invalidReport) { _ = try LearnerHealthSnapshot.decode(fixture, sessionID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee") }
        expect(.invalidReport) { _ = try LearnerHealthSnapshot.decode(Data("{\"status\":\"state_root_unavailable\"}".utf8), sessionID: sessionID) }

        let script = scratch.appendingPathComponent("reader-fixture.py")
        let fixtureURL = scratch.appendingPathComponent("report.json")
        try fixture.write(to: fixtureURL)
        let fixtureLiteral = String(data: try JSONSerialization.data(withJSONObject: fixtureURL.path, options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)!
        let homeLiteral = String(data: try JSONSerialization.data(withJSONObject: scratch.path, options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)!
        try """
        import os, sys
        assert sys.flags.isolated == 1 and sys.flags.dont_write_bytecode == 1
        assert sys.argv[1:] == ['--session-id', '\(sessionID)']
        assert os.environ['CODEX_HOME'] == \(homeLiteral)
        assert 'PYTHONPATH' not in os.environ
        assert sys.stdin.read() == ''
        print(open(\(fixtureLiteral)).read())
        """.write(to: script, atomically: true, encoding: .utf8)
        let fromProcess = try LearnerHealthReader.run(script: script, python: python,
                                                     sessionID: sessionID, codexHome: scratch.path)
        require(fromProcess.sessionId == sessionID, "Process result remains bound to requested task")
        expect(.invalidSession) { _ = try LearnerHealthReader.run(script: script, python: python, sessionID: "../other", codexHome: scratch.path) }
        expect(.invalidHome) { _ = try LearnerHealthReader.run(script: script, python: python, sessionID: sessionID, codexHome: "/tmp/../secret") }

        try "print('x' * 60000)".write(to: script, atomically: true, encoding: .utf8)
        expect(.outputLimit) { _ = try LearnerHealthReader.run(script: script, python: python, sessionID: sessionID, codexHome: scratch.path) }
        try "import sys; print('private diagnostic', file=sys.stderr); sys.exit(7)".write(to: script, atomically: true, encoding: .utf8)
        expect(.unavailable) { _ = try LearnerHealthReader.run(script: script, python: python, sessionID: sessionID, codexHome: scratch.path) }
        try "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)".write(to: script, atomically: true, encoding: .utf8)
        let started = ProcessInfo.processInfo.systemUptime
        expect(.timeout) { _ = try LearnerHealthReader.run(script: script, python: python, sessionID: sessionID, codexHome: scratch.path, timeout: 0.15) }
        require(ProcessInfo.processInfo.systemUptime - started < 2, "Reader must return within its timeout plus cleanup grace")
        print("Learner health UI checks passed: schema, task binding, evidence distinctions, isolated process, output bound, timeout, and sanitized errors.")
    }

    static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func expect(_ expected: LearnerHealthReadError, _ body: () throws -> Void) {
        do {
            try body()
            fatalError("Expected \(expected)")
        } catch let error as LearnerHealthReadError {
            require(error == expected, "Unexpected error: \(error)")
        } catch {
            fatalError("Unsanitized error: \(error)")
        }
    }
}
