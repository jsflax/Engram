import Foundation
import Darwin

/// Repairs a missing user-scoped registration without replacing a user's server.
/// Call from a background queue: the CLI has a bounded wait, but config I/O is synchronous.
public enum ClaudeMCPRegistration {
    public enum Outcome: Equatable, Sendable, CustomStringConvertible {
        case alreadyRegistered, registered, preservedExistingServer, invalidConfiguration
        case missingMemoryExecutable, claudeNotFound, launchFailed, verificationFailed
        case commandFailed(Int32)
        case timedOut(cleanupConfirmed: Bool)

        public var description: String {
            switch self {
            case .alreadyRegistered: "already registered"
            case .registered: "registered and verified in user configuration"
            case .preservedExistingServer: "existing memory server preserved; automatic replacement skipped"
            case .invalidConfiguration: "user configuration could not be read safely; retrying on next app launch"
            case .missingMemoryExecutable: "memory executable missing; retrying on next app launch"
            case .claudeNotFound: "Claude executable not found; retrying on next app launch"
            case .launchFailed: "Claude could not launch; retrying on next app launch"
            case .verificationFailed: "CLI exited successfully but registration was not verified; retrying on next app launch"
            case .commandFailed(let status): "Claude exited \(status); retrying on next app launch"
            case .timedOut(let confirmed):
                "Claude registration timed out (process exit confirmed: \(confirmed)); retrying on next app launch"
            }
        }
    }

    public static func register(
        memoryExecutable: URL,
        home: URL,
        environment: [String: String],
        timeout: TimeInterval = 10
    ) -> Outcome {
        register(memoryExecutable: memoryExecutable, home: home, environment: environment,
                 timeout: timeout, candidates: executableCandidates(home: home, environment: environment))
    }

    // Injectable candidates keep tests entirely on private fake executables.
    static func register(
        memoryExecutable: URL,
        home: URL,
        environment: [String: String],
        timeout: TimeInterval,
        candidates: [URL]
    ) -> Outcome {
        let config = configurationURL(home: home, environment: environment)
        switch registrationState(at: config, memoryExecutable: memoryExecutable) {
        case .matching: return .alreadyRegistered
        case .other: return .preservedExistingServer
        case .invalid: return .invalidConfiguration
        case .missing: break
        }
        guard isExecutable(memoryExecutable) else { return .missingMemoryExecutable }
        guard let claude = candidates.first(where: isExecutable) else { return .claudeNotFound }

        var env = environment
        env.removeValue(forKey: "CLAUDECODE")
        env["HOME"] = home.path
        env["PATH"] = executableCandidates(home: home, environment: environment)
            .map { $0.deletingLastPathComponent().path }.joined(separator: ":")

        let process = Process()
        process.executableURL = claude
        process.arguments = ["mcp", "add", "--scope", "user", "--transport", "stdio",
                             "memory", "--", memoryExecutable.path]
        process.environment = env
        process.currentDirectoryURL = home
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return .launchFailed }
        // Darwin Foundation launches Process in a separate group. Verify that
        // ownership before ever using a negative PID: never signal our app's group.
        let childPID = process.processIdentifier
        let ownedGroup = getpgid(childPID) == childPID ? childPID : nil

        if finished.wait(timeout: .now() + max(0, timeout)) == .timedOut {
            guard let ownedGroup else {
                // Fail conservatively if a future Foundation implementation does
                // not isolate the child. Direct-child exit cannot prove tree cleanup.
                if process.isRunning { process.terminate() }
                if finished.wait(timeout: .now() + 1) == .timedOut {
                    if process.isRunning { kill(childPID, SIGKILL) }
                    _ = finished.wait(timeout: .now() + 1)
                }
                return .timedOut(cleanupConfirmed: false)
            }
            kill(-ownedGroup, SIGTERM)
            if waitForExit(process, ownedGroup: ownedGroup, timeout: 1) {
                return .timedOut(cleanupConfirmed: true)
            }
            kill(-ownedGroup, SIGKILL)
            return .timedOut(cleanupConfirmed: waitForExit(process, ownedGroup: ownedGroup, timeout: 1))
        }
        guard process.terminationStatus == 0 else { return .commandFailed(process.terminationStatus) }
        guard registrationState(at: config, memoryExecutable: memoryExecutable) == .matching else {
            return .verificationFailed
        }
        return .registered
    }

    private static func waitForExit(_ process: Process, ownedGroup: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        repeat {
            // Waiting for the direct child alone misses children of CLI wrappers.
            let groupGone = kill(-ownedGroup, 0) == -1 && errno == ESRCH
            if !process.isRunning && groupGone { return true }
            if DispatchTime.now() >= deadline { return false }
            usleep(10_000)
        } while true
    }

    static func executableCandidates(home: URL, environment: [String: String]) -> [URL] {
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        var seen = Set<String>()
        return paths.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
            .map { URL(fileURLWithPath: $0).appendingPathComponent("claude") }
    }

    static func configurationURL(home: URL, environment: [String: String]) -> URL {
        guard let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty else {
            return home.appendingPathComponent(".claude.json")
        }
        let path = custom.hasPrefix("~/") ? home.appendingPathComponent(String(custom.dropFirst(2))).path : custom
        return URL(fileURLWithPath: path, relativeTo: home).standardizedFileURL.appendingPathComponent(".claude.json")
    }

    private enum RegistrationState { case missing, matching, other, invalid }

    private static func registrationState(at url: URL, memoryExecutable: URL) -> RegistrationState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .invalid }
        guard let serversValue = root["mcpServers"] else { return .missing }
        guard let servers = serversValue as? [String: Any] else { return .invalid }
        guard let value = servers["memory"] else { return .missing }
        guard let server = value as? [String: Any],
              server["command"] as? String == memoryExecutable.path,
              server["type"] == nil || server["type"] as? String == "stdio",
              server["args"] == nil || (server["args"] as? [String]) == []
        else { return .other }
        return .matching
    }

    private static func isExecutable(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: url.path)
    }
}
