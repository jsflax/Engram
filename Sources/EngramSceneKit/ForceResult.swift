import simd

/// GPU/CPU force computation result — decoupled from ForceSimulation3D for testability.
/// Supports two modes:
/// - Forces: raw force vectors for CPU integration (fx/fy/fz)
/// - Positions: GPU-integrated positions (positions array) — forces already applied with alpha
public struct ForceResult: Sendable {
    public let fx: [Float], fy: [Float], fz: [Float]
    /// GPU-integrated positions. When non-nil, forces were already integrated on GPU
    /// (with alpha scaling) and these positions should replace CPU arrays directly.
    public let positions: [SIMD3<Float>]?

    /// Opt-in monotonic stamp immediately before the existing MainActor task.
    /// Its queue interval excludes GPU execution and CPU readback; nil is unknown.
    public let diagnosticEnqueuedAt: UInt64?

    /// Per-phase timing breakdown (milliseconds). Populated by encodeForcePassSync.
    public var cpuPrepMs: Double = 0
    public var gpuMs: Double = 0
    public var readbackMs: Double = 0
    public var algorithm: String = ""

    public init(fx: [Float], fy: [Float], fz: [Float], diagnosticEnqueuedAt: UInt64? = nil) {
        self.fx = fx; self.fy = fy; self.fz = fz
        self.positions = nil
        self.diagnosticEnqueuedAt = diagnosticEnqueuedAt
    }

    public init(positions: [SIMD3<Float>], diagnosticEnqueuedAt: UInt64? = nil) {
        self.fx = []; self.fy = []; self.fz = []
        self.positions = positions
        self.diagnosticEnqueuedAt = diagnosticEnqueuedAt
    }
}
