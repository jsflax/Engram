import CoreGraphics
import Darwin
import Foundation
import Testing
@testable import EngramRealityKit

@Suite("Asynchronous label atlas", .timeLimit(.minutes(1)))
struct LabelAtlasBuildTests {
    private let nodeID = UUID()

    private func request(label: String = "original", project: String = "project",
                         topic: String = "topic", isHub: Bool = false,
                         hubs: Set<UUID> = [], projects: Set<String> = ["project"],
                         topics: Set<String> = ["topic"]) -> AtlasRequest {
        AtlasRequest(nodes: [RKNodeSnapshot(id: nodeID, project: project, topic: topic,
                                           label: label, importance: 1, isHub: isHub)],
                     hubs: hubs, projects: projects, topics: topics)
    }

    @Test("Same IDs invalidate for text, membership, cluster names, and hub styles")
    func contentInvalidation() {
        let original = request()
        #expect(original == request())
        #expect(original != request(label: "edited"))
        #expect(original != request(project: "moved"))
        #expect(original != request(topic: "moved"))
        #expect(original != request(projects: ["renamed"]))
        #expect(original != request(topics: ["renamed"]))
        #expect(original != request(isHub: true))
        #expect(original != request(hubs: [nodeID]))
    }

    @Test("A change inside debounce remains dirty until its frame arrives")
    func debounceRetainsChanges() {
        var invalidation = LabelAtlasInvalidation()
        let observedInitial = invalidation.observe(version: 1)
        let requestedInitial = invalidation.shouldRequest(frame: 0)
        let observedChange = invalidation.observe(version: 2)
        let requestedTooSoon = invalidation.shouldRequest(frame: 1)
        let observedDuplicate = invalidation.observe(version: 2)
        let requestedBeforeDeadline = invalidation.shouldRequest(frame: 59)
        let requestedAtDeadline = invalidation.shouldRequest(frame: 60)
        let requestedWhenClean = invalidation.shouldRequest(frame: 120)
        #expect(observedInitial)
        #expect(requestedInitial)
        #expect(observedChange)
        #expect(!requestedTooSoon)
        #expect(!observedDuplicate)
        #expect(!requestedBeforeDeadline)
        #expect(requestedAtDeadline)
        #expect(!requestedWhenClean)
    }

    @Test("One worker coalesces requests and rejects obsolete completion")
    @MainActor
    func coalescesPendingBuilds() async throws {
        let worker = ControlledAtlasRasterizer()
        let publication = AtlasPublicationRecorder()
        let queue = LabelAtlasBuildQueue(
            rasterize: { input in await worker.run(input, onMainThread: pthread_main_np() != 0) },
            publish: { raster in
                publication.record(raster)
                return true
            }
        )
        let first = request(label: "first")
        let newest = request(label: "newest")
        queue.request(first)
        let startedFirst = await worker.nextStarted()
        #expect(startedFirst.request == first)
        #expect(!startedFirst.onMainThread)

        queue.request(request(label: "superseded"))
        queue.request(newest)
        queue.request(newest)
        await worker.finish(startedFirst.id)

        let startedNewest = await worker.nextStarted()
        #expect(startedNewest.request == newest)
        #expect(publication.values.isEmpty)
        await worker.finish(startedNewest.id)
        await publication.waitForValue()
        #expect(publication.values.count == 1)
        #expect(await worker.startedCount == 2)
    }

    @Test("Invalidation preserves the visible atlas and rejects cancelled work")
    @MainActor
    func cancellationPreservesPublishedAtlas() async throws {
        let worker = ControlledAtlasRasterizer()
        let publication = AtlasPublicationRecorder()
        let queue = LabelAtlasBuildQueue(
            rasterize: { input in await worker.run(input, onMainThread: pthread_main_np() != 0) },
            publish: { raster in
                publication.record(raster)
                return true
            }
        )
        queue.request(request(label: "visible"))
        let visible = await worker.nextStarted()
        await worker.finish(visible.id)
        await publication.waitForValue()

        queue.request(request(label: "cancelled"))
        let cancelled = await worker.nextStarted()
        queue.invalidate()
        queue.request(request(label: "replacement"))
        await worker.finish(cancelled.id)
        let replacement = await worker.nextStarted()
        #expect(replacement.request.entries.first?.label == "replacement")
        #expect(publication.values.count == 1)
        await worker.finish(replacement.id)
        await publication.waitForValue(count: 2)
        #expect(publication.values.count == 2)
    }

    @Test("Raster output keeps cluster labels without node entries")
    func clusterOnlyAtlas() async throws {
        let input = AtlasRequest(nodes: [], hubs: [], projects: ["project"], topics: ["topic"])
        let output = await Task.detached { AtlasRasterizer.render(input) }.value
        let raster = try #require(output)
        #expect(raster.nodeRects.isEmpty)
        #expect(raster.projectRects["project"] != nil)
        #expect(raster.topicRects["topic"] != nil)
        #expect(raster.image.width > 0)
    }

    @Test("Failed texture publication allows retrying unchanged input")
    @MainActor
    func retriesFailedPublication() async {
        let worker = ControlledAtlasRasterizer()
        let publication = AtlasPublicationRecorder()
        let queue = LabelAtlasBuildQueue(
            rasterize: { input in await worker.run(input, onMainThread: pthread_main_np() != 0) },
            publish: { raster in
                publication.record(raster)
                return publication.values.count > 1
            }
        )
        let input = request()
        queue.request(input)
        let first = await worker.nextStarted()
        await worker.finish(first.id)
        await publication.waitForValue()
        #expect(queue.needsRetry)

        queue.request(input)
        let retry = await worker.nextStarted()
        #expect(retry.request == input)
        await worker.finish(retry.id)
        await publication.waitForValue(count: 2)
        #expect(!queue.needsRetry)
    }
    @Test(arguments: [false, true])
    func wideContractLabelsStayInsideCappedAtlasAndRetainFullSource(longNode: Bool) async throws {
        let project = String(repeating: "W", count: 256), topic = String(repeating: "M", count: 256)
        let label = longNode ? String(repeating: "W", count: 512) : String(repeating: "W", count: 100)
        let node = RKNodeSnapshot(id: nodeID, project: project, topic: topic, label: label, importance: 1, isHub: false)
        let input = AtlasRequest(nodes: [node], hubs: [], projects: [project], topics: [topic])
        let value = await Task.detached { AtlasRasterizer.render(input) }.value
        let raster = try #require(value)
        let layout = try #require(raster.layout)
        #expect(raster.image.width > 512 && raster.image.width <= 4096 && raster.image.height <= 4096)
        #expect(input.entries[0].label == label && input.projects == [project] && input.topics == [topic])
        #expect(layout.matches(nodes: [node], hubs: [], projects: [project], topics: [topic]))
        let nodeRect = try #require(raster.nodeRects[nodeID])
        let projectRect = try #require(raster.projectRects[project])
        let topicRect = try #require(raster.topicRects[topic])
        for rect in [nodeRect, projectRect, topicRect] {
            #expect(rect.u0 >= 0 && rect.u1 <= 1 && rect.v0 >= 0 && rect.v1 <= 1)
            #expect(rect.u1 > rect.u0 && rect.v1 > rect.v0)
        }
        // A maximum-byte ASCII project is wider than4096 before ellipsizing.
        #expect((projectRect.u1 - projectRect.u0) * Float(raster.image.width) <= 4096)
        let aspect = try #require(layout.projectAspects[project])
        #expect(abs(aspect - (projectRect.u1 - projectRect.u0) / (projectRect.v1 - projectRect.v0) * raster.aspectCorrection) < 0.0001)
    }

    @Test func maximumGraphLabelMetadataUsesExistingDetachedWorkerAndBoundedAtlas() async throws {
        let nodes = (0..<2000).map { index in
            RKNodeSnapshot(id: UUID(), project: "project", topic: "topic", label: "Memory \(index)", importance: 1, isHub: false)
        }
        let input = AtlasRequest(nodes: nodes, hubs: [], projects: ["project"], topics: ["topic"])
        let output = await Task.detached {
            (pthread_main_np() != 0, AtlasRasterizer.render(input))
        }.value
        #expect(!output.0)
        let raster = try #require(output.1)
        let layout = try #require(raster.layout)
        #expect(layout.matches(nodes: nodes, hubs: [], projects: ["project"], topics: ["topic"]))
        #expect(raster.image.width <= 4096 && raster.image.height <= 4096)
        #expect(layout.nodeAspects.count == raster.nodeRects.count && raster.nodeRects.count == 2000)
        #expect(raster.nodeRects.values.allSatisfy { $0.u0 >= 0 && $0.u1 <= 1 && $0.v0 >= 0 && $0.v1 <= 1 })
    }

    @Test @MainActor
    func publishedLayoutKeepsWorkerInputIdentityAcrossObsoleteCompletion() async throws {
        let worker = ControlledAtlasRasterizer(), publication = AtlasPublicationRecorder()
        let queue = LabelAtlasBuildQueue(
            rasterize: { input in await worker.run(input, onMainThread: pthread_main_np() != 0) },
            publish: { raster in publication.record(raster); return true })
        let old = request(label: "old"), current = request(label: "current")
        let oldValue = await Task.detached { AtlasRasterizer.render(old) }.value
        let currentValue = await Task.detached { AtlasRasterizer.render(current) }.value
        let oldRaster = try #require(oldValue), currentRaster = try #require(currentValue)
        queue.request(old)
        let first = await worker.nextStarted()
        #expect(!first.onMainThread)
        queue.request(current)
        await worker.finish(first.id, with: oldRaster)
        let second = await worker.nextStarted()
        #expect(!second.onMainThread && publication.values.isEmpty)
        await worker.finish(second.id, with: currentRaster)
        await publication.waitForValue()
        #expect(publication.values.count == 1)
        let layout = try #require(publication.values[0].layout)
        let node = RKNodeSnapshot(id: nodeID, project: "project", topic: "topic", label: "current", importance: 1, isHub: false)
        #expect(layout.matches(nodes: [node], hubs: [], projects: ["project"], topics: ["topic"]))
        let staleNode = RKNodeSnapshot(id: nodeID, project: "project", topic: "topic", label: "old", importance: 1, isHub: false)
        #expect(!layout.matches(nodes: [staleNode], hubs: [], projects: ["project"], topics: ["topic"]))
    }

}

/// Continuations keep these tests deterministic: the test controls completion
/// of the raster work, including work that deliberately ignores cancellation.
private actor ControlledAtlasRasterizer {
    struct Started: Sendable {
        let id: Int
        let request: AtlasRequest
        let onMainThread: Bool
    }

    private(set) var startedCount = 0
    private var started: [Started] = []
    private var startedWaiters: [CheckedContinuation<Started, Never>] = []
    private var finishing: [Int: (AtlasRequest, CheckedContinuation<AtlasRaster?, Never>)] = [:]

    func run(_ request: AtlasRequest, onMainThread: Bool) async -> AtlasRaster? {
        startedCount += 1
        let event = Started(id: startedCount, request: request, onMainThread: onMainThread)
        return await withCheckedContinuation { continuation in
            finishing[event.id] = (request, continuation)
            if startedWaiters.isEmpty {
                started.append(event)
            } else {
                startedWaiters.removeFirst().resume(returning: event)
            }
        }
    }

    func nextStarted() async -> Started {
        if !started.isEmpty { return started.removeFirst() }
        return await withCheckedContinuation { startedWaiters.append($0) }
    }

    func finish(_ id: Int, with raster: AtlasRaster? = nil) {
        guard let (_, continuation) = finishing.removeValue(forKey: id) else { return }
        if let raster { continuation.resume(returning: raster); return }
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        continuation.resume(returning: AtlasRaster(image: context.makeImage()!, nodeRects: [:],
                                                   projectRects: [:], topicRects: [:], aspectCorrection: 1))
    }
}

@MainActor
private final class AtlasPublicationRecorder {
    private(set) var values: [AtlasRaster] = []
    private var waiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    func record(_ raster: AtlasRaster) {
        values.append(raster)
        if let waiter, values.count >= waiter.count {
            self.waiter = nil
            waiter.continuation.resume()
        }
    }

    func waitForValue(count: Int = 1) async {
        guard values.count < count else { return }
        await withCheckedContinuation { waiter = (count, $0) }
    }
}
