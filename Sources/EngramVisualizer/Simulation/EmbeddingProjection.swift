import SwiftUI
import Lattice
import EngramKit
import simd

// MARK: - Orchestrator

@Observable
@MainActor
final class EmbeddingProjection {
    private(set) var state: ProjectionState = .idle
    private(set) var projectedPositions: [UUID: CGPoint] = [:]
    private(set) var projectedPositions3D: [UUID: SIMD3<Float>] = [:]
    var knowledgeVoids: [KnowledgeVoid] = []
    var semanticClusters: [SemanticCluster] = []
    var semanticClusters3D: [SemanticCluster3D] = []

    /// Raw 384-dim embeddings, cached from Lattice
    private var embeddings: [UUID: [Float]] = [:]
    @ObservationIgnored private var requestVersion: UInt64 = 0
    @ObservationIgnored private var embeddingTask: Task<[UUID: [Float]], Never>?
    @ObservationIgnored private var projectionTask: Task<TSNEKernel.Output, Never>?

    /// Track which node IDs were projected so we know when to re-project
    private var projectedNodeIds: Set<UUID> = []

    /// Target positions from the latest t-SNE emission — frame-level interpolation
    /// lerps projectedPositions toward these each frame for smooth animation.
    private var targetPositions: [UUID: CGPoint] = [:]
    private var targetPositions3D: [UUID: SIMD3<Float>] = [:]

    /// Whether the 3D lerp animation has converged (no pending targets).
    var is3DAnimationSettled: Bool { targetPositions3D.isEmpty }

    /// Authoritative positions for cluster/void detection. Uses targetPositions (the true
    /// final t-SNE result) when available, so hulls are computed at the correct locations
    /// even while projectedPositions is still lerping toward them.
    var detectionPositions: [UUID: CGPoint] {
        targetPositions.isEmpty ? projectedPositions : targetPositions
    }

    /// Whether the projection is stale (topology changed since last computation)
    var isStale: Bool {
        guard state == .ready else { return false }
        return false  // Staleness tracked externally via GraphView
    }

    // MARK: - Embedding Loading

    func loadEmbeddings(for nodeIds: Set<UUID>, from reference: LatticeThreadSafeReference) async -> Bool {
        embeddingTask?.cancel()
        projectionTask?.cancel()
        requestVersion &+= 1
        let version = requestVersion
        state = .loadingEmbeddings
        let existing = embeddings
        let task = Task.detached(priority: .userInitiated) {
            guard let lattice = reference.resolve() else { return [UUID: [Float]]() }
            var result: [UUID: [Float]] = [:]
            for id in nodeIds {
                guard !Task.isCancelled else { return [:] }
                if let cached = existing[id] { result[id] = cached; continue }
                guard let memory = lattice.objects(Memory.self).where({ $0.globalId == id }).first else { continue }
                let elements = memory.embedding.elements
                if !elements.isEmpty { result[id] = elements }
            }
            return result
        }
        embeddingTask = task
        let loaded = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard version == requestVersion, !Task.isCancelled, !task.isCancelled else { return false }
        embeddings = loaded
        embeddingTask = nil
        return true
    }

    // MARK: - Projection

    func computeProjection(
        nodeIds: Set<UUID>, center: CGPoint, spread: CGFloat,
        initialPositions: [UUID: CGPoint] = [:]
    ) async {
        let version = requestVersion
        // Collect embeddings for nodes that have them
        var ids: [UUID] = []
        var embeddingArrays: [[Float]] = []
        var noEmbeddingIds: [UUID] = []

        for id in nodeIds {
            if let emb = embeddings[id], !emb.isEmpty {
                ids.append(id)
                embeddingArrays.append(emb)
            } else {
                noEmbeddingIds.append(id)
            }
        }

        guard ids.count >= 2 else {
            state = .failed("Need at least 2 memories with embeddings")
            return
        }

        // Clear stale clusters/voids from previous run so they don't flash
        // while the new projection computes. They'll be re-detected after convergence.
        semanticClusters = []
        knowledgeVoids = []

        // Set initial projected positions (force layout) for progressive display
        if !initialPositions.isEmpty {
            projectedPositions = initialPositions
        }

        state = .computing(progress: 0)

        let perplexity = min(30.0, Double(ids.count - 1) / 3.0)

        // Build t-SNE initial positions from force layout (for smooth visual transition)
        let tsneInitialPositions: [(x: Double, y: Double)]?
        if !initialPositions.isEmpty {
            tsneInitialPositions = ids.map { id in
                let p = initialPositions[id] ?? CGPoint(x: center.x, y: center.y)
                return (x: Double(p.x), y: Double(p.y))
            }
        } else {
            tsneInitialPositions = nil
        }

        let input = TSNEKernel.Input(
            embeddings: embeddingArrays,
            ids: ids,
            perplexity: max(1.0, perplexity),
            maxIterations: 1000,
            initialPositions: tsneInitialPositions
        )

        let progressHandler: @Sendable (Double) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.requestVersion == version else { return }
                guard case .computing = self.state else { return }
                self.state = .computing(progress: progress)
            }
        }

        targetPositions = [:]

        // Intermediate position handler — updates targetPositions with per-emission tight bbox.
        // Frame-level interpolation in tickAnimation() smoothly lerps projectedPositions toward
        // these targets each frame, dampening any bbox-induced coordinate shifts between emissions.
        let capturedNoEmbeddingIds = noEmbeddingIds
        let capturedCenter = center
        let capturedSpread = spread
        let positionsHandler: @Sendable ([(id: UUID, x: Double, y: Double)], _ zValues: [Double]?) -> Void = { [weak self] rawPositions, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.requestVersion == version else { return }
                // Ignore stale emissions that arrive after computation finished
                guard case .computing = self.state else { return }
                self.targetPositions = Self.scaleToWorld(
                    rawPositions, center: capturedCenter, spread: capturedSpread,
                    noEmbeddingIds: capturedNoEmbeddingIds
                )
            }
        }

        let task = Task.detached(priority: .userInitiated) {
            await TSNEKernel.compute(input, progress: progressHandler, onPositions: positionsHandler)
        }
        projectionTask = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard version == requestVersion, !Task.isCancelled, !task.isCancelled else { return }
        projectionTask = nil

        // Final scaling with the converged positions
        guard !result.positions.isEmpty else {
            state = .failed("t-SNE produced no positions")
            return
        }

        // Set final positions as the lerp target — tickAnimation() will smoothly
        // converge projectedPositions toward them. Never assign projectedPositions
        // directly to avoid a one-frame snap (the lerp is always lagging the target).
        targetPositions = Self.scaleToWorld(
            result.positions, center: center, spread: spread,
            noEmbeddingIds: noEmbeddingIds
        )
        projectedNodeIds = nodeIds
        state = .ready
    }

    /// Scale raw t-SNE positions to world coordinates.
    private static func scaleToWorld(
        _ rawPositions: [(id: UUID, x: Double, y: Double)],
        center: CGPoint, spread: CGFloat,
        noEmbeddingIds: [UUID]
    ) -> [UUID: CGPoint] {
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for p in rawPositions {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        let rangeX = max(maxX - minX, 1)
        let rangeY = max(maxY - minY, 1)

        var positions: [UUID: CGPoint] = [:]
        for p in rawPositions {
            let nx = (p.x - minX) / rangeX - 0.5
            let ny = (p.y - minY) / rangeY - 0.5
            positions[p.id] = CGPoint(
                x: center.x + CGFloat(nx) * spread,
                y: center.y + CGFloat(ny) * spread
            )
        }

        if !noEmbeddingIds.isEmpty {
            let edgeRadius = spread * 0.6
            let angleStep = 2 * CGFloat.pi / CGFloat(noEmbeddingIds.count)
            for (i, id) in noEmbeddingIds.enumerated() {
                let angle = angleStep * CGFloat(i)
                positions[id] = CGPoint(
                    x: center.x + cos(angle) * edgeRadius,
                    y: center.y + sin(angle) * edgeRadius
                )
            }
        }

        return positions
    }

    // MARK: - Frame-Level Animation

    /// Lerps projectedPositions toward targetPositions each frame.
    /// Call at 60fps from the Canvas timer for smooth progressive animation.
    /// Automatically stops when positions have converged (max delta < 0.5px)
    /// to avoid unnecessary @Observable mutations that cause indefinite CPU load.
    func tickAnimation() {
        guard !targetPositions.isEmpty else { return }
        let alpha: CGFloat = 0.15  // 15% per frame at 60fps ≈ smooth ~100ms convergence
        var updated = projectedPositions
        var maxDelta: CGFloat = 0
        for (id, target) in targetPositions {
            let current = updated[id] ?? target
            let dx = target.x - current.x
            let dy = target.y - current.y
            maxDelta = max(maxDelta, abs(dx), abs(dy))
            updated[id] = CGPoint(x: current.x + dx * alpha, y: current.y + dy * alpha)
        }
        projectedPositions = updated

        // Once converged, snap to exact targets and stop ticking.
        // This prevents indefinite @Observable mutations at 60fps.
        if maxDelta < 0.5 {
            projectedPositions = targetPositions
            targetPositions = [:]
        }
    }

    // MARK: - 3D Projection

    @discardableResult func computeProjection3D(
        nodeIds: Set<UUID>, spread: Float,
        initialPositions: [UUID: SIMD3<Float>] = [:]
    ) async -> Bool {
        let version = requestVersion
        var ids: [UUID] = []
        var embeddingArrays: [[Float]] = []
        var noEmbeddingIds: [UUID] = []

        for id in nodeIds {
            if let emb = embeddings[id], !emb.isEmpty {
                ids.append(id)
                embeddingArrays.append(emb)
            } else {
                noEmbeddingIds.append(id)
            }
        }

        guard ids.count >= 2 else {
            state = .failed("Need at least 2 memories with embeddings")
            return false
        }

        state = .computing(progress: 0)

        let perplexity = min(30.0, Double(ids.count - 1) / 3.0)

        // Build initial positions from 3D force layout
        let tsneInitialPositions: [(x: Double, y: Double)]?
        if !initialPositions.isEmpty {
            tsneInitialPositions = ids.map { id in
                let p = initialPositions[id] ?? .zero
                return (x: Double(p.x), y: Double(p.y))
            }
        } else {
            tsneInitialPositions = nil
        }

        let input = TSNEKernel.Input(
            embeddings: embeddingArrays, ids: ids,
            perplexity: max(1.0, perplexity), maxIterations: 1000,
            initialPositions: tsneInitialPositions, outputDims: 3
        )

        let progressHandler: @Sendable (Double) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.requestVersion == version else { return }
                guard case .computing = self.state else { return }
                self.state = .computing(progress: progress)
            }
        }

        targetPositions3D = [:]

        let capturedNoEmbeddingIds = noEmbeddingIds
        let capturedSpread = spread
        let positionsHandler: @Sendable ([(id: UUID, x: Double, y: Double)], _ zValues: [Double]?) -> Void = { [weak self] rawPositions, zValues in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.requestVersion == version else { return }
                guard case .computing = self.state else { return }
                self.targetPositions3D = Self.scaleToWorld3D(
                    rawPositions, zValues: zValues, spread: capturedSpread,
                    noEmbeddingIds: capturedNoEmbeddingIds
                )
            }
        }

        let task = Task.detached(priority: .userInitiated) {
            await TSNEKernel.compute(input, progress: progressHandler, onPositions: positionsHandler)
        }
        projectionTask = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard version == requestVersion, !Task.isCancelled, !task.isCancelled else { return false }
        projectionTask = nil

        guard !result.positions.isEmpty else {
            state = .failed("t-SNE 3D produced no positions")
            return false
        }

        targetPositions3D = Self.scaleToWorld3D(
            result.positions, zValues: result.zValues, spread: spread,
            noEmbeddingIds: noEmbeddingIds
        )
        projectedNodeIds = nodeIds
        state = .ready
        return true
    }

    private static func scaleToWorld3D(
        _ rawPositions: [(id: UUID, x: Double, y: Double)],
        zValues: [Double]?,
        spread: Float,
        noEmbeddingIds: [UUID]
    ) -> [UUID: SIMD3<Float>] {
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude, minZ = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude, maxZ = -Double.greatestFiniteMagnitude
        let zVals = zValues ?? [Double](repeating: 0, count: rawPositions.count)
        for (i, p) in rawPositions.enumerated() {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            let zv = i < zVals.count ? zVals[i] : 0
            minZ = min(minZ, zv); maxZ = max(maxZ, zv)
        }
        let rangeX = max(maxX - minX, 1)
        let rangeY = max(maxY - minY, 1)
        let rangeZ = max(maxZ - minZ, 1)

        var positions: [UUID: SIMD3<Float>] = [:]
        for (i, p) in rawPositions.enumerated() {
            let nx = Float((p.x - minX) / rangeX - 0.5)
            let ny = Float((p.y - minY) / rangeY - 0.5)
            let zv = i < zVals.count ? zVals[i] : 0
            let nz = Float((zv - minZ) / rangeZ - 0.5)
            positions[p.id] = SIMD3(nx * spread, ny * spread, nz * spread)
        }

        if !noEmbeddingIds.isEmpty {
            let edgeRadius = spread * 0.6
            let angleStep = 2 * Float.pi / Float(noEmbeddingIds.count)
            for (i, id) in noEmbeddingIds.enumerated() {
                let angle = angleStep * Float(i)
                positions[id] = SIMD3(cos(angle) * edgeRadius, sin(angle) * edgeRadius, 0)
            }
        }

        return positions
    }

    /// Lerps projectedPositions3D toward targetPositions3D each frame.
    func tickAnimation3D() {
        guard !targetPositions3D.isEmpty else { return }
        let alpha: Float = 0.15
        var updated = projectedPositions3D
        var maxDelta: Float = 0
        for (id, target) in targetPositions3D {
            let current = updated[id] ?? target
            let delta = target - current
            maxDelta = max(maxDelta, abs(delta.x), abs(delta.y), abs(delta.z))
            updated[id] = current + delta * alpha
        }
        projectedPositions3D = updated

        if maxDelta < 0.5 {
            projectedPositions3D = targetPositions3D
            targetPositions3D = [:]
        }
    }

    // MARK: - Invalidation

    func invalidate() {
        requestVersion &+= 1
        embeddingTask?.cancel()
        projectionTask?.cancel()
        embeddingTask = nil
        projectionTask = nil
        state = .idle
        projectedPositions = [:]
        projectedPositions3D = [:]
        targetPositions = [:]
        targetPositions3D = [:]
        knowledgeVoids = []
        semanticClusters = []
        semanticClusters3D = []
        projectedNodeIds = []
    }

    func markStale() {
        // Don't clear positions — keep showing old projection with a stale badge
        if state == .ready {
            // State stays .ready but GraphView will check topology version
        }
    }
}
