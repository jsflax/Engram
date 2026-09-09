import CoreGraphics
import CoreText
import Foundation
import AppKit

/// Renders holo screen info card text into a CGImage using CoreText.
///
/// Ported from the Metal-era MascotSystem.renderHoloTexture() — same layout,
/// fonts, and colors. Returns a CGImage that callers convert to a RealityKit
/// TextureResource.
actor HoloTextureRenderer {
    static let shared = HoloTextureRenderer()

    /// Info needed to render the holo card.
    struct NodeInfo: Sendable, Equatable {
        let content: String
        let project: String
        let topic: String
        let importance: Int
        let createdAt: Date
        let lastAccessedAt: Date
    }

    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df
    }()

    /// Render an info card as a CGImage (512×400 logical, 2× retina = 1024×800).
    func render(info: NodeInfo) -> CGImage? {
        // Requests are serialized here, away from the main/render actor. A
        // superseded request waiting in the actor queue performs no raster work.
        guard !Task.isCancelled else { return nil }
        let texW = 512
        let texH = 400
        let scale = 2
        let allocW = texW * scale
        let allocH = texH * scale
        let bytesPerRow = allocW * 4

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: allocW, height: allocH,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: allocW, height: allocH))

        // Flip horizontally — RealityKit's generatePlane UVs are mirrored from front face
        ctx.translateBy(x: CGFloat(allocW), y: 0)
        ctx.scaleBy(x: -1, y: 1)

        // Semi-transparent dark background panel
        ctx.setFillColor(CGColor(red: 0.02, green: 0.06, blue: 0.12, alpha: 0.7))
        ctx.fill(CGRect(x: 0, y: 0, width: allocW, height: allocH))

        // Glowing border
        let borderColor = CGColor(red: 0.1, green: 0.5, blue: 0.8, alpha: 0.6)
        ctx.setStrokeColor(borderColor)
        ctx.setLineWidth(CGFloat(scale) * 2)
        ctx.stroke(CGRect(x: 2, y: 2, width: allocW - 4, height: allocH - 4))

        // Scale for retina
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

        // Fonts
        let topicFont: CTFont = NSFont.monospacedSystemFont(ofSize: 18, weight: .bold) as CTFont
        let metaFont: CTFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular) as CTFont
        let sepFont: CTFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular) as CTFont
        let contentFont: CTFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular) as CTFont

        // Colors
        let topicColor = CGColor(red: 0.3, green: 0.9, blue: 1.0, alpha: 1.0)
        let metaColor = CGColor(red: 0.45, green: 0.6, blue: 0.7, alpha: 0.7)
        let sepColor = CGColor(red: 0.3, green: 0.5, blue: 0.6, alpha: 0.4)
        let contentColor = CGColor(red: 0.65, green: 0.8, blue: 0.9, alpha: 0.85)

        func makeLine(_ text: String, font: CTFont, color: CGColor) -> (line: CTLine, ascent: CGFloat) {
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: color
            ]
            let attrStr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attrStr)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            return (line, ascent)
        }

        func drawLine(_ line: CTLine, ascent: CGFloat, x: CGFloat, topY: CGFloat) {
            ctx.textPosition = CGPoint(x: x, y: CGFloat(texH) - topY - ascent)
            CTLineDraw(line, ctx)
        }

        let margin: CGFloat = 32
        var y: CGFloat = 28

        // Header: Topic / Project
        let topicStr = "\(info.topic.prefix(24)) / \(info.project.prefix(16))"
        let topic = makeLine(topicStr, font: topicFont, color: topicColor)
        drawLine(topic.line, ascent: topic.ascent, x: margin, topY: y)
        y += 26

        // Meta: dates
        let metaStr = "created \(dateFormatter.string(from: info.createdAt))  |  accessed \(dateFormatter.string(from: info.lastAccessedAt))"
        let meta = makeLine(metaStr, font: metaFont, color: metaColor)
        drawLine(meta.line, ascent: meta.ascent, x: margin, topY: y)
        y += 16

        // Separator
        let sep = String(repeating: "\u{2500}", count: 46)
        let sepLine = makeLine(sep, font: sepFont, color: sepColor)
        drawLine(sepLine.line, ascent: sepLine.ascent, x: margin, topY: y)
        y += 12

        // Content: word-wrapped
        let lineHeight: CGFloat = 14
        let usableWidth = CGFloat(texW) - margin * 2
        let contentCharsPerLine = Int(usableWidth / 6)
        let maxLines = Int((CGFloat(texH) - y - 20) / lineHeight)

        let content = info.content
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        var lines: [String] = []
        var currentLine = ""
        for word in content.split(separator: " ", omittingEmptySubsequences: true) {
            guard !Task.isCancelled else { return nil }
            let candidate = currentLine.isEmpty ? String(word) : currentLine + " " + word
            if candidate.count > contentCharsPerLine && !currentLine.isEmpty {
                lines.append(currentLine)
                // Later lines never fit on the unchanged card; avoid wrapping
                // the remainder of a long memory that cannot be displayed.
                if lines.count == maxLines { currentLine = ""; break }
                currentLine = String(word)
            } else {
                currentLine = candidate
            }
        }
        if !currentLine.isEmpty { lines.append(currentLine) }

        for line in lines.prefix(maxLines) {
            guard !Task.isCancelled else { return nil }
            let ct = makeLine(line, font: contentFont, color: contentColor)
            drawLine(ct.line, ascent: ct.ascent, x: margin, topY: y)
            y += lineHeight
        }

        return ctx.makeImage()
    }
}
