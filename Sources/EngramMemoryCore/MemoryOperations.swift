import Foundation

// MARK: - Durable mutation operations (version 1)
//
// This is an additive contract, not an implementation or a capability claim.
// A backend may advertise localMutationOperationsV1 only after it can commit
// the mutation and its receipt in the SAME owning-store transaction. A wrapper
// that calls remember/update/connect and then writes a receipt is not conforming.

/// A SHA-256 value. The backend computes a request's payload digest from its
/// versioned canonical representation; callers cannot choose that digest.
/// This type validates representation only and deliberately performs no hashing.
public struct MemoryOperationDigest: Sendable, Codable, Hashable {
    public let sha256: String

    public init(sha256: String) throws {
        guard sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw MemoryOperationError.invalidRequest("Expected 64 lowercase SHA-256 hex digits")
        }
        self.sha256 = sha256
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        try self.init(sha256: value)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(sha256)
    }
}

/// Identity and authorization context captured by the backend. Display names
/// are intentionally excluded. Compare against a freshly captured principal
/// after any suspension and before mutation; this is not authentication input.
public struct MemoryOperationPrincipalBinding: Sendable, Codable, Equatable {
    public let id: UUID?
    public let kind: Principal.Kind
    public let groupIds: [UUID]
    public let scopes: [String]

    public init(_ principal: Principal) {
        self.id = principal.id
        self.kind = principal.kind
        self.groupIds = Array(Set(principal.groupIds)).sorted { $0.uuidString < $1.uuidString }
        self.scopes = principal.scopes.sorted()
    }

    private enum CodingKeys: String, CodingKey { case id, kind, groupIds, scopes }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(Principal(
            id: try values.decodeIfPresent(UUID.self, forKey: .id),
            kind: try values.decode(Principal.Kind.self, forKey: .kind),
            groupIds: try values.decode([UUID].self, forKey: .groupIds),
            scopes: Set(try values.decode([String].self, forKey: .scopes))))
    }
}

/// A backend-issued logical store identity and principal binding. A cloned
/// database retains its store ID, so callers must also retain their original
/// backend route; this value alone does not authorize replay on another host.
public struct MemoryOperationScope: Sendable, Codable, Equatable {
    public static let currentVersion = 1
    public let version: Int
    public let storeID: UUID
    public let principal: MemoryOperationPrincipalBinding

    public init(version: Int = Self.currentVersion, storeID: UUID,
                principal: MemoryOperationPrincipalBinding) throws {
        guard version == Self.currentVersion else {
            throw MemoryOperationError.invalidRequest("Unsupported operation scope version")
        }
        self.version = version
        self.storeID = storeID
        self.principal = principal
    }

    private enum CodingKeys: String, CodingKey { case version, storeID, principal }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(version: values.decode(Int.self, forKey: .version),
                      storeID: values.decode(UUID.self, forKey: .storeID),
                      principal: values.decode(MemoryOperationPrincipalBinding.self, forKey: .principal))
    }
}

/// The exact half-open byte interval of the original source snapshot. The
/// digest covers the immutable excerpt used to derive the operation, not a
/// later read of a growing transcript. No transcript text is included here.
public struct MemoryOperationSourceInterval: Sendable, Codable, Equatable {
    public let startOffset: UInt64
    public let endOffset: UInt64
    public let excerptDigest: MemoryOperationDigest

    public init(startOffset: UInt64, endOffset: UInt64,
                excerptDigest: MemoryOperationDigest) throws {
        guard endOffset > startOffset else {
            throw MemoryOperationError.invalidRequest("Source interval must be nonempty and ordered")
        }
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.excerptDigest = excerptDigest
    }

    private enum CodingKeys: String, CodingKey { case startOffset, endOffset, excerptDigest }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(startOffset: values.decode(UInt64.self, forKey: .startOffset),
                      endOffset: values.decode(UInt64.self, forKey: .endOffset),
                      excerptDigest: values.decode(MemoryOperationDigest.self, forKey: .excerptDigest))
    }
}

/// Bounded, content-free evidence tying a mutation to its execution manifest.
/// These identifiers are correlation data, never authorization or instructions.
public struct MemoryOperationProvenance: Sendable, Codable, Equatable {
    public static let maximumIdentifierBytes = 128
    public let host: String
    public let sessionID: String
    public let runID: String
    public let source: MemoryOperationSourceInterval

    public init(host: String, sessionID: String, runID: String,
                source: MemoryOperationSourceInterval) throws {
        for value in [host, sessionID, runID] {
            guard !value.isEmpty, value.utf8.count <= Self.maximumIdentifierBytes,
                  value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw MemoryOperationError.invalidRequest("Invalid operation provenance identifier")
            }
        }
        self.host = host
        self.sessionID = sessionID
        self.runID = runID
        self.source = source
    }

    private enum CodingKeys: String, CodingKey { case host, sessionID, runID, source }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(host: values.decode(String.self, forKey: .host),
                      sessionID: values.decode(String.self, forKey: .sessionID),
                      runID: values.decode(String.self, forKey: .runID),
                      source: values.decode(MemoryOperationSourceInterval.self, forKey: .source))
    }
}

/// Version 1 covers these existing semantic operations, not arbitrary tool
/// names. The local capability excludes foreign owning stores and undelete.
/// Unsupported targets must be rejected before any mutation or legacy fallback.
public enum MemoryMutation: Sendable, Codable {
    case remember(RememberRequest)
    case update(UpdateRequest)
    case connect(ConnectRequest)

    public enum Kind: String, Sendable, Codable { case remember, update, connect }

    public var kind: Kind {
        switch self {
        case .remember: .remember
        case .update: .update
        case .connect: .connect
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, request }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .remember: self = .remember(try values.decode(RememberRequest.self, forKey: .request))
        case .update: self = .update(try values.decode(UpdateRequest.self, forKey: .request))
        case .connect: self = .connect(try values.decode(ConnectRequest.self, forKey: .request))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        switch self {
        case .remember(let request): try values.encode(request, forKey: .request)
        case .update(let request): try values.encode(request, forKey: .request)
        case .connect(let request): try values.encode(request, forKey: .request)
        }
    }
}

/// Persist this immutable request before execution. Within its original store
/// and principal, reusing an operation ID with a different canonical payload
/// (including scope or provenance) is a conflict, never a second write. This
/// is not global deduplication across stores or principals. Effective defaults
/// belong to the backend's versioned canonical format, not to a transport's
/// JSON serialization.
public struct MemoryOperationRequest: Sendable, Codable {
    public static let currentVersion = 1
    public let version: Int
    public let operationID: UUID
    public let expectedScope: MemoryOperationScope
    public let provenance: MemoryOperationProvenance
    public let mutation: MemoryMutation

    public init(version: Int = Self.currentVersion, operationID: UUID,
                expectedScope: MemoryOperationScope, provenance: MemoryOperationProvenance,
                mutation: MemoryMutation) throws {
        guard version == Self.currentVersion else {
            throw MemoryOperationError.invalidRequest("Unsupported operation request version")
        }
        self.version = version
        self.operationID = operationID
        self.expectedScope = expectedScope
        self.provenance = provenance
        self.mutation = mutation
    }

    private enum CodingKeys: String, CodingKey { case version, operationID, expectedScope, provenance, mutation }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(version: values.decode(Int.self, forKey: .version),
                      operationID: values.decode(UUID.self, forKey: .operationID),
                      expectedScope: values.decode(MemoryOperationScope.self, forKey: .expectedScope),
                      provenance: values.decode(MemoryOperationProvenance.self, forKey: .provenance),
                      mutation: values.decode(MemoryMutation.self, forKey: .mutation))
    }
}

/// A durable result from the original transaction. Replays return this same
/// receipt, including its original outcome and timestamp. Receipt presence
/// proves the recorded transaction committed; it does not prove independent
/// memory readback or completion of the learner's entire source interval.
public struct MemoryOperationReceipt: Sendable, Codable, Equatable {
    public enum Outcome: String, Sendable, Codable {
        /// The original transaction changed rows. Returning this receipt on
        /// replay does not represent another write; count by operation ID.
        case applied
        /// A terminal decision such as an existing connection or declined
        /// duplicate. This decision is ledger-recorded even without row edits.
        case unchanged
    }

    public static let currentVersion = 1
    public static let maximumResultIDs = 128
    public let version: Int
    public let operationID: UUID
    public let scope: MemoryOperationScope
    public let payloadDigest: MemoryOperationDigest
    public let mutation: MemoryMutation.Kind
    public let outcome: Outcome
    /// Primary mutation targets/results, not necessarily newly created rows.
    /// An unchanged duplicate may return an existing memory ID; acknowledgements
    /// must inspect outcome and deduplicate operation IDs before counting writes.
    /// This is not every bookkeeping row (for example, automatic topic links).
    public let memoryIDs: [UUID]
    public let edgeIDs: [UUID]
    public let committedAt: Date

    public init(version: Int = Self.currentVersion, operationID: UUID,
                scope: MemoryOperationScope, payloadDigest: MemoryOperationDigest,
                mutation: MemoryMutation.Kind, outcome: Outcome,
                memoryIDs: [UUID] = [], edgeIDs: [UUID] = [], committedAt: Date) throws {
        guard version == Self.currentVersion else {
            throw MemoryOperationError.invalidRequest("Unsupported operation receipt version")
        }
        guard memoryIDs.count + edgeIDs.count <= Self.maximumResultIDs,
              Set(memoryIDs).count == memoryIDs.count, Set(edgeIDs).count == edgeIDs.count,
              committedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw MemoryOperationError.invalidRequest("Invalid operation receipt result")
        }
        self.version = version
        self.operationID = operationID
        self.scope = scope
        self.payloadDigest = payloadDigest
        self.mutation = mutation
        self.outcome = outcome
        self.memoryIDs = memoryIDs
        self.edgeIDs = edgeIDs
        self.committedAt = committedAt
    }

    private enum CodingKeys: String, CodingKey {
        case version, operationID, scope, payloadDigest, mutation, outcome, memoryIDs, edgeIDs, committedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(version: values.decode(Int.self, forKey: .version),
                      operationID: values.decode(UUID.self, forKey: .operationID),
                      scope: values.decode(MemoryOperationScope.self, forKey: .scope),
                      payloadDigest: values.decode(MemoryOperationDigest.self, forKey: .payloadDigest),
                      mutation: values.decode(MemoryMutation.Kind.self, forKey: .mutation),
                      outcome: values.decode(Outcome.self, forKey: .outcome),
                      memoryIDs: values.decode([UUID].self, forKey: .memoryIDs),
                      edgeIDs: values.decode([UUID].self, forKey: .edgeIDs),
                      committedAt: values.decode(Date.self, forKey: .committedAt))
    }
}

public enum MemoryOperationStatus: Sendable, Codable, Equatable {
    case committed(MemoryOperationReceipt)
    /// Only a successful ledger lookup may produce absent. It is not proof
    /// that an older writer has stopped; recovery must fence that writer before
    /// replay. A query error, unavailable store, or wrong scope must throw.
    case absent(operationID: UUID, scope: MemoryOperationScope)
}

public enum MemoryOperationError: Error, Sendable, Equatable {
    case unsupported
    case scopeMismatch
    case payloadConflict(operationID: UUID)
    case unsupportedTarget
    case invalidRequest(String)
    /// May include an indeterminate commit. Never interpret this as absence
    /// or permission to invoke a legacy write; inspect status in the same scope.
    case storageUnavailable
}

public extension MemoryService {
    func operationScope() async throws -> MemoryOperationScope {
        throw MemoryOperationError.unsupported
    }

    func applyOperation(_ request: MemoryOperationRequest) async throws -> MemoryOperationReceipt {
        throw MemoryOperationError.unsupported
    }

    func operationStatus(operationID: UUID, scope: MemoryOperationScope) async throws -> MemoryOperationStatus {
        throw MemoryOperationError.unsupported
    }
}
