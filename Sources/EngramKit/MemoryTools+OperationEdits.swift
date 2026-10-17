import EngramMemoryCore
import EngramModels
import Foundation
import Lattice

extension MemoryTools {
    /// A durable operation may only write this actor's exact local owning
    /// store. Never use findMemory/readLattice here: those can select a synced
    /// copy or a group attachment whose transaction is not the local ledger's.
    /// Query failure and duplicate identities are not evidence of absence.
    func operationLocalMemory(id: UUID) throws -> Memory {
        let rows = localLattice.objects(Memory.self)
            .where { $0.globalId == id }.snapshot(limit: 2)
        guard localLattice.lastQueryError() == nil, rows.count <= 1 else {
            throw MemoryOperationError.storageUnavailable
        }
        // Scalar reads use the image already hydrated by this successful query;
        // otherwise detached getters perform fresh SQL and can clear its error
        // slot or mix a later row image into the preparation snapshot.
        guard let memory = rows.first?.materialize(), memory.globalId == id, memory.deletedAt == nil else {
            throw MemoryOperationError.unsupportedTarget
        }
        return memory
    }

    /// The dispatcher performs the cheap replay lookup first. Embedding may
    /// suspend, so no detached row selected before that await is ever written.
    /// The ledger must be constructed with this actor's localLattice, and its
    /// checked transaction repeats receipt lookup before invoking the body.
    func applyPreparedUpdate(_ prepared: MemoryOperationCanonicalPayload,
                             _ value: MemoryOperationCanonicalPayload.Update,
                             ledger: MemoryOperationLedger) async throws -> MemoryOperationReceipt {
        let original = try operationLocalMemory(id: value.id)
        let oldContent = original.content
        try operationCheckPrivacyEdit(value, memory: original, principal: identity.currentPrincipal())

        let newContent: String?
        switch value.contentEdit {
        case nil: newContent = nil
        case .content(let content): newContent = content
        case .append(let append): newContent = oldContent + "\n" + append
        case .prepend(let prepend): newContent = prepend + "\n" + oldContent
        case .replaceOccurrences(let find, let replace):
            guard oldContent.contains(find) else {
                throw MemoryOperationError.invalidRequest("Update find pattern is absent from the target memory")
            }
            newContent = oldContent.replacingOccurrences(of: find, with: replace)
        }

        let newEmbedding: [Float]?
        if let newContent {
            guard let embedding = try await embedder.embed(text: newContent) else {
                throw MemoryServiceError.embeddingUnavailable
            }
            let dimension = await embedder.dimension
            guard dimension > 0, embedding.count == dimension, embedding.allSatisfy(\.isFinite) else {
                throw MemoryServiceError.embeddingUnavailable
            }
            newEmbedding = embedding
        } else { newEmbedding = nil }

        // The provider is evaluated after checked BEGIN, including replay, so
        // embedding suspension and waiting behind another writer cannot leave
        // the ledger using a stale principal captured before either wait.
        let commit = try ledger.withOperation(prepared, principal: { identity.currentPrincipal() }) {
            let currentPrincipal = try operationCurrentPrincipal(for: prepared)
            let memory = try operationLocalMemory(id: value.id)
            guard memory.content.utf8.elementsEqual(oldContent.utf8) else {
                throw MemoryOperationError.invalidRequest("Memory content changed during operation preparation")
            }
            try operationCheckPrivacyEdit(value, memory: memory, principal: currentPrincipal)

            let now = Date()
            if let newContent, let newEmbedding {
                memory.content = newContent
                memory.embedding = Vector<Float>(newEmbedding)
            }
            if let topic = value.topic { memory.topic = topic }
            if let project = value.project { memory.project = project }
            if let source = value.source { memory.source = source }
            if let importance = value.importance { memory.importance = importance }
            if let isPrivate = value.isPrivate { memory.isPrivate = isPrivate }
            if let expiration = value.expiration {
                switch expiration {
                case .permanent: memory.expiresAt = .distantFuture
                case .afterDays(let days): memory.expiresAt = now.addingTimeInterval(Double(days) * 86_400)
                }
            }
            // Preserve author attribution and tombstones. No undelete, graph
            // effects, or provider calls may escape this atomic mutation body.
            memory.lastAccessedAt = now
            memory.modifiedAt = now
            return .init(outcome: .applied, memoryIDs: [value.id])
        }
        return commit.receipt
    }

    /// Endpoint checks, duplicate/revival selection, edge mutation, and receipt
    /// publication all run in the same checked local-store transaction.
    func applyPreparedConnect(_ prepared: MemoryOperationCanonicalPayload,
                              _ value: MemoryOperationCanonicalPayload.Connect,
                              ledger: MemoryOperationLedger) throws -> MemoryOperationReceipt {
        guard let relation = Edge.Relation(rawValue: value.relation.rawValue) else {
            throw MemoryOperationError.invalidRequest("Unsupported operation connection relation")
        }
        let commit = try ledger.withOperation(prepared, principal: { identity.currentPrincipal() }) {
            let currentPrincipal = try operationCurrentPrincipal(for: prepared)
            _ = try operationLocalMemory(id: value.sourceID)
            _ = try operationLocalMemory(id: value.targetID)
            let rows = localLattice.objects(Edge.self)
                .where { $0.sourceGlobalId == value.sourceID && $0.targetGlobalId == value.targetID && $0.relation == relation }
                .snapshot(limit: 2)
            guard localLattice.lastQueryError() == nil, rows.count <= 1 else {
                throw MemoryOperationError.storageUnavailable
            }
            if let edge = rows.first?.materialize() {
                guard let id = edge.globalId else { throw MemoryOperationError.storageUnavailable }
                if edge.deletedAt != nil {
                    edge.deletedAt = nil
                    return .init(outcome: .applied, memoryIDs: operationEndpointIDs(value), edgeIDs: [id])
                }
                return .init(outcome: .unchanged, memoryIDs: operationEndpointIDs(value), edgeIDs: [id])
            }
            let edge = Edge(sourceGlobalId: value.sourceID, targetGlobalId: value.targetID,
                            relation: relation, authorUserId: currentPrincipal.id)
            try localLattice.add(edge)
            guard let id = edge.globalId else { throw MemoryOperationError.storageUnavailable }
            return .init(outcome: .applied, memoryIDs: operationEndpointIDs(value), edgeIDs: [id])
        }
        return commit.receipt
    }

    private func operationCurrentPrincipal(for prepared: MemoryOperationCanonicalPayload) throws -> Principal {
        let principal = identity.currentPrincipal()
        guard MemoryOperationPrincipalBinding(principal) == prepared.expectedScope.principal else {
            throw MemoryOperationError.scopeMismatch
        }
        return principal
    }

    private func operationCheckPrivacyEdit(_ value: MemoryOperationCanonicalPayload.Update,
                                           memory: Memory, principal: Principal) throws {
        if value.isPrivate != nil, let author = memory.authorUserId, author != principal.id {
            throw MemoryOperationError.unsupportedTarget
        }
    }

    private func operationEndpointIDs(_ value: MemoryOperationCanonicalPayload.Connect) -> [UUID] {
        value.sourceID == value.targetID ? [value.sourceID] : [value.sourceID, value.targetID]
    }
}
