import FoundationModels
import EngramKit

@available(macOS 26.0, iOS 26.0, *)
public struct UpdateTool: Tool {
    public typealias Output = String
    let memoryTools: MemoryTools

    public let name = "update"
    public let description = """
        Edit an existing memory by ID or by semantic similarity search. \
        Supports full content replacement, append, prepend, and find-replace. \
        Can also update metadata fields like topic, source, importance, and expiry.
        """

    @Generable
    public struct Arguments {
        @Guide(description: "Target memory by its UUID.")
        public var id: String?

        @Guide(description: "Target memory by similarity search query (finds the closest match).")
        public var query: String?

        @Guide(description: "Project scope for similarity search targeting.")
        public var project: String?

        @Guide(description: "Replace the full content of the memory.")
        public var content: String?

        @Guide(description: "Append text to the end of the memory content.")
        public var append: String?

        @Guide(description: "Prepend text to the beginning of the memory content.")
        public var prepend: String?

        @Guide(description: "Text to find for find-and-replace. Must be used with 'replace'.")
        public var find: String?

        @Guide(description: "Replacement text. Must be used with 'find'.")
        public var replace: String?

        @Guide(description: "Move the memory to a different project scope.")
        public var setProject: String?

        @Guide(description: "Update the topic category.")
        public var topic: String?

        @Guide(description: "Update the source attribution.")
        public var source: String?

        @Guide(description: "Set auto-expiry in days from now.")
        public var expiresInDays: Int?

        @Guide(description: "Update importance ranking (1-5).")
        public var importance: Int?

        @Guide(description: "Set whether the memory stays on this device, excluded from personal cloud/device sync and group sharing. False follows the project's sync and sharing settings.")
        public var isPrivate: Bool?
    }

    public func call(arguments: Arguments) async throws -> String {
        try await dispatchTool(memoryTools, name: "update", args: [
            ("id", arguments.id),
            ("query", arguments.query),
            ("project", arguments.project),
            ("content", arguments.content),
            ("append", arguments.append),
            ("prepend", arguments.prepend),
            ("find", arguments.find),
            ("replace", arguments.replace),
            ("set_project", arguments.setProject),
            ("topic", arguments.topic),
            ("source", arguments.source),
            ("expires_in_days", arguments.expiresInDays),
            ("importance", arguments.importance),
            ("is_private", arguments.isPrivate),
        ])
    }
}
