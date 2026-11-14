import SwiftUI

/// Detail panel showing a selected memory's content with typewriter effect.
/// The host supplies an immutable row; changing its content restarts the animation.
public struct EngramGraphMemoryDetailPanel: View {
    private let memory: EngramGraphMemory
    let connectedCount: Int
    let onClose: () -> Void
    private let projectColor: Color
    private let authorDisplayName: String?

    public init(memory: EngramGraphMemory, connectedCount: Int, projectColor: Color,
                authorDisplayName: String? = nil, onClose: @escaping () -> Void) {
        self.memory = memory; self.connectedCount = connectedCount; self.projectColor = projectColor
        self.authorDisplayName = authorDisplayName; self.onClose = onClose
    }

    @State private var typingProgress: Int = 0
    private var content: String { memory.content }
    private var typingDone: Bool { typingProgress >= content.count }

    public var body: some View {
        Group {
            #if os(iOS)
            mobileContent
            #else
            desktopContent
            #endif
        }
        #if os(iOS)
        .padding(12)
        #else
        .padding(20)
        #endif
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.08, green: 0.1, blue: 0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            projectColor.opacity(0.3),
                            lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
        }
        .task(id: memory.id.uuidString + content) {
            typingProgress = 0
            let total = content.count
            // Adaptive batch size: complete in ~1s at 60fps (~60 ticks)
            let batch = max(2, total / 60)
            while !Task.isCancelled && typingProgress < total {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                typingProgress = min(typingProgress + batch, total)
            }
        }
    }
    private var mobileContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(projectColor).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(memory.project).font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(projectColor).lineLimit(1)
                    Text(memory.topic).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.6)).engramGraphTouchTarget()
                }
                .buttonStyle(.plain).accessibilityLabel("Close memory details")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    contentText
                    metadata
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("engram.graph.memory-detail-scroll")
        }
    }

    private var desktopContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Circle()
                    .fill(projectColor)
                    .frame(width: 10, height: 10)
                Text(memory.project)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(projectColor)
                Text("·")
                    .foregroundStyle(.white.opacity(0.3))
                Text(memory.topic)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.4))
                        .font(.system(size: 16))
                        .engramGraphTouchTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close memory details")
            }
            .padding(.bottom, 12)

            // Content (typewriter effect — text selection deferred until animation completes)
            ScrollView {
                contentText
            }

            Spacer(minLength: 12)

            metadata
        }
    }

    @ViewBuilder private var contentText: some View {
        let displayText = typingDone ? content : String(content.prefix(typingProgress))
        if typingDone {
            Text(displayText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        } else {
            Text(displayText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let source = memory.source, !source.isEmpty {
                Text("source: \(source)")
                    #if !os(iOS)
                    .lineLimit(2)
                    #endif
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
            }
            Text("accesses: \(memory.accessCount)")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
            if connectedCount > 0 {
                Divider().overlay(Color.white.opacity(0.1))
                Text("\(connectedCount) connection\(connectedCount == 1 ? "" : "s")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
            HStack {
                if memory.importance > 0 {
                    Text("importance: \(memory.importance)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
                // Attribution for group-shared rows; self/legacy stay
                // clean (nil author or the signed-in user's own id).
                if let authorDisplayName {
                    Text("by \(authorDisplayName)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.cyan.opacity(0.5))
                }
                Spacer()
                Text(memory.createdAt, style: .date)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
    }

}
