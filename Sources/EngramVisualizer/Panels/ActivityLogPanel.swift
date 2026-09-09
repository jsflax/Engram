import SwiftUI

struct ActivityLogPanel: View {
    let galaxyRegistry: GalaxyRegistry
    let onSelect: (UUID) -> Void

    @State private var knownCount: Int = 0
    @State private var glowingIds: Set<UUID> = []

    fileprivate static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let colorMap = galaxyRegistry.panelSnapshot.colorMap
            let recent = galaxyRegistry.panelSnapshot.recentNodes
            let nodeCount = galaxyRegistry.panelSnapshot.visibleCount

            VStack(alignment: .trailing, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                    Text("Activity")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                Divider().overlay(Color.white.opacity(0.15))

                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .trailing, spacing: 2) {
                        ForEach(recent, id: \.id) { node in
                            let isGlowing = glowingIds.contains(node.id)
                            ActivityRow(
                                node: node,
                                colorMap: colorMap,
                                isGlowing: isGlowing,
                                now: context.date,
                                onSelect: onSelect
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(width: 220)
            .frame(maxHeight: 300)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white.opacity(0.7))
            .onChange(of: nodeCount) { _, newCount in
                guard knownCount > 0, newCount > knownCount else {
                    knownCount = newCount
                    return
                }
                // New nodes = those in recentNodes that weren't there before
                let newIds = Set(recent.prefix(newCount - knownCount).map(\.id))
                knownCount = newCount
                withAnimation(.easeInOut(duration: 0.3)) {
                    glowingIds.formUnion(newIds)
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    withAnimation(.easeOut(duration: 0.6)) {
                        glowingIds.subtract(newIds)
                    }
                }
            }
        }
        .onAppear { galaxyRegistry.panelSnapshot.refresh(from: galaxyRegistry) }
    }
}

private struct ActivityRow: View {
    let node: NodeData
    let colorMap: [String: Color]
    let isGlowing: Bool
    let now: Date
    let onSelect: (UUID) -> Void

    var body: some View {
        Button {
            onSelect(node.id)
        } label: {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Text(relativeTime)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(minWidth: 32, alignment: .trailing)
                Text(node.label)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isGlowing ? .cyan : .white.opacity(0.7))
                Circle()
                    .fill(GraphView.projectColor(for: node.project, in: colorMap))
                    .frame(width: 6, height: 6)
                    .shadow(color: isGlowing ? .cyan.opacity(0.8) : .clear, radius: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(.cyan.opacity(isGlowing ? 0.1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.6), value: isGlowing)
    }

    private var relativeTime: String {
        ActivityLogPanel.relativeFormatter.localizedString(for: node.createdAt, relativeTo: now)
    }
}
