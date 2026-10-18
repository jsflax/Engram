@testable import Engram
import Foundation
import XCTest

@MainActor
final class VisualizerHostIsolationTests: XCTestCase {
    func testHostedAppUsesOwnedDatabaseAndHomeWithoutInstallingSupport() throws {
        let environment = ProcessInfo.processInfo.environment
        let root = try XCTUnwrap(environment["ENGRAM_VISUALIZER_TEST_ROOT"])
        let expectedHome = try XCTUnwrap(environment["CFFIXED_USER_HOME"])
        let expectedTemporary = try XCTUnwrap(environment["TMPDIR"])
        let canonical: (String) -> String = {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
        }
        XCTAssertEqual(environment["ENGRAM_PERF_ISOLATED"], "1")
        XCTAssertTrue(PerformanceLaunch.isIsolated)
        XCTAssertEqual(canonical(NSHomeDirectory()), canonical(expectedHome))
        XCTAssertEqual(canonical(FileManager.default.temporaryDirectory.path), canonical(expectedTemporary))
        XCTAssertEqual(canonical(PerformanceLaunch.databasePath), canonical(root + "/app-memory.sqlite"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: PerformanceLaunch.databasePath),
                      "The actual test host must have opened its isolated startup database")
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedHome + "/.claude/bin"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedHome + "/.codex"))
        let account = AccountService()
        XCTAssertFalse(account.isSignedIn)
        XCTAssertEqual(account.endpoint, "http://127.0.0.1:1")
    }
}
