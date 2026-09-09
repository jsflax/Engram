import Foundation

/// Explicitly isolates profiling and hosted tests from the user's account and services.
enum PerformanceLaunch {
    // Retained for the process lifetime; the OS releases the activity at exit.
    // Only explicit profiling runs opt out of App Nap. Idle sleep is handled
    // separately by the harness's child-scoped caffeinate assertion.
    @MainActor private static var benchmarkActivity: NSObjectProtocol?

    @MainActor static func beginBenchmarkActivity() {
        guard ProcessInfo.processInfo.environment["ENGRAM_FRAME_STATS"] != nil,
              benchmarkActivity == nil else { return }
        benchmarkActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Measure Engram graph loading performance"
        )
    }

    static let isIsolated = ProcessInfo.processInfo.environment["ENGRAM_PERF_ISOLATED"] == "1"
        || NSClassFromString("XCTestCase") != nil

    static let databasePath: String = {
        if let path = ProcessInfo.processInfo.environment["CLAUDE_MEMORY_DB"] { return path }
        guard isIsolated else { return NSHomeDirectory() + "/.claude/memory.sqlite" }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram-isolated-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("memory.sqlite").path
    }()

    /// Profiling fixtures are copied into temporary directories. Resolve links
    /// before checking so a temporary symlink to the live DB is never reset.
    static var usesTemporaryDatabase: Bool {
        guard isIsolated else { return false }
        let path = URL(fileURLWithPath: databasePath).resolvingSymlinksInPath().standardizedFileURL.path
        return [FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/private/tmp", isDirectory: true)]
            .contains { directory in
                let prefix = directory.resolvingSymlinksInPath().standardizedFileURL.path
                return path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
            }
    }
}
