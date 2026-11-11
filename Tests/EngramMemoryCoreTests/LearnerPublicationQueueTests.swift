import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import EngramMemoryCore

@Suite("LearnerPublicationQueue", .serialized)
struct LearnerPublicationQueueTests {
    private typealias Q = LearnerPublicationQueue
    private typealias V = Q.Value
    private struct Vectors: Decodable { let version: Int; let host: String; let account: String; let vectors: [Vector] }
    private struct Vector: Decodable {
        let name: String; let kind: String; let dataBase64: String; let sha256: String
        let accepted: Bool; let canonicalBase64: String?; let candidate: String?; let prepared: String?
    }
    private func vectors() throws -> Vectors {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/LearnerPublicationQueue/v1.json")
        let bytes = try Data(contentsOf: file)
        try #require(bytes.count <= 256 * 1024)
        return try JSONDecoder().decode(Vectors.self, from: bytes)
    }
    private func vector(_ name: String) throws -> Data {
        let row = try #require(try vectors().vectors.first { $0.name == name })
        return try #require(Data(base64Encoded: row.dataBase64))
    }
    private func id(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012x", n) }
    private func candidate(_ n: Int = 1, kind: String = "company", content: String? = nil) throws -> Data {
        var row = try #require(try Q.decode(vector("candidate_" + kind)).object)
        row["operationID"] = .string(id(n)); row["candidateID"] = .string(id(n + 1000))
        if let content { row["content"] = .string(content); row["payloadSHA256"] = .string(Q.sha256(Data(content.utf8))) }
        return Q.canonical(.object(row))
    }
    private func prepared(_ candidate: Data, padding: Int = 0) throws -> Data {
        var row = Q.binding(candidate, candidate: try Q.candidate(candidate)); row["backendDigest"] = .string(String(repeating: "f", count: 64))
        return Data(repeating: 32, count: padding) + Q.canonical(.object(row))
    }
    private func receipt(_ candidate: Data, _ prepared: Data) throws -> Data {
        var row = try #require(try Q.preparedBody(prepared, candidateBytes: candidate).object)
        row["preparedBodySHA256"] = .string(Q.sha256(prepared)); row["outcome"] = .string("committed")
        row["committedIDs"] = .array([.string(id(900))]); return Q.canonical(.object(row))
    }
    private func open(_ root: URL, fault: ((String,String) throws -> Void)? = nil) throws -> Q {
        try Q(root: root.path, host: "test-host", account: "test-account", fault: fault)
    }
    /// Honor an explicit absolute TMPDIR, or own a private UUID leaf below this repository's .build.
    /// The queue still checks its original root and every ancestor; no /tmp or app-state fallback.
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let configured = ProcessInfo.processInfo.environment["TMPDIR"]
        let fallback = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build")
        let path = configured ?? fallback.path
        try #require(path.hasPrefix("/") && !path.split(separator: "/").contains(".."))
        let base = URL(fileURLWithPath: path)
        try #require(base.resolvingSymlinksInPath().path == base.standardizedFileURL.path)
        if configured == nil && !FileManager.default.fileExists(atPath: base.path) {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory)
        try #require(exists && isDirectory.boolValue)
        let root = base.appendingPathComponent("learner-queue-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Owned queue fixture cleanup failed") }
        }
        try body(root)
    }
    private func write(_ data: Data, _ file: URL) throws {
        let fd: Int32
        #if canImport(Darwin)
        fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        #else
        fd = Glibc.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        #endif
        try #require(fd >= 0)
        defer {
            #if canImport(Darwin)
            Darwin.close(fd)
            #else
            Glibc.close(fd)
            #endif
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count: Int
                #if canImport(Darwin)
                count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                #else
                count = Glibc.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                #endif
                if count < 0 && errno == EINTR { continue }; try #require(count > 0); offset += count
            }
        }
        try #require(fsync(fd) == 0)
    }
    private func refuse(_ code: String? = nil, _ body: () throws -> Void) {
        do { try body(); Issue.record("Expected queue refusal") }
        catch let error as Q.Failure { if let code { #expect(error.code == code) } }
        catch { Issue.record("Unexpected non-queue error type") }
    }
    private func stage(_ q: Q, _ c: Data) throws -> (String,Data,Data) {
        let op = try #require(try Q.candidate(c)["operationID"]?.string)
        let p = try prepared(c), r = try receipt(c,p)
        _ = try q.retainCandidate(c); _ = try q.retainPrepared(operationID: op, bytes: p)
        return (op,p,r)
    }

    @Test func portableSHA256HasIndependentKnownVectors() {
        #expect(Q.sha256(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(Q.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Q.sha256(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }
    @Test func sharedTwentySevenVectorsBindExactBytesAndCanonicalEncoding() throws {
        let file = try vectors(); #expect(file.version == 1); #expect(file.vectors.count == 27)
        #expect(Set(file.vectors.map(\.name)).count == 27)
        let lookup = Dictionary(uniqueKeysWithValues: file.vectors.map { ($0.name,$0) })
        for row in file.vectors {
            let data = try #require(Data(base64Encoded: row.dataBase64)); #expect(Q.sha256(data) == row.sha256, "Vector: \(row.name)")
            let decode: () throws -> V = {
                switch row.kind {
                case "json": return try Q.decode(data)
                case "candidate": return try Q.candidate(data)
                case "prepared":
                    let name = try #require(row.candidate), c = try #require(lookup[name])
                    let bytes = try #require(Data(base64Encoded:c.dataBase64))
                    return try Q.preparedBody(data,candidateBytes:bytes)
                case "receipt":
                    let cname = try #require(row.candidate), pname = try #require(row.prepared)
                    let c = try #require(lookup[cname]), p = try #require(lookup[pname])
                    let cb = try #require(Data(base64Encoded:c.dataBase64)), pb = try #require(Data(base64Encoded:p.dataBase64))
                    return try Q.receiptBody(data,preparedBytes:pb,candidateBytes:cb)
                default: throw Q.Failure(code:"unknown_vector_kind")
                }
            }
            if row.accepted { #expect(try Q.canonical(decode()).base64EncodedString() == row.canonicalBase64, "Vector: \(row.name)") }
            else { refuse { _ = try decode() }; #expect(row.canonicalBase64 == nil) }
        }
    }
    @Test func decoderBudgetsAndEscapedSurrogatePairsAreStrict() throws {
        #expect(try Q.decode(Data("\"\\ud83d\\ude42\"".utf8)) == .string("🙂"))
        for input in ["\u{feff}{}", "\"\\ud800\"", "\"\\udc00\"", "{\"x\":true,\"x\":1}", "[1,]", "{\"x\":1,}", "-0", "1e0", "1.0", "01", "9007199254740992"] {
            refuse { _ = try Q.decode(Data(input.utf8)) }
        }
        refuse { _ = try Q.decode(Data([0xff])) }
        refuse("json_key") { _ = try Q.decode(Data("{\"é\":0}".utf8)) }
        refuse("json_key") { _ = try Q.decode(Data("{\"\":0}".utf8)) }
        refuse("decode_budget") { _ = try Q.decode(Data((String(repeating:"[",count:17)+"0"+String(repeating:"]",count:17)).utf8)) }
        refuse("array_bound") { _ = try Q.decode(Data(("["+Array(repeating:"0",count:1025).joined(separator:",")+"]").utf8)) }
        let largeObject = "{"+(0..<129).map { "\"k\($0)\":0" }.joined(separator:",")+"}"
        refuse("object_bound") { _ = try Q.decode(Data(largeObject.utf8)) }
        let thousand = "["+Array(repeating:"0",count:1024).joined(separator:",")+"]"
        refuse("decode_budget") { _ = try Q.decode(Data(("["+Array(repeating:thousand,count:8).joined(separator:",")+"]").utf8)) }
    }
    @Test func emptyNamespaceIsNotCompletionAndUnavailableAdapterCannotMarkDispatch() throws {
        try withRoot { root in
            let q = try open(root); defer { q.close() }
            let recovered = try q.recover(); #expect(recovered.records.isEmpty); #expect(!recovered.sessionComplete)
            #expect(recovered.accounting.values.reduce(0,+) == 0)
            let adapter = Q.UnavailableHostedAdapter()
            refuse("hosted_adapter_unavailable") { try adapter.prepare() }
            refuse("hosted_adapter_unavailable") { try adapter.apply() }
            refuse("hosted_adapter_unavailable") { try adapter.lookup() }
            #expect(try FileManager.default.contentsOfDirectory(atPath:root.path).sorted() == [".owner.lock","namespace.json"])
        }
    }
    @Test func allFiveDestinationsRetainWithHeldLocalRefusingPreparation() throws {
        try withRoot { root in
            let q = try open(root); defer { q.close() }
            for (index,kind) in ["company","team","personal","private","held"].enumerated() {
                let c = try candidate(index + 1,kind:kind), row = try q.retainCandidate(c)
                #expect(row.state == (kind == "held" ? "heldLocal" : "pending"))
                #expect(row.candidateBytes == c)
                if kind == "held" { refuse("held_local") { _ = try q.retainPrepared(operationID:row.operationID,bytes:prepared(c)) } }
            }
            let r = try q.recover(); #expect(r.accounting["retained"] == 5); #expect(r.accounting["heldLocal"] == 1); #expect(r.accounting["pending"] == 4)
        }
    }
    @Test func stateTransitionsReopenWithExactBodiesAndReplayWithoutNewFiles() throws {
        try withRoot { root in
            let c = try vector("candidate_company"), p = try vector("prepared_company"), r = try vector("receipt_company")
            let op = try #require(try Q.candidate(c)["operationID"]?.string)
            var q = try open(root)
            #expect(try q.retainCandidate(c).state == "pending"); q.close(); q = try open(root)
            #expect(try q.retainPrepared(operationID:op,bytes:p).preparedBytes == p); q.close(); q = try open(root)
            #expect(try q.recordDispatchStarted(operationID:op).state == "dispatchedUnknown"); q.close(); q = try open(root)
            #expect(try q.recordUncertain(operationID:op,reason:"lostResponse").state == "dispatchedUnknown"); q.close(); q = try open(root)
            let final = try q.retainReceipt(operationID:op,bytes:r); q.close(); q = try open(root); defer { q.close() }
            #expect(final.state == "acknowledged"); #expect(final.preparedBytes == p); #expect(final.receiptBytes == r)
            #expect(final.backendDigest != final.preparedSHA256); #expect(final.preparedSHA256 == Q.sha256(p))
            let before = try FileManager.default.contentsOfDirectory(atPath:root.path).sorted()
            #expect(try q.retainCandidate(c) == final); #expect(try q.retainPrepared(operationID:op,bytes:p) == final)
            #expect(try q.recordDispatchStarted(operationID:op) == final); #expect(try q.retainReceipt(operationID:op,bytes:r) == final)
            refuse("stage_missing") { _ = try q.recordUncertain(operationID:op,reason:"unknown") }
            #expect(try FileManager.default.contentsOfDirectory(atPath:root.path).sorted() == before)
            #expect(try q.recover().accounting["acknowledged"] == 1)
        }
    }
    @Test func stageAndExactByteConflictsCannotRetargetTheOperation() throws {
        try withRoot { root in
            let q = try open(root); defer { q.close() }; let c = try candidate(), p = try prepared(c), op = id(1)
            refuse("stage_missing") { _ = try q.recordDispatchStarted(operationID:op) }
            _ = try q.retainCandidate(c)
            refuse("candidate_conflict") { _ = try q.retainCandidate(Data(" ".utf8)+c) }
            refuse("stage_missing") { _ = try q.retainReceipt(operationID:op,bytes:receipt(c,p)) }
            _ = try q.retainPrepared(operationID:op,bytes:p)
            refuse("prepared_conflict") { _ = try q.retainPrepared(operationID:op,bytes:Data(" ".utf8)+p) }
            _ = try q.recordDispatchStarted(operationID:op)
            _ = try q.recordUncertain(operationID:op,reason:"cancelled")
            #expect(try q.recordUncertain(operationID:op,reason:"cancelled").state == "dispatchedUnknown")
            refuse("uncertain_conflict") { _ = try q.recordUncertain(operationID:op,reason:"interrupted") }
            let r = try receipt(c,p); _ = try q.retainReceipt(operationID:op,bytes:r)
            refuse("receipt_conflict") { _ = try q.retainReceipt(operationID:op,bytes:Data(" ".utf8)+r) }
            #expect(try q.recover().records.first?.candidateBytes == c)
        }
    }
    @Test func frozenCandidateIdentityAndNamespaceAreNotRebound() throws {
        try withRoot { root in
            let q = try open(root); defer { q.close() }; let c = try candidate(); _ = try q.retainCandidate(c)
            var next = try #require(try Q.decode(c).object); next["operationID"] = .string(id(2))
            refuse("candidate_rebound") { _ = try q.retainCandidate(Q.canonical(.object(next))) }
            next["candidateID"] = .string(id(1002)); next["account"] = .string("other-account")
            refuse("candidate_namespace") { _ = try q.retainCandidate(Q.canonical(.object(next))) }
            q.close()
            refuse("namespace_binding") { _ = try Q.openOwnedNamespace(root:root.path,host:"test-host",account:"other-account") }
            let reopened = try open(root); defer { reopened.close() }; #expect(try reopened.recover().records.count == 1)
        }
    }
    @Test func everyPreparedAndReceiptBindingFieldIsChecked() throws {
        let c = try candidate(), p = try prepared(c), good = try #require(try Q.decode(p).object)
        for key in good.keys.sorted() where key != "backendDigest" {
            var changed = good; changed[key] = .string("wrong")
            refuse { _ = try Q.preparedBody(Q.canonical(.object(changed)),candidateBytes:c) }
        }
        var extra = good; extra["authorized"] = .bool(true)
        refuse("record_fields") { _ = try Q.preparedBody(Q.canonical(.object(extra)),candidateBytes:c) }
        let r = try #require(try Q.decode(receipt(c,p)).object)
        for key in r.keys.sorted() {
            var changed = r; changed[key] = .string("wrong")
            refuse { _ = try Q.receiptBody(Q.canonical(.object(changed)),preparedBytes:p,candidateBytes:c) }
        }
    }
    @Test func oneUnknownDispatchHoldsSlotUntilAnExactHistoricalReceipt() throws {
        try withRoot { root in
            let q = try open(root); let a = try candidate(1), b = try candidate(2)
            let (first,_,ack) = try stage(q,a); let (second,_,_) = try stage(q,b)
            _ = try q.recordDispatchStarted(operationID:first); _ = try q.recordUncertain(operationID:first,reason:"unknown")
            refuse("publication_slot") { _ = try q.recordDispatchStarted(operationID:second) }
            #expect(!FileManager.default.fileExists(atPath:root.appendingPathComponent(second+".dispatch.json").path))
            q.close(); let reopened = try open(root); defer { reopened.close() }
            refuse("publication_slot") { _ = try reopened.recordDispatchStarted(operationID:second) }
            _ = try reopened.recordDispatchStarted(operationID:first)
            _ = try reopened.retainReceipt(operationID:first,bytes:ack)
            #expect(try reopened.recordDispatchStarted(operationID:second).state == "dispatchedUnknown")
        }
    }
    @Test func contradictoryTwoUnknownDispatchesRefuseOnReopen() throws {
        try withRoot { root in
            let q = try open(root); _ = try stage(q,candidate(1)); _ = try stage(q,candidate(2))
            _ = try q.recordDispatchStarted(operationID:id(1)); q.close()
            let wrapped = try Data(contentsOf:root.appendingPathComponent(id(2)+".prepared.json"))
            let c = try candidate(2), p = try prepared(c)
            let data = Q.canonical(.object(["version":.number(1),"stage":.string("dispatch"),"operationID":.string(id(2)),
                "priorSHA256":.string(Q.sha256(wrapped)),"preparedBodySHA256":.string(Q.sha256(p)),"backendDigest":.string(String(repeating:"f",count:64))]))
            try write(data,root.appendingPathComponent(id(2)+".dispatch.json"))
            refuse("publication_slot") { _ = try open(root) }
        }
    }
    @Test func corruptChainAndUnknownFieldsRefuseReopen() throws {
        try withRoot { root in
            let q = try open(root); let (op,_,_) = try stage(q,candidate()); q.close()
            let file = root.appendingPathComponent(op+".prepared.json")
            var row = try #require(try Q.decode(Data(contentsOf:file)).object); row["priorSHA256"] = .string(String(repeating:"0",count:64))
            try Q.canonical(.object(row)).write(to:file)
            refuse("stage_chain") { _ = try open(root) }
        }
        try withRoot { root in
            let q = try open(root); _ = try q.retainCandidate(candidate()); q.close()
            let file = root.appendingPathComponent(id(1)+".candidate.json")
            var row = try #require(try Q.decode(Data(contentsOf:file)).object); row["currentAuthority"] = .bool(true)
            try Q.canonical(.object(row)).write(to:file)
            refuse("record_fields") { _ = try open(root) }
        }
    }
    @Test func observedHistoryDeletionOrChangeRefusesOnTheLiveOwner() throws {
        try withRoot { root in
            let q = try open(root); defer { q.close() }; _ = try q.retainCandidate(candidate())
            try FileManager.default.removeItem(at:root.appendingPathComponent(id(1)+".candidate.json"))
            refuse("observed_history_changed") { _ = try q.recover() }
        }
        try withRoot { root in
            let q = try open(root); defer { q.close() }; let c = try candidate(); _ = try q.retainCandidate(c)
            try (Data(" ".utf8)+c).write(to:root.appendingPathComponent(id(1)+".candidate.json"))
            refuse("observed_history_changed") { _ = try q.recover() }
        }
    }
    @Test func ownerLockIsExclusiveAndCloseCannotReleaseAnotherOwner() throws {
        try withRoot { root in
            let first = try open(root)
            refuse("namespace_busy") { _ = try open(root) }
            first.close(); let second = try open(root); defer { second.close() }; first.close()
            refuse("namespace_busy") { _ = try open(root) }
            refuse("queue_unavailable") { _ = try first.recover() }
            #expect(try second.recover().accounting["retained"] == 0)
        }
    }
    @Test func symlinkRootAncestorAndMemberAreRefused() throws {
        try withRoot { parent in
            let actual = parent.appendingPathComponent("actual"), link = parent.appendingPathComponent("link")
            try FileManager.default.createDirectory(at:actual,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            try FileManager.default.createSymbolicLink(at:link,withDestinationURL:actual)
            refuse { _ = try open(link) }
            let nested = actual.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            refuse { _ = try open(link.appendingPathComponent("nested")) }
            try FileManager.default.removeItem(at:nested)
            let q = try open(actual); q.close()
            let external = parent.appendingPathComponent("external"); try write(try candidate(),external)
            try FileManager.default.createSymbolicLink(at:actual.appendingPathComponent(id(1)+".candidate.json"),withDestinationURL:external)
            refuse { _ = try open(actual) }
        }
    }
    @Test func unsafeModeHardlinkAndReplacedRootCannotProvideCustody() throws {
        try withRoot { root in
            let q = try open(root); _ = try q.retainCandidate(candidate()); q.close()
            let file = root.appendingPathComponent(id(1)+".candidate.json")
            try #require(chmod(file.path,mode_t(0o644)) == 0)
            refuse("unsafe_file") { _ = try open(root) }
            try #require(chmod(file.path,mode_t(0o600)) == 0)
            let extra = root.appendingPathComponent(id(2)+".candidate.json")
            try #require(link(file.path,extra.path) == 0)
            refuse("unsafe_file") { _ = try open(root) }
        }
        try withRoot { parent in
            let root = parent.appendingPathComponent("root"), retired = parent.appendingPathComponent("retired")
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            let q = try open(root); defer { q.close() }; try FileManager.default.moveItem(at:root,to:retired)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            refuse("root_changed") { _ = try q.recover() }
        }
    }
    @Test func everyPersistenceFaultPoisonsWithoutDeletingTheCreatedStage() throws {
        for point in ["before_write","after_write","file_fsync","directory_fsync"] {
            try withRoot { root in
                let q = try open(root,fault:{ found,name in if found == point && name.hasSuffix(".candidate.json") { throw Q.Failure(code:"injected") } })
                let c = try candidate()
                refuse("injected") { _ = try q.retainCandidate(c) }
                refuse("queue_unavailable") { _ = try q.recover() }; q.close()
                let file = root.appendingPathComponent(id(1)+".candidate.json"); #expect(FileManager.default.fileExists(atPath:file.path))
                if point == "before_write" { refuse("record_bound") { _ = try open(root) } }
                else {
                    let reopened = try open(root); defer { reopened.close() }
                    #expect(try reopened.recover().records.first?.candidateBytes == c)
                }
            }
        }
    }
    @Test func partialExistingStageIsPreservedAndRefusedWithoutRepair() throws {
        try withRoot { root in
            let q = try open(root); q.close(); let file = root.appendingPathComponent(id(1)+".candidate.json")
            let prefix = Data(try candidate().prefix(7)); try write(prefix,file)
            refuse { _ = try open(root) }
            #expect(try Data(contentsOf:file) == prefix)
        }
    }
    @Test func reopenRequiresRealFileAndDirectoryDurability() throws {
        for point in ["reopen_file_fsync","reopen_directory_fsync"] {
            try withRoot { root in
                let q = try open(root); _ = try q.retainCandidate(candidate()); q.close()
                refuse("injected") { _ = try open(root,fault:{ found,_ in if found == point { throw Q.Failure(code:"injected") } }) }
                let reopened = try open(root); defer { reopened.close() }; #expect(try reopened.recover().records.count == 1)
            }
        }
    }
    @Test func stageBodyAndContentCapsRefuseWithoutAddingARecord() throws {
        try withRoot { root in
            let q = try open(root); defer { q.close() }
            refuse("record_bound") { _ = try q.retainCandidate(Data(repeating:32,count:Q.maxRecord+1)) }
            refuse("content_bound") { _ = try q.retainCandidate(candidate(content:String(repeating:"a",count:32769))) }
            let c = try candidate(); _ = try q.retainCandidate(c)
            refuse("record_bound") { _ = try q.retainPrepared(operationID:id(1),bytes:Data(repeating:32,count:Q.maxBody+1)) }
            #expect(try q.recover().accounting["retained"] == 1)
            #expect(try FileManager.default.contentsOfDirectory(atPath:root.path).count == 3)
        }
    }
    @Test func twoHundredFiftySixRetainedOperationsAreTheHardCapacity() throws {
        try withRoot { root in
            let q = try open(root); defer { q.close() }
            // Direct fixture writes avoid quadratic append/reload cost, but reopen validates every actual record.
            q.close()
            for n in 1...256 { try write(try candidate(n),root.appendingPathComponent(id(n)+".candidate.json")) }
            let reopened = try open(root); defer { reopened.close() }
            #expect(try reopened.recover().records.count == 256)
            refuse("operation_bound") { _ = try reopened.retainCandidate(candidate(257)) }
            #expect(try reopened.recover().accounting["retained"] == 256)
        }
    }
    @Test func aggregateByteCapIsEnforcedOnActualFilesBeforeDecodingThem() throws {
        try withRoot { root in
            let q = try open(root); q.close()
            // Each candidate is itself valid and within 128 KiB. The metadata makes
            // 256 exact 128 KiB files exceed the 32 MiB aggregate, independently of record validity.
            for n in 1...256 {
                let c = try candidate(n), padded = Data(repeating:32,count:Q.maxRecord-c.count)+c
                try write(padded,root.appendingPathComponent(id(n)+".candidate.json"))
            }
            refuse("aggregate_bound") { _ = try open(root) }
            #expect(try FileManager.default.contentsOfDirectory(atPath:root.path).count == 258)
        }
    }
    @Test func enumerationStopsAtEntryCapBeforeAnyInvalidStageBodyIsRead() throws {
        try withRoot { root in
            let q = try open(root); q.close()
            for n in 1...256 {
                for stage in ["candidate","prepared","dispatch","uncertain","receipt"] {
                    try write(Data(),root.appendingPathComponent(id(n)+"."+stage+".json"))
                }
            }
            try write(Data(),root.appendingPathComponent(id(257)+".candidate.json"))
            refuse("entry_bound") { _ = try open(root) }
        }
    }
    @Test func unknownFilenameAndNonemptyLockRefuseWithoutDeletingEvidence() throws {
        try withRoot { root in
            let q = try open(root); q.close(); let foreign = root.appendingPathComponent("unexpected")
            try write(Data([1]),foreign); refuse("filename") { _ = try open(root) }; #expect(FileManager.default.fileExists(atPath:foreign.path))
        }
        try withRoot { root in
            let q = try open(root); q.close(); let lock = root.appendingPathComponent(".owner.lock")
            try Data([1]).write(to:lock); refuse("lock_content") { _ = try open(root) }; #expect(try Data(contentsOf:lock) == Data([1]))
        }
    }
    @Test func hostileFIFOIsRefusedBeforeAnyBlockingMemberRead() throws {
        try withRoot { root in
            let q = try open(root); q.close()
            let file = root.appendingPathComponent(id(1)+".candidate.json")
            try #require(mkfifo(file.path,mode_t(0o600)) == 0)
            refuse("unsafe_file") { _ = try open(root) }
            var st = stat(); try #require(lstat(file.path,&st) == 0)
            #expect(st.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO))
        }
    }
    @Test func localCloseUncertaintyPoisonsAndNeverClaimsTransportSettlement() throws {
        try withRoot { root in
            var armed = false
            var observed = 0
            let q = try open(root,fault:{ point,_ in
                if armed && point == "descriptor_close" { observed += 1; throw Q.Failure(code:"injected_close_failure") }
            })
            _ = try q.retainCandidate(candidate())
            armed = true
            refuse("descriptor_close_uncertain") { _ = try q.recover() }
            #expect(observed > 0)
            refuse("queue_unavailable") { _ = try q.retainCandidate(candidate(2)) }
            #expect(q.close() == .uncertain)
            let before = observed
            #expect(q.close() == .uncertain)
            #expect(observed == before) // No numeric descriptor retry after uncertain close.
            armed = false
            let reopened = try open(root)
            #expect(try reopened.recover().records.count == 1)
            #expect(reopened.close() == .originalsClosed)
        }
    }
}
