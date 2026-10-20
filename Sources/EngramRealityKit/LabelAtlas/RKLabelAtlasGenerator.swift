import CoreText
import CoreGraphics
import Metal
import RealityKit
import simd
import Foundation

/// Generates a texture atlas of label text using CoreText.
///
/// Port of LabelAtlasGenerator.swift — uses CoreText to rasterize labels
/// into a texture atlas. Outputs TextureResource for RealityKit.
@MainActor
public final class RKLabelAtlasGenerator {
    private let device: MTLDevice

    /// UV rects for each node label.
    public private(set) var nodeRects: [UUID: (u0: Float, v0: Float, u1: Float, v1: Float)] = [:]
    /// UV rects for project labels.
    public private(set) var projectRects: [String: (u0: Float, v0: Float, u1: Float, v1: Float)] = [:]
    /// UV rects for topic labels.
    public private(set) var topicRects: [String: (u0: Float, v0: Float, u1: Float, v1: Float)] = [:]
    /// Aspect correction factor.
    public private(set) var aspectCorrection: Float = 1.0
    /// Atlas texture resource for RealityKit materials.
    public private(set) var atlasTexture: TextureResource?

    // Counts successful atlas creation, excluding cached-input early returns.
    private(set) var diagnosticAtlasCreations: UInt64 = 0
    private var cachedEntries: [AtlasEntry] = []
    private var cachedProjects: Set<String> = []
    private var cachedTopics: Set<String> = []

    public init(device: MTLDevice) {
        self.device = device
    }

    /// Regenerate the label atlas for the given nodes and project/topic cluster names.
    ///
    /// Project and topic labels are packed first (always visible), then node labels
    /// fill remaining space. This guarantees cluster labels are never crowded out
    /// when node count is high.
    public func regenerateAtlas(
        nodes: [RKNodeSnapshot],
        hubs: Set<UUID>,
        projects: Set<String> = [],
        topics: Set<String> = []
    ) {
        _ = refreshAtlas(nodes: nodes, hubs: hubs, projects: projects, topics: topics)
    }

    /// True when these exact raster inputs have a valid cached or newly created atlas.
    func refreshAtlas(
        nodes: [RKNodeSnapshot], hubs: Set<UUID>, projects: Set<String>, topics: Set<String>
    ) -> Bool {
        let entries = nodes.map { node in
            AtlasEntry(id: node.id, label: node.label, isHub: hubs.contains(node.id))
        }

        // Compare raster inputs only at regeneration boundaries, never per frame.
        if entries == cachedEntries, projects == cachedProjects, topics == cachedTopics,
           atlasTexture != nil { return true }
        guard !entries.isEmpty else { return false }

        // Fonts
        let monoMedium = CTFontCreateWithName("SF Mono" as CFString, 14, nil)
        let monoBold = CTFontCreateWithName("SF Mono" as CFString, 16, nil)
        let projFont = CTFontCreateWithName("SF Mono" as CFString, 36, nil)
        let topicFont = CTFontCreateWithName("SF Mono" as CFString, 24, nil)

        let padding: CGFloat = 4
        let maxDim = 4096
        // Keep the complete line. If it exceeds the bounded native texture,
        // uniformly reduce its raster scale instead of clipping or dropping it.
        func boundedMetrics(width: CGFloat, height: CGFloat, ascent: CGFloat)
            -> (width: CGFloat, height: CGFloat, ascent: CGFloat, scale: CGFloat) {
            let limit = CGFloat(maxDim) - padding * 2
            let scale = min(1, min(limit / max(width, 1), limit / max(height, 1)))
            return (width * scale, height * scale, ascent * scale, scale)
        }
        let labelColor = CGColor(gray: 1, alpha: 1)

        // --- Measure project labels ---
        struct ClusterLabel {
            let key: String
            let line: CTLine
            let width: CGFloat
            let height: CGFloat
            let ascent: CGFloat
            let rasterScale: CGFloat
        }
        var projLabels: [ClusterLabel] = []
        for name in projects.sorted() {
            let attrs: [NSAttributedString.Key: Any] = [.font: projFont, .foregroundColor: labelColor]
            let attrStr = NSAttributedString(string: name.uppercased(), attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrStr)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let w = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let metrics = boundedMetrics(width: w + 8, height: ascent + descent + leading, ascent: ascent)
            projLabels.append(ClusterLabel(key: name, line: line, width: metrics.width,
                height: metrics.height, ascent: metrics.ascent, rasterScale: metrics.scale))
        }

        // --- Measure topic labels ---
        var topicLabels: [ClusterLabel] = []
        for name in topics.sorted() {
            let attrs: [NSAttributedString.Key: Any] = [.font: topicFont, .foregroundColor: labelColor]
            let attrStr = NSAttributedString(string: name, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrStr)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let w = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let metrics = boundedMetrics(width: w + 8, height: ascent + descent + leading, ascent: ascent)
            topicLabels.append(ClusterLabel(key: name, line: line, width: metrics.width,
                height: metrics.height, ascent: metrics.ascent, rasterScale: metrics.scale))
        }

        // --- Measure node labels ---
        var labelInfos: [(entry: AtlasEntry, line: CTLine, width: CGFloat, height: CGFloat, ascent: CGFloat, rasterScale: CGFloat)] = []
        for entry in entries {
            let font = entry.isHub ? monoBold : monoMedium
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: labelColor]
            let attrStr = NSAttributedString(string: entry.label, attributes: attributes)
            let line = CTLineCreateWithAttributedString(attrStr)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let height = ascent + descent + leading
            let metrics = boundedMetrics(width: width + 8, height: height + 4, ascent: ascent)
            labelInfos.append((entry, line, metrics.width, metrics.height, metrics.ascent, metrics.scale))
        }
        labelInfos.sort { $0.height > $1.height }

        // --- Determine atlas size ---
        // Estimate cluster label space needed (pack them first)
        func clusterPackHeight(_ labels: [ClusterLabel], atlasWidth: Int) -> Int {
            var curX: Int = 0, curY: Int = 0, rowH: Int = 0
            for label in labels {
                let w = Int(ceil(label.width + padding * 2))
                let h = Int(ceil(label.height + padding * 2))
                if curX + w > atlasWidth { curX = 0; curY += rowH; rowH = 0 }
                curX += w
                rowH = max(rowH, h)
            }
            return curY + rowH
        }

        var atlasW: Int = 512
        var atlasH: Int = 512
        // Row wrapping alone cannot fit a rectangle wider than the bitmap.
        let widestCluster = max(projLabels.map(\.width).max() ?? 0, topicLabels.map(\.width).max() ?? 0)
        let widest = max(widestCluster, labelInfos.map(\.width).max() ?? 0)
        let minimumWidth = min(maxDim, Int(ceil(widest + padding * 2)))
        while atlasW < minimumWidth { atlasW *= 2 }

        // Expand atlas to fit cluster labels + as many node labels as possible
        while true {
            let clusterH = clusterPackHeight(projLabels, atlasWidth: atlasW)
                         + clusterPackHeight(topicLabels, atlasWidth: atlasW)
            let remainH = atlasH - clusterH

            // Try packing node labels in remaining space
            var curX: Int = 0, curY: Int = 0, rowH: Int = 0
            var fits = true
            for info in labelInfos {
                let w = Int(ceil(info.width + padding * 2))
                let h = Int(ceil(info.height + padding * 2))
                if curX + w > atlasW { curX = 0; curY += rowH; rowH = 0 }
                if curY + h > remainH { fits = false; break }
                curX += w
                rowH = max(rowH, h)
            }

            // Cluster labels themselves must fit
            if clusterH > atlasH { fits = false }

            if fits { break }

            if atlasW <= atlasH && atlasW < maxDim {
                atlasW *= 2
            } else if atlasH < maxDim {
                atlasH *= 2
            } else {
                break  // Max size — node labels will be truncated, cluster labels still fit
            }
        }

        // --- Render to CGContext ---
        let bitsPerComponent = 8
        let bytesPerRow = atlasW * 4
        guard let context = CGContext(
            data: nil,
            width: atlasW,
            height: atlasH,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.clear(CGRect(x: 0, y: 0, width: atlasW, height: atlasH))

        func drawLine(_ line: CTLine, x: CGFloat, y: CGFloat, scale: CGFloat) {
            context.saveGState()
            context.translateBy(x: x, y: y)
            context.scaleBy(x: scale, y: scale)
            context.textMatrix = .identity
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }

        let uvW = Float(atlasW)
        let uvH = Float(atlasH)

        // Helper to pack + draw a set of cluster labels, returning (rectMap, nextY)
        func drawClusterLabels(
            _ labels: [ClusterLabel], startY: Int
        ) -> (rects: [String: (u0: Float, v0: Float, u1: Float, v1: Float)], endY: Int) {
            var rectMap: [String: (u0: Float, v0: Float, u1: Float, v1: Float)] = [:]
            var curX: Int = 0, curY: Int = startY, rowH: Int = 0
            for label in labels {
                let w = Int(ceil(label.width + padding * 2))
                let h = Int(ceil(label.height + padding * 2))
                if curX + w > atlasW { curX = 0; curY += rowH; rowH = 0 }
                guard curY + h <= atlasH else { break }

                let drawX = CGFloat(curX) + padding
                let drawY = CGFloat(atlasH - curY) - label.ascent - padding
                drawLine(label.line, x: drawX, y: drawY, scale: label.rasterScale)

                let u0 = Float(curX) / uvW
                let v0 = Float(atlasH - curY - h) / uvH
                let u1 = Float(curX + w) / uvW
                let v1 = Float(atlasH - curY) / uvH
                rectMap[label.key] = (u0, v0, u1, v1)

                curX += w
                rowH = max(rowH, h)
            }
            return (rectMap, curY + rowH)
        }

        // 1. Pack project labels first (highest priority)
        let (projRectMap, afterProjY) = drawClusterLabels(projLabels, startY: 0)

        // 2. Pack topic labels next
        let (topicRectMap, afterTopicY) = drawClusterLabels(topicLabels, startY: afterProjY)

        // 3. Pack node labels in remaining space
        var nodeRectMap: [UUID: (u0: Float, v0: Float, u1: Float, v1: Float)] = [:]
        var curX: Int = 0
        var curY: Int = afterTopicY
        var rowH: Int = 0

        for info in labelInfos {
            let w = Int(ceil(info.width + padding * 2))
            let h = Int(ceil(info.height + padding * 2))

            if curX + w > atlasW { curX = 0; curY += rowH; rowH = 0 }
            guard curY + h <= atlasH else { continue }

            let drawX = CGFloat(curX) + padding
            let drawY = CGFloat(atlasH - curY) - info.ascent - padding
            drawLine(info.line, x: drawX, y: drawY, scale: info.rasterScale)

            let u0 = Float(curX) / uvW
            let v0 = Float(atlasH - curY - h) / uvH
            let u1 = Float(curX + w) / uvW
            let v1 = Float(atlasH - curY) / uvH
            nodeRectMap[info.entry.id] = (u0, v0, u1, v1)

            curX += w
            rowH = max(rowH, h)
        }
        // Create TextureResource from CGContext's CGImage
        guard let image = context.makeImage() else { return false }

        do {
            let texture = try TextureResource(image: image, options: .init(semantic: .raw))
            // Publish matching UVs, dimensions and cache inputs only with the
            // successful texture. A failed rebuild leaves the prior atlas coherent.
            self.atlasTexture = texture
            self.projectRects = projRectMap; self.topicRects = topicRectMap
            self.nodeRects = nodeRectMap
            self.aspectCorrection = Float(atlasW) / Float(atlasH)
            cachedEntries = entries; cachedProjects = projects; cachedTopics = topics
            diagnosticAtlasCreations &+= 1
            return true
        } catch {
            return false
        }
    }
}

/// Internal atlas entry for label generation.
struct AtlasEntry: Equatable {
    let id: UUID
    let label: String
    let isHub: Bool
}
