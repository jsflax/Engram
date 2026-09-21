# Engram for Codex

Engram gives Codex persistent memory, project advice, and automatic session learning.
The plugin includes the native Swift memory MCP server and resource bundles,
seven memory skills, the Engram icon, and lifecycle adapters.

## Setup

Install **Engram** from its configured marketplace, review and trust its hook
definitions in Codex's Hooks settings or `/hooks`, then start or continue a task. Hooks
initialize host settings automatically under `$CODEX_HOME/engram` (normally
`~/.codex/engram`). Each laptop gets its own paths, enrollment, and queue.

The bundled native build supports Apple Silicon Macs running macOS 15 or newer.
The lifecycle adapters require Python 3.11 or newer; the launcher discovers a
compatible local interpreter. Install Python separately if no compatible version
is available. Codex launches the Swift memory server directly. Python runs the
hooks and the learner's restricted MCP proxy; no HTTP memory service is used.
The learner uses the signed-in Codex
account through an ephemeral local Codex subprocess.

A separately configured `mcp_servers.memory` overrides the bundled server.
Automatic memory access requires an effective policy explicitly approving the
needed tools. Disabled tools and plugin policies remain effective. Installed
packages resolve policy from their exact marketplace cache identity. A source
checkout requires exactly one matching configured plugin identity; ambiguous
identities fail closed, including when one candidate is disabled.

## Lifecycle

| Event | Behavior |
|---|---|
| SessionStart | Recall project context and enroll the task |
| UserPromptSubmit | Recall prompt advice; ensure enrollment |
| SubagentStart | Supply context; enroll when a child transcript is available |
| PreToolUse / Agent or collaboration spawn | Recall agent-task context; periodic learning nudge |
| PostToolUse | Recognize explicit structured failures when supplied |
| Stop / SubagentStop | Queue incremental task or child learning |
| PreCompact / auto | Queue learning before automatic compaction |
| SessionEnd | Clean ephemeral tool counters; preserve learning progress |

**Tool-failure limitation:** the inspected Codex 0.154 source omits usable exit
metadata from some shell hook payloads and does not dispatch some failed tool
calls. The adapter never guesses failure from arbitrary stdout. This is partial
failure-event coverage, not full Claude `PostToolUseFailure` parity.

Advice uses the prompt and inferred project, with no fixed memory UUID pins.
When the project is inferred, semantically relevant memories from this user's
other projects may be returned with their project label. An explicit entry in
`recall.json`'s `projects` map restricts output to that project and global memories.

## Learning and privacy

Tasks enroll automatically at their first observed transcript boundary. Existing
history is not backfilled. If the first observed event is Stop, learning starts
with later appended content. Fresh children may learn their first work only when
their creation time and inherited-history boundary are proven.

One queue and provider lock serialize automatic learners on each Codex home.
The learner has no project shell, browser, other integrations, or recursive hook
access. Its memory proxy enforces approved tools, private new memories, session
provenance, bounded calls/writes, and exact write receipts. Failure does not
advance saved progress. Interactive memory calls and another laptop remain independent.

If a failed run has a successful, unresolved, or unknown write, its task is held
as `reconciliation_required`. Later turns cannot replay that excerpt until the
recorded run and memory IDs are reconciled. The hook-status skill exposes this
condition; it does not clear it automatically.

Receipts distinguish enrollment, queued work, provider completion, and reported
memory UUIDs. Queueing is not completion; a saved UUID is not independent database
readback. Advice receipts describe generated context, not whether a model used it.
Receipts omit prompts and memory bodies. Private learner run state can contain
excerpts and provider output needed to execute and verify a run.

To pause future learning, set `enabled` to `false` in
`engram/learner/admission.json`. Setup preserves existing settings and disabled
policies. Pausing does not cancel a running provider. Plugin enable-state changes
apply at Codex's supported reload boundary; existing-task pickup needs verification.

## Migration

### Persistent transcript identity

Fresh host setup uses `host_sessions_v2`: a local APFS volume UUID plus inode
identifies each bound directory and transcript. A device number may change after
a remount; it is checked within each read for races, but is not saved as the v2
identity. Unsupported filesystems fail closed. Existing host settings are kept
unchanged when the package is updated.

Existing `host_sessions_v1` tasks require explicit, selected-task migration with
`scripts/codex_learner_migrate.py`. Its `plan` command validates the original
policy, enrollment frontier, transcript metadata, cursor and pending request;
the resulting plan binds exact preimages and runtime hashes. Inspect that plan
before passing its path and SHA256 to `apply`. When no historical volume UUID
exists, current-volume adoption must be explicitly authorized and is recorded
as such; migration does not prove historical volume continuity.

The first host policy conversion must include the explicitly reviewed healthy
v1 tasks, including tasks waiting for their next event. The tool rechecks that
cohort under its locks before changing state. A newly eligible task causes a
refusal and a new review; it is never silently added. If the required cohort
exceeds the supported selection bound, keep v1 until a coordinated rollout is
prepared. Installing the new runtime preserves an existing v1 policy.

Applying a plan temporarily disables host admission while publishing the selected
records and route, then restores the policy's original enabled setting in v2.
The journal supports `recover` after an interrupted publication. Other tasks'
records remain untouched; unmigrated v1 enrollments under v2 require their own
migration. Later plans use the retained original v1 policy as their legacy anchor.

Each migrated task receives a separate migration hold. `release-plan` and
`release` remove only explicitly selected holds after validating their records.
They do not clear a reconciliation gate, change a cursor or paused request, retry
work, or launch a learner. Previously released tasks may advance normally while
their siblings remain held. Use the CLI's `--help` and `hook-status` to inspect
the required arguments and current state.

### Previous installers

`engram@personal` succeeds `engram-hooks@personal`. Disable the old plugin through
Codex's plugin controls before trusting the successor. Keep old cached resources
for open tasks that still reference them. The new package never replays or deletes
the paused pilot queue and does not modify Claude Code's hooks.

If the standalone native Codex learner was installed previously, run its
`install_codex_support.sh uninstall` action before enabling the plugin. That
ownership-aware migration removes only the legacy registrations it can identify;
it preserves learner queues, cursors, runtime files, and custom memory settings.
Review any reported ownership conflict instead of deleting hooks manually.
New native installers skip legacy setup when an Engram plugin is configured,
including when that plugin is disabled. Old immutable learner runtimes still
require the explicit migration; a source update cannot change their behavior.

Public marketplace distribution requires separate platform compatibility,
licensing, packaging, and submission review.
