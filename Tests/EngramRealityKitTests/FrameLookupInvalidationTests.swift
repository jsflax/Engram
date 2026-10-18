import Foundation
import Testing
@testable import EngramRealityKit

@MainActor
private final class FrameLookupProvider: SceneDataProvider {
    var nodes: [RKNodeSnapshot] = []
    var edges: [RKEdgeSnapshot] = []
    var hubs: Set<UUID> = []
    var projectColorMap: [String: SIMD3<Float>] = [:]
    var positions: [UUID: SIMD3<Float>] = [:]
    var glowingNodes: [UUID: Float] = [:]
    var newNodeGlows: [UUID: Float] = [:]
    var dyingNodes: Set<UUID> = []
    var selectedNode: UUID?
    var expandedHubs: Set<UUID> = []
    var searchMatchIds: Set<UUID> = []
    var isSearchActive = false
    var projectCentroids: [String: SIMD3<Float>] = [:]
    var topologyVersion: UInt64 = 0
    var positionVersion: UInt64 = 0
    func tick(dt: Float) {}
}

@Suite("Frame lookup invalidation")
@MainActor
struct FrameLookupInvalidationTests {
    private func node(_ id: UUID, _ project: String) -> RKNodeSnapshot {
        RKNodeSnapshot(id: id, project: project, topic: "topic", label: project,
                       importance: 1, isHub: false)
    }

    private func edge(_ source: UUID, _ target: UUID) -> RKEdgeSnapshot {
        RKEdgeSnapshot(id: UUID(), sourceId: source, targetId: target, relation: "related")
    }

    @Test("Stable light lookups preserve first-match and live palette behavior")
    func lightColorsRemainLive() {
        let provider = FrameLookupProvider(), lookup = MascotGraphIndex()
        let id = UUID()
        let red = SIMD3<Float>(1, 0, 0), blue = SIMD3<Float>(0, 0, 1)
        provider.nodes = [node(id, "first"), node(id, "duplicate")]
        provider.projectColorMap = ["first": red, "duplicate": blue]
        for _ in 0..<100 {
            #expect(lookup.projectColor(for: id, dataProvider: provider) == red)
            #expect(lookup.indexByID[id] == 0)
        }
        provider.projectColorMap["first"] = blue
        #expect(lookup.projectColor(for: id, dataProvider: provider) == blue)
        provider.projectColorMap.removeValue(forKey: "first")
        #expect(lookup.projectColor(for: id, dataProvider: provider) == SIMD3<Float>(repeating: 0.5))
        #expect(lookup.projectColor(for: UUID(), dataProvider: provider) == SIMD3<Float>(repeating: 0.5))
    }

    @Test("Light lookup follows append, edits, deletion, reorder and provider replacement")
    func lightNodeInvalidation() {
        let provider = FrameLookupProvider(), lookup = MascotGraphIndex()
        let first = UUID(), second = UUID()
        let red = SIMD3<Float>(1, 0, 0), blue = SIMD3<Float>(0, 0, 1)
        provider.projectColorMap = ["A": red, "B": blue]
        provider.nodes = [node(first, "A")]
        #expect(lookup.projectColor(for: first, dataProvider: provider) == red)
        provider.nodes.append(node(second, "B"))
        provider.topologyVersion += 1
        #expect(lookup.projectColor(for: second, dataProvider: provider) == blue)
        provider.nodes = [node(second, "B"), node(first, "B")]
        provider.topologyVersion += 1
        #expect(lookup.projectColor(for: first, dataProvider: provider) == blue)
        #expect(lookup.indexByID[first] == 1)
        provider.nodes.removeLast()
        provider.topologyVersion += 1
        #expect(lookup.projectColor(for: first, dataProvider: provider) == SIMD3<Float>(repeating: 0.5))
        let replacement = FrameLookupProvider()
        replacement.nodes = [node(second, "A")]
        replacement.projectColorMap = provider.projectColorMap
        replacement.topologyVersion = provider.topologyVersion
        #expect(lookup.projectColor(for: second, dataProvider: replacement) == red)
    }

    @Test("Deleting an edge preserves selection and discards obsolete particle offsets")
    func selectedEdgeDeletion() {
        let provider = FrameLookupProvider(), system = RKFlowParticleSystem()
        let selected = UUID(), target = UUID(), other = UUID()
        provider.selectedNode = selected
        provider.positions = [selected: .zero, target: SIMD3(1, 2, 3)]
        provider.edges = [edge(other, target), edge(selected, target)]
        system.update(dataProvider: provider, dt: 0.4)
        #expect(system.connectedEdgeIndices == [1])
        #expect(system.particles.map(\.edgeIndex) == [1])
        provider.edges.removeFirst()
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 0.4)
        #expect(provider.selectedNode == selected)
        #expect(system.connectedEdgeIndices == [0])
        #expect(system.particles.map(\.edgeIndex) == [0])
        #expect(system.particles.first?.targetPos == SIMD3<Float>(1, 2, 3))
        provider.edges.removeAll()
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 0.4)
        #expect(system.connectedEdgeIndices.isEmpty)
        #expect(system.particles.isEmpty)
    }

    @Test("Same-count edge reorder and replacement refresh a retained selection")
    func selectedEdgeReorderAndReplacement() {
        let provider = FrameLookupProvider(), system = RKFlowParticleSystem()
        let selected = UUID(), a = UUID(), b = UUID()
        provider.selectedNode = selected
        provider.positions = [selected: .zero, a: SIMD3(1, 0, 0), b: SIMD3(2, 0, 0)]
        provider.edges = [edge(selected, a), edge(a, b)]
        system.update(dataProvider: provider, dt: 0.4)
        provider.edges.reverse()
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 0.4)
        #expect(system.connectedEdgeIndices == [1])
        #expect(system.particles.map(\.edgeIndex) == [1])
        provider.edges[1] = edge(b, selected)
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 0.4)
        #expect(system.particles.count == 1)
        #expect(system.particles.first?.sourcePos == SIMD3<Float>.zero)
        #expect(system.particles.first?.targetPos == SIMD3<Float>(2, 0, 0))
    }

    @Test("Unchanged frames retain spawn progress and selection changes reset it")
    func stableFlowAndSelectionChange() {
        let provider = FrameLookupProvider(), system = RKFlowParticleSystem()
        let selected = UUID(), target = UUID()
        provider.selectedNode = selected
        provider.positions = [selected: .zero, target: SIMD3(1, 0, 0)]
        provider.edges = [edge(selected, target)]
        system.update(dataProvider: provider, dt: 0.2)
        #expect(system.particles.isEmpty)
        system.update(dataProvider: provider, dt: 0.2)
        #expect(system.particles.count == 1)
        let age = system.particles[0].age
        system.update(dataProvider: provider, dt: 0.1)
        #expect(system.particles.count == 1)
        #expect(system.particles[0].age > age)
        provider.selectedNode = nil
        system.update(dataProvider: provider, dt: 0.1)
        #expect(system.connectedEdgeIndices.isEmpty)
        #expect(system.particles.isEmpty)
        provider.selectedNode = target
        system.update(dataProvider: provider, dt: 0.4)
        #expect(system.particles.first?.sourcePos == SIMD3<Float>(1, 0, 0))
        #expect(system.particles.first?.targetPos == SIMD3<Float>.zero)
    }

    @Test("Provider/count changes invalidate offsets and keep the thirty-edge cap")
    func flowProviderCountAndCap() {
        let provider = FrameLookupProvider(), system = RKFlowParticleSystem()
        let selected = UUID(), target = UUID()
        provider.selectedNode = selected
        provider.positions = [selected: .zero, target: SIMD3(1, 0, 0)]
        provider.edges = (0..<40).map { _ in edge(selected, target) }
        system.update(dataProvider: provider, dt: 0.4)
        #expect(system.connectedEdgeIndices == Array(0..<30))
        #expect(system.particles.count == 30)
        provider.edges = [provider.edges[0]] // Defensive count guard, even without a revision.
        system.update(dataProvider: provider, dt: 0.4)
        #expect(system.connectedEdgeIndices == [0])
        #expect(system.particles.count == 1)
        provider.edges.append(edge(target, selected))
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 0.4)
        #expect(system.connectedEdgeIndices == [0, 1])
        #expect(system.particles.count == 2)
        let replacement = FrameLookupProvider()
        replacement.selectedNode = selected
        replacement.positions = provider.positions
        replacement.edges = [edge(target, UUID()), edge(target, UUID())]
        replacement.topologyVersion = provider.topologyVersion
        system.update(dataProvider: replacement, dt: 0.4)
        #expect(system.connectedEdgeIndices.isEmpty)
        #expect(system.particles.isEmpty)
    }
}
