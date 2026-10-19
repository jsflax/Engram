import Foundation
import XCTest
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
    var explicitNodeVersion: UInt64?
    var explicitHubVersion: UInt64?
    var explicitAppendGeneration: UInt64?
    var nodeVersion: UInt64 { explicitNodeVersion ?? topologyVersion }
    var hubVersion: UInt64 { explicitHubVersion ?? topologyVersion }
    var nodeAppendGeneration: UInt64 { explicitAppendGeneration ?? topologyVersion }
    func tick(dt: Float) {}
}

@MainActor
final class FrameLookupInvalidationTests: XCTestCase {
    private func node(_ id: UUID, _ project: String, topic: String = "topic") -> RKNodeSnapshot {
        RKNodeSnapshot(id: id, project: project, topic: topic, label: project,
                       importance: 1, isHub: false)
    }

    private func edge(_ source: UUID, _ target: UUID) -> RKEdgeSnapshot {
        RKEdgeSnapshot(id: UUID(), sourceId: source, targetId: target, relation: "related")
    }

    func testLightColorsRemainLive() {
        let provider = FrameLookupProvider(), lookup = MascotGraphIndex()
        let id = UUID()
        let red = SIMD3<Float>(1, 0, 0), blue = SIMD3<Float>(0, 0, 1)
        provider.nodes = [node(id, "first"), node(id, "duplicate")]
        provider.projectColorMap = ["first": red, "duplicate": blue]
        for _ in 0..<100 {
            XCTAssertTrue(lookup.projectColor(for: id, dataProvider: provider) == red)
            XCTAssertTrue(lookup.indexByID[id] == 0)
        }
        provider.projectColorMap["first"] = blue
        XCTAssertTrue(lookup.projectColor(for: id, dataProvider: provider) == blue)
        provider.projectColorMap.removeValue(forKey: "first")
        XCTAssertTrue(lookup.projectColor(for: id, dataProvider: provider) == SIMD3<Float>(repeating: 0.5))
        XCTAssertTrue(lookup.projectColor(for: UUID(), dataProvider: provider) == SIMD3<Float>(repeating: 0.5))
    }

    func testLightNodeInvalidation() {
        let provider = FrameLookupProvider(), lookup = MascotGraphIndex()
        let first = UUID(), second = UUID()
        let red = SIMD3<Float>(1, 0, 0), blue = SIMD3<Float>(0, 0, 1)
        provider.projectColorMap = ["A": red, "B": blue]
        provider.nodes = [node(first, "A")]
        XCTAssertTrue(lookup.projectColor(for: first, dataProvider: provider) == red)
        provider.nodes.append(node(second, "B"))
        provider.topologyVersion += 1
        XCTAssertTrue(lookup.projectColor(for: second, dataProvider: provider) == blue)
        provider.nodes = [node(second, "B"), node(first, "B")]
        provider.topologyVersion += 1
        XCTAssertTrue(lookup.projectColor(for: first, dataProvider: provider) == blue)
        XCTAssertTrue(lookup.indexByID[first] == 1)
        provider.nodes.removeLast()
        provider.topologyVersion += 1
        XCTAssertTrue(lookup.projectColor(for: first, dataProvider: provider) == SIMD3<Float>(repeating: 0.5))
        let replacement = FrameLookupProvider()
        replacement.nodes = [node(second, "A")]
        replacement.projectColorMap = provider.projectColorMap
        replacement.topologyVersion = provider.topologyVersion
        XCTAssertTrue(lookup.projectColor(for: second, dataProvider: replacement) == red)
    }

    func testSelectedEdgeDeletion() {
        let provider = FrameLookupProvider(), system = RKFlowParticleSystem()
        let selected = UUID(), target = UUID(), other = UUID()
        provider.selectedNode = selected
        provider.positions = [selected: .zero, target: SIMD3(1, 2, 3)]
        provider.edges = [edge(other, target), edge(selected, target)]
        system.update(dataProvider: provider, dt: 0.4)
        XCTAssertTrue(system.connectedEdgeIndices == [1])
        XCTAssertTrue(system.particles.map(\.edgeIndex) == [1])
        provider.edges.removeFirst()
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 0.4)
        XCTAssertTrue(provider.selectedNode == selected)
        XCTAssertTrue(system.connectedEdgeIndices == [0])
        XCTAssertTrue(system.particles.map(\.edgeIndex) == [0])
        XCTAssertTrue(system.particles.first?.targetPos == SIMD3<Float>(1, 2, 3))
        provider.edges.removeAll()
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 0.4)
        XCTAssertTrue(system.connectedEdgeIndices.isEmpty)
        XCTAssertTrue(system.particles.isEmpty)
    }

    func testSelectedEdgeReorderAndReplacement() {
        let provider = FrameLookupProvider(), system = RKFlowParticleSystem()
        let selected = UUID(), a = UUID(), b = UUID()
        provider.selectedNode = selected
        provider.positions = [selected: .zero, a: SIMD3(1, 0, 0), b: SIMD3(2, 0, 0)]
        provider.edges = [edge(selected, a), edge(a, b)]
        system.update(dataProvider: provider, dt: 0.4)
        provider.edges.reverse()
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 0.4)
        XCTAssertTrue(system.connectedEdgeIndices == [1])
        XCTAssertTrue(system.particles.map(\.edgeIndex) == [1])
        provider.edges[1] = edge(b, selected)
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 0.4)
        XCTAssertTrue(system.particles.count == 1)
        XCTAssertTrue(system.particles.first?.sourcePos == SIMD3<Float>.zero)
        XCTAssertTrue(system.particles.first?.targetPos == SIMD3<Float>(2, 0, 0))
    }

    func testStableFlowAndSelectionChange() {
        let provider = FrameLookupProvider(), system = RKFlowParticleSystem()
        let selected = UUID(), target = UUID()
        provider.selectedNode = selected
        provider.positions = [selected: .zero, target: SIMD3(1, 0, 0)]
        provider.edges = [edge(selected, target)]
        system.update(dataProvider: provider, dt: 0.2)
        XCTAssertTrue(system.particles.isEmpty)
        system.update(dataProvider: provider, dt: 0.2)
        XCTAssertTrue(system.particles.count == 1)
        let age = system.particles[0].age
        system.update(dataProvider: provider, dt: 0.1)
        XCTAssertTrue(system.particles.count == 1)
        XCTAssertTrue(system.particles[0].age > age)
        provider.selectedNode = nil
        system.update(dataProvider: provider, dt: 0.1)
        XCTAssertTrue(system.connectedEdgeIndices.isEmpty)
        XCTAssertTrue(system.particles.isEmpty)
        provider.selectedNode = target
        system.update(dataProvider: provider, dt: 0.4)
        XCTAssertTrue(system.particles.first?.sourcePos == SIMD3<Float>(1, 0, 0))
        XCTAssertTrue(system.particles.first?.targetPos == SIMD3<Float>.zero)
    }

    func testFlowProviderCountAndCap() {
        let provider = FrameLookupProvider(), system = RKFlowParticleSystem()
        let selected = UUID(), target = UUID()
        provider.selectedNode = selected
        provider.positions = [selected: .zero, target: SIMD3(1, 0, 0)]
        provider.edges = (0..<40).map { _ in edge(selected, target) }
        system.update(dataProvider: provider, dt: 0.4)
        XCTAssertTrue(system.connectedEdgeIndices == Array(0..<30))
        XCTAssertTrue(system.particles.count == 30)
        provider.edges = [provider.edges[0]] // Defensive count guard, even without a revision.
        system.update(dataProvider: provider, dt: 0.4)
        XCTAssertTrue(system.connectedEdgeIndices == [0])
        XCTAssertTrue(system.particles.count == 1)
        provider.edges.append(edge(target, selected))
        provider.topologyVersion += 1
        system.update(dataProvider: provider, dt: 0.4)
        XCTAssertTrue(system.connectedEdgeIndices == [0, 1])
        XCTAssertTrue(system.particles.count == 2)
        let replacement = FrameLookupProvider()
        replacement.selectedNode = selected
        replacement.positions = provider.positions
        replacement.edges = [edge(target, UUID()), edge(target, UUID())]
        replacement.topologyVersion = provider.topologyVersion
        system.update(dataProvider: replacement, dt: 0.4)
        XCTAssertTrue(system.connectedEdgeIndices.isEmpty)
        XCTAssertTrue(system.particles.isEmpty)
    }

    func testLabelMembershipSeparatesDomainsAndExtendsAppendPrefix() {
        let provider = FrameLookupProvider()
        var cache = LabelProjectTopicCache()
        let first = UUID(), second = UUID(), third = UUID()
        provider.explicitNodeVersion = 1
        provider.explicitHubVersion = 1
        provider.explicitAppendGeneration = 1
        provider.nodes = [node(first, "First")]
        let initial = cache.update(provider)
        XCTAssertTrue(initial.projects == Set(["First"]))
        XCTAssertTrue(initial.topics == Set(["topic"]))
        cache.rescanPositions(nodes: provider.nodes, positionArray: [SIMD3(0, 8, 0)], positions: [:])
        let originalTopic = cache.topic(at: 0)
        let visited = cache.nodesVisited, revision = cache.revision

        provider.edges = [edge(first, second)]
        provider.topologyVersion += 1
        provider.hubs = [first]
        provider.explicitHubVersion = 2
        let independent = cache.update(provider)
        XCTAssertTrue(independent.projects == initial.projects)
        XCTAssertTrue(independent.topics == initial.topics)
        XCTAssertTrue(cache.nodesVisited == visited)
        XCTAssertTrue(cache.revision == revision)

        // Two producer publications may arrive before this consumer updates.
        provider.nodes.append(RKNodeSnapshot(id: second, project: "Second", topic: "new topic",
                                            label: "Second", importance: 1, isHub: false))
        provider.explicitNodeVersion = 2
        provider.nodes.append(node(third, "Third"))
        provider.explicitNodeVersion = 3
        let appended = cache.update(provider)
        XCTAssertTrue(appended.projects == Set(["First", "Second", "Third"]))
        XCTAssertTrue(appended.topics == Set(["topic", "new topic"]))
        XCTAssertTrue(initial.projects == Set(["First"]))
        XCTAssertTrue(cache.nodesVisited - visited == 2)
        XCTAssertTrue(cache.revision > revision)
        cache.rescanPositions(nodes: provider.nodes,
                              positionArray: [SIMD3(0, -2, 0), SIMD3(0, 10, 0), SIMD3(0, -4, 0)],
                              positions: [:])
        XCTAssertTrue(cache.maxY(forProject: "First") == -2)
        XCTAssertTrue(cache.maxY(forProject: "Second") == 10)
        XCTAssertTrue(cache.maxY(forProject: "Third") == -4)
        XCTAssertTrue(cache.topicCount == 2)
        XCTAssertTrue(cache.topic(at: 0)?.name == "topic")
        XCTAssertTrue(cache.topic(at: 0)?.sum == SIMD3<Float>(0, -6, 0))
        XCTAssertTrue(cache.topic(at: 0)?.count == 2)
        XCTAssertTrue(cache.topic(at: 0)?.project == "Third")
        XCTAssertTrue(cache.topic(at: 1)?.name == "new topic")
        XCTAssertTrue(cache.topic(at: 1)?.count == 1)
        XCTAssertTrue(originalTopic?.maxY == 8)
    }

    func testLabelMembershipRejectsInvalidContinuity() {
        let provider = FrameLookupProvider()
        var cache = LabelProjectTopicCache()
        let first = UUID(), second = UUID()
        provider.explicitNodeVersion = 1
        provider.explicitAppendGeneration = 1
        provider.nodes = [node(first, "Old"), node(second, "Removed")]
        let initial = cache.update(provider)
        XCTAssertTrue(initial.projects == Set(["Old", "Removed"]))
        cache.rescanPositions(nodes: provider.nodes,
                              positionArray: [SIMD3(0, 10, 0), SIMD3(0, 20, 0)], positions: [:])

        // Same count, different order and metadata: the old set cannot be
        // extended even though the node array did not shrink.
        provider.nodes = [node(second, "Current"), node(first, "Current")]
        provider.explicitNodeVersion = 2
        provider.explicitAppendGeneration = 2
        let edited = cache.update(provider)
        XCTAssertTrue(edited.projects == Set(["Current"]))
        XCTAssertTrue(edited.topics == Set(["topic"]))
        cache.rescanPositions(nodes: provider.nodes,
                              positionArray: [SIMD3(0, 1, 0), SIMD3(0, 2, 0)], positions: [:])
        XCTAssertTrue(cache.maxY(forProject: "Old") == nil)
        XCTAssertTrue(cache.maxY(forProject: "Removed") == nil)
        XCTAssertTrue(cache.maxY(forProject: "Current") == 2)
        XCTAssertTrue(cache.topic(at: 0)?.sum == SIMD3<Float>(0, 3, 0))
        provider.nodes.removeAll()
        provider.explicitNodeVersion = 3
        // Defensive shrink refusal also applies if a producer failed to
        // advance its generation; no stale project/topic survives.
        let emptied = cache.update(provider)
        XCTAssertTrue(emptied.projects.isEmpty)
        XCTAssertTrue(emptied.topics.isEmpty)
        cache.rescanPositions(nodes: [], positionArray: [], positions: [:])
        XCTAssertTrue(cache.topicCount == 0)
        XCTAssertTrue(cache.maxY(forProject: "Current") == nil)

        provider.nodes = [node(first, "Repopulated")]
        provider.explicitNodeVersion = 4
        provider.explicitAppendGeneration = 3
        XCTAssertTrue(cache.update(provider).projects == Set(["Repopulated"]))
        let replacement = FrameLookupProvider()
        replacement.nodes = [RKNodeSnapshot(id: first, project: "Replacement", topic: "replacement topic",
                                             label: "Replacement", importance: 1, isHub: false)]
        replacement.explicitNodeVersion = provider.explicitNodeVersion
        replacement.explicitAppendGeneration = provider.explicitAppendGeneration
        let replaced = cache.update(replacement)
        XCTAssertTrue(replaced.projects == Set(["Replacement"]))
        XCTAssertTrue(replaced.topics == Set(["replacement topic"]))
        cache.rescanPositions(nodes: replacement.nodes, positionArray: [SIMD3(0, -5, 0)], positions: [:])
        XCTAssertTrue(cache.maxY(forProject: "Repopulated") == nil)
        XCTAssertTrue(cache.topicCount == 1)
        XCTAssertTrue(cache.topic(at: 0)?.name == "replacement topic")
        XCTAssertTrue(cache.topic(at: 0)?.project == "Replacement")
        XCTAssertTrue(cache.topic(at: 0)?.maxY == -5)

        // The ordinary conservative provider contract changes generation with
        // topology, so a simultaneous prefix edit and append is fully read.
        let conservative = FrameLookupProvider()
        conservative.nodes = [node(first, "Before")]
        XCTAssertTrue(cache.update(conservative).projects == Set(["Before"]))
        conservative.nodes = [node(first, "After"), node(second, "Appended")]
        conservative.topologyVersion += 1
        let fallback = cache.update(conservative)
        XCTAssertTrue(fallback.projects == Set(["After", "Appended"]))
        XCTAssertTrue(fallback.topics == Set(["topic"]))
    }

    func testLabelNumericRescanFollowsMotion() {
        let provider = FrameLookupProvider()
        var cache = LabelProjectTopicCache()
        provider.nodes = [node(UUID(), "A"), node(UUID(), "B"), node(UUID(), "A", topic: "other")]
        _ = cache.update(provider)
        cache.rescanPositions(nodes: provider.nodes,
                              positionArray: [SIMD3(2, 8, 4), SIMD3(4, 12, 2), SIMD3(0, 3, 0)],
                              positions: [:])
        XCTAssertTrue(cache.maxY(forProject: "A") == 8)
        XCTAssertTrue(cache.maxY(forProject: "B") == 12)
        XCTAssertTrue(cache.topic(at: 0)?.sum == SIMD3<Float>(6, 20, 6))
        XCTAssertTrue(cache.topic(at: 0)?.count == 2)
        XCTAssertTrue(cache.topic(at: 0)?.project == "B")
        XCTAssertTrue(cache.topic(at: 0)?.maxY == 12)
        XCTAssertTrue(cache.topic(at: 1)?.count == 1)
        let visited = cache.nodesVisited, revision = cache.revision

        provider.positionVersion += 1
        _ = cache.update(provider)
        cache.rescanPositions(nodes: provider.nodes,
                              positionArray: [SIMD3(2, -8, 4), SIMD3(4, -12, 2), SIMD3(0, -3, 0)],
                              positions: [:])
        XCTAssertTrue(cache.nodesVisited == visited)
        XCTAssertTrue(cache.revision == revision)
        XCTAssertTrue(cache.maxY(forProject: "A") == -3)
        XCTAssertTrue(cache.maxY(forProject: "B") == -12)
        XCTAssertTrue(cache.topic(at: 0)?.sum == SIMD3<Float>(6, -20, 6))
        XCTAssertTrue(cache.topic(at: 0)?.count == 2)
        XCTAssertTrue(cache.topic(at: 0)?.maxY == -8)
        XCTAssertTrue(cache.topic(at: 1)?.sum == SIMD3<Float>(0, -3, 0))
    }

    func testLabelNumericRescanPreservesMissingPositionSemantics() {
        let provider = FrameLookupProvider()
        var cache = LabelProjectTopicCache()
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        provider.nodes = [node(a, "A"), node(b, "B"), node(c, "C"), node(d, "D", topic: "missing")]
        let membership = cache.update(provider)
        XCTAssertTrue(membership.projects == Set(["A", "B", "C", "D"]))
        cache.rescanPositions(nodes: provider.nodes, positionArray: [.zero],
                              positions: [a: SIMD3(99, 99, 99), b: SIMD3(2, 4, 6)])
        XCTAssertTrue(cache.maxY(forProject: "A") == 0)
        XCTAssertTrue(cache.maxY(forProject: "B") == 4)
        XCTAssertTrue(cache.maxY(forProject: "C") == nil)
        XCTAssertTrue(cache.maxY(forProject: "D") == nil)
        XCTAssertTrue(cache.topic(at: 0)?.sum == SIMD3<Float>(2, 4, 6))
        XCTAssertTrue(cache.topic(at: 0)?.count == 2)
        XCTAssertTrue(cache.topic(at: 0)?.project == "B")
        XCTAssertTrue(cache.topic(at: 1) == nil)

        // The previous last valid node disappears; an absent suffix must not
        // retain its sum, height or color project.
        cache.rescanPositions(nodes: provider.nodes, positionArray: [.zero], positions: [c: SIMD3(3, 6, 9)])
        XCTAssertTrue(cache.maxY(forProject: "B") == nil)
        XCTAssertTrue(cache.topic(at: 0)?.sum == SIMD3<Float>(3, 6, 9))
        XCTAssertTrue(cache.topic(at: 0)?.project == "C")
        XCTAssertTrue(cache.topic(at: 0)?.maxY == 6)

        cache.rescanPositions(nodes: provider.nodes, positionArray: [.zero, .zero, .zero, .zero], positions: [:])
        XCTAssertTrue(cache.topic(at: 0)?.count == 3)
        XCTAssertTrue(cache.topic(at: 0)?.sum == SIMD3<Float>.zero)
        XCTAssertTrue(cache.topic(at: 0)?.project == "C")
        XCTAssertTrue(cache.topic(at: 1)?.count == 1)
        XCTAssertTrue(cache.maxY(forProject: "D") == 0)
        cache.rescanPositions(nodes: provider.nodes, positionArray: [], positions: [:])
        XCTAssertTrue(cache.topicCount == 2) // Atlas membership includes unpositioned nodes.
        XCTAssertTrue(cache.topic(at: 0) == nil)
        XCTAssertTrue(cache.topic(at: 1) == nil)
        XCTAssertTrue(cache.maxY(forProject: "A") == nil)
    }

    func testLabelNumericSlotsFollowReorderAndTopicChanges() {
        let provider = FrameLookupProvider()
        var cache = LabelProjectTopicCache()
        let a = UUID(), b = UUID()
        provider.nodes = [node(a, "A"), node(b, "B")]
        _ = cache.update(provider)
        cache.rescanPositions(nodes: provider.nodes, positionArray: [],
                              positions: [a: SIMD3(1, 2, 3), b: SIMD3(4, 5, 6)])
        XCTAssertTrue(cache.topic(at: 0)?.project == "B")
        provider.nodes.reverse()
        provider.topologyVersion += 1
        _ = cache.update(provider)
        cache.rescanPositions(nodes: provider.nodes, positionArray: [],
                              positions: [a: SIMD3(1, 2, 3), b: SIMD3(4, 5, 6)])
        XCTAssertTrue(cache.topic(at: 0)?.project == "A")
        XCTAssertTrue(cache.topic(at: 0)?.sum == SIMD3<Float>(5, 7, 9))

        provider.nodes = [node(b, "Changed", topic: "new"), node(a, "Changed", topic: "new")]
        provider.topologyVersion += 1
        _ = cache.update(provider)
        cache.rescanPositions(nodes: provider.nodes, positionArray: [],
                              positions: [a: SIMD3(1, -2, 3), b: SIMD3(4, -5, 6)])
        XCTAssertTrue(cache.maxY(forProject: "A") == nil)
        XCTAssertTrue(cache.maxY(forProject: "B") == nil)
        XCTAssertTrue(cache.maxY(forProject: "Changed") == -2)
        XCTAssertTrue(cache.topicCount == 1)
        XCTAssertTrue(cache.topic(at: 0)?.name == "new")
        XCTAssertTrue(cache.topic(at: 0)?.project == "Changed")
        XCTAssertTrue(cache.topic(at: 0)?.sum == SIMD3<Float>(5, -7, 9))
        XCTAssertTrue(cache.topic(at: 0)?.count == 2)
    }
}
