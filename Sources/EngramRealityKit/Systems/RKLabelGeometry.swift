import Foundation
import simd

/// Shared billboard dimensions for rendering and explicit compact-graph fitting.
/// The desktop galaxy keeps its existing dimensions; compact graphs opt in.
public enum RKLabelGeometry {
    public enum Kind: Sendable { case node, hub, project, topic }

    public static func halfHeight(for kind: Kind, compact: Bool) -> Float {
        switch kind {
        case .node: return 2
        case .hub: return 2.5
        case .project: return compact ? 4 : 14
        case .topic: return compact ? 3 : 8
        }
    }

    public static func halfExtents(for kind: Kind, aspect: Float, compact: Bool,
                                   scaleFactor: Float = 1) -> SIMD2<Float> {
        let height = halfHeight(for: kind, compact: compact) * (compact ? scaleFactor : 1)
        return SIMD2(height * aspect, height)
    }

}

/// Numeric dimensions of exactly the labels admitted to a published atlas. The existing
/// detached atlas worker measures text once; camera fitting never runs CoreText.
public struct RKLabelLayout: Sendable {
    private let input: AtlasRequest
    public let nodeAspects: [UUID: Float]
    public let projectAspects: [String: Float]
    public let topicAspects: [String: Float]

    init(input: AtlasRequest, nodeRects: [UUID: AtlasRect], projectRects: [String: AtlasRect],
         topicRects: [String: AtlasRect], aspectCorrection: Float) {
        self.input = input
        func aspect(_ rect: AtlasRect) -> Float {
            (rect.u1 - rect.u0) / max(rect.v1 - rect.v0, 0.001) * aspectCorrection
        }
        nodeAspects = nodeRects.mapValues(aspect)
        projectAspects = projectRects.mapValues(aspect)
        topicAspects = topicRects.mapValues(aspect)
    }

    public func matches(nodes: [RKNodeSnapshot], hubs: Set<UUID>, projects: Set<String>, topics: Set<String>) -> Bool {
        input == AtlasRequest(nodes: nodes, hubs: hubs, projects: projects, topics: topics)
    }
}
