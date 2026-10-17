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

**Tool-failure limitation:** Engram classifies only explicit structured failure
metadata, such as an integer shell exit code or an MCP error flag. Current
[Codex hook documentation](https://learn.chatgpt.com/docs/hooks) includes nonzero
Bash exits, but tool output remains host-specific. Plain-text output is left
unclassified; the adapter never guesses failure from arbitrary stdout. Verify
actual receipts on each host before claiming Claude `PostToolUseFailure` parity.

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
refusal and a new review; it is never silently added. A plan can explicitly select
at most 192 tasks; the impact scan remains bounded to 500 enrollment entries.
If the required cohort exceeds 192, keep v1 until a coordinated rollout is
prepared. Installing the new runtime preserves an existing v1 policy. A larger
selection still requires a fresh reviewed list of IDs and an exact plan; raising
the bound does not expand any existing selection or authorize activation.

Applying a plan temporarily disables host admission while publishing the selected
records and route, then restores the policy's original enabled setting in v2.
The journal supports `recover` after an interrupted publication. Other tasks'
records remain untouched; unmigrated v1 enrollments under v2 require their own
migration. Later plans use the retained original v1 policy as their legacy anchor.
The plan limit remains 32 MiB. Commands have an absolute time bound from their
original start: 30 seconds for up to 64 selected tasks, 60 seconds for 65–128,
and 90 seconds for 129–192. The full reviewed migration cohort determines the
bound, including release commands. Loading a plan and validating its selection
consume that same allowance; the clock is never restarted.

`apply` and `recover` may return exit code **3** with
`status: migration_in_progress_held`. This is a verified durable stopping point,
not completion: admission remains suspended until the final checks finish, and
all selected holds must exist before any task record changes. The summary gives
the exact plan SHA256, phase, verified hold and record counts, and
`next_command: recover`. After checking that summary, continue with **the same
reviewed plan file and SHA256**. Each command has bounded publication work;
never replace the plan, reset a cursor, or retry a failed command until green.

Exit code **0** reports the command's completed result. Exit code **1** reports
refusal or interruption requiring diagnosis; a hard deadline can leave a valid
partial journal but is not an exit-3 progress receipt. Preserve its evidence and
review the exact journal before recovery. Oversized plans refuse before
publication. Planning speed alone does not qualify application or recovery time
for a larger cohort.

Each migrated task receives a separate migration hold. `release-plan` and
`release` remove only explicitly selected holds after validating their records.
A bounded `release` may return exit code **3** with
`status: migration_release_in_progress`, the released count, and the exact
migration and release SHA256 values. Continue only that same release plan and
SHA256; its durable intent accounts for holds already removed. Release does not
clear a reconciliation gate, change a cursor or paused request, retry work, or
launch a learner. Previously released tasks may advance normally while
their siblings remain held. Use the CLI's `--help` and `hook-status` to inspect
the required arguments and current state.

### Interrupted learning and historical reconciliation

New V2 learner runs require the native `localMutationOperationsV1` capability.
Each write has a durable operation identity, and the native server commits its
receipt with the mutation. Recovery first waits for the old writer to finish,
then checks recorded operations. It does not retry a provider run merely because
a response was lost. Cursor and queue publication use a separate durable journal;
a newer queued request survives completion of an older run. Upgrade the native
MCP and plugin together. A capability mismatch remains an explicit hold.

`hook-status` and the app distinguish native writes, provider completion,
verified transcript coverage, interrupted publication and independent readback.
An old success timestamp or enabled policy alone does not mean current learning
is healthy. Passive health inspection does not run a provider or query memories.

Legacy failed runs lack the new execution seals. The explicit
`scripts/learner_reconcile.py` CLI supports a narrow retrospective review: one
acknowledged remember and one affirmative pre-transaction no-write remember,
both with elapsed original fourteen-day lifetimes, plus a reviewed disposition
for every message in the bounded interval. It requires current V2 admission,
exact historical evidence, independent memory-row checks and a hash-pinned review
bundle. It refuses other cases, including fresh unexpired intents and uncertain
writes. Use `--help` for the explicit `prepare`, `apply` and `recover` arguments.

A separate expired replacement-update profile supports one acknowledged update
followed by one affirmative pre-transaction no-write remember, with both original
fourteen-day lifetimes elapsed. It requires the exact update arguments and
acknowledgement, an independent readback of the preserved row, and a pinned
review covering all thirteen assistant messages in the historical interval.
Every sentence and clause must have a reviewed disposition and attribution;
assistant proposals cannot become asserted facts. The same publication and
recovery checks apply, with no memory writes or renewed lifetimes.

Preparation produces an immutable plan for inspection. Application requires that
plan's exact SHA256, preserves the original failed run and memory IDs, advances
only its reviewed interval, and records `legacy_reconciled_no_new_mutation`.
It performs no native mutation and does not renew a lifetime, claim historical
provider success, or manufacture modern successful-coverage evidence. The
pending request retains its original pause and provenance; resuming it is a
separate operation with normal admission checks.

For a separately reviewed legacy update followed by an affirmative no-write
remember, `scripts/learner_residual.py` supports the reviewed five-intent recovery
profile. `prepare` seals the review, current source, preserved update and native
store route; it does not dispatch mutations. `execute` requires the prepared run,
manifest and context hashes. It preserves the old update and sends only the
retained residual intents through native durable operations.

`recover` only checks recorded operation status and completes qualified
publication. An absent operation remains held until the explicit
`continue-absent` command receives the same execution pins. Continuation first
revokes every older writer and reuses the original operation IDs and payloads.
Unknown writes, changed evidence, manual-review pauses and semantic duplicates
remain held. This narrow profile does not prepare a second residual recovery for
a task that already has a recorded residual reconciliation.

The resulting `legacy_reconciled_with_residuals` receipt records retrospective
reviewed writes separately from the failed historical provider run. It advances
only the reviewed interval, preserves original or newer pending work, and leaves
explicit resume as a separate action. Inspect the completed recovery receipt and
perform independent memory readback before treating the recovery as verified.

Interrupted application can finish only its pinned publication. The worker can
recover selected unfinished legacy metadata when its current local store route
and owned locks are available; otherwise it reports a hold for explicit recovery.
Repeated application or recovery still requires the current published state and
reviewed inputs. Later cursor or relevant memory changes require inspection;
they never authorize republishing an old plan.

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
