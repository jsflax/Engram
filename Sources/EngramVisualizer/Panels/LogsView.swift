import SwiftUI

/// A log file source displayed in the logs tab.
struct LogSource: Identifiable, Sendable {
    let id: String
    let label: String
    let path: String
    let icon: String
    let color: Color
}

/// Parsed log entry from a log file.
struct LogEntry: Identifiable, Equatable, Sendable {
    let id: Int
    let timestamp: Date?
    let source: String
    let message: String
    let raw: String
}

@MainActor @Observable
final class LogsStore {
    private(set) var entries: [LogEntry] = [] {
        didSet { filterEntries() }
    }
    var selectedSource: String? = nil {
        didSet { filterEntries() }
    }
    var searchText = "" {
        didSet { filterEntries() }
    }
    var autoScroll = true
    private(set) var filteredEntries: [LogEntry] = []
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored nonisolated(unsafe) private var worker: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var continuation: AsyncStream<Void>.Continuation?

    static let sources: [LogSource] = [
        LogSource(
            id: "memory",
            label: "MCP",
            path: NSHomeDirectory() + "/.claude/memory.log",
            icon: "server.rack",
            color: .green
        ),
        LogSource(
            id: "hooks",
            label: "Hooks",
            path: NSHomeDirectory() + "/.claude/hooks.log",
            icon: "arrow.triangle.branch",
            color: .cyan
        ),
        LogSource(
            id: "session-learner",
            label: "Learner",
            path: NSHomeDirectory() + "/.claude/session-learner.log",
            icon: "brain",
            color: .purple
        ),
        LogSource(
            id: "maintenance",
            label: "Maintenance",
            path: NSHomeDirectory() + "/.claude/memory-maintenance.log",
            icon: "wrench.and.screwdriver",
            color: .orange
        ),
    ]

    private func filterEntries() {
        var result = entries
        if let source = selectedSource {
            result = result.filter { $0.source == source }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { $0.raw.lowercased().contains(query) }
        }
        filteredEntries = result
    }

    func loadLogs() {
        if worker == nil { startWatching() }
        continuation?.yield(())
    }

    func startWatching() {
        guard worker == nil else { return }
        generation &+= 1
        let generation = generation
        let sources = Self.sources
        let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        worker = Task.detached(priority: .utility) { [weak self] in
            var watchers = LogTailReader.makeWatchers(sources: sources, continuation: continuation)
            defer { watchers.forEach { $0.cancel() } }
            continuation.yield(())
            for await _ in changes {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { break }
                guard !Task.isCancelled else { break }
                // Reattach after directory changes/rotation before reading, so
                // writes to replacement files cannot fall between subscriptions.
                let replacement = LogTailReader.makeWatchers(sources: sources, continuation: continuation)
                watchers.forEach { $0.cancel() }
                watchers = replacement
                let entries = LogTailReader.read(sources: sources)
                guard !Task.isCancelled else { break }
                await self?.publish(entries, generation: generation)
            }
        }
    }

    private func publish(_ entries: [LogEntry], generation: UInt64) {
        guard generation == self.generation, self.entries != entries else { return }
        self.entries = entries
    }

    func stopWatching() {
        generation &+= 1
        continuation?.finish()
        continuation = nil
        worker?.cancel()
        worker = nil
    }

    deinit {
        continuation?.finish()
        worker?.cancel()
    }
}

/// Content view for the Logs sidebar tab.
struct LogsContentView: View {
    @State private var store = LogsStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sourceFilter

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
                TextField("Filter logs…", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                if !store.searchText.isEmpty {
                    Button { store.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.08, green: 0.1, blue: 0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                    )
            )

            // Log entries
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        let filtered = store.filteredEntries
                        if filtered.isEmpty {
                            emptyState
                        } else {
                            ForEach(filtered) { entry in
                                logRow(entry)
                                    .id(entry.id)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: store.entries.last) { _, _ in
                    if store.autoScroll, let last = store.filteredEntries.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Bottom toolbar
            HStack(spacing: 8) {
                Button {
                    store.autoScroll.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: store.autoScroll ? "arrow.down.to.line" : "arrow.down.to.line.compact")
                            .font(.system(size: 9))
                        Text(store.autoScroll ? "Auto-scroll" : "Paused")
                            .font(.system(size: 9, design: .monospaced))
                    }
                    .foregroundStyle(store.autoScroll ? .cyan.opacity(0.8) : .white.opacity(0.4))
                }
                .buttonStyle(.plain)

                Spacer()

                Text("\(store.filteredEntries.count) lines")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))

                Button {
                    store.loadLogs()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Reload logs")
            }
        }
        .onAppear {
            store.loadLogs()
            store.startWatching()
        }
        .onDisappear {
            store.stopWatching()
        }
    }

    // MARK: - Source Filter

    private var sourceFilter: some View {
        HStack(spacing: 4) {
            filterChip(label: "All", id: nil)
            ForEach(LogsStore.sources) { source in
                filterChip(label: source.label, id: source.id, icon: source.icon, color: source.color)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func filterChip(label: String, id: String?, icon: String? = nil, color: Color = .white) -> some View {
        let selected = store.selectedSource == id
        return Button {
            store.selectedSource = id
        } label: {
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 8))
                }
                Text(label)
                    .font(.system(size: 9, weight: selected ? .semibold : .regular, design: .monospaced))
            }
            .foregroundStyle(selected ? color.opacity(0.9) : .white.opacity(0.4))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(selected ? color.opacity(0.15) : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Log Row

    private func logRow(_ entry: LogEntry) -> some View {
        let source = LogsStore.sources.first { $0.id == entry.source }
        let color = source?.color ?? .white
        return HStack(alignment: .top, spacing: 6) {
            if let ts = entry.timestamp {
                Text(Self.timeFormatter.string(from: ts))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.25))
                    .frame(width: 42, alignment: .trailing)
            }
            Circle()
                .fill(color)
                .frame(width: 4, height: 4)
                .padding(.top, 4)
            Text(entry.message)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.2))
            Text("No log entries")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
            Text("Logs appear when hooks or\nbackground tasks run.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.2))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Formatters

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
