---
name: hook-status
description: Check Engram advice, tool and lifecycle hooks, and session learner receipts for the current Codex task, including policy, queued work, completion, and recorded memory IDs.
---

# Engram Hook Status

Run the bundled [metadata reader](scripts/hook_status.py) with an available Python 3.11+ interpreter. It defaults to `CODEX_THREAD_ID` for the current task and respects `CODEX_HOME`. Pass `--session-id UUID` only when the user selected another task. If the current task ID is unavailable, obtain the intended UUID instead of inspecting unrelated tasks.

The script reads bounded receipt windows and only the selected task's enrollment, admission, cursor, pending, and explicitly linked run records. It reports the host policy's enabled flag. Use its JSON report; do not inspect raw prompts, transcripts, provider logs, memory bodies, or other queue entries to answer this status request.

Summarize advice, tool/lifecycle events, routing, policy, and learner completion separately. An `emitted` advice receipt records prepared context, not proof the model received or used it. Enrollment establishes a starting frontier; `queued` does not establish provider completion. A successful learner run or a provider's `stored` outcome is receipt evidence, not an independent memory readback. Report those distinctions and returned UUIDs/digests accurately. Missing files or no matching records mean no evidence in the inspected window, not a proven hook failure.

Receipt `attribution` distinguishes the selected actor from a shared hook session. A valid `agent` hash selects advice/lifecycle receipts for that concrete child even when `session` identifies the root. Rows for another recorded actor in the selected shared session appear only in `related_receipts`; they do not prove the selected task ran that hook. `session_match_agent_unspecified` preserves legacy or host receipts without actor identity, and cannot distinguish root from descendant activity. Invalid actor identity is separately scoped, never silently treated as the selected actor. Future lifecycle receipts retain a bounded hash when the host supplies `agent_id`; historical missing identities are not reconstructed.

Router and learner records use canonical `session_id` when present. A different or malformed canonical identity cannot fall back to a matching root `hook_session_id`. Legacy hook-session-only matches remain available with `hook_session_match_task_unspecified` attribution. Related router receipts come only from the same bounded log window and an explicit matching hook session; the reader does not discover child tasks or scan their queues. `window.matching_records` counts selected/legacy matches, while `related_matching_records` counts separately scoped rows. Each returned list remains bounded; neither a complete file window nor its last few returned rows establishes lifetime event coverage.

`reconciliation_required` means a failed run may already have written memory, or its write status is unknown. Report its linked run, reason, and recorded UUIDs; later events are held to prevent blind replay. The status reader does not clear this gate or establish whether an uncertain write persisted.

## Typed learner health

Use `learner.health` (schema version 1) as the summary. Its `headline` and `recovery.action` are exact codes for consumers, including the app UI. Policy and activity are separate: enabled policy does not establish that learning is progressing. Authoritative reconciliation, migration and processing markers take precedence over stale pending `batch_limit` pauses and old success timestamps. All concurrent holds remain in `holds`; resolving one does not resolve the others.

- `processing_unverified` means an admission processing marker exists. The reader does not probe worker liveness and cannot infer whether the process is active or interrupted.
- `admission_deferred` means the latest bounded worker admission receipt is recent and names this exact pending request. Report `worker_admission.reason`, its recorded load/limit or cooldown eligibility when present, `observed_at`, `age_seconds`, and candidate binding. These are facts recorded at the decision, not a live load or worker check. Session holds and backoff retain precedence.
- `worker_admission` describes shared worker admission. Other-session candidates, prior requests, recovery candidates, and legacy reason-only records do not establish deferral of this pending request. Legacy records are historical/advisory; records older than 600 seconds or with future timestamps cannot set `admission_deferred`. A later admitted receipt supersedes an earlier deferral even for another candidate, but does not prove this task ran or completed.
- Admission refusals preserve queued work. `next_attempt.policy=next_eligible_lifecycle_event` and `scheduled_at=null` mean there is no scheduled timer wake. A cooldown `eligible_after` is only an eligibility bound; once elapsed, a later eligible natural event is still needed. Do not interpret `queued`, enabled policy, or empty holds as proof that shared admission succeeded. Admission recovery actions do not authorize a forced event or replay.
- `progress.last_completed_interval` requires a linked successful run receipt. `last_success_timestamp_claim` is the retained session field and cannot establish the latest interval's completion. The reader checks at most one additional successful run linked in the bounded event window; absent evidence is not proof that no prior learning occurred.
- Backlog bytes describe only a recorded pending snapshot with matching file identity. `unknown`, `stale_snapshot` and `identity_mismatch` must remain distinct from zero backlog. Current transcript size is never inspected; `idle` means no selected pending request and no processing marker, not proof that current history is caught up.
- `outcomes` separates queue metadata, provider completion, native acknowledgements recorded by the runner, and independent readback. The reader performs no memory readback, even when a provider claims `stored` or a run receipt records acknowledged UUIDs. Recorded acknowledgement is not independent proof of current persistence.
- `failure.diagnostic_error_count` is the run's aggregate provider/gateway/transport count, not a count of unique failed operations or writes. `unverified_completion` is a source-defined failure reason and must not be presented as success.
- `recovery.action` describes the next supported investigation or recovery step; it does not authorize clearing gates or automatic replay. An explicit resume must preserve admission, identity, current backoff and reconciliation checks.

The aggregate is a bounded, non-atomic metadata snapshot. Missing, unsafe or malformed records cannot establish healthy learning. Preserve `metadata_issues` and the underlying receipt evidence when investigating a conflicting or changing snapshot. Missing required session, admission or host enrollment records and invalid recovery fields produce an unknown summary. Invalid fields are identified only by fixed field names; their contents are never returned. Any present reconciliation field remains a hold, including malformed empty, null or false values.

`migration_hold` is a separate filesystem-identity migration hold. Report it independently of a reconciliation gate and a paused pending request. `host_sessions_v2` uses persistent APFS volume UUID and inode identities; legacy v1 enrollments remain held until explicitly migrated. A migration hold or `admission_legacy_migration_required` does not authorize a retry, clearing a gate, changing the cursor, or adopting the current end of the transcript. Migration and activation are separately reviewed operations.

Report a returned learner `reason` code when present. The reader exposes only an exact allowlist of source-defined admission codes; it omits other reasons rather than displaying arbitrary error text. A missing reason therefore does not mean the event had no error.

Advice diagnostics and lifecycle failure kinds are exact enums, never exception text. Runtime identity exposes only package version, source hashes, and typed status; it identifies observed package files, not successful execution or saved memory.

The reader prefers `CODEX_HOME/engram` and its shared `learner` state. It falls back to legacy `engram-gui-hooks` only when the modern directory is absent, never when it is unsafe. Within legacy state, it selects `learners/<selected-task-id>` if present, otherwise the original `learner` root. An unsafe per-task root refuses fallback. Directory presence alone does not establish activation.

This is a read-only status check. Installation, trust changes, retries, provider calls, and memory writes are separate tasks.
