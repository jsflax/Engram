import Foundation
import Testing
import CEngramSceneTypes
@preconcurrency import Metal
@testable import EngramSceneKit

@Suite("Barnes-Hut tree uploads")
@MainActor
struct BHOctreeUploadCacheTests {
    @Test
    func testOctreeUploadReusesAcceptedTree() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var cache = BHOctreeUploadCache()
        let emptyResult = cache.prepare(device: device)
        #expect(emptyResult == nil)
        #expect(cache.uploadCount == 0)

        let nodes = makeNodes(count: 9, seed: 1)
        cache.replace(with: nodes)
        let firstResult = cache.prepare(device: device)
        let first = try #require(firstResult)
        expectContents(first, nodes: nodes)
        let bytes = Data(bytes: first.contents(), count: nodes.count * MemoryLayout<BHOctreeNode>.stride)
        for _ in 0..<12 {
            let reusedResult = cache.prepare(device: device)
            let reused = try #require(reusedResult)
            #expect(reused === first)
            #expect(Data(bytes: reused.contents(), count: bytes.count) == bytes)
            #expect(cache.uploadCount == 1)
        }
    }

    @Test
    func testOctreeUploadReplacesEqualCountTree() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var cache = BHOctreeUploadCache()
        cache.replace(with: makeNodes(count: 9, seed: 1))
        let firstResult = cache.prepare(device: device)
        let first = try #require(firstResult)

        let replacement = makeNodes(count: 9, seed: 50)
        cache.replace(with: replacement)
        let replacedResult = cache.prepare(device: device)
        let replaced = try #require(replacedResult)
        #expect(replaced === first)
        #expect(cache.uploadCount == 2)
        expectContents(replaced, nodes: replacement)
        _ = cache.prepare(device: device)
        #expect(cache.uploadCount == 2)
    }

    @Test
    func testOctreeUploadGrowsThenShrinks() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var cache = BHOctreeUploadCache()
        cache.replace(with: makeNodes(count: 9, seed: 1))
        let firstResult = cache.prepare(device: device)
        let first = try #require(firstResult)

        let larger = makeNodes(count: first.length / MemoryLayout<BHOctreeNode>.stride + 1, seed: 100)
        cache.replace(with: larger)
        let grownResult = cache.prepare(device: device)
        let grown = try #require(grownResult)
        #expect(grown !== first)
        #expect(grown.length >= larger.count * MemoryLayout<BHOctreeNode>.stride)
        #expect(cache.uploadCount == 2)
        expectContents(grown, nodes: larger)

        let smaller = makeNodes(count: 3, seed: 200)
        cache.replace(with: smaller)
        let shrunkResult = cache.prepare(device: device)
        let shrunk = try #require(shrunkResult)
        #expect(shrunk === grown)
        #expect(cache.nodes?.count == smaller.count)
        #expect(cache.uploadCount == 3)
        expectContents(shrunk, nodes: smaller)
        _ = cache.prepare(device: device)
        #expect(cache.uploadCount == 3)
    }

    private func makeNodes(count: Int, seed: Int) -> [OctreeNode] {
        (0..<count).map { index in
            let value = Float(seed + index)
            var node = OctreeNode.empty(cx: value, cy: -value, cz: value + 0.25, halfSize: value + 0.5)
            node.comX = value + 1
            node.comY = value + 2
            node.comZ = value + 3
            node.mass = value + 4
            for child in 0..<8 {
                node.setChild(child, child.isMultiple(of: 2) ? -1 : Int32((seed + index + child) % count))
            }
            node.bodyIndex = index.isMultiple(of: 2) ? -1 : Int32(seed + index)
            return node
        }
    }

    private func expectContents(_ buffer: MTLBuffer, nodes: [OctreeNode]) {
        let pointer = buffer.contents().bindMemory(to: BHOctreeNode.self, capacity: nodes.count)
        for (index, expected) in nodes.enumerated() {
            let actual = pointer[index]
            #expect([actual.cx, actual.cy, actual.cz, actual.halfSize,
                     actual.comX, actual.comY, actual.comZ, actual.mass] ==
                    [expected.cx, expected.cy, expected.cz, expected.halfSize,
                     expected.comX, expected.comY, expected.comZ, expected.mass])
            #expect([actual.children.0, actual.children.1, actual.children.2, actual.children.3,
                     actual.children.4, actual.children.5, actual.children.6, actual.children.7] ==
                    (0..<8).map { expected.child($0) })
            #expect(actual.bodyIndex == expected.bodyIndex)
            #expect(actual._pad == 0)
        }
    }
}
