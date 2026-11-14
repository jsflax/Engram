import Foundation
import CoreGraphics
import CoreText
#if os(macOS)
import AppKit
internal typealias RKPlatformColor = NSColor
#else
import UIKit
internal typealias RKPlatformColor = UIColor
#endif

/// Shared drawing adapters; graph layout/rendering remains in the existing systems.
internal enum RKPlatform {
    static func font(size: CGFloat, bold: Bool = false, monospaced: Bool = false) -> CTFont {
        let kind: CTFontUIFontType = monospaced ? .userFixedPitch : (bold ? .emphasizedSystem : .system)
        let base = CTFontCreateUIFontForLanguage(kind, size, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, size, nil)
        if bold, let strong = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) { return strong }
        return base
    }
    @MainActor static var maximumFramesPerSecond: Int {
        #if os(macOS)
        NSScreen.main?.maximumFramesPerSecond ?? 0
        #else
        UIScreen.main.maximumFramesPerSecond
        #endif
    }
}
