import Foundation

/// Rotate a log file if it exceeds `maxBytes`. Keeps one `.1` backup.
public func rotateFileIfNeeded(_ path: String, maxBytes: Int = 256 * 1024) {
    let fm = FileManager.default
    guard let attrs = try? fm.attributesOfItem(atPath: path),
          let size = attrs[.size] as? Int,
          size > maxBytes else { return }
    let backup = path + ".1"
    try? fm.removeItem(atPath: backup)
    try? fm.moveItem(atPath: path, toPath: backup)
}

#if os(macOS) || os(Linux)
/// Spawn a `claude` CLI subprocess as a fire-and-forget background process.
///
/// Uses `/bin/sh -c` with shell redirection to capture output to a log file.
/// The subprocess is fully detached from the calling process's stdio.
///
/// - Parameters:
///   - prompt: The prompt to pass via `claude -p`.
///   - systemPrompt: Appended as `--append-system-prompt`.
///   - allowedTools: Comma-separated tool names for `--allowedTools`.
///   - model: Model name (e.g. "sonnet").
///   - envGuard: Environment variable set on the subprocess to prevent recursion.
///   - logPath: Absolute path to the log file for stdout/stderr capture.
///   - cwd: Optional working directory for the subprocess.
///   - extraClaudeArgs: Optional extra CLI flags (already shell-safe), e.g. an
///     explicit `--mcp-config` so the subprocess doesn't depend on cwd
///     discovery.
///   - postCommand: Optional shell command to run after `claude` exits (regardless of exit code).
///   - maxTurns: Agentic turn bound passed as `--max-turns` — a detached
///     learner must not be able to run away on the host's API key.
///   - wallClockSeconds: Hard kill after this long, via a portable sh
///     watcher (macOS has no `timeout(1)`); pairs with maxTurns so one
///     wedged tool call can't hold the process open either.
public func spawnClaudeSubprocess(
    prompt: String,
    systemPrompt: String,
    allowedTools: String,
    model: String,
    envGuard: (key: String, value: String),
    logPath: String,
    cwd: String? = nil,
    extraClaudeArgs: String = "",
    postCommand: String? = nil,
    maxTurns: Int = 15,
    wallClockSeconds: Int = 720
) throws {
    let escapedPrompt = prompt.replacingOccurrences(of: "'", with: "'\\''")
    let escapedSystemPrompt = systemPrompt.replacingOccurrences(of: "'", with: "'\\''")

    rotateFileIfNeeded(logPath)

    // Per-run temp capture, appended to the log on completion: keeps
    // concurrent spawns from interleaving AND lets the failure checks below
    // grep THIS run's output only (grepping the shared log would re-match a
    // previous run's errors forever).
    // `;` separators, NOT `&&`: `a && b & ` backgrounds the whole chain
    // (POSIX precedence), which would leave $T set only inside the
    // backgrounded subshell and make the wall-clock kill hit the wrapper
    // instead of claude.
    let shellCommand = """
    T=$(mktemp) || exit 1; \
    echo '===== started at '\\''\(ISO8601DateFormatter().string(from: Date()))'\\'' =====' >> '\(logPath)'; \
    claude -p '\(escapedPrompt)' \
      --model \(model) \
      --allowedTools '\(allowedTools)' \
      --max-turns \(maxTurns) \
      --no-session-persistence \
      --output-format text \
      --append-system-prompt '\(escapedSystemPrompt)' \
      \(extraClaudeArgs) \
      > "$T" 2>&1 & CPID=$!; \
    ( sleep \(wallClockSeconds) && kill "$CPID" 2>/dev/null \
      && echo '===== killed at \(wallClockSeconds)s wall-clock bound =====' >> "$T" ) & WPID=$!; \
    wait "$CPID"; RC=$?; kill "$WPID" 2>/dev/null; cat "$T" >> '\(logPath)'; \
    if grep -qi 'not logged in\\|invalid api key\\|please run /login' "$T"; then \
      echo '===== ERROR: spawned claude is NOT AUTHENTICATED — the subprocess died before doing anything. Headless/env-auth setups strip ANTHROPIC_API_KEY/CLAUDE_CODE_OAUTH_TOKEN from hook children; use credential-file auth in CLAUDE_CONFIG_DIR, or spawn from a non-hook process. =====' >> '\(logPath)'; \
    elif [ "$RC" -ne 0 ]; then \
      echo "===== ERROR: spawned claude exited $RC =====" >> '\(logPath)'; \
    fi; rm -f "$T"\(postCommand.map { "; \($0)" } ?? "")
    """

    let sh = Process()
    sh.executableURL = URL(fileURLWithPath: "/bin/sh")
    sh.arguments = ["-c", shellCommand]
    sh.environment = ProcessInfo.processInfo.environment.merging(
        [envGuard.key: envGuard.value],
        uniquingKeysWith: { _, new in new }
    )
    if let cwd {
        sh.currentDirectoryURL = URL(fileURLWithPath: cwd)
    }

    // Detach from our process's stdio
    sh.standardOutput = FileHandle.nullDevice
    sh.standardError = FileHandle.nullDevice

    try sh.run()
    // Don't wait — fire and forget
}

#endif

/// Strip YAML frontmatter (--- delimited block) from markdown content.
public func stripFrontmatter(_ content: String) -> String {
    guard content.hasPrefix("---") else { return content }
    let lines = content.components(separatedBy: .newlines)
    for i in 1..<lines.count {
        if lines[i].hasPrefix("---") {
            return lines[(i + 1)...].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    return content
}

/// Load an agent system prompt by name, stripping YAML frontmatter.
///
/// Searches in order:
/// 1. `~/.claude/agents/<name>.md` (user-installed override)
/// 2. An optional resource bundle (EngramKit passes its SPM bundle; the
///    portable/Linux hooks pass nil — sandboxes have no installed agents)
///
/// Falls back to the provided inline default if neither source exists.
public func loadAgentSystemPrompt(name: String, bundle: Bundle? = nil,
                                  fallback: String) -> String {
    // 1. User-installed override (hot-editable without rebuild)
    let userPath = NSHomeDirectory() + "/.claude/agents/\(name).md"
    if let content = try? String(contentsOfFile: userPath, encoding: .utf8) {
        return stripFrontmatter(content)
    }

    // 2. Bundled resource
    if let url = bundle?.url(forResource: name, withExtension: "md"),
       let content = try? String(contentsOf: url, encoding: .utf8) {
        return stripFrontmatter(content)
    }

    return fallback
}
