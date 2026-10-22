import EngramMemoryCore
import Foundation
#if canImport(EngramKit)
import EngramKit
import Lattice
#endif

#if canImport(EngramKit)

/// Statement-level SQLite busy timeout for every hook-opened Lattice.
///
/// Lattice's default is 30s — a headless-server number. A hook is the
/// opposite of headless: it sits INSIDE the user's prompt latency, under a
/// budget of a few seconds, so a lock held by a mid-catch-up sync daemon
/// must surface as a fast failure the budget machinery can degrade around,
/// never a 30s wait (Aug 2026 incident: advise rode the lock all the way to
/// the harness's 60s kill). One constant, passed at every open site below;
/// the attach clone inherits it from the hub configuration.
let hookBusyTimeoutMs = 2000

/// Requested Lattice log verbosity for the hook path.
///
/// Verbose Lattice logging used to be HARDCODED to `.debug` here, with a
/// per-session log FILE — synchronous file I/O inside the hook's timed
/// window, on a path that runs on every prompt. In the field that produced
/// single 93MB session logs and a 748MB `~/.claude/memory-logs`. It is now
/// opt-in through the same switch the MCP server uses (Sources/Engram/
/// main.swift): ENGRAM_LATTICE_LOG_LEVEL = off|error|warning|info|debug.
///
/// Unset ⇒ errors only, written to stderr, which the harness already
/// captures into hooks.log — so genuine failures stay visible and nothing
/// touches the log directory.
private let latticeLogLevelEnv: String? =
    ProcessInfo.processInfo.environment["ENGRAM_LATTICE_LOG_LEVEL"]?.lowercased()

/// Applied once per process, the first time a Lattice is opened.
private let latticeLogLevelApplied: Bool = {
    switch latticeLogLevelEnv {
    case "off": Lattice.setLogLevel(.off)
    case "warning", "warn": Lattice.setLogLevel(.warn)
    case "info": Lattice.setLogLevel(.info)
    case "debug": Lattice.setLogLevel(.debug)
    default: Lattice.setLogLevel(.error)
    }
    return true
}()

/// Point Lattice's log at this session's file — ONLY when logging was asked
/// for. Writing the file is the expensive half, so an unset (or "off") env
/// var leaves Lattice logging to stderr and never creates the directory.
private func configureLatticeLogging(sessionId: String?) {
    _ = latticeLogLevelApplied
    guard let level = latticeLogLevelEnv, level != "off" else { return }
    guard let sid = sessionId ?? ProcessInfo.processInfo.environment["CLAUDE_SESSION_ID"],
          !sid.isEmpty else { return }
    let fm = FileManager.default
    if !fm.fileExists(atPath: memoryLogsDir) {
        try? fm.createDirectory(atPath: memoryLogsDir, withIntermediateDirectories: true)
    }
    Lattice.setLogFile(URL(fileURLWithPath: memoryLogsDir + "/lattice-\(sid).log"))
}

/// Open Lattice with the full schema at the default database path.
func openLattice(sessionId: String? = nil) -> Lattice? {
    let dbPath = defaultDbPath
    guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

    configureLatticeLogging(sessionId: sessionId)

    return try? Lattice(
        Memory.self, Edge.self, Checkpoint.self, HookState.self, SessionState.self,
        configuration: .init(fileURL: URL(fileURLWithPath: dbPath), migration: engramMigrations,
                             busyTimeoutMs: hookBusyTimeoutMs)
    )
}

/// Initialize MemoryTools (Lattice + embedding model).
///
/// `budget` (hook start + recall budget) enables budget shaping: the hub open
/// and the embedder load are timed, and when together they have consumed more
/// than `HookBudget.secondaryAttachFraction` of the budget the personal synced
/// DB and group spokes are NOT attached. Under contention those extra opens
/// were the difference between a slow local-only recall and no recall at all
/// ("exceeded its 15s budget"). Degradation is logged, never silent.
func initMemoryTools(sessionId: String? = nil,
                     budget: (start: Date, seconds: Double)? = nil) async -> MemoryTools? {
    let phaseStart = Date()
    sessionLog("initMemoryTools: opening lattice at \(defaultDbPath)", sessionId: sessionId)
    guard let lattice = openLattice() else {
        sessionLog("initMemoryTools: FAILED — no database at \(defaultDbPath)", sessionId: sessionId)
        hookLog("No memory database at \(defaultDbPath)")
        return nil
    }
    let hubOpenSeconds = Date().timeIntervalSince(phaseStart)
    sessionLog("initMemoryTools: lattice opened", sessionId: sessionId)

    // Embedder BEFORE the secondary attaches: it is the other big fixed
    // cost, and the attach decision below wants to see both.
    let modelPath = ProcessInfo.processInfo.environment["CLAUDE_MEMORY_MODEL"]
    sessionLog("initMemoryTools: loading embedder (modelPath=\(modelPath ?? "bundled"))", sessionId: sessionId)
    let embedderStart = Date()
    let embedder = EmbeddingService(modelPath: modelPath)
    await embedder.load()
    let embedderSeconds = Date().timeIntervalSince(embedderStart)
    sessionLog("initMemoryTools: embedder loaded", sessionId: sessionId)

    var attachSecondary = true
    if let budget {
        let elapsed = Date().timeIntervalSince(budget.start)
        attachSecondary = HookBudget.shouldAttachSecondary(elapsed: elapsed, budget: budget.seconds)
        hookLog(String(format: "initMemoryTools phases: hub open %.2fs, embedder %.2fs, %.2fs of %.1fs budget elapsed",
                       hubOpenSeconds, embedderSeconds, elapsed, budget.seconds))
        if !attachSecondary {
            hookLog("initMemoryTools: degraded: skipping synced/spokes (hub open + embedder consumed > "
                + "\(Int(HookBudget.secondaryAttachFraction * 100))% of the recall budget)")
        }
    }

    // Synced DB — same open the MCP server does (main.swift). Without it,
    // hook recall (advise/on-start/pre-tool) was blind to cross-device
    // memories: readLattice saw syncedLattice == nil and every synced
    // project silently fell back to local-only. Plain open, no WSS/IPC —
    // the daemon owns sync; hooks only read.
    //
    // Gated on POLICY, not just file existence (R3): readLattice only ever
    // attaches the synced DB for a project whose SyncConfig policy is .sync
    // (project row or the "_default" fallback), so when NO row says .sync
    // this open is pure cost — and against a daemon mid-catch-up it is the
    // cost that wedges the hook. The hub handle is already open; one
    // indexed read decides.
    var syncedRef: LatticeThreadSafeReference?
    let claudeDir = (defaultDbPath as NSString).deletingLastPathComponent
    let syncedDbPath = SyncService.syncedDbPath(claudeDir: claudeDir)
    if attachSecondary, FileManager.default.fileExists(atPath: syncedDbPath) {
        let syncPolicyInPlay = lattice.objects(SyncConfig.self)
            .where { $0.policy == .sync }
            .first != nil
        if syncPolicyInPlay {
            let synced = try? Lattice(
                Memory.self, Edge.self, SyncConfig.self,
                configuration: .init(fileURL: URL(fileURLWithPath: syncedDbPath),
                                     migration: engramMigrations,
                                     busyTimeoutMs: hookBusyTimeoutMs)
            )
            syncedRef = synced?.sendableReference
            sessionLog("initMemoryTools: synced lattice \(synced != nil ? "opened" : "FAILED to open") at \(syncedDbPath)", sessionId: sessionId)
        } else {
            sessionLog("initMemoryTools: synced DB present but no SyncConfig row has policy .sync — skipping the synced open", sessionId: sessionId)
        }
    }

    // Per-session Lattice logging — opt-in, see `configureLatticeLogging`.
    configureLatticeLogging(sessionId: sessionId)

    // Group spokes — the same membership-scoped union the MCP server reads.
    // Without these the advise hook injects only personal memories, which is
    // the whole point of group sync missing from the surface where teammates'
    // knowledge is supposed to show up unprompted.
    var groupRefs: [MemoryTools.GroupSpokeRef] = []
    for spoke in attachSecondary ? SyncService.discoverGroupSpokes(claudeDir: claudeDir) : [] {
        guard let lattice = try? Lattice(
            Memory.self, Edge.self, GroupProjectMap.self,
            configuration: .init(fileURL: URL(fileURLWithPath: spoke.path),
                                 migration: engramMigrations,
                                 busyTimeoutMs: hookBusyTimeoutMs)
        ) else {
            sessionLog("initMemoryTools: FAILED to open group spoke at \(spoke.path)", sessionId: sessionId)
            continue
        }
        groupRefs.append(.init(groupId: spoke.groupId, path: spoke.path,
                               ref: lattice.sendableReference))
    }
    sessionLog("initMemoryTools: \(groupRefs.count) group spoke(s) attached", sessionId: sessionId)

    let tools = MemoryTools(localRef: lattice.sendableReference, syncedRef: syncedRef,
                            groupRefs: groupRefs, embedder: embedder)
    // Every hook recall INJECTS its output into a tool-capable session, so
    // the hook path always fences foreign-authored content; the per-device
    // opt-out ("memory-hooks group-advise off" or the visualizer settings
    // row) excludes it entirely. One site — Advise, OnStart, and PreTool
    // all init through here.
    let includeGroup = lattice.objects(HookState.self)
        .where { $0.key == .adviseIncludeGroupMemories }
        .first?.value != "false"
    await tools.setForeignContentPolicy(fence: true, exclude: !includeGroup)
    return tools
}

/// Get the current total memory count from the database.
func currentMemoryCount() -> Int? {
    guard let lattice = openLattice() else { return nil }
    return lattice.count(Memory.self)
}

/// Read a global HookState value by key from an ALREADY-OPEN lattice.
///
/// Every open/close pair pays a PRAGMA optimize and a PASSIVE checkpoint, so
/// call sites that touch several keys in a row must share one handle rather
/// than reach for the convenience overloads below.
func getHookState(_ lattice: Lattice, key: HookState.Key) -> String? {
    lattice.objects(HookState.self)
        .where { $0.key == key }
        .first?.value
}

/// Write a global HookState value by key (upsert) on an already-open lattice.
func setHookState(_ lattice: Lattice, key: HookState.Key, value: String) {
    if let existing = lattice.objects(HookState.self).where({ $0.key == key }).first {
        existing.value = value
        existing.updatedAt = Date()
    } else {
        // Non-throwing helper by design (hook call sites treat state writes
        // as best-effort); a failed upsert logs rather than propagating.
        do { try lattice.add(HookState(key: key, value: value)) }
        catch { hookLog("setHookState(\(key)) failed: \(error)") }
    }
}

/// Read a global HookState value by key, opening the database for it.
func getHookState(key: HookState.Key) -> String? {
    guard let lattice = openLattice() else { return nil }
    return getHookState(lattice, key: key)
}

/// Write a global HookState value by key (upsert), opening the database for it.
func setHookState(key: HookState.Key, value: String) {
    guard let lattice = openLattice() else { return }
    setHookState(lattice, key: key, value: value)
}

/// Get or create the SessionState row for a given session ID.
/// Run `body` with the session state while HOLDING the backing lattice.
/// The old shape returned the object after the function-scope lattice was
/// released — with the weak instance cache, a solo hook process then
/// deallocated the lattice under the live object, and the next property
/// WRITE trapped in the C++ backend (production memory-hooks OnStop
/// crashes, Jul 3-4: SessionState.stopNudgeSent.setter → setBool SIGTRAP).
@discardableResult
func withSessionState<T>(sessionId: String?, _ body: (SessionState) -> T) -> T? {
    guard let sessionId, !sessionId.isEmpty else { return nil }
    guard let lattice = openLattice(sessionId: sessionId) else { return nil }
    let state: SessionState
    if let existing = lattice.objects(SessionState.self).where({ $0.sessionId == sessionId }).first {
        state = existing
    } else {
        state = SessionState(sessionId: sessionId)
        do { try lattice.add(state) }
        catch {
            hookLog("withSessionState: could not create SessionState: \(error)")
            return nil
        }
    }
    return withExtendedLifetime(lattice) { body(state) }
}

#endif

// MARK: - ANSI Colors

private enum ANSIColor {
    static let reset   = "\u{1B}[0m"
    static let bold    = "\u{1B}[1m"
    static let dim     = "\u{1B}[2m"
    static let cyan    = "\u{1B}[36m"
    static let magenta = "\u{1B}[35m"
    static let green   = "\u{1B}[32m"
    static let yellow  = "\u{1B}[33m"
    static let red     = "\u{1B}[31m"
    static let blue    = "\u{1B}[34m"
}

/// Color-code a distance value: green (<0.20), yellow (0.20-0.35), red (>0.35).
private func colorDist(_ dist: String) -> String {
    guard let d = Double(dist) else { return dist }
    let color = d < 0.20 ? ANSIColor.green : d < 0.35 ? ANSIColor.yellow : ANSIColor.red
    return "\(color)\(dist)\(ANSIColor.reset)"
}

// MARK: - Recall Logging

/// Path to the per-session recall log for the statusline.
private let memoryLogsDir = NSHomeDirectory() + "/.claude/memory-logs"

/// Parse a directRecall result string and log a compact summary of each recalled memory.
/// Format: one line per memory with id (short), project/topic, distance, and content preview.
/// When sessionId is provided, also writes a statusline-optimized version to the session recall log.
func logRecalledMemories(_ result: String, hook: String, sessionId: String? = nil) {
    // Each memory block starts with [id:UUID] [project/topic]
    // Direct results: [id:UUID] [project/topic] (distance: 0.123...) content
    // Connected results come after "--- Connected (graph traversal, depth: N) ---"

    var directCount = 0
    var connectedCount = 0
    var inConnected = false
    var lines: [String] = []
    var statusLines: [String] = []

    for block in result.components(separatedBy: "\n\n") {
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }

        if trimmed.hasPrefix("--- Connected") {
            inConnected = true
            continue
        }
        if trimmed.hasPrefix("⚠️ Weak recall") {
            lines.append("  \(ANSIColor.yellow)\(ANSIColor.bold)⚠️  weak recall signal\(ANSIColor.reset)")
            statusLines.append("  \(ANSIColor.yellow)\(ANSIColor.bold)⚠️  weak recall\(ANSIColor.reset)")
            continue
        }

        // Parse [id:UUID] [project/topic] ...
        guard trimmed.hasPrefix("[id:") else { continue }

        // Extract short ID (first 8 chars of UUID)
        let idEnd = trimmed.firstIndex(of: "]") ?? trimmed.startIndex
        let idStr = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<idEnd])
        let shortId = String(idStr.prefix(8))

        // Extract [project/topic]
        let afterId = trimmed[trimmed.index(after: idEnd)...]
        var projTopic = ""
        if let ptStart = afterId.firstIndex(of: "["),
           let ptEnd = afterId.firstIndex(of: "]") {
            projTopic = String(afterId[afterId.index(after: ptStart)..<ptEnd])
        }

        // Extract distance if present
        var dist = ""
        if let distRange = trimmed.range(of: "distance: ") {
            let distStart = distRange.upperBound
            if let distEnd = trimmed[distStart...].firstIndex(where: { $0 == "," || $0 == ")" }) {
                dist = String(trimmed[distStart..<distEnd])
            }
        }

        // Extract edge info for connected memories
        var edge = ""
        var statusEdge = ""
        if inConnected {
            if let edgeRange = trimmed.range(of: "--[") {
                let edgeStart = edgeRange.lowerBound
                if let edgeEnd = trimmed[edgeStart...].range(of: "]--") {
                    let fullEdge = String(trimmed[edgeStart...edgeEnd.upperBound])
                    edge = " \(ANSIColor.blue)" + fullEdge + ANSIColor.reset

                    // Statusline: extract edge type and direction, plus target short ID
                    let edgeType = String(fullEdge.drop(while: { $0 != "[" }).dropFirst()
                        .prefix(while: { $0 != "]" }))
                    let isOutgoing = fullEdge.hasSuffix(">")

                    // Extract target short ID from content after edge
                    var targetShortId = ""
                    if let targetIdRange = trimmed.range(of: "[id:", range: edgeEnd.upperBound..<trimmed.endIndex) {
                        let tidStart = targetIdRange.upperBound
                        targetShortId = String(trimmed[tidStart...].prefix(8))
                    }

                    let arrow = isOutgoing ? "→" : "←"
                    statusEdge = " \(ANSIColor.blue)\(edgeType) \(arrow)\(targetShortId.isEmpty ? "" : " \(targetShortId)")\(ANSIColor.reset)"
                }
            }
        }

        // Content preview: everything after the metadata parenthetical
        var preview = ""
        // Find content after last ) that follows the metadata
        if let lastParen = trimmed.range(of: ") ", options: .backwards) {
            preview = String(trimmed[lastParen.upperBound...].prefix(60))
                .replacingOccurrences(of: "\n", with: " ")
        } else {
            // Fallback: grab last portion
            let parts = trimmed.split(separator: " ", maxSplits: 3)
            if parts.count > 2 {
                preview = String(parts.last?.prefix(60) ?? "")
                    .replacingOccurrences(of: "\n", with: " ")
            }
        }

        if inConnected {
            connectedCount += 1
        } else {
            directCount += 1
        }

        // Hook log line (verbose)
        let distLabel = dist.isEmpty ? "" : " \(colorDist(dist))"
        let prefix = inConnected
            ? "  \(ANSIColor.dim)├\(ANSIColor.reset) "
            : "  \(ANSIColor.dim)•\(ANSIColor.reset) "
        lines.append("\(prefix)\(ANSIColor.cyan)\(shortId)\(ANSIColor.reset) \(ANSIColor.magenta)[\(projTopic)]\(ANSIColor.reset)\(distLabel)\(edge) \(ANSIColor.dim)\(preview)\(ANSIColor.reset)")

        // Statusline log line (compact)
        let shortDist = dist.isEmpty ? "" : {
            // ".22" instead of "0.216"
            if let d = Double(dist) {
                return " \(colorDist(String(format: ".%02d", Int(d * 100))))"
            }
            return " \(colorDist(dist))"
        }()
        let statusPrefix = inConnected
            ? "  \(ANSIColor.dim)├\(ANSIColor.reset) "
            : "  \(ANSIColor.dim)•\(ANSIColor.reset) "
        let statusContent = inConnected
            ? statusEdge
            : "\(shortDist) \(ANSIColor.dim)\(String(preview.prefix(50)))\(ANSIColor.reset)"
        statusLines.append("\(statusPrefix)\(ANSIColor.cyan)\(shortId)\(ANSIColor.reset) \(ANSIColor.magenta)[\(projTopic)]\(ANSIColor.reset)\(statusContent)")
    }

    if lines.isEmpty { return }

    // Write to hooks.log (verbose format)
    hookLog("\(ANSIColor.bold)\(hook): recalled \(directCount) direct + \(connectedCount) connected\(ANSIColor.reset)")
    for line in lines {
        hookLog(line)
    }

    // Write to session recall log (statusline format)
    if let sessionId, !sessionId.isEmpty {
        writeSessionRecallLog(
            sessionId: sessionId,
            directCount: directCount,
            connectedCount: connectedCount,
            lines: statusLines
        )
    }
}

/// Write the statusline-optimized recall log for this session (overwrites on each recall).
private func writeSessionRecallLog(sessionId: String, directCount: Int, connectedCount: Int, lines: [String]) {
    sessionLog("writeSessionRecallLog: dir=\(memoryLogsDir), sessionId=\(sessionId), \(directCount)+\(connectedCount) entries", sessionId: sessionId)
    let fm = FileManager.default
    if !fm.fileExists(atPath: memoryLogsDir) {
        sessionLog("writeSessionRecallLog: creating directory", sessionId: sessionId)
        try? fm.createDirectory(atPath: memoryLogsDir, withIntermediateDirectories: true)
    }
    let path = memoryLogsDir + "/recall-\(sessionId).log"
    let df = DateFormatter()
    df.dateFormat = "h:mm a"
    let timeStr = df.string(from: Date())
    var content = "\(directCount)+\(connectedCount) recalled @ \(timeStr)\n"
    for line in lines {
        content += line + "\n"
    }
    do {
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        sessionLog("writeSessionRecallLog: wrote \(content.count) bytes to \(path)", sessionId: sessionId)
    } catch {
        sessionLog("writeSessionRecallLog: FAILED: \(error)", sessionId: sessionId)
        hookLog("Failed to write session recall log: \(error)")
    }
}

/// Write a skip indicator to the recall log (keeps previous recall visible, adds skip note).
func writeSessionRecallSkip(sessionId: String) {
    let path = memoryLogsDir + "/recall-\(sessionId).log"
    // If a recall log already exists, don't overwrite it — the previous recall is still useful.
    // Only write the skip file if there's nothing to show yet.
    if FileManager.default.fileExists(atPath: path) { return }
    let fm = FileManager.default
    if !fm.fileExists(atPath: memoryLogsDir) {
        try? fm.createDirectory(atPath: memoryLogsDir, withIntermediateDirectories: true)
    }
    let dim = "\u{1B}[2m"
    let rst = "\u{1B}[0m"
    let content = "\(dim)recall skipped (conversational filler)\(rst)\n"
    try? content.write(toFile: path, atomically: true, encoding: .utf8)
}

/// Delete session logs only if they're older than 5 minutes (avoids race with mid-session reconnects).
func cleanupSessionLogs(sessionId: String) {
    let fm = FileManager.default
    let paths = [
        memoryLogsDir + "/recall-\(sessionId).log",
        memoryLogsDir + "/debug-\(sessionId).log",
        memoryLogsDir + "/lattice-\(sessionId).log",
        memoryLogsDir + "/lattice-mcp-\(sessionId).log",
    ]
    let staleThreshold: TimeInterval = 300 // 5 minutes
    for path in paths {
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) > staleThreshold else { continue }
        try? fm.removeItem(atPath: path)
    }
}

// MARK: - Recursion / Orchestration Guards

/// True inside a spawned learner or maintenance subprocess — their own
/// hooks must stay silent, or a learner gets nudged to spawn a learner
/// (observed in the Aug 13 workup incident: only OnStop/PreCompact checked
/// the learner variable; Advise/PreTool checked maintenance only, and
/// OnFailure checked nothing).
func isMemorySubprocess() -> Bool {
    let env = ProcessInfo.processInfo.environment
    return env["CLAUDE_MEMORY_LEARNER"] != nil
        || env["CLAUDE_MEMORY_MAINTENANCE"] != nil
}

/// True when an orchestrator (overlord, in agent sandboxes) owns learner
/// triggering: it runs `memory-hooks sample-gate` itself after the run's
/// artifact is posted. All in-session learning NUDGES and in-binary learner
/// SPAWNS stand down — a mid-run nudge lands in the billed, customer-facing
/// transcript (it became workup's posted Linear "diagnosis"), and a second
/// spawn path would double-fire the learner.
func learnerIsOrchestrated() -> Bool {
    ProcessInfo.processInfo.environment["ENGRAM_LEARNER_ORCHESTRATED"] == "1"
}

// MARK: - Shared Nudges

/// Returns the learning nudge for the given project (always fires).
func learningNudge(project: String) -> String {
    """
    ## Session learning

    If you haven't already, use the session-learner agent in the background to capture insights from this session.

    Project: \(project)

    IMPORTANT: Answer the user's request FIRST. Put the session-learner Task call at the END of your response. Do NOT relay or summarize its output — launch it silently.
    """
}

/// Threshold for first throttled learning nudge (tool calls into the session).
private let learningNudgeInitialThreshold = 15
/// Interval between subsequent throttled learning nudges (tool calls).
private let learningNudgeInterval = 30

/// Increments the tool call counter and returns a learning nudge only when threshold is crossed.
/// Use this for high-frequency hooks (PostToolUseFailure) to avoid habituation.
func throttledLearningNudge(project: String, sessionId: String?) -> String? {
    let shouldNudge = updateSessionCounters(sessionId: sessionId) { state -> Bool in
        state.toolCallCount += 1

        let lastNudgeAt = state.learningNudgeLastToolCount
        let threshold = lastNudgeAt == 0 ? learningNudgeInitialThreshold : learningNudgeInterval
        let delta = state.toolCallCount - lastNudgeAt

        guard delta >= threshold else { return false }
        state.learningNudgeLastToolCount = state.toolCallCount
        return true
    }
    guard shouldNudge == true else { return nil }
    hookLog("Learning nudge injected (throttled)")

    return """
    ## Action required: capture session insights

    Spawn the session-learner agent in the background to record what you've learned this session. \
    Project: \(project). Answer the user FIRST, put the Task call at the END, and do NOT relay its output.
    """
}
