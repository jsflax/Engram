import Foundation
import Lattice

/// Binding stored alongside graph content, so publishing or moving the file
/// retains its durable agent owner. Renaming an agent never rekeys memory.
@Model
public final class AgentMemoryGraph {
    public var agentId: UUID
    public var graphId: UUID
    public init(agentId: UUID = UUID(), graphId: UUID = UUID()) {
        self.agentId = agentId
        self.graphId = graphId
    }
}
