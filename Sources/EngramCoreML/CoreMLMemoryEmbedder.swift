import Foundation
@preconcurrency import CoreML
import EngramMemoryCore
import Tokenizers
import Hub

/// Canonical bundled assets shared with the existing desktop EmbeddingService.
/// Keeping these in one resource bundle preserves exactly the same vector space.
public enum CoreMLMemoryAssets {
    public static var modelURL: URL? {
        assetURL("paraphrase-MiniLM-L6-v2_Embedding", extension: "mlmodelc")
    }
    public static var tokenizerDirectory: URL? {
        assetURL("paraphrase-MiniLM-L6-v2_tokenizer", extension: nil)
    }

    static func assetURL(_ name: String, extension ext: String?) -> URL? {
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
        let roots = [Bundle.main.resourceURL, executableDirectory,
                     executableDirectory?.deletingLastPathComponent().appendingPathComponent("Resources"),
                     Bundle.main.bundleURL].compactMap { $0 }
        return assetURL(name, extension: ext, bundleRoots: roots, fallback: { Bundle.module })
    }

    /// A signed app keeps resources under Contents/Resources; a standalone
    /// helper keeps them next to its executable. SwiftPM's generated accessor
    /// can trap when neither its build path nor Bundle.main.bundleURL contains
    /// the bundle, so evaluate it only after checking these installed layouts.
    static func assetURL(_ name: String, extension ext: String?, bundleRoots: [URL],
                         fallback: () -> Bundle) -> URL? {
        for root in bundleRoots {
            for bundleName in ["EngramPortable_EngramCoreML.bundle", "Engram_EngramCoreML.bundle"] {
                if let bundle = Bundle(url: root.appendingPathComponent(bundleName)),
                   let asset = bundle.url(forResource: name, withExtension: ext) {
                    return asset
                }
            }
        }
        return fallback().url(forResource: name, withExtension: ext)
    }
}

/// The same 384-dimensional MiniLM vector space used by desktop Engram and TEI.
/// All assets ship in this product's resource bundle. Loading never downloads a
/// model, tokenizer, or Hub configuration. The actor keeps inference serialized.
public actor CoreMLMemoryEmbedder: Embedder {
    public nonisolated static let modelIdentifier = "sentence-transformers/paraphrase-MiniLM-L6-v2"
    public nonisolated let dimension = 384

    public enum ComputePolicy: Sendable {
        case automatic, cpuOnly
    }
    public enum LoadError: Error, Sendable {
        case missingBundledResource(String)
        case invalidLocalAssets
        case incompatibleModel
        case invalidEmbedding
    }

    private let policy: ComputePolicy
    private let resourceDirectory: URL?
    private var loaded: Loaded?
    private var loading: Task<Loaded, Error>?

    /// Pass a local resource directory only for explicit host packaging or
    /// verification; it must contain both bundled-named model and tokenizer.
    /// A missing asset is an error, never permission to fetch another model.
    public init(computePolicy: ComputePolicy = .automatic, resourceDirectory: URL? = nil) {
        policy = computePolicy
        self.resourceDirectory = resourceDirectory
    }

    public var isLoaded: Bool { loaded != nil }

    /// Optional eager warm-up. embed() also loads on its first call. Hosts may
    /// show this failure in memory status; MemoryTools still persists offline.
    public func load() async throws {
        if loaded != nil { return }
        let task: Task<Loaded, Error>
        if let existing = loading { task = existing }
        else {
            let policy = policy, directory = resourceDirectory
            task = Task.detached(priority: .utility) {
                try Loaded.load(policy: policy, directory: directory)
            }
            loading = task
        }
        do {
            loaded = try await task.value
            loading = nil
            try Task.checkCancellation()
        } catch {
            loading = nil
            throw error
        }
    }

    public func embed(text: String) async throws -> [Float]? {
        try Task.checkCancellation()
        try await load()
        guard let loaded else { throw LoadError.incompatibleModel }
        let tokens = Array(loaded.tokenizer.encode(text: text).prefix(512))
        guard !tokens.isEmpty else { throw LoadError.invalidEmbedding }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "inputIds": MLFeatureValue(shapedArray: MLShapedArray<Int32>(
                scalars: tokens.map(Int32.init), shape: [1, tokens.count])),
            "attentionMask": MLFeatureValue(shapedArray: MLShapedArray<Float>(
                scalars: Array(repeating: 1, count: tokens.count), shape: [1, tokens.count])),
        ])
        // A synchronous prediction inside this actor prevents overlapping GPU
        // jobs from concurrent recall/backfill calls. This is never MainActor.
        let prediction = try loaded.predict(input)
        try Task.checkCancellation()
        guard let value = prediction.featureValue(for: "embeddings")?.multiArrayValue,
              value.count == dimension else { throw LoadError.invalidEmbedding }
        let vector = (0..<value.count).map { value[$0].floatValue }
        guard vector.allSatisfy(\.isFinite) else { throw LoadError.invalidEmbedding }
        return vector
    }

    /// Immutable after loading; accessed only by the owning embedder actor.
    private final class Loaded: @unchecked Sendable {
        let model: MLModel
        let tokenizer: any Tokenizer
        init(model: MLModel, tokenizer: any Tokenizer) {
            self.model = model; self.tokenizer = tokenizer
        }

        func predict(_ input: any MLFeatureProvider) throws -> any MLFeatureProvider {
            try model.prediction(from: input)
        }

        static func load(policy: ComputePolicy, directory: URL?) throws -> Loaded {
            if let directory, !directory.isFileURL { throw LoadError.invalidLocalAssets }
            func asset(_ name: String, _ ext: String?) throws -> URL {
                if let directory {
                    let url = directory.appendingPathComponent(name + (ext.map { "." + $0 } ?? ""))
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        throw LoadError.missingBundledResource(name)
                    }
                    return url
                }
                guard let url = CoreMLMemoryAssets.assetURL(name, extension: ext) else {
                    throw LoadError.missingBundledResource(name)
                }
                return url
            }
            let modelURL = try asset("paraphrase-MiniLM-L6-v2_Embedding", "mlmodelc")
            let tokenizerURL = try asset("paraphrase-MiniLM-L6-v2_tokenizer", nil)
            // Use the existing SwiftLM local JSON path. In particular, never
            // call AutoTokenizer.from(pretrained:), which can download assets.
            func config(_ name: String) throws -> Config {
                let json = try JSONSerialization.jsonObject(with: Data(contentsOf: tokenizerURL.appendingPathComponent(name)))
                guard let dictionary = json as? [NSString: Any] else { throw LoadError.invalidLocalAssets }
                return Config(dictionary)
            }
            let tokenizer = try AutoTokenizer.from(tokenizerConfig: config("tokenizer_config.json"),
                                                   tokenizerData: config("tokenizer.json"))
            let configuration = MLModelConfiguration()
            configuration.computeUnits = policy == .cpuOnly ? .cpuOnly : .all
            let model = try MLModel(contentsOf: modelURL, configuration: configuration)
            let metadata = model.modelDescription.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
            guard metadata["co.swiftlm.embedding_dim"] == "384",
                  metadata["co.swiftlm.pooling_strategy"] == "mean",
                  metadata["co.swiftlm.normalize_embeddings"] == "true",
                  metadata["co.huggingface.exporters.name"] == CoreMLMemoryEmbedder.modelIdentifier else {
                throw LoadError.incompatibleModel
            }
            return Loaded(model: model, tokenizer: tokenizer)
        }
    }
}
