import SwiftUI

public enum EngramGraphLayout: String, CaseIterable, Equatable, Sendable {
    case forceDirected = "Force"
    case embedding = "Semantic"
}

public struct EngramGraphLayoutPicker: View {
    let mode: EngramGraphLayout
    let progress: Double?
    let onModeChange: (EngramGraphLayout) -> Void

    public init(mode: EngramGraphLayout, progress: Double? = nil,
                onModeChange: @escaping (EngramGraphLayout) -> Void) {
        self.mode = mode; self.progress = progress; self.onModeChange = onModeChange
    }
    public var body: some View {
        HStack(spacing: 0) {
            ForEach(EngramGraphLayout.allCases, id: \.rawValue) { m in
                Button {
                    onModeChange(m)
                } label: {
                    HStack(spacing: 4) {
                        if m == .embedding, let progress {
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
                    .engramGraphTouchTarget()
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
