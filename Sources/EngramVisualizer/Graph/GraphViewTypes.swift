import EngramGraphUI
import SwiftUI
import Lattice
import Combine
import EngramKit
import simd

// MARK: - Display data

struct TopicGroupInfo: Equatable {
    let topic: String
    let project: String
    let ids: [UUID]
}

// MARK: - Camera 3D state (isolated from GraphView to avoid body re-evaluation on camera changes)

/// Holds 3D camera state. Written by renderTick's cameraCallback.
/// All properties are @ObservationIgnored to avoid triggering
/// expensive re-renders every frame.
@Observable
@MainActor
final class Camera3DState {
    @ObservationIgnored var azimuth: Float = 0
    @ObservationIgnored var position: SIMD3<Float> = .zero
    @ObservationIgnored var target: SIMD3<Float> = .zero
    @ObservationIgnored var positions: [UUID: SIMD3<Float>] = [:]
}

// MARK: - Viewport state (isolated from query data to avoid expensive recomputation on pan/zoom)

@Observable
@MainActor
final class ViewportState {
    var scale: CGFloat = 1.0
    var offset: CGPoint = .zero
    var draggedNode: UUID?
    var hoveredNode: UUID?

    // Animated pan target — lerped each frame by the Canvas timer
    private var targetOffset: CGPoint?
    private let panSpeed: CGFloat = 0.12
    var isAnimatingPan: Bool { targetOffset != nil }

    func animateTo(offset target: CGPoint) {
        targetOffset = target
    }

    /// Call each frame to interpolate toward the target. Returns true while animating.
    @discardableResult
    func tickPan() -> Bool {
        guard let target = targetOffset else { return false }
        let dx = target.x - offset.x
        let dy = target.y - offset.y
        if abs(dx) < 0.5 && abs(dy) < 0.5 {
            offset = target
            targetOffset = nil
            return false
        }
        offset = CGPoint(
            x: offset.x + dx * panSpeed,
            y: offset.y + dy * panSpeed
        )
        return true
    }
}

// MARK: - Sound Toggle (isolated to avoid re-rendering GraphView)

struct SoundToggleButton: View {
    @Environment(VisualizerConfig.self) private var config

    var body: some View {
        Button {
            config.soundEnabled.toggle()
        } label: {
            Image(systemName: config.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(config.soundEnabled ? 0.7 : 0.3))
        }
        .buttonStyle(.plain)
        .help(config.soundEnabled ? "Mute notifications" : "Unmute notifications")
    }
}

// MARK: - Keyboard Shortcuts Modifier

struct GraphKeyboardShortcuts: ViewModifier {
    @Binding var selectedMemoryId: UUID?
    let viewport: ViewportState
    let cycleConnectedNode: () -> Void
    let exportToPNG: () -> Void

    func body(content: Content) -> some View {
        content
            .onKeyPress(.escape) {
                selectedMemoryId = nil
                return .handled
            }
            .onKeyPress(.tab) {
                cycleConnectedNode()
                return .handled
            }
            .onKeyPress("+") {
                viewport.scale = min(3.0, viewport.scale * 1.1)
                return .handled
            }
            .onKeyPress("=") {
                viewport.scale = min(3.0, viewport.scale * 1.1)
                return .handled
            }
            .onKeyPress("-") {
                viewport.scale = max(0.2, viewport.scale / 1.1)
                return .handled
            }
            .onKeyPress(characters: .alphanumerics, phases: .down) { keyPress in
                if keyPress.characters == "E" && keyPress.modifiers == [.command, .shift] {
                    exportToPNG()
                    return .handled
                }
                return .ignored
            }
    }
}

// MARK: - Search Bar (isolated view — owns its own text state to avoid invalidating GraphView on each keystroke)

struct SearchBarView: View {
    @Binding var matchIds: Set<UUID>
    @Binding var isActive: Bool
    let lattice: Lattice

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        EngramGraphSearchField(text: $text, matchCount: matchIds.count)
        .task(id: text) {
            let query = text
            guard !query.isEmpty else {
                matchIds = []
                isActive = false
                return
            }
            isActive = true
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let ftsQuery: TextQuery = .search(query)
            var ids = Set<UUID>()
            for match in lattice.objects(Memory.self).matching(ftsQuery, on: \.content, limit: 500) {
                if let gid = match.object.globalId { ids.insert(gid) }
            }
            matchIds = ids
        }
    }
}
