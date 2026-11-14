import SwiftUI

extension View {
    /// Enlarge the actual label and hit region on touch devices. Desktop wrappers
    /// keep their existing compact layout.
    @ViewBuilder
    func engramGraphTouchTarget(alignment: Alignment = .center) -> some View {
        #if os(iOS)
        self.frame(minWidth: 48, minHeight: 48, alignment: alignment)
            .contentShape(Rectangle())
        #else
        self
        #endif
    }
}
