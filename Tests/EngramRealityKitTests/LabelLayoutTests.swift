import Testing
import Foundation
import CoreText
import Metal
import RealityKit
@testable import EngramRealityKit

@Suite("Label Layout Tests")
struct LabelLayoutTests {

    @Test("Pack single rect")
    func packSingleRect() {
        let sizes = [(width: 100, height: 50)]
        let result = packRects(sizes: sizes, atlasWidth: 512, atlasHeight: 512)
        #expect(result.count == 1)
        #expect(result[0] != nil)
        #expect(result[0]!.x == 0)
        #expect(result[0]!.y == 0)
        #expect(result[0]!.width == 100)
        #expect(result[0]!.height == 50)
    }

    @Test("Pack multiple rects in single row")
    func packSingleRow() {
        let sizes = [
            (width: 100, height: 50),
            (width: 150, height: 50),
            (width: 200, height: 50),
        ]
        let result = packRects(sizes: sizes, atlasWidth: 512, atlasHeight: 512)
        #expect(result.allSatisfy { $0 != nil })
        // All should be on the same row (total width = 450 < 512)
        #expect(result[0]!.y == 0)
        #expect(result[1]!.y == 0)
        #expect(result[2]!.y == 0)
        // Sequential x positions
        #expect(result[1]!.x == 100)
        #expect(result[2]!.x == 250)
    }

    @Test("Pack wraps to next row")
    func packWrapsRow() {
        let sizes = [
            (width: 300, height: 50),
            (width: 300, height: 60),
        ]
        let result = packRects(sizes: sizes, atlasWidth: 512, atlasHeight: 512)
        #expect(result.allSatisfy { $0 != nil })
        // Second rect should wrap (300 + 300 > 512)
        #expect(result[0]!.y == 0)
        #expect(result[1]!.y == 50) // row height of first rect
    }

    @Test("Pack skips rects that don't fit vertically")
    func packSkipsOverflow() {
        let sizes = [
            (width: 300, height: 400),
            (width: 300, height: 400), // Won't fit: wraps to row 2, 400 + 400 > 512
        ]
        let result = packRects(sizes: sizes, atlasWidth: 512, atlasHeight: 512)
        #expect(result[0] != nil)
        #expect(result[1] == nil) // second rect at y=400, needs 400 more → 800 > 512
    }

    @Test("Pack empty input")
    func packEmpty() {
        let result = packRects(sizes: [], atlasWidth: 512, atlasHeight: 512)
        #expect(result.isEmpty)
    }

    @Test("Pack many small rects")
    func packManySmall() {
        let sizes = (0..<100).map { _ in (width: 40, height: 20) }
        let result = packRects(sizes: sizes, atlasWidth: 512, atlasHeight: 512)
        // 512 / 40 = 12 per row, 100 / 12 = ~9 rows, 9 * 20 = 180 < 512
        let packed = result.compactMap { $0 }
        #expect(packed.count == 100)
    }
}


extension LabelLayoutTests {
    @Test("Atlas bounds retain the last glyph of long project, topic and node labels",
          arguments: ["project", "topic", "node"], [80, 500])
    @MainActor func longLabelAtlasIncludesFinalGlyph(kind: String, count: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let text = String(repeating: "W", count: count)
        let node = RKNodeSnapshot(id: UUID(), project: "p", topic: "t",
            label: kind == "node" ? text : "short", importance: 1, isHub: false)
        let atlas = RKLabelAtlasGenerator(device: device)
        atlas.regenerateAtlas(nodes: [node], hubs: [],
            projects: kind == "project" ? [text] : [], topics: kind == "topic" ? [text] : [])
        let texture = try #require(atlas.atlasTexture)
        let rect: (u0: Float, v0: Float, u1: Float, v1: Float)
        switch kind {
        case "project": rect = try #require(atlas.projectRects[text])
        case "topic": rect = try #require(atlas.topicRects[text])
        default: rect = try #require(atlas.nodeRects[node.id])
        }
        #expect(texture.width > 512 && texture.width <= 4096)
        #expect(texture.height <= 4096)
        #expect(rect.u0 >= 0 && rect.v0 >= 0 && rect.u1 <= 1 && rect.v1 <= 1)
        // Independent CoreText metrics establish the width of the complete line.
        let fontSize: CGFloat = kind == "project" ? 36 : (kind == "topic" ? 24 : 14)
        let font = CTFontCreateWithName("SF Mono" as CFString, fontSize, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let scale = min(1, 4088 / (lineWidth + 8))
        let packedWidth = CGFloat(rect.u1 - rect.u0) * CGFloat(texture.width)
        #expect(abs(packedWidth - ceil((lineWidth + 8) * scale + 8)) < 0.01)

        // Read the actual uploaded native texture. The final glyph must have
        // nontransparent pixels, not merely a published out-of-bounds UV rect.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat,
            width: texture.width, height: texture.height, mipmapped: texture.mipmapLevelCount > 1)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderWrite
        let readback = try #require(device.makeTexture(descriptor: descriptor))
        try texture.copy(to: readback)
        #expect([MTLPixelFormat.rgba8Unorm, .rgba8Unorm_srgb, .bgra8Unorm, .bgra8Unorm_srgb].contains(readback.pixelFormat))
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            readback.getBytes(buffer.baseAddress!, bytesPerRow: texture.width * 4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        let lastGlyphOffset = CTLineGetOffsetForStringIndex(line, text.utf16.count - 1, nil)
        let startX = Int(floor(CGFloat(rect.u0) * CGFloat(texture.width) + 4 + lastGlyphOffset * scale))
        let endX = min(texture.width, Int(ceil(CGFloat(rect.u0) * CGFloat(texture.width) + 4 + lineWidth * scale)))
        #expect(startX >= 0 && startX < endX)
        let finalGlyphInk = (0..<texture.height).contains { y in
            (startX..<endX).contains { x in bytes[(y * texture.width + x) * 4 + 3] > 0 }
        }
        #expect(finalGlyphInk)
        print("LABEL_ATLAS kind=\(kind) count=\(count) texture=\(texture.width)x\(texture.height) finalGlyph=\(startX)..<\(endX) scale=\(scale)")
    }
}
