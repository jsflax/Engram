import Foundation
import Lattice

/// Checks an explicitly selected shared collection without registering a
/// schema, running migrations, or creating a replacement for a missing file.
public enum AgentMemorySourceValidation {
    public enum ValidationError: Error, LocalizedError, Sendable {
        case unavailable
        case incompatibleSchema(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable: return "The memory collection is unavailable."
            case .incompatibleSchema(let field):
                return "This file is not a compatible Engram collection (\(field))."
            }
        }
    }

    public static func validate(fileURL: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileURL.isFileURL,
              FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { throw ValidationError.unavailable }
        // Dynamic opens recover the on-disk schema using SQLITE_OPEN_READONLY.
        // Supplying today's typed schema here could mask an unrelated database
        // or attempt to upgrade an older collection owned by another process.
        let source = try Lattice.dynamic(fileURL: fileURL)
        defer { source.close() }
        let schemas = source.dynamicSchema
        func require(_ table: String, _ fields: [(String, ColumnType)]) throws {
            guard let schema = schemas.first(where: { $0.name == table }) else {
                throw ValidationError.incompatibleSchema(table)
            }
            for (name, type) in fields {
                guard let property = schema.property(named: name), property.isScalar,
                      property.columnType == type else {
                    throw ValidationError.incompatibleSchema("\(table).\(name)")
                }
            }
        }
        // This is the stable pre-groups shape. Later optional provenance,
        // tombstone, pending-embedding, and transfer fields are not required.
        try require("Memory", [
            ("content", .text), ("topic", .text), ("project", .text), ("source", .text),
            ("embedding", .blob), ("createdAt", .real), ("lastAccessedAt", .real),
            ("expiresAt", .real), ("accessCount", .integer), ("importance", .integer),
            ("isPrivate", .integer),
        ])
        try require("Edge", [
            ("sourceGlobalId", .text), ("targetGlobalId", .text),
            ("relation", .text), ("createdAt", .real),
        ])
    }
}
