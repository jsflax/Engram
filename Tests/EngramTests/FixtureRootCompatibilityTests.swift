import Foundation
import Testing
import EngramTestSupport

@Suite("Fixture root compatibility")
struct FixtureRootCompatibilityTests {
    @Test func legacyRootStillCreatesItsDirectory() throws {
        let root = try EngramTestFixtureRoot.directory()
            .appendingPathComponent("legacy-fixture-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let selected = try testFixtureDirectory(environment: ["ENGRAM_TEST_ROOT": root.path])

        #expect(selected == root)
        var isDirectory = ObjCBool(false)
        #expect(FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func explicitExistingRootTakesPriorityWithoutCreatingTheLegacyRoot() throws {
        let base = try EngramTestFixtureRoot.directory()
        let root = base.appendingPathComponent("explicit-fixture-root-\(UUID().uuidString)", isDirectory: true)
        let legacy = base.appendingPathComponent("unused-legacy-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: legacy)
        }

        let selected = try testFixtureDirectory(environment: [
            "ENGRAM_TEST_FIXTURE_ROOT": root.path,
            "ENGRAM_TEST_ROOT": legacy.path,
        ])

        #expect(selected == root)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func invalidExplicitRootDoesNotFallBackToTheLegacyRoot() throws {
        let legacy = try EngramTestFixtureRoot.directory()
            .appendingPathComponent("refused-legacy-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: legacy) }

        #expect(throws: EngramTestFixtureRoot.Failure.notAbsolute) {
            try testFixtureDirectory(environment: [
                "ENGRAM_TEST_FIXTURE_ROOT": "relative-root",
                "ENGRAM_TEST_ROOT": legacy.path,
            ])
        }
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }
}
