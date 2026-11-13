import Foundation
import Testing
@testable import EngramKit

@Suite("Desktop embedding lifecycle", .timeLimit(.minutes(1)))
struct EmbeddingServiceOwnershipTests: Sendable {
    @Test func missingModelStaysDegraded() async throws {
        let service = EmbeddingService(modelPath: "/missing-embedding-" + UUID().uuidString)
        #expect(await service.dimension == 0)
        await service.load()
        #expect(await service.isLoaded == false)
        #expect(await service.dimension == 0)
        #expect(try await service.embed(text: "unavailable") == nil)
        #expect(try await service.similarity("one", "two") == nil)
    }

    @Test func constructionAndUnstartedReadsDoNotLoad() async throws {
        let calls = Calls()
        let service = service(calls: calls)
        #expect(await service.dimension == 0)
        #expect(await service.isLoaded == false)
        #expect(try await service.embed(text: "before start") == nil)
        #expect(try await service.similarity("one", "two") == nil)
        #expect(await calls.inputs.isEmpty)
    }

    @Test func customPathWinsAndBundledTokenizerStillWins() async throws {
        let calls = Calls()
        let custom = "/explicit/model.mlpackage"
        let service = service(calls: calls, modelPath: custom)
        await service.load()
        let inputs = await calls.inputs
        #expect(inputs.count == 1)
        #expect(inputs.first?.0 == URL(fileURLWithPath: custom))
        #expect(inputs.first?.1 == tokenizer)
        #expect(await service.dimension == 3)
        #expect(try await service.embed(text: "one") == [3, 0, 0])
        #expect(try await service.similarity("one", "two") == 0.6)
    }

    @Test func absentBundledTokenizerPassesMetadataFallbackToTheLoader() async throws {
        let calls = Calls()
        let service = service(calls: calls, tokenizerURL: nil)
        await service.load()
        let inputs = await calls.inputs
        #expect(inputs.count == 1)
        #expect(inputs.first?.0 == model)
        #expect(inputs.first?.1 == nil)
    }

    @Test func absentModelNeverInvokesTheLoader() async {
        let calls = Calls()
        let service = EmbeddingService(modelPath: nil, bundledModel: { nil },
            bundledTokenizer: { nil }, loader: { url, tokenizer in
                await calls.record(url, tokenizer)
                return Self.loadedModel
            })
        await service.load()
        #expect(await service.dimension == 0)
        #expect(await calls.inputs.isEmpty)
    }

    @Test func backgroundLoadIsJoinedAndDimensionStaysZeroUntilAdoption() async throws {
        let gate = LoadGate()
        defer { gate.release() }
        let calls = Calls()
        let service = EmbeddingService(modelPath: nil, bundledModel: { model },
            bundledTokenizer: { tokenizer }, loader: { url, tokenizer in
                await calls.record(url, tokenizer)
                await gate.enterAndWait()
                return Self.loadedModel
            })
        await service.startLoading()
        let entered = await gate.waitForEntry()
        try #require(entered, "Background loading never reached the loader")
        await service.startLoading()
        #expect(await calls.inputs.count == 1)
        #expect(await service.dimension == 0)
        #expect(await service.isLoaded == false)
        let read = Task { try await service.embed(text: "one") }
        gate.release()
        #expect(try await read.value == [3, 0, 0])
        #expect(await service.dimension == 3)
        #expect(await service.isLoaded)
        #expect(await calls.inputs.count == 1)
    }

    private var model: URL { URL(fileURLWithPath: "/bundled/model.mlmodelc") }
    private var tokenizer: URL { URL(fileURLWithPath: "/bundled/tokenizer") }

    private func service(calls: Calls, modelPath: String? = nil,
                         tokenizerURL: URL? = URL(fileURLWithPath: "/bundled/tokenizer")) -> EmbeddingService {
        EmbeddingService(modelPath: modelPath, bundledModel: { model },
            bundledTokenizer: { tokenizerURL }, loader: { url, tokenizer in
                await calls.record(url, tokenizer)
                return Self.loadedModel
            })
    }

    private static var loadedModel: EmbeddingService.Model {
        .init(dimension: 3, embed: { _ in [3, 0, 0] }, similarity: { a, b in
            #expect(a == "one" && b == "two")
            return 0.6
        })
    }

    private actor Calls {
        private(set) var inputs: [(URL, URL?)] = []
        func record(_ model: URL, _ tokenizer: URL?) { inputs.append((model, tokenizer)) }
    }

    private final class LoadGate: Sendable {
        private let entry = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        private let completion = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        func enterAndWait() async {
            entry.continuation.yield(())
            var iterator = completion.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        func waitForEntry() async -> Bool {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    var iterator = self.entry.stream.makeAsyncIterator()
                    return await iterator.next() != nil
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(10))
                    return false
                }
                defer { group.cancelAll() }
                return await group.next() ?? false
            }
        }
        func release() { completion.continuation.finish() }
    }
}
