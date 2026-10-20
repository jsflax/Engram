import EngramModels
import EngramLattice
import Lattice
import Foundation

// MARK: - Historical Schema Models

/// Namespace for v1 schema models. Do NOT use for new code.
public enum V1 {
    /// Edge model from schema v1: used Int64 primaryKey references.
    @Model
    public final class Edge {
        public var sourceId: Int64
        public var targetId: Int64
        public var relation: String
        public var createdAt: Date

        public init(sourceId: Int64 = 0, targetId: Int64 = 0, relation: String = "", createdAt: Date = Date()) {
            self.sourceId = sourceId
            self.targetId = targetId
            self.relation = relation
            self.createdAt = createdAt
        }
    }
}

// MARK: - Schema Version Constants

/// Current schema version. Bump this when adding new migrations.
///
/// v3 (Groups): `Memory.{authorUserId, deletedAt, deletedBy, modifiedAt}`,
/// `Edge.{authorUserId, deletedAt}`, and the group-DB-only `GroupProjectMap`
/// model. All additions are nullable columns handled by Lattice's
/// `ensure_swift_tables` — no transform block needed (the v1→v2 entry below
/// shows the transform pattern when one IS needed). The stored
/// `SyncConfig.exposedTeams` column name is deliberately KEPT (renaming
/// would skew the personal-sync wire format across the user's own app
/// versions); new code uses the `exposedGroups` computed alias.
/// v4 adds durable pending embeddings without losing legacy rows.
public let currentSchemaVersion = AgentMemorySchema.currentVersion

// MARK: - Migration Definitions

/// Migration from v1 → v2: Edge sourceId/targetId (Int64) → sourceGlobalId/targetGlobalId (UUID).
///
/// For each old Edge row:
/// 1. Look up the Memory with primaryKey == old.sourceId to get its globalId
/// 2. Look up the Memory with primaryKey == old.targetId to get its globalId
/// 3. Set sourceGlobalId and targetGlobalId on the new Edge
/// 4. Convert string relation to Edge.Relation enum (unchanged storage, just typed)
///
/// Orphan edges (where the referenced Memory no longer exists) are assigned UUID.zero
/// as a sentinel — callers should clean these up after migration.
nonisolated(unsafe) public let engramMigrations: [Int: Migration] = [
    2: Migration(
        (from: V1.Edge.self, to: EngramModels.Edge.self),
        blocks: { (old: V1.Edge, new: EngramModels.Edge) in
            // Look up source memory by old Int64 primary key
            if let sourceMem = Migration.lookup(Memory.self, id: old.sourceId),
               let sourceGlobalId = sourceMem.globalId {
                new.sourceGlobalId = sourceGlobalId
            } else {
                // Orphan edge — source memory was deleted
                new.sourceGlobalId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            }

            // Look up target memory by old Int64 primary key
            if let targetMem = Migration.lookup(Memory.self, id: old.targetId),
               let targetGlobalId = targetMem.globalId {
                new.targetGlobalId = targetGlobalId
            } else {
                // Orphan edge — target memory was deleted
                new.targetGlobalId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            }

            // Convert string relation to enum (raw values match)
            new.relation = EngramModels.Edge.Relation(rawValue: old.relation) ?? .relatesTo

            // Preserve creation timestamp
            new.createdAt = old.createdAt
        }
    )
].merging(AgentMemorySchema.migrations) { _, portable in portable }
