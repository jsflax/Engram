import CryptoKit
import Darwin
import Foundation

/// A close-only lifetime holder for an already acquired Python writer fence.
///
/// This validates the supplied descriptor and pinned immutable binding. Darwin
/// has no non-mutating flock ownership query: these checks cannot prove that the
/// particular open-file description already holds LOCK_SH. The trusted proxy
/// must acquire_shared() and directly pass that same FD with Popen(pass_fds:).
/// This helper deliberately never acquires, converts, or releases a flock.
/// Keep the returned instance alive until the native server has stopped every
/// possible mutation/receipt transaction. It opens no environment-supplied path.
final class InheritedWriterFence {
    static let descriptorEnvironmentKey = "ENGRAM_WRITER_FENCE_FD"
    static let bindingEnvironmentKey = "ENGRAM_WRITER_FENCE_BINDING_B64"
    private static let protocolName = "inherited_shared_writer_fence_v1"
    private static let maximumBytes = 65_536
    private var descriptor: Int32

    enum ValidationError: Error {
        case missingPair, invalidDescriptor, invalidBinding, descriptorChanged, duplicationFailed
    }

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit { close() }

    /// Optional only when neither variable is supplied. A partial or malformed
    /// supplied fence always throws; startup must terminate before any DB open.
    /// Binding bytes must equal Python migration.encode(binding): sorted compact
    /// JSON plus one newline. Canonical equality rejects duplicate fields and
    /// alternate numeric representations before they can weaken identity checks.
    static func consume(environment: [String: String]) throws -> InheritedWriterFence? {
        let rawFD = environment[descriptorEnvironmentKey]
        let encoded = environment[bindingEnvironmentKey]
        if rawFD == nil && encoded == nil { return nil }
        guard let rawFD, let encoded else { throw ValidationError.missingPair }
        guard let source = Int32(rawFD), source >= 3, String(source) == rawFD else {
            throw ValidationError.invalidDescriptor
        }
        guard encoded.utf8.count <= 4 * ((maximumBytes + 2) / 3),
              let bindingBytes = Data(base64Encoded: encoded), bindingBytes.count <= maximumBytes else {
            throw ValidationError.invalidBinding
        }
        let binding = try Binding.decode(bindingBytes)
        try validate(source, binding: binding)
        let retained = fcntl(source, F_DUPFD_CLOEXEC, 3)
        guard retained >= 3 else { throw ValidationError.duplicationFailed }
        do {
            try validate(retained, binding: binding)
            try validate(source, binding: binding)
            // Same open-file description; closing this process's original copy
            // cannot unlock the retained duplicate or a proxy's copy.
            Darwin.close(source)
            return InheritedWriterFence(descriptor: retained)
        } catch {
            Darwin.close(retained)
            throw error
        }
    }

    /// Close only this process's retained copy. Never call flock(..., LOCK_UN).
    /// Startup owns this holder; close is not exposed through the MCP protocol.
    func close() {
        if descriptor >= 0 {
            let owned = descriptor
            descriptor = -1
            Darwin.close(owned)
        }
    }

    private struct Binding {
        let epoch: String
        let owner: String
        let lockSHA256: String
        let identity: [String: Int64]

        var lockBytes: Data {
            Data("{\"epoch_id\":\"\(epoch)\",\"owner_id\":\"\(owner)\",\"protocol\":\"\(InheritedWriterFence.protocolName)\",\"version\":1}\n".utf8)
        }

        var canonicalBytes: Data {
            let fields = identity.keys.sorted().map { "\"\($0)\":\(identity[$0]!)" }.joined(separator: ",")
            return Data("{\"epoch_id\":\"\(epoch)\",\"lock_identity\":{\(fields)},\"lock_sha256\":\"\(lockSHA256)\",\"owner_id\":\"\(owner)\",\"protocol\":\"\(InheritedWriterFence.protocolName)\"}\n".utf8)
        }

        static func decode(_ raw: Data) throws -> Binding {
            let object: Any
            do { object = try JSONSerialization.jsonObject(with: raw) }
            catch { throw ValidationError.invalidBinding }
            guard let value = object as? [String: Any],
                  Set(value.keys) == ["protocol", "epoch_id", "owner_id", "lock_sha256", "lock_identity"],
                  value["protocol"] as? String == InheritedWriterFence.protocolName,
                  let epoch = value["epoch_id"] as? String, UUID(uuidString: epoch)?.uuidString.lowercased() == epoch,
                  let owner = value["owner_id"] as? String, UUID(uuidString: owner)?.uuidString.lowercased() == owner,
                  let digest = value["lock_sha256"] as? String, digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let fields = value["lock_identity"] as? [String: Any],
                  Set(fields.keys) == ["device", "inode", "uid", "gid", "mode", "size", "mtime_ns", "ctime_ns", "nlink"] else {
                throw ValidationError.invalidBinding
            }
            var identity: [String: Int64] = [:]
            for (name, value) in fields {
                guard let number = value as? NSNumber else { throw ValidationError.invalidBinding }
                identity[name] = number.int64Value
            }
            let binding = Binding(epoch: epoch, owner: owner, lockSHA256: digest, identity: identity)
            // Exact serialization eliminates permissive NSNumber conversions,
            // duplicate JSON keys, extra whitespace, float aliases, and booleans.
            guard binding.canonicalBytes == raw,
                  SHA256.hash(data: binding.lockBytes).map({ String(format: "%02x", $0) }).joined() == digest else {
                throw ValidationError.invalidBinding
            }
            return binding
        }
    }

    private static func identity(_ fd: Int32) throws -> [String: Int64] {
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_mode & 0o777 == 0o600, info.st_uid == getuid(), info.st_nlink == 1,
              let inode = Int64(exactly: info.st_ino) else {
            throw ValidationError.invalidDescriptor
        }
        func nanos(_ time: timespec) throws -> Int64 {
            let (seconds, overflow1) = Int64(time.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
            let (result, overflow2) = seconds.addingReportingOverflow(Int64(time.tv_nsec))
            guard !overflow1 && !overflow2 else { throw ValidationError.invalidDescriptor }
            return result
        }
        return ["device": Int64(info.st_dev), "inode": inode, "uid": Int64(info.st_uid),
                "gid": Int64(info.st_gid), "mode": Int64(info.st_mode), "size": Int64(info.st_size),
                "mtime_ns": try nanos(info.st_mtimespec), "ctime_ns": try nanos(info.st_ctimespec),
                "nlink": Int64(info.st_nlink)]
    }

    private static func validate(_ fd: Int32, binding: Binding) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, flags & O_ACCMODE == O_RDWR,
              try identity(fd) == binding.identity,
              binding.identity["size"] == Int64(binding.lockBytes.count) else {
            throw ValidationError.descriptorChanged
        }
        var bytes = [UInt8](repeating: 0, count: binding.lockBytes.count)
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { buffer in
                pread(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ValidationError.descriptorChanged }
            offset += count
        }
        guard Data(bytes) == binding.lockBytes, try identity(fd) == binding.identity else {
            throw ValidationError.descriptorChanged
        }
    }
}
