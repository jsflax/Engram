import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Shared search control; the owner supplies the query engine for its exact graph.
public struct EngramGraphSearchField: View {
    @Binding private var text: String
    private let matchCount: Int
    #if os(iOS)
    @State private var isFocused = false
    #else
    @FocusState private var isFocused: Bool
    #endif
    public init(text: Binding<String>, matchCount: Int) {
        self._text = text; self.matchCount = matchCount
    }
    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.4))
                .font(.system(size: 12))
            #if os(iOS)
            EngramGraphTouchSearchField(text: $text, isFocused: $isFocused)
                .frame(minWidth: 80, maxWidth: .infinity, minHeight: 44)
            #else
            TextField("Search memories…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .focused($isFocused)
                .frame(minWidth: 80, idealWidth: 180, maxWidth: 180)
                .onKeyPress(.escape) {
                    text = ""
                    isFocused = false
                    return .handled
                }
            #endif
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.4))
                        .font(.system(size: 11))
                        .engramGraphTouchTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear memory search")

                Text("\(matchCount) match\(matchCount == 1 ? "" : "es")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    #if os(iOS)
                    .fixedSize(horizontal: true, vertical: false)
                    #endif
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.08, green: 0.1, blue: 0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.white.opacity(isFocused ? 0.3 : 0.1), lineWidth: 1)
                )
        )
    }
}

#if os(iOS)
/// Give the native editable control the full touch height. A SwiftUI frame around
/// a plain TextField enlarged its wrapper while the field's actual AX frame
/// remained 22 points high in the app's browser.
private struct EngramGraphTouchSearchField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, isFocused: $isFocused) }
    func makeUIView(context: Context) -> TouchTextField {
        let field = TouchTextField()
        field.placeholder = "Search memories…"
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.textColor = UIColor.white.withAlphaComponent(0.9)
        field.borderStyle = .none
        field.returnKeyType = .search
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateUIView(_ field: TouchTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isFocused = $isFocused
        if field.text != text { field.text = text }
        if isFocused && !field.isFirstResponder { field.becomeFirstResponder() }
        else if !isFocused && field.isFirstResponder { field.resignFirstResponder() }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>
        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text; self.isFocused = isFocused
        }
        @objc func textChanged(_ field: UITextField) { text.wrappedValue = field.text ?? "" }
        func textFieldDidBeginEditing(_ field: UITextField) {
            if !isFocused.wrappedValue { isFocused.wrappedValue = true }
        }
        func textFieldDidEndEditing(_ field: UITextField) {
            if isFocused.wrappedValue { isFocused.wrappedValue = false }
        }
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
            return true
        }
    }

    final class TouchTextField: UITextField {
        override var intrinsicContentSize: CGSize {
            let size = super.intrinsicContentSize
            return CGSize(width: size.width, height: max(44, size.height))
        }
        override var keyCommands: [UIKeyCommand]? {
            (super.keyCommands ?? []) + [UIKeyCommand(input: UIKeyCommand.inputEscape,
                modifierFlags: [], action: #selector(clearAndResign))]
        }
        @objc private func clearAndResign() {
            text = ""
            sendActions(for: .editingChanged)
            resignFirstResponder()
        }
    }
}
#endif
