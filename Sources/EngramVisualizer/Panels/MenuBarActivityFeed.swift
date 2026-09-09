import SwiftUI
import Lattice
import EngramKit

struct MenuBarActivityFeed: View {
    @Environment(\.lattice) private var lattice
    @State private var store = MenuBarActivityStore()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 8) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 14))
                    Text("Engram")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Spacer()
                    Text("\(store.rows.count)")
                        .accessibilityIdentifier("menu.memory-count")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Divider()

                // Open Engram button
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first { $0.title == "Engram" }?.makeKeyAndOrderFront(nil)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 11))
                        Text("Open Engram")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(.quaternary.opacity(0.5))

                Divider()

                // Recent memories
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.rows) { memory in
                            MenuBarMemoryRow(
                                memory: memory,
                                color: store.projectColors[memory.project] ?? .gray,
                                now: context.date
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(width: 300, height: 400)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("menu.activity-feed")
            .background {
                WindowVisibilityLifecycle(
                    responseName: "menu.feed",
                    onShow: { store.start(lattice: lattice) },
                    onHide: { store.stop() }
                )
                .allowsHitTesting(false)
            }
        }
    }
}

private struct MenuBarMemoryRow: View {
    let memory: MenuBarMemory
    let color: Color
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(memory.label)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Text(memory.relativeTimestamp(at: now))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
