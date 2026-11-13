import Foundation

/// An explicit base for disposable test files; callers retain their UUIDs and cleanup.
/// The runner owns and verifies the supplied directory. This helper does not create it.
public enum EngramTestFixtureRoot {
    public enum Failure: Error, Equatable, Sendable {
        case notAbsolute
        case missingOrNotDirectory
    }

    public static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallback: () -> URL = { FileManager.default.temporaryDirectory },
        isExistingDirectory: (URL) -> Bool = { url in
            var isDirectory = ObjCBool(false)
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    ) throws -> URL {
        fallback()
    }
}
