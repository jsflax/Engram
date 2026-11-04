import Testing
import Foundation
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
    @Test(arguments: [false, true])
    func compactGeometryMatchesRasterizedLabelBoundsWithoutChangingDesktop(isHub: Bool) async throws {
        let id = UUID(), project = "hud", topic = "native-connectors"
        let text = "Memory label with a long title"
        let node = RKNodeSnapshot(id: id, project: project, topic: topic,
            label: text, importance: 1, isHub: isHub)
        let input = AtlasRequest(nodes: [node], hubs: [], projects: [project], topics: [topic])
        let value = await Task.detached { AtlasRasterizer.render(input) }.value
        let raster = try #require(value)
        let layout = try #require(raster.layout)
        let samples: [(AtlasRect?, Float?, RKLabelGeometry.Kind, Float, Float)] = [
            (raster.nodeRects[id], layout.nodeAspects[id], isHub ? .hub : .node, isHub ? 2.5 : 2, isHub ? 2.5 : 2),
            (raster.projectRects[project], layout.projectAspects[project], .project, 4, 14),
            (raster.topicRects[topic], layout.topicAspects[topic], .topic, 3, 8)
        ]
        for (optionalRect, optionalAspect, kind, compactHeight, desktopHeight) in samples {
            let rect = try #require(optionalRect)
            let actualAspect = (rect.u1 - rect.u0) / (rect.v1 - rect.v0) * raster.aspectCorrection
            let cachedAspect = try #require(optionalAspect)
            #expect(abs(cachedAspect - actualAspect) < 0.0001)
            let compact = RKLabelGeometry.halfExtents(for: kind, aspect: actualAspect, compact: true)
            #expect(abs(compact.x - compactHeight * actualAspect) < 0.0001 && compact.y == compactHeight)
            let desktop = RKLabelGeometry.halfExtents(for: kind, aspect: actualAspect, compact: false)
            #expect(abs(desktop.x - desktopHeight * actualAspect) < 0.0001 && desktop.y == desktopHeight)
            let scaled = RKLabelGeometry.halfExtents(for: kind, aspect: actualAspect, compact: true, scaleFactor: 0.005)
            #expect(abs(scaled.y - compactHeight * 0.005) < 0.0001)
        }
    }

}
