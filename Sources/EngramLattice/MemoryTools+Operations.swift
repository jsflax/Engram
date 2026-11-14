import EngramMemoryCore
import Foundation
import Lattice

extension MemoryTools {
    /// Requires a preflighted, registered and bootstrapped local operation
    /// store. This read never initializes a ledger or falls back to legacy CRUD.
    public func operationScope() async throws -> MemoryOperationScope {
        guard localMutationOperationsEnabled else { throw MemoryOperationError.unsupported }
        try prepareOperationStorage()
        return try MemoryOperationLedger(lattice: localLattice).scope(principal: identity.currentPrincipal())
    }

    public func operationStatus(operationID: UUID, scope: MemoryOperationScope) async throws -> MemoryOperationStatus {
        guard localMutationOperationsEnabled else { throw MemoryOperationError.unsupported }
        try prepareOperationStorage()
        return try MemoryOperationLedger(lattice: localLattice).status(
            operationID: operationID, scope: scope, principal: identity.currentPrincipal())
    }

    public func applyOperation(_ request: MemoryOperationRequest) async throws -> MemoryOperationReceipt {
        guard localMutationOperationsEnabled else { throw MemoryOperationError.unsupported }
        let prepared = try MemoryOperationCanonicalPayload.prepare(request)
        try prepareOperationStorage()
        let ledger = MemoryOperationLedger(lattice: localLattice)
        // Exact replay must succeed without embedding, re-running duplicate
        // detection, refreshing TTL or publishing episode/save effects again.
        if let prior = try ledger.lookup(prepared, principal: identity.currentPrincipal()) { return prior }
        switch prepared.mutation {
        case .remember(let value):
            return try await applyPreparedRemember(prepared, value, ledger: ledger)
        case .update(let value):
            return try await applyPreparedUpdate(prepared, value, ledger: ledger)
        case .connect(let value):
            return try applyPreparedConnect(prepared, value, ledger: ledger)
        }
    }

    private func prepareOperationStorage() throws {
        do { try prepareStorage() }
        catch { throw MemoryOperationError.storageUnavailable }
    }

    private func applyPreparedRemember(_ prepared: MemoryOperationCanonicalPayload,
                                       _ value: MemoryOperationCanonicalPayload.Remember,
                                       ledger: MemoryOperationLedger) async throws -> MemoryOperationReceipt {
        guard let floats = try await embedder.embed(text: value.content) else {
            throw MemoryOperationError.storageUnavailable
        }
        // A lazy embedder publishes its dimension only after loading the model.
        let dimension = await embedder.dimension
        guard dimension > 0, floats.count == dimension,
              floats.allSatisfy({ $0.isFinite }) else {
            throw MemoryOperationError.storageUnavailable
        }
        let embedding = Vector<Float>(floats)
        // Opening an attached union may register schema on a new connection.
        // Do it before taking this writer's lock, then validate its route under
        // that lock without creating another connection.
        let readContext = try (value.topic == "episode" ? nil : prepareOperationReadLattice(for: value.project))
        // All identity and process-local snapshots are captured after preparation
        // suspensions. withOperation validates this scope again under BEGIN.
        let rememberedAt = Date()
        let episodeExpired = activeEpisodeId != nil && rememberedAt.timeIntervalSince(lastMemoryTime) > 1800
        let episodeID = episodeExpired ? nil : activeEpisodeId
        var effects: RememberCommitEffects?
        let commit = try ledger.withOperation(prepared, principal: { identity.currentPrincipal() }) {
            let principal = identity.currentPrincipal()
            guard MemoryOperationPrincipalBinding(principal) == prepared.expectedScope.principal else {
                throw MemoryOperationError.scopeMismatch
            }
            if let parentID = value.parentID { _ = try operationLocalMemory(id: parentID) }
            let readDB = try readContext.map { try validateOperationReadLattice($0, for: value.project) } ?? localLattice
            let candidates = try rememberNeighbors(topic: value.topic, project: value.project,
                                                   embedding: embedding, database: readDB)
            let conflicts = candidates.filter {
                $0.distance < ($0.object.project == value.project ? 0.55 : 0.45)
                    && jaccardSimilarity(value.content, $0.object.content) >= 0.4
            }
            if !conflicts.isEmpty {
                // The existing remember contract declines near duplicates.
                // Retain that decision so replay cannot turn it into a write.
                let ids = try conflicts.map { candidate -> UUID in
                    guard let id = candidate.object.globalId else { throw MemoryOperationError.storageUnavailable }
                    return id
                }
                return .init(outcome: .unchanged, memoryIDs: ids)
            }
            let autoConnect = Array(candidates.filter {
                $0.distance >= ($0.object.project == value.project ? 0.55 : 0.45) && $0.distance < 1.00
            }.sorted { $0.distance < $1.distance }.prefix(3))
            let expiresAt: Date
            switch value.expiration {
            case .permanent: expiresAt = .distantFuture
            case .afterDays(let days): expiresAt = Date().addingTimeInterval(Double(days) * 86400)
            }
            let memory = Memory(content: value.content, topic: value.topic, project: value.project,
                                source: value.source, embedding: embedding, expiresAt: expiresAt,
                                importance: value.importance, isPrivate: value.isPrivate,
                                authorUserId: principal.id, modifiedAt: rememberedAt)
            let result = try commitRemember(memory, parentGidValue: value.parentID,
                                            episodeId: episodeID, autoConnectCandidates: autoConnect,
                                            authorID: principal.id)
            effects = result
            return .init(outcome: .applied, memoryIDs: [result.memoryID], edgeIDs: result.edgeIDs)
        }
        if !commit.isReplay, let effects {
            if episodeExpired { endActiveEpisode() }
            lastMemoryTime = rememberedAt
            lastRememberedId = effects.memoryID
            for message in effects.logs { log(message) }
            appendSessionSaveLog(sessionId: currentSessionId, globalId: effects.memoryID.uuidString,
                                 project: value.project, topic: value.topic,
                                 preview: String(value.content.prefix(50)))
        }
        return commit.receipt
    }
}
