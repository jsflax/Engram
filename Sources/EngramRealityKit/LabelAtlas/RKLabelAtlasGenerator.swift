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
    /// UV rects for each node label.
    public var nodeRects: [UUID: AtlasRect] { published?.nodeRects ?? [:] }
    /// UV rects for project labels.
    public var projectRects: [String: AtlasRect] { published?.projectRects ?? [:] }
    /// UV rects for topic labels.
    public var topicRects: [String: AtlasRect] { published?.topicRects ?? [:] }
    /// Aspect correction factor.
    public var aspectCorrection: Float { published?.aspectCorrection ?? 1 }
    /// Atlas texture resource for RealityKit materials.
    public var atlasTexture: TextureResource? { published?.texture }
    /// Changes only when a complete texture and its matching coordinates land.
    public private(set) var atlasVersion: UInt64 = 0

    private struct PublishedAtlas {
        let texture: TextureResource
        let nodeRects: [UUID: AtlasRect]
        let projectRects: [String: AtlasRect]
        let topicRects: [String: AtlasRect]
        let aspectCorrection: Float
    }

    private var published: PublishedAtlas?
    private lazy var builds = LabelAtlasBuildQueue(
        rasterize: { request in AtlasRasterizer.render(request) },
        publish: { [weak self] raster in self?.publish(raster) ?? false }
    )

    var needsAtlasRetry: Bool { builds.needsRetry }

    public init(device: MTLDevice) {}

    /// Queue an atlas build without blocking the frame on measurement or drawing.
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
        builds.request(AtlasRequest(nodes: nodes, hubs: hubs, projects: projects, topics: topics))
    }

    public func invalidatePendingAtlas() {
        builds.invalidate()
    }

    public func cancelPendingBuilds() {
        builds.invalidate()
    }

    private func publish(_ raster: AtlasRaster) -> Bool {
        guard let texture = try? TextureResource(image: raster.image, options: .init(semantic: .raw)) else {
            return false
        }
        // No suspension between texture creation and UV publication. Render
        // systems observe either the entire old atlas or the entire new one.
        published = PublishedAtlas(texture: texture, nodeRects: raster.nodeRects,
                                   projectRects: raster.projectRects, topicRects: raster.topicRects,
                                   aspectCorrection: raster.aspectCorrection)
        atlasVersion &+= 1
        return true
    }
}

public typealias AtlasRect = (u0: Float, v0: Float, u1: Float, v1: Float)

struct AtlasRequest: Equatable, Sendable {
    let entries: [AtlasEntry]
    let projects: [String]
    let topics: [String]

    init(nodes: [RKNodeSnapshot], hubs: Set<UUID>, projects: Set<String>, topics: Set<String>) {
        entries = nodes.map {
            AtlasEntry(id: $0.id, label: $0.label, project: $0.project,
                       topic: $0.topic, isHub: hubs.contains($0.id) || $0.isHub)
        }
        self.projects = projects.sorted()
        self.topics = topics.sorted()
    }
}

/// CGImage is immutable after creation; its CGContext and CoreText objects
/// remain worker-local. The image and value dictionaries may cross executors.
struct AtlasRaster: @unchecked Sendable {
    let image: CGImage
    let nodeRects: [UUID: AtlasRect]
    let projectRects: [String: AtlasRect]
    let topicRects: [String: AtlasRect]
    let aspectCorrection: Float
}

enum AtlasRasterizer {
    static func render(_ request: AtlasRequest) -> AtlasRaster? {
        guard !Task.isCancelled else { return nil }
        let entries = request.entries
        // Fonts
        let monoMedium = CTFontCreateWithName("SF Mono" as CFString, 14, nil)
        let monoBold = CTFontCreateWithName("SF Mono" as CFString, 16, nil)
        let projFont = CTFontCreateWithName("SF Mono" as CFString, 36, nil)
        let topicFont = CTFontCreateWithName("SF Mono" as CFString, 24, nil)

        let padding: CGFloat = 4

        // --- Measure project labels ---
        struct ClusterLabel {
            let key: String
            let line: CTLine
            let width: CGFloat
            let height: CGFloat
            let ascent: CGFloat
        }
        var projLabels: [ClusterLabel] = []
        for name in request.projects {
            guard !Task.isCancelled else { return nil }
            let attrs: [NSAttributedString.Key: Any] = [.font: projFont, .foregroundColor: CGColor.white]
            let attrStr = NSAttributedString(string: name.uppercased(), attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrStr)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let w = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            projLabels.append(ClusterLabel(key: name, line: line, width: w + 8, height: ascent + descent + leading, ascent: ascent))
        }

        // --- Measure topic labels ---
        var topicLabels: [ClusterLabel] = []
        for name in request.topics {
            guard !Task.isCancelled else { return nil }
            let attrs: [NSAttributedString.Key: Any] = [.font: topicFont, .foregroundColor: CGColor.white]
            let attrStr = NSAttributedString(string: name, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrStr)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let w = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            topicLabels.append(ClusterLabel(key: name, line: line, width: w + 8, height: ascent + descent + leading, ascent: ascent))
        }

        // --- Measure node labels ---
        var labelInfos: [(entry: AtlasEntry, line: CTLine, width: CGFloat, height: CGFloat, ascent: CGFloat)] = []
        for entry in entries {
            guard !Task.isCancelled else { return nil }
            let font = entry.isHub ? monoBold : monoMedium
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: CGColor.white]
            let attrStr = NSAttributedString(string: entry.label, attributes: attributes)
            let line = CTLineCreateWithAttributedString(attrStr)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let height = ascent + descent + leading
            labelInfos.append((entry, line, width + 8, height + 4, ascent))
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

        let maxDim = 4096
        var atlasW: Int = 512
        var atlasH: Int = 512

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
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: atlasW, height: atlasH))

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
                context.textPosition = CGPoint(x: drawX, y: drawY)
                CTLineDraw(label.line, context)

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
            guard !Task.isCancelled else { return nil }
            let w = Int(ceil(info.width + padding * 2))
            let h = Int(ceil(info.height + padding * 2))

            if curX + w > atlasW { curX = 0; curY += rowH; rowH = 0 }
            guard curY + h <= atlasH else { continue }

            let drawX = CGFloat(curX) + padding
            let drawY = CGFloat(atlasH - curY) - info.ascent - padding
            context.textPosition = CGPoint(x: drawX, y: drawY)
            CTLineDraw(info.line, context)

            let u0 = Float(curX) / uvW
            let v0 = Float(atlasH - curY - h) / uvH
            let u1 = Float(curX + w) / uvW
            let v1 = Float(atlasH - curY) / uvH
            nodeRectMap[info.entry.id] = (u0, v0, u1, v1)

            curX += w
            rowH = max(rowH, h)
        }
        guard !Task.isCancelled, let image = context.makeImage() else { return nil }
        return AtlasRaster(image: image, nodeRects: nodeRectMap,
                           projectRects: projRectMap, topicRects: topicRectMap,
                           aspectCorrection: Float(atlasW) / Float(atlasH))
    }
}

/// Internal atlas entry for label generation.
struct AtlasEntry: Equatable, Sendable {
    let id: UUID
    let label: String
    let project: String
    let topic: String
    let isHub: Bool
}
