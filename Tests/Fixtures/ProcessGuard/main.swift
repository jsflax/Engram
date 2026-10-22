import EngramMemoryCore
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Test-only executable: exactly the entry point used by memory-hooks, with no
// provider, network, Lattice or app dependency in portable qualification.
do {
    if CommandLine.arguments.dropFirst().first == "provider-join-guard-group" {
        guard CommandLine.arguments.count == 3,
              setpgid(0, getpgid(getppid())) == 0 else { exit(91) }
        signal(SIGTERM, SIG_IGN)
        close(3)
        try String(getpid()).write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
        while true { pause() }
    }
    guard CommandLine.arguments.dropFirst().first == "internal-process-guard" else { exit(2) }
    exit(try OwnedProcessGuard.runCommand(arguments: Array(CommandLine.arguments.dropFirst(2))))
} catch {
    exit(127)
}
