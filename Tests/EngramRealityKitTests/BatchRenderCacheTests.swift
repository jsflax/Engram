import Testing
@testable import EngramRealityKit

@Suite("Completed batch render caching")
@MainActor
struct BatchRenderCacheTests {
    private func state(positionVersion: UInt64 = 0, visible: [Int] = [0]) -> BatchRenderState {
        BatchRenderState(topology: 0, positions: positionVersion, visibleIndices: visible,
                         selection: nil, search: [], searchActive: false, colors: [:], scale: 1)
    }

    @Test("A failed upload retries unchanged inputs until it succeeds")
    func retriesFailedUpload() {
        let cache = BatchRenderCache()
        let input = state()
        var attempts = 0
        cache.update(input) { attempts += 1; return false }
        cache.update(input) { attempts += 1; return false }
        cache.update(input) { attempts += 1; return true }
        cache.update(input) { attempts += 1; return true }
        #expect(attempts == 3)
    }

    @Test("Partial failure requires restoring even previously completed inputs")
    func restoresAfterPartialFailure() {
        let cache = BatchRenderCache()
        var uploadedPositionVersion: UInt64 = 0
        var attempts = 0
        cache.update(state()) { attempts += 1; return true }
        cache.update(state(positionVersion: 1)) {
            attempts += 1
            uploadedPositionVersion = 1 // Transforms landed, but texture upload failed.
            return false
        }
        cache.update(state()) {
            attempts += 1
            uploadedPositionVersion = 0
            return true
        }
        #expect(attempts == 3)
        #expect(uploadedPositionVersion == 0)
    }

    @Test("An empty graph hides once and the next visible graph uploads")
    func emptyGraphTransitions() {
        let cache = BatchRenderCache()
        var attempts = 0
        cache.update(state()) { attempts += 1; return true }
        cache.update(state(visible: [])) { attempts += 1; return true }
        cache.update(state(visible: [])) { attempts += 1; return true }
        cache.update(state()) { attempts += 1; return true }
        #expect(attempts == 3)
    }
}
