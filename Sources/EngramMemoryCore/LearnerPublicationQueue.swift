import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Inactive, local byte custody only. No method establishes current authority,
/// authenticates a backend, dispatches a request, or certifies session completion.
/// A coherent rewrite by the same OS user across reopen requires an external
/// authenticity anchor to detect; this local queue does not invent one.
final class LearnerPublicationQueue {
    struct Failure: Error, Equatable { let code: String }
    indirect enum Value: Equatable, Sendable {
        case object([String: Value]), array([Value]), string(String), number(UInt64), bool(Bool), null
        subscript(_ key: String) -> Value? { if case .object(let row) = self { return row[key] }; return nil }
        var string: String? { if case .string(let text) = self { return text }; return nil }
        var object: [String: Value]? { if case .object(let row) = self { return row }; return nil }
        var array: [Value]? { if case .array(let rows) = self { return rows }; return nil }
    }
    struct Record: Equatable {
        let operationID: String
        let state: String
        let candidateBytes: Data
        let preparedBytes: Data?
        let receiptBytes: Data?
        let candidateSHA256: String
        let preparedSHA256: String?
        let receiptSHA256: String?
        let backendDigest: String?
        let destination: Value
    }
    struct Recovery {
        let records: [Record]
        let accounting: [String: Int]
        let sessionComplete = false
    }
    /// Only local descriptor close results. Neither case says that a transport
    /// operation has settled. Uncertainty is sticky and never retried by fd number.
    enum LocalCloseOutcome: Equatable { case originalsClosed, uncertain }
    struct UnavailableHostedAdapter {
        func prepare() throws -> Never { throw Failure(code: "hosted_adapter_unavailable") }
        func apply() throws -> Never { throw Failure(code: "hosted_adapter_unavailable") }
        func lookup() throws -> Never { throw Failure(code: "hosted_adapter_unavailable") }
    }
    static let maxRecord = 128 * 1024
    static let maxBody = 64 * 1024
    static let maxTotal = 32 * 1024 * 1024
    static let maxOperations = 256
    static let maxEntries = 1282
    static let maxInteger: UInt64 = 9_007_199_254_740_991
    private static let stages = Set(["candidate", "prepared", "dispatch", "uncertain", "receipt"])
    private static let states = ["heldLocal", "pending", "prepared", "dispatchedUnknown", "acknowledged"]
    private let mutex = NSLock()
    private let root: String
    private let host: String
    private let account: String
    private let fault: ((String, String) throws -> Void)?
    private var rootFD: Int32 = -1
    private var lockFD: Int32 = -1
    private var rootIdentity: Identity?
    private var lockIdentity: Identity?
    private var closed = false
    private var poisoned = false
    private var descriptorCloseUncertain = false
    private var total = 0
    private var observed: [String: Data] = [:]

    private static func require(_ condition: Bool, _ code: String = "invalid_record") throws {
        if !condition { throw Failure(code: code) }
    }

    // A bounded byte parser avoids Foundation's duplicate-key and number coercions.
    private struct Parser {
        let bytes: [UInt8]
        var offset = 0
        var nodes = 0
        mutating func space() { while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
        mutating func take(_ byte: UInt8) throws {
            try require(offset < bytes.count && bytes[offset] == byte, "json_syntax"); offset += 1
        }
        mutating func hex() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 {
                try require(offset < bytes.count, "json_escape")
                let b = bytes[offset]; offset += 1
                let digit: UInt32
                switch b { case 48...57: digit = UInt32(b - 48); case 65...70: digit = UInt32(b - 55)
                case 97...102: digit = UInt32(b - 87); default: throw Failure(code: "json_escape") }
                value = value * 16 + digit
            }
            return value
        }
        mutating func string() throws -> String {
            try take(34)
            var output: [UInt8] = []
            while offset < bytes.count {
                let b = bytes[offset]; offset += 1
                if b == 34 {
                    guard let result = String(bytes: output, encoding: .utf8) else { throw Failure(code: "utf8") }
                    return result
                }
                try require(b >= 32, "json_string")
                if b != 92 { output.append(b); continue }
                try require(offset < bytes.count, "json_escape")
                let escape = bytes[offset]; offset += 1
                switch escape {
                case 34, 47, 92: output.append(escape)
                case 98: output.append(8)
                case 102: output.append(12)
                case 110: output.append(10)
                case 114: output.append(13)
                case 116: output.append(9)
                case 117:
                    var point = try hex()
                    if (0xD800...0xDBFF).contains(point) {
                        try take(92); try take(117)
                        let low = try hex()
                        try require((0xDC00...0xDFFF).contains(low), "json_surrogate")
                        point = 0x10000 + (point - 0xD800) * 1024 + low - 0xDC00
                    } else { try require(!(0xDC00...0xDFFF).contains(point), "json_surrogate") }
                    guard let scalar = Unicode.Scalar(point) else { throw Failure(code: "json_surrogate") }
                    output.append(contentsOf: String(scalar).utf8)
                default: throw Failure(code: "json_escape")
                }
            }
            throw Failure(code: "json_truncated")
        }
        mutating func value(_ depth: Int = 0) throws -> Value {
            try require(depth <= 16 && nodes < 8192, "decode_budget"); nodes += 1; space()
            try require(offset < bytes.count, "json_truncated")
            let b = bytes[offset]
            if b == 34 { return .string(try string()) }
            if b == 123 {
                offset += 1; space(); var row: [String: Value] = [:]
                if offset < bytes.count && bytes[offset] == 125 { offset += 1; return .object(row) }
                while true {
                    try require(row.count < 128, "object_bound"); space()
                    let key = try string()
                    try require((1...128).contains(key.utf8.count) && key.utf8.allSatisfy { (32...126).contains($0) }, "json_key")
                    try require(row[key] == nil, "duplicate_key")
                    space(); try take(58); row[key] = try value(depth + 1); space()
                    try require(offset < bytes.count, "json_truncated")
                    let end = bytes[offset]; offset += 1
                    if end == 125 { return .object(row) }; try require(end == 44, "json_object")
                }
            }
            if b == 91 {
                offset += 1; space(); var items: [Value] = []
                if offset < bytes.count && bytes[offset] == 93 { offset += 1; return .array(items) }
                while true {
                    try require(items.count < 1024, "array_bound"); items.append(try value(depth + 1)); space()
                    try require(offset < bytes.count, "json_truncated")
                    let end = bytes[offset]; offset += 1
                    if end == 93 { return .array(items) }; try require(end == 44, "json_array")
                }
            }
            for (word, result) in [("true", Value.bool(true)), ("false", .bool(false)), ("null", .null)] {
                let token = Array(word.utf8)
                if bytes.count - offset >= token.count && Array(bytes[offset..<(offset + token.count)]) == token {
                    offset += token.count; return result
                }
            }
            try require((48...57).contains(b), "json_number")
            let start = offset
            var number: UInt64 = 0
            while offset < bytes.count && (48...57).contains(bytes[offset]) {
                try require(offset - start < 16, "json_integer")
                number = number * 10 + UInt64(bytes[offset] - 48); offset += 1
            }
            try require((offset - start == 1 || b != 48) && number <= maxInteger, "json_integer")
            return .number(number)
        }
    }
    static func decode(_ data: Data, limit: Int = maxRecord) throws -> Value {
        try require(!data.isEmpty && data.count <= limit, "record_bound")
        try require(String(data: data, encoding: .utf8) != nil, "utf8")
        var parser = Parser(bytes: Array(data)); let value = try parser.value(); parser.space()
        try require(parser.offset == data.count, "json_trailing"); return value
    }
    static func canonical(_ value: Value) -> Data {
        var bytes: [UInt8] = []
        func string(_ text: String) {
            bytes.append(34)
            for scalar in text.unicodeScalars {
                switch scalar.value {
                case 34: bytes += [92, 34]; case 92: bytes += [92, 92]
                case 8: bytes += [92, 98]; case 12: bytes += [92, 102]; case 10: bytes += [92, 110]
                case 13: bytes += [92, 114]; case 9: bytes += [92, 116]
                case 0..<32:
                    bytes += Array(String(format: "\\u%04x", scalar.value).utf8)
                default: bytes += String(scalar).utf8
                }
            }
            bytes.append(34)
        }
        func emit(_ item: Value) {
            switch item {
            case .object(let row):
                bytes.append(123)
                for (index, key) in row.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }).enumerated() {
                    if index > 0 { bytes.append(44) }; string(key); bytes.append(58); emit(row[key]!)
                }
                bytes.append(125)
            case .array(let items):
                bytes.append(91)
                for (index, child) in items.enumerated() { if index > 0 { bytes.append(44) }; emit(child) }
                bytes.append(93)
            case .string(let text): string(text)
            case .number(let n): bytes += String(n).utf8
            case .bool(let flag): bytes += (flag ? "true" : "false").utf8
            case .null: bytes += "null".utf8
            }
        }
        emit(value); return Data(bytes)
    }
    static func sha256(_ data: Data) -> String {
        // Portable SHA-256: the core target has no crypto package dependency.
        let constants: [UInt32] = [0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
            0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
            0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
            0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
            0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
            0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
            0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
            0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
        func r(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var bytes = Array(data); let bits = UInt64(bytes.count) * 8
        bytes.append(0x80); while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: bits >> shift)) }
        var h: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 { for j in 0..<4 { w[i] = (w[i] << 8) | UInt32(bytes[offset + i * 4 + j]) } }
            for i in 16..<64 {
                let a = w[i - 15], b = w[i - 2]
                w[i] = w[i - 16] &+ (r(a,7) ^ r(a,18) ^ (a >> 3)) &+ w[i - 7] &+ (r(b,17) ^ r(b,19) ^ (b >> 10))
            }
            var a=h[0], b=h[1], c=h[2], d=h[3], e=h[4], f=h[5], g=h[6], x=h[7]
            for i in 0..<64 {
                let t1 = x &+ (r(e,6) ^ r(e,11) ^ r(e,25)) &+ ((e & f) ^ (~e & g)) &+ constants[i] &+ w[i]
                let t2 = (r(a,2) ^ r(a,13) ^ r(a,22)) &+ ((a & b) ^ (a & c) ^ (b & c))
                x=g; g=f; f=e; e=d &+ t1; d=c; c=b; b=a; a=t1 &+ t2
            }
            for (i, value) in [a,b,c,d,e,f,g,x].enumerated() { h[i] = h[i] &+ value }
        }
        return h.map { String(format: "%08x", $0) }.joined()
    }
    private static func fields(_ value: Value, _ names: [String]) throws -> [String: Value] {
        guard case .object(let row) = value, Set(row.keys) == Set(names) else { throw Failure(code: "record_fields") }; return row
    }
    private static func identifier(_ value: Value?) throws {
        guard let value, case .string(let text) = value else { throw Failure(code: "identifier") }
        try require((1...128).contains(text.utf8.count) && text.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [46,95,58,45].contains($0)
        }, "identifier")
    }
    private static func uuid(_ value: Value?) throws {
        guard let value, case .string(let text) = value else { throw Failure(code: "uuid") }
        let bytes = Array(text.utf8)
        try require(bytes.count == 36 && bytes.enumerated().allSatisfy { i,b in
            [8,13,18,23].contains(i) ? b == 45 : ((48...57).contains(b) || (97...102).contains(b))
        }, "uuid")
    }
    private static func digest(_ value: Value?) throws {
        guard let value, case .string(let text) = value else { throw Failure(code: "digest") }
        try require(text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }, "digest")
    }
    private static func integer(_ value: Value?, minimum: UInt64 = 0) throws {
        guard let value, case .number(let n) = value, n >= minimum, n <= maxInteger else { throw Failure(code: "integer") }
    }
    private static func uniqueIDs(_ value: Value?, minimum: Int = 0, uuids: Bool = false) throws {
        guard let value, case .array(let items) = value else { throw Failure(code: "list_bound") }
        try require((minimum...32).contains(items.count), "list_bound")
        var seen = Set<String>()
        for item in items {
            if uuids { try uuid(item) } else { try identifier(item) }
            try require(seen.insert(item.string!).inserted, "duplicate_id")
        }
    }
    private static func destination(_ value: Value) throws {
        guard let kind = value["kind"]?.string else { throw Failure(code: "destination") }
        switch kind {
        case "heldLocal":
            let row = try fields(value, ["kind","storeID","reason"]); try identifier(row["storeID"])
            try require(["incomplete","restricted","unknownSource","unsupported"].contains(row["reason"]?.string ?? ""), "hold_reason")
        case "privateLocal":
            let row = try fields(value, ["kind","storeID","principalID"])
            for key in ["storeID","principalID"] { try identifier(row[key]) }
        case "personal":
            let row = try fields(value, ["kind","backend","resourceID","graphID","principalID","policyID"])
            try require(["native","hosted"].contains(row["backend"]?.string ?? ""), "personal_backend")
            for key in ["resourceID","graphID","principalID","policyID"] { try identifier(row[key]) }
        case "company", "team":
            let keys = ["kind","resourceID","graphID","principalID","policyID","employeeID","clientID","qualificationDigest","membershipGeneration","grantGeneration","capabilityGeneration"]
            let row = try fields(value, keys + (kind == "team" ? ["audienceID"] : []))
            for key in ["resourceID","graphID","principalID","policyID","employeeID","clientID"] { try identifier(row[key]) }
            if kind == "team" { try identifier(row["audienceID"]) }; try digest(row["qualificationDigest"])
            for key in ["membershipGeneration","grantGeneration","capabilityGeneration"] { try integer(row[key], minimum: 1) }
        default: throw Failure(code: "destination")
        }
    }
    static func candidate(_ data: Data) throws -> Value {
        let value = try decode(data)
        let row = try fields(value, ["version","stage","host","account","sessionID","candidateID","operationID","mutation","content","payloadSHA256","coverageDigest","coverageComplete","evidence","privateFloor","audienceCeiling","destination"])
        try require(row["version"] == .number(1) && row["stage"] == .string("candidate") && row["mutation"] == .string("remember"))
        try identifier(row["host"]); try identifier(row["account"])
        for key in ["sessionID","candidateID","operationID"] { try uuid(row[key]) }
        guard let content = row["content"]?.string else { throw Failure(code: "content") }
        try require((1...(32 * 1024)).contains(content.utf8.count), "content_bound")
        try digest(row["payloadSHA256"]); try digest(row["coverageDigest"])
        try require(row["payloadSHA256"] == .string(sha256(Data(content.utf8))), "payload_hash")
        guard let coverage = row["coverageComplete"], let floor = row["privateFloor"],
              case .bool(let complete) = coverage, case .bool(let privateFloor) = floor else { throw Failure(code: "boolean") }
        guard let evidence = row["evidence"]?.array, evidence.count <= 32 else { throw Failure(code: "evidence_bound") }
        var seen = Set<String>()
        for item in evidence {
            let fields = try Self.fields(item, ["id","revision","digest"])
            try identifier(fields["id"]); try identifier(fields["revision"]); try digest(fields["digest"])
            try require(seen.insert(fields["id"]!.string!).inserted, "duplicate_evidence")
        }
        try uniqueIDs(row["audienceCeiling"]); let target = row["destination"]!
        try destination(target); let kind = target["kind"]!.string!
        try require(!privateFloor || ["privateLocal","heldLocal"].contains(kind), "private_floor")
        try require(complete || kind == "heldLocal", "incomplete_hold")
        let shared = ["company","team"].contains(kind) || (kind == "personal" && target["backend"] == .string("hosted"))
        try require(!shared || !evidence.isEmpty, "evidence_hold")
        if ["company","team"].contains(kind) { try require(row["audienceCeiling"]!.array!.contains(target["graphID"]!), "audience_ceiling") }
        return value
    }
    static func binding(_ data: Data, candidate value: Value) -> [String: Value] {
        ["version":.number(1),"protocol":.string("local-custody-v1"),"operationID":value["operationID"]!,
         "candidateSHA256":.string(sha256(data)),"destination":value["destination"]!,"payloadSHA256":value["payloadSHA256"]!,
         "coverageDigest":value["coverageDigest"]!,"derivationSHA256":.string(sha256(canonical(.object([
            "privateFloor":value["privateFloor"]!,"audienceCeiling":value["audienceCeiling"]!])))),
         "qualificationDigest":value["destination"]!["qualificationDigest"] ?? .null]
    }
    static func preparedBody(_ data: Data, candidateBytes: Data) throws -> Value {
        let value = try candidate(candidateBytes), body = try decode(data, limit: maxBody)
        let expected = binding(candidateBytes, candidate: value)
        let row = try fields(body, Array(expected.keys) + ["backendDigest"])
        for (key, item) in expected { try require(row[key] == item, "prepared_binding") }
        try digest(row["backendDigest"]); return body
    }
    static func receiptBody(_ data: Data, preparedBytes: Data, candidateBytes: Data) throws -> Value {
        let body = try preparedBody(preparedBytes, candidateBytes: candidateBytes).object!
        let value = try decode(data, limit: maxBody)
        let row = try fields(value, Array(body.keys) + ["preparedBodySHA256","outcome","committedIDs"])
        for (key, item) in body { try require(row[key] == item, "receipt_binding") }
        try require(row["preparedBodySHA256"] == .string(sha256(preparedBytes)) && row["outcome"] == .string("committed"), "receipt_prepared")
        try uniqueIDs(row["committedIDs"], minimum: 1, uuids: true); return value
    }
    private static func envelope(_ stage: String, _ op: String, _ prior: Data, _ body: Data) -> Data {
        canonical(.object(["version":.number(1),"stage":.string(stage),"operationID":.string(op),
            "priorSHA256":.string(sha256(prior)),"bodyBase64":.string(body.base64EncodedString()),"bodySHA256":.string(sha256(body))]))
    }
    private static func unwrap(_ data: Data, _ stage: String, _ op: String, _ prior: Data) throws -> Data {
        let row = try fields(decode(data), ["version","stage","operationID","priorSHA256","bodyBase64","bodySHA256"])
        try require(row["version"] == .number(1) && row["stage"] == .string(stage) && row["operationID"] == .string(op)
            && row["priorSHA256"] == .string(sha256(prior)), "stage_chain")
        guard let text = row["bodyBase64"]?.string, text.utf8.count <= 87384, let body = Data(base64Encoded: text) else { throw Failure(code: "base64") }
        try require(!body.isEmpty && body.count <= maxBody && body.base64EncodedString() == text, "base64")
        try require(row["bodySHA256"] == .string(sha256(body)), "body_hash"); return body
    }

    private struct Identity: Equatable {
        let device: UInt64, inode: UInt64, size: Int64, seconds: Int64, nanos: Int64
        init(_ st: stat) {
            device = UInt64(truncatingIfNeeded: st.st_dev); inode = UInt64(truncatingIfNeeded: st.st_ino); size = Int64(st.st_size)
            #if canImport(Darwin)
            seconds = Int64(st.st_mtimespec.tv_sec); nanos = Int64(st.st_mtimespec.tv_nsec)
            #else
            seconds = Int64(st.st_mtim.tv_sec); nanos = Int64(st.st_mtim.tv_nsec)
            #endif
        }
        func sameFile(_ other: Identity) -> Bool { device == other.device && inode == other.inode }
    }
    @discardableResult
    private static func systemClose(_ fd: Int32) -> Bool {
        if fd < 0 { return true }
        #if canImport(Darwin)
        return Darwin.close(fd) == 0
        #else
        return Glibc.close(fd) == 0
        #endif
    }
    @discardableResult
    private func closeLocal(_ fd: Int32) -> Bool {
        if fd < 0 { return true }
        var injectedFailure = false
        do { try fault?("descriptor_close", "") } catch { injectedFailure = true }
        // Even an injected failure still closes the original once. An OS error
        // may leave fd state uncertain; never retry a potentially reused number.
        let succeeded = Self.systemClose(fd)
        if !succeeded || injectedFailure { descriptorCloseUncertain = true; poisoned = true }
        return succeeded && !injectedFailure
    }
    private static func checkedStat(_ fd: Int32) throws -> stat {
        var value = stat(); try require(fstat(fd, &value) == 0, "file_stat"); return value
    }
    private static func mode(_ st: stat, directory: Bool = false) throws {
        try require((st.st_mode & mode_t(S_IFMT)) == mode_t(directory ? S_IFDIR : S_IFREG)
            && st.st_uid == getuid() && (st.st_mode & 0o7777) == mode_t(directory ? 0o700 : 0o600)
            && (directory || st.st_nlink == 1), "unsafe_file")
    }
    private static func openRoot(_ path: String) throws -> Int32 {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        try require(path.hasPrefix("/") && path != "/" && parts.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
            && !path.utf8.contains(0), "root_path")
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var fd = open("/", flags); try require(fd >= 0, "root_open")
        do {
            for part in parts.dropFirst() {
                let next = openat(fd, String(part), flags); try require(next >= 0, "ancestor_open")
                let old = fd; fd = next
                try require(systemClose(old), "descriptor_close_uncertain")
                let st = try checkedStat(fd)
                try require((st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) && [uid_t(0),getuid()].contains(st.st_uid)
                    && st.st_mode & 0o022 == 0, "unsafe_ancestor")
            }
            try mode(checkedStat(fd), directory: true); return fd
        } catch {
            guard systemClose(fd) else { throw Failure(code: "descriptor_close_uncertain") }
            throw error
        }
    }
    static func openOwnedNamespace(root: String, host: String, account: String) throws -> LearnerPublicationQueue {
        try LearnerPublicationQueue(root: root, host: host, account: account)
    }
    // The internal fault seam can only throw; every successful path still calls fsync.
    init(root: String, host: String, account: String, fault: ((String, String) throws -> Void)? = nil) throws {
        self.root = root; self.host = host; self.account = account; self.fault = fault
        try Self.identifier(.string(host)); try Self.identifier(.string(account))
        do {
            rootFD = try Self.openRoot(root); rootIdentity = Identity(try Self.checkedStat(rootFD))
            lockFD = openat(rootFD, ".owner.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600))
            try Self.require(lockFD >= 0, "lock_open")
            let st = try Self.checkedStat(lockFD); try Self.mode(st); try Self.require(st.st_size == 0, "lock_content")
            try Self.require(flock(lockFD, LOCK_EX | LOCK_NB) == 0, "namespace_busy"); lockIdentity = Identity(st)
            let initialNames = try names()
            if !initialNames.contains("namespace.json") {
                try Self.require(initialNames == [".owner.lock"], "namespace_missing")
                try append("namespace.json", Self.canonical(.object(["version":.number(1),"host":.string(host),"account":.string(account)])))
            }
            _ = try load()
            for name in try names() {
                let fd = openat(rootFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                try Self.require(fd >= 0, "reopen_file")
                do { try Self.mode(Self.checkedStat(fd)); try fault?("reopen_file_fsync", name)
                    try Self.require(fsync(fd) == 0, "file_fsync")
                } catch { closeLocal(fd); throw error }
                try Self.require(closeLocal(fd), "descriptor_close_uncertain")
            }
            try fault?("reopen_directory_fsync", ""); try Self.require(fsync(rootFD) == 0, "directory_fsync")
            _ = try load()
        } catch {
            let outcome = close()
            if outcome == .uncertain { throw Failure(code: "descriptor_close_uncertain") }
            if let failure = error as? Failure { throw failure }; throw Failure(code: "namespace_open")
        }
    }
    private func check() throws {
        try Self.require(!closed && !poisoned, "queue_unavailable")
        let fresh: Int32
        do { fresh = try Self.openRoot(root) }
        catch {
            if (error as? Failure)?.code == "descriptor_close_uncertain" { descriptorCloseUncertain = true; poisoned = true }
            throw error
        }
        defer { closeLocal(fresh) }
        try Self.require(rootIdentity!.sameFile(Identity(try Self.checkedStat(fresh))), "root_changed")
        let held = try Self.checkedStat(lockFD); var named = stat()
        try Self.require(fstatat(rootFD, ".owner.lock", &named, AT_SYMLINK_NOFOLLOW) == 0, "lock_changed")
        try Self.mode(held); try Self.mode(named)
        try Self.require(Identity(held).sameFile(lockIdentity!) && Identity(named).sameFile(lockIdentity!)
            && held.st_size == 0 && named.st_size == 0, "lock_changed")
    }
    private func names() throws -> [String] {
        let fd = openat(rootFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try Self.require(fd >= 0, "directory_open")
        guard let stream = fdopendir(fd) else { closeLocal(fd); throw Failure(code: "directory_stream") }
        defer {
            if closedir(stream) != 0 { descriptorCloseUncertain = true; poisoned = true }
        }
        var result: [String] = []; var seen = Set<String>()
        while true {
            errno = 0
            guard let entry = readdir(stream) else { try Self.require(errno == 0, "directory_read"); break }
            let bytes = withUnsafeBytes(of: entry.pointee.d_name) { raw -> [UInt8] in
                Array(raw.prefix(while: { $0 != 0 }))
            }
            if bytes == [46] || bytes == [46,46] { continue }
            try Self.require(result.count < Self.maxEntries && bytes.count <= 96, "entry_bound")
            guard let name = String(bytes: bytes, encoding: .utf8) else { throw Failure(code: "filename") }
            if name != ".owner.lock" && name != "namespace.json" { _ = try splitName(name) }
            try Self.require(seen.insert(name).inserted, "duplicate_file"); result.append(name)
        }
        return result
    }
    private func splitName(_ name: String) throws -> (String,String) {
        let pieces = name.split(separator: ".", omittingEmptySubsequences: false)
        try Self.require(pieces.count == 3 && pieces[2] == "json" && Self.stages.contains(String(pieces[1])), "filename")
        let op = String(pieces[0]); try Self.uuid(.string(op)); return (op,String(pieces[1]))
    }
    private func read(_ name: String, limit: Int) throws -> Data {
        var initial = stat()
        try Self.require(fstatat(rootFD, name, &initial, AT_SYMLINK_NOFOLLOW) == 0, "file_stat")
        try Self.mode(initial)
        let fd = openat(rootFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        try Self.require(fd >= 0, "file_open"); defer { closeLocal(fd) }
        let before = try Self.checkedStat(fd); try Self.mode(before)
        try Self.require(Identity(initial) == Identity(before), "file_changed")
        try Self.require(before.st_size >= 0 && before.st_size <= off_t(limit), "file_bound")
        total += Int(before.st_size); try Self.require(total <= Self.maxTotal, "aggregate_bound")
        var output = Data(); var remaining = Int(before.st_size); var buffer = [UInt8](repeating: 0, count: 65536)
        while remaining > 0 {
            let count = buffer.withUnsafeMutableBytes { bytes in systemRead(fd, bytes.baseAddress!, min(remaining, bytes.count)) }
            if count < 0 && errno == EINTR { continue }
            try Self.require(count > 0, "file_truncated"); output.append(contentsOf: buffer.prefix(count)); remaining -= count
        }
        var byte: UInt8 = 0; var tail: Int
        repeat { tail = systemRead(fd, &byte, 1) } while tail < 0 && errno == EINTR
        try Self.require(tail == 0, "file_grew")
        let after = try Self.checkedStat(fd); var named = stat()
        try Self.require(fstatat(rootFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0, "file_changed"); try Self.mode(named)
        try Self.require(Identity(before) == Identity(after) && Identity(after) == Identity(named), "file_changed")
        return output
    }
    private func systemRead(_ fd: Int32, _ pointer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.read(fd, pointer, count)
        #else
        Glibc.read(fd, pointer, count)
        #endif
    }
    private func load() throws -> [String:[String:Data]] {
        try check(); try Self.require(!descriptorCloseUncertain, "descriptor_close_uncertain")
        total = 0; let names = try names()
        try Self.require(names.contains("namespace.json") && names.contains(".owner.lock"), "namespace_missing")
        var bytes: [String:Data] = [:]
        bytes[".owner.lock"] = try read(".owner.lock", limit: 0)
        let metadata = try read("namespace.json", limit: 1024); bytes["namespace.json"] = metadata
        try Self.require(Self.decode(metadata, limit: 1024) == .object(["version":.number(1),"host":.string(host),"account":.string(account)]), "namespace_binding")
        var rows: [String:[String:Data]] = [:]
        for name in names.sorted() where name != "namespace.json" && name != ".owner.lock" {
            let (op, stage) = try splitName(name)
            if rows[op] == nil { try Self.require(rows.count < Self.maxOperations, "operation_bound"); rows[op] = [:] }
            let data = try read(name, limit: Self.maxRecord); bytes[name] = data; rows[op]![stage] = data
        }
        for (name, data) in observed { try Self.require(bytes[name] == data, "observed_history_changed") }
        var ids = Set<String>(); var unresolved = 0
        for (op, stages) in rows {
            guard let raw = stages["candidate"] else { throw Failure(code: "stage_missing") }
            let c = try Self.candidate(raw)
            try Self.require(c["operationID"] == .string(op) && c["host"] == .string(host) && c["account"] == .string(account), "candidate_namespace")
            try Self.require(ids.insert(c["candidateID"]!.string!).inserted, "candidate_rebound")
            if c["destination"]!["kind"] == .string("heldLocal") { try Self.require(Set(stages.keys) == ["candidate"], "held_local") }
            var prepared: Data?; var body: Value?
            if let wrapped = stages["prepared"] {
                prepared = try Self.unwrap(wrapped, "prepared", op, raw); body = try Self.preparedBody(prepared!, candidateBytes: raw)
            }
            if ["dispatch","uncertain","receipt"].contains(where: { stages[$0] != nil }) {
                guard let prepared, let body, let dispatch = stages["dispatch"], let wrapped = stages["prepared"] else { throw Failure(code: "stage_missing") }
                let expected = Self.dispatch(op, wrapped, prepared, body)
                try Self.require(Self.decode(dispatch) == Self.decode(expected), "dispatch_binding")
                if stages["receipt"] == nil { unresolved += 1 }
            }
            if let uncertain = stages["uncertain"] {
                let row = try Self.fields(Self.decode(uncertain), ["version","stage","operationID","priorSHA256","reason"])
                try Self.require(row["version"] == .number(1) && row["stage"] == .string("uncertain") && row["operationID"] == .string(op)
                    && row["priorSHA256"] == .string(Self.sha256(stages["dispatch"]!))
                    && ["cancelled","lostResponse","interrupted","unknown"].contains(row["reason"]?.string ?? ""), "uncertain_binding")
            }
            if let received = stages["receipt"] {
                let receipt = try Self.unwrap(received, "receipt", op, stages["uncertain"] ?? stages["dispatch"]!)
                _ = try Self.receiptBody(receipt, preparedBytes: prepared!, candidateBytes: raw)
            }
        }
        try Self.require(unresolved <= 1, "publication_slot")
        try Self.require(!descriptorCloseUncertain, "descriptor_close_uncertain")
        observed = bytes; return rows
    }
    private func append(_ name: String, _ data: Data) throws {
        try Self.require(!data.isEmpty && data.count <= Self.maxRecord && total + data.count <= Self.maxTotal, "capacity")
        var fd: Int32 = -1
        do {
            try check()
            try Self.require(!descriptorCloseUncertain, "descriptor_close_uncertain")
            fd = openat(rootFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600))
            try Self.require(fd >= 0, "exclusive_create"); try Self.mode(Self.checkedStat(fd))
            try fault?("before_write", name)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count: Int
                    #if canImport(Darwin)
                    count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), min(65536, bytes.count - offset))
                    #else
                    count = Glibc.write(fd, bytes.baseAddress!.advanced(by: offset), min(65536, bytes.count - offset))
                    #endif
                    if count < 0 && errno == EINTR { continue }
                    try Self.require(count > 0, "write_zero"); offset += count
                }
            }
            try fault?("after_write", name); try fault?("file_fsync", name)
            try Self.require(fsync(fd) == 0, "file_fsync"); try fault?("directory_fsync", name)
            try Self.require(fsync(rootFD) == 0, "directory_fsync")
            let original = fd; fd = -1
            try Self.require(closeLocal(original), "descriptor_close_uncertain")
            observed[name] = data; total += data.count
        } catch {
            if fd >= 0 { let original = fd; fd = -1; closeLocal(original) }
            poisoned = true
            if descriptorCloseUncertain { throw Failure(code: "descriptor_close_uncertain") }
            if let failure = error as? Failure { throw failure }; throw Failure(code: "persistence_failed")
        }
    }
    private static func dispatch(_ op: String, _ wrapped: Data, _ prepared: Data, _ body: Value) -> Data {
        canonical(.object(["version":.number(1),"stage":.string("dispatch"),"operationID":.string(op),
            "priorSHA256":.string(sha256(wrapped)),"preparedBodySHA256":.string(sha256(prepared)),"backendDigest":body["backendDigest"]!]))
    }
    private func record(_ op: String, _ stages: [String:Data]) throws -> Record {
        let raw = stages["candidate"]!, c = try Self.candidate(raw)
        var state = c["destination"]!["kind"] == .string("heldLocal") ? "heldLocal" : "pending"
        var prepared: Data?, receipt: Data?, backend: String?
        if let wrapped = stages["prepared"] {
            prepared = try Self.unwrap(wrapped,"prepared",op,raw)
            backend = try Self.preparedBody(prepared!, candidateBytes: raw)["backendDigest"]!.string; state = "prepared"
        }
        if stages["dispatch"] != nil { state = "dispatchedUnknown" }
        if let wrapped = stages["receipt"] {
            receipt = try Self.unwrap(wrapped,"receipt",op,stages["uncertain"] ?? stages["dispatch"]!); state = "acknowledged"
        }
        return Record(operationID: op, state: state, candidateBytes: raw, preparedBytes: prepared, receiptBytes: receipt,
            candidateSHA256: Self.sha256(raw), preparedSHA256: prepared.map(Self.sha256), receiptSHA256: receipt.map(Self.sha256),
            backendDigest: backend, destination: c["destination"]!)
    }
    func retainCandidate(_ data: Data) throws -> Record {
        mutex.lock(); defer { mutex.unlock() }; let rows = try load(), c = try Self.candidate(data)
        try Self.require(c["host"] == .string(host) && c["account"] == .string(account), "candidate_namespace")
        let op = c["operationID"]!.string!
        if let stages = rows[op] { try Self.require(stages["candidate"] == data, "candidate_conflict"); return try record(op, stages) }
        try Self.require(rows.count < Self.maxOperations, "operation_bound")
        for stages in rows.values { try Self.require(Self.candidate(stages["candidate"]!)["candidateID"] != c["candidateID"], "candidate_rebound") }
        try append(op + ".candidate.json", data); return try record(op, ["candidate":data])
    }
    func retainPrepared(operationID op: String, bytes data: Data) throws -> Record {
        mutex.lock(); defer { mutex.unlock() }; let rows = try load(); try Self.uuid(.string(op))
        guard var stages = rows[op] else { throw Failure(code: "operation_missing") }
        let raw = stages["candidate"]!, c = try Self.candidate(raw)
        try Self.require(c["destination"]!["kind"] != .string("heldLocal"), "held_local")
        _ = try Self.preparedBody(data, candidateBytes: raw)
        if let existing = stages["prepared"] { try Self.require(Self.unwrap(existing,"prepared",op,raw) == data, "prepared_conflict") }
        else { let wrapped = Self.envelope("prepared",op,raw,data); try append(op + ".prepared.json",wrapped); stages["prepared"] = wrapped }
        return try record(op,stages)
    }
    func recordDispatchStarted(operationID op: String) throws -> Record {
        mutex.lock(); defer { mutex.unlock() }; let rows = try load(); try Self.uuid(.string(op))
        guard var stages = rows[op], let wrapped = stages["prepared"] else { throw Failure(code: "stage_missing") }
        if stages["dispatch"] == nil {
            // This is one unresolved local outcome, never an I/O join proof.
            // A future transport must keep its original handles independently.
            try Self.require(!rows.contains { key, stages in key != op && stages["dispatch"] != nil && stages["receipt"] == nil }, "publication_slot")
            let prepared = try Self.unwrap(wrapped,"prepared",op,stages["candidate"]!)
            let body = try Self.preparedBody(prepared,candidateBytes:stages["candidate"]!)
            let data = Self.dispatch(op,wrapped,prepared,body); try append(op + ".dispatch.json",data); stages["dispatch"] = data
        }
        return try record(op,stages)
    }
    func recordUncertain(operationID op: String, reason: String) throws -> Record {
        mutex.lock(); defer { mutex.unlock() }; let rows = try load(); try Self.uuid(.string(op))
        guard var stages = rows[op], let dispatch = stages["dispatch"], stages["receipt"] == nil else { throw Failure(code: "stage_missing") }
        try Self.require(["cancelled","lostResponse","interrupted","unknown"].contains(reason), "uncertain_reason")
        let data = Self.canonical(.object(["version":.number(1),"stage":.string("uncertain"),"operationID":.string(op),
            "priorSHA256":.string(Self.sha256(dispatch)),"reason":.string(reason)]))
        if let existing = stages["uncertain"] { try Self.require(existing == data, "uncertain_conflict") }
        else { try append(op + ".uncertain.json",data); stages["uncertain"] = data }
        return try record(op,stages)
    }
    func retainReceipt(operationID op: String, bytes data: Data) throws -> Record {
        mutex.lock(); defer { mutex.unlock() }; let rows = try load(); try Self.uuid(.string(op))
        guard var stages = rows[op], let dispatch = stages["dispatch"], let wrapped = stages["prepared"] else { throw Failure(code: "stage_missing") }
        let prepared = try Self.unwrap(wrapped,"prepared",op,stages["candidate"]!)
        _ = try Self.receiptBody(data,preparedBytes:prepared,candidateBytes:stages["candidate"]!)
        let prior = stages["uncertain"] ?? dispatch
        if let existing = stages["receipt"] { try Self.require(Self.unwrap(existing,"receipt",op,prior) == data, "receipt_conflict") }
        else { let envelope = Self.envelope("receipt",op,prior,data); try append(op + ".receipt.json",envelope); stages["receipt"] = envelope }
        return try record(op,stages)
    }
    func recover() throws -> Recovery {
        mutex.lock(); defer { mutex.unlock() }; let rows = try load()
        let records = try rows.keys.sorted().map { try record($0,rows[$0]!) }
        var accounting = Dictionary(uniqueKeysWithValues: Self.states.map { ($0,0) })
        for row in records { accounting[row.state]! += 1 }; accounting["retained"] = records.count
        return Recovery(records: records, accounting: accounting)
    }
    @discardableResult
    func close() -> LocalCloseOutcome {
        mutex.lock(); defer { mutex.unlock() }; closed = true
        let lock = lockFD, root = rootFD; lockFD = -1; rootFD = -1
        closeLocal(lock); closeLocal(root)
        return descriptorCloseUncertain ? .uncertain : .originalsClosed
    }
    deinit { close() }
}
