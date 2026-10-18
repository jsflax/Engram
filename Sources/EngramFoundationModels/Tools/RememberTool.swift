import FoundationModels
import EngramKit

@available(macOS 26.0, iOS 26.0, *)
public struct RememberTool: Tool {
    public typealias Output = String
    let memoryTools: MemoryTools

    public let name = "remember"
    public let description = """
        Store a memory for later recall. Each memory gets a semantic embedding \
        for similarity search. Keep memories atomic — one concept per memory.
        """

    @Generable
    public struct Arguments {
        @Guide(description: "The memory content to store.")
        public var content: String

        @Guide(description: "Category topic (e.g. 'architecture', 'debugging', 'preferences').")
        public var topic: String?

        @Guide(description: "Project scope. Use the project name for project-specific knowledge, or 'global' for cross-project preferences.")
        public var project: String?

        @Guide(description: "Where the memory came from (e.g. 'conversation', 'code-review', 'debugging-session').")
        public var source: String?

        @Guide(description: "Auto-expire after this many days. Use for temporary context.")
        public var expiresInDays: Int?

        @Guide(description: "If true, store even if a near-duplicate exists.")
        public var force: Bool?

        @Guide(description: "Importance ranking from 1-5. Higher importance boosts recall ranking.")
        public var importance: Int?

        @Guide(description: "UUID of a parent memory. Creates a 'part_of' edge automatically for building hierarchies.")
        public var parentId: String?

        @Guide(description: "If true, keep the memory on this device, excluding personal cloud/device sync and group sharing. False follows the project's sync and sharing settings.")
        public var isPrivate: Bool?
    }

    public func call(arguments: Arguments) async throws -> String {
        try await dispatchTool(memoryTools, name: "remember", args: [
            ("content", arguments.content),
            ("topic", arguments.topic),
            ("project", arguments.project),
            ("source", arguments.source),
            ("expires_in_days", arguments.expiresInDays),
            ("force", arguments.force),
            ("importance", arguments.importance),
            ("parent_id", arguments.parentId),
            ("is_private", arguments.isPrivate),
        ])
    }
}
