import EngramMemoryCore
import Foundation

private enum Failure: Error { case check(String) }

@main
struct CanonicalPayloadTests {
    static let operationID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    static let storeID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    static let principalID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
    static let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let secondID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let privateText = "Private fixture: cafe\u{0301}\nline\0tail"

    static func check(_ condition: Bool, _ label: String) throws {
        if !condition { throw Failure.check(label) }
    }

    static func principal(groups: [UUID] = [secondID, firstID, firstID],
                          scopes: Set<String> = ["full", "agent"],
                          id: UUID? = principalID, kind: Principal.Kind = .agent,
                          displayName: String? = nil) -> MemoryOperationPrincipalBinding {
        MemoryOperationPrincipalBinding(Principal(id: id, kind: kind,
            displayName: displayName, groupIds: groups, scopes: scopes))
    }

    static func scope(store: UUID = storeID,
                      principal binding: MemoryOperationPrincipalBinding = principal()) throws -> MemoryOperationScope {
        try MemoryOperationScope(storeID: store, principal: binding)
    }

    static func provenance(host: String = "codex", session: String = "session-1",
                           run: String = "run-1", start: UInt64 = 17, end: UInt64 = 91,
                           excerpt: String = String(repeating: "a", count: 64)) throws -> MemoryOperationProvenance {
        try MemoryOperationProvenance(host: host, sessionID: session, runID: run,
            source: MemoryOperationSourceInterval(startOffset: start, endOffset: end,
                excerptDigest: MemoryOperationDigest(sha256: excerpt)))
    }

    static func request(_ mutation: MemoryMutation = .remember(RememberRequest(content: privateText)),
                        id: UUID = operationID, expectedScope: MemoryOperationScope? = nil,
                        provenance source: MemoryOperationProvenance? = nil) throws -> MemoryOperationRequest {
        try MemoryOperationRequest(operationID: id, expectedScope: expectedScope ?? scope(),
                                   provenance: source ?? provenance(), mutation: mutation)
    }

    static func prepare(_ mutation: MemoryMutation) throws -> MemoryOperationCanonicalPayload {
        try MemoryOperationCanonicalPayload.prepare(request(mutation))
    }

    static func digest(_ mutation: MemoryMutation) throws -> String {
        try prepare(mutation).digest.sha256
    }

    static func invalid(_ mutation: MemoryMutation) throws {
        do {
            _ = try prepare(mutation)
            throw Failure.check("Invalid mutation was accepted")
        } catch MemoryOperationError.invalidRequest { }
    }

    static func changed(_ original: MemoryOperationRequest,
                        _ candidates: [MemoryOperationRequest]) throws {
        let originalDigest = try MemoryOperationCanonicalPayload.prepare(original).digest
        for candidate in candidates {
            try check(try MemoryOperationCanonicalPayload.prepare(candidate).digest != originalDigest,
                      "Changed semantic field did not change digest")
        }
    }

    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("independent reference vector", referenceVector),
            ("normalized identity and unordered principal sets", normalizedIdentity),
            ("ledger principal key matches scope equivalence", principalKey),
            ("prepared remember defaults and field coverage", rememberFields),
            ("all scope and provenance changes conflict", scopeAndProvenance),
            ("update modes and every metadata field conflict", updateFields),
            ("exact content bytes and boundary framing", exactBytes),
            ("expiration actions and omission semantics", expiration),
            ("connection targets and relation change digest", connection),
            ("invalid dynamic mutations fail closed", invalidMutations),
            ("unsupported versions and tools fail decoding", unsupportedVersions),
            ("caller digest cannot override native digest", ignoresCallerDigest),
            ("public receipt contains no mutation content", receiptContent),
        ]
        for (name, test) in tests {
            try test()
            print("PASS \(name)")
        }
        print("{\"tests\":\(tests.count),\"failures\":0}")
    }

    static func referenceVector() throws {
        try check(CommandLine.arguments.count == 2, "Expected independent reference digest")
        let original = try request()
        let result = try MemoryOperationCanonicalPayload.prepare(original)
        try check(result.digest.sha256 == CommandLine.arguments[1], "Independent golden vector mismatch")
        let decoded = try JSONDecoder().decode(MemoryOperationRequest.self,
                                              from: JSONEncoder().encode(original))
        try check(try MemoryOperationCanonicalPayload.prepare(decoded).digest == result.digest,
                  "Transport round-trip changed digest")
        for _ in 0..<100 {
            try check(try MemoryOperationCanonicalPayload.prepare(original).digest == result.digest,
                      "Repeated preparation changed digest")
        }
    }

    static func normalizedIdentity() throws {
        let original = try request()
        let permuted = try request(expectedScope: scope(principal: principal(
            groups: [firstID, secondID], scopes: ["agent", "full"], displayName: "Ignored display name")))
        try check(try MemoryOperationCanonicalPayload.prepare(original).digest ==
                  MemoryOperationCanonicalPayload.prepare(permuted).digest,
                  "Principal set ordering/duplicates or display name changed digest")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json["operationID"] = operationID.uuidString.uppercased()
        let uppercase = try JSONDecoder().decode(MemoryOperationRequest.self,
                                                from: JSONSerialization.data(withJSONObject: json))
        try check(try MemoryOperationCanonicalPayload.prepare(uppercase).digest ==
                  MemoryOperationCanonicalPayload.prepare(original).digest,
                  "UUID case changed digest")
        let composed = try request(expectedScope: scope(principal: principal(scopes: ["caf\u{00e9}"])))
        let decomposed = try request(expectedScope: scope(principal: principal(scopes: ["cafe\u{0301}"])))
        try check(composed.expectedScope.principal == decomposed.expectedScope.principal,
                  "Fixture principal equality changed")
        try check(try MemoryOperationCanonicalPayload.prepare(composed).digest ==
                  MemoryOperationCanonicalPayload.prepare(decomposed).digest,
                  "Equivalent principal scope Unicode changed digest")
    }

    static func principalKey() throws {
        let original = try MemoryOperationCanonicalPayload.principalKey(principal())
        let reordered = principal(groups: [firstID, secondID], scopes: ["agent", "full"], displayName: "other")
        try check(try MemoryOperationCanonicalPayload.principalKey(reordered) == original,
                  "Ledger principal key changed for equivalent binding")
        let composed = principal(scopes: ["caf\u{00e9}"])
        let decomposed = principal(scopes: ["cafe\u{0301}"])
        try check(try MemoryOperationCanonicalPayload.principalKey(composed) ==
                  MemoryOperationCanonicalPayload.principalKey(decomposed),
                  "Ledger principal key disagrees with Unicode scope equivalence")
        for binding in [principal(id: firstID), principal(id: nil), principal(kind: .user),
                        principal(groups: []), principal(scopes: []), principal(scopes: ["Full", "agent"])] {
            try check(try MemoryOperationCanonicalPayload.principalKey(binding) != original,
                      "Changed principal field did not change ledger key")
        }
        try check(original.count == 64 && original == original.lowercased(), "Invalid principal key representation")
        try check(try MemoryOperationCanonicalPayload.prepare(request()).digest.sha256 != original,
                  "Principal key and payload domains are not separated")
    }

    static func rememberFields() throws {
        let value = try prepare(.remember(RememberRequest(content: privateText)))
        guard case .remember(let prepared) = value.mutation else { throw Failure.check("Wrong prepared tool") }
        try check(Array(prepared.content.utf8) == Array(privateText.utf8), "Prepared content changed bytes")
        try check(prepared.topic == "general" && prepared.project == "global" && prepared.source == "" &&
                  prepared.importance == 0 && !prepared.isPrivate && prepared.parentID == nil &&
                  prepared.expiration == .permanent, "Prepared remember has unresolved/wrong defaults")
        let explicit = RememberRequest(content: privateText, topic: "general", project: "global",
                                       source: "", isPrivate: false, expiresInDays: 0)
        try check(try digest(.remember(explicit)) == value.digest.sha256, "Static defaults not normalized")
        let candidates: [RememberRequest] = [
            RememberRequest(content: privateText + "!"),
            RememberRequest(content: privateText, topic: ""),
            RememberRequest(content: privateText, project: ""),
            RememberRequest(content: privateText, source: "source"),
            RememberRequest(content: privateText, importance: 1),
            RememberRequest(content: privateText, isPrivate: true),
            RememberRequest(content: privateText, parentId: firstID),
            RememberRequest(content: privateText, expiresInDays: 1),
        ]
        try changed(request(), candidates.map { try request(.remember($0)) })
    }

    static func scopeAndProvenance() throws {
        let original = try request()
        let scopes = try [scope(store: firstID), scope(principal: principal(id: firstID)),
            scope(principal: principal(id: nil)), scope(principal: principal(kind: .user)),
            scope(principal: principal(groups: [firstID])), scope(principal: principal(scopes: ["full"]))]
        let sources = try [provenance(host: "claude"), provenance(session: "session-2"),
            provenance(run: "run-2"), provenance(start: 18), provenance(end: 92),
            provenance(excerpt: String(repeating: "b", count: 64))]
        try changed(original, [try request(id: firstID)] + scopes.map { try request(expectedScope: $0) } +
                    sources.map { try request(provenance: $0) })
    }

    static func updateFields() throws {
        let original = try request(.update(UpdateRequest(id: firstID, append: privateText)))
        let candidates: [UpdateRequest] = [
            UpdateRequest(id: secondID, append: privateText),
            UpdateRequest(id: firstID, content: privateText),
            UpdateRequest(id: firstID, prepend: privateText),
            UpdateRequest(id: firstID, find: "old", replace: privateText),
            UpdateRequest(id: firstID, append: privateText, topic: ""),
            UpdateRequest(id: firstID, append: privateText, project: ""),
            UpdateRequest(id: firstID, append: privateText, source: ""),
            UpdateRequest(id: firstID, append: privateText, source: "provenance"),
            UpdateRequest(id: firstID, append: privateText, importance: 0),
            UpdateRequest(id: firstID, append: privateText, expiresInDays: 0),
            UpdateRequest(id: firstID, append: privateText, isPrivate: false),
        ]
        try changed(original, candidates.map { try request(.update($0)) })
        let detailed = UpdateRequest(id: firstID, find: "old", replace: "", topic: "topic", project: "project",
            source: "source", importance: 5, expiresInDays: -3, isPrivate: true)
        guard case .update(let value) = try prepare(.update(detailed)).mutation else {
            throw Failure.check("Wrong prepared update kind")
        }
        try check(value.id == firstID && value.contentEdit == .replaceOccurrences(find: "old", replace: "") &&
                  value.topic == "topic" && value.project == "project" && value.source == "source" && value.importance == 5 &&
                  value.expiration == .afterDays(-3) && value.isPrivate == true,
                  "Prepared update lost an effective field")
        try changed(request(.update(detailed)), [
            request(.update(UpdateRequest(id: firstID, find: "OLD", replace: "", topic: "topic", project: "project",
                source: "source", importance: 5, expiresInDays: -3, isPrivate: true))),
            request(.update(UpdateRequest(id: firstID, find: "old", replace: "new", topic: "topic", project: "project",
                source: "source", importance: 5, expiresInDays: -3, isPrivate: true))),
        ])
        guard case .update(let sourceOnly) = try prepare(.update(UpdateRequest(id: firstID, source: ""))).mutation else {
            throw Failure.check("Source-only update lost")
        }
        try check(sourceOnly.contentEdit == nil && sourceOnly.source == "", "Explicit empty source must remain an edit")
    }

    static func exactBytes() throws {
        let inputs = ["", " ", "x", "x\n", "x\r\n", "x\0", "\u{00e9}", "e\u{0301}"]
        var digests = Set<String>()
        for input in inputs {
            let prepared = try prepare(.update(UpdateRequest(id: firstID, append: input)))
            guard case .update(let value) = prepared.mutation, case .append(let text) = value.contentEdit else {
                throw Failure.check("Append mode lost")
            }
            try check(Array(text.utf8) == Array(input.utf8), "Append bytes changed")
            digests.insert(prepared.digest.sha256)
        }
        try check(digests.count == inputs.count, "Distinct append bytes collided")
        let a = RememberRequest(content: "ab", topic: "c")
        let b = RememberRequest(content: "a", topic: "bc")
        try check(try digest(.remember(a)) != digest(.remember(b)), "String field boundaries ambiguous")
        try check(try digest(.remember(RememberRequest(content: "a", source: "bc"))) !=
                  digest(.remember(RememberRequest(content: "ab", source: "c"))), "Separated fields ambiguous")
    }

    static func expiration() throws {
        let permanent = try digest(.remember(RememberRequest(content: "x")))
        for days in [0, -1, Int.min] {
            try check(try digest(.remember(RememberRequest(content: "x", expiresInDays: days))) == permanent,
                      "Remember nonpositive TTL not permanent")
        }
        let actions: [Int?] = [nil, 0, -1, 1, Int.min, Int.max]
        var digests = Set<String>()
        for days in actions {
            let prepared = try prepare(.update(UpdateRequest(id: firstID, topic: "x", expiresInDays: days)))
            digests.insert(prepared.digest.sha256)
            guard case .update(let value) = prepared.mutation else { throw Failure.check("Expected update") }
            let expected: MemoryOperationCanonicalPayload.Expiration? = days.map {
                $0 == 0 ? .permanent : .afterDays($0)
            }
            try check(value.expiration == expected, "TTL resolution changed relative semantics")
        }
        try check(digests.count == actions.count, "TTL omission/action/duration not distinguished")
    }

    static func connection() throws {
        let original = try request(.connect(ConnectRequest(sourceId: firstID, targetId: secondID, relation: "relates_to")))
        var candidates = try MemoryOperationCanonicalPayload.Relation.allCases.filter { $0 != .relatesTo }.map {
            try request(.connect(ConnectRequest(sourceId: firstID, targetId: secondID, relation: $0.rawValue)))
        }
        candidates.append(try request(.connect(ConnectRequest(sourceId: secondID, targetId: firstID, relation: "relates_to"))))
        candidates.append(try request(.connect(ConnectRequest(sourceId: firstID, targetId: operationID, relation: "relates_to"))))
        candidates.append(try request())
        candidates.append(try request(.update(UpdateRequest(id: firstID, topic: "relates_to"))))
        try changed(original, candidates)
        guard case .connect(let value) = try MemoryOperationCanonicalPayload.prepare(original).mutation else {
            throw Failure.check("Wrong prepared connection kind")
        }
        try check(value.sourceID == firstID && value.targetID == secondID && value.relation == .relatesTo,
                  "Prepared connection lost fields")
    }

    static func invalidMutations() throws {
        try invalid(.remember(RememberRequest(content: "")))
        for importance in [Int.min, -1, 0, 6, Int.max] {
            try invalid(.remember(RememberRequest(content: "x", importance: importance)))
        }
        for importance in [Int.min, -1, 6, Int.max] {
            try invalid(.update(UpdateRequest(id: firstID, importance: importance)))
        }
        try invalid(.update(UpdateRequest(id: firstID)))
        try invalid(.update(UpdateRequest(id: firstID, content: "x", append: "y")))
        try invalid(.update(UpdateRequest(id: firstID, append: "x", prepend: "y")))
        try invalid(.update(UpdateRequest(id: firstID, prepend: "x", find: "y", replace: "z")))
        try invalid(.update(UpdateRequest(id: firstID, find: "x")))
        try invalid(.update(UpdateRequest(id: firstID, replace: "x", topic: "y")))
        for relation in ["unknown", "", "RELATES_TO", " relates_to"] {
            try invalid(.connect(ConnectRequest(sourceId: firstID, targetId: secondID, relation: relation)))
        }
        do {
            _ = try prepare(.update(UpdateRequest(id: firstID, undelete: true)))
            throw Failure.check("Undelete was accepted")
        } catch MemoryOperationError.unsupportedTarget { }
    }

    static func unsupportedVersions() throws {
        let original = try request()
        let originalJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        var candidates: [[String: Any]] = []
        var unknownRequest = originalJSON
        unknownRequest["version"] = 2
        candidates.append(unknownRequest)
        var unknownScope = originalJSON
        var scope = unknownScope["expectedScope"] as! [String: Any]
        scope["version"] = 2
        unknownScope["expectedScope"] = scope
        candidates.append(unknownScope)
        var unknownTool = originalJSON
        var mutation = unknownTool["mutation"] as! [String: Any]
        mutation["kind"] = "forget"
        unknownTool["mutation"] = mutation
        candidates.append(unknownTool)
        for candidate in candidates {
            var refused = false
            do {
                _ = try JSONDecoder().decode(MemoryOperationRequest.self,
                    from: JSONSerialization.data(withJSONObject: candidate))
            } catch { refused = true }
            try check(refused, "Unsupported version/tool decoded")
        }
    }

    static func ignoresCallerDigest() throws {
        let original = try request()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json["payloadDigest"] = String(repeating: "0", count: 64)
        let decoded = try JSONDecoder().decode(MemoryOperationRequest.self,
                                              from: JSONSerialization.data(withJSONObject: json))
        try check(try MemoryOperationCanonicalPayload.prepare(decoded).digest ==
                  MemoryOperationCanonicalPayload.prepare(original).digest,
                  "Untrusted digest changed native digest")
    }

    static func receiptContent() throws {
        let value = try MemoryOperationCanonicalPayload.prepare(request())
        let receipt = try MemoryOperationReceipt(operationID: value.operationID,
            scope: value.expectedScope, payloadDigest: value.digest, mutation: .remember,
            outcome: .applied, memoryIDs: [firstID], committedAt: Date(timeIntervalSince1970: 1))
        let encoded = try JSONEncoder().encode(receipt)
        let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        try check(Set(json.keys) == ["version", "operationID", "scope", "payloadDigest", "mutation",
                                    "outcome", "memoryIDs", "edgeIDs", "committedAt"],
                  "Public receipt unexpectedly exposes request fields")
        try check(!String(decoding: encoded, as: UTF8.self).contains("Private fixture"),
                  "Public receipt leaked mutation text")
    }
}
