import SwiftUI
import Lattice
import EngramKit

// MARK: - Edge Relation Colors

enum EdgeColors {
    static let relationColors: [String: Color] = [
        "part_of": .cyan,
        "contradicts": .red,
        "supersedes": .orange,
        "derived_from": .yellow,
        "relates_to": .blue,
        "summarized_by": .purple,
    ]
}

// MARK: - Stats Overlay
struct StatsOverlay: View {
    let galaxyRegistry: GalaxyRegistry
    let hiddenProjects: Set<String>
    let hiddenRelations: Set<String>
    private var projects: [String] { galaxyRegistry.panelSnapshot.projects }
    let toggleProject: (String) -> Void
    let toggleRelation: (String) -> Void
    private var colorMap: [String: Color] { galaxyRegistry.panelSnapshot.colorMap }
    var driveToProject: ((String) -> Void)? = nil

    @Environment(\.lattice) private var lattice
    @State private var isMaintenanceActive: Bool = false
    @State private var maintenanceObserver: AnyObject?

    @State private var dbFileSize = "—"

    nonisolated private static func readDatabaseSize() -> String {
        let dbPath = ProcessInfo.processInfo.environment["CLAUDE_MEMORY_DB"]
            ?? NSHomeDirectory() + "/.claude/memory.sqlite"
        let fm = FileManager.default
        var total: Int64 = 0
        for path in [dbPath, dbPath + "-wal", dbPath + "-shm"] {
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        guard total > 0 else { return "—" }
        if total < 1024 { return "\(total) B" }
        let kb = Double(total) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        return String(format: "%.1f MB", mb)
    }

    var body: some View {
        let visibleMemoryCount = galaxyRegistry.panelSnapshot.visibleCount
        let totalMemories = galaxyRegistry.panelSnapshot.totalCount
        let visibleEdgeCount = galaxyRegistry.panelSnapshot.edgeCount
        let allRelationCounts = galaxyRegistry.panelSnapshot.relationCounts
        VStack(alignment: .trailing, spacing: 6) {
            if visibleMemoryCount < totalMemories {
                Text("\(visibleMemoryCount)/\(totalMemories) memories")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
            } else {
                Text("\(totalMemories) memories")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
            }
            Text("\(visibleEdgeCount) edges")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
            Text("db: \(dbFileSize)")
                .font(.system(size: 11, design: .monospaced))

            if isMaintenanceActive {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.purple)
                        .frame(width: 6, height: 6)
                    Text("maintenance active")
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(.purple.opacity(0.9))
            }

            Divider().frame(width: 100).overlay(Color.white.opacity(0.2))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .trailing, spacing: 6) {
                    // Project filters
                    ForEach(projects, id: \.self) { project in
                        HStack(spacing: 4) {
                            if let driveToProject {
                                Button {
                                    driveToProject(project)
                                } label: {
                                    Image(systemName: "scope")
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(.plain)
                                .opacity(hiddenProjects.contains(project) ? 0.3 : 0.6)
                                .help("Fly to \(project)")
                            }
                            Button {
                                toggleProject(project)
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(GraphView.projectColor(for: project, in: colorMap))
                                        .frame(width: 8, height: 8)
                                        .opacity(hiddenProjects.contains(project) ? 0.3 : 1.0)
                                    Text(project)
                                        .font(.system(size: 11, design: .monospaced))
                                        .strikethrough(hiddenProjects.contains(project))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Edge type filters (use unfiltered counts so hidden types remain visible)
                    if !allRelationCounts.isEmpty {
                        Divider().frame(width: 100).overlay(Color.white.opacity(0.2))

                        ForEach(allRelationCounts, id: \.key) { relation, count in
                            Button {
                                toggleRelation(relation)
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(EdgeColors.relationColors[relation] ?? .white)
                                        .frame(width: 8, height: 8)
                                        .opacity(hiddenRelations.contains(relation) ? 0.3 : 1.0)
                                    Text("\(relation.replacingOccurrences(of: "_", with: " ")) (\(count))")
                                        .font(.system(size: 11, design: .monospaced))
                                        .strikethrough(hiddenRelations.contains(relation))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .foregroundStyle(.white.opacity(0.7))
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .onAppear { setupMaintenanceObserver() }
        .task {
            while !Task.isCancelled {
                let size = await Task.detached(priority: .utility) { Self.readDatabaseSize() }.value
                guard !Task.isCancelled else { return }
                dbFileSize = size
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    private func setupMaintenanceObserver() {
        // Check initial state
        if let state = lattice.objects(HookState.self)
            .where({ $0.key == .maintenanceActive }).first {
            isMaintenanceActive = state.value == "1"
        }

        // Observe changes
        let ref = lattice.sendableReference
        maintenanceObserver = lattice.objects(HookState.self).observe { change in
            guard let bgLattice = ref.resolve() else { return }
            switch change {
            case .insert(let pk), .update(let pk):
                guard let state = bgLattice.object(HookState.self, primaryKey: pk),
                      state.key == .maintenanceActive else { return }
                let active = state.value == "1"
                Task { @MainActor in isMaintenanceActive = active }
            case .delete:
                Task { @MainActor in isMaintenanceActive = false }
            }
        } as AnyObject
    }
    
}

// MARK: - Time Slider

struct TimeSliderBar: View {
    let earliestDate: Date
    let latestDate: Date
    @Binding var sliderDate: Date?
    @Binding var isPlaying: Bool

    @State private var sliderValue: Double = 1.0

    private var timeRange: TimeInterval {
        max(latestDate.timeIntervalSince(earliestDate), 1)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if isPlaying {
                    isPlaying = false
                } else {
                    if sliderValue >= 1.0 { sliderValue = 0.0 }
                    isPlaying = true
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)

            Text(dateLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 80, alignment: .leading)

            Slider(value: $sliderValue, in: 0...1)
                .tint(.cyan.opacity(0.6))
                .onChange(of: sliderValue) { _, newVal in
                    if newVal >= 1.0 {
                        sliderDate = nil
                        isPlaying = false
                    } else {
                        let interval = newVal * timeRange
                        sliderDate = earliestDate.addingTimeInterval(interval)
                    }
                }

            Button {
                sliderValue = 1.0
                sliderDate = nil
                isPlaying = false
            } label: {
                Text("All")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(red: 0.051, green: 0.067, blue: 0.09).opacity(0.9))
        .task(id: isPlaying) {
            guard isPlaying else { return }
            while !Task.isCancelled && isPlaying && sliderValue < 1.0 {
                try? await Task.sleep(for: .milliseconds(50))
                sliderValue = min(1.0, sliderValue + 0.005)
            }
            if sliderValue >= 1.0 {
                isPlaying = false
                sliderDate = nil
            }
        }
    }

    private var dateLabel: String {
        if let date = sliderDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            return formatter.string(from: date)
        }
        return "All time"
    }
}

// MARK: - Layout Mode Picker

struct LayoutModePicker: View {
    let mode: LayoutMode
    let projectionState: ProjectionState
    let onModeChange: (LayoutMode) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(LayoutMode.allCases, id: \.rawValue) { m in
                Button {
                    onModeChange(m)
                } label: {
                    HStack(spacing: 4) {
                        if m == .embedding, case .computing(let progress) = projectionState {
                            // Circular progress indicator
                            ZStack {
                                Circle()
                                    .stroke(.white.opacity(0.15), lineWidth: 1.5)
                                Circle()
                                    .trim(from: 0, to: progress)
                                    .stroke(.cyan.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                            }
                            .frame(width: 10, height: 10)
                        }
                        Text(m.rawValue)
                            .font(.system(size: 11, weight: mode == m ? .semibold : .regular, design: .monospaced))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(mode == m ? .white.opacity(0.12) : .clear)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(mode == m ? 0.9 : 0.4))
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(red: 0.08, green: 0.1, blue: 0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

// MARK: - Void Toggle Button

struct VoidToggleButton: View {
    @Binding var showVoids: Bool

    var body: some View {
        Button {
            showVoids.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                Text("Voids")
                    .font(.system(size: 11, design: .monospaced))
            }
            .foregroundStyle(.white.opacity(showVoids ? 0.8 : 0.35))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(showVoids
                          ? Color(red: 0.3, green: 0.25, blue: 0.5).opacity(0.4)
                          : Color(red: 0.08, green: 0.1, blue: 0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(.white.opacity(showVoids ? 0.2 : 0.1), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .help("Toggle knowledge void visualization")
    }
}
