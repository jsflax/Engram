import SwiftLM
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
    private var model: CoreMLEmbeddingModel?
    private let modelPath: String?
    private var loadingTask: Task<CoreMLEmbeddingModel?, Never>?

    /// Create an embedding service.
    /// - Parameter modelPath: Path to a `.mlpackage` or `.mlmodelc` model. If nil, uses the
    ///   bundled paraphrase-MiniLM-L6-v2 model from the app's resource bundle.
    public init(modelPath: String? = nil) {
        self.modelPath = modelPath
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
    private func _load(customPath: String?) async -> CoreMLEmbeddingModel? {
        let url: URL

        if let customPath {
            url = URL(fileURLWithPath: customPath)
        } else if let bundledURL = CoreMLMemoryAssets.modelURL {
            url = bundledURL
        } else {
            log("No embedding model found (not bundled, no CLAUDE_MEMORY_MODEL). Running in degraded mode (text search only).")
            return nil
        }

        do {
            // Find the tokenizer — check bundle first, then auto-discover alongside model
            let tokenizerDir: URL?
            if let bundledTokenizer = CoreMLMemoryAssets.tokenizerDirectory {
                tokenizerDir = bundledTokenizer
            } else {
                tokenizerDir = nil  // Let SwiftLM auto-discover from model path
            }

            let loaded = try await CoreMLEmbeddingModel.load(url: url, tokenizerDirectory: tokenizerDir)
            log("Loaded embedding model (dim=\(loaded.embeddingDimension))")
            return loaded
        } catch {
            log("Failed to load embedding model: \(error). Running in degraded mode.")
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

    public var dimension: Int { model?.embeddingDimension ?? 0 }

    public func embed(text: String) async throws -> [Float]? {
        await ensureLoaded()
        guard let model else { return nil }
        return try await model.embed(text: text)
    }

    public func similarity(_ text1: String, _ text2: String) async throws -> Float? {
        await ensureLoaded()
        guard let model else { return nil }
        return try await model.similarity(text1, text2)
    }

}
