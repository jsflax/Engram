import Foundation
import Testing
@testable import EngramCoreML

@Suite("Desktop embedding compatibility")
struct CoreMLTextModelTests {
    @Test func metadataKeepsCustomDimensionsAndLegacyDefaults() {
        let defaults = CoreMLTextConfiguration(metadata: [:])
        #expect(defaults.embeddingDimension == 768)
        #expect(defaults.maxSequenceLength == 512)
        #expect(defaults.normalizeEmbeddings)
        #expect(defaults.modelID == nil)

        let custom = CoreMLTextConfiguration(metadata: [
            "co.swiftlm.embedding_dim": "12",
            "co.swiftlm.hidden_size": "24",
            "co.swiftlm.max_position_embeddings": "37",
            "co.swiftlm.normalize_embeddings": "false",
            "co.huggingface.exporters.name": "custom/tokenizer",
        ])
        #expect(custom.embeddingDimension == 12)
        #expect(custom.maxSequenceLength == 37)
        #expect(!custom.normalizeEmbeddings)
        #expect(custom.modelID == "custom/tokenizer")
        #expect(CoreMLTextConfiguration(metadata: ["co.swiftlm.hidden_size": "24"]).embeddingDimension == 24)
        #expect(CoreMLTextConfiguration(metadata: [
            "co.swiftlm.embedding_dim": "invalid", "co.swiftlm.hidden_size": "24",
        ]).embeddingDimension == 768)
    }

    @Test func explicitTokenizerPrecedesMetadataAndNilUsesTheHub() throws {
        let directory = URL(fileURLWithPath: "/fixture/custom-tokenizer")
        #expect(try CoreMLTokenizerSource.resolve(directory: directory, modelID: "metadata/tokenizer") == .local(directory))
        #expect(try CoreMLTokenizerSource.resolve(directory: directory, modelID: nil) == .local(directory))
        // The facade calls the explicit-optional overload: nil uses metadata,
        // including when a sibling tokenizer happens to exist on disk.
        #expect(try CoreMLTokenizerSource.resolve(directory: nil, modelID: "metadata/tokenizer") == .hub("metadata/tokenizer"))
        #expect(throws: CoreMLTextModel.LoadError.missingTokenizerModelID) {
            try CoreMLTokenizerSource.resolve(directory: nil, modelID: nil)
        }
    }

    @Test func customModelPathCompilesPackagesAndKeepsCompiledPaths() async throws {
        let recorder = CompilationRecorder()
        let package = URL(fileURLWithPath: "/fixture/custom-model.mlpackage")
        let compiled = URL(fileURLWithPath: "/fixture/compiled-custom.mlmodelc")
        let result = try await CoreMLModelLocation.compiledURL(for: package) { url in
            await recorder.record(url)
            return compiled
        }
        #expect(result == compiled)
        #expect(await recorder.urls == [package])

        let existing = URL(fileURLWithPath: "/fixture/another-model.mlmodelc")
        let existingResult = try await CoreMLModelLocation.compiledURL(for: existing) { url in
            await recorder.record(url)
            return compiled
        }
        #expect(existingResult == existing)
        #expect(await recorder.urls == [package])
    }

    @Test func outputShapeKeepsSuffixAndMeanPoolingRules() {
        let config = CoreMLTextConfiguration(metadata: [
            "co.swiftlm.embedding_dim": "2",
            "co.swiftlm.normalize_embeddings": "false",
            // Existing custom models use mean pooling here even if metadata
            // names a different pooling strategy.
            "co.swiftlm.pooling_strategy": "cls",
        ])
        #expect(CoreMLTextOutput.vector(values: [8, 9, 2, 4], shape: [2, 2], configuration: config) == [2, 4])
        #expect(CoreMLTextOutput.vector(values: [2, 4, 6, 8], shape: [1, 2, 2], configuration: config) == [4, 6])
        #expect(CoreMLTextOutput.vector(values: [2, 4, 6], shape: [3], configuration: config) == [2, 4, 6])

        let normalized = CoreMLTextConfiguration(metadata: ["co.swiftlm.embedding_dim": "2"])
        let pooled = CoreMLTextOutput.vector(values: [3, 4, 3, 4], shape: [1, 2, 2], configuration: normalized)
        #expect(abs(pooled[0] - 0.6) < 0.000001)
        #expect(abs(pooled[1] - 0.8) < 0.000001)
        #expect(CoreMLTextOutput.vector(values: [0, 0], shape: [1, 1, 2], configuration: normalized) == [0, 0])
        // Already-pooled output is not normalized a second time.
        #expect(CoreMLTextOutput.vector(values: [3, 4], shape: [1, 2], configuration: normalized) == [3, 4])
    }

    @Test func similarityUsesCosineAndKeepsDegenerateResults() {
        #expect(CoreMLTextOutput.cosine([3, 4], [6, 8]) == 1)
        #expect(abs(CoreMLTextOutput.cosine([1, 0], [1, 1]) - Float(1 / sqrt(2.0))) < 0.000001)
        #expect(CoreMLTextOutput.cosine([1, 0], [-1, 0]) == -1)
        #expect(CoreMLTextOutput.cosine([0, 0], [1, 1]) == 0)
        #expect(CoreMLTextOutput.cosine([], []) == 0)
        #expect(CoreMLTextOutput.cosine([1], [1, 2]) == 0)
    }

    @Test func aMissingCustomModelDoesNotUseTheBundledModel() async {
        let missing = URL(fileURLWithPath: "/missing-model-" + UUID().uuidString + ".mlmodelc")
        await #expect(throws: (any Error).self) {
            try await CoreMLTextModel.load(url: missing, tokenizerDirectory: CoreMLMemoryAssets.tokenizerDirectory)
        }
    }

    @Test func explicitBundledAssetsLoadThroughTheCustomModelRoute() async throws {
        let modelURL = try #require(CoreMLMemoryAssets.modelURL)
        let tokenizer = try #require(CoreMLMemoryAssets.tokenizerDirectory)
        let model = try await CoreMLTextModel.load(url: modelURL, tokenizerDirectory: tokenizer)
        #expect(model.embeddingDimension == 384)
        let vector = try await model.embed(text: "A puppy plays outside.")
        #expect(vector.count == 384)
        #expect(vector.allSatisfy(\.isFinite))
        let same = try await model.similarity("A puppy plays outside.", "A puppy plays outside.")
        #expect(abs(same - 1) < 0.00001)
    }

    private actor CompilationRecorder {
        private(set) var urls: [URL] = []
        func record(_ url: URL) { urls.append(url) }
    }
}
