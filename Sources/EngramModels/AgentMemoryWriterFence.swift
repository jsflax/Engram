import Foundation
import Lattice

/// Graph-local coordinator authority, shared by processes opening this file.
/// Read and update only while holding the graph's checked write transaction.
/// This is not agent memory: exclude it from every upload/download sync filter
/// and never grant replicas write access to this table. It is also excluded
/// from the transferable memory snapshot hash.
@Model public final class AgentMemoryWriterFence {
    @Unique() public var key: String = ""
    public var graphID: String = ""
    public var coordinatorDeviceID: String = ""
    public var writerDeviceID: String = ""
    public var baselineDigest: String = ""

    public init() {}
    public init(graphID: String, coordinatorDeviceID: String, writerDeviceID: String = "", baselineDigest: String = "") {
        self.graphID = graphID.lowercased()
        self.coordinatorDeviceID = coordinatorDeviceID.lowercased()
        self.key = Self.key(graphID: graphID, coordinatorDeviceID: coordinatorDeviceID)
        self.writerDeviceID = writerDeviceID.lowercased()
        self.baselineDigest = baselineDigest
    }
    public static func key(graphID: String, coordinatorDeviceID: String) -> String {
        graphID.lowercased() + "|" + coordinatorDeviceID.lowercased()
    }
}
