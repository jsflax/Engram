import ArgumentParser
import EngramMemoryCore

/// Re-exec target for our detached provider wrapper. It belongs to the same
/// hooks binary; no separate helper is selected from the user's PATH.
struct InternalProcessGuard: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "internal-process-guard", shouldDisplay: false)

    @Argument(parsing: .unconditionalRemaining)
    var arguments: [String] = []

    func run() throws {
        throw ExitCode(try OwnedProcessGuard.runCommand(arguments: arguments))
    }
}
