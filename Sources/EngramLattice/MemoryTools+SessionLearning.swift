import Foundation
import Lattice
import MCP
import EngramModels
import EngramMemoryCore

extension MemoryTools {
    func requireSessionLearningWriteAdmission() throws {
        guard let identity = sessionLearningWriteIdentity else { return }
        guard let receipt = try loadSessionLearningReceipt(identity), receipt.state == .running,
              receipt.inFlightWrite,
              localLattice.objects(HookState.self).where({ $0.key == .agentSessionLearningGate }).first?.value
                == identity.attemptID.uuidString.lowercased() else {
            throw MemoryServiceError.invalidArguments("Learning write admission was withdrawn")
        }
    }
    private func validateLearningIdentity(_ identity: SessionLearningIdentity) throws {
        guard privateGraphOnly, let graphBinding,
              identity.graphID == graphBinding.graphId, identity.principalID == graphBinding.agentId,
              UUID(uuidString: identity.turnID) != nil, !identity.workspaceID.isEmpty,
              !identity.roomID.isEmpty, identity.generation > 0,
              identity.inputSHA256.count == 64,
              identity.inputSHA256.allSatisfy({ $0.isHexDigit }) else {
            throw MemoryServiceError.invalidArguments("Invalid scoped learning identity")
        }
    }

    public func sessionLearningReceipt(_ identity: SessionLearningIdentity) throws -> SessionLearningReceipt? {
        defer { retireAllReadMarks() }
        return try loadSessionLearningReceipt(identity)
    }

    private func loadSessionLearningReceipt(_ identity: SessionLearningIdentity) throws -> SessionLearningReceipt? {
        try validateLearningIdentity(identity)
        guard let row = localLattice.object(HookState.self, globalId: identity.attemptID) else { return nil }
        guard row.key == .agentSessionLearningReceipt,
              let data = row.value.data(using: .utf8),
              let receipt = try? JSONDecoder().decode(SessionLearningReceipt.self, from: data),
              receipt.identity == identity else {
            throw MemoryServiceError.invalidArguments("Learning receipt identity changed")
        }
        return receipt
    }

    private func storeLearningReceipt(_ receipt: SessionLearningReceipt) throws {
        let value = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        if let row = localLattice.object(HookState.self, globalId: receipt.identity.attemptID) {
            guard row.key == .agentSessionLearningReceipt else {
                throw MemoryServiceError.invalidArguments("Learning receipt identity collision")
            }
            row.value = value; row.updatedAt = receipt.updatedAt
        } else {
            try localLattice.add(HookState(key: .agentSessionLearningReceipt, value: value),
                                 preservingGlobalId: receipt.identity.attemptID)
        }
    }

    /// Claims once under the graph's existing writer lifetime. A leftover gate never
    /// authorizes replay: it may represent an interrupted write on another host.
    public func beginSessionLearning(_ identity: SessionLearningIdentity) throws -> Bool {
        defer { retireAllReadMarks() }
        try validateLearningIdentity(identity)
        return try localLattice.withTransaction {
            if try loadSessionLearningReceipt(identity) != nil { return false }
            let gates = localLattice.objects(HookState.self)
                .where { $0.key == .agentSessionLearningGate }.snapshot()
            guard gates.count <= 1 else { throw MemoryServiceError.invalidArguments("Invalid learning gate") }
            if let gate = gates.first, !gate.value.isEmpty {
                try storeLearningReceipt(.init(identity: identity, state: .held, reason: .priorAttemptUnresolved))
                return false
            }
            let gate = gates.first ?? HookState(key: .agentSessionLearningGate, value: "")
            if gates.isEmpty { try localLattice.add(gate) }
            gate.value = identity.attemptID.uuidString.lowercased(); gate.updatedAt = Date()
            try storeLearningReceipt(.init(identity: identity))
            return true
        }
    }

    public func finishSessionLearning(_ identity: SessionLearningIdentity,
                                      state: SessionLearningReceipt.State,
                                      reason: SessionLearningReceipt.Reason) throws -> SessionLearningReceipt {
        defer { retireAllReadMarks() }
        return try localLattice.withTransaction {
            guard var receipt = try loadSessionLearningReceipt(identity), receipt.state == .running,
                  let gate = localLattice.objects(HookState.self)
                    .where({ $0.key == .agentSessionLearningGate }).first,
                  gate.value == identity.attemptID.uuidString.lowercased() else {
                throw MemoryServiceError.invalidArguments("Learning attempt is not current")
            }
            receipt.state = receipt.inFlightWrite ? .reconciliationRequired : state
            if state == .completed && !receipt.inFlightWrite && receipt.memoryIDs.isEmpty { receipt.state = .noChange }
            receipt.reason = reason; receipt.updatedAt = Date()
            try storeLearningReceipt(receipt)
            if !receipt.inFlightWrite { gate.value = ""; gate.updatedAt = Date() }
            return receipt
        }
    }

    /// Same substantive-block floor, truncation and novelty threshold as Engram's
    /// TranscriptSampler. The host passes visible blocks directly; no transcript is opened.
    /// Missing embeddings admit model triage, matching the standalone gate's fail-open policy.
    public func recordSessionLearningSample(_ identity: SessionLearningIdentity,
                                            decision: SessionLearningReceipt.SampleDecision) throws -> SessionLearningReceipt {
        defer { retireAllReadMarks() }
        return try localLattice.withTransaction {
            guard var receipt = try loadSessionLearningReceipt(identity), receipt.state == .running else {
                throw MemoryServiceError.invalidArguments("Learning attempt is not current")
            }
            receipt.sampleDecision = decision; receipt.updatedAt = Date()
            try storeLearningReceipt(receipt); return receipt
        }
    }

    public func sessionLearningSample(_ blocks: [String]) async throws -> SessionLearningReceipt.SampleDecision {
        defer { retireAllReadMarks() }
        let candidates = blocks.filter { $0.count >= TranscriptExcerpts.minBlockChars }.suffix(5)
        guard !candidates.isEmpty else { return .insufficientContent }
        for block in candidates {
            try Task.checkCancellation()
            let text = String(block.prefix(TranscriptExcerpts.maxCharsPerExcerpt))
            guard let floats = try await embedding(for: text), !floats.isEmpty else { return .embeddingUnavailable }
            let nearest = localLattice.objects(Memory.self)
                .where { $0.expiresAt > Date() && $0.deletedAt == nil }
                .nearest(to: Vector<Float>(floats), on: \.embedding, limit: 1, distance: .l2).snapshot()
            guard let distance = nearest.first?.distance else { return .novel }
            if distance >= SamplerThresholds.novelty { return .novel }
        }
        return .notNovel
    }

    /// Enforced below the model's MCP surface. Receipts precede write execution,
    /// so losing a provider or helper cannot erase the possibility of a write.
    public func handleSessionLearningTool(_ params: CallTool.Parameters,
                                         identity: SessionLearningIdentity) async throws -> CallTool.Result {
        defer { retireAllReadMarks() }
        guard SessionLearningPolicy.tools.contains(params.name),
              !(params.arguments?.keys.contains { ["graph", "graph_id", "graphId", "agent_id", "agentId", "path", "directory"].contains($0) } ?? false),
              params.arguments?["force"] != .bool(true) else {
            throw MemoryServiceError.invalidArguments("Tool is outside the learning grant")
        }
        let writes = SessionLearningPolicy.writeTools.contains(params.name)
        if params.name == "update" {
            guard case .string(let id)? = params.arguments?["id"], UUID(uuidString: id) != nil,
                  params.arguments?["query"] == nil else {
                throw MemoryServiceError.invalidArguments("Learning updates require one exact memory UUID")
            }
        }
        try localLattice.withTransaction {
            guard var receipt = try loadSessionLearningReceipt(identity), receipt.state == .running,
                  !receipt.inFlightWrite, receipt.toolCalls < SessionLearningPolicy.maximumToolCalls,
                  !writes || receipt.writeCalls < SessionLearningPolicy.maximumWrites,
                  localLattice.objects(HookState.self).where({ $0.key == .agentSessionLearningGate }).first?.value
                    == identity.attemptID.uuidString.lowercased() else {
                throw MemoryServiceError.invalidArguments("Learning attempt is closed or its limit was reached")
            }
            receipt.toolCalls += 1
            if writes { receipt.writeCalls += 1; receipt.inFlightWrite = true }
            receipt.updatedAt = Date(); try storeLearningReceipt(receipt)
        }
        var arguments = params.arguments ?? [:]
        if params.name == "remember" {
            arguments["source"] = .string("orbital-session-learner:\(identity.workspaceID):\(identity.turnID):\(identity.generation)")
            lastRememberedId = nil
        }
        if writes { sessionLearningWriteIdentity = identity }
        defer { if writes { sessionLearningWriteIdentity = nil } }
        let result = try await handle(.init(name: params.name, arguments: arguments))
        if writes {
            // An error reply does not prove no mutation. Keep the pre-write marker.
            guard result.isError != true else { return result }
            var ids: [UUID] = []
            if params.name == "remember", let id = lastRememberedId { ids = [id] }
            if params.name == "update", case .string(let raw)? = arguments["id"], let id = UUID(uuidString: raw) { ids = [id] }
            if params.name == "connect" {
                for key in ["from", "to"] {
                    if case .string(let raw)? = arguments[key], let id = UUID(uuidString: raw) { ids.append(id) }
                }
            }
            try localLattice.withTransaction {
                guard var receipt = try loadSessionLearningReceipt(identity), receipt.state == .running, receipt.inFlightWrite else {
                    throw MemoryServiceError.invalidArguments("Learning write receipt is no longer current")
                }
                receipt.memoryIDs = Array(Set(receipt.memoryIDs + ids)).sorted { $0.uuidString < $1.uuidString }
                receipt.inFlightWrite = false; receipt.updatedAt = Date(); try storeLearningReceipt(receipt)
            }
        }
        return result
    }
}
