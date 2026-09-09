import Foundation

/// One worker owns expensive CoreText work. A burst retains only its latest
/// immutable request, and obsolete completions never replace the visible atlas.
@MainActor
final class LabelAtlasBuildQueue {
    typealias Rasterize = @Sendable (AtlasRequest) async -> AtlasRaster?

    private let rasterize: Rasterize
    private let publish: @MainActor (AtlasRaster) -> Bool
    private(set) var needsRetry = false
    private var generation: UInt64 = 0
    private var latestInput: AtlasRequest?
    private var pending: (generation: UInt64, request: AtlasRequest)?
    private var active: (generation: UInt64, task: Task<Void, Never>)?

    init(rasterize: @escaping Rasterize, publish: @escaping @MainActor (AtlasRaster) -> Bool) {
        self.rasterize = rasterize
        self.publish = publish
    }

    func request(_ input: AtlasRequest) {
        guard input != latestInput else { return }
        needsRetry = false
        latestInput = input
        generation &+= 1
        pending = (generation, input)
        active?.task.cancel()
        startPendingIfIdle()
    }

    /// Called as soon as graph metadata changes, even inside the debounce
    /// window. Keep the published atlas, but prevent a now-stale build landing.
    func invalidate() {
        generation &+= 1
        latestInput = nil
        pending = nil
        needsRetry = false
        active?.task.cancel()
    }

    private func startPendingIfIdle() {
        guard active == nil, let next = pending else { return }
        pending = nil
        let rasterize = rasterize
        let task = Task.detached(priority: .utility) { [weak self] in
            let result = await rasterize(next.request)
            await self?.complete(generation: next.generation, result: result)
        }
        active = (next.generation, task)
    }

    private func complete(generation completedGeneration: UInt64, result: AtlasRaster?) {
        guard active?.generation == completedGeneration else { return }
        active = nil
        if completedGeneration == generation {
            if result.map(publish) != true {
                // Raster and GPU texture failures may both retry unchanged
                // input; the caller retains its normal debounce interval.
                latestInput = nil
                needsRetry = true
            }
        }
        startPendingIfIdle()
    }

    deinit {
        active?.task.cancel()
    }
}

/// Frame-based throttling with a retained dirty bit. A one-frame topology
/// notification inside the interval must still trigger a later atlas build.
struct LabelAtlasInvalidation {
    private var observedVersion: UInt64?
    private var lastRequestFrame: UInt64?
    private(set) var isDirty = false

    mutating func markDirty() {
        isDirty = true
    }

    mutating func observe(version: UInt64) -> Bool {
        guard observedVersion != version else { return false }
        observedVersion = version
        isDirty = true
        return true
    }

    mutating func shouldRequest(frame: UInt64) -> Bool {
        guard isDirty else { return false }
        if let lastRequestFrame, frame &- lastRequestFrame < 60 { return false }
        isDirty = false
        lastRequestFrame = frame
        return true
    }
}
