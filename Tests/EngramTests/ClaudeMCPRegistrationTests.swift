import Foundation
import Darwin
import Testing
@testable import EngramKit

private struct MCPRegistrationFixture {
    let home: URL
    let memory: URL
    let claude: URL
    let config: URL

    init() throws {
        let root = ProcessInfo.processInfo.environment["ENGRAM_ADOPTION_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        home = root.appendingPathComponent("engram-mcp-\(UUID().uuidString)")
        memory = home.appendingPathComponent(".claude/bin/memory")
        claude = home.appendingPathComponent(".local/bin/claude")
        config = home.appendingPathComponent(".claude.json")
        try FileManager.default.createDirectory(at: memory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeExecutable(memory, "#!/bin/sh\nexit 0\n")
    }

    func cleanup() { try? FileManager.default.removeItem(at: home) }

    func writeExecutable(_ url: URL, _ contents: String) throws {
        try contents.write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    func writeConfig(_ object: [String: Any], to url: URL? = nil) throws {
        try JSONSerialization.data(withJSONObject: object, options: .sortedKeys).write(to: url ?? config)
    }

    var desiredConfig: [String: Any] {
        ["untouched": "sentinel", "mcpServers": [
            "other": ["type": "http", "url": "https://example.invalid/mcp"],
            "memory": ["type": "stdio", "command": memory.path, "args": []]
        ]]
    }

    func successfulClaude() throws {
        try writeConfig(desiredConfig, to: home.appendingPathComponent("expected.json"))
        try writeExecutable(claude, """
        #!/bin/sh
        printf '%s\n' "$@" > "$HOME/arguments"
        printf '%s' "${CLAUDECODE-unset}" > "$HOME/nesting"
        /bin/cp "$HOME/expected.json" "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
        """)
    }

    func register(environment: [String: String] = [:], timeout: TimeInterval = 2,
                  candidates: [URL]? = nil) -> ClaudeMCPRegistration.Outcome {
        ClaudeMCPRegistration.register(memoryExecutable: memory, home: home, environment: environment,
                                       timeout: timeout, candidates: candidates ?? [claude])
    }
}

@Test("GUI discovery includes native Claude and both Homebrew locations, without relative PATH entries")
func claudeMCPRegistrationDiscovery() {
    let home = URL(fileURLWithPath: "/private/fixture-home")
    let paths = ClaudeMCPRegistration.executableCandidates(home: home, environment: ["PATH": "/usr/bin:.:relative:/usr/bin:"]).map(\.path)
    #expect(paths == ["/usr/bin/claude", "/private/fixture-home/.local/bin/claude",
                      "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "/bin/claude"])
}

@Test("Missing registration is added in user scope and read back without removing any server")
func claudeMCPRegistrationAddsAndVerifies() throws {
    let fixture = try MCPRegistrationFixture(); defer { fixture.cleanup() }
    try fixture.writeConfig(["untouched": "sentinel", "mcpServers": ["other": ["type": "http", "url": "https://example.invalid/mcp"]]])
    try fixture.successfulClaude()
    #expect(fixture.register(environment: ["PATH": "/usr/bin:/bin", "CLAUDECODE": "1"]) == .registered)
    let arguments = try String(contentsOf: fixture.home.appendingPathComponent("arguments"), encoding: .utf8)
    #expect(arguments.components(separatedBy: .newlines) == ["mcp", "add", "--scope", "user", "--transport", "stdio", "memory", "--", fixture.memory.path, ""])
    #expect(try String(contentsOf: fixture.home.appendingPathComponent("nesting"), encoding: .utf8) == "unset")
    #expect(fixture.register(candidates: []) == .alreadyRegistered)
    let config = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.config)) as? [String: Any])
    #expect(config["untouched"] as? String == "sentinel")
    #expect((config["mcpServers"] as? [String: Any])?["other"] != nil)
}

@Test("An existing customized or external memory server is preserved byte for byte")
func claudeMCPRegistrationPreservesOtherServer() throws {
    let fixture = try MCPRegistrationFixture(); defer { fixture.cleanup() }
    try fixture.successfulClaude()
    for server: [String: Any] in [
        ["type": "http", "url": "https://example.invalid/memory"],
        ["command": "/a/different/memory", "args": []],
        ["command": fixture.memory.path, "args": ["--custom"]]
    ] {
        try fixture.writeConfig(["mcpServers": ["memory": server]])
        let before = try Data(contentsOf: fixture.config)
        #expect(fixture.register() == .preservedExistingServer)
        #expect(try Data(contentsOf: fixture.config) == before)
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("arguments").path))
    }
}

@Test("Unreadable JSON and malformed MCP objects are never replaced")
func claudeMCPRegistrationPreservesMalformedConfiguration() throws {
    let fixture = try MCPRegistrationFixture(); defer { fixture.cleanup() }
    try fixture.successfulClaude()
    for contents in ["{broken", "[]", "{\"mcpServers\":null}"] {
        try contents.write(to: fixture.config, atomically: false, encoding: .utf8)
        #expect(fixture.register() == .invalidConfiguration)
        #expect(try String(contentsOf: fixture.config, encoding: .utf8) == contents)
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("arguments").path))
}

@Test("Missing Claude and failed registrations can retry without changing the app version")
func claudeMCPRegistrationRetriesFailures() throws {
    let fixture = try MCPRegistrationFixture(); defer { fixture.cleanup() }
    #expect(fixture.register(candidates: []) == .claudeNotFound)
    try fixture.writeExecutable(fixture.claude, "#!/bin/sh\nexit 7\n")
    #expect(fixture.register() == .commandFailed(7))
    try fixture.writeExecutable(fixture.claude, "#!/bin/sh\nexit 0\n")
    #expect(fixture.register() == .verificationFailed)
    try fixture.successfulClaude()
    #expect(fixture.register() == .registered)
}

@Test("A missing memory binary prevents registration")
func claudeMCPRegistrationRequiresMemory() throws {
    let fixture = try MCPRegistrationFixture(); defer { fixture.cleanup() }
    try FileManager.default.removeItem(at: fixture.memory)
    #expect(fixture.register(candidates: []) == .missingMemoryExecutable)
}

@Test("Registration honors Claude's custom user configuration directory")
func claudeMCPRegistrationCustomConfigDirectory() throws {
    let fixture = try MCPRegistrationFixture(); defer { fixture.cleanup() }
    let profile = fixture.home.appendingPathComponent("profile")
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    try fixture.writeConfig(["mcpServers": ["memory": ["type": "http", "url": "https://example.invalid/keep"]]])
    let before = try Data(contentsOf: fixture.config)
    try fixture.successfulClaude()
    #expect(fixture.register(environment: ["CLAUDE_CONFIG_DIR": profile.path]) == .registered)
    #expect(try Data(contentsOf: fixture.config) == before)
    #expect(FileManager.default.fileExists(atPath: profile.appendingPathComponent(".claude.json").path))
}

@Test("A hung Claude command is stopped within a bounded wait")
func claudeMCPRegistrationTimeout() throws {
    let fixture = try MCPRegistrationFixture(); defer { fixture.cleanup() }
    // exec keeps the sleeper in the exact child process, without a detached descendant.
    try fixture.writeExecutable(fixture.claude, "#!/bin/sh\nexec /bin/sleep 30\n")
    let start = Date()
    #expect(fixture.register(timeout: 0.05) == .timedOut(cleanupConfirmed: true))
    #expect(Date().timeIntervalSince(start) < 3)
}

@Test("A timed-out Claude wrapper and its TERM-resistant descendant are both stopped")
func claudeMCPRegistrationTimeoutCleansWrapperDescendant() throws {
    let fixture = try MCPRegistrationFixture(); defer { fixture.cleanup() }
    let childFile = fixture.home.appendingPathComponent("descendant-pid")
    let wrapperFile = fixture.home.appendingPathComponent("wrapper-pid")
    try fixture.writeExecutable(fixture.claude, """
    #!/bin/sh
    trap '' TERM
    /bin/sleep 30 &
    child=$!
    printf '%s' "$child" > "$HOME/descendant-pid"
    printf '%s' "$$" > "$HOME/wrapper-pid"
    wait "$child"
    """)
    let start = Date()
    let result = fixture.register(timeout: 0.25)
    let child = try #require(Int32(String(contentsOf: childFile, encoding: .utf8)))
    let wrapper = try #require(Int32(String(contentsOf: wrapperFile, encoding: .utf8)))
    // Cleanup remains bounded even if the assertion detects a regression.
    defer {
        if kill(child, 0) == 0 { kill(child, SIGKILL) }
        if kill(wrapper, 0) == 0 { kill(wrapper, SIGKILL) }
    }
    #expect(result == .timedOut(cleanupConfirmed: true))
    #expect(kill(child, 0) == -1 && errno == ESRCH)
    #expect(kill(wrapper, 0) == -1 && errno == ESRCH)
    #expect(Date().timeIntervalSince(start) < 3)
}
