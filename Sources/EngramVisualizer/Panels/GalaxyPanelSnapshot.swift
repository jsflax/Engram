import SwiftUI

/// Observable panel data is separate from the graph host and its per-frame data.
/// Rebuild once per group of topology changes, never during a timeline tick.
@MainActor @Observable
final class GalaxyPanelSnapshot {
    private(set) var visibleCount = 0
    private(set) var totalCount = 0
    private(set) var edgeCount = 0
    private(set) var projectCounts: [String: Int] = [:]
    private(set) var projects: [String] = []
    private(set) var colorMap: [String: Color] = [:]
    private(set) var recentNodes: [NodeData] = []
    private(set) var relationCounts: [(key: String, value: Int)] = []
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored nonisolated(unsafe) private var refreshTask: Task<Void, Never>?

    func refresh(from registry: GalaxyRegistry) {
        needsRefresh = true
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self, weak registry] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                guard let self, let registry else { break }
                // onAppear can request a refresh independently of the registry,
                // and a scheduled refresh may outlive the start of bulk loading.
                // Keep the request pending without retaining mutable buffers;
                // the next iteration retries after its normal coalescing delay.
                if registry.galaxies.values.contains(where: { $0.isDrainingInitialSnapshot }) { continue }
                self.needsRefresh = false
                // Copies share storage. Enumeration, deduplication, and selection
                // happen on the worker; no model or registry crosses the actor.
                let nodes = registry.galaxiesInPrecedenceOrder().map { $0.renderStore.allNodes }
                let visible = registry.mergedNodes
                let colors = registry.mergedColorMap
                let edgeCount = registry.mergedEdges.count
                let relations = registry.mergedRelationCounts
                let derived = await Task.detached(priority: .utility) {
                    Self.derive(allNodes: nodes, visible: visible)
                }.value
                guard !Task.isCancelled else { break }
                self.totalCount = derived.totalCount
                self.visibleCount = visible.count
                self.edgeCount = edgeCount
                self.projectCounts = derived.projectCounts
                self.projects = colors.keys.sorted()
                self.recentNodes = derived.recent
                self.colorMap = colors
                self.relationCounts = relations
                if !self.needsRefresh { break }
            }
            self?.refreshTask = nil
        }
    }

    deinit { refreshTask?.cancel() }

    nonisolated static func derive(allNodes: [[UUID: NodeData]], visible: [NodeData])
        -> (totalCount: Int, projectCounts: [String: Int], recent: [NodeData]) {
        var seen: Set<UUID> = []
        var counts: [String: Int] = [:]
        for galaxy in allNodes {
            for node in galaxy.values where seen.insert(node.id).inserted {
                counts[node.project, default: 0] += 1
            }
        }
        // Keep only the top 50 while scanning; avoid sorting the whole graph.
        var recent: [NodeData] = []
        recent.reserveCapacity(50)
        for node in visible {
            let index = recent.firstIndex {
                node.createdAt > $0.createdAt ||
                    (node.createdAt == $0.createdAt && node.id.uuidString < $0.id.uuidString)
            } ?? recent.endIndex
            if index < 50 {
                recent.insert(node, at: index)
                if recent.count > 50 { recent.removeLast() }
            }
        }
        return (seen.count, counts, recent)
    }
}
