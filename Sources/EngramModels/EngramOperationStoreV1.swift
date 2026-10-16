import Foundation
import Lattice

/// Device-local durable-operation identity. Never register this model in a
/// personal-sync or group schema. Versioned name avoids applying a new unique
/// constraint to legacy data: Lattice's constraint repair may delete duplicates.
@Model @Detached
public final class EngramOperationStoreV1 {
    @Unique(allowsUpsert: false)
    public var singletonKey: String
    public var storeID: String
    public var formatVersion: Int

    public init(storeID: UUID) {
        self.singletonKey = "local-operation-store"
        self.storeID = storeID.uuidString.lowercased()
        self.formatVersion = 1
    }
}

/// Immutable, content-free commit evidence in the SAME local database as the
/// mutation. Insert only through MemoryOperationLedger's checked transaction.
/// The model's setters exist for Lattice; application code must never update or
/// delete receipts. Neither this table nor its audit rows may be synchronized.
@Model @Detached
public final class EngramOperationReceiptV1 {
    @Unique(compoundedWith: \Self.storeID, \.principalKey, allowsUpsert: false)
    public var operationID: String
    public var storeID: String
    public var principalKey: String
    public var payloadSHA256: String
    public var receiptJSON: String
    public var provenanceJSON: String
    public var formatVersion: Int

    public init(operationID: String, storeID: String, principalKey: String,
                payloadSHA256: String, receiptJSON: String, provenanceJSON: String) {
        self.operationID = operationID
        self.storeID = storeID
        self.principalKey = principalKey
        self.payloadSHA256 = payloadSHA256
        self.receiptJSON = receiptJSON
        self.provenanceJSON = provenanceJSON
        self.formatVersion = 1
    }
}
