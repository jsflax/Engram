import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Ring Buffer

/// Fixed-size circular buffer for recent log entries.
/// Writes use a lock (normal code paths). The buffer is pre-allocated so
/// the signal handler can dump it to disk without allocating.
public final class LogRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<UInt8>
    private var pos: Int = 0
    private var wrapped: Bool = false
    private let lock = NSLock()

    public init(capacity: Int = 64 * 1024) {
        self.capacity = capacity
        self.storage = .allocate(capacity: capacity)
        self.storage.initialize(repeating: 0, count: capacity)
    }

    deinit { storage.deallocate() }

    /// Append a log line (normal code, takes lock).
    public func append(_ message: String) {
        let bytes = Array(message.utf8)
        lock.lock()
        for byte in bytes {
            storage[pos] = byte
            pos = (pos + 1) % capacity
            if pos == 0 { wrapped = true }
        }
        if bytes.last != 0x0A {
            storage[pos] = 0x0A
            pos = (pos + 1) % capacity
            if pos == 0 { wrapped = true }
        }
        lock.unlock()
    }

    /// Read all buffered content (normal code, takes lock).
    public func contents() -> String {
        lock.lock()
        defer { lock.unlock() }
        return readUnsafe()
    }

    /// Read without locking — only safe from signal handler (post-crash, single-threaded).
    func readUnsafe() -> String {
        if !wrapped {
            return String(bytes: UnsafeBufferPointer(start: storage, count: pos), encoding: .utf8) ?? ""
        }
        var data = Data(capacity: capacity)
        data.append(storage + pos, count: capacity - pos)
        data.append(storage, count: pos)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Write buffer contents to fd using POSIX write() (async-signal-safe).
    func writeToFd(_ fd: Int32) {
        if !wrapped {
            _ = write(fd, storage, pos)
        } else {
            _ = write(fd, storage + pos, capacity - pos)
            _ = write(fd, storage, pos)
        }
    }
}

// MARK: - Crash Reporter

/// Installs signal handlers that write a crash report on fatal signals.
/// The crash report includes:
/// 1. Signal info + PID + uptime
/// 2. Recent Engram log entries (from ring buffer)
/// 3. Tail of the LatticeCore C++ log file (from disk)
public final class CrashReporter: @unchecked Sendable {
    public static let shared = CrashReporter()

    public let ringBuffer = LogRingBuffer()
    public let pid = ProcessInfo.processInfo.processIdentifier
    public let startTime = Date()

    /// Pre-formatted header bytes (allocated once at install time).
    private var headerBytes: [UInt8] = []
    /// Pre-computed crash file path as C string (for open() in signal handler).
    private var crashPath: [CChar] = []
    /// Path to the LatticeCore log file for this process.
    private var latticeLogPath: [CChar] = []
    /// How many bytes to read from the tail of the lattice log.
    private let latticeLogTailSize: Int = 64 * 1024

    private init() {}

    /// Pre-compute paths and install signal handlers. Call once at startup.
    /// Does NOT create any files — crash file is only created in the signal handler.
    public func install() {
        let dir = NSHomeDirectory() + "/.claude/memory-logs"
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        crashPath = Array((dir + "/crash-\(pid).log").utf8CString)

        // Pre-format header
        let header = """
        === ENGRAM MCP CRASH REPORT ===
        PID: \(pid)
        Started: \(ISO8601DateFormatter().string(from: startTime))
        Signal:\u{20}
        """
        headerBytes = Array(header.utf8)

        // Pre-compute lattice log path — matches main.swift naming
        let logSuffix = ProcessInfo.processInfo.environment["CLAUDE_SESSION_ID"] ?? "\(pid)"
        latticeLogPath = Array((dir + "/lattice-mcp-\(logSuffix).log").utf8CString)

        for sig in [SIGSEGV, SIGABRT, SIGTRAP, SIGBUS, SIGILL] {
            installHandler(sig)
        }
    }

    private func installHandler(_ sig: Int32) {
        var action = sigaction()
        #if canImport(Darwin)
        action.__sigaction_u.__sa_handler = { signal in
            CrashReporter.shared.writeCrashReport(signal: signal)
            Darwin.signal(signal, SIG_DFL)
            raise(signal)
        }
        #else
        action.__sigaction_handler.sa_handler = { signal in
            CrashReporter.shared.writeCrashReport(signal: signal)
            Glibc.signal(signal, SIG_DFL)
            raise(signal)
        }
        #endif
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        sigaction(sig, &action, nil)
    }

    /// Record a log entry in the ring buffer.
    public func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        ringBuffer.append("[\(timestamp)] \(message)")
    }

    /// Recent ring buffer entries (for diagnostics tool).
    public var recentEntries: String { ringBuffer.contents() }

    /// Uptime in seconds.
    public var uptimeSeconds: Int { Int(Date().timeIntervalSince(startTime)) }

    // MARK: - Signal Handler (async-signal-safe)

    fileprivate func writeCrashReport(signal: Int32) {
        // Open crash file on demand — only real crashes produce files
        let crashFd = crashPath.withUnsafeBufferPointer { ptr in
            open(ptr.baseAddress!, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        }
        guard crashFd >= 0 else { return }

        // 1. Header + signal name
        headerBytes.withUnsafeBufferPointer { ptr in
            _ = write(crashFd, ptr.baseAddress!, ptr.count)
        }
        writeSignalName(signal, to: crashFd)

        // 2. Engram log ring buffer
        let sep1: StaticString = "\n\n--- Recent Engram log entries ---\n"
        sep1.withUTF8Buffer { buf in _ = write(crashFd, buf.baseAddress!, buf.count) }
        ringBuffer.writeToFd(crashFd)

        // 3. Tail of LatticeCore log file
        let sep2: StaticString = "\n--- LatticeCore log (last 64KB) ---\n"
        sep2.withUTF8Buffer { buf in _ = write(crashFd, buf.baseAddress!, buf.count) }
        appendLatticeLogTail(crashFd)

        // 4. Footer
        let footer: StaticString = "\n--- End crash report ---\n"
        footer.withUTF8Buffer { buf in _ = write(crashFd, buf.baseAddress!, buf.count) }

        _ = close(crashFd)
    }

    /// Read the last N bytes of the LatticeCore log and write them to crashFd.
    /// Uses only async-signal-safe POSIX calls.
    private func appendLatticeLogTail(_ crashFd: Int32) {
        let logFd = latticeLogPath.withUnsafeBufferPointer { ptr in
            open(ptr.baseAddress!, O_RDONLY)
        }
        guard logFd >= 0 else {
            let msg: StaticString = "(no lattice log file)\n"
            msg.withUTF8Buffer { buf in _ = write(crashFd, buf.baseAddress!, buf.count) }
            return
        }

        // Seek to last latticeLogTailSize bytes
        let fileSize = lseek(logFd, 0, SEEK_END)
        let offset = max(0, fileSize - off_t(latticeLogTailSize))
        lseek(logFd, offset, SEEK_SET)

        // Read + write in chunks (stack-allocated)
        var buf = [UInt8](repeating: 0, count: 8192)
        buf.withUnsafeMutableBufferPointer { ptr in
            while true {
                let n = read(logFd, ptr.baseAddress!, ptr.count)
                if n <= 0 { break }
                _ = write(crashFd, ptr.baseAddress!, n)
            }
        }
        _ = close(logFd)
    }

    private func writeSignalName(_ sig: Int32, to fd: Int32) {
        let name: StaticString
        switch sig {
        case SIGSEGV:  name = "11 (SIGSEGV)"
        case SIGABRT:  name = "6 (SIGABRT)"
        case SIGTRAP:  name = "5 (SIGTRAP)"
        case SIGBUS:   name = "10 (SIGBUS)"
        case SIGILL:   name = "4 (SIGILL)"
        default:       name = "unknown"
        }
        name.withUTF8Buffer { buf in _ = write(fd, buf.baseAddress!, buf.count) }
    }

}
