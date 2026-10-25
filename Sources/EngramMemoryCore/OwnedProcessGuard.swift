import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// Installed only by the dedicated guard command, never by an embedding app or
// a test calling run(). The handler does only a nonblocking POSIX write.
nonisolated(unsafe) private var guardSignalWriteFD: Int32 = -1
private func guardSignalHandler(_ value: Int32) {
    let savedErrno = errno
    var value = value
    _ = write(guardSignalWriteFD, &value, MemoryLayout<Int32>.size)
    errno = savedErrno
}

/// Owns one provider until waitpid reaps it. Unlike a shell watchdog, no other
/// waiter can reap/reuse the PID between our liveness check and signal. The
/// caller keeps its admission descriptor open throughout this synchronous call.
/// SIGKILL of the guard itself cannot be handled; normal cancellation and the
/// wall deadline go through TERM, KILL, and an actual reap before return.
public enum OwnedProcessGuard {
    public enum Failure: Error { case invalidArguments, systemCall(String, Int32) }

    public static func run(command: [String], wallSeconds: Double,
                           terminationGraceSeconds: Double = 3,
                           cancellationFD: Int32? = nil, leaseFD: Int32? = nil) throws -> Int32 {
        guard let executable = command.first, executable.hasPrefix("/"),
              command.allSatisfy({ !$0.utf8.contains(0) }),
              wallSeconds.isFinite, wallSeconds > 0,
              terminationGraceSeconds.isFinite, terminationGraceSeconds >= 0 else {
            throw Failure.invalidArguments
        }
        if let leaseFD {
            var state = stat()
            guard leaseFD > STDERR_FILENO, fstat(leaseFD, &state) == 0,
                  state.st_mode & S_IFMT == S_IFREG else { throw Failure.invalidArguments }
        }
        if let cancellationFD {
            let flags = fcntl(cancellationFD, F_GETFL)
            guard flags >= 0, flags & O_NONBLOCK != 0 else { throw Failure.invalidArguments }
        }
        return try spawnAndWait(command: command, executable: executable,
            wallSeconds: wallSeconds, terminationGraceSeconds: terminationGraceSeconds,
            cancellationFD: cancellationFD, leaseFD: leaseFD)
    }

    private static func spawnAndWait(command: [String], executable: String,
                                      wallSeconds: Double, terminationGraceSeconds: Double,
                                      cancellationFD: Int32?, leaseFD: Int32?) throws -> Int32 {
        #if os(Linux)
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #else
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #endif
        func checked(_ result: Int32, _ name: String) throws {
            guard result == 0 else { throw Failure.systemCall(name, result) }
        }
        try checked(posix_spawn_file_actions_init(&actions), "file_actions_init")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawnattr_init(&attributes), "attributes_init")
        defer { posix_spawnattr_destroy(&attributes) }
        try checked(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0), "stdin")
        if let leaseFD { try checked(posix_spawn_file_actions_addclose(&actions, leaseFD), "close_child_lease") }
        if let cancellationFD { try checked(posix_spawn_file_actions_addclose(&actions, cancellationFD), "close_child_cancel") }
        var empty = sigset_t(), defaults = sigset_t()
        sigemptyset(&empty); sigemptyset(&defaults)
        for value in [SIGTERM, SIGINT, SIGHUP] { sigaddset(&defaults, value) }
        try checked(posix_spawnattr_setsigmask(&attributes, &empty), "signal_mask")
        try checked(posix_spawnattr_setsigdefault(&attributes, &defaults), "signal_defaults")
        try checked(posix_spawnattr_setpgroup(&attributes, 0), "process_group")
        try checked(posix_spawnattr_setflags(&attributes,
            Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETPGROUP)), "spawn_flags")

        let argv = command.map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for value in argv + environment { free(value) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), environment.dropLast().allSatisfy({ $0 != nil }) else {
            throw Failure.systemCall("argument_allocation", ENOMEM)
        }
        // A cancellation already delivered to our handler must not start new
        // provider work. A signal arriving during spawn is handled by the loop.
        let cancelledBeforeSpawn = cancellationRequested(cancellationFD)
        if cancelledBeforeSpawn != 0 { return 128 + cancelledBeforeSpawn }
        var child: pid_t = 0
        let launched = argv.withUnsafeBufferPointer { args in
            environment.withUnsafeBufferPointer { env in
                posix_spawn(&child, executable, &actions, &attributes,
                            UnsafeMutablePointer(mutating: args.baseAddress!),
                            UnsafeMutablePointer(mutating: env.baseAddress!))
            }
        }
        try checked(launched, "spawn")
        let deadline = ProcessInfo.processInfo.systemUptime + wallSeconds
        var terminateAt: Double?
        var killed = false
        while true {
            var status: Int32 = 0
            let waited = waitpid(child, &status, WNOHANG)
            if waited == child {
                let signal = status & 0x7f
                // A traced child may report a stop even without WUNTRACED.
                // Only exited/signaled statuses mean the child was reaped.
                if signal != 0x7f { return signal == 0 ? (status >> 8) & 0xff : 128 + signal }
            }
            if waited < 0 {
                if errno == EINTR { continue }
                // A dedicated guard is the sole waiter and resets SIGCHLD;
                // ECHILD would violate that ownership contract. Fail closed:
                // keep the lease, and never signal a potentially recycled PID.
                if errno == ECHILD {
                    FileHandle.standardError.write(Data("Engram process guard: lost child wait ownership; retaining admission without signaling an unverified PID.\n".utf8))
                    while true { Thread.sleep(forTimeInterval: 1) }
                }
                // Unexpected observation failure must not drop the lease.
                // Keep ownership and proceed to termination/reap below.
            }
            let now = ProcessInfo.processInfo.systemUptime
            let requested = cancellationRequested(cancellationFD)
            if terminateAt == nil, requested != 0 || now >= deadline || waited < 0 {
                // This child has not been reaped. Its PID/process-group ID
                // cannot be recycled before this sole owner calls waitpid.
                signalOwnedChild(child, signal: requested == 0 ? SIGTERM : requested)
                terminateAt = now
            } else if let terminateAt, !killed, now - terminateAt >= terminationGraceSeconds {
                signalOwnedChild(child, signal: SIGKILL)
                killed = true
            }
            // SIGKILL can wait on kernel I/O. Retain the lease until waitpid
            // observes termination; no elapsed-time escape admits overlap.
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private static func signalOwnedChild(_ child: pid_t, signal: Int32) {
        _ = kill(-child, signal)
        // The direct child may have moved to another process group. It is
        // still unreaped and owned by us, so signaling its exact PID is safe.
        _ = kill(child, signal)
    }

    private static func cancellationRequested(_ descriptor: Int32?) -> Int32 {
        guard let descriptor else { return 0 }
        var value: Int32 = 0
        while read(descriptor, &value, MemoryLayout<Int32>.size) == MemoryLayout<Int32>.size {
            if [SIGTERM, SIGINT, SIGHUP].contains(value) { return value }
        }
        return 0
    }

    /// Shared entry point for the hidden hooks command and portable fixture.
    /// Arguments are generated internally; no PATH lookup chooses the guard.
    public static func runCommand(arguments: [String]) throws -> Int32 {
        if arguments.first == "--exec-shell" {
            guard arguments.count == 2, !arguments[1].isEmpty,
                  !arguments[1].utf8.contains(0) else { throw Failure.invalidArguments }
            try execShell(arguments[1])
        }
        var wall: Double?, lease: Int32?, command: [String] = []
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            if key == "--" { command = Array(arguments.dropFirst(index + 1)); break }
            guard index + 1 < arguments.count else { throw Failure.invalidArguments }
            switch key {
            case "--wall-seconds":
                guard wall == nil, let value = Double(arguments[index + 1]) else { throw Failure.invalidArguments }
                wall = value
            case "--lease-fd":
                guard lease == nil, let value = Int32(arguments[index + 1]) else { throw Failure.invalidArguments }
                lease = value
            default: throw Failure.invalidArguments
            }
            index += 2
        }
        guard let wall, wall.isFinite, wall > 0,
              let executable = command.first, executable.hasPrefix("/"),
              command.allSatisfy({ !$0.utf8.contains(0) }) else { throw Failure.invalidArguments }
        if let lease {
            var state = stat()
            guard lease > STDERR_FILENO, fstat(lease, &state) == 0,
                  state.st_mode & S_IFMT == S_IFREG else { throw Failure.invalidArguments }
        }
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw Failure.systemCall("signal_pipe", errno) }
        defer { close(descriptors[0]); close(descriptors[1]) }
        for fd in descriptors {
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
                throw Failure.systemCall("signal_pipe_flags", errno)
            }
        }
        guardSignalWriteFD = descriptors[1]
        let previousTerm = signal(SIGTERM, guardSignalHandler)
        let previousInt = signal(SIGINT, guardSignalHandler)
        let previousHup = signal(SIGHUP, guardSignalHandler)
        // An inherited SIG_IGN would make the kernel reap our child before
        // waitpid can observe its termination. This command owns its process.
        let previousChild = signal(SIGCHLD, SIG_DFL)
        defer {
            signal(SIGTERM, previousTerm); signal(SIGINT, previousInt); signal(SIGHUP, previousHup)
            signal(SIGCHLD, previousChild)
            guardSignalWriteFD = -1
        }
        // Only this dedicated command changes its own mask. Install cancellation
        // handlers first so a pending signal is queued before provider admission.
        var empty = sigset_t(), previousMask = sigset_t()
        sigemptyset(&empty)
        let reset = pthread_sigmask(SIG_SETMASK, &empty, &previousMask)
        guard reset == 0 else { throw Failure.systemCall("signal_mask", reset) }
        defer { pthread_sigmask(SIG_SETMASK, &previousMask, nil) }
        return try run(command: command, wallSeconds: wall, cancellationFD: descriptors[0], leaseFD: lease)
    }


    /// Foundation may inherit a worker thread's blocked mask. Reset it in the
    /// dedicated child, never briefly unmask the embedding app's calling thread.
    /// exec preserves the owned PID and stdin, including the admission lease.
    private static func execShell(_ body: String) throws -> Never {
        let command: [String] = ["/bin/sh", "-c", body]
        let argv = command.map { strdup($0) } + [nil]
        defer { for value in argv { free(value) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }) else {
            throw Failure.systemCall("argument_allocation", ENOMEM)
        }
        let previousTerm = signal(SIGTERM, SIG_DFL)
        let previousInt = signal(SIGINT, SIG_DFL)
        let previousHup = signal(SIGHUP, SIG_DFL)
        let previousChild = signal(SIGCHLD, SIG_DFL)
        defer {
            signal(SIGTERM, previousTerm); signal(SIGINT, previousInt)
            signal(SIGHUP, previousHup); signal(SIGCHLD, previousChild)
        }
        var empty = sigset_t(), previousMask = sigset_t()
        sigemptyset(&empty)
        let reset = pthread_sigmask(SIG_SETMASK, &empty, &previousMask)
        guard reset == 0 else { throw Failure.systemCall("signal_mask", reset) }
        defer { pthread_sigmask(SIG_SETMASK, &previousMask, nil) }
        let execError = argv.withUnsafeBufferPointer { args in
            _ = execv("/bin/sh", UnsafeMutablePointer(mutating: args.baseAddress!))
            return errno
        }
        throw Failure.systemCall("exec_shell", execError)
    }
}
