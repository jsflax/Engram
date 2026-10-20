import SwiftUI
import Lattice
import EngramKit
import EngramGraphUI

/// Resolves the desktop's live row and attribution before shared presentation.
struct MemoryDetailPanel: View {
    @Bindable var memory: Memory
    let connectedCount: Int
    let onClose: () -> Void
    let colorMap: [String: Color]
    var body: some View {
        if let id = memory.globalId {
            EngramGraphMemoryDetailPanel(
                memory: EngramGraphMemory(id: id, content: memory.content,
                    project: memory.project, topic: memory.topic, importance: memory.importance,
                    createdAt: memory.createdAt, lastAccessedAt: memory.lastAccessedAt,
                    accessCount: memory.accessCount, source: memory.source),
                connectedCount: connectedCount,
                projectColor: GraphView.projectColor(for: memory.project, in: colorMap),
                authorDisplayName: memory.authorUserId.flatMap {
                    $0 == GroupDirectory.currentUserId() ? nil : GroupDirectory.badgeName(for: $0)
                }, onClose: onClose)
        }
    }
}
