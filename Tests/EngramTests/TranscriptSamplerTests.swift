import Testing
import EngramKit
import EngramMemoryCore
import Lattice
import MCP
import Foundation

// MARK: - JSONL Parsing

@Test func extractAssistantTextBlocks_parsesTextBlocks() {
    let jsonl = makeFakeTranscript([
        ("user", "how do I fix the crash?"),
        ("assistant", "Let me investigate the crash in your UIKit code."),
        ("assistant", nil),  // tool_use only, no text
        ("assistant", "The root cause is that UITableView deselects rows during trait collection changes."),
    ])
    let path = writeTempFile(jsonl)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let blocks = TranscriptSampler.extractAssistantTextBlocks(from: path)
    #expect(blocks.count == 2)
    #expect(blocks[0].contains("investigate the crash"))
    #expect(blocks[1].contains("root cause"))
}

@Test func extractAssistantTextBlocks_skipsThinkingAndToolUse() {
    let line = makeJsonlLine(type: "assistant", content: [
        ["type": "thinking", "thinking": "Let me think about this..."],
        ["type": "tool_use", "id": "toolu_123", "name": "Read", "input": ["file_path": "/foo"]],
    ])
    let path = writeTempFile(line)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let blocks = TranscriptSampler.extractAssistantTextBlocks(from: path)
    #expect(blocks.isEmpty)
}

@Test func extractAssistantTextBlocks_ignoresUserMessages() {
    let jsonl = [
        makeJsonlLine(type: "user", message: ["role": "user", "content": "hello world"]),
        makeJsonlLine(type: "assistant", content: [["type": "text", "text": "Hi there!"]]),
    ].joined(separator: "\n")
    let path = writeTempFile(jsonl)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let blocks = TranscriptSampler.extractAssistantTextBlocks(from: path)
    #expect(blocks.count == 1)
    #expect(blocks[0] == "Hi there!")
}

@Test func extractAssistantTextBlocks_handlesEmptyFile() {
    let path = writeTempFile("")
    defer { try? FileManager.default.removeItem(atPath: path) }

    let blocks = TranscriptSampler.extractAssistantTextBlocks(from: path)
    #expect(blocks.isEmpty)
}

// MARK: - Sampling with Novelty Scoring

@Test func sample_ranksNovelExcerptsHigher() async throws {
    let ctx = try await makeSamplerContext()

    // Seed memories about Swift concurrency — this topic is "known"
    for i in 0..<5 {
        _ = try await ctx.tools.handle(CallTool.Parameters(
            name: "remember",
            arguments: [
                "content": .string("Swift async/await structured concurrency patterns and task groups for parallel execution variant \(i)"),
                "force": .bool(true),
            ]
        ))
    }

    // Transcript with known topic (Swift concurrency) and novel topic (Kubernetes)
    let jsonl = makeFakeTranscript([
        ("assistant", padTo150("Swift concurrency uses async/await and TaskGroup for structured parallel execution. The key benefit is automatic cancellation propagation.")),
        ("assistant", padTo150("Kubernetes deployment strategy uses rolling updates with readiness probes. The pod disruption budget ensures at least 2 replicas stay running during deploys.")),
        ("assistant", "ok"),  // short — should be filtered out
        ("assistant", padTo150("To configure the Kubernetes ingress controller, set up an nginx-based LoadBalancer service with TLS termination and rate limiting annotations.")),
        ("assistant", padTo150("Swift actors provide data isolation for concurrent access. Each actor has a serial executor that processes messages one at a time.")),
    ])
    let transcriptPath = writeTempFile(jsonl)
    defer { try? FileManager.default.removeItem(atPath: transcriptPath) }

    let excerpts = await TranscriptSampler.sample(
        transcriptPath: transcriptPath,
        lattice: ctx.lattice,
        embedder: ctx.embedder,
        maxExcerpts: 4,
        maxCharsPerExcerpt: 500,
        maxTotalChars: 3000
    )

    // Novelty threshold filters the close rehash (async/await, dist ~0.23) and "ok" (too short).
    // Kubernetes (very novel) ranks highest. The actors excerpt (dist ~0.37) may survive
    // because "actors + serial executor" is a distinct subtopic from the seeded "async/await + TaskGroup" memories.
    let kubernetesExcerpts = excerpts.filter { $0.text.contains("Kubernetes") || $0.text.contains("ingress") }

    #expect(!kubernetesExcerpts.isEmpty, "Novel Kubernetes content should survive novelty filter")

    // Kubernetes should always rank first (highest novelty)
    if let first = excerpts.first {
        #expect(first.text.contains("Kubernetes") || first.text.contains("ingress"),
                "Most novel excerpt should be Kubernetes, got: \(first.text.prefix(60))...")
    }

    // The close rehash of async/await should be filtered
    let closeRehash = excerpts.first { $0.text.contains("async/await") && $0.text.contains("TaskGroup") }
    #expect(closeRehash == nil, "Close paraphrase of seeded async/await content should be filtered")
}

@Test func sample_respectsCharBudget() async throws {
    let ctx = try await makeSamplerContext()

    var entries: [(String, String?)] = []
    for i in 0..<10 {
        entries.append(("assistant", padTo150("This is a detailed explanation about topic number \(i) covering various aspects of the implementation including edge cases and performance.")))
    }
    let jsonl = makeFakeTranscript(entries)
    let transcriptPath = writeTempFile(jsonl)
    defer { try? FileManager.default.removeItem(atPath: transcriptPath) }

    let excerpts = await TranscriptSampler.sample(
        transcriptPath: transcriptPath,
        lattice: ctx.lattice,
        embedder: ctx.embedder,
        maxExcerpts: 10,
        maxCharsPerExcerpt: 200,
        maxTotalChars: 500
    )

    let totalChars = excerpts.reduce(0) { $0 + $1.charLength }
    #expect(totalChars <= 500, "Total chars \(totalChars) should be within budget of 500")
}

@Test func sample_returnsEmptyForTrivialTranscript() async throws {
    let ctx = try await makeSamplerContext()

    let jsonl = makeFakeTranscript([
        ("assistant", "Sure, I'll fix that."),
        ("assistant", "Done."),
        ("assistant", "You're welcome!"),
    ])
    let transcriptPath = writeTempFile(jsonl)
    defer { try? FileManager.default.removeItem(atPath: transcriptPath) }

    let excerpts = await TranscriptSampler.sample(
        transcriptPath: transcriptPath,
        lattice: ctx.lattice,
        embedder: ctx.embedder
    )

    #expect(excerpts.isEmpty, "Trivial transcript with short messages should produce no excerpts")
}

@Test func sample_distinguishesNovelInsightWithinSameTopic() async throws {
    let ctx = try await makeSamplerContext()

    // Seed memories about Swift concurrency — general knowledge
    let knownFacts = [
        "Swift async/await provides structured concurrency with automatic cancellation propagation through task hierarchies",
        "Swift TaskGroup allows parallel execution of dynamic numbers of child tasks with automatic cleanup on scope exit",
        "Swift actors provide data isolation by serializing access through a serial executor, preventing data races",
        "Swift async let enables concurrent execution of a fixed number of tasks that are awaited together",
        "Swift structured concurrency ensures child tasks complete before parent scope exits, preventing orphaned work",
    ]
    for fact in knownFacts {
        _ = try await ctx.tools.handle(CallTool.Parameters(
            name: "remember",
            arguments: [
                "content": .string(fact),
                "force": .bool(true),
            ]
        ))
    }

    // Transcript: one rehash of known content, one novel discovery within the SAME topic
    let rehash = padTo150("Swift concurrency uses structured task groups and async/await for parallel execution with automatic cancellation. Child tasks are always cleaned up when the parent scope exits.")
    let novelInsight = padTo150("Discovered that TaskGroup cancellation fires in reverse-add order. When child tasks hold locks, this reverse ordering causes deadlock because task N waits for task N-1's lock, but task N-1 is already cancelled and waiting. The fix is to release locks in a defer block before the cancellation check point.")

    let jsonl = makeFakeTranscript([
        ("assistant", rehash),
        ("assistant", novelInsight),
    ])
    let transcriptPath = writeTempFile(jsonl)
    defer { try? FileManager.default.removeItem(atPath: transcriptPath) }

    let excerpts = await TranscriptSampler.sample(
        transcriptPath: transcriptPath,
        lattice: ctx.lattice,
        embedder: ctx.embedder,
        maxExcerpts: 2,
        maxCharsPerExcerpt: 500,
        maxTotalChars: 2000
    )

    // With novelty threshold: rehash (dist ~0.23) should be filtered, novel (dist ~0.50) should survive
    let rehashExcerpt = excerpts.first { $0.text.contains("structured task groups") }
    let novelExcerpt = excerpts.first { $0.text.contains("reverse-add order") }

    #expect(rehashExcerpt == nil, "Rehash should be filtered by novelty threshold")
    #expect(novelExcerpt != nil, "Novel insight should survive novelty threshold")

    if let novelExcerpt {
        print("Novel insight distance: \(novelExcerpt.minDistance)")
        #expect(novelExcerpt.minDistance > TranscriptSampler.defaultNoveltyThreshold,
                "Novel excerpt distance (\(novelExcerpt.minDistance)) should exceed threshold (\(TranscriptSampler.defaultNoveltyThreshold))")
    }
}

@Test func sample_subtleNoveltyWithinSameTopic() async throws {
    let ctx = try await makeSamplerContext()

    // Seed: specific knowledge about Swift actor reentrancy
    let knownFacts = [
        "Swift actors are reentrant by default — when an actor method hits an await, other calls can execute before the first resumes",
        "Actor reentrancy means mutable state can change across await points, so you must re-check invariants after every await",
        "The nonisolated keyword lets you opt methods out of actor isolation when they only read immutable state",
    ]
    for fact in knownFacts {
        _ = try await ctx.tools.handle(CallTool.Parameters(
            name: "remember",
            arguments: [
                "content": .string(fact),
                "force": .bool(true),
            ]
        ))
    }

    // Rehash: paraphrasing the known reentrancy facts
    let rehash = padTo150("Swift actors are reentrant — when a method suspends at an await point, other messages can interleave. This means you need to re-validate state after each suspension point because another call may have mutated it.")
    // Novel: a subtle new insight — reentrancy + Combine interaction (same conceptual neighborhood)
    let subtleNovel = padTo150("When a Swift actor subscribes to a Combine publisher via sink, the sink closure runs on the publisher's scheduler, NOT on the actor. This bypasses actor isolation entirely. Wrapping the closure body in Task { await self.handle(value) } is required to re-enter the actor context.")

    let jsonl = makeFakeTranscript([
        ("assistant", rehash),
        ("assistant", subtleNovel),
    ])
    let transcriptPath = writeTempFile(jsonl)
    defer { try? FileManager.default.removeItem(atPath: transcriptPath) }

    let excerpts = await TranscriptSampler.sample(
        transcriptPath: transcriptPath,
        lattice: ctx.lattice,
        embedder: ctx.embedder,
        maxExcerpts: 2,
        maxCharsPerExcerpt: 500,
        maxTotalChars: 2000
    )

    // With novelty threshold: rehash (dist ~0.20) filtered, Combine insight (dist ~0.42) survives
    let rehashExcerpt = excerpts.first { $0.text.contains("re-validate") }
    let novelExcerpt = excerpts.first { $0.text.contains("Combine publisher") }

    #expect(rehashExcerpt == nil, "Reentrancy paraphrase should be filtered by novelty threshold")
    #expect(novelExcerpt != nil, "Combine isolation insight should survive novelty threshold")

    if let novelExcerpt {
        print("Novel (actor + Combine) distance: \(novelExcerpt.minDistance)")
        #expect(novelExcerpt.minDistance > TranscriptSampler.defaultNoveltyThreshold)
    }
}

@Test func sample_nearParaphraseWithSubtleDifference() async throws {
    let ctx = try await makeSamplerContext()

    // Seed: "actors are reentrant, state can change across awaits"
    _ = try await ctx.tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Swift actors are reentrant by default — when an actor method hits an await, other calls can execute before the first resumes. Mutable state can change across await points so you must re-check invariants after every await."),
            "force": .bool(true),
        ]
    ))

    // Two transcript excerpts, very close semantically:
    // 1. Pure paraphrase of the known fact (just rewords it)
    let paraphrase = padTo150("In Swift, actors allow reentrancy — suspending at an await lets other messages interleave. You need to re-validate your assumptions about mutable state after each suspension because interleaving calls may have changed it.")
    // 2. Same topic but adds the key insight: checking `isCancelled` after await is also affected
    let refinement = padTo150("In Swift, actor reentrancy also affects cancellation checking — if you check Task.isCancelled before an await and it returns false, after the await it might be true because the task was cancelled while suspended. Always re-check isCancelled after await points inside actors.")

    let jsonl = makeFakeTranscript([
        ("assistant", paraphrase),
        ("assistant", refinement),
    ])
    let transcriptPath = writeTempFile(jsonl)
    defer { try? FileManager.default.removeItem(atPath: transcriptPath) }

    // noveltyThreshold: 0 — this test measures raw distance discrimination, not pipeline gating
    let excerpts = await TranscriptSampler.sample(
        transcriptPath: transcriptPath,
        lattice: ctx.lattice,
        embedder: ctx.embedder,
        maxExcerpts: 2,
        maxCharsPerExcerpt: 500,
        maxTotalChars: 2000,
        noveltyThreshold: 0
    )

    let paraphraseExcerpt = excerpts.first { $0.text.contains("re-validate your assumptions") }
    let refinementExcerpt = excerpts.first { $0.text.contains("isCancelled") }

    #expect(paraphraseExcerpt != nil && refinementExcerpt != nil, "Both excerpts should be present")

    if let paraphraseExcerpt, let refinementExcerpt {
        print("Paraphrase distance: \(paraphraseExcerpt.minDistance)")
        print("Refinement (isCancelled) distance: \(refinementExcerpt.minDistance)")
        print("Delta: \(refinementExcerpt.minDistance - paraphraseExcerpt.minDistance)")

        // This is the hard case. Both are about actor reentrancy.
        // Can the embedding model see that the cancellation insight adds new info?
        #expect(refinementExcerpt.minDistance > paraphraseExcerpt.minDistance,
                "Cancellation refinement (\(refinementExcerpt.minDistance)) should be farther than pure paraphrase (\(paraphraseExcerpt.minDistance))")
    }
}

@Test func sample_pureParaphraseHasSmallDistance() async throws {
    let ctx = try await makeSamplerContext()

    // Seed: exact content
    _ = try await ctx.tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Swift actors are reentrant by default — when an actor method hits an await, other calls can execute before the first resumes. Mutable state can change across await points so you must re-check invariants after every await."),
            "force": .bool(true),
        ]
    ))

    // Transcript: two pure paraphrases of the same content (no new information)
    let para1 = padTo150("In Swift, actors allow reentrancy — suspending at an await lets other messages interleave. You need to re-validate your assumptions about mutable state after each suspension because interleaving calls may have changed it.")
    let para2 = padTo150("Actor methods in Swift can be re-entered when they suspend. While one call is waiting at an await, another call to the same actor can run. This means shared mutable state might change between the time you read it and the time the await returns.")

    let jsonl = makeFakeTranscript([
        ("assistant", para1),
        ("assistant", para2),
    ])
    let transcriptPath = writeTempFile(jsonl)
    defer { try? FileManager.default.removeItem(atPath: transcriptPath) }

    // noveltyThreshold: 0 — this test measures raw distance, not pipeline gating
    let excerpts = await TranscriptSampler.sample(
        transcriptPath: transcriptPath,
        lattice: ctx.lattice,
        embedder: ctx.embedder,
        maxExcerpts: 2,
        maxCharsPerExcerpt: 500,
        maxTotalChars: 2000,
        noveltyThreshold: 0
    )

    #expect(excerpts.count == 2)

    print("Paraphrase 1 distance: \(excerpts[0].minDistance)")
    print("Paraphrase 2 distance: \(excerpts[1].minDistance)")
    print("Max distance: \(excerpts.map(\.minDistance).max()!)")

    // Both should be close to existing memories — low distances
    for excerpt in excerpts {
        #expect(excerpt.minDistance < TranscriptSampler.defaultNoveltyThreshold,
                "Pure paraphrase should be close to existing memory, got \(excerpt.minDistance)")
    }
}

@Test func sample_noveltyThresholdFiltersPureParaphrases() async throws {
    let ctx = try await makeSamplerContext()

    _ = try await ctx.tools.handle(CallTool.Parameters(
        name: "remember",
        arguments: [
            "content": .string("Swift actors are reentrant by default — when an actor method hits an await, other calls can execute before the first resumes. Mutable state can change across await points so you must re-check invariants after every await."),
            "force": .bool(true),
        ]
    ))

    let para1 = padTo150("In Swift, actors allow reentrancy — suspending at an await lets other messages interleave. You need to re-validate your assumptions about mutable state after each suspension because interleaving calls may have changed it.")
    let para2 = padTo150("Actor methods in Swift can be re-entered when they suspend. While one call is waiting at an await, another call to the same actor can run. This means shared mutable state might change between the time you read it and the time the await returns.")

    let jsonl = makeFakeTranscript([
        ("assistant", para1),
        ("assistant", para2),
    ])
    let transcriptPath = writeTempFile(jsonl)
    defer { try? FileManager.default.removeItem(atPath: transcriptPath) }

    // With default novelty threshold, pure paraphrases should be filtered out
    let excerpts = await TranscriptSampler.sample(
        transcriptPath: transcriptPath,
        lattice: ctx.lattice,
        embedder: ctx.embedder,
        maxExcerpts: 2,
        maxCharsPerExcerpt: 500,
        maxTotalChars: 2000
    )

    #expect(excerpts.isEmpty, "Pure paraphrases (distance < 0.28) should be filtered by novelty threshold")
}

@Test func sample_benchmarkRealTranscript() async throws {
    let ctx = try await makeSamplerContext()

    // Use the largest real transcript available
    let path = NSString(string: "~/.claude/projects/-Users-jason-flax-Projects-lattice/d5b47c93-234d-434c-abd5-42c6bf7c7a56.jsonl").expandingTildeInPath as String
    guard FileManager.default.fileExists(atPath: path) else {
        print("Skipping benchmark — transcript not found")
        return
    }

    let blocks = TranscriptSampler.extractAssistantTextBlocks(from: path)
    let substantive = blocks.filter { $0.count >= 100 }
    print("Transcript: \(blocks.count) total blocks, \(substantive.count) substantive")

    let start = ContinuousClock.now
    let excerpts = await TranscriptSampler.sample(
        transcriptPath: path,
        lattice: ctx.lattice,
        embedder: ctx.embedder,
        maxExcerpts: 5,
        maxCharsPerExcerpt: 500,
        maxTotalChars: 2000
    )
    let elapsed = ContinuousClock.now - start
    let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000

    print("Sampling took \(ms)ms for \(substantive.count) substantive blocks")
    print("Excerpts returned: \(excerpts.count)")
    for (i, e) in excerpts.enumerated() {
        print("  [\(i+1)] dist=\(String(format: "%.3f", e.minDistance)) len=\(e.charLength) \(e.text.prefix(80))...")
    }
}

@Test func formatForAssessment_producesReadableOutput() {
    let excerpts = [
        TranscriptSampler.ScoredExcerpt(text: "First excerpt about architecture.", minDistance: 0.8, charLength: 32),
        TranscriptSampler.ScoredExcerpt(text: "Second excerpt about debugging.", minDistance: 0.5, charLength: 30),
    ]

    let formatted = TranscriptSampler.formatForAssessment(excerpts)
    #expect(formatted.contains("[1] First excerpt"))
    #expect(formatted.contains("[2] Second excerpt"))
}

// MARK: - Test Context

struct SamplerTestContext {
    let tools: MemoryTools
    let lattice: Lattice
    let embedder: EmbeddingService
}

func makeSamplerContext() async throws -> SamplerTestContext {
    let path = FileManager.default.temporaryDirectory
        .appending(path: "claude-memory-test-\(UUID().uuidString).sqlite")
    let lattice = try Lattice(Memory.self, Edge.self, Checkpoint.self, HookState.self, SyncConfig.self, configuration: .init(fileURL: path))
    let embedder = sharedEmbedder
    if await !embedder.isLoaded {
        await embedder.load()
    }
    let tools = MemoryTools(localRef: lattice.sendableReference, syncedRef: nil, embedder: embedder,
        identity: StaticIdentityProvider(.anonymous))
    return SamplerTestContext(tools: tools, lattice: lattice, embedder: embedder)
}

// MARK: - JSONL Helpers

private func makeFakeTranscript(_ entries: [(role: String, text: String?)]) -> String {
    entries.map { role, text in
        if role == "user" {
            return makeJsonlLine(type: "user", message: ["role": "user", "content": text ?? ""])
        } else {
            if let text {
                return makeJsonlLine(type: "assistant", content: [["type": "text", "text": text]])
            } else {
                return makeJsonlLine(type: "assistant", content: [
                    ["type": "tool_use", "id": "toolu_\(UUID().uuidString.prefix(8))", "name": "Read", "input": ["file_path": "/tmp/foo"]],
                ])
            }
        }
    }.joined(separator: "\n")
}

private func makeJsonlLine(type: String, content: [[String: Any]]) -> String {
    let obj: [String: Any] = [
        "type": type,
        "message": ["role": type, "content": content] as [String: Any],
        "uuid": UUID().uuidString,
        "timestamp": ISO8601DateFormatter().string(from: Date()),
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
          let str = String(data: data, encoding: .utf8) else { return "{}" }
    return str
}

private func makeJsonlLine(type: String, message: [String: Any]) -> String {
    let obj: [String: Any] = [
        "type": type,
        "message": message,
        "uuid": UUID().uuidString,
        "timestamp": ISO8601DateFormatter().string(from: Date()),
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
          let str = String(data: data, encoding: .utf8) else { return "{}" }
    return str
}

private func writeTempFile(_ content: String) -> String {
    let path = FileManager.default.temporaryDirectory
        .appending(path: "test-transcript-\(UUID().uuidString).jsonl").path
    FileManager.default.createFile(atPath: path, contents: Data(content.utf8))
    return path
}

private func padTo150(_ s: String) -> String {
    if s.count >= 150 { return s }
    return s + String(repeating: " ", count: 150 - s.count) + "."
}
