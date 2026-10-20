import RealityKit
import simd
import Foundation

/// Flow particle system — billboard quads traveling along edges connected to selected node.
///
/// Max 30 edges, spawn every 0.4s, travel 1.25s per edge.
@MainActor
public final class RKFlowParticleSystem {
    private struct Particle {
        let edgeIndex: Int
        let sourcePos: SIMD3<Float>
        let targetPos: SIMD3<Float>
        var progress: Float  // 0..1 along edge
        var age: Float       // seconds alive
    }

    private var particles: [Particle] = []
    private var spawnTimer: Float = 0
    private let spawnInterval: Float = 0.4
    private let particleLifespan: Float = 1.25
    private let maxEdges: Int = 30

    private var lastSelectedNode: UUID?
    private var lastTopologyVersion: UInt64?
    private var connectedEdgeIndices: [Int] = []

    public init() {}

    public func update(
        scene: EngramRealityScene,
        dataProvider: SceneDataProvider,
        dt: Float,
        scaleFactor: Float
    ) {
        let selectedNode = dataProvider.selectedNode

        // Filtering can remove or reorder edges without changing the selection.
        if selectedNode != lastSelectedNode || dataProvider.topologyVersion != lastTopologyVersion {
            lastSelectedNode = selectedNode
            lastTopologyVersion = dataProvider.topologyVersion
            connectedEdgeIndices.removeAll()
            particles.removeAll()
            spawnTimer = 0

            if let nodeId = selectedNode {
                let edges = dataProvider.edges
                for i in 0..<edges.count {
                    guard connectedEdgeIndices.count < maxEdges else { break }
                    if edges[i].sourceId == nodeId || edges[i].targetId == nodeId {
                        connectedEdgeIndices.append(i)
                    }
                }
            }
        }

        guard !connectedEdgeIndices.isEmpty else { return }

        let edges = dataProvider.edges
        let positions = dataProvider.positions

        // Spawn new particles
        spawnTimer += dt
        while spawnTimer >= spawnInterval {
            spawnTimer -= spawnInterval
            for edgeIdx in connectedEdgeIndices {
                let edge = edges[edgeIdx]
                guard let src = positions[edge.sourceId],
                      let tgt = positions[edge.targetId] else { continue }
                // Always flow away from selected node
                let (from, to): (SIMD3<Float>, SIMD3<Float>)
                if edge.sourceId == selectedNode {
                    (from, to) = (src, tgt)
                } else {
                    (from, to) = (tgt, src)
                }
                particles.append(Particle(
                    edgeIndex: edgeIdx,
                    sourcePos: from,
                    targetPos: to,
                    progress: 0,
                    age: 0
                ))
            }
        }

        // Update existing particles
        particles = particles.compactMap { var p = $0
            p.age += dt
            p.progress = p.age / particleLifespan
            return p.progress < 1.0 ? p : nil
        }

        // TODO: Write particle quads to flow particle mesh when mesh infrastructure is ready
        // For now, particles are computed but rendering deferred to Phase 4
    }
}
