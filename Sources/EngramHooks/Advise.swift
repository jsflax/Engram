import ArgumentParser
import EngramMemoryCore
import Foundation
#if canImport(EngramKit)
import EngramKit
import Lattice
#endif

/// Synchronous blocking sleep for the watchdog test seam: models a C++
/// frame stuck in an uninterruptible lock wait, so it must genuinely BLOCK
/// the thread (Task.sleep would suspend cooperatively — the opposite of the
/// failure being simulated). Isolated here because `Thread.sleep` is
/// (rightly) unavailable to async contexts.
private func blockingWedge(seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
}

/// UserPromptSubmit hook: recalls relevant memories, nudges learning and maintenance.
struct Advise: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Recall relevant memories, nudge learning and maintenance (UserPromptSubmit hook)"
    )

    func run() async throws {
        // The hook's ONE absolute deadline is anchored here — everything
        // this process does (recall AND the tail) shares it.
        let hookStart = Date()

        // Guard against recursion: learner/maintenance subprocesses set env vars
        if isMemorySubprocess() {
            return
        }

        let inputData = readStdin()
        guard !inputData.isEmpty else { return }

        let input: UserPromptSubmitInput
        do {
            input = try JSONDecoder().decode(UserPromptSubmitInput.self, from: inputData)
        } catch {
            hookLog("Failed to parse hook input: \(error)")
            return
        }

        guard let prompt = input.prompt, !prompt.isEmpty else {
            hookLog("Advise: empty or nil prompt, skipping")
            return
        }

        let project = projectName(from: input.cwd)
        let proj = project ?? "unknown"
        let sid = input.sessionId
        sessionLog("Advise: START sessionId=\(sid ?? "nil"), project=\(proj)", sessionId: sid)
        hookLog("Advise: project=\(proj), prompt=\(String(prompt.prefix(80)))...")

        // Recall must be FAST OR ABSENT — a degraded database (WAL bloat,
        // contention) must never ride to the harness's kill timeout and
        // stall the user's prompt. Budget = a fraction of THIS hook's own
        // registered timeout (read from settings.json), so tightening the
        // registration tightens the budget with it. The deadline is
        // ABSOLUTE, from hook start: recall and the post-recall tail
        // (maintenance check, session counters) spend from the same
        // account, so a slow recall leaves the tail less, and a consumed
        // budget leaves it nothing (Aug 2026 incident: the UNBUDGETED tail
        // blocked on the same wedged database and rode to the 60s kill).
        // Degradation is VISIBLE: a one-line notice in the injected
        // context, never a silent absence.
        let budget = HookBudget.recallBudget(event: "UserPromptSubmit")
        let deadline = hookStart.addingTimeInterval(budget)

        // H1.6: the section accumulator doubles as the UNCONDITIONAL
        // watchdog. Armed here — before ANY lattice/DB touch — with an OS
        // thread deadline of budget+2s: the budgets above stop WAITING on a
        // wedged database, but only the watchdog still runs when a C++
        // frame is stuck in an uninterruptible lock wait and the
        // cooperative pool is starved. Whatever has accumulated by then
        // ships, with a one-line notice, exit 0.
        let watchdog = HookWatchdog(eventName: "UserPromptSubmit")
        watchdog.arm(
            firesAt: hookStart.addingTimeInterval(budget + 2),
            notice: "⚠️ Memory hook watchdog: the memory system did not finish within "
                + "\(String(format: "%.0f", budget))s+2s; emitting partial context and exiting. "
                + "Memories are intact; recall resumes when the database recovers.")

        if let remote = RemoteConfig.active {
            // Remote backend: the server does distillation, ranking,
            // fencing, and budgeting; gate-less by design (it runs once per
            // agent event). Returns the full "## Relevant memories" block.
            if let block = await RemoteMemory.advise(
                remote, prompt: prompt, project: remote.project ?? project) {
                sessionLog("Advise(remote): block \(block.count) chars", sessionId: sid)
                logRecalledMemories(block, hook: "Advise", sessionId: sid)
                watchdog.append(block)
            } else {
                sessionLog("Advise(remote): no block", sessionId: sid)
                if let sid, !sid.isEmpty { writeSessionRecallSkip(sessionId: sid) }
            }
            await appendNudgesAndEmit(input: input, project: proj, deadline: deadline,
                                      watchdog: watchdog)
        }

        #if canImport(EngramKit)
        // Whether recall rode past its budget. A database that just failed
        // to answer inside its own budget is the LAST database that should
        // be handed more work — the tail below branches on this.
        var recallBlewBudget = false

        // Gate: classify whether this prompt is worth recalling memories for.
        sessionLog("Advise: running recall gate", sessionId: sid)
        let gate = try? RecallGateClassifier()
        let shouldRecall = gate?.shouldRecall(query: prompt) ?? true
        sessionLog("Advise: recall gate = \(shouldRecall ? "recall" : "skip")", sessionId: sid)
        hookLog("Advise: recall gate = \(shouldRecall ? "recall" : "skip")")

        // Recall relevant memories (only if gate says the prompt is topical)
        if shouldRecall {
            sessionLog("Advise: calling initMemoryTools", sessionId: sid)
            currentSessionId = sid
            // The budget covers the WHOLE slow path — tools init (model load
            // + DB opens, which pay the same degraded-database costs as the
            // query) AND the recall itself. Timeline evidence: on a bloated
            // hub, init alone took 10s before any query ran. The Lattice
            // query-deadline primitive (1.3.0) will upgrade this from "stop
            // waiting" to "interrupt the query".
            hookLog("Advise: running budgeted recall (budget \(budget)s)")
            let outcome = try await HookBudget.race(
                seconds: max(0, deadline.timeIntervalSinceNow)
            ) { () -> (result: String, query: String)? in
                guard let tools = await initMemoryTools(sessionId: sid) else {
                    hookLog("Advise: failed to initialize memory tools")
                    return nil
                }
                // Extract content words to focus the embedding on key concepts.
                // Raw prose averages all concepts into a poor vector neighborhood.
                let contentWords = MemoryTools.extractContentWords(from: prompt)
                let recallQuery = contentWords.isEmpty ? prompt : contentWords.joined(separator: " ")
                hookLog("Advise: running directRecall (query: \(String(recallQuery.prefix(80)))...)")
                guard let result = try await tools.directRecall(
                    query: recallQuery,
                    project: project,
                    depth: 1,
                    limit: 5
                ) else { return nil }
                return (result, recallQuery)
            }
            switch outcome {
            case .completed(let recall?):
                let result = recall.result
                sessionLog("Advise: directRecall returned \(result.count) chars", sessionId: sid)
                logRecalledMemories(result, hook: "Advise", sessionId: sid)
                sessionLog("Advise: logRecalledMemories done, recall log written", sessionId: sid)
                watchdog.append(AdviseAssembly.memorySection(renderedRecall: result, query: recall.query))
            case .completed(nil):
                sessionLog("Advise: recall returned nil (or tools init failed)", sessionId: sid)
                hookLog("Advise: recall returned nil")
            case .failed(let error):
                sessionLog("Advise: directRecall FAILED: \(error)", sessionId: sid)
                hookLog("Advise: recall failed: \(error)")
            case .deadlineExceeded:
                recallBlewBudget = true
                sessionLog("Advise: recall EXCEEDED \(budget)s budget — degrading visibly", sessionId: sid)
                hookLog("Advise: recall exceeded \(budget)s budget — skipped (db degraded?)")
                watchdog.append(
                    "⚠️ Memory recall skipped this turn — exceeded its \(String(format: "%.0f", budget))s budget. " +
                    "The memory database is responding slowly (maintenance or repair may be needed); " +
                    "memories are intact and recall resumes when the database recovers.")
                if let sid, !sid.isEmpty { writeSessionRecallSkip(sessionId: sid) }
            }
        } else {
            hookLog("Advise: skipped recall (conversational filler)")
            // Write skip indicator so statusline shows current state
            if let sid, !sid.isEmpty {
                writeSessionRecallSkip(sessionId: sid)
            }
        }

        // Spawn maintenance subprocess if threshold crossed (fire-and-forget).
        // Local-only: the server owns hygiene for the shared PG store.
        // NEVER after a blown budget: the check itself re-opens the same
        // database that just failed to answer inside its budget — in the
        // Aug 2026 incident that open blocked on the connection mutex held
        // by the orphaned recall, riding the hook to the harness's 60s kill.
        // And never PAST the deadline: the tail spends only what recall
        // left in the shared budget.
        if recallBlewBudget {
            hookLog("Advise: recall blew its budget — skipping the maintenance check")
        } else {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                hookLog("Advise: no budget left for the maintenance check — skipping")
            } else {
                let outcome = try? await HookBudget.race(seconds: remaining) {
                    spawnMaintenanceIfNeeded(project: proj, cwd: input.cwd)
                }
                if case .deadlineExceeded = outcome {
                    hookLog("Advise: maintenance check exceeded the remaining "
                        + "\(String(format: "%.1f", remaining))s budget — abandoned")
                }
            }
        }
        #endif

        // TEST SEAM (child-process watchdog test): simulate the incident's
        // uninterruptible C++ lock wait on the main path — a blocking sleep
        // no budget race can interrupt, in the exact place the unbudgeted
        // tail used to wedge. Inert without the env var; while it holds,
        // only the watchdog can end this process.
        if let raw = ProcessInfo.processInfo.environment["ENGRAM_TEST_ADVISE_WEDGE_MS"],
           let wedgeMs = Double(raw), wedgeMs > 0 {
            hookLog("Advise: TEST wedge engaged (\(Int(wedgeMs))ms)")
            blockingWedge(seconds: wedgeMs / 1000.0)
        }

        await appendNudgesAndEmit(input: input, project: proj, deadline: deadline,
                                  watchdog: watchdog)
    }

    /// Shared tail for both backends: the stop-hook handshake, the learning
    /// nudge, and the hook output envelope.
    ///
    /// `deadline` is the hook's one absolute deadline: the lattice-backed
    /// session counters answer only inside it. Past it — or on overrun —
    /// the FILE-backed store (SessionCounters.swift) answers instead, so a
    /// wedged database cannot hold the output envelope hostage. The file
    /// store misses lattice-side stop-nudge state; the worst case is one
    /// redundant learning nudge on an already-degraded turn.
    private func appendNudgesAndEmit(input: UserPromptSubmitInput, project: String,
                                     deadline: Date, watchdog: HookWatchdog) async -> Never {
        // Learning nudge — skip if stop hook just fired (session-learner already spawned)
        let sessionId = input.sessionId
        let consumeStopNudge: @Sendable (inout SessionCounters) -> Bool = { state in
            guard state.stopNudgeSent else { return false }
            state.stopNudgeSent = false
            return true
        }
        let remaining = deadline.timeIntervalSinceNow
        let consumedStopNudge: Bool?
        if remaining <= 0 {
            hookLog("Advise: no budget left for lattice session counters — using the file store")
            consumedStopNudge = fileSessionCounters(sessionId: sessionId, consumeStopNudge)
        } else {
            let outcome = try? await HookBudget.race(seconds: remaining) {
                updateSessionCounters(sessionId: sessionId, consumeStopNudge)
            }
            if case .completed(let value) = outcome {
                consumedStopNudge = value
            } else {
                hookLog("Advise: session counters exceeded the remaining "
                    + "\(String(format: "%.1f", remaining))s budget — falling back to the file store")
                consumedStopNudge = fileSessionCounters(sessionId: sessionId, consumeStopNudge)
            }
        }
        // In orchestrated mode (sandboxes) the nudge NEVER fires: the
        // orchestrator runs sample-gate itself post-run, and a mid-run
        // nudge would land in the billed transcript.
        if consumedStopNudge != true && !learnerIsOrchestrated() {
            watchdog.append(learningNudge(project: project))
        }

        // Hard exit (inside the watchdog's one-shot emit): a one-shot hook
        // must not pay teardown costs. Lattice deinit runs a close-time
        // checkpoint that took 11s against a bloated WAL (timeline
        // evidence) — on top of a met budget, that alone can blow the
        // harness registration. stdout is already flushed (unbuffered fd
        // write); an orphaned budgeted query dies here, and SQLite handles
        // process death safely. Maintenance children survive exec-style.
        watchdog.completeNormally()
    }

    #if canImport(EngramKit)
    // MARK: - Maintenance Subprocess

    /// The maintenance system prompt, loaded from agents/memory-maintenance.md or inlined.
    private static let maintenanceSystemPrompt: String = loadAgentSystemPrompt(
        name: "memory-maintenance", bundle: agentPromptBundle,
        fallback: """
        You are a memory maintenance agent. Your job is to analyze the memory database and improve its organization for better recall quality.

        ## Workflow
        1. Run stats() and list_topics() to understand memory distribution.
        2. Run find_clusters() to discover redundant memories.
        3. Consolidate genuinely redundant memories. Keep distinct ones separate.
        4. Use organize() to create subtopics for large topic groups.
        5. Connect new memories to related existing ones.
        6. Verify improvements with stats() and list_topics().

        ## Guidelines
        - Read full memory content before deciding what to do.
        - Only consolidate memories that are truly saying the same thing.
        - Be efficient — don't over-process clean databases.
        """
    )

    private static let maintenanceAllowedTools = "mcp__memory__*,Read,Grep,Glob,Bash"

    private static let maintenanceLogPath = NSHomeDirectory() + "/.claude/memory-maintenance.log"

    /// Check if maintenance threshold is crossed and spawn the subprocess if so.
    /// Counts AuditLog rows since last run — immune to concurrent-process
    /// counter clobbering.
    ///
    /// This runs AFTER recall, inside whatever remains of the hook's one
    /// absolute deadline (it used to be UNBUDGETED — every cost landed on
    /// the user's prompt latency, and on a wedged database it rode to the
    /// harness kill). Two costs used to dominate:
    ///
    /// 1. Up to six Lattice open/close cycles per prompt — one at the top of
    ///    the function plus one per `getHookState`/`setHookState` — each
    ///    paying a PRAGMA optimize and a PASSIVE checkpoint on close, even
    ///    when the very first short-circuit was about to return. Now: ONE
    ///    handle, and the already-active / cooldown short-circuits run
    ///    before anything else touches the database.
    ///
    /// 2. `COUNT(*) WHERE tableName = 'Memory' AND timestamp > since` over a
    ///    3.96M-row audit log. The only usable index leads on `tableName`, so
    ///    that walked every Memory audit row and fetched each row's
    ///    `timestamp` from the table — 3.8s warm on the reporting user's
    ///    database. And it ran on EVERY prompt once past the cooldown, not
    ///    once per window: the cooldown is measured from the last SPAWN, so
    ///    a database that never reaches the threshold pays it forever.
    ///
    /// The window is now anchored on the audit primary key recorded at the
    /// last spawn instead of on a timestamp. `id > watermark` is a rowid
    /// restriction the index can answer, so the count never leaves the index
    /// for the rows it rejects: 0.05s on that same database, a 75x cut, and
    /// exact — not an estimate.
    ///
    /// The row filter deliberately keeps BOTH halves of the trigger's
    /// meaning: `tableName == "Memory"` AND local origin. A bare
    /// `head - watermark` delta would count sync-applied rows, so any sync
    /// drain would spawn a maintenance subprocess on every cooldown.
    private func spawnMaintenanceIfNeeded(project: String, cwd: String?) {
        guard let lattice = openLattice() else { return }

        let lastRunTimestamp = Double(
            getHookState(lattice, key: .maintenanceLastRunTimestamp) ?? "0"
        ) ?? 0
        let since = Date(timeIntervalSince1970: lastRunTimestamp)

        // Don't spawn if maintenance is already running — but with a
        // staleness escape: the flag is cleared by the maintenance agent on
        // completion, so a SIGKILL mid-run used to leave it stuck at "1" and
        // disable maintenance forever. lastRunTimestamp is set alongside the
        // flag, so an "active" older than an hour is a corpse, not a run.
        if getHookState(lattice, key: .maintenanceActive) == "1" {
            let flagAge = Date().timeIntervalSince(since)
            if flagAge < 3600 { return }
            setHookState(lattice, key: .maintenanceActive, value: "0")
        }

        // Enforce minimum cooldown to prevent maintenance's own writes from re-triggering
        guard Date().timeIntervalSince(since) >= maintenanceCooldownSeconds else { return }

        // Head of the audit log. Monotonic (INTEGER PRIMARY KEY AUTOINCREMENT),
        // and a descending walk stops on the first row.
        let headId = lattice.objects(AuditLog.self)
            .sortedBy(\.primaryKey, order: .reverse)
            .first?.primaryKey ?? 0

        guard let stored = getHookState(lattice, key: .maintenanceAuditWatermark),
              let watermark = Int64(stored) else {
            // First evaluation on this database, or the first after upgrading
            // from the timestamp-window trigger. Anchor at the current head
            // rather than pay the 3.8s reconstruction of a window we are
            // about to stop using; the cost is at most one deferred
            // maintenance run, once.
            setHookState(lattice, key: .maintenanceAuditWatermark, value: String(headId))
            hookLog("Advise: seeded maintenance audit watermark at \(headId)")
            return
        }

        let delta = lattice.objects(AuditLog.self)
            .where { $0.primaryKey > watermark && $0.tableName == "Memory" && $0.isFromRemote == false }
            .count

        guard delta >= maintenanceThreshold else { return }

        // Update baseline immediately to prevent re-spawning on next advise call
        setHookState(lattice, key: .maintenanceLastRunTimestamp, value: String(Date().timeIntervalSince1970))
        setHookState(lattice, key: .maintenanceAuditWatermark, value: String(headId))

        // Signal the visualizer that maintenance is active
        setHookState(lattice, key: .maintenanceActive, value: "1")

        let prompt = """
        Perform maintenance on the memory database. Focus on project "\(project)".

        Current state: \(delta) Memory writes since last maintenance.

        Follow your system prompt workflow: assess, find redundancy, find communities, take action, connect the graph, verify.
        """

        let hooksBin = NSHomeDirectory() + "/.claude/bin/memory-hooks"

        do {
            try spawnClaudeSubprocess(
                prompt: prompt,
                systemPrompt: Self.maintenanceSystemPrompt,
                allowedTools: Self.maintenanceAllowedTools,
                model: "sonnet",
                envGuard: (key: "CLAUDE_MEMORY_MAINTENANCE", value: "1"),
                logPath: Self.maintenanceLogPath,
                cwd: cwd,
                postCommand: "'\(hooksBin)' clear-maintenance",
                // Maintenance legitimately runs long (consolidate/organize
                // sweeps) — keep bounds well above the learner defaults.
                maxTurns: 40,
                wallClockSeconds: 1800
            )
            hookLog("Advise: spawned memory-maintenance subprocess (ops delta: \(delta))")
        } catch {
            hookLog("Advise: failed to spawn memory-maintenance: \(error)")
        }
    }
    #endif
}
