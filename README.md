# Engram

A local MCP server that gives AI coding agents persistent, semantic memory across sessions.

![Demo](claude_memory_graph.gif)

## Install

```bash
curl -sL https://raw.githubusercontent.com/jsflax/Engram/main/scripts/install.sh | bash
```

This downloads the pre-built binaries and configures Claude Code. When Codex and
Python 3.11+ are installed, it also registers Codex's Engram MCP and session learner.

To build from source instead:

```bash
git clone https://github.com/jsflax/Engram.git
cd Engram
./scripts/install.sh --from-source
```

Start a new Claude Code session — memory tools are immediately available.

### Codex session learning

Codex's native `Stop`, `PreCompact`, and `SessionEnd` hooks queue an incremental
session learner. Source installs, release downloads, and Engram app upgrades all
install the same runtime. Open `/hooks` in the Codex CLI and review/trust the three
Engram hooks before they can execute. An upgrade that changes a hook definition
requires another review. Existing hooks, MCP settings, and notifications survive.
The integration is tested with Codex CLI 0.153.4; older versions without native
hooks and `--ignore-user-config` must be upgraded.

The learner uses your signed-in Codex account and selected model/reasoning effort,
so automatic learning consumes Codex usage. It sends a bounded excerpt of visible
user/assistant messages to that model, then calls your local Engram MCP to recall
and store useful findings. It excludes hidden reasoning, tool output, and inherited
fork history. Common credential patterns are redacted; this is not a general
secret detector. New memories are private and include their source session ID.
The current learner supports a local **stdio** memory MCP, not a remote HTTP MCP.

One learner runs at a time, with a 10-minute limit, at most 12 memory calls and
five writes per batch. An independent MCP gateway enforces the limits and checks
write receipts. Successful transcript ranges are checkpointed so repeated hooks
do not learn them again. Failures preserve the cursor and impose a five-minute
backoff. A wakeup processes at most four batches (24,000 visible characters each)
from one pending source; longer backlogs wait for the next source event or a manual
retry. A short `Stop` excerpt waits for more content; compaction and session end
also process short excerpts. The original Codex turn never waits for learning.

To retry installation after installing Python or Codex:

```bash
bash ~/.claude/bin/codex/install_codex_support.sh install
```

Inspect actual completion and pending sessions, or resume one pending source:

```bash
python3 ~/.claude/bin/codex/codex_learner.py status
python3 ~/.claude/bin/codex/codex_learner.py retry --session-id SESSION_ID
```

Use a Python 3.11+ interpreter for these commands. Private state and write receipts
live in `~/.codex/engram-learner/` (`CODEX_HOME` is respected). `events.jsonl` records
queueing separately from completion; `runs/*/run.json` records verified writes or
the failure reason. Failed runs retain private diagnostics. Successful runs discard
their provider transcript. Local budgets can be lowered in `settings.json` using
`wall_seconds`, `max_tool_calls`, `max_writes`, and `max_runs_per_worker`.

To disable only Codex learning, untrust its Engram hooks in `/hooks`, or run
`bash ~/.claude/bin/codex/install_codex_support.sh uninstall`. Uninstall removes
only unchanged Engram-owned registrations and keeps memories, cursors, and backups.

### Engram Visualizer

```bash
swift run -c release EngramVisualizer
```

## Why not MEMORY.md?

Claude Code has built-in memory via `MEMORY.md` files. Here's why Engram is better:

| | MEMORY.md | Engram |
|---|---|---|
| **Retrieval** | Dumps entire file into system prompt | Semantic vector search — only relevant memories surfaced |
| **Capacity** | Truncated at 200 lines | Unlimited — stores thousands, retrieves the best matches |
| **Search** | Position-based (top of file = seen first) | Hybrid FTS5 + vector similarity (most relevant = seen first) |
| **Cross-project** | Per-project files, no sharing | Project scoping + global scope — preferences follow you everywhere |
| **Maintenance** | Append-only text that gets stale | `update`, `merge`, `forget`, auto-expiring memories, conflict detection |
| **Structure** | Flat text, no relationships | Knowledge graph — connect memories with typed edges, traverse on recall |
| **Continuity** | No session awareness | Episodic memory, task checkpoints, clustering + consolidation |
| **Privacy** | Plain text files | Local SQLite + on-device embeddings (MiniLM-L6); optional Codex learning sends visible excerpts to the selected model |

**The one-liner:** MEMORY.md is 200 lines of flat text that gets stale. Engram is a vector database that scales, searches semantically, and self-maintains.

## Tools

### Core

| Tool | Description |
|------|-------------|
| `remember` | Store a memory with semantic embedding. Conflict detection blocks near-duplicates (`force: true` to override). Optional `importance: 1-5` |
| `recall` | Hybrid FTS5 + vector search with project boosting, reinforcement scoring (frequency + importance + recency), temporal filters (`since`/`before`), and optional graph traversal (`depth: 1-3`) |
| `forget` | Delete by ID, topic, or project. Cascades edge cleanup |
| `update` | Edit by ID or similarity — full replace, `append`, `prepend`, `find`+`replace`, or metadata-only (`topic`, `source`, `expires_in_days`, `importance`) |
| `merge` | Consolidate multiple memories into one. Cleans up source edges |
| `stats` | Database overview with per-project and per-topic breakdowns |
| `list_topics` | List all topics with counts |
| `timeline` | Chronological memory view grouped by day/week/month with project, topic, and temporal filters |

### Knowledge Graph

| Tool | Description |
|------|-------------|
| `connect` | Create a directed edge between memories (`relates_to`, `contradicts`, `supersedes`, `derived_from`, `part_of`, `summarized_by`) |
| `disconnect` | Remove edges by edge ID or by (from, to) pair |
| `graph` | View a memory's neighborhood — shows connections up to a given depth |

### Task Continuity

| Tool | Description |
|------|-------------|
| `checkpoint` | Save work-in-progress state (plan, progress, context) for cross-session resume |
| `resume` | Load a task checkpoint and mark it active |
| `list_tasks` | List tasks filtered by project and/or status (active, paused, completed) |

### Episodic Memory

| Tool | Description |
|------|-------------|
| `begin_episode` | Start a named session episode. Auto-closes any active episode |
| `end_episode` | End an episode with optional summary |
| `recall_episode` | Replay an episode's memories in chronological order |
| `list_episodes` | List episodes filtered by project and/or status |

### Organization & Clustering

| Tool | Description |
|------|-------------|
| `organize` | Batch re-topic memories, create a hub memory, and link members via `part_of` edges |
| `detect_communities` | Label propagation on the knowledge graph to discover natural memory groups |
| `find_clusters` | Discover groups of semantically similar memories by cosine distance |
| `consolidate` | Create a summary memory from a cluster, deprioritize originals with `summarized_by` edges |

## Engram Visualizer

An interactive force-directed graph visualization of your memory database, built with SwiftUI. Point it at a specific database with `CLAUDE_MEMORY_DB=~/path/to/memory.sqlite swift run -c release EngramVisualizer`.

**Features:**
- Force-directed graph layout with project-colored nodes and inter-project repulsion
- Floating PiP panel — drag to detach, resize from corners, snaps to screen edges
- FTS5-backed search with prefix matching — highlights matches, dims the rest
- Edge type filtering with color-coded relations (part_of, contradicts, supersedes, etc.)
- Time slider with play button to animate graph growth over time
- Project filtering toggles in the stats overlay
- Semantic cluster hulls drawn as translucent project-colored regions
- Activity log with real-time memory updates and click-to-navigate
- Minimap with click-to-navigate
- Detail panel with typewriter effect for selected memories
- Drag nodes with instant local repulsion, pan, zoom-to-cursor (scroll wheel + pinch)
- Keyboard shortcuts: Esc (deselect), Tab (cycle connections), Cmd+F (search), +/- (zoom), Cmd+Shift+E (export PNG)

## Uninstall

```bash
curl -sL https://raw.githubusercontent.com/jsflax/Engram/main/scripts/uninstall.sh | bash
```

Removes the binary and MCP registration. Database is preserved at `~/.claude/memory.sqlite` (delete manually if desired).

## How it works

- **Embedding model**: [paraphrase-MiniLM-L6-v2](https://huggingface.co/sentence-transformers/paraphrase-MiniLM-L6-v2) runs locally via CoreML. 384-dimensional vectors.
- **Storage**: SQLite via [Lattice](https://github.com/jsflax/lattice) ORM with [sqlite-vec](https://github.com/asg017/sqlite-vec) for vector search and FTS5 for full-text search.
- **Transport**: stdio MCP — server starts with each Claude Code session, loads embedding model once, stays alive for the session duration.
- **Hybrid search**: Recall combines FTS5 full-text search (any matching term qualifies) with vector cosine similarity. Falls back to FTS5-only if the embedding model is unavailable.
- **Scoping**: Memories have `project` and `topic` fields. Project is a soft ranking signal — same-project and global memories rank higher, but cross-project results still surface if semantically relevant.
- **Knowledge graph**: Connect memories with typed directed edges. Recall with `depth > 0` follows edges via BFS to surface connected knowledge. Edges auto-cleanup on forget/merge.
- **Reinforcement scoring**: Recall ranking blends cosine similarity with three reinforcement signals — **frequency** (log-scaled access count, up to 15% boost), **importance** (explicit 1-5 rating, up to 20% boost), and **recency** (exponential decay from last access, up to 10% boost). Cosine similarity still dominates; reinforcement fine-tunes ordering among close matches.
- **Conflict detection**: `remember` checks for near-duplicates (cosine distance < 0.12 same-project, < 0.05 cross-scope). Blocks storage with a warning; use `force: true` to override.
- **Expiration**: Set `expires_in_days` for temporal context ("currently working on X"). Expired memories are filtered from recall automatically.
- **Episodic memory**: Opt-in session grouping via `begin_episode`/`end_episode`. Episodes are hub memories (topic: "episode") linked to member memories via `part_of` edges. Stale episodes auto-end after a 30-minute gap.
- **Task continuity**: `checkpoint` saves plan/progress/context state. `resume` restores it in a new session. Tasks persist across conversations.
- **Clustering**: `find_clusters` uses greedy cosine-distance clustering to find related memory groups. `consolidate` creates a summary, deprioritizes originals (importance -> 0), and links them with `summarized_by` edges. `organize` batch re-topics memories with automatic hub creation.
- **Cross-project linking**: `remember` auto-detects mentions of other project names in content and creates `relates_to` edges to those projects' hub memories.
- **Hooks**: Optional `memory-hooks` binary for Claude Code hooks integration — auto-injects recalled context before each message (`advise`), blocks session end to capture insights when significant work is detected (`stop`), and triggers maintenance when memory operations accumulate.

## Configuration

| Environment variable | Default | Description |
|---|---|---|
| `CLAUDE_MEMORY_DB` | `~/.claude/memory.sqlite` | Database path |
| `CLAUDE_MEMORY_MODEL` | Bundled MiniLM-L6 | Custom embedding model path |

## Requirements

- macOS (CoreML for embeddings)
- Swift 6.2+
- Claude Code CLI
