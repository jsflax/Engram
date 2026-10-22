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
                let parsed = parseLine(line.text, source: source.id, formatter: formatter)
                entries.append(LogEntry(id: LogEntry.ID(source: source.id, offset: line.offset),
                                        timestamp: parsed.timestamp, source: source.id,
                                        message: parsed.message, raw: line.text))
            }
        }
        // Ties keep read order; `sorted` is not stable.
        return entries.enumerated().sorted { a, b in
            switch (a.element.timestamp, b.element.timestamp) {
            case let (x?, y?): x == y ? a.offset < b.offset : x < y
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Each line comes with the byte offset where it starts in the file.
    static func tailLines(path: String) -> [(offset: UInt64, text: String)] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            let start = end > UInt64(maximumTailBytes) ? end - UInt64(maximumTailBytes) : 0
            try handle.seek(toOffset: start)
            guard var data = try handle.read(upToCount: maximumTailBytes) else { return [] }
            var dataOffset = start
            // The first bytes may be a partial line or UTF-8 code point. Discard
            // them before decoding; complete lines retain their original text.
            if start > 0 {
                guard let newline = data.firstIndex(of: 10) else { return [] }
                data = data.subdata(in: (newline + 1)..<data.count)
                dataOffset += UInt64(newline + 1)
            }
            // Split bytes rather than decoded text so each line keeps its offset.
            // Slices of `data` share its indices.
            return data.split { $0 == 10 || $0 == 13 }
                .suffix(maximumLines)
                .map { line in
                    (offset: dataOffset + UInt64(line.startIndex),
                     text: String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .filter { !$0.text.isEmpty }
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
