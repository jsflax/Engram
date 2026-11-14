import Foundation
import Lattice

/// Client-safe storage diagnostics. Lattice's associated messages can contain
/// SQL, memory content, and paths; keep those in the existing local error log.
/// A failed tool may already have completed earlier writes, so these messages
/// deliberately make no claim about persistence or whether retrying is safe.
package func mcpLatticeErrorDescription(_ error: LatticeError) -> String {
    switch error {
    case .missingLatticeContext:
        return "Memory storage context is unavailable."
    case .alreadyManaged:
        return "Memory storage rejected an already managed object."
    case .addFailed(let detail):
        return storageFailureDescription("insert", detail: detail)
    case .transactionError(let detail):
        return storageFailureDescription("transaction", detail: detail)
    case .syncReceiveFailed(let detail):
        return storageFailureDescription("synchronization", detail: detail)
    case .attachFailed(let detail):
        return storageFailureDescription("attachment", detail: detail)
    case .detachFailed(let detail):
        return storageFailureDescription("detachment", detail: detail)
    }
}

private func storageFailureDescription(_ operation: String, detail: String) -> String {
    var reason = detail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    // Core's SQL-execution error appends the actual statement. It must neither
    // reach the client nor make SQL containing a lock phrase look like SQLITE_BUSY.
    if let sql = reason.range(of: " (sql: ") {
        reason = String(reason[..<sql.lowerBound])
    }
    // Only recognize known Core wrappers and SQLite reasons, rather than
    // matching an arbitrary occurrence of "busy" or "locked" in private data.
    for prefix in ["insert failed: ", "failed to prepare insert: ",
                   "failed to begin transaction: ", "sql execution failed: ",
                   "execution failed: ", "failed to prepare statement: "] {
        if reason.hasPrefix(prefix) {
            reason.removeFirst(prefix.count)
            break
        }
    }
    let isLocked = reason == "database is locked" || reason == "database is busy"
        || reason == "database table is locked" || reason.hasPrefix("database table is locked: ")
        || reason == "database schema is locked" || reason.hasPrefix("database schema is locked: ")
    if isLocked {
        return "Memory storage \(operation) failed: database is busy or locked."
    }
    return "Memory storage \(operation) failed."
}
