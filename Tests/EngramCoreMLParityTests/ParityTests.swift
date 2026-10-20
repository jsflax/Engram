import Testing
import EngramCoreML
import EngramKit
@Test func bundledPortableAndDesktopVectorsAgree() async throws {
    let desktop = EmbeddingService()
    await desktop.load()
    let portable = CoreMLMemoryEmbedder(computePolicy: .cpuOnly)
    let corpus = [
        "configure the sync daemon for the group relay",
        "sqlite3_column_name returns NULL under memory pressure",
        "the stripe webhook needs the group id in subscription metadata",
        "agents recall their previous debugging sessions across sandboxes",
        "tombstones converge for every member including the author",
        "the projection pipeline replays postgres events into lattice files",
    ]
    for text in corpus {
        let a = try #require(try await desktop.embed(text: text))
        let b = try #require(try await portable.embed(text: text))
        #expect(a.count == 384 && b.count == 384)
        let dot = zip(a,b).reduce(Double(0)) { $0 + Double($1.0) * Double($1.1) }
        let normA = a.reduce(Double(0)) { $0 + Double($1) * Double($1) }.squareRoot()
        let normB = b.reduce(Double(0)) { $0 + Double($1) * Double($1) }.squareRoot()
        #expect(dot / (normA * normB) >= 0.999)
    }
}
