import CryptoKit
import EngramMemoryCore
import Foundation

/// Backend-owned preparation for durable local mutations. This is deliberately
/// internal, has no transport decoder, and accepts no caller-supplied digest.
/// It does not perform or authorize a mutation or advertise backend capability.
///
/// An executor must apply `mutation`, not reinterpret the original request.
/// Defaults below are pinned to format version 1 and never consult ambient
/// project, clock, principal, or store state. Validate the prepared scope against
/// the current authenticated scope again after suspension, before committing.
/// A future context-dependent default needs an explicit durable resolution
/// contract; adding ambient resolution here would break safe receipt lookup.
struct MemoryOperationCanonicalPayload: Sendable {
    static let formatVersion: UInt64 = 1

    /// Relative expiration instructions, not a wall-clock-derived date. The
    /// original transaction resolves this once; replay returns its receipt and
    /// must not refresh expiration. Update retains negative relative durations.
    enum Expiration: Sendable, Equatable {
        case permanent
        case afterDays(Int)
    }

    struct Remember: Sendable {
        let content: String
        let topic: String
        let project: String
        let source: String
        let importance: Int
        let isPrivate: Bool
        let parentID: UUID?
        let expiration: Expiration
    }

    enum ContentEdit: Sendable, Equatable {
        case content(String)
        /// Append/prepend preserve the exact argument bytes. The executor adds
        /// the existing handler's single LF separator, even for an empty value.
        case append(String)
        case prepend(String)
        case replaceOccurrences(find: String, replace: String)
    }

    struct Update: Sendable {
        let id: UUID
        let contentEdit: ContentEdit?
        /// Nil means no edit; an empty string is an explicit edit.
        let topic: String?
        let project: String?
        let source: String?
        let importance: Int?
        /// Nil means no edit, distinct from an explicit permanent expiration.
        let expiration: Expiration?
        /// Nil means no edit, distinct from explicitly setting false.
        let isPrivate: Bool?
    }

    /// Format-v1 semantic relations. Expansion needs an intentional contract
    /// decision; an arbitrary string must not accidentally reach storage.
    enum Relation: String, Sendable, CaseIterable {
        case relatesTo = "relates_to"
        case contradicts
        case supersedes
        case derivedFrom = "derived_from"
        case partOf = "part_of"
        case summarizedBy = "summarized_by"
    }

    struct Connect: Sendable {
        let sourceID: UUID
        let targetID: UUID
        let relation: Relation
    }

    enum Mutation: Sendable {
        case remember(Remember)
        case update(Update)
        case connect(Connect)
    }

    let operationID: UUID
    let expectedScope: MemoryOperationScope
    let provenance: MemoryOperationProvenance
    let mutation: Mutation
    let digest: MemoryOperationDigest

    private init(request: MemoryOperationRequest, mutation: Mutation,
                 digest: MemoryOperationDigest) {
        self.operationID = request.operationID
        self.expectedScope = request.expectedScope
        self.provenance = request.provenance
        self.mutation = mutation
        self.digest = digest
    }

    static func prepare(_ request: MemoryOperationRequest) throws -> Self {
        // The DTO validates these too. Keep the format's boundary explicit so
        // future DTO versions cannot silently inherit version-1 hashing.
        guard request.version == 1, request.expectedScope.version == 1 else {
            throw MemoryOperationError.invalidRequest("Unsupported canonical operation version")
        }
        let mutation = try prepare(request.mutation)
        var encoder = Encoder()
        encoder.string("engram.memory-operation")
        encoder.uint64(formatVersion)
        encoder.uint64(UInt64(request.version))
        encoder.uuid(request.operationID)
        encoder.scope(request.expectedScope)
        encoder.provenance(request.provenance)
        encoder.mutation(mutation)
        let digest = try digest(encoder.data)
        return Self(request: request, mutation: mutation, digest: digest)
    }

    /// Stable ledger identity for the captured principal. Use this instead of
    /// JSON encoding as a key; it shares payload normalization and has its own
    /// domain. It is not an authentication token. Store UUID and operation UUID
    /// remain separate parts of the ledger's uniqueness constraint, and a
    /// receipt's complete scope must still match the current authenticated scope.
    static func principalKey(_ binding: MemoryOperationPrincipalBinding) throws -> String {
        var encoder = Encoder()
        encoder.string("engram.memory-operation.principal")
        encoder.uint64(formatVersion)
        encoder.principal(binding)
        return try digest(encoder.data).sha256
    }

    private static func digest(_ data: Data) throws -> MemoryOperationDigest {
        try MemoryOperationDigest(sha256: SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined())
    }

    private static func prepare(_ mutation: MemoryMutation) throws -> Mutation {
        switch mutation {
        case .remember(let value):
            guard !value.content.isEmpty else {
                throw MemoryOperationError.invalidRequest("Remember content must be nonempty")
            }
            // Explicit zero is invalid in the existing remember contract; the
            // omitted/default zero is an internal effective value, not an input
            // to pass back through the legacy request validator.
            if let importance = value.importance, !(1...5).contains(importance) {
                throw MemoryOperationError.invalidRequest("Remember importance must be between 1 and 5")
            }
            let days = value.expiresInDays ?? 0
            let expiration: Expiration = days > 0 ? .afterDays(days) : .permanent
            return .remember(Remember(content: value.content,
                                      topic: value.topic ?? "general",
                                      project: value.project ?? "global",
                                      source: value.source ?? "",
                                      importance: value.importance ?? 0,
                                      isPrivate: value.isPrivate,
                                      parentID: value.parentId,
                                      expiration: expiration))
        case .update(let value):
            guard !value.undelete else { throw MemoryOperationError.unsupportedTarget }
            let contentModes = [value.content != nil, value.append != nil,
                                value.prepend != nil, value.find != nil]
            guard contentModes.filter({ $0 }).count <= 1 else {
                throw MemoryOperationError.invalidRequest("Update content edit modes are mutually exclusive")
            }
            guard (value.find == nil) == (value.replace == nil) else {
                throw MemoryOperationError.invalidRequest("Update find and replace must be supplied together")
            }
            if let importance = value.importance, !(0...5).contains(importance) {
                throw MemoryOperationError.invalidRequest("Update importance must be between 0 and 5")
            }
            let edit: ContentEdit?
            if let content = value.content { edit = .content(content) }
            else if let append = value.append { edit = .append(append) }
            else if let prepend = value.prepend { edit = .prepend(prepend) }
            else if let find = value.find, let replace = value.replace {
                edit = .replaceOccurrences(find: find, replace: replace)
            } else { edit = nil }
            let expiration: Expiration? = value.expiresInDays.map {
                $0 == 0 ? .permanent : .afterDays($0)
            }
            guard edit != nil || value.topic != nil || value.project != nil || value.source != nil ||
                    value.importance != nil || expiration != nil || value.isPrivate != nil else {
                throw MemoryOperationError.invalidRequest("Update requires at least one edit")
            }
            return .update(Update(id: value.id, contentEdit: edit, topic: value.topic,
                                  project: value.project, source: value.source, importance: value.importance,
                                  expiration: expiration, isPrivate: value.isPrivate))
        case .connect(let value):
            guard let relation = Relation(rawValue: value.relation) else {
                throw MemoryOperationError.invalidRequest("Unsupported connection relation")
            }
            return .connect(Connect(sourceID: value.sourceId, targetID: value.targetId,
                                    relation: relation))
        }
    }

    /// Canonical format 1 is a binary, ordered, length-prefixed encoding, not
    /// JSON or Swift's randomized Hasher. Fields appear in the exact order of
    /// the methods below. All lengths, counts and unsigned integers are 64-bit
    /// big endian. Signed integers use 64-bit two's-complement big endian.
    /// Strings are length + unmodified UTF-8 (no trimming, Unicode normalization,
    /// or newline conversion); UUIDs are lowercase canonical UUID strings.
    /// Bool and optional-presence tags are one byte (0/1). Arrays are count +
    /// encoded elements. Variant tags are strings. Principal memberships are
    /// deduplicated/sorted UUIDs; scopes normalize to NFC (matching Swift String
    /// equality), then deduplicate and sort by UTF-8 bytes. Mutation/provenance
    /// strings are never normalized.
    /// The domain and version lead the stream; changing its layout or semantic
    /// defaults requires a new canonical format and explicit compatibility.
    /// Bytes contain private mutation content: hash locally, never log/export
    /// them or include them in MemoryOperationReceipt/status responses.
    private struct Encoder {
        var data = Data()

        mutating func uint64(_ value: UInt64) {
            var bigEndian = value.bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }

        mutating func integer(_ value: Int) { uint64(UInt64(bitPattern: Int64(value))) }
        mutating func bool(_ value: Bool) { data.append(value ? 1 : 0) }

        mutating func string(_ value: String) {
            uint64(UInt64(value.utf8.count))
            data.append(contentsOf: value.utf8)
        }

        mutating func uuid(_ value: UUID) { string(value.uuidString.lowercased()) }

        mutating func optional<T>(_ value: T?, _ encode: (inout Self, T) -> Void) {
            bool(value != nil)
            if let value { encode(&self, value) }
        }

        mutating func scope(_ value: MemoryOperationScope) {
            uint64(UInt64(value.version))
            uuid(value.storeID)
            principal(value.principal)
        }

        mutating func principal(_ value: MemoryOperationPrincipalBinding) {
            optional(value.id) { $0.uuid($1) }
            string(value.kind.rawValue)
            let groups = Set(value.groupIds).sorted {
                $0.uuidString < $1.uuidString
            }
            uint64(UInt64(groups.count))
            for group in groups { uuid(group) }
            let scopes = Set(value.scopes.map {
                $0.precomposedStringWithCanonicalMapping
            }).sorted {
                $0.utf8.lexicographicallyPrecedes($1.utf8)
            }
            uint64(UInt64(scopes.count))
            for scope in scopes { string(scope) }
        }

        mutating func provenance(_ value: MemoryOperationProvenance) {
            string(value.host)
            string(value.sessionID)
            string(value.runID)
            uint64(value.source.startOffset)
            uint64(value.source.endOffset)
            string(value.source.excerptDigest.sha256)
        }

        mutating func expiration(_ value: Expiration) {
            switch value {
            case .permanent: string("permanent")
            case .afterDays(let days): string("relative-days"); integer(days)
            }
        }

        mutating func contentEdit(_ value: ContentEdit) {
            switch value {
            case .content(let text): string("content"); string(text)
            case .append(let text): string("append-with-lf"); string(text)
            case .prepend(let text): string("prepend-with-lf"); string(text)
            case .replaceOccurrences(let find, let replace):
                string("replace-occurrences"); string(find); string(replace)
            }
        }

        mutating func mutation(_ value: Mutation) {
            switch value {
            case .remember(let request):
                string("remember")
                string(request.content)
                string(request.topic)
                string(request.project)
                string(request.source)
                integer(request.importance)
                bool(request.isPrivate)
                optional(request.parentID) { $0.uuid($1) }
                expiration(request.expiration)
            case .update(let request):
                string("update")
                uuid(request.id)
                optional(request.contentEdit) { $0.contentEdit($1) }
                optional(request.topic) { $0.string($1) }
                optional(request.project) { $0.string($1) }
                optional(request.source) { $0.string($1) }
                optional(request.importance) { $0.integer($1) }
                optional(request.expiration) { $0.expiration($1) }
                optional(request.isPrivate) { $0.bool($1) }
                bool(false) // Undelete is explicitly unsupported in version 1.
            case .connect(let request):
                string("connect")
                uuid(request.sourceID)
                uuid(request.targetID)
                string(request.relation.rawValue)
            }
        }
    }
}
