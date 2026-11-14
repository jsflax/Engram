import Foundation
import Lattice

/// A sender's sealed graph snapshot. This record travels through Lattice with
/// the graph; it carries hashes/counts, never a second copy of memory content.
/// Transport adapters must allow only the authoritative graph host to insert
/// manifests and must refuse updates/deletes of these rows from replicas.
@Model public final class AgentMemoryTransferManifest {
    public var sourceGraphId: UUID = UUID()
    public var sourceAgentId: UUID = UUID()
    public var formatVersion: Int = 1
    public var schemaVersion: Int = 6
    public var contentDigest: String = ""
    public var tableCountsJSON: String = "{}"
    public var createdAt: Date = Date()
    public init() {}
}
