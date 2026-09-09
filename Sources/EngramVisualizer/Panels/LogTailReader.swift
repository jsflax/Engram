import Foundation

/// Bounded file IO and parsing used only by the logs worker.
enum LogTailReader {
    static let maximumTailBytes = 1_048_576
    static let maximumLines = 500

    static func read(sources: [LogSource]) -> [LogEntry] {
        let formatter = ISO8601DateFormatter()
        var entries: [LogEntry] = []
        for source in sources {
            for line in tailLines(path: source.path) {
                let parsed = parseLine(line, source: source.id, formatter: formatter)
                entries.append(LogEntry(id: entries.count, timestamp: parsed.timestamp,
                                        source: source.id, message: parsed.message, raw: line))
            }
        }
        entries.sort {
            switch ($0.timestamp, $1.timestamp) {
            case let (a?, b?): a == b ? $0.id < $1.id : a < b
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): $0.id < $1.id
            }
        }
        return entries.enumerated().map { index, entry in
            LogEntry(id: index, timestamp: entry.timestamp, source: entry.source,
                     message: entry.message, raw: entry.raw)
        }
    }

    static func tailLines(path: String) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            let start = end > UInt64(maximumTailBytes) ? end - UInt64(maximumTailBytes) : 0
            try handle.seek(toOffset: start)
            guard var data = try handle.read(upToCount: maximumTailBytes) else { return [] }
            // The first bytes may be a partial line or UTF-8 code point. Discard
            // them before decoding; complete lines retain their original text.
            if start > 0 {
                guard let newline = data.firstIndex(of: 10) else { return [] }
                data = data.subdata(in: (newline + 1)..<data.count)
            }
            return String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .suffix(maximumLines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } catch {
            return []
        }
    }

    static func makeWatchers(sources: [LogSource], continuation: AsyncStream<Void>.Continuation)
        -> [DispatchSourceFileSystemObject] {
        // Directory notifications catch creation/replacement; file notifications
        // catch appends, which do not change the parent directory on macOS.
        let directories = Set(sources.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path })
        return (Array(directories) + sources.map(\.path)).compactMap { path in
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let watcher = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete],
                queue: .global(qos: .utility))
            watcher.setEventHandler { continuation.yield(()) }
            watcher.setCancelHandler { close(fd) }
            watcher.resume()
            return watcher
        }
    }

    private static func parseLine(_ line: String, source: String, formatter: ISO8601DateFormatter)
        -> (timestamp: Date?, message: String) {
        if source == "memory" {
            let pattern = /^\[claude-memory\]\s+(\d{4}-\d{2}-\d{2}T[\d:]+Z)\s+(.*)/
            if let match = line.wholeMatch(of: pattern) {
                return (formatter.date(from: String(match.1)), String(match.2))
            }
        }
        if source == "hooks" {
            let pattern = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\s+\[memory-hooks\]\s*(.*)/
            if let match = line.wholeMatch(of: pattern) {
                return (formatter.date(from: String(match.1)), String(match.2))
            }
        }
        let startPattern = /^=+\s*started at '([^']+)'\s*=+$/
        if let match = line.wholeMatch(of: startPattern) {
            return (formatter.date(from: String(match.1)), "--- Session started ---")
        }
        let genericPattern = /^(\d{4}-\d{2}-\d{2}T[\d:]+Z?)\s+(.*)/
        if let match = line.wholeMatch(of: genericPattern) {
            return (formatter.date(from: String(match.1)), String(match.2))
        }
        return (nil, line)
    }
}
