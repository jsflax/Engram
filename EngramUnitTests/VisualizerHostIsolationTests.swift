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
        // Foundation may retain the OS temporary directory despite TMPDIR.
        // Validate the explicit owned fixture route that this lane supplies.
        let temporaryURL = URL(fileURLWithPath: expectedTemporary, isDirectory: true)
        let ownedRunRoot = URL(fileURLWithPath: root, isDirectory: true).deletingLastPathComponent()
        XCTAssertEqual(canonical(expectedTemporary), canonical(ownedRunRoot.appendingPathComponent("tmp").path))
        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let probe = temporaryURL.appendingPathComponent("visualizer-isolation-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: probe) }
        let probeData = Data("owned temporary fixture".utf8)
        try probeData.write(to: probe, options: .atomic)
        XCTAssertEqual(try Data(contentsOf: probe), probeData)
        try FileManager.default.removeItem(at: probe)
        XCTAssertFalse(FileManager.default.fileExists(atPath: probe.path))
        let audioReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let files = try? FileManager.default.contentsOfDirectory(
                at: temporaryURL, includingPropertiesForKeys: nil)
            return files?.contains { $0.lastPathComponent.hasPrefix("engram_tone_") && $0.pathExtension == "wav" } == true
        }, object: nil)
        // The host's SwiftUI renderer may finish startup after XCTest begins.
        wait(for: [audioReady], timeout: 5)
        let audioFiles = try FileManager.default.contentsOfDirectory(
            at: temporaryURL, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
            .filter { $0.lastPathComponent.hasPrefix("engram_tone_") && $0.pathExtension == "wav" }
        XCTAssertFalse(audioFiles.isEmpty, "The actual app host must generate its audio fixtures in the owned directory")
        for file in audioFiles {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            XCTAssertEqual(values.isRegularFile, true)
            XCTAssertGreaterThan(try XCTUnwrap(values.fileSize), 44, "Generated WAV must contain audio data")
        }
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
