import EngramKit
import Lattice
import Testing

@Suite("MCP storage error diagnostics")
struct MCPStorageErrorTests {
    @Test(arguments: [
        "Insert failed: database is locked",
        "Failed to prepare insert: database is locked",
        "Failed to begin transaction: database is locked",
        "SQL execution failed: database is locked (SQL: INSERT INTO Memory VALUES ('private fixture'))",
        "Execution failed: database table is locked: /private/fixture.sqlite",
        "Failed to prepare statement: database schema is locked: private_fixture",
        "database is busy",
        "  INSERT FAILED: DATABASE IS LOCKED\n",
    ])
    func lockReasonRemainsActionableWithoutPrivateDetail(_ detail: String) {
        let failures: [(LatticeError, String)] = [
            (.addFailed(detail), "insert"),
            (.transactionError(detail), "transaction"),
            (.syncReceiveFailed(detail), "synchronization"),
            (.attachFailed(detail), "attachment"),
            (.detachFailed(detail), "detachment"),
        ]
        for (error, operation) in failures {
            #expect(mcpLatticeErrorDescription(error)
                == "Memory storage \(operation) failed: database is busy or locked.")
        }
    }

    @Test(arguments: [
        "Insert failed: UNIQUE constraint failed: Memory.globalId",
        "Insert failed: disk I/O error at /private/fixture.sqlite",
        "SQL execution failed: no such table: private_fixture (SQL: INSERT INTO Memory VALUES ('database is locked'))",
        "Insert failed: CHECK constraint failed: content != 'database is locked'",
        "unknown failure: private memory content about busy or locked accounts",
    ])
    func otherFailuresPreserveCategoryWithoutLeakingDetail(_ detail: String) {
        let failures: [(LatticeError, String)] = [
            (.addFailed(detail), "insert"),
            (.transactionError(detail), "transaction"),
            (.syncReceiveFailed(detail), "synchronization"),
            (.attachFailed(detail), "attachment"),
            (.detachFailed(detail), "detachment"),
        ]
        for (error, operation) in failures {
            #expect(mcpLatticeErrorDescription(error) == "Memory storage \(operation) failed.")
        }
    }

    @Test func storageStateFailuresHaveSpecificSafeMessages() {
        #expect(mcpLatticeErrorDescription(.missingLatticeContext)
            == "Memory storage context is unavailable.")
        #expect(mcpLatticeErrorDescription(.alreadyManaged)
            == "Memory storage rejected an already managed object.")
    }
}
