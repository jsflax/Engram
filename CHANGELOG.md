# Changelog

All notable changes to Engram are documented in this file.

> Formerly "ClaudeMemory" — renamed in v0.12.0 to be tool-agnostic.

## [Unreleased]

## [0.14.4] - 2026-09-09

### Performance
- **The menu-bar activity feed reads only its latest 20 memories.** Reads
  happen off the main thread, bursts of database changes are coalesced,
  and relative timestamps no longer re-enumerate the database every second.
  Cached rows survive closing the feed, and its subscription restarts on
  every opening of macOS's reused status panel.
- **Sidebar statistics, recent activity, and log tails are cached.** Log
  reads are bounded and run in the background; opening panels no longer
  sorts or scans the full graph on the main thread.
  Project and relation rows are laid out lazily, with configuration read
  once per render instead of repeatedly for each row.
- **Graph loading yields between small batches.** Semantic embedding work,
  label-atlas rasterization, and mascot information cards run in the
  background, with obsolete work discarded when the graph changes.
- **Settled graphs avoid redundant rendering work.** Position revisions,
  complete visibility-cache invalidation, and stable GPU instance slots
  reduce repeated data preparation and uploads without lowering visual
  budgets. Settled nebula emitters also avoid redundant transform writes.
  Bounded upload buffers are reused only after the GPU finishes
  reading them; failed uploads remain eligible for retry.
- Added isolated macOS profiling fixtures and regression coverage for
  menu SQL work, graph updates, label generation, and GPU instance reuse.

### Known performance limits
- Large real-world graphs still exceed the 33 ms frame target, and some
  automated menu interactions exceed 100 ms. This is an incremental performance
  release, not clearance of every performance gate. See the
  [validation report](https://github.com/jsflax/Engram/blob/v0.14.4/docs/performance/2026-09-09-follow-up.md) for measurements
  and remaining validation gaps.

Hook-side half of the agents-platform "learner nudge" incident fix
(Aug 13: mid-run nudges became the workup agent's posted Linear
"diagnosis"; see the engram-server/overlord waves for the other half).

### Fixed
- **A learner can no longer be nudged to spawn a learner.** The advise
  and pre-tool hooks guarded only against the maintenance subprocess
  (`CLAUDE_MEMORY_MAINTENANCE`) and the failure hook guarded against
  nothing; all three now also stand down inside a spawned learner
  (`CLAUDE_MEMORY_LEARNER`), matching the stop/pre-compact hooks.
- **The stop hook's sample-gate spawn now resolves the hooks binary from
  the running executable** instead of the hardcoded Mac install path
  (`~/.claude/bin/memory-hooks`). In sandboxes the binary lives at
  `/usr/local/bin/memory-hooks`, so every sandbox Stop event exec-127'd
  silently — the learner pipeline never ran in a sandbox even once.

### Added
- **Orchestrated-learner mode** (`ENGRAM_LEARNER_ORCHESTRATED=1`): when
  an orchestrator owns learner triggering (agent sandboxes, where it
  invokes `memory-hooks sample-gate` itself after the run's artifact is
  posted), all in-session learning nudges are suppressed — a mid-run
  nudge lands in the billed, customer-facing transcript — and the
  stop/pre-compact spawn paths stand down so the learner can't
  double-fire. Local (Mac) behavior is unchanged.
- **Spawned subprocesses are bounded.** The detached learner runs with
  `--max-turns 15` and a 12-minute wall-clock kill (portable sh watcher;
  macOS has no `timeout(1)`); maintenance gets wider bounds (40 turns /
  30 minutes). Previously both were unbounded on the host's API key.

## [0.14.3] - 2026-08-13

0.14.2 fixed sync's correctness diseases; this release fixes its
*availability* diseases. If your prompt hook was killed at 60 seconds
with nothing to show for it, if the sync database's write-ahead log grew
to gigabytes while the daemon ran, or if machine-to-machine sync sat
"pending" forever while the log filled with UNIQUE-constraint errors,
this is the fix.

### Fixed
- **The prompt hook can no longer hang to the harness's kill.** Three
  layers, so no single failure wedges it again: hook database opens now
  use a 2-second lock patience instead of the library's 30 (and the
  library now honors that setting for transaction starts, which it
  previously ignored — two hidden 30-second waits were the whole 60
  seconds); everything after recall runs against one absolute deadline
  and falls back to file-backed state on overrun; and an unconditional
  watchdog thread ships whatever was gathered and exits cleanly at
  budget+2s even if a database call is stuck in native code and cannot
  be interrupted. Worst case is now a slightly degraded answer two
  seconds late, never a silent 60-second death.
- **Idle helper processes no longer pin the write-ahead log.** Each MCP
  server that had answered even one call kept a read snapshot open
  indefinitely, and one held snapshot is enough to stop checkpoints from
  reclaiming ANY log space — the log hit 16GB twice this way. Two fixes:
  the internal maintenance timer no longer disarms itself in a narrow
  race while a snapshot is being created (the bug that made snapshots
  immortal), and every tool call now releases all read snapshots when it
  finishes — an idle helper holds zero.
- **Machine-to-machine sync no longer livelocks under load.** Applying
  received changes fought a vector-index maintenance path that blindly
  rewrote index rows it didn't need to touch — tens of thousands of
  constraint failures hammering the write lock. Index reconciliation now
  checks before writing (the common case is now a lock-free read), and a
  batch that fails mid-apply keeps credit for the chunks that committed
  instead of being re-sent in full forever. The stuck machine's four
  frozen windows drain on first reconnect.
- **The daemon now says so when the log is pinned.** If the write-ahead
  log passes 1GB while checkpointing is stuck, the daemon logs which
  processes are holding it — the last two occurrences of this took days
  to diagnose from the outside; the next one is a log line.
- **Sync log lines now say which side wrote them.** The hub and the
  mirror sides of the same channel logged under one identical label from
  one process, which misdirected diagnosis in two incidents running.

## [0.14.2] - 2026-08-11

Finishes the job 0.14.1 started. 0.14.1 stopped sync history from being
*created* without bound, but two defects kept it from being *cleaned up*,
and a third made the app itself crash while syncing. If your database
grew again after 0.14.1, if the app quit unexpectedly while the sidebar
or graph was open, or if sync seemed stuck at "uploading" forever, this
is the fix.

### Fixed
- **Sync could get permanently stuck partway through an upload.** When an
  acknowledgement arrived later than the uploader's patience allowed, the
  upload was resent — correctly — but the entry stayed marked as
  outstanding forever afterward. That frozen marker is the same one that
  gates history cleanup, so a single late acknowledgement could stop a
  machine from ever cleaning up its history again. On the affected
  machine two channels were frozen with 245,550 entries above them that
  the database had already recorded as delivered. Late acknowledgements
  now resolve properly, and every upload pass reconciles its outstanding
  list against what the database actually says.
- **Receiving an update that changes nothing no longer records history.**
  Two synced machines could hand each other the same unchanged rows
  indefinitely, and each machine recorded a full history entry per
  arrival. One machine took on 2.3 million such entries in four hours.
  Updates that would not change a single value are now recognized and
  acknowledged without being recorded — with a durable receipt so
  re-delivery still can't apply stale data over a newer local edit.
- **The app could crash while sync was running.** Every batch of changes
  spawned its own delivery task on a thread with a small stack, and a
  busy sync (hundreds of thousands of rows) spawned thousands of them at
  once; deep enough into the work, the app ran out of stack and quit.
  Delivery now runs on one dedicated thread with room to work.
- **Reading a memory's fields no longer costs one database query per
  field.** Loading a row's values now fetches the whole row once. This
  was the innermost layer of the crash above, and it makes the graph,
  the sidebar, and recall meaningfully faster.
- **Uploads are acknowledged far faster.** The server was writing tens of
  thousands of diagnostic log lines per batch — inside the database
  transaction, on the connection thread everyone else shared — which
  dominated the time to acknowledge an upload and stalled unrelated
  connections. Applying an upload now happens off that shared thread,
  with the per-row logging where it belongs, and acknowledgements are no
  longer sent for acknowledgements (a pointless round trip that ran
  forever).
- **Catch-up can no longer come back empty.** A client whose last-known
  position had been cleaned up on the server received *nothing* on
  reconnect, silently and permanently. It now receives full history.
- **The sync daemon no longer hangs silently when it can't read your
  credentials.** A signature mismatch made the keychain read wait for a
  prompt that can never appear in the background, leaving a daemon that
  looked alive and did nothing. It now gives up, explains the likely
  cause, and restarts.
- **Installing or upgrading no longer resets your hook timeouts.** Any
  value you raised was overwritten on every app launch; a too-short
  timeout means the prompt hook is killed mid-recall and your memories
  quietly don't arrive. Both installers (the app and `install.sh`) now
  merge per hook — your raised timeouts and any hooks of your own under
  the same events survive — instead of replacing whole sections.
- **Related memories could go missing from a project's clusters.** The
  similarity search asked for the closest matches *globally* and only
  then narrowed to the project, so a busy neighbouring project could use
  up every slot and a project's own related memories would never be
  found — losing an entire cluster from the graph. The search is now
  scoped before it ranks.
- **Clustering a project got dramatically cheaper**: 20,802 database
  queries down to 601 for a 200-memory project (~1.2s → ~0.16s), because
  neighbour comparison no longer round-trips to the database per memory.
  This is the work that made opening a large graph slow.
- **The prompt hook no longer writes a debug log on every prompt.** It
  was on unconditionally — 93MB single log files, 748MB accumulated —
  and the writing happened inside the window your prompt waits on. Set
  `ENGRAM_LATTICE_LOG_LEVEL` if you want it back.
- **The prompt hook's maintenance check no longer scans the whole
  history.** It counted matching rows by timestamp over the entire audit
  log — 3.8 seconds on a large database, *after* the recall budget was
  already spent. It now compares against a saved position: 0.05s.

## [0.14.1] - 2026-08-09

Fixes a sync-history defect that could make the memory database grow
without bound — and repairs affected databases automatically. If your
machine felt slow after 0.14.0 (a stalled first launch, laggy project
list, hanging sync toggles, or hook timeouts), this is the fix.

### Fixed
- **Sync history could grow without bound.** Four defects compounded:
  every schema migration re-recorded the entire database into the sync
  history; a shared-graph channel that matched nothing could never
  advance its cursor, which in turn vetoed *all* history cleanup; the
  cleanup itself keyed off a value that skips ahead of un-uploaded work,
  so it deleted nothing rather than risk deleting too much; and the
  uploader re-sent each batch before its acknowledgements could arrive
  (16-26× amplification). On the worst affected machine: 4.7M history
  rows for 28K memories, an 11GB write-ahead log, and a sync daemon that
  never finished uploading. Fixed at the source, with the compounding
  cleanup veto removed.
- **Automatic repair.** Affected databases are compacted at the next
  daemon start (no action needed), and history is now compacted hourly
  rather than only at startup. `memory-sync repair-audit` is the opt-in
  tool that additionally reclaims disk — it backs up every database
  first, refuses to run unless the daemon is stopped and no other
  process holds the files, and reports exactly what it changed. On the
  affected machine: 5.3GB → 844MB with byte-identical recall results.
- **First launch after the 0.14.0 upgrade stalled the app** — the
  one-time re-embedding sweep never flushed its write-ahead log, so
  every reader (the visualizer's graph load, recall) crawled for the
  duration and local-only projects appeared missing. The sweep now
  checkpoints as it goes.
- **Memory recall in hooks is time-budgeted.** A degraded database could
  make the prompt hook run until the harness killed it — silently, with
  no context and no explanation. Recall now gets a budget derived from
  the hook's own configured timeout; on overrun it says so in one line
  instead of stalling your prompt or vanishing.
- **Sync progress logs identify their channel** — several sync channels
  share one log stream, and unlabeled interleaved counters made this
  incident far harder to diagnose than it should have been.

## [0.14.0] - 2026-08-08

Groups: shared memory for teams. Your personal graph stays yours; each
group you join adds a shared graph that recall reads alongside it. Also
ships embedding space v2 (better semantic matching, automatic migration)
and a deep round of crash and recall-correctness fixes.

### Added
- **Groups — shared memory graphs for teams.** Organizations are trees
  (an org root, teams, sub-teams); membership anywhere in a subtree
  implies membership above it. Each group syncs to its own on-device
  graph, recall unions your personal graph with every membership graph
  in one query, and shared results are attributed (`[by:Name]`) and
  provenanced (`[via:group]`). Reads are membership-scoped; *exposure*
  is a separate, explicit per-project control over what leaves the
  machine. Invites, roles (owner/admin/member), per-seat billing, and
  admin tooling live on engramdb.io; the visualizer renders each group
  as its own galaxy with author rows, management UI, and per-group
  exposure controls.
- **Team → concept links (a graph of graphs).** A team can link to a
  shared concept graph (say, `mobile`) and every member gains
  member-level access through the link — one hop, same organization,
  no per-person joins. Linked graphs join the recall union like any
  membership graph. Creating a link takes admin on both ends; severing
  it takes admin on either end and revokes access immediately.
- **Embedding space v2.** The bundled model switches to mean-pooled
  paraphrase-MiniLM (held to ≥0.999 parity with the reference server
  implementation by a regression gate), with recall/dedupe thresholds
  recalibrated from 27k rows of production data. Existing memories are
  re-embedded by an idempotent, version-marked sweep that runs at
  daemon startup and — for machines without a running daemon, including
  signed-out and free-tier installs — as a background backstop when the
  memory server starts. Shared group graphs converge as each author's
  machine migrates and relays its re-embedded vectors (a manual
  `memory-sync migrate-embeddings` sweep exists for repair and offline
  copies).
- **Prompt-injection fence for shared content.** Teammate-authored
  memories injected into hook context are wrapped in a "data, not
  instructions" fence with a length cap, and the maintenance
  subprocess never sees foreign-authored content at all.
- **Linux hooks.** `memory-hooks` builds on Linux — the full hook
  suite works in remote and sandboxed sessions.
- **EngramMemoryCore.** The memory contract (recall/advise/remember
  over structured captures) is now a portable module with an
  executable conformance suite, shared by the local tools and server
  backends.

### Fixed
- **Crashes under system memory pressure** (latticecore 1.2.2–1.2.5).
  A purged sqlite page cache could SIGSEGV column-name reads; C++
  database errors escaping through the Swift bridge killed the app
  with SIGTRAP. All Swift-facing read, transaction, lookup, and
  maintenance surfaces are now sealed — errors surface as errors, not
  crashes. Also fixed the Xcode lockfile pinning that had quietly kept
  app builds on old, unfixed dependency versions.
- **Recall could silently miss shared-graph memories** (latticecore
  1.2.6–1.2.8). Four independent defects, each enough to hide teammate
  content: multi-graph KNN keyed candidates by per-database rowid, so
  colliding rowids across graphs surfaced wrong rows with borrowed
  distances (now keyed by global identity); a graph hydrated purely by
  sync never got a vector index at all (now created and backfilled
  automatically at open, and `vacuum` covers group graphs); the
  multi-database union view mapped columns by position, so filters
  read scrambled values and dropped valid rows (now projected by name);
  and the query planner could drive the vector index as a join's inner
  side under filters, returning nothing (the KNN now runs isolated).
- **Graph traversal edge shadowing** — a loose (distance-gated) edge
  discovered before a structural edge to the same memory no longer
  suppresses it, so `part_of`/`relates_to` connections always surface.
- **Expired sign-in surfaces as signed-out** instead of a silently
  failing sync, and the CLI gains `account` subcommands to inspect and
  repair auth state.
- **Group galaxies resolve canonical project names** across members
  (a teammate's differently-named checkout of the same repo lands in
  the same galaxy), and nebula rendering gained titles, bridges, LOD,
  and a per-galaxy gas fix.

## [0.13.3] - 2026-07-08

Performance release: kills the sync-daemon busy-spin, the unbounded WAL
growth, and the recall slowdown they compounded into (Claude Code's
UserPromptSubmit hook timing out — recall observed at 228s on a churned
database; now sub-second).

### Fixed
- **Sync daemon busy-spin** — upload passes were re-invoked with zero delay
  from four sites and each pass re-scanned the entire audit log (the daemon
  burned ~46 CPU-hours in 2 days against a slow server). Upload ticks are
  now paced (leading-edge immediate + coalescing window; WSS 750ms, IPC
  relay 50ms), each pass is bounded to one send window by a new per-slot
  `upload_floor` cursor, and a stalled server backs the resend cadence off
  exponentially instead of being re-hammered every 10s.
- **Unbounded WAL growth** — nothing at runtime ever checkpointed the WAL
  while the daemon's long-lived connections pinned the passive autocheckpoint
  (`memory.sqlite-wal` observed at 1.1GB; every SQL statement then pays an
  O(WAL) page-lookup penalty). The sync engine now runs PASSIVE checkpoints
  every 60s — including while disconnected — and TRUNCATE every 5 minutes
  when idle.
- **Reconnect storms** — the exponential backoff reset itself on every
  successful open, so a flapping endpoint reconnected at ~1s forever. The
  counter now resets only after a connection proves stable (≥60s).
- **Recall N×K statement explosion** — every property read on a recalled
  memory issued its own `SELECT` (~300 statements per depth-1 recall).
  Recall now materializes each hit from the row its query already fetched
  (zero further SQL), reads embeddings once per traversal candidate, and
  batches access-stat bumps into one transaction of atomic increments on
  the correct database handle (they silently autocommitted individually on
  synced projects before).
- **Sync progress counters** — `pending` accumulated the whole backlog on
  every pass and never returned to zero; it now mirrors exactly the
  sent-but-unACKed set, so the daemon health surface is trustworthy.

## [0.13.2] - 2026-07-06

First field-report fix (thanks to the first external install).

### Fixed
- **CLI binaries broken after app auto-update** — the installer copied
  binaries out of a Sparkle-updated bundle without stripping
  `com.apple.quarantine`, so Gatekeeper blocked the memory MCP server when
  Claude Code spawned it; a partial copy could also stamp the version and
  wedge the install until the next release. The installer now strips
  quarantine after each copy, treats missing bundled binaries as an error,
  verifies every binary (executable + unquarantined) before stamping the
  version, and logs failures to `~/.claude/cli-install-error.log` instead of
  dying silently.

## [0.13.1] - 2026-07-05

Same-day follow-up to 0.13.0 focused on onboarding and first-run polish.

### Fixed
- **Stale dev endpoints purged at launch** — a persisted ngrok/localhost
  `sync_endpoint` from an old dev session survived app updates and silently
  pointed both the app and the sync daemon at a dead tunnel ("authentication
  failed" with no hint why). Ephemeral dev endpoints are now discarded;
  genuine custom endpoints still persist.
- **Daemon endpoint follows the app** — the sync daemon's launchd plist
  snapshots its `--endpoint` at install time; endpoint changes (and the
  migration above) now rewrite the plist and restart the daemon immediately
  instead of waiting for the next app version bump.
- **Proximity audio audible from anywhere** — the manual distance gain never
  fully silenced (floored at −30 dB) and the quantile LOD near-tier is
  relative, so the nearest tones hummed at any camera distance. Voices now
  hard-mute beyond an absolute audibility range.

### Added
- **Live subscription unlock** — while signed in without an active
  subscription, the app polls status once a minute; an admin-granted (or
  newly purchased) subscription connects sync immediately, no restart.
- **Subscribe button** in the Account tab for signed-in users without a
  subscription — opens the web checkout.

### Notes
- Email registration works end-to-end as of the 0.13.0 server deploy (the
  server now returns a session token on register; previously registration
  failed silently in all app versions).

## [0.13.0] - 2026-07-05

The revival release: three months of accumulated breakage fixed across the
full stack — visualizer, IPC/cloud sync, hooks, and the production relay.
Cloud sync is live end-to-end for the first time since April 5.

### Fixed — sync (15 production bugs)
- **Cloud sync outage root causes**: expired auth token silently rejected every 60s
  for 3 months (the UI's green "Synced" showed pending-count, not connection state —
  now a real health surface); relay dropped each connection's first frames
  (handler-registration race); no at-least-once redelivery (unACKed entries now
  resend on a 10s timeout); IPC wedged at 0/365 by sync-state collapse against a
  stale config snapshot (live slot registry + startup heal).
- **The relay killer**: Swift C++-interop on aarch64 Linux crashes (null protocol
  witness) on Collection ops over imported std::vector — the production relay
  segfaulted on every received frame. macOS unaffected, so every local gate stayed
  green. Index loops now (lattice 0.10.6); reproduced + validated in a Linux container.
- **Unshare destroyed peers' data**: narrowing a sync filter fleet-deleted rows on
  every device (the February data-loss bug). Filter removals now stop at the
  device's own synced DB; peers retain their copies (E2E-pinned).
- **URLSession 401 poisoning**: one 401 during server boot made CFNetwork silently
  drop the Authorization header on all later connects in that session — fresh
  ephemeral session per attempt + stale-session delegate guard.
- **Upload flow control**: full-backlog bursts (25×1MB frames) overran the relay;
  sends are now windowed per ack round-trip. Transport errors without close events
  left the synchronizer "connected" and unable to reconnect — fixed.
- **April recall crash**: Results live-fetch subscript TOCTOU under Collection.map —
  KNN results materialized via Array().
- **Hooks crash**: session state mutated after its backing lattice deallocated
  (weak instance cache) — all access now scoped via withSessionState.

### Fixed — visualizer
- **Traversal color flash**: MeshInstancesComponent slots are now stable across
  topology changes (color texture and transforms aren't versioned together by
  RealityKit); departed slots collapse to zero scale.
- **Mascot "camo" texture**: the scene sets no IBL, so RealityKit's default studio
  environment mirrored in glossy regions — reflections damped (roughness floor,
  specular cut, clearcoat off). The asset itself was never broken.
- **Sign-out crash during galaxy load** (Galaxy.startObservers fatalErrors → graceful).
- **New-memory relayout**: a settled simulation absorbs small topology deltas (≤24)
  without a full re-layout jolt.
- **MeshInstancesComponent UAF crash** on near-camera orbit (create-once components).
- **Sidebar lag**: per-project counts cached (was 77 synchronous SQL COUNTs per
  SwiftUI body evaluation against a 1.1GB database).

### Performance
- Visualizer at 42k nodes / 232k edges: orbit worst-case 434ms → **12.4ms p50**
  (preview, full 8k-instance render budget + 30k edges). Idle LOD is ~free
  (cached visible-set); GPU force pass confirmed 0.4–1.0ms (Barnes-Hut).
- Production adapter now maintains indexed position arrays + per-tick caches
  (glow/centroid/topic), quantile-tier LOD replaces fixed cutoffs (fixed
  5000-unit cull blanked the whole graph at 42k scale).
- Label propagation rewritten: async in-place, sticky ties, closed-neighborhood
  seeding — deterministic communities.

### Added
- **CrashReporter**: async-signal-safe crash reports for the MCP server (ring
  buffer + signal handlers, no allocation in the handler).
- **Statusline**: remember-events render in the Claude Code statusline
  (engram-statusline.sh + installer).
- **Sync health surface**: daemon status JSON (state/pending/lastSync) + red/yellow
  problem rows in the sync UI.
- **vacuum / train_vectors MCP tools**; nuclear-compact escape hatch for full
  re-upload; fresh-peer replay handshake for IPC catch-up.

### Changed
- Package now depends on tagged releases (lattice 0.10.6) instead of a local
  path — remote-resolved builds are the release gate.
- Maintenance trigger: 10 → 50 CRUD ops + 15-minute cooldown (self-retrigger fix).
- Lattice logging env-gated (default error) + session-log cleanup covers all
  binaries; memory-logs no longer grow unbounded.

### Known debt
- EngramVisualizerTests' GPU-internal suites (BH roundtrip internals, hybrid
  CPU-integration path, pipelining-count asserts) predate the April Metal refactor
  and were dead-on-arrival with it (a deleted-kernel crash blocked the whole target
  until this release); their timing budgets are idle-machine calibrated. The public
  ForceEngine path is green. Reconciliation tracked for a follow-up.

## [0.12.4] - 2026-02-26

### Fixed
- **Label atlas crash on large graphs** — `renderLabelAtlas` created textures exceeding Metal's 16384px max dimension when users had many memories with long labels (e.g. height 22774). Atlas now falls back to 1x scale when 2x would overflow, with a hard cap at 16384.
- **Label truncation overflow** — `extractLabel` topic-prefix path could produce 50+ character labels (e.g. `"visualizer-3d-rendering-core: ..."`) when topic names were long, wasting atlas row space. Labels now intelligently budget between topic and content, capped at 30 chars total.
- **Atlas texture storage mode** — changed from `.managed` to `.shared` (correct for Apple Silicon unified memory)

### Changed
- **Sparkle signing** — replaced `--deep` codesign with explicit bottom-up signing of XPC services, fixing App Management TCC prompt on macOS Ventura+

## [0.12.3] - 2026-02-26

### Fixed
- **Metal crash on minimize** — MTKView continued rendering at 60fps when the window was minimized, producing zero-dimension drawables that triggered a Metal validation SIGABRT. Added dimension guards and pause/resume on minimize/deminiaturize.
- **Empty embedding SIGTRAP** — `remember`, `merge`, and `consolidate` silently stored `Vector<Float>([])` when the CoreML embedding model failed to load. Later `recall` with a valid query vector hit a dimension mismatch in sqlite-vec, causing an uncatchable SIGTRAP in LatticeCore. These operations now fail with a clear error instead of storing empty vectors.

### Improved
- **Recall quality** — NLTagger POS-based content-word extraction for FTS queries (drops determiners, pronouns, prepositions), staleness penalty for never-accessed memories older than 14 days, weak-recall warning when average distance > 0.07, and graph traversal now filters connected memories by semantic relevance to the query
- **GPU compute edge stamping** — edge cylinder geometry now stamped via Metal compute kernel, matching the existing node sphere pipeline
- **Log rotation** — hooks, session-learner, and maintenance logs rotate at 256KB with one `.1` backup

### Added
- **Sidebar view** — new left-side panel for graph controls and navigation

## [0.12.2] - 2026-02-25

### Fixed
- **Sparkle auto-update broken** — `sparkle:version` (build number) was hardcoded to `1` for every release, so Sparkle never offered updates. Build number now auto-increments from the previous appcast entry.

## [0.12.1] - 2026-02-25

### Changed
- **Raw Metal renderer** — replaced RealityKit with a custom MTKView pipeline, eliminating 67.5% main thread blocking in `re::DrawingManager::commitFrameInternal()` and 13.5% VFX lock contention from `ParticleEmitterComponent`
- **GPU procedural nebulae** — fBm noise billboards rendered entirely in Metal fragment shaders, replacing RealityKit particle emitters
- **Blinn-Phong lighting** — sphere impostor nodes use analytical normal reconstruction with Blinn-Phong shading tuned for dark-background aesthetic
- **Opaque rendering** — fog baked into `base_color` in shaders instead of `.transparent` blending, avoiding GPU depth sorting of 55K+ triangles
- **Search spotlight** — suppressed recall glow on non-matching nodes for cleaner visual contrast
- **EngramModels library extraction** — core model types (Memory, Edge, Checkpoint, HookState) moved into a separate SPM target; EngramKit re-exports via `@_exported import EngramModels`
- **Account UI** — Apple and Google Sign-In via `AuthenticationServices` and `GoogleSignIn-iOS`, posting identity tokens to cloud sync backend
- **Streaming graph load** — batched node loading off main actor for faster initial render
- **GraphRenderStore** — bypass SwiftUI observation for 3D render data, reducing unnecessary view recomputation
- **Project labels in 3D view** — project name labels rendered in the 3D scene with tighter clustering
- Lattice dependency switched from local path to remote URL (`0.4.0`)

### Fixed
- Node flicker during force simulation convergence
- FTS5 full-text search query handling
- GPU compute label batch sizing and edge buffer synchronization
- Drive-to-project camera animation

## [0.12.0] - 2026-02-22

### Changed
- **Rebrand to Engram** — product name, Xcode project, bundle ID (`io.engram.app`), CI/CD artifacts, and documentation all renamed. CLI tool names (`memory` / `memory-hooks`) and MCP server name (`memory`) are unchanged.
- **Fire-and-forget memory maintenance** — maintenance agent now spawns as a detached `claude` CLI subprocess (same pattern as session-learner) instead of injecting a nudge into conversation context. Saves tokens and turns in the main conversation.
- Extracted shared `spawnClaudeSubprocess()` utility used by both session-learner and maintenance spawners
- Maintenance nudge removed from all hook handlers (SessionStart, PreToolUse, PostToolUseFailure, PreCompact) — only the Advise hook spawns maintenance now
- Subprocess allowed tools use wildcard `mcp__memory__*` instead of enumerating each tool

## [0.11.0] - 2026-02-21

### Added
- **Sparkle auto-update** — in-app "Check for Updates..." menu item with Ed25519-signed appcast feed
- **DMG distribution** — notarized DMG with drag-to-Applications install, built in CI
- **CLI sync on launch** — app bundles MCP server, hooks, and agents; auto-installs to `~/.claude/bin/` when app version is newer
- **3D hub expansion** — tap a hub node to orbit its children in a Fibonacci sphere arrangement
- **3D edge flow particles** — animated particles traveling along edges of selected/expanded nodes
- **3D search spotlight** — matching nodes glow cyan, non-matches dim to 12% opacity

### Changed
- Release CI pipeline overhauled: xcodebuild archive, Developer ID signing, DMG creation, notarization, Sparkle appcast generation
- `appcast.xml` committed to repo root and auto-updated by CI on each release
- `install.sh` now mentions DMG download as an alternative

## [0.10.0] - 2026-02-21

### Added
- **3D graph visualization** — full RealityKit-based 3D view with orbit camera, fog, nebula particle clusters, and depth-sorted canvas labels with shadow outlines
- **Gamepad support** — FPS-style controls: L-stick move, R-stick look, triggers rise/descend, A select, B deselect, X/Y teleport prev/next project, bumpers cycle nodes
- **Keyboard teleport** — T/R keys teleport to next/previous project (equivalent to gamepad Y/X)
- **Teleport to hub node** — camera jumps to the project's hub memory (target of `part_of` edges) with tight orbit radius, falling back to centroid
- **Live 3D updates** — new memories and edges appear incrementally without app restart via `ForceSimulation3D.addNode()`/`addEdge()`
- **Progressive t-SNE animation** — nodes smoothly drift from force layout to semantic positions as t-SNE converges, with lerp-based display/target separation
- **ScreenCaptureKit export** — Export as PNG captures Metal/RealityKit content correctly (replaces obsoleted `CGWindowListCreateImage`)
- **UI test suite** — Xcode UI test target with frame timing profiler and teleport proximity verification
- **Xcode project** — `Engram.xcodeproj` for building/testing outside SPM
- `set_project` parameter on `update` tool for moving memories between project scopes

### Changed
- Session-learner rewritten as fire-and-forget `claude` CLI subprocess (eliminates Conductor UI collision)
- Session-learner always spawns when transcript is present (removed productive-tool-call threshold)
- Uninstall script now cleans up all installed components (hooks, agents, binary)
- `.mcp.json` added to `.gitignore`

### Improved
- **3D render performance** — opacity caching skips redundant ECS mutations, edge distance culling hides off-screen edges, position-change detection gates edge geometry updates, label cap at 80 nearest, shadow filter replaces 5-draw stroke (62% work time reduction)
- **3D drag sync** — `isDragging` flag skips camera lerp during drag so labels and entities move in lockstep
- **Activity panel selection** — two-way sync via `lastSyncedSelection` prevents Timer from stomping binding changes

### Fixed
- Teleport double-scaling bug: camera target was scaled by `scaleFactor` twice (once in teleport, again in `cameraTransform`), placing orbit center near origin instead of the target node
- Teleport label stomping: rapid teleports no longer cancel each other's dismiss timers (counter-based task ID)
- Session-learner infinite recursion via `CLAUDE_MEMORY_LEARNER` env var guard
- Conductor UI collision from session-learner nudge ordering

## [0.9.1] - 2026-02-20

### Changed
- Session-learner always spawns when transcript is present (removed `productiveCount` threshold gate)
- Improved session-learner prompt: framing changed to "capture what was learned"; explicit skip instruction for trivial sessions
- Added `--output-format text` to CLI invocation for human-readable session-learner logs

## [0.9.0] - 2026-02-20

### Added
- **Fire-and-forget session learning** — Stop hook spawns detached `claude` CLI subprocess, eliminating Conductor UI collision
- **Progressive t-SNE animation** — nodes drift from force layout to semantic positions as t-SNE converges
- `set_project` parameter on `update` tool for moving memories between project scopes

### Changed
- Uninstall script cleans up all installed components
- `.mcp.json` added to `.gitignore`

## [0.8.2] - 2026-02-16

### Added
- Node lifecycle animations: arrival glow, death fade, and snap-back physics on drag release

## [0.8.1] - 2026-02-16

### Changed
- Rebalanced force simulation physics for better node spacing
- Added `summary` parameter to `organize` tool for custom hub descriptions
- Added test step to release CI workflow

## [0.8.0] - 2026-02-16

### Added
- **Stop hook** (`on-stop`) — blocks session end when significant code changes detected, nudges session-learner to capture insights
- **Per-session state model** (`SessionState`) — replaces global HookState keys for tool call tracking and learning nudge throttling; cleaned up on session end
- `EmbeddingService.similarity()` method for direct text-to-text similarity comparison
- Visualizer: floating PiP panel with drag, resize, and corner-snapping
- Visualizer: `@globalActor`-based force simulation for off-MainActor O(n^2) computation
- Visualizer: synchronous local repulsion on drag for immediate visual feedback

### Changed
- Recall output label changed from "relevance:" to "distance:" for clarity
- Lattice dependency updated from local path to remote `0.3.1`
- Hooks: learning nudge skipped when stop hook already fired (prevents double-nudge)
- Hooks: `openLattice()` simplified — single function replaces `openLattice(at:)` and `openLatticeReadOnly()`
- Visualizer: ActivityLogPanel refactored to use `NodeData` instead of `Memory` directly
- install.sh: auto-approve memory MCP tools

### Fixed
- Graph traversal crash when depth=0 (now uses `stride` instead of range)
- `FlexibleIntArray` parsing of bracket-wrapped string arrays
- ForceSimulation `tickInFlight` starvation — `isActive` now also checks `maxSpeed`
- Throttled learning nudge counter reset properly scoped to session instead of global state

## [0.7.1] - 2026-02-15

### Added
- Visualizer: activity log panel — persistent scrollable list of recent memories with animated slide-in, cyan glow on new entries, and click-to-navigate

### Changed
- Visualizer: replace transient toast notifications with the persistent activity log
- Visualizer: raise normal label zoom threshold from 1.4x to 1.8x for cleaner overview
- README: use `swift run -c release` for visualizer launch commands

### Improved
- Visualizer: extract search bar into isolated view to prevent expensive recomputation on each keystroke
- Visualizer: move cluster computation to reactive state for snappier search typing
- Hooks: simplified hook handlers, removed unused Analyze/TranscriptParser modules

## [0.7.0] - 2026-02-15

### Added
- **`organize` tool** — batch re-topic memories with automatic hub creation and `part_of` edge linking
- **Cross-project hub linking** — `remember` auto-links memories to other projects' hubs when content mentions them by name (word-boundary, case-insensitive)
- **Hooks binary** (`memory-hooks`) — `advise` hook injects recalled memories as context before each message; `analyze` hook nudges session learning after substantive interactions
- **Custom agents** — `session-learner` and `memory-maintenance` agent definitions for background work
- Install script improvements: better update detection, hooks binary installation, agents directory

### Changed
- Episodes refactored to hub memories (topic: "episode") linked via `part_of` edges — no separate Episode model
- Label propagation uses synchronous updates for deterministic community detection across bridge edges

### Improved
- Visualizer: smaller node label fonts, material background on stats overlay, bold hub labels, golden-angle colors, trackpad gestures, better clustering layout

### Fixed
- Replace force-unwraps with safe optional handling across MCP tool handlers
- Improve MCP error reporting with descriptive messages instead of crashes
- Label propagation bridge-edge test now passes (synchronous updates prevent label cascading)

## [0.6.0] - 2026-02-15

### Added
- Visualizer: search, filtering, clustering visualization, and performance fixes
- Pre-compile CoreML embedding model at build time for fast MCP startup
- Lazy-load embeddings on first use instead of at initialization

## [0.5.2] - 2026-02-14

### Changed
- Update Lattice dependency to versioned 0.1.0

## [0.5.1] - 2026-02-14

### Fixed
- Install script now updates existing memory instructions instead of skipping them

## [0.5.0] - 2026-02-14

### Added
- Jaccard term-overlap similarity to conflict detection (reduces false positives from topically similar but distinct memories)
- Visualizer macOS app for exploring the knowledge graph
- Demo GIF in README

## [0.4.4] - 2026-02-14

### Added
- `parent_id` parameter on `remember` for hierarchical memories (auto-creates `part_of` edges)
- Atomic memory nudges in system instructions (one concept per memory guidance)
- Smarter graph display with hub/detail hierarchy

## [0.4.3] - 2026-02-14

### Fixed
- Add consolidation guardrails to prevent over-consolidation of distinct memories

## [0.4.2] - 2026-02-14

### Fixed
- Parse `ids` parameter correctly when MCP client sends comma-separated string instead of array (affects `merge` and `consolidate`)

## [0.4.1] - 2026-02-14

### Added
- `summarized_by` relation type for the `connect` tool
- README updated with all 20 tools, Tier 2 features, and hybrid search documentation

## [0.4.0] - 2026-02-14

### Added
- **Tier 2 features**: temporal queries (`timeline`), task continuity (`checkpoint`/`resume`/`list_tasks`), episodic memory (`begin_episode`/`end_episode`/`recall_episode`/`list_episodes`), and clustering (`find_clusters`/`consolidate`/`detect_communities`)

## [0.3.0] - 2026-02-14

### Added
- Knowledge graph with directed edges (`connect`, `disconnect`, `graph` tools)
- Relation types: `relates_to`, `contradicts`, `supersedes`, `derived_from`, `part_of`
- Fine-grained `update` tool with `append`, `prepend`, `find`+`replace`, and metadata-only modes
- Conflict detection on `remember` using embedding distance thresholds
- Reinforcement and importance scoring in recall ranking

## [0.1.0] - 2026-02-13

### Added
- Initial release — local MCP memory server for Claude Code
- Core memory tools: `remember`, `recall`, `forget`, `update`, `merge`, `list_topics`, `stats`
- Hybrid search combining semantic embeddings (CoreML) and full-text search (FTS5)
- SQLite-backed persistent storage with per-project scoping
- Pre-built universal binary releases for macOS
- One-liner install script (`scripts/install.sh`)
- CI/CD with GitHub Actions on macOS 26 / Swift 6.2
- Homebrew tap workflow

[0.12.4]: https://github.com/jsflax/Engram/compare/v0.12.3...v0.12.4
[0.12.3]: https://github.com/jsflax/Engram/compare/v0.12.2...v0.12.3
[0.12.2]: https://github.com/jsflax/Engram/compare/v0.12.1...v0.12.2
[0.12.1]: https://github.com/jsflax/Engram/compare/v0.12.0...v0.12.1
[0.12.0]: https://github.com/jsflax/Engram/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/jsflax/Engram/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/jsflax/Engram/compare/v0.9.1...v0.10.0
[0.9.1]: https://github.com/jsflax/Engram/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/jsflax/Engram/compare/v0.8.2...v0.9.0
[0.8.2]: https://github.com/jsflax/Engram/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/jsflax/Engram/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/jsflax/Engram/compare/v0.7.3...v0.8.0
[0.7.1]: https://github.com/jsflax/Engram/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/jsflax/Engram/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/jsflax/Engram/compare/v0.5.2...v0.6.0
[0.5.2]: https://github.com/jsflax/Engram/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/jsflax/Engram/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/jsflax/Engram/compare/v0.4.4...v0.5.0
[0.4.4]: https://github.com/jsflax/Engram/compare/v0.4.3...v0.4.4
[0.4.3]: https://github.com/jsflax/Engram/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/jsflax/Engram/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/jsflax/Engram/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/jsflax/Engram/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/jsflax/Engram/compare/v0.1.0...v0.3.0
[0.1.0]: https://github.com/jsflax/Engram/releases/tag/v0.1.0
