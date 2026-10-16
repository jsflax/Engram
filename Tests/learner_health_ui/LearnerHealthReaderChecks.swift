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
        model["headline"] = "processing_unverified"
        learner["health"] = model
        object["learner"] = learner
        let processing = try LearnerHealthSnapshot.decode(JSONSerialization.data(withJSONObject: object), sessionID: sessionID)
        require(processing.learner.health.title.contains("unverified"), "A processing marker cannot prove running")
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
