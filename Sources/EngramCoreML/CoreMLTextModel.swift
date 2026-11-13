import Foundation
@preconcurrency import CoreML
import Accelerate
import Tokenizers
import Hub

/// A desktop-compatible encoder for an explicitly selected CoreML model.
/// An explicit tokenizer directory is loaded locally. Without one, the model's
/// tokenizer identifier is resolved through the Hub, which may download assets.
/// Use CoreMLMemoryEmbedder for the bundled, strictly offline MiniLM contract.
public actor CoreMLTextModel {
    public nonisolated let embeddingDimension: Int

    public enum LoadError: Error, Equatable, Sendable {
        case missingTokenizerModelID
        case missingEmbeddingOutput
    }

    private let engine: CoreMLEmbeddingEngine
    private let configuration: CoreMLTextConfiguration

    private init(engine: CoreMLEmbeddingEngine, configuration: CoreMLTextConfiguration) {
        self.engine = engine
        self.configuration = configuration
        embeddingDimension = configuration.embeddingDimension
    }

    /// Compiles .mlpackage inputs and opens compiled inputs directly. The
    /// desktop compute policy remains CPU and GPU, without the Neural Engine.
    public static func load(url: URL, tokenizerDirectory: URL?) async throws -> CoreMLTextModel {
        let modelURL = try await CoreMLModelLocation.compiledURL(for: url) { source in
            try await MLModel.compileModel(at: source)
        }
        let options = MLModelConfiguration()
        options.computeUnits = .cpuAndGPU
        let model = try MLModel(contentsOf: modelURL, configuration: options)
        let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        let configuration = CoreMLTextConfiguration(metadata: metadata)
        let source = try CoreMLTokenizerSource.resolve(directory: tokenizerDirectory, modelID: configuration.modelID)
        let tokenizer: any Tokenizer
        switch source {
        case .local(let directory):
            tokenizer = try CoreMLEmbeddingEngine.localTokenizer(at: directory)
        case .hub(let identifier):
            tokenizer = try await AutoTokenizer.from(pretrained: identifier)
        }
        return CoreMLTextModel(engine: CoreMLEmbeddingEngine(model: model, tokenizer: tokenizer),
                               configuration: configuration)
    }

    public func embed(text: String) async throws -> [Float] {
        try await engine.desktopVector(text: text, configuration: configuration)
    }

    public func similarity(_ first: String, _ second: String) async throws -> Float {
        let a = try await embed(text: first)
        let b = try await embed(text: second)
        return CoreMLTextOutput.cosine(a, b)
    }
}

struct CoreMLTextConfiguration: Sendable {
    let modelID: String?
    let embeddingDimension: Int
    let maxSequenceLength: Int
    let normalizeEmbeddings: Bool

    init(metadata: [String: String]) {
        modelID = metadata["co.huggingface.exporters.name"]
        embeddingDimension = Int(metadata["co.swiftlm.embedding_dim"] ?? metadata["co.swiftlm.hidden_size"] ?? "") ?? 768
        maxSequenceLength = Int(metadata["co.swiftlm.max_position_embeddings"] ?? "") ?? 512
        normalizeEmbeddings = (metadata["co.swiftlm.normalize_embeddings"] ?? "true") == "true"
    }
}

enum CoreMLTokenizerSource: Equatable, Sendable {
    case local(URL)
    case hub(String)

    static func resolve(directory: URL?, modelID: String?) throws -> Self {
        if let directory { return .local(directory) }
        guard let modelID else { throw CoreMLTextModel.LoadError.missingTokenizerModelID }
        // The desktop facade has always used the explicit-optional loader.
        // Its nil path uses metadata; it does not search sibling directories.
        return .hub(modelID)
    }
}

enum CoreMLModelLocation {
    static func compiledURL(for url: URL, compile: @Sendable (URL) async throws -> URL) async throws -> URL {
        url.pathExtension == "mlpackage" ? try await compile(url) : url
    }
}

enum CoreMLTextOutput {
    static func vector(values: [Float], shape: [Int], configuration: CoreMLTextConfiguration) -> [Float] {
        if shape.count == 2 { return Array(values.suffix(configuration.embeddingDimension)) }
        guard shape.count == 3 else { return values }
        let tokens = shape[1], width = shape[2]
        var mean = [Float](repeating: 0, count: width)
        for token in 0..<tokens {
            for column in 0..<width { mean[column] += values[token * width + column] }
        }
        for column in mean.indices { mean[column] /= Float(tokens) }
        // Preserve the desktop convention: rank-three output is mean pooled,
        // regardless of the optional pooling-strategy metadata string.
        guard configuration.normalizeEmbeddings else { return mean }
        var sum: Float = 0
        vDSP_svesq(mean, 1, &sum, vDSP_Length(mean.count))
        var divisor = sqrt(sum)
        guard divisor != 0 else { return mean }
        var result = [Float](repeating: 0, count: mean.count)
        vDSP_vsdiv(mean, 1, &divisor, &result, 1, vDSP_Length(mean.count))
        return result
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var product: Float = 0
        var aSquared: Float = 0
        var bSquared: Float = 0
        vDSP_dotpr(a, 1, b, 1, &product, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &aSquared, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &bSquared, vDSP_Length(b.count))
        let denominator = sqrt(aSquared) * sqrt(bSquared)
        return denominator == 0 ? 0 : product / denominator
    }
}

/// Loaded model and tokenizer are immutable and stay behind an owning actor.
/// Both encoders use the same input and local-tokenizer path; their loading,
/// prediction scheduling and output validation contracts remain distinct.
final class CoreMLEmbeddingEngine: @unchecked Sendable {
    let model: MLModel
    let tokenizer: any Tokenizer

    init(model: MLModel, tokenizer: any Tokenizer) {
        self.model = model
        self.tokenizer = tokenizer
    }

    func input(text: String, limit: Int, requireTokens: Bool = false) throws -> MLDictionaryFeatureProvider {
        let tokens = Array(tokenizer.encode(text: text).prefix(limit))
        if requireTokens, tokens.isEmpty { throw CoreMLMemoryEmbedder.LoadError.invalidEmbedding }
        return try MLDictionaryFeatureProvider(dictionary: [
            "inputIds": MLFeatureValue(shapedArray: MLShapedArray<Int32>(
                scalars: tokens.map(Int32.init), shape: [1, tokens.count])),
            "attentionMask": MLFeatureValue(shapedArray: MLShapedArray<Float>(
                scalars: Array(repeating: 1, count: tokens.count), shape: [1, tokens.count])),
        ])
    }

    func predict(_ input: any MLFeatureProvider) throws -> any MLFeatureProvider {
        try model.prediction(from: input)
    }

    func desktopVector(text: String, configuration: CoreMLTextConfiguration) async throws -> [Float] {
        let input = try input(text: text, limit: configuration.maxSequenceLength)
        let prediction = try await model.prediction(from: input)
        guard let value = prediction.featureValue(for: "embeddings")?.multiArrayValue else {
            throw CoreMLTextModel.LoadError.missingEmbeddingOutput
        }
        return CoreMLTextOutput.vector(values: (0..<value.count).map { Float(truncating: value[$0]) },
                                       shape: value.shape.map(\.intValue), configuration: configuration)
    }

    static func localTokenizer(at directory: URL) throws -> any Tokenizer {
        func config(_ name: String) throws -> Config {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            let json = try JSONSerialization.jsonObject(with: data)
            guard let dictionary = json as? [NSString: Any] else {
                throw CoreMLMemoryEmbedder.LoadError.invalidLocalAssets
            }
            return Config(dictionary)
        }
        return try AutoTokenizer.from(tokenizerConfig: config("tokenizer_config.json"),
                                      tokenizerData: config("tokenizer.json"))
    }
}
