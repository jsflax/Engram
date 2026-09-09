import Foundation

/// Shared routing for patrol selection and holo lookups; never retains a second
/// node snapshot or rebuilds project subsets during a mascot's animation tick.
@MainActor
final class MascotGraphIndex {
    private var providerIdentity: ObjectIdentifier?
    private var topologyVersion: UInt64 = .max
    private var nodeCount = -1
    private(set) var projects: Set<String> = []
    private(set) var indicesByProject: [String: [Int]] = [:]
    private(set) var indexByID: [UUID: Int] = [:]

    func update(nodes: [RKNodeSnapshot], topologyVersion: UInt64, provider: AnyObject) {
        let identity = ObjectIdentifier(provider)
        guard providerIdentity != identity || self.topologyVersion != topologyVersion
                || nodeCount != nodes.count else { return }
        providerIdentity = identity
        self.topologyVersion = topologyVersion
        nodeCount = nodes.count
        indicesByProject.removeAll(keepingCapacity: true)
        indexByID.removeAll(keepingCapacity: true)
        indexByID.reserveCapacity(nodes.count)
        for (index, node) in nodes.enumerated() {
            indicesByProject[node.project, default: []].append(index)
            // Match the old first(where:) lookup if a provider contains copies.
            if indexByID[node.id] == nil { indexByID[node.id] = index }
        }
        projects = Set(indicesByProject.keys)
    }
}
