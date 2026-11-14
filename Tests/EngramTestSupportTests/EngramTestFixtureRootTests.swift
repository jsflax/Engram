import Foundation
import Testing
import EngramTestSupport

struct EngramTestFixtureRootTests {
    @Test func anExplicitExistingRootReplacesTheFallback() throws {
        let root = URL(fileURLWithPath: "/engram-fixture-root", isDirectory: true)
        var inspected: [URL] = []
        var fallbackCalls = 0
        let result = try EngramTestFixtureRoot.directory(
            environment: ["ENGRAM_TEST_FIXTURE_ROOT": root.path],
            fallback: {
                fallbackCalls += 1
                return URL(fileURLWithPath: "/unexpected-fallback", isDirectory: true)
            }, isExistingDirectory: { candidate in
                inspected.append(candidate)
                return candidate == root
            })
        #expect(result == root)
        #expect(inspected == [root])
        #expect(fallbackCalls == 0)
    }

    @Test func anUnsetOverridePreservesTheLazyFallback() throws {
        let fallback = URL(fileURLWithPath: "/ordinary-test-fallback", isDirectory: true)
        var fallbackCalls = 0
        var inspections = 0
        let result = try EngramTestFixtureRoot.directory(environment: [:], fallback: {
            fallbackCalls += 1
            return fallback
        }, isExistingDirectory: { _ in
            inspections += 1
            return false
        })
        #expect(result == fallback)
        #expect(fallbackCalls == 1)
        #expect(inspections == 0)
    }

    @Test(arguments: ["", "relative/path", "~/fixture-root", "file:///fixture-root"])
    func aNonabsoluteOverrideIsRefusedBeforeInspectingTheFilesystem(path: String) {
        var fallbackCalls = 0
        var inspections = 0
        #expect(throws: EngramTestFixtureRoot.Failure.notAbsolute) {
            try EngramTestFixtureRoot.directory(
                environment: ["ENGRAM_TEST_FIXTURE_ROOT": path],
                fallback: {
                    fallbackCalls += 1
                    return URL(fileURLWithPath: "/unexpected-fallback", isDirectory: true)
                }, isExistingDirectory: { _ in
                    inspections += 1
                    return true
                })
        }
        #expect(fallbackCalls == 0)
        #expect(inspections == 0)
    }

    @Test func aMissingOrNondirectoryOverrideIsRefusedWithoutFallback() {
        let root = URL(fileURLWithPath: "/missing-or-file-fixture-root", isDirectory: true)
        var inspected: [URL] = []
        var fallbackCalls = 0
        #expect(throws: EngramTestFixtureRoot.Failure.missingOrNotDirectory) {
            try EngramTestFixtureRoot.directory(
                environment: ["ENGRAM_TEST_FIXTURE_ROOT": root.path],
                fallback: {
                    fallbackCalls += 1
                    return URL(fileURLWithPath: "/unexpected-fallback", isDirectory: true)
                }, isExistingDirectory: { candidate in
                    inspected.append(candidate)
                    return false
                })
        }
        #expect(inspected == [root])
        #expect(fallbackCalls == 0)
    }
}
