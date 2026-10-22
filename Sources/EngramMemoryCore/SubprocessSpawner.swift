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
///   - wallClockSeconds: Send TERM after this long, then KILL after a three
///     second grace period. The native guard retains admission until it reaps
///     the provider, including when kernel I/O delays termination.
///   - learnerLogContext: Optional per-session launch/exit attribution. Child
///     exit status is not a memory-write or persistence receipt.
///   - admission: Concurrency/cooldown/load gate (SpawnAdmission). The default
///     is the shared on-disk gate; pass nil to bypass it (tests only).
///   - beforeLaunch: Optional observational-state callback after admission and
///     immediately before process launch. A refused admission never invokes it.
///   - guardExecutable: Explicit same-release hooks binary for embedding apps.
///     Hook callers re-exec their current binary; no PATH helper is selected.
/// - Returns: `.spawned` or `.skipped(verdict)`. A refusal is not an error —
///   callers log the verdict and move on.
@discardableResult
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
    wallClockSeconds: Int = 720,
    learnerLogContext: LearnerLogContext? = nil,
    admission: SpawnAdmission? = .default,
    beforeLaunch: (() throws -> Void)? = nil,
    guardExecutable: String? = nil
) throws -> SpawnOutcome {
    let guardPath = try processGuardExecutable(explicit: guardExecutable)
    rotateFileIfNeeded(logPath)
    let lifecycleLog = learnerLogContext.map { LearnerLifecycleLog(context: $0) }
    if let lifecycleLog {
        // Best effort only. Failure to create a diagnostic directory must not
        // suppress the learner or change its permissions, tools or budget.
        try? FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: lifecycleLog.path).deletingLastPathComponent().path,
            withIntermediateDirectories: true)
    }
    let shellCommand = claudeSubprocessShellCommand(
        prompt: prompt, systemPrompt: systemPrompt, allowedTools: allowedTools,
        model: model, logPath: logPath, extraClaudeArgs: extraClaudeArgs,
        postCommand: postCommand, maxTurns: maxTurns,
        wallClockSeconds: wallClockSeconds, lifecycleLog: lifecycleLog,
        inheritsAdmissionLease: admission != nil, guardExecutable: guardPath)

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

    // Foundation explicitly maps standardInput across exec. The shell moves
    // the lease to fd 3 before replacing stdin. The native guard retains it
    // and explicitly closes it in the provider child before exec.
    let launch: (Int32?) throws -> Int32 = { lease in
        try launchClaudeShell(sh, lease: lease, beforeLaunch: beforeLaunch)
    }
    guard let admission else {
        return .spawned(pid: try launch(nil))
    }
    let verdict = try admission.admit(kind: SpawnOutcome.kind(forEnvGuard: envGuard.key)) { try launch($0) }
    if case .admitted(let pid) = verdict { return .spawned(pid: pid) }
    return .skipped(verdict)
}

/// Only the running hooks executable or an explicit packaged path may act as
/// the guard. In particular, an installed older memory-hooks on PATH cannot
/// silently supply an incompatible internal command to an updated app.
func processGuardExecutable(explicit: String?) throws -> String {
    let candidate: URL
    if let explicit {
        guard explicit.hasPrefix("/") else { throw OwnedProcessGuard.Failure.invalidArguments }
        candidate = URL(fileURLWithPath: explicit)
    } else {
        guard let current = Bundle.main.executableURL,
              ["memory-hooks", "EngramHooks"].contains(current.lastPathComponent) else {
            throw OwnedProcessGuard.Failure.invalidArguments
        }
        candidate = current
    }
    let resolved = candidate.resolvingSymlinksInPath().path
    guard FileManager.default.isExecutableFile(atPath: resolved) else {
        throw OwnedProcessGuard.Failure.invalidArguments
    }
    return resolved
}

/// Foundation's inherited stdin mapping is shared by production and stand-in
/// tests. The callback runs only after admission and before the child can exit.
func launchClaudeShell(_ process: Process, lease: Int32?, beforeLaunch: (() throws -> Void)? = nil) throws -> Int32 {
    process.standardInput = lease.map { FileHandle(fileDescriptor: $0, closeOnDealloc: false) } ?? .nullDevice
    try beforeLaunch?()
    try process.run()
    return process.processIdentifier
}

/// Result of `spawnClaudeSubprocess`.
public enum SpawnOutcome: Equatable, Sendable, CustomStringConvertible {
    case spawned(pid: Int32)
    case skipped(SpawnAdmission.Verdict)

    public var description: String {
        switch self {
        case .spawned(let pid): return "spawned (wrapper pid \(pid))"
        case .skipped(let verdict): return verdict.description
        }
    }

    /// The recursion-guard variable doubles as the subprocess kind.
    static func kind(forEnvGuard key: String) -> SpawnAdmission.Kind {
        switch key {
        case "CLAUDE_MEMORY_LEARNER": return .learner
        case "CLAUDE_MEMORY_MAINTENANCE": return .maintenance
        case "CLAUDE_MEMORY_SYNC_RECONCILIATION": return .reconciliation
        default: return .other
        }
    }
}

/// Pure command construction also lets the detached shell contract be tested
/// with a fake executable, without a provider, transcript or memory store.
func claudeSubprocessShellCommand(
    prompt: String, systemPrompt: String, allowedTools: String, model: String,
    logPath: String, extraClaudeArgs: String = "", postCommand: String? = nil,
    maxTurns: Int = 15, wallClockSeconds: Int = 720,
    lifecycleLog: LearnerLifecycleLog? = nil, inheritsAdmissionLease: Bool = false,
    guardExecutable: String
) -> String {
    let escapedPrompt = prompt.replacingOccurrences(of: "'", with: "'\\''")
    let escapedSystemPrompt = systemPrompt.replacingOccurrences(of: "'", with: "'\\''")
    let started = lifecycleLog?.appendCommand(event: "learner_child_started") ?? ""
    let exited = lifecycleLog?.appendCommand(event: "learner_child_exited", includeExitCode: true) ?? ""
    let leaseSetup = inheritsAdmissionLease ? "exec 3<&0; exec </dev/null; " : ""
    let guardPath = guardExecutable.replacingOccurrences(of: "'", with: "'\\''")
    let guardLease = inheritsAdmissionLease ? " --lease-fd 3" : ""

    // Per-run temp capture, appended to the log on completion: keeps
    // concurrent spawns from interleaving AND lets the failure checks below
    // grep THIS run's output only (grepping the shared log would re-match a
    // previous run's errors forever).
    // `;` separators, NOT `&&`: `a && b & ` backgrounds the whole chain
    // (POSIX precedence), which would leave $T set only inside the
    // backgrounded subshell. CPID identifies the native guard, whose observed
    // exit code is the provider's reaped status; it is not a persistence receipt.
    // `/usr/bin/nice -n 10`: a detached learner competes with the user's
    // interactive sessions and their Swift builds for CPU; it should lose.
    return """
    \(leaseSetup)T=$(mktemp) || exit 1; \
    echo '===== started at '\\''\(ISO8601DateFormatter().string(from: Date()))'\\'' =====' >> '\(logPath)'; \
    '\(guardPath)' internal-process-guard --wall-seconds \(wallClockSeconds)\(guardLease) -- \
      /usr/bin/nice -n 10 claude -p '\(escapedPrompt)' \
      --model \(model) \
      --allowedTools '\(allowedTools)' \
      --max-turns \(maxTurns) \
      --no-session-persistence \
      --output-format text \
      --append-system-prompt '\(escapedSystemPrompt)' \
      \(extraClaudeArgs) \
      > "$T" 2>&1 & CPID=$!; \
    \(started) \
    wait "$CPID"; RC=$?;\(exited) cat "$T" >> '\(logPath)'; \
    if grep -qi 'not logged in\\|invalid api key\\|please run /login' "$T"; then \
      echo '===== ERROR: spawned claude is NOT AUTHENTICATED — the subprocess died before doing anything. Headless/env-auth setups strip ANTHROPIC_API_KEY/CLAUDE_CODE_OAUTH_TOKEN from hook children; use credential-file auth in CLAUDE_CONFIG_DIR, or spawn from a non-hook process. =====' >> '\(logPath)'; \
    elif [ "$RC" -ne 0 ]; then \
      echo "===== ERROR: spawned claude exited $RC =====" >> '\(logPath)'; \
    fi; rm -f "$T"\(postCommand.map { "; \($0)" } ?? "")
    """
}

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
