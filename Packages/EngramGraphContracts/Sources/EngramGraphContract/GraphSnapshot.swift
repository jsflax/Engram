import Foundation

/// Portable values for an already-authorized project graph. These identifiers select data; none is
/// an authentication credential or permission to read it. The exporting service must authorize the
/// exact workspace/project and filter private, expired and deleted rows before making a snapshot.
public struct EngramGraphScope: Codable, Equatable, Sendable {
    public let workspaceID: String
    public let project: String
    /// Empty means every topic in this project. Canonical ordering makes scope equality deterministic.
    public let topics: [String]

    public init(workspaceID: String, project: String, topics: [String] = []) throws {
        try GraphValueValidation.text(workspaceID, maximum: 256, allowEmpty: false)
        try GraphValueValidation.text(project, maximum: 256, allowEmpty: false)
        guard topics.count <= 32 else { throw EngramGraphError.capacity }
        for topic in topics { try GraphValueValidation.text(topic, maximum: 256, allowEmpty: false) }
        guard Set(topics).count == topics.count else { throw EngramGraphError.duplicateIdentity }
        self.workspaceID = workspaceID; self.project = project; self.topics = topics.sorted()
    }

    private enum CodingKeys: String, CodingKey { case workspaceID, project, topics }
    public init(from decoder: any Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(workspaceID: value.decode(String.self, forKey: .workspaceID),
                      project: value.decode(String.self, forKey: .project),
                      topics: GraphValueValidation.array(String.self, in: value, key: .topics, maximum: 32))
    }
}

public enum EngramGraphError: Error, Equatable, Sendable {
    case unsupportedVersion, invalidText, invalidNumber, capacity, duplicateIdentity
    case outOfScope, missingEndpoint, invalidRevision
}

public enum EngramGraphLimits {
    public static let maximumNodes = 2_000
    public static let maximumEdges = 8_000
    public static let maximumTextBytes = 4 * 1024 * 1024
    /// Applies before JSON decoding. The bounded semantic values are checked independently afterward.
    public static let maximumEncodedBytes = 8 * 1024 * 1024
    /// Revisions cross the Foundation/native connector boundary as exactly representable JSON numbers.
    public static let maximumRevision: UInt64 = 9_007_199_254_740_991
}

/// Graph-space coordinates, independent of RealityKit/SIMD. Bounds also keep conversion to Float safe.
public struct EngramGraphPosition: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double
    public init(x: Double, y: Double, z: Double) throws {
        guard [x, y, z].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else {
            throw EngramGraphError.invalidNumber
        }
        self.x = x; self.y = y; self.z = z
    }
    private enum CodingKeys: String, CodingKey { case x, y, z }
    public init(from decoder: any Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(x: value.decode(Double.self, forKey: .x), y: value.decode(Double.self, forKey: .y),
                      z: value.decode(Double.self, forKey: .z))
    }
}

/// The export omits embeddings, provenance paths, author credentials, privacy flags and live models.
/// Node text has already passed service authorization; the view cannot request a wider scope itself.
public struct EngramGraphNode: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let project: String
    public let topic: String
    public let label: String
    public let content: String
    /// True when content is an explicit preview; hosts must not present it as the full memory.
    public let contentIsExcerpt: Bool
    public let importance: Int
    public let isHub: Bool
    /// nil uses the viewer's existing scoped layout. Storage exports need not invent coordinates.
    public let position: EngramGraphPosition?
    public let createdAt: Date
    public let lastAccessedAt: Date

    public init(id: UUID, project: String, topic: String, label: String, content: String = "", contentIsExcerpt: Bool = false,
                importance: Int, isHub: Bool, position: EngramGraphPosition? = nil,
                createdAt: Date = .distantPast, lastAccessedAt: Date = .distantPast) {
        self.id = id; self.project = project; self.topic = topic; self.label = label; self.content = content
        self.contentIsExcerpt = contentIsExcerpt
        self.importance = importance; self.isHub = isHub; self.position = position
        self.createdAt = createdAt; self.lastAccessedAt = lastAccessedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, project, topic, label, content, contentIsExcerpt, importance, isHub, position, createdAt, lastAccessedAt
    }
    public init(from decoder: any Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try value.decode(UUID.self, forKey: .id),
                  project: try value.decode(String.self, forKey: .project),
                  topic: try value.decode(String.self, forKey: .topic),
                  label: try value.decode(String.self, forKey: .label),
                  content: try value.decode(String.self, forKey: .content),
                  contentIsExcerpt: try value.decodeIfPresent(Bool.self, forKey: .contentIsExcerpt) ?? false,
                  importance: try value.decode(Int.self, forKey: .importance),
                  isHub: try value.decode(Bool.self, forKey: .isHub),
                  position: try value.decodeIfPresent(EngramGraphPosition.self, forKey: .position),
                  createdAt: try value.decode(Date.self, forKey: .createdAt),
                  lastAccessedAt: try value.decode(Date.self, forKey: .lastAccessedAt))
    }
}

public struct EngramGraphEdge: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourceID: UUID
    public let targetID: UUID
    public let relation: String
    public init(id: UUID, sourceID: UUID, targetID: UUID, relation: String) {
        self.id = id; self.sourceID = sourceID; self.targetID = targetID; self.relation = relation
    }
}

/// One finished, internally consistent export. A limit-reached snapshot is a deliberately bounded
/// result, not an in-progress page; the UI must show its limit. Loading/failure never substitutes an
/// empty snapshot. Preserve the last authorized snapshot until a newer finished generation arrives.
///
/// Construction validates values, not authorization or transaction consistency. The exporting
/// service supplies those guarantees; hosts additionally compare scope and connection identity.
public struct EngramGraphSnapshot: Codable, Equatable, Sendable {
    public enum Completeness: String, Codable, Sendable { case complete, limitReached }
    public static let schemaVersion = 1
    public let scope: EngramGraphScope
    public let revision: UInt64
    public let completeness: Completeness
    public let nodes: [EngramGraphNode]
    public let edges: [EngramGraphEdge]

    public init(scope: EngramGraphScope, revision: UInt64, completeness: Completeness,
                nodes: [EngramGraphNode], edges: [EngramGraphEdge]) throws {
        guard revision <= EngramGraphLimits.maximumRevision else { throw EngramGraphError.invalidRevision }
        guard nodes.count <= EngramGraphLimits.maximumNodes, edges.count <= EngramGraphLimits.maximumEdges else {
            throw EngramGraphError.capacity
        }
        let nodeIDs = Set(nodes.map(\.id)), edgeIDs = Set(edges.map(\.id)), topics = Set(scope.topics)
        guard nodeIDs.count == nodes.count, edgeIDs.count == edges.count else { throw EngramGraphError.duplicateIdentity }
        var textBytes = 0
        func text(_ value: String, maximum: Int, allowEmpty: Bool = true) throws {
            try GraphValueValidation.text(value, maximum: maximum, allowEmpty: allowEmpty)
            textBytes += value.utf8.count
            guard textBytes <= EngramGraphLimits.maximumTextBytes else { throw EngramGraphError.capacity }
        }
        for node in nodes {
            guard node.project == scope.project, topics.isEmpty || topics.contains(node.topic) else {
                throw EngramGraphError.outOfScope
            }
            try text(node.project, maximum: 256, allowEmpty: false)
            try text(node.topic, maximum: 256, allowEmpty: false)
            try text(node.label, maximum: 512, allowEmpty: false)
            try text(node.content, maximum: 16 * 1024)
            guard (0...5).contains(node.importance), node.createdAt.timeIntervalSince1970.isFinite,
                  node.lastAccessedAt.timeIntervalSince1970.isFinite else { throw EngramGraphError.invalidNumber }
        }
        for edge in edges {
            guard nodeIDs.contains(edge.sourceID), nodeIDs.contains(edge.targetID) else { throw EngramGraphError.missingEndpoint }
            try text(edge.relation, maximum: 128, allowEmpty: false)
        }
        self.scope = scope; self.revision = revision; self.completeness = completeness
        self.nodes = nodes; self.edges = edges
    }

    /// Use at a transport boundary instead of directly decoding unbounded bytes. A caller with its
    /// own decoder must enforce this byte ceiling before invoking Codable too.
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= EngramGraphLimits.maximumEncodedBytes else { throw EngramGraphError.capacity }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= EngramGraphLimits.maximumEncodedBytes else { throw EngramGraphError.capacity }
        return data
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, scope, revision, completeness, nodes, edges }
    public init(from decoder: any Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        guard try value.decode(Int.self, forKey: .schemaVersion) == Self.schemaVersion else {
            throw EngramGraphError.unsupportedVersion
        }
        try self.init(scope: value.decode(EngramGraphScope.self, forKey: .scope),
                      revision: value.decode(UInt64.self, forKey: .revision),
                      completeness: value.decode(Completeness.self, forKey: .completeness),
                      nodes: GraphValueValidation.array(EngramGraphNode.self, in: value, key: .nodes,
                                                       maximum: EngramGraphLimits.maximumNodes),
                      edges: GraphValueValidation.array(EngramGraphEdge.self, in: value, key: .edges,
                                                       maximum: EngramGraphLimits.maximumEdges))
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.container(keyedBy: CodingKeys.self)
        try value.encode(Self.schemaVersion, forKey: .schemaVersion)
        try value.encode(scope, forKey: .scope); try value.encode(revision, forKey: .revision)
        try value.encode(completeness, forKey: .completeness)
        try value.encode(nodes, forKey: .nodes); try value.encode(edges, forKey: .edges)
    }
}

private enum GraphValueValidation {
    static func array<Value: Decodable, Key: CodingKey>(_ type: Value.Type,
        in container: KeyedDecodingContainer<Key>, key: Key, maximum: Int) throws -> [Value] {
        var values = try container.nestedUnkeyedContainer(forKey: key)
        if let count = values.count, count > maximum { throw EngramGraphError.capacity }
        var result: [Value] = []
        while !values.isAtEnd {
            guard result.count < maximum else { throw EngramGraphError.capacity }
            result.append(try values.decode(type))
        }
        return result
    }

    static func text(_ value: String, maximum: Int, allowEmpty: Bool) throws {
        guard value.utf8.count <= maximum, !value.utf8.contains(0),
              allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EngramGraphError.invalidText
        }
    }
}
