import MCP

/// The executable owns its inherited writer fence until this returns true.
/// Receive-loop completion alone leaves entered handlers and response writes
/// alive. Only the external lifetime owner can join every SDK-owned task.
package func waitForMCPServerShutdown(_ server: Server) async -> Bool {
    await server.waitUntilCompleted()
    return await server.waitForShutdown()
}
