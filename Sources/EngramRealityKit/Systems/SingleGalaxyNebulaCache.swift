import Foundation
import simd

/// Opt-in cache for providers using the default single-galaxy nebula layout.
/// Flat positions, when supplied, must contain one valid position per node.
/// Centroids are included independently: their slower aggregate pass may finish
/// after motion stops without another position or topology revision.
@MainActor
public final class SingleGalaxyNebulaCache {
    private struct Inputs: Equatable {
        let provider: ObjectIdentifier
        let topology: UInt64
        let positions: UInt64
        let nodeCount: Int
        let centroids: [String: SIMD3<Float>]
    }

    private var lastInputs: Inputs?
    private var cachedClusters: [RKNebulaCluster] = []

    public init() {}

    public func clusters(for provider: SceneDataProvider) -> [RKNebulaCluster] {
        let inputs = Inputs(provider: ObjectIdentifier(provider), topology: provider.topologyVersion,
                            positions: provider.positionVersion, nodeCount: provider.nodes.count,
                            centroids: provider.projectCentroids)
        guard inputs != lastInputs else { return cachedClusters }
        cachedClusters = deriveSingleGalaxyNebulaClusters(
            nodes: provider.nodes, centroids: inputs.centroids,
            positionArray: provider.positionArray, positions: { provider.positions }
        )
        lastInputs = inputs
        return cachedClusters
    }
}

/// Counts and exact maximum distances in one pass. The dictionary fallback is
/// read lazily and only once, so providers with flat positions never build it.
func deriveSingleGalaxyNebulaClusters(
    nodes: [RKNodeSnapshot],
    centroids: [String: SIMD3<Float>],
    positionArray: [SIMD3<Float>],
    positions: () -> [UUID: SIMD3<Float>]
) -> [RKNebulaCluster] {
    let hasFlatPositions = positionArray.count == nodes.count
    let fallbackPositions = hasFlatPositions ? [:] : positions()
    var counts: [String: Int] = [:]
    var radii: [String: Float] = [:]
    counts.reserveCapacity(centroids.count)
    radii.reserveCapacity(centroids.count)
    for (index, node) in nodes.enumerated() {
        counts[node.project, default: 0] += 1
        guard let centroid = centroids[node.project] else { continue }
        let position = hasFlatPositions ? positionArray[index] : fallbackPositions[node.id]
        guard let position else { continue }
        radii[node.project] = max(radii[node.project] ?? 0, simd_length(position - centroid))
    }
    return centroids.map { project, centroid in
        RKNebulaCluster(galaxyId: "main", project: project, centroid: centroid,
                       count: counts[project] ?? 0, radius: (radii[project] ?? 0) + 40)
    }
}
