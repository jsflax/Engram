import Foundation
import Lattice
import MCP

extension MemoryTools {
    struct DerivationSnapshot: Equatable {
        struct Source: Equatable {
            let id: UUID?
            let store: URL
            let content: String
            let topic: String
            let project: String
            let isPrivate: Bool
            let author: UUID?
            let modifiedAt: Date?
            let audience: Set<String>
        }

        let sources: [Source]
        let destination: Set<String>
    }

    struct DerivationScopeError: Error {
        let message: String

        var result: CallTool.Result {
            CallTool.Result(content: [.text("Derivation scope refused: \(message)")], isError: true)
        }
    }

    /// Re-fetch after an embedding await: another tool may have changed privacy,
    /// exposure, membership or tombstones while this actor was suspended.
    func derivationSources(_ ids: [UUID]) throws -> [(memory: Memory, lattice: Lattice)] {
        try ids.map { id in
            guard let source = findMemory(id: id), source.memory.deletedAt == nil else {
                throw DerivationScopeError(message: "A source is missing or tombstoned. Choose live sources and retry.")
            }
            return source
        }
    }

    /// Immutable values, not live model references: reclassifying or replacing a
    /// source while embedding must not publish a summary of its older content.
    func derivationSnapshot(
        sources: [(memory: Memory, lattice: Lattice)], project: String,
        destinationLattice: Lattice? = nil
    ) throws -> DerivationSnapshot {
        let spokes = liveGroupSpokes()
        // Existing rows may be updated directly in a group spoke. Its actual
        // audience is authoritative even if a local project has the same name.
        let destination: Set<String>
        if let destinationLattice, let spoke = spokes.first(where: {
            $0.lattice.configuration.fileURL.standardizedFileURL == destinationLattice.configuration.fileURL.standardizedFileURL
        }) {
            destination = [spoke.groupId.uuidString]
        } else {
            destination = try derivationProjectAudience(project)
        }
        return try DerivationSnapshot(sources: sources.map { source in
            let store = source.lattice.configuration.fileURL.standardizedFileURL
            let audience: Set<String>
            if source.memory.isPrivate {
                audience = []
            } else if let spoke = spokes.first(where: { $0.lattice.configuration.fileURL.standardizedFileURL == store }) {
                // A teammate's project name need not match ours. The actual
                // spoke defines its audience, not a local project's name.
                audience = [spoke.groupId.uuidString]
            } else {
                audience = try derivationProjectAudience(source.memory.project)
            }
            return DerivationSnapshot.Source(
                id: source.memory.globalId, store: store,
                content: source.memory.content, topic: source.memory.topic, project: source.memory.project,
                isPrivate: source.memory.isPrivate, author: source.memory.authorUserId,
                modifiedAt: source.memory.modifiedAt, audience: audience
            )
        }, destination: destination)
    }

    /// Returns the privacy inherited by a derived row. This checks the audience
    /// represented by today's store/exposure configuration; it does not invent a
    /// per-memory ACL or authorize later project re-exposure.
    func derivationPrivacy(
        sources: [(memory: Memory, lattice: Lattice)],
        project: String,
        destinationLattice: Lattice? = nil,
        updatesSourceLabels: Bool = false,
        unchangedFrom initial: DerivationSnapshot? = nil
    ) throws -> Bool {
        let snapshot = try derivationSnapshot(sources: sources, project: project, destinationLattice: destinationLattice)
        if let initial, snapshot != initial {
            throw DerivationScopeError(message: "Source content or sharing scope changed while deriving. Re-read the sources and retry.")
        }
        let hasPrivate = snapshot.sources.contains { $0.isPrivate }
        let hasPublic = snapshot.sources.contains { !$0.isPrivate }
        if !hasPublic { return hasPrivate }

        let destination = snapshot.destination
        let audiences = snapshot.sources.map(\.audience)
        let hasSharedSource = audiences.contains { !$0.isEmpty }

        if hasPrivate {
            // Organize also writes its derived label onto every original. A
            // private hub alone cannot protect a label copied onto public rows.
            guard !updatesSourceLabels, !hasSharedSource, destination.isEmpty else {
                throw DerivationScopeError(message: "Private and non-private sources cannot be combined in shared work or used to relabel non-private originals. Derive them separately.")
            }
            return true
        }

        if hasSharedSource, let first = audiences.first,
           audiences.contains(where: { $0 != first }) {
            throw DerivationScopeError(message: "Sources have different group audiences. Derive each scope separately.")
        }
        guard audiences.allSatisfy({ destination.isSubset(of: $0) }) else {
            throw DerivationScopeError(message: "The destination project would share source material with another group. Choose a destination within the source audience.")
        }
        return false
    }

    private func derivationProjectAudience(_ project: String) throws -> Set<String> {
        let configs = localLattice.objects(SyncConfig.self).where({ $0.project == project }).snapshot(limit: 2)
        guard localLattice.lastQueryError() == nil, configs.count <= 1 else {
            throw DerivationScopeError(message: "Could not determine the project's sharing scope. Restore access to its policy before deriving.")
        }
        guard let config = configs.first else { return [] }
        // Group exposure is exact-project only; _default governs personal sync.
        // Preserve legacy non-UUID identifiers while normalizing UUID casing.
        return Set(config.exposedGroups.map { UUID(uuidString: $0)?.uuidString ?? $0 })
    }
}
