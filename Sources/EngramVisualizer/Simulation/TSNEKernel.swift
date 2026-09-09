import Foundation
import Accelerate

/// Pure t-SNE computation kernel. Runs on `@ForceSimulatorActor` (background). Fully `Sendable`.
///
/// Algorithm:
/// 1. Pairwise cosine distance matrix — O(n²) using vDSP for 384-dim dot products
/// 2. Perplexity calibration — binary search for sigma per point to match target perplexity
/// 3. Symmetrize P matrix — P_ij = (P(j|i) + P(i|j)) / 2n
/// 4. Gradient descent — 1000 iterations with early exaggeration (first 250 iters, 12x),
///    momentum (0.5 early, 0.8 late), learning rate 200. Student-t distribution in low-dim space.
struct TSNEKernel: Sendable {
    struct Input: Sendable {
        let embeddings: [[Float]]  // n x dim
        let ids: [UUID]
        let perplexity: Double     // default 30
        let maxIterations: Int     // default 1000
        let initialPositions: [(x: Double, y: Double)]?  // optional init from force layout
        let outputDims: Int        // 2 or 3

        init(embeddings: [[Float]], ids: [UUID], perplexity: Double, maxIterations: Int,
             initialPositions: [(x: Double, y: Double)]?, outputDims: Int = 2) {
            self.embeddings = embeddings
            self.ids = ids
            self.perplexity = perplexity
            self.maxIterations = maxIterations
            self.initialPositions = initialPositions
            self.outputDims = outputDims
        }
    }

    struct Output: Sendable {
        let positions: [(id: UUID, x: Double, y: Double)]
        /// Non-nil only when outputDims == 3
        let zValues: [Double]?
    }

    @ForceSimulatorActor
    static func compute(
        _ input: Input,
        progress: @Sendable (Double) -> Void,
        onPositions: @Sendable ([(id: UUID, x: Double, y: Double)], _ zValues: [Double]?) -> Void = { _, _ in }
    ) -> Output {
        let n = input.embeddings.count
        guard !Task.isCancelled else { return Output(positions: [], zValues: nil) }
        let D = input.outputDims  // output dimensionality (2 or 3)
        guard n >= 2 else {
            return Output(
                positions: input.ids.enumerated().map { (i, id) in (id: id, x: Double(i) * 50, y: 0) },
                zValues: D == 3 ? [Double](repeating: 0, count: input.ids.count) : nil
            )
        }

        // --- Step 1: Pairwise cosine distance matrix ---
        let dim = input.embeddings[0].count
        guard dim > 0 else {
            return Output(
                positions: input.ids.map { (id: $0, x: 0, y: 0) },
                zValues: D == 3 ? [Double](repeating: 0, count: n) : nil
            )
        }

        // Precompute norms
        var norms = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var sumSq: Float = 0
            vDSP_dotpr(input.embeddings[i], 1, input.embeddings[i], 1, &sumSq, vDSP_Length(dim))
            norms[i] = sqrt(sumSq)
        }

        // Distance matrix (cosine distance = 1 - cosine similarity)
        guard !Task.isCancelled else { return Output(positions: [], zValues: nil) }
        var dist = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            guard !Task.isCancelled else { return Output(positions: [], zValues: nil) }
            for j in (i + 1)..<n {
                var dot: Float = 0
                vDSP_dotpr(input.embeddings[i], 1, input.embeddings[j], 1, &dot, vDSP_Length(dim))
                let denom = norms[i] * norms[j]
                let cosDist: Double = denom > 0 ? Double(1 - dot / denom) : 1.0
                dist[i * n + j] = max(cosDist, 0)
                dist[j * n + i] = max(cosDist, 0)
            }
        }

        progress(0.1)

        // --- Step 2: Perplexity calibration (binary search for sigma per point) ---
        let targetEntropy = log(min(input.perplexity, Double(n - 1) / 3.0))
        guard !Task.isCancelled else { return Output(positions: [], zValues: nil) }
        var P = [Double](repeating: 0, count: n * n)  // conditional probabilities P(j|i)

        for i in 0..<n {
            var lo: Double = 1e-10
            guard !Task.isCancelled else { return Output(positions: [], zValues: nil) }
            var hi: Double = 1e4
            var sigma: Double = 1.0

            for _ in 0..<50 {  // binary search iterations
                sigma = (lo + hi) / 2
                let twoSigmaSq = 2.0 * sigma * sigma

                // Compute P(j|i) = exp(-d²/2σ²) / Σ_k exp(-d²_ik/2σ²)
                var sumExp: Double = 0
                for j in 0..<n where j != i {
                    let d = dist[i * n + j]
                    let val = exp(-d * d / twoSigmaSq)
                    P[i * n + j] = val
                    sumExp += val
                }
                if sumExp < 1e-300 { sumExp = 1e-300 }
                // Normalize and compute entropy
                var entropy: Double = 0
                for j in 0..<n where j != i {
                    P[i * n + j] /= sumExp
                    if P[i * n + j] > 1e-300 {
                        entropy -= P[i * n + j] * log(P[i * n + j])
                    }
                }

                if entropy > targetEntropy {
                    hi = sigma
                } else {
                    lo = sigma
                }
            }
        }

        progress(0.2)

        // --- Step 3: Symmetrize P matrix ---
        let twoN = Double(2 * n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let sym = (P[i * n + j] + P[j * n + i]) / twoN
                P[i * n + j] = max(sym, 1e-12)
                P[j * n + i] = max(sym, 1e-12)
            }
        }

        // --- Step 4: Gradient descent with early exaggeration ---
        // Y is interleaved: [x0,y0,(z0),x1,y1,(z1),...] with D components per point
        var Y = [Double](repeating: 0, count: n * D)

        // Initialize from force layout positions (for smooth visual transition) or random
        if let initPos = input.initialPositions, initPos.count == n {
            var meanX: Double = 0, meanY: Double = 0
            for p in initPos { meanX += p.x; meanY += p.y }
            meanX /= Double(n); meanY /= Double(n)
            var maxRange: Double = 1e-10
            for p in initPos {
                maxRange = max(maxRange, Swift.abs(p.x - meanX))
                maxRange = max(maxRange, Swift.abs(p.y - meanY))
            }
            let scale = 0.01 / maxRange
            for i in 0..<n {
                Y[i * D] = (initPos[i].x - meanX) * scale
                Y[i * D + 1] = (initPos[i].y - meanY) * scale
                if D == 3 {
                    // Initialize z with small random jitter
                    Y[i * D + 2] = Double.random(in: -0.005...0.005)
                }
            }
        } else {
            for i in 0..<(n * D) {
                Y[i] = Double.random(in: -0.01...0.01)
            }
        }

        var gains = [Double](repeating: 1, count: n * D)
        var velocities = [Double](repeating: 0, count: n * D)

        let earlyExaggerationIters = min(250, input.maxIterations / 4)
        let earlyExaggeration: Double = 12.0
        let learningRate: Double = 200.0

        let lastProgress = 0.2
        let progressRange = 0.8  // 0.2 to 1.0

        for iter in 0..<input.maxIterations {
            guard !Task.isCancelled else { return Output(positions: [], zValues: nil) }
            let momentum: Double = iter < earlyExaggerationIters ? 0.5 : 0.8
            let exaggeration: Double = iter < earlyExaggerationIters ? earlyExaggeration : 1.0

            // Compute Q distribution (Student-t with 1 DOF)
            var Q = [Double](repeating: 0, count: n * n)
            var sumQ: Double = 0
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var distSq: Double = 0
                    for d in 0..<D {
                        let diff = Y[i * D + d] - Y[j * D + d]
                        distSq += diff * diff
                    }
                    let qij = 1.0 / (1.0 + distSq)
                    Q[i * n + j] = qij
                    Q[j * n + i] = qij
                    sumQ += 2 * qij
                }
            }
            if sumQ < 1e-300 { sumQ = 1e-300 }

            // Compute gradients
            var gradients = [Double](repeating: 0, count: n * D)
            for i in 0..<n {
                for j in 0..<n where j != i {
                    let pij = P[i * n + j] * exaggeration
                    let qij = Q[i * n + j] / sumQ
                    let mult = 4.0 * (pij - qij) * Q[i * n + j]
                    for d in 0..<D {
                        gradients[i * D + d] += mult * (Y[i * D + d] - Y[j * D + d])
                    }
                }
            }

            // Update with adaptive gains and momentum
            for i in 0..<(n * D) {
                let sameSign = (gradients[i] > 0) == (velocities[i] > 0)
                gains[i] = sameSign ? max(gains[i] * 0.8, 0.01) : gains[i] + 0.2
                velocities[i] = momentum * velocities[i] - learningRate * gains[i] * gradients[i]
                Y[i] += velocities[i]
            }

            // Center the solution
            var means = [Double](repeating: 0, count: D)
            for i in 0..<n {
                for d in 0..<D { means[d] += Y[i * D + d] }
            }
            for d in 0..<D { means[d] /= Double(n) }
            for i in 0..<n {
                for d in 0..<D { Y[i * D + d] -= means[d] }
            }

            // Progress callback at ~10% intervals
            let iterProgress = lastProgress + progressRange * Double(iter + 1) / Double(input.maxIterations)
            if (iter + 1) % max(1, input.maxIterations / 10) == 0 {
                progress(iterProgress)
            }

            // Emit intermediate positions for progressive animation.
            // During early exaggeration: emit every 25 iters (positions are volatile but
            // frame-level lerp in EmbeddingProjection dampens jumps). After: every 10 iters.
            let emitInterval = iter < earlyExaggerationIters ? 25 : 10
            if (iter + 1) % emitInterval == 0 {
                var interPositions: [(id: UUID, x: Double, y: Double)] = []
                interPositions.reserveCapacity(n)
                var interZ: [Double]? = D == 3 ? [] : nil
                for i in 0..<n {
                    interPositions.append((id: input.ids[i], x: Y[i * D], y: Y[i * D + 1]))
                    if D == 3 { interZ!.append(Y[i * D + 2]) }
                }
                onPositions(interPositions, interZ)
            }
        }

        progress(1.0)

        // Build output
        var positions: [(id: UUID, x: Double, y: Double)] = []
        positions.reserveCapacity(n)
        var zValues: [Double]? = D == 3 ? [] : nil
        for i in 0..<n {
            positions.append((id: input.ids[i], x: Y[i * D], y: Y[i * D + 1]))
            if D == 3 { zValues!.append(Y[i * D + 2]) }
        }
        return Output(positions: positions, zValues: zValues)
    }
}
