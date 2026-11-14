import EngramCoreML
import Foundation

/// Manages the CoreML embedding model for semantic memory search.
///
/// Loads paraphrase-MiniLM-L6-v2 (bundled as a SwiftPM resource by default)
/// to generate 384-dimensional embeddings for vector similarity search.
/// Falls back to text-based search if the model fails to load.
///
/// Model loading happens in the background so it doesn't block MCP server startup.
/// The first call to `embed()` will await loading completion.
public actor EmbeddingService {
    struct Model: Sendable {
        let dimension: Int
        let embed: @Sendable (String) async throws -> [Float]
        let similarity: @Sendable (String, String) async throws -> Float
    }
    typealias Loader = @Sendable (URL, URL?) async throws -> Model

    private var model: Model?
    private let modelPath: String?
    private let bundledModel: @Sendable () -> URL?
    private let bundledTokenizer: @Sendable () -> URL?
    private let loader: Loader
    private let diagnosticSink: @Sendable (String) -> Void
    private var loadingTask: Task<Model?, Never>?

    /// Create an embedding service.
    /// - Parameter modelPath: Path to a `.mlpackage` or `.mlmodelc` model. If nil, uses the
    ///   bundled paraphrase-MiniLM-L6-v2 model from the app's resource bundle.
    public init(modelPath: String? = nil) {
        self.init(modelPath: modelPath, diagnosticSink: { log($0) })
    }

    /// Uses the production assets and loader with an explicit diagnostic sink.
    init(modelPath: String? = nil,
         diagnosticSink: @escaping @Sendable (String) -> Void) {
        self.modelPath = modelPath
        self.diagnosticSink = diagnosticSink
        bundledModel = { CoreMLMemoryAssets.modelURL }
        bundledTokenizer = { CoreMLMemoryAssets.tokenizerDirectory }
        loader = { url, tokenizer in
            let model = try await CoreMLTextModel.load(url: url, tokenizerDirectory: tokenizer)
            return Model(dimension: model.embeddingDimension,
                embed: { try await model.embed(text: $0) },
                similarity: { try await model.similarity($0, $1) })
        }
    }

    /// The same loading boundary used by production, with deterministic assets
    /// and a suspended loader available to lifecycle tests.
    init(modelPath: String?, bundledModel: @escaping @Sendable () -> URL?,
         bundledTokenizer: @escaping @Sendable () -> URL?, loader: @escaping Loader,
         diagnosticSink: @escaping @Sendable (String) -> Void) {
        self.modelPath = modelPath
        self.bundledModel = bundledModel
        self.bundledTokenizer = bundledTokenizer
        self.loader = loader
        self.diagnosticSink = diagnosticSink
    }

    /// Begin loading the model in the background.
    /// Call this early to start loading, then `embed()` will await completion.
    public func startLoading() {
        guard loadingTask == nil else { return }
        let path = self.modelPath
        loadingTask = Task { [weak self] in
            await self?._load(customPath: path)
        }
    }

    /// Load the model, awaiting background loading if already started.
    /// Used by tests that need the model ready immediately.
    public func load() async {
        if let task = loadingTask {
            model = await task.value
            loadingTask = nil
        } else {
            model = await _load(customPath: modelPath)
        }
    }

    /// Internal loading implementation.
    private func _load(customPath: String?) async -> Model? {
        let url: URL

        if let customPath {
            url = URL(fileURLWithPath: customPath)
        } else if let bundledURL = bundledModel() {
            url = bundledURL
        } else {
            diagnosticSink("No embedding model found (not bundled, no CLAUDE_MEMORY_MODEL). Running in degraded mode (text search only).")
            return nil
        }

        do {
            // Preserve the explicit-optional loading route: the bundle wins,
            // otherwise the model metadata selects the Hub tokenizer.
            let loaded = try await loader(url, bundledTokenizer())
            diagnosticSink("Loaded embedding model (dim=\(loaded.dimension))")
            return loaded
        } catch {
            diagnosticSink("Failed to load embedding model: \(error). Running in degraded mode.")
            return nil
        }
    }

    /// Ensure model is loaded, awaiting background loading if in progress.
    private func ensureLoaded() async {
        if model != nil { return }
        if let task = loadingTask {
            model = await task.value
            loadingTask = nil
        }
    }

    public var isLoaded: Bool { model != nil }

    public var dimension: Int { model?.dimension ?? 0 }

    public func embed(text: String) async throws -> [Float]? {
        await ensureLoaded()
        guard let model else { return nil }
        return try await model.embed(text)
    }

    public func similarity(_ text1: String, _ text2: String) async throws -> Float? {
        await ensureLoaded()
        guard let model else { return nil }
        return try await model.similarity(text1, text2)
    }

}
