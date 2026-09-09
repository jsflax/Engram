import EngramModels
import Lattice
import SwiftUI
import UserNotifications

// MARK: - Sidebar (hover-to-peek, click-to-pin)

@LatticeEnum enum SidebarTab: String, CaseIterable, Equatable {
    case visualizer = "Graph"
    case logs = "Logs"
    case settings = "Settings"
    case account = "Account"
}

/// Read live configuration once in the parent's observation scope. Lazy rows
/// receive values, not a long-lived materialized model or per-row SQL getters.
struct SidebarRenderConfiguration {
    struct Graph {
        let hiddenProjects: Set<String>
        let hiddenRelations: Set<String>
        let layoutMode: LayoutMode
    }

    let selectedTab: SidebarTab
    let graph: Graph?

    @MainActor init(config: VisualizerConfig) {
        selectedTab = config.selectedTab
        if selectedTab == .visualizer {
            graph = Graph(hiddenProjects: config.hiddenProjects,
                          hiddenRelations: config.hiddenRelations,
                          layoutMode: config.layoutMode)
        } else {
            graph = nil
        }
    }
}

struct SidebarView: View {
    typealias Tab = SidebarTab

    @Environment(VisualizerConfig.self) private var config
    @Environment(\.lattice) var lattice
    @Environment(SyncManager.self) var syncManager
    @Environment(GroupService.self) var groupService
    @State private var isCompacting = false
    /// Project whose group-exposure expansion is open (Account tab).
    @State var expandedExposureProject: String?

    // Visualizer tab
    var projects: [String] { galaxyRegistry.panelSnapshot.projects }
    var colorMap: [String: Color] { galaxyRegistry.panelSnapshot.colorMap }
    var galaxyRegistry: GalaxyRegistry
    let projectionState: ProjectionState
    let toggleProject: (String) -> Void
    let toggleRelation: (String) -> Void
    let switchLayoutMode: (LayoutMode) -> Void
    let driveToProject: ((String) -> Void)?

    // Account tab
    @Bindable var accountService: AccountService
    @LatticeQuery<SyncConfig>(sort: \SyncConfig.project) var syncConfigs
    // The advise toggle must read through @LatticeQuery: a raw
    // lattice.objects() call in body registers no SwiftUI dependency (and
    // an empty first result not even per-instance observation), so the
    // pill would render dead — each hopeful re-click silently flipping the
    // stored value.
    @LatticeQuery<HookState>(sort: \HookState.updatedAt) var hookStates
    @State var email = ""
    @State var password = ""
    @State var isRegistering = false
    // Cached per-project node counts for the Projects list. Computed from
    // the in-memory graph in one pass — the rows previously ran a
    // synchronous SQL COUNT against the (1GB+) database per project per
    // SwiftUI body evaluation, which made opening the drawer a lag spike.
    var projectCounts: [String: Int] { galaxyRegistry.panelSnapshot.projectCounts }

    func refreshProjectCounts() {
        galaxyRegistry.panelSnapshot.refresh(from: galaxyRegistry)
    }

    var body: some View {
        let renderConfig = SidebarRenderConfiguration(config: config)
        return VStack(spacing: 0) {
            Spacer().frame(height: 28) // clear traffic light buttons
            tabBar(selectedTab: renderConfig.selectedTab)
            Divider().overlay(Color.white.opacity(0.08))

            switch renderConfig.selectedTab {
            case .logs:
                LogsContentView()
                    .padding(16)
            case .visualizer:
                ScrollView(.vertical, showsIndicators: false) {
                    if let graphConfig = renderConfig.graph {
                        visualizerContent(graphConfig).padding(16)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("sidebar.graph-scroll")
            default:
                ScrollView(.vertical, showsIndicators: false) {
                    Group {
                        switch renderConfig.selectedTab {
                        case .settings: settingsContent
                        case .account: accountContent
                        case .visualizer, .logs: EmptyView()
                        }
                    }
                    .padding(16)
                }
            }
        }
        .panelResponseProbe("sidebar.open")
        .panelResponseProbe("sidebar.\(renderConfig.selectedTab.rawValue)")
        .frame(width: 310)
        .frame(maxHeight: .infinity)
        .background(Color(red: 0.055, green: 0.07, blue: 0.095).opacity(0.98))
        .background(.ultraThinMaterial)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 0,
                bottomTrailingRadius: 10, topTrailingRadius: 10
            )
        )
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 0,
                bottomTrailingRadius: 10, topTrailingRadius: 10
            )
            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 20, x: 5)
        .onAppear { refreshProjectCounts() }
        .task {
            while !Task.isCancelled {
                let size = await Task.detached(priority: .utility) { Self.readDBFileSize() }.value
                guard !Task.isCancelled else { break }
                dbFileSize = size
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
            }
        }
    }

    // MARK: - Tab Bar

    private func tabBar(selectedTab: Tab) -> some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    guard config.selectedTab != tab else { return }
                    // Timing begins after the live guard, not at action entry.
                    PanelResponseRecorder.begin("sidebar.\(tab.rawValue)")
                    config.selectedTab = tab
                    PanelResponseRecorder.mutationReturned("sidebar.\(tab.rawValue)")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tabIcon(tab))
                            .font(.system(size: 10))
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular, design: .monospaced))
                    }
                    .foregroundStyle(.white.opacity(selectedTab == tab ? 0.9 : 0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(selectedTab == tab ? .white.opacity(0.1) : .clear)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.tab.\(tab.rawValue)")
            }
        }
        .padding(6)
    }

    private func tabIcon(_ tab: Tab) -> String {
        switch tab {
        case .visualizer: "cube.transparent"
        case .logs: "doc.text"
        case .settings: "gearshape"
        case .account: "person.circle"
        }
    }

    // MARK: - Section Helper

    func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title)
            content()
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.3))
            .tracking(1.2)
    }

    // MARK: - Visualizer Tab

    @State private var dbFileSize = "—"

    @ViewBuilder
    private func visualizerContent(_ renderConfig: SidebarRenderConfiguration.Graph) -> some View {
        let projects = self.projects
        let colors = colorMap
        let relationCounts = galaxyRegistry.panelSnapshot.relationCounts
        let onToggleProject = toggleProject
        let onToggleRelation = toggleRelation
        let onDriveToProject = driveToProject
        // Rows must be direct lazy children. A lazy stack around an eager
        // Projects/Relations section still lays out every offscreen row.
        LazyVStack(alignment: .leading, spacing: 0) {
            section("Stats") {
                let visibleCount = galaxyRegistry.panelSnapshot.visibleCount
                let totalCount = galaxyRegistry.panelSnapshot.totalCount
                VStack(alignment: .leading, spacing: 6) {
                    if visibleCount < totalCount {
                        statRow("Memories", value: "\(visibleCount)/\(totalCount)")
                            .accessibilityIdentifier("sidebar.memory-count")
                            .accessibilityValue("\(totalCount)")
                    } else {
                        statRow("Memories", value: "\(totalCount)")
                            .accessibilityIdentifier("sidebar.memory-count")
                            .accessibilityValue("\(totalCount)")
                    }
                    statRow("Edges", value: "\(galaxyRegistry.panelSnapshot.edgeCount)")
                    statRow("Database", value: dbFileSize)
                }
            }
            .padding(.bottom, 24)

            section("Layout") {
                VStack(alignment: .leading, spacing: 10) {
                    layoutModePicker(selectedMode: renderConfig.layoutMode)
                }
            }
            .padding(.bottom, 24)

            sectionHeader("Projects")
                .padding(.bottom, 10)
            ForEach(projects, id: \.self) { project in
                SidebarProjectRow(project: project,
                                  hidden: renderConfig.hiddenProjects.contains(project),
                                  color: GraphView.projectColor(for: project, in: colors),
                                  toggleProject: onToggleProject, driveToProject: onDriveToProject)
                    .padding(.top, project == projects.first ? 0 : 2)
            }

            if !relationCounts.isEmpty {
                sectionHeader("Relations")
                    .padding(.top, 24)
                    .padding(.bottom, 10)
                ForEach(relationCounts, id: \.key) { relation, count in
                    SidebarRelationRow(relation: relation, count: count,
                                       hidden: renderConfig.hiddenRelations.contains(relation),
                                       color: EdgeColors.relationColors[relation] ?? .white,
                                       toggleRelation: onToggleRelation)
                        .padding(.top, relation == relationCounts.first?.key ? 0 : 2)
                }
            }
        }
    }

    // MARK: - Layout Controls

    private func layoutModePicker(selectedMode: LayoutMode) -> some View {
        HStack(spacing: 0) {
            ForEach(LayoutMode.allCases, id: \.rawValue) { mode in
                Button { switchLayoutMode(mode) } label: {
                    HStack(spacing: 4) {
                        if mode == .embedding, case .computing(let progress) = projectionState {
                            ZStack {
                                Circle().stroke(.white.opacity(0.15), lineWidth: 1.5)
                                Circle()
                                    .trim(from: 0, to: progress)
                                    .stroke(.cyan.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                            }
                            .frame(width: 10, height: 10)
                        }
                        Text(mode.rawValue)
                            .font(.system(size: 11, weight: selectedMode == mode ? .semibold : .regular, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(selectedMode == mode ? .white.opacity(0.12) : .clear)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(selectedMode == mode ? 0.9 : 0.4))
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

    // MARK: - Project Row

    private struct SidebarProjectRow: View {
        let project: String
        let hidden: Bool
        let color: Color
        let toggleProject: (String) -> Void
        let driveToProject: ((String) -> Void)?

        var body: some View {
            Button { toggleProject(project) } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                        .opacity(hidden ? 0.3 : 1.0)

                    Text(project)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(hidden ? 0.3 : 0.7))
                        .strikethrough(hidden)
                        .lineLimit(1)

                    Spacer()

                    if let driveToProject {
                        Button { driveToProject(project) } label: {
                            Image(systemName: "scope")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(hidden ? 0.15 : 0.4))
                        }
                        .buttonStyle(.plain)
                        .help("Fly to \(project)")
                    }

                    Image(systemName: hidden ? "eye.slash" : "eye")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(hidden ? 0.3 : 0.5))
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.white.opacity(hidden ? 0 : 0.03))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar.project.\(project)")
        }
    }

    // MARK: - Relation Row

    private struct SidebarRelationRow: View {
        let relation: String
        let count: Int
        let hidden: Bool
        let color: Color
        let toggleRelation: (String) -> Void

        var body: some View {
            Button { toggleRelation(relation) } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                        .opacity(hidden ? 0.3 : 1.0)

                    Text(relation.replacingOccurrences(of: "_", with: " "))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(hidden ? 0.3 : 0.7))
                        .strikethrough(hidden)
                        .lineLimit(1)

                    Spacer()

                    Text("\(count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))

                    Image(systemName: hidden ? "eye.slash" : "eye")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(hidden ? 0.3 : 0.5))
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar.relation.\(relation)")
        }
    }

    // MARK: - Toggle Row

    private func toggleRow(_ label: String, icon: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 12, design: .monospaced))
                Spacer()
                togglePill(isOn: isOn)
            }
            .foregroundStyle(.white.opacity(0.7))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Advise group-memory opt-out (decision 15's escape hatch)

    /// Per-device knob read by the advise hook. Default ON (beta posture);
    /// stored as a HookState row so hooks see it without extra plumbing.
    var adviseIncludesGroupMemories: Bool {
        hookStates.first { $0.key == .adviseIncludeGroupMemories }?.value != "false"
    }

    func setAdviseIncludesGroupMemories(_ include: Bool) {
        if let row = hookStates.first(where: { $0.key == .adviseIncludeGroupMemories }) {
            row.value = include ? "true" : "false"
            row.updatedAt = Date()
        } else {
            do {
                try lattice.add(HookState(key: .adviseIncludeGroupMemories,
                                          value: include ? "true" : "false"))
            } catch {
                print("[Sidebar] advise opt-out write failed: \(error)")
            }
        }
    }

    func togglePill(isOn: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isOn ? Color.cyan.opacity(0.5) : .white.opacity(0.1))
            .frame(width: 32, height: 18)
            .overlay(
                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .offset(x: isOn ? 7 : -7)
            )
            .animation(.easeInOut(duration: 0.15), value: isOn)
    }

    // MARK: - Stat Row

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    nonisolated private static func readDBFileSize() -> String {
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

    // MARK: - Settings Tab

    @ViewBuilder
    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            section("Notifications") {
                toggleRow(
                    "Push Notifications",
                    icon: config.notificationsEnabled ? "bell.fill" : "bell.slash.fill",
                    isOn: config.notificationsEnabled
                ) {
                    if config.notificationsEnabled {
                        config.notificationsEnabled = false
                    } else {
                        Task {
                            let center = UNUserNotificationCenter.current()
                            let granted = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
                            if granted == true {
                                config.notificationsEnabled = true
                            }
                        }
                    }
                }
            }

            section("Panels") {
                toggleRow(
                    "Activity Log",
                    icon: config.showActivityLog ? "list.bullet.rectangle" : "list.bullet.rectangle",
                    isOn: config.showActivityLog
                ) {
                    config.showActivityLog.toggle()
                }
                toggleRow(
                    "Stats Overlay",
                    icon: config.showStatsOverlay ? "chart.bar.fill" : "chart.bar",
                    isOn: config.showStatsOverlay
                ) {
                    config.showStatsOverlay.toggle()
                }
                toggleRow(
                    "Mascot Bots",
                    icon: config.showMascots ? "figure.walk" : "figure.stand",
                    isOn: config.showMascots
                ) {
                    config.showMascots.toggle()
                }
            }

            section("Audio") {
                toggleRow(
                    "Sound Effects",
                    icon: config.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    isOn: config.soundEnabled
                ) {
                    config.soundEnabled.toggle()
                }
            }

            section("Advise") {
                VStack(alignment: .leading, spacing: 6) {
                    toggleRow(
                        "Teammates' memories in advise",
                        icon: "person.2.wave.2",
                        isOn: adviseIncludesGroupMemories
                    ) {
                        setAdviseIncludesGroupMemories(!adviseIncludesGroupMemories)
                    }
                    Text("When off, group-shared memories from teammates are excluded from automatic context injection on this device.")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            section("Storage") {
                VStack(alignment: .leading, spacing: 10) {
                    statRow("Database", value: dbFileSize)

                    Button {
                        guard !isCompacting else { return }
                        isCompacting = true
                        Task {
                            lattice.compactHistory()
                            lattice.vacuum()
                            lattice.checkpoint()
                            isCompacting = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isCompacting {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 11))
                            }
                            Text(isCompacting ? "Compacting…" : "Compact Database")
                                .font(.system(size: 12, design: .monospaced))
                        }
                        .foregroundStyle(.white.opacity(isCompacting ? 0.4 : 0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.white.opacity(0.06))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isCompacting)
                }
            }

            section("About") {
                VStack(alignment: .leading, spacing: 6) {
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
                    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                    statRow("Version", value: "v\(version)")
                    statRow("Build", value: build)
                }
            }
        }
    }
}
