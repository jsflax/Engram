---
name: hook-status
description: Check Engram advice, tool and lifecycle hooks, and session learner receipts for the current Codex task, including policy, queued work, completion, and recorded memory IDs.
---

# Engram Hook Status

Run the bundled [metadata reader](scripts/hook_status.py) with an available Python 3.11+ interpreter. It defaults to `CODEX_THREAD_ID` for the current task and respects `CODEX_HOME`. Pass `--session-id UUID` only when the user selected another task. If the current task ID is unavailable, obtain the intended UUID instead of inspecting unrelated tasks.

The script reads bounded receipt windows and only the selected task's enrollment, admission, cursor, pending, and explicitly linked run records. It reports the host policy's enabled flag. Use its JSON report; do not inspect raw prompts, transcripts, provider logs, memory bodies, or other queue entries to answer this status request.

Summarize advice, tool/lifecycle events, routing, policy, and learner completion separately. An `emitted` advice receipt records prepared context, not proof the model received or used it. Enrollment establishes a starting frontier; `queued` does not establish provider completion. A successful learner run or a provider's `stored` outcome is receipt evidence, not an independent memory readback. Report those distinctions and returned UUIDs/digests accurately. Missing files or no matching records mean no evidence in the inspected window, not a proven hook failure.

`reconciliation_required` means a failed run may already have written memory, or its write status is unknown. Report its linked run, reason, and recorded UUIDs; later events are held to prevent blind replay. The status reader does not clear this gate or establish whether an uncertain write persisted.

`migration_hold` is a separate filesystem-identity migration hold. Report it independently of a reconciliation gate and a paused pending request. `host_sessions_v2` uses persistent APFS volume UUID and inode identities; legacy v1 enrollments remain held until explicitly migrated. A migration hold or `admission_legacy_migration_required` does not authorize a retry, clearing a gate, changing the cursor, or adopting the current end of the transcript. Migration and activation are separately reviewed operations.

Report a returned learner `reason` code when present. The reader exposes only an exact allowlist of source-defined admission codes; it omits other reasons rather than displaying arbitrary error text. A missing reason therefore does not mean the event had no error.

Advice diagnostics and lifecycle failure kinds are exact enums, never exception text. Runtime identity exposes only package version, source hashes, and typed status; it identifies observed package files, not successful execution or saved memory.

The reader prefers `CODEX_HOME/engram` and its shared `learner` state. It falls back to legacy `engram-gui-hooks` only when the modern directory is absent, never when it is unsafe. Within legacy state, it selects `learners/<selected-task-id>` if present, otherwise the original `learner` root. An unsafe per-task root refuses fallback. Directory presence alone does not establish activation.

This is a read-only status check. Installation, trust changes, retries, provider calls, and memory writes are separate tasks.
