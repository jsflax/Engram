import EngramModels

/// Capture database-backed values once in the parent's observation scope.
/// Lazy project rows retain only values; rebuilding the parent reads live data.
struct SidebarSyncSnapshot: Equatable, Sendable {
    struct Project: Equatable, Sendable {
        let isSyncing: Bool
        let exposedGroups: Set<String>

        static let missing = Project(isSyncing: false, exposedGroups: [])
    }

    static let empty = SidebarSyncSnapshot([])
    private let projects: [String: Project]

    init<Configs: Sequence>(_ configs: Configs) where Configs.Element == SyncConfig {
        var projects: [String: Project] = [:]
        for config in configs {
            let project = config.project
            // Match the previous first(where:) behavior if a caller supplies
            // duplicates, rather than trapping or silently choosing the last.
            guard projects[project] == nil else { continue }
            projects[project] = Project(isSyncing: config.policy == .sync,
                                        exposedGroups: config.exposedGroups)
        }
        self.projects = projects
    }

    subscript(project: String) -> Project { projects[project] ?? .missing }
}
