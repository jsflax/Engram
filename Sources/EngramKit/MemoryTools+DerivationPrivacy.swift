import Foundation
import Lattice
import MCP

extension MemoryTools {
    typealias DerivationSource = (memory: Memory, lattice: Lattice)

    struct DerivationStoreBinding: Equatable {
        let role: String
        let url: URL
        let identity: String
        let group: String?
    }

    struct DerivationInputs {
        // One target per requested UUID, in the existing local/synced/group
        // precedence. Policy copies must never multiply writes or edges.
        let targets: [DerivationSource]
        let copies: [DerivationSource]
        let stores: [DerivationStoreBinding]
    }

    struct DerivationSnapshot: Equatable {
        struct Source: Equatable {
            let id: UUID?
            let store: URL
            let content: String
            let topic: String
            let project: String
            let source: String
            let isPrivate: Bool
            let author: UUID?
            let modifiedAt: Date?
            let audience: Set<String>
        }

        let stores: [DerivationStoreBinding]
        let sources: [Source]
        let destination: Set<String>
    }

    struct DerivationScopeError: Error {
        let message: String

        var result: CallTool.Result {
            CallTool.Result(content: [.text("Derivation scope refused: \(message)")], isError: true)
        }
    }

    /// Capture the complete configured store set, including empty spokes. A
    /// revoked, replaced or ambiguously bound store is not permission to omit it.
    func derivationStores() throws -> [(binding: DerivationStoreBinding, lattice: Lattice)] {
        try validateDerivationStorageCompleteness()
        guard liveGroupSpokes().count == groupSpokes.count else {
            throw DerivationScopeError(message: "A configured group store is unavailable. Restore access before deriving.")
        }
        var stores: [(String, Lattice, String?)] = [("local", localLattice, nil)]
        if let syncedLattice { stores.append(("synced", syncedLattice, nil)) }
        stores.append(contentsOf: groupSpokes.map { ("group:" + $0.groupId.uuidString, $0.lattice, $0.groupId.uuidString) })
        var identities = Set<String>()
        var roles = Set<String>()
        return try stores.map { role, lattice, group in
            let identity: String
            switch lattice.configuration.storage {
            case .memory(let name): identity = "memory:" + name
            case .file(let url):
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      let device = attributes[.systemNumber] as? NSNumber,
                      let inode = attributes[.systemFileNumber] as? NSNumber else {
                    throw DerivationScopeError(message: "A source store is unavailable. Restore access before deriving.")
                }
                identity = "file:" + device.stringValue + ":" + inode.stringValue
            }
            guard identities.insert(identity).inserted, roles.insert(role).inserted else {
                throw DerivationScopeError(message: "A store has ambiguous ownership or group scope. Resolve its binding before deriving.")
            }
            return (DerivationStoreBinding(role: role, url: lattice.configuration.fileURL.standardizedFileURL,
                                           identity: identity, group: group), lattice)
        }
    }

    /// Re-fetch every copy after an embedding await. Materialization pins the
    /// hydrated scalar row image; live property reads could mix different edits.
    /// This is a conservative recheck, not a cross-store transaction or lock.
    func derivationSources(_ ids: [UUID]) throws -> DerivationInputs {
        guard !ids.isEmpty, ids.count <= 4096, Set(ids).count == ids.count else {
            throw DerivationScopeError(message: "Choose between 1 and 4096 distinct live source IDs.")
        }
        let stores = try derivationStores()
        var targets: [DerivationSource] = []
        var copies: [DerivationSource] = []
        for id in ids {
            var replicas: [DerivationSource] = []
            for (_, store) in stores {
                let rows = store.objects(Memory.self).where({ $0.globalId == id }).snapshot(limit: 2)
                guard store.lastQueryError() == nil, rows.count <= 1 else {
                    throw DerivationScopeError(message: "Could not read every source copy. Restore access before deriving.")
                }
                if let memory = rows.first?.materialize() {
                    guard memory.deletedAt == nil else {
                        throw DerivationScopeError(message: "A source copy is tombstoned. Have its author undelete it or choose other live sources.")
                    }
                    replicas.append((memory, store))
                }
            }
            guard let first = replicas.first else {
                throw DerivationScopeError(message: "A source was not found. Restore it before deriving.")
            }
            // Privacy may disagree while replicas converge: inherit it
            // conservatively. Conflicting evidence or attribution is ambiguous.
            guard replicas.allSatisfy({
                $0.memory.content == first.memory.content && $0.memory.topic == first.memory.topic &&
                $0.memory.project == first.memory.project && $0.memory.source == first.memory.source &&
                $0.memory.authorUserId == first.memory.authorUserId
            }) else {
                throw DerivationScopeError(message: "Source copies disagree about content or attribution. Resolve them before deriving.")
            }
            targets.append(first)
            guard copies.count + replicas.count <= 4096 else {
                throw DerivationScopeError(message: "Too many source copies for one derivation. Choose a smaller source set.")
            }
            copies.append(contentsOf: replicas)
        }
        let bindings = stores.map(\.binding)
        guard try derivationStores().map(\.binding) == bindings else {
            throw DerivationScopeError(message: "Source store bindings changed while reading. Retry after access is stable.")
        }
        return DerivationInputs(targets: targets, copies: copies, stores: bindings)
    }

    /// Immutable values, not live model references: reclassifying or replacing a
    /// source while embedding must not publish a summary of its older content.
    func derivationSnapshot(
        sources: DerivationInputs, project: String,
        destinationLattice: Lattice? = nil
    ) throws -> DerivationSnapshot {
        guard try derivationStores().map(\.binding) == sources.stores else {
            throw DerivationScopeError(message: "Source store bindings changed while deriving. Re-read the sources and retry.")
        }
        let spokes = sources.stores.filter { $0.group != nil }
        // Existing rows may be updated directly in a group spoke. Its actual
        // audience is authoritative even if a local project has the same name.
        let destination: Set<String>
        if let destinationLattice, let spoke = spokes.first(where: {
            $0.url == destinationLattice.configuration.fileURL.standardizedFileURL
        }) {
            destination = [spoke.group!]
        } else {
            destination = try derivationProjectAudience(project)
        }
        return try DerivationSnapshot(stores: sources.stores, sources: sources.copies.map { source in
            let store = source.lattice.configuration.fileURL.standardizedFileURL
            let audience: Set<String>
            if source.memory.isPrivate {
                audience = []
            } else if let spoke = spokes.first(where: { $0.url == store }) {
                // A teammate's project name need not match ours. The actual
                // spoke defines its audience, not a local project's name.
                audience = [spoke.group!]
            } else {
                audience = try derivationProjectAudience(source.memory.project)
            }
            return DerivationSnapshot.Source(
                id: source.memory.globalId, store: store,
                content: source.memory.content, topic: source.memory.topic, project: source.memory.project,
                source: source.memory.source, isPrivate: source.memory.isPrivate, author: source.memory.authorUserId,
                modifiedAt: source.memory.modifiedAt, audience: audience
            )
        }, destination: destination)
    }

    /// Returns the privacy inherited by a derived row. This checks the audience
    /// represented by today's store/exposure configuration; it does not invent a
    /// per-memory ACL or authorize later project re-exposure.
    func derivationPrivacy(
        sources: DerivationInputs,
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
        guard let config = configs.first?.materialize() else { return [] }
        // Group exposure is exact-project only; _default governs personal sync.
        // Preserve legacy non-UUID identifiers while normalizing UUID casing.
        return Set(config.exposedGroups.map { UUID(uuidString: $0)?.uuidString ?? $0 })
    }
}
