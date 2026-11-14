import Foundation
import Testing
import EngramGraphContract

struct GraphSnapshotTests {
    private func scope(topics: [String] = []) throws -> EngramGraphScope {
        try .init(workspaceID: "personal", project: "hud", topics: topics)
    }
    private func node(id: UUID = UUID(), project: String = "hud", topic: String = "design",
                      label: String = "Native surface", content: String = "", importance: Int = 3) throws -> EngramGraphNode {
        .init(id: id, project: project, topic: topic, label: label, content: content, importance: importance,
              isHub: false, position: try .init(x: 1, y: 2, z: 3))
    }
    private func snapshot(_ nodes: [EngramGraphNode], edges: [EngramGraphEdge] = [],
                          revision: UInt64 = 1) throws -> EngramGraphSnapshot {
        try .init(scope: scope(), revision: revision, completeness: .complete, nodes: nodes, edges: edges)
    }

    @Test func canonicalScopeAndFinishedLimitedGraphRoundTrip() throws {
        let selected = try scope(topics: ["performance", "design"])
        #expect(selected.topics == ["design", "performance"])
        let first = try node(), second = try node(topic: "performance")
        let edge = EngramGraphEdge(id: UUID(), sourceID: first.id, targetID: second.id, relation: "related_to")
        let value = try EngramGraphSnapshot(scope: selected, revision: 17, completeness: .limitReached,
                                           nodes: [first, second], edges: [edge])
        #expect(try EngramGraphSnapshot.decode(value.encoded()) == value)
        #expect(try EngramGraphSnapshot.decode(value.encoded()).completeness == .limitReached)
        let layoutOwned = EngramGraphNode(id: UUID(), project: "hud", topic: "design",
                                          label: "Existing layout", importance: 3, isHub: false)
        let withoutGeometry = try snapshot([layoutOwned])
        #expect(try EngramGraphSnapshot.decode(withoutGeometry.encoded()) == withoutGeometry)
        #expect(withoutGeometry.nodes[0].position == nil)
    }

    @Test func foreignProjectTopicAndEndpointsCannotEnterSnapshot() throws {
        #expect(throws: EngramGraphError.outOfScope) { try snapshot([node(project: "other")]) }
        #expect(throws: EngramGraphError.outOfScope) {
            try EngramGraphSnapshot(scope: scope(topics: ["performance"]), revision: 1,
                                    completeness: .complete, nodes: [node()], edges: [])
        }
        let own = try node(), foreign = try node()
        #expect(throws: EngramGraphError.missingEndpoint) {
            try snapshot([own], edges: [.init(id: UUID(), sourceID: own.id, targetID: foreign.id, relation: "related_to")])
        }
    }

    @Test func duplicateIDsAndUnsupportedRevisionsAreRejected() throws {
        let own = try node()
        #expect(throws: EngramGraphError.duplicateIdentity) { try snapshot([own, own]) }
        let edge = EngramGraphEdge(id: UUID(), sourceID: own.id, targetID: own.id, relation: "related_to")
        #expect(throws: EngramGraphError.duplicateIdentity) { try snapshot([own], edges: [edge, edge]) }
        #expect(throws: EngramGraphError.duplicateIdentity) { try scope(topics: ["design", "design"]) }
        #expect(throws: EngramGraphError.invalidRevision) { try snapshot([], revision: .max) }
        #expect(try snapshot([], revision: EngramGraphLimits.maximumRevision).nodes.isEmpty)
    }

    @Test func coordinateAndTextBoundsApplyBeforeRendererConversion() throws {
        for number in [Double.nan, .infinity, -.infinity, 1_000_001] {
            #expect(throws: EngramGraphError.invalidNumber) { try EngramGraphPosition(x: number, y: 0, z: 0) }
        }
        #expect(throws: EngramGraphError.invalidText) { try snapshot([node(label: "bad\0label")]) }
        #expect(throws: EngramGraphError.invalidText) { try snapshot([node(content: String(repeating: "a", count: 16 * 1024 + 1))]) }
        #expect(throws: EngramGraphError.invalidNumber) { try snapshot([node(importance: 6)]) }
        #expect(throws: EngramGraphError.invalidText) { try EngramGraphScope(workspaceID: " ", project: "hud") }
    }

    @Test func aggregateCountsAndTextAreBounded() throws {
        let tooMany = try (0...EngramGraphLimits.maximumNodes).map { _ in try node() }
        #expect(throws: EngramGraphError.capacity) { try snapshot(tooMany) }
        let content = String(repeating: "a", count: 16 * 1024)
        let tooMuchText = try (0..<257).map { _ in try node(content: content) }
        #expect(throws: EngramGraphError.capacity) { try snapshot(tooMuchText) }
        #expect(throws: EngramGraphError.capacity) {
            try EngramGraphSnapshot.decode(Data(repeating: 0, count: EngramGraphLimits.maximumEncodedBytes + 1))
        }
    }

    @Test func decodingCannotBypassValidationOrVersion() throws {
        let valid = try snapshot([node()]).encoded()
        let original = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var version = original; version["schemaVersion"] = 2
        #expect(throws: EngramGraphError.unsupportedVersion) {
            try EngramGraphSnapshot.decode(JSONSerialization.data(withJSONObject: version))
        }
        var foreign = original
        var nodes = try #require(original["nodes"] as? [[String: Any]])
        nodes[0]["project"] = "other"
        foreign["nodes"] = nodes
        #expect(throws: EngramGraphError.outOfScope) {
            try EngramGraphSnapshot.decode(JSONSerialization.data(withJSONObject: foreign))
        }
        var excess = original
        excess["nodes"] = Array(repeating: nodes[0], count: EngramGraphLimits.maximumNodes + 1)
        #expect(throws: EngramGraphError.capacity) {
            try EngramGraphSnapshot.decode(JSONSerialization.data(withJSONObject: excess))
        }
    }

    @Test func explicitExcerptRoundTripsAndOlderFullContentDefaultsFalse() throws {
        let row = EngramGraphNode(id: UUID(), project: "hud", topic: "design", label: "Preview",
                                  content: "First part", contentIsExcerpt: true, importance: 1, isHub: false)
        let encoded = try snapshot([row]).encoded()
        #expect(try EngramGraphSnapshot.decode(encoded).nodes.first?.contentIsExcerpt == true)
        var value = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var nodes = try #require(value["nodes"] as? [[String: Any]])
        nodes[0].removeValue(forKey: "contentIsExcerpt")
        value["nodes"] = nodes
        let legacy = try EngramGraphSnapshot.decode(JSONSerialization.data(withJSONObject: value))
        #expect(legacy.nodes.first?.contentIsExcerpt == false)
    }

}
