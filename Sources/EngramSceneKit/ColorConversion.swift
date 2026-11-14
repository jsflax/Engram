// Platform color adapters for the shared scene renderer.

import SwiftUI
import simd
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Convert a SwiftUI Color to SIMD3<Float> via sRGB extraction.
public func colorToSIMD3(_ color: Color) -> SIMD3<Float> {
    #if os(macOS)
    let platformColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
    #else
    let platformColor = UIColor(color)
    #endif
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    platformColor.getRed(&r, green: &g, blue: &b, alpha: &a)
    return SIMD3<Float>(Float(r), Float(g), Float(b))
}

/// Dim a node color for edge rendering (0.6x).
@inlinable
public func edgeColorSIMD3(nodeColor: SIMD3<Float>) -> SIMD3<Float> {
    nodeColor * 0.6
}

/// Convert a project color for nebula rendering (1.3x + 0.1 boost, clamped).
public func nebulaColorSIMD4(from color: Color, alpha: Float = 0.25) -> SIMD4<Float> {
    let base = colorToSIMD3(color)
    return SIMD4<Float>(
        min(1.0, base.x * 1.3 + 0.1),
        min(1.0, base.y * 1.3 + 0.1),
        min(1.0, base.z * 1.3 + 0.1),
        alpha
    )
}
