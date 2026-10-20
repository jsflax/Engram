#!/usr/bin/env swift
/// Train a recall gate classifier using CreateML.
/// Input: MiniLM 384-dim embeddings. Output: "recall" or "skip".
///
/// Usage: swift scripts/train_recall_gate.swift
/// Output: Sources/EngramKit/Resources/RecallGateClassifier.mlmodelc

import CreateML
import CoreML
import Foundation
import TabularData

// MARK: - Training Data

struct Example {
    let text: String
    let label: String  // "recall" or "skip"
}

let examples: [Example] = [
    // =========================================================================
    // RECALL: queries where stored memories would genuinely help
    // =========================================================================

    // --- Short topical (1-5 words) ---
    Example(text: "Tell me about Lattice", label: "recall"),
    Example(text: "Swift concurrency patterns", label: "recall"),
    Example(text: "Metal rendering", label: "recall"),
    Example(text: "SQLite WAL mode", label: "recall"),
    Example(text: "NLTagger POS tagging", label: "recall"),
    Example(text: "CoreML model loading", label: "recall"),
    Example(text: "RealityKit particle system", label: "recall"),
    Example(text: "WebSocket sync protocol", label: "recall"),
    Example(text: "Kubernetes pod networking", label: "recall"),
    Example(text: "git rebase workflow", label: "recall"),
    Example(text: "Python virtual environments", label: "recall"),
    Example(text: "React component lifecycle", label: "recall"),
    Example(text: "database indexing performance", label: "recall"),
    Example(text: "Vapor server setup", label: "recall"),
    // --- "Tell me about X" pattern ---
    Example(text: "tell me about the sync daemon", label: "recall"),
    Example(text: "tell me about SwiftUI state management", label: "recall"),
    Example(text: "tell me about the recall algorithm", label: "recall"),
    Example(text: "tell me about Metal shaders", label: "recall"),
    Example(text: "tell me about the knowledge graph", label: "recall"),
    Example(text: "what about CoreData", label: "recall"),
    Example(text: "what about the mascot system", label: "recall"),
    Example(text: "what is t-SNE", label: "recall"),
    Example(text: "what is cosine similarity", label: "recall"),
    Example(text: "explain embeddings", label: "recall"),
    Example(text: "explain the MCP protocol", label: "recall"),
    // --- More short topical ---
    Example(text: "async await", label: "recall"),
    Example(text: "SwiftUI previews", label: "recall"),
    Example(text: "Xcode build settings", label: "recall"),
    Example(text: "launch daemon", label: "recall"),
    Example(text: "JSON parsing", label: "recall"),
    Example(text: "URLSession configuration", label: "recall"),
    Example(text: "memory leaks", label: "recall"),
    Example(text: "retain cycles", label: "recall"),
    Example(text: "unit testing patterns", label: "recall"),
    Example(text: "CI/CD pipeline", label: "recall"),
    Example(text: "Docker compose", label: "recall"),
    Example(text: "GraphQL schema", label: "recall"),
    Example(text: "REST API design", label: "recall"),
    Example(text: "OAuth authentication", label: "recall"),
    Example(text: "JWT tokens", label: "recall"),
    Example(text: "Redis caching", label: "recall"),

    // --- Single-sentence questions ---
    Example(text: "how does the sync system work", label: "recall"),
    Example(text: "what's the architecture of the visualizer", label: "recall"),
    Example(text: "debugging Metal shader compilation", label: "recall"),
    Example(text: "how does recall work in Engram", label: "recall"),
    Example(text: "explain the knowledge graph traversal", label: "recall"),
    Example(text: "what embedding model do we use", label: "recall"),
    Example(text: "how is the advise hook implemented", label: "recall"),
    Example(text: "where is the embedding service defined", label: "recall"),
    Example(text: "what are the SPM targets", label: "recall"),
    Example(text: "show me the recall algorithm", label: "recall"),
    Example(text: "where are we using NLTagger", label: "recall"),
    Example(text: "how would we fix the primary recall noise", label: "recall"),
    Example(text: "what's our testing strategy", label: "recall"),
    Example(text: "how do we handle errors in the sync pipeline", label: "recall"),
    Example(text: "explain the MCP server protocol", label: "recall"),
    Example(text: "how does the mascot chat work", label: "recall"),

    // --- Multi-sentence technical questions ---
    Example(text: "how much is the advise hook helping in this session? or is it mostly producing noise?", label: "recall"),
    Example(text: "I wanted to talk about traversing structural edges. Specifically, can we filter relates_to at depth 1 by distance threshold?", label: "recall"),
    Example(text: "The recall results are pulling in Metal rendering stuff when I'm asking about database queries. Why is the graph traversal so noisy?", label: "recall"),
    Example(text: "I think the adaptive outlier threshold is too permissive. The bestDistance * 3.0 multiplier lets in anything when results are sparse.", label: "recall"),
    Example(text: "We discussed using an ML model for auxiliary verb tagging a while ago. What approach did we decide on?", label: "recall"),
    Example(text: "The visualizer is showing jitter when the mascot visits nodes. I think it's related to the SwiftUI callback pattern we fixed before.", label: "recall"),
    Example(text: "Can you check how the sync daemon handles the case where two processes both have WSS connections? I think there's a data loss bug.", label: "recall"),
    Example(text: "Last session we fixed a bug in traverseGraph where hasStructuralEdge was checking all edges instead of the connecting edge. Is that deployed?", label: "recall"),

    // --- Task/action requests with technical content ---
    Example(text: "fix the authentication bug", label: "recall"),
    Example(text: "implement dark mode", label: "recall"),
    Example(text: "add a new API endpoint", label: "recall"),
    Example(text: "refactor the database layer", label: "recall"),
    Example(text: "Add a hard distance cap to the recall algorithm so that even with a permissive adaptive threshold, results beyond 0.35 are dropped.", label: "recall"),
    Example(text: "Write a test that verifies the graph traversal doesn't chain through filtered-out relates_to nodes at depth 2.", label: "recall"),
    Example(text: "The StatsOverlay is frozen because it gets let params from GraphView body instead of owning its own @LatticeQuery. Can you fix that pattern?", label: "recall"),
    Example(text: "I need you to update the Advise hook to extract content words using NLTagger before passing the query to directRecall.", label: "recall"),
    Example(text: "Can you profile the Metal encode pass? I think we're creating too many blit encoders per frame. The p95 encode_ms is 16ms.", label: "recall"),

    // --- Bug reports with context ---
    Example(text: "I'm getting a crash in CoreText TAttributes::ApplyFont when the mascot visits nodes. The stack trace shows NSString.draw being called during Metal draw callbacks.", label: "recall"),
    Example(text: "The build fails with 'input file was modified during build' when running swift test. Xcode seems to be touching MetalSceneManager.swift.", label: "recall"),
    Example(text: "After the GPU optimizations, there's visible frame jitter. Camera3DState uses @ObservationIgnored on all properties so it shouldn't be SwiftUI redraws.", label: "recall"),
    Example(text: "Memory writes work in regular sessions but fail with 'Connection closed' during maintenance subprocess runs. Stats and unfiltered recall still work.", label: "recall"),

    // --- Multi-paragraph / complex prompts ---
    Example(text: "I've been thinking about the recall quality problem. There are two separate issues: 1) the graph traversal pulls in unrelated memories via relates_to edges when the connected memory has a structural edge elsewhere, and 2) the primary recall results include distant memories because the adaptive outlier threshold scales relative to the best match.", label: "recall"),
    Example(text: "Here's what I want to do: first, fix the traverseGraph function to track which edge connected each memory during BFS. Then update handleRecall to pass a filter closure that checks the connecting edge type, not just whether the memory has any structural edge. Structural edges like part_of should always pass, but relates_to should require cosine distance <= 0.15.", label: "recall"),
    Example(text: "The maintenance agent keeps failing to write memories. I've seen this across 11 consecutive runs. Regular sessions write fine though — I created 30 new memories today. The pattern seems to be that high query volume during maintenance exhausts some resource. Can you look at the MCP connection handling?", label: "recall"),
    Example(text: "I want to add a recall gate classifier. The idea is: before the advise hook calls directRecall, classify whether the user's prompt is something that would benefit from memory recall, or if it's just conversational filler like 'yes' or 'sounds good'. A small CoreML model trained on MiniLM embeddings should work.", label: "recall"),

    // --- Code snippets in prompts ---
    Example(text: "This line is wrong: `let threshold = max(min(p75 * 1.2, bestDistance * 3.0), 1e-9)`. The 3.0 multiplier is way too generous. What should we change it to?", label: "recall"),
    Example(text: "Can you explain what this does?\n```swift\nlet connected = traverseGraph(\n    from: recalledGlobalIds,\n    depth: depth,\n    excludeGlobalIds: recalledGlobalIds,\n    db: db\n)\n```", label: "recall"),
    Example(text: "I'm seeing this error: `MCPError.invalidParams(\"Invalid relation 'dependsOn'. Must be one of: contradicts, derived_from, part_of, relates_to, summarized_by, supersedes\")`. How do I add a new relation type?", label: "recall"),

    // --- Operational/troubleshooting queries (still topical) ---
    Example(text: "can you check if the daemon is stuck?", label: "recall"),
    Example(text: "is the sync daemon running", label: "recall"),
    Example(text: "check the server logs", label: "recall"),
    Example(text: "is the MCP server connected", label: "recall"),
    Example(text: "why is the build failing", label: "recall"),
    Example(text: "the tests are hanging", label: "recall"),
    Example(text: "is the database locked", label: "recall"),
    Example(text: "check the process list for memory leaks", label: "recall"),
    Example(text: "is Xcode indexing still running", label: "recall"),
    Example(text: "the app crashed on launch", label: "recall"),
    Example(text: "can you check what's using port 8080", label: "recall"),
    Example(text: "is the websocket connection alive", label: "recall"),
    Example(text: "check if the migration ran", label: "recall"),
    Example(text: "is the cache stale", label: "recall"),
    Example(text: "why is it so slow", label: "recall"),
    Example(text: "something broke after the last change", label: "recall"),

    // --- Reference to past work ---
    Example(text: "remember when we fixed the label flickering issue? I think a similar z-fighting problem is happening with the edge rendering now", label: "recall"),
    Example(text: "we talked about this before - the mascot CoreText crash. did we end up using CTFont or NSFont.monospacedSystemFont?", label: "recall"),
    Example(text: "continue where we left off with the Metal GPU optimizations", label: "recall"),

    // --- Implicit topical queries ---
    Example(text: "what did we decide about the sync daemon architecture? I want to make sure we're not hitting that cross-process WSS bug", label: "recall"),
    Example(text: "I need to understand the memory token economics before I present Engram to the team. How many tokens does the advise hook inject?", label: "recall"),

    // =========================================================================
    // SKIP: conversational filler where recall adds no value
    // =========================================================================

    // --- Single word/token ---
    Example(text: "yes", label: "skip"),
    Example(text: "no", label: "skip"),
    Example(text: "ok", label: "skip"),
    Example(text: "sure", label: "skip"),
    Example(text: "thanks", label: "skip"),
    Example(text: "nice", label: "skip"),
    Example(text: "cool", label: "skip"),
    Example(text: "perfect", label: "skip"),
    Example(text: "great", label: "skip"),
    Example(text: "haha", label: "skip"),
    Example(text: "lol", label: "skip"),
    Example(text: "hmm", label: "skip"),
    Example(text: "idk", label: "skip"),
    Example(text: "nah", label: "skip"),
    Example(text: "yep", label: "skip"),
    Example(text: "nope", label: "skip"),
    Example(text: "exactly", label: "skip"),
    Example(text: "right", label: "skip"),
    Example(text: "agreed", label: "skip"),
    Example(text: "what", label: "skip"),
    Example(text: "huh", label: "skip"),
    Example(text: "wow", label: "skip"),
    Example(text: "damn", label: "skip"),

    // --- Short phrases (2-4 words) ---
    Example(text: "thank you", label: "skip"),
    Example(text: "sounds good", label: "skip"),
    Example(text: "let's do it", label: "skip"),
    Example(text: "go ahead", label: "skip"),
    Example(text: "try again", label: "skip"),
    Example(text: "got it", label: "skip"),
    Example(text: "makes sense", label: "skip"),
    Example(text: "i see", label: "skip"),
    Example(text: "oh interesting", label: "skip"),
    Example(text: "wait what", label: "skip"),
    Example(text: "never mind", label: "skip"),
    Example(text: "hold on", label: "skip"),
    Example(text: "one sec", label: "skip"),
    Example(text: "do that", label: "skip"),
    Example(text: "ship it", label: "skip"),
    Example(text: "that works", label: "skip"),
    Example(text: "good idea", label: "skip"),
    Example(text: "fair enough", label: "skip"),
    Example(text: "my bad", label: "skip"),
    Example(text: "oh right", label: "skip"),
    Example(text: "ah ok", label: "skip"),
    Example(text: "yeah totally", label: "skip"),
    Example(text: "for sure", label: "skip"),
    Example(text: "no worries", label: "skip"),
    Example(text: "all good", label: "skip"),
    Example(text: "LGTM", label: "skip"),

    // --- Short sentences (confirmations/reactions/directives) ---
    Example(text: "can you undo that", label: "skip"),
    Example(text: "is it way better?", label: "skip"),
    Example(text: "looks good to me", label: "skip"),
    Example(text: "actually nevermind", label: "skip"),
    Example(text: "that's not what I meant", label: "skip"),
    Example(text: "no that's wrong", label: "skip"),
    Example(text: "yeah that's fine", label: "skip"),
    Example(text: "just do it", label: "skip"),
    Example(text: "go with the first option", label: "skip"),
    Example(text: "the second one", label: "skip"),
    Example(text: "either works", label: "skip"),
    Example(text: "I don't care which", label: "skip"),
    Example(text: "whatever you think is best", label: "skip"),
    Example(text: "up to you", label: "skip"),
    Example(text: "your call", label: "skip"),
    Example(text: "I trust your judgment", label: "skip"),

    // --- Multi-sentence but still filler ---
    Example(text: "yeah that looks right. go ahead and do it.", label: "skip"),
    Example(text: "ok I see what you mean. let's go with that approach.", label: "skip"),
    Example(text: "no wait, undo that. I changed my mind.", label: "skip"),
    Example(text: "hmm I'm not sure about that. let me think about it.", label: "skip"),
    Example(text: "oh nice, that's much better. ship it.", label: "skip"),
    Example(text: "lol that's hilarious. anyway, keep going.", label: "skip"),
    Example(text: "thanks for explaining. makes sense now.", label: "skip"),
    Example(text: "I see what you did there. looks correct to me.", label: "skip"),
    Example(text: "sorry, I wasn't clear. what I meant was just do the simple version.", label: "skip"),
    Example(text: "nah, don't bother with that. it's not important.", label: "skip"),
    Example(text: "that's exactly what I wanted. nice work.", label: "skip"),
    Example(text: "I think you're overcomplicating it. just keep it simple.", label: "skip"),
    Example(text: "perfect, that's the fix. commit it.", label: "skip"),
    Example(text: "wait actually, can you revert that last change? I want to try something else.", label: "skip"),
    Example(text: "yeah I already tried that. didn't work.", label: "skip"),
    Example(text: "no no no, the other one. the second option you mentioned.", label: "skip"),
    Example(text: "ok fine, let's move on to something else.", label: "skip"),
    Example(text: "I agree with your analysis. proceed.", label: "skip"),
    Example(text: "good point. I hadn't thought of that.", label: "skip"),
    Example(text: "right, that makes more sense. do that instead.", label: "skip"),

    // --- Directives without topical content ---
    Example(text: "commit this", label: "skip"),
    Example(text: "push it", label: "skip"),
    Example(text: "revert that", label: "skip"),
    Example(text: "undo the last change", label: "skip"),
    Example(text: "show me the diff", label: "skip"),
    Example(text: "read that file", label: "skip"),
    Example(text: "open it", label: "skip"),
    Example(text: "delete that", label: "skip"),
    Example(text: "can you format this", label: "skip"),
    Example(text: "make it shorter", label: "skip"),
    Example(text: "add some comments", label: "skip"),
    Example(text: "rename that variable", label: "skip"),

    // --- Emotional/social ---
    Example(text: "you're amazing", label: "skip"),
    Example(text: "this is frustrating", label: "skip"),
    Example(text: "I'm confused", label: "skip"),
    Example(text: "that's annoying", label: "skip"),
    Example(text: "finally!", label: "skip"),
    Example(text: "about time", label: "skip"),
    Example(text: "I've been dealing with this all day", label: "skip"),
    Example(text: "ok I need a break", label: "skip"),
    Example(text: "you keep going for simple", label: "skip"),

    // --- Ambiguous but still filler (no searchable topic) ---
    Example(text: "why are you so opposed to that", label: "skip"),
    Example(text: "can we try a different approach", label: "skip"),
    Example(text: "is there a better way to do this", label: "skip"),
    Example(text: "what do you think about that", label: "skip"),
    Example(text: "how long will this take", label: "skip"),
    Example(text: "is this going to break anything", label: "skip"),
    Example(text: "are we done yet", label: "skip"),
    Example(text: "what's left to do", label: "skip"),
    Example(text: "can you explain that again", label: "skip"),
    Example(text: "I don't understand what you mean", label: "skip"),
    Example(text: "say that again but simpler", label: "skip"),
    Example(text: "too complicated. simplify.", label: "skip"),
    Example(text: "why did you do it that way", label: "skip"),
    Example(text: "wouldn't the other way be better", label: "skip"),
    Example(text: "small classifier sounds nice if it works?", label: "skip"),
    Example(text: "why are you so opposed to including a coreml classifier? they are super lightweight", label: "skip"),
    Example(text: "can use createML", label: "skip"),
    Example(text: "it's a swift thing", label: "skip"),
    Example(text: "but i feel like you need way more examples. sometimes i might prompt you in a very complex way, all your examples are a single sentence", label: "skip"),
    Example(text: "so are is this prompt injecting any extra context?", label: "skip"),
    Example(text: "is anything being injected into the prompt", label: "skip"),
    Example(text: "what context is being added to this message", label: "skip"),
    Example(text: "is the gate blocking this", label: "skip"),
    Example(text: "did it change anything", label: "skip"),
    Example(text: "did you rebuild it", label: "skip"),
    Example(text: "was that supposed to happen", label: "skip"),
    Example(text: "what just happened", label: "skip"),
    Example(text: "is that right", label: "skip"),
    Example(text: "does that look correct", label: "skip"),
    Example(text: "any errors?", label: "skip"),
    Example(text: "how's it going", label: "skip"),
]

// MARK: - Embedding

/// Load the MiniLM CoreML model and embed all training examples.
func loadEmbeddingModel() throws -> MLModel {
    // Look for the model in the EngramKit resources
    let modelPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/EngramCoreML/Resources/paraphrase-MiniLM-L6-v2_Embedding.mlmodelc")
    guard FileManager.default.fileExists(atPath: modelPath.path) else {
        fatalError("MiniLM model not found at \(modelPath.path). Run from the Engram project root.")
    }
    return try MLModel(contentsOf: modelPath)
}

func embed(text: String, model: MLModel) throws -> [Double] {
    // The MiniLM model expects tokenized input. For training purposes,
    // we'll use CreateML's built-in text features instead of raw embeddings.
    // This way the classifier works on text directly.
    fatalError("Use MLTextClassifier instead — it handles featurization internally")
}

// MARK: - Training

func train() throws {
    print("Preparing training data...")

    // Build a DataFrame for CreateML
    var texts: [String] = []
    var labels: [String] = []
    for ex in examples {
        texts.append(ex.text)
        labels.append(ex.label)
    }

    var dataFrame = DataFrame()
    dataFrame.append(column: Column(name: "text", contents: texts))
    dataFrame.append(column: Column(name: "label", contents: labels))

    let (trainingData, testingData) = dataFrame.randomSplit(by: 0.8)

    print("Training: \(trainingData.rows.count) examples, Testing: \(testingData.rows.count) examples")

    // Train a text classifier
    let params = MLTextClassifier.ModelParameters(
        algorithm: .transferLearning(.elmoEmbedding, revision: nil)  // ELMo-based transfer learning
    )

    let classifier = try MLTextClassifier(
        trainingData: DataFrame(trainingData),
        textColumn: "text",
        labelColumn: "label",
        parameters: params
    )

    // Evaluate
    let metrics = classifier.evaluation(on: DataFrame(testingData), textColumn: "text", labelColumn: "label")
    print("Training error: \(classifier.trainingMetrics.classificationError)")
    print("Validation error: \(metrics.classificationError)")
    print("Training accuracy: \(1.0 - classifier.trainingMetrics.classificationError)")
    print("Validation accuracy: \(1.0 - metrics.classificationError)")

    // Test specific examples
    let testCases: [(String, String)] = [
        ("Tell me about Lattice", "recall"),
        ("yes", "skip"),
        ("is it way better?", "skip"),
        ("how does the sync system work", "recall"),
        ("sounds good", "skip"),
        ("The recall results are pulling in Metal rendering stuff when I'm asking about database queries", "recall"),
        ("yeah that looks right. go ahead and do it.", "skip"),
        ("Metal rendering", "recall"),
        ("lol", "skip"),
        ("run the tests", "recall"),
        ("I'm getting a crash in CoreText TAttributes::ApplyFont when the mascot visits nodes", "recall"),
        ("perfect, that's the fix. commit it.", "skip"),
        ("can you undo that", "skip"),
        ("what embedding model do we use", "recall"),
        ("but i feel like you need way more examples. sometimes i might prompt you in a very complex way", "skip"),
    ]
    print("\n--- Predictions ---")
    var correct = 0
    for (text, expected) in testCases {
        let pred = try classifier.prediction(from: text)
        let mark = pred == expected ? "✓" : "✗"
        if pred == expected { correct += 1 }
        print("\(mark) \"\(text.prefix(60))...\" → \(pred) (expected: \(expected))")
    }
    print("Test accuracy: \(correct)/\(testCases.count)")

    // Save
    let outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/EngramKit/Resources")

    let metadata = MLModelMetadata(
        author: "Engram",
        shortDescription: "Classifies user queries as recall-worthy or conversational filler",
        version: "1.0"
    )

    // Save as .mlmodel (source format)
    let sourceURL = outputDir.appendingPathComponent("RecallGateClassifier.mlmodel")
    if FileManager.default.fileExists(atPath: sourceURL.path) {
        try FileManager.default.removeItem(at: sourceURL)
    }
    try classifier.write(to: sourceURL, metadata: metadata)
    print("Source model saved to: \(sourceURL.path)")

    // Compile to .mlmodelc
    let compiledURL = try MLModel.compileModel(at: sourceURL)
    let destURL = outputDir.appendingPathComponent("RecallGateClassifier.mlmodelc")
    if FileManager.default.fileExists(atPath: destURL.path) {
        try FileManager.default.removeItem(at: destURL)
    }
    try FileManager.default.moveItem(at: compiledURL, to: destURL)
    print("Compiled model saved to: \(destURL.path)")

    // Clean up source
    try FileManager.default.removeItem(at: sourceURL)

    // Print model size
    let enumerator = FileManager.default.enumerator(at: destURL, includingPropertiesForKeys: [.fileSizeKey])
    var totalSize = 0
    while let fileURL = enumerator?.nextObject() as? URL {
        let attrs = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        totalSize += attrs.fileSize ?? 0
    }
    print("Model size: \(totalSize / 1024) KB")
}

do {
    try train()
} catch {
    print("Training failed: \(error)")
    exit(1)
}
