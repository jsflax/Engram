#!/usr/bin/env python3
"""Read bounded, allowlisted Engram hook metadata for one Codex task."""
from __future__ import annotations

import argparse
from collections import deque
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import time
import uuid

MAX_LOG_BYTES = 262144
MAX_JSON_BYTES = 65536
MAX_LINE_BYTES = 8192
MAX_LINES = 512
MAX_RECORDS = 12
MAX_OUTPUT_BYTES = 49152
RUN_ID = re.compile(r"[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}")
UUID_TEXT = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
HASH = re.compile(r"(?:[0-9a-f]{20}|[0-9a-f]{64})")
TIMESTAMP = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})")
EVENTS = {"SessionStart", "UserPromptSubmit", "SubagentStart", "Stop", "PreCompact", "SessionEnd",
          "PreToolUse", "PostToolUse", "unknown",
          "queued", "rejected", "duplicate_event", "blocked", "deferred_short", "learner_finished", "worker_error",
          "reconciliation_required", "resumed", "resume_refused"}
STATUSES = {"emitted", "empty", "invalid", "timeout", "cancelled", "cleanup_timeout", "spawn_error",
            "protocol", "tool_error", "oversize", "guard", "disabled", "no_pins", "busy", "duplicate",
            "cooldown", "circuit", "policy_denied", "policy_unavailable", "running", "succeeded", "failed",
            "enrolled_frontier", "no_visible_content", "batch_limit", "blocked", "deferred",
            "enrolled", "observed", "queued", "not_queued", "rejected", "tool_not_agent",
            "cleaned", "already_clean", "nudge_disabled", "nudge", "counted",
            "success_ignored", "unclassified_ignored", "reconciliation_required", "backoff"}
OUTCOMES = {"stored", "no_new_memories", "failed"}
WRITE_TOOLS = {"remember", "update", "connect", "merge", "consolidate", "organize"}
# Exact codes emitted by the bundled admission/runner source. Never accept a
# prefix or arbitrary exception text: reasons may otherwise contain private data.
REASONS = {"admission_session_not_enrolled", "admission_project_mismatch",
           "admission_inactive", "admission_unqualified_gui_metadata",
           "admission_inherited_session", "admission_state_dir_mismatch",
           "admission_frontier_anchor_changed", "admission_transcript_identity_changed",
           "admission_unavailable_or_invalid", "admission_durable_binding_changed",
           "admission_cursor_missing_or_changed", "admission_request_binding_changed",
           "admission_expected_binding_changed"}
REASONS |= {"queued", "enqueue_refused", "first_observed_frontier", "frontier_preserved",
            "successful_or_unverified_write", "write_status_unknown", "reconciliation_required",
            "session_end_cleanup_only", "learner_recursion_guard", "unavailable_or_invalid",
            "hook_input_invalid", "hook_input_too_large", "event_not_supported", "event_not_stop",
            "routes_inactive", "route_inactive", "session_not_routed", "session_not_supported",
            "project_mismatch", "agent_session_mismatch", "hook_session_mismatch",
            "admission_digest_changed", "admission_route_mismatch", "routes_schema_invalid",
            "routes_path_invalid", "routes_too_large", "routes_membership_invalid",
            "routes_directory_not_private", "route_schema_invalid", "route_binding_invalid",
            "route_digest_invalid", "route_roots_not_distinct", "state_directory_not_private"}
REASONS |= {"unverified_completion", "timeout", "output_limit", "output_line_limit",
            "tool_limit", "unexpected_tool", "admission_interrupted_processing",
            "admission_processing_changed", "admission_missing_durable_record",
            "admission_incomplete_durable_record", "admission_cursor_before_frontier",
            "admission_cursor_binding_changed", "admission_cursor_changed_while_waiting"}
REASONS |= {"resume_missing_request_or_state", "resume_worker_active", "resume_request_or_state_changed",
            "resume_request_not_safely_paused", "resume_backoff", "resume_transcript_identity_changed",
            "resume_transcript_truncated"}
REASONS |= {"admission_" + value for value in {
    "enrollment_activation_changed", "enrollment_origin_changed", "future_cutoff",
    "initial_metadata_required", "invalid_capture_time", "invalid_enrollment_schema",
    "invalid_host_policy_schema", "invalid_origin_time", "invalid_rollout_filename",
    "invalid_rollout_layout", "learner_transcript", "manual_compaction_not_enabled",
    "metadata_agent_mismatch", "metadata_session_mismatch", "missing_or_invalid_turn",
    "session_or_project_mismatch", "state_directory_not_private", "state_directory_symlink",
    "state_file_symlink", "transcript_outside_sessions", "unknown_inherited_boundary",
    "unowned_existing_state", "unqualified_event", "unqualified_source", "unqualified_version",
    "unsupported_policy", "legacy_migration_required", "migration_held",
    "directory_identity_changed", "invalid_transcript_binding", "invalid_initial_metadata_size",
    "initial_metadata_changed", "invalid_legacy_event_identity"}}
REASONS |= {"admission_identity_" + value for value in {
    "abi_unsupported", "api_unavailable", "attributes_malformed", "attributes_unavailable",
    "attributes_unsupported", "fd_invalid", "file_type_unsupported", "filesystem_changed",
    "filesystem_malformed", "filesystem_unavailable", "filesystem_unsupported", "inode_invalid",
    "invalid", "mount_invalid", "persistence_unsupported", "platform_unsupported", "root_changed",
    "root_mismatch", "scheme_unsupported", "target_changed", "unavailable", "uuid_invalid", "volume_changed"}}
FAILURE_PHASES = {"arguments", "config", "state_setup", "input", "payload", "policy",
                  "state_lock", "state_load", "state_reserve", "spawn", "mcp_initialize",
                  "mcp_recall", "mcp_graph", "parse_recall", "parse_graph", "render",
                  "cleanup", "state_commit"}
ERROR_KINDS = {"classified", "json_decode", "unicode", "recursion", "io", "missing_key",
               "type", "overflow", "value", "other"}
IDENTITY_STATUSES = {"ok", "missing", "unreadable", "not_regular", "too_large",
                     "path_unavailable", "source_path_unavailable", "changed_during_read",
                     "hash_failed", "invalid_manifest"}
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:\+codex\.[0-9]{14})?")


def valid_uuid(value):
    return isinstance(value, str) and UUID_TEXT.fullmatch(value) is not None


def task_matches(record, sid):
    return isinstance(record, dict) and any(
        valid_uuid(record.get(key)) and record[key].lower() == sid
        for key in ("session_id", "hook_session_id"))


class ReadFailure(Exception):
    pass


def directory_status(path):
    """Distinguish absent state from unsafe state without following symlinks."""
    directory = None
    try:
        directory = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
        for part in path.parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK,
                            dir_fd=directory)
            os.close(directory)
            directory = child
        return "ok" if os.fstat(directory).st_uid == os.getuid() else "unavailable"
    except FileNotFoundError:
        return "missing"
    except (OSError, ReadFailure, ValueError):
        return "unavailable"
    finally:
        if directory is not None:
            os.close(directory)


def state_root(home):
    modern = home / "engram"
    status = directory_status(modern)
    if status == "ok":
        return modern, {"selection": "modern_host", "relative_path": "engram"}
    if status == "missing":
        return home / "engram-gui-hooks", {"selection": "legacy_fallback",
                                           "relative_path": "engram-gui-hooks"}
    return None, {"selection": "unavailable", "read_status": status}


def learner_root(root, sid):
    """Select only this task's fixed root; an unsafe root never falls back."""
    candidate = root / "learners" / sid
    directory = None
    try:
        directory = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
        for part in candidate.parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK,
                            dir_fd=directory)
            os.close(directory)
            directory = child
        if os.fstat(directory).st_uid != os.getuid():
            raise ReadFailure("unsafe_directory")
        return candidate, {"selection": "per_task", "relative_path": "learners/" + sid,
                           "activation_evidence": "not_checked"}
    except FileNotFoundError:
        return root / "learner", {"selection": "pilot_fallback", "relative_path": "learner",
                                   "activation_evidence": "not_checked"}
    except (OSError, ReadFailure, ValueError):
        return None, {"selection": "unavailable", "activation_evidence": "not_checked"}
    finally:
        if directory is not None:
            os.close(directory)


def open_regular(path):
    """Open each component without following symlinks, including parent dirs."""
    path = Path(path)
    if not path.is_absolute() or any(part in (".", "..") for part in path.parts):
        raise ReadFailure("unsafe_path")
    directory = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK,
                            dir_fd=directory)
            os.close(directory)
            directory = child
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            os.close(fd)
            raise ReadFailure("unsafe_file")
        return fd, info
    finally:
        os.close(directory)


def read_bounded(path, limit, tail=False):
    try:
        fd, info = open_regular(path)
        with os.fdopen(fd, "rb") as stream:
            if info.st_size > limit and not tail:
                return None, {"read_status": "oversize", "file_size_bytes": info.st_size}
            start = max(0, info.st_size - limit) if tail else 0
            stream.seek(start)
            data = stream.read(limit)
        meta = {"read_status": "ok", "file_size_bytes": info.st_size,
                "bytes_read": len(data), "mtime_ns": info.st_mtime_ns,
                "tail_truncated": bool(start)}
        if start:
            data = data.partition(b"\n")[2]  # Never parse a partial first record.
        return data, meta
    except FileNotFoundError:
        return None, {"read_status": "missing"}
    except (OSError, ReadFailure, ValueError):
        return None, {"read_status": "unavailable"}


def read_json(path):
    data, meta = read_bounded(path, MAX_JSON_BYTES)
    if data is None:
        return None, meta
    try:
        value = json.loads(data)
        if not isinstance(value, dict):
            raise ValueError
        return value, meta
    except (ValueError, UnicodeError, RecursionError):
        return None, {**meta, "read_status": "invalid_json"}


def read_log(path, matches):
    data, meta = read_bounded(path, MAX_LOG_BYTES, tail=True)
    found = deque(maxlen=MAX_RECORDS)
    if data is None:
        return list(found), meta
    lines = data.splitlines()
    meta.update(line_limit_reached=len(lines) > MAX_LINES, invalid_records=0, matching_records=0)
    for line in lines[-MAX_LINES:]:
        try:
            if len(line) > MAX_LINE_BYTES:
                raise ValueError
            record = json.loads(line)
            if not isinstance(record, dict):
                raise ValueError
            if matches(record):
                meta["matching_records"] += 1
                found.append(record)
        except (ValueError, UnicodeError, RecursionError):
            meta["invalid_records"] += 1
    return list(found), meta


def runtime_identity(value):
    """Return observed hashes and strict enums, never paths or arbitrary strings."""
    if not isinstance(value, dict):
        return {}
    out = {}
    if type(value.get("schema_version")) is int and value["schema_version"] == 1:
        out["schema_version"] = 1
    if value.get("evidence") == "observed_package_files":
        out["evidence"] = "observed_package_files"
    if isinstance(value.get("status"), str) and value["status"] in {
            "complete", "incomplete", "identity_unavailable"}:
        out["status"] = value["status"]

    def observed_file(record):
        result = {}
        if isinstance(record, dict):
            if isinstance(record.get("status"), str) and record["status"] in IDENTITY_STATUSES:
                result["status"] = record["status"]
            digest = record.get("sha256")
            if isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest):
                result["sha256"] = digest
        return result

    package = value.get("package")
    if isinstance(package, dict):
        out["package"] = observed_file(package)
        version = package.get("version")
        if isinstance(version, str) and len(version) <= 80 and VERSION.fullmatch(version):
            out["package"]["version"] = version
        if isinstance(package.get("manifest"), dict):
            out["package"]["manifest"] = observed_file(package["manifest"])
    sources = value.get("sources")
    if isinstance(sources, dict):
        out["sources"] = {key: observed_file(sources[key]) for key in
                          ("router", "runner", "template", "admission", "host_admission", "file_identity")
                          if isinstance(sources.get(key), dict)}
    return out


def metadata(record):
    """Only typed IDs, digests, enums, counts, and timestamps may leave here."""
    if not isinstance(record, dict):
        return {}
    out = {}
    for key in ("session_id", "hook_session_id", "invocation_id", "activation_id"):
        if valid_uuid(record.get(key)):
            out[key] = record[key].lower()
    for key in ("session", "agent", "turn", "source", "tool", "context_sha256", "state_sha256",
                "last_excerpt_sha256", "policy_sha256", "frontier_anchor_sha256", "initial_meta_sha256"):
        value = record.get(key)
        if isinstance(value, str) and HASH.fullmatch(value):
            out[key] = value
    for key in ("request_id", "processing", "paused_request_id"):
        value = record.get(key)
        if isinstance(value, str) and re.fullmatch(r"[0-9a-f]{32}", value):
            out[key] = value
    for key in ("last_run", "run_id"):
        if isinstance(record.get(key), str) and RUN_ID.fullmatch(record[key]):
            out[key] = record[key]
    for key in ("event", "hook_event"):
        if isinstance(record.get(key), str) and record[key] in EVENTS:
            out[key] = record[key]
    for key in ("status", "pause_reason"):
        if isinstance(record.get(key), str) and record[key] in STATUSES:
            out[key] = record[key]
    if isinstance(record.get("previous_pause_reason"), str) and record["previous_pause_reason"] in {
            "failed", "backoff", "blocked", "reconciliation_required", "batch_limit"}:
        out["previous_pause_reason"] = record["previous_pause_reason"]
    stable = record.get("identity")
    if (isinstance(stable, dict) and stable.get("scheme") == "macos_volume_uuid_inode_v1"
            and valid_uuid(stable.get("volume_uuid"))
            and type(stable.get("inode")) is int and 0 < stable["inode"] < 2 ** 64):
        out["identity"] = {"scheme": stable["scheme"], "volume_uuid": stable["volume_uuid"],
                           "inode": stable["inode"]}
    if record.get("mode") in {"host_sessions_v1", "host_sessions_v2"}:
        out["mode"] = record["mode"]
    if record.get("kind") == "identity_migration_hold":
        out["kind"] = record["kind"]
        if isinstance(record.get("plan_sha256"), str) and re.fullmatch(r"[0-9a-f]{64}", record["plan_sha256"]):
            out["plan_sha256"] = record["plan_sha256"]
    if isinstance(record.get("reason"), str) and record["reason"] in REASONS:
        out["reason"] = record["reason"]
    for key, allowed in (("failure_phase", FAILURE_PHASES), ("error_kind", ERROR_KINDS)):
        if isinstance(record.get(key), str) and record[key] in allowed:
            out[key] = record[key]
    for key, allowed in (("failure_kind", {"mcp_error", "nonzero_exit", "success", "unknown"}),
                         ("project_filter", {"exact_and_global", "semantic_relevance"}),
                         ("trigger", {"auto", "manual"}),
                         ("phase", {"input", "selection", "admission", "enrollment", "enqueue", "cleanup"})):
        if isinstance(record.get(key), str) and record[key] in allowed:
            out[key] = record[key]
    if isinstance(record.get("outcome"), str) and record["outcome"] in OUTCOMES:
        out["outcome"] = record["outcome"]
    if isinstance(record.get("id_verification"), str) and record["id_verification"] in {"requested_uuid_match", "text_unverified"}:
        out["id_verification"] = record["id_verification"]
    for key in ("time", "at", "requested_at", "updated_at", "started_at", "ended_at", "last_success_at", "captured_at", "cutoff"):
        if isinstance(record.get(key), str) and TIMESTAMP.fullmatch(record[key]):
            out[key] = record[key]
    for key in ("offset", "end_offset", "frontier_offset", "size_bytes", "context_chars", "elapsed_ms", "tool_calls",
                "write_calls", "tool_errors", "chars"):
        if type(record.get(key)) is int and 0 <= record[key] <= 2**63 - 1:
            out[key] = record[key]
    if type(record.get("returncode")) is int and -128 <= record["returncode"] <= 2**63 - 1:
        out["returncode"] = record["returncode"]
    if type(record.get("retry_after")) in (int, float) and 0 <= record["retry_after"] <= 2**53:
        out["retry_after"] = record["retry_after"]
    if "processing" in record:
        out["processing_present"] = record["processing"] is not None
    if type(record.get("writes")) is int and 0 <= record["writes"] <= 100:
        out["writes"] = record["writes"]
    for key in ("provider_error", "unexpected_tool", "turn_completed", "enabled"):
        if type(record.get(key)) is bool:
            out[key] = record[key]
    if isinstance(record.get("memory_ids"), list):
        out["memory_ids"] = [v.lower() for v in record["memory_ids"][:20] if valid_uuid(v)]
    if isinstance(record.get("writes"), list):
        out["writes"] = [{"tool": v["tool"], "memory_ids": [i.lower() for i in v.get("memory_ids", [])[:20] if valid_uuid(i)]}
                         for v in record["writes"][:5]
                         if isinstance(v, dict) and isinstance(v.get("tool"), str) and v["tool"] in WRITE_TOOLS
                         and isinstance(v.get("memory_ids", []), list)]
    if isinstance(record.get("runtime_identity"), dict):
        out["runtime_identity"] = runtime_identity(record["runtime_identity"])
    gate = record.get("reconciliation_required")
    # Field presence is a hold, including malformed empty/null/false values.
    # Sanitization must never erase the only evidence that replay is unsafe.
    if "reconciliation_required" in record:
        view = {}
        if isinstance(gate, dict) and isinstance(gate.get("run_id"), str) and RUN_ID.fullmatch(gate["run_id"]):
            view["run_id"] = gate["run_id"]
        if isinstance(gate, dict) and isinstance(gate.get("reason"), str) and gate["reason"] in {
                "successful_or_unverified_write", "write_status_unknown"}:
            view["reason"] = gate["reason"]
        if isinstance(gate, dict) and isinstance(gate.get("memory_ids"), list):
            view["memory_ids"] = [v.lower() for v in gate["memory_ids"][:20] if valid_uuid(v)]
        out["reconciliation_required"] = view
    return out


def policy_view(path):
    value, read = read_json(path)
    out = {"read": read}
    if value is not None:
        out["metadata"] = {k: v for k, v in metadata(value).items()
                           if k in {"enabled", "activation_id", "cutoff"}}
        if value.get("mode") in {"host_sessions_v1", "host_sessions_v2"}:
            out["metadata"]["mode"] = value["mode"]
        if type(value.get("schema_version")) is int and value["schema_version"] in {1, 2}:
            out["metadata"]["schema_version"] = value["schema_version"]
    return out


def scoped_json(path, sid, binding=False):
    value, read = read_json(path)
    if value is None:
        return None, {"read": read}
    identity = value.get("binding") if binding else value
    if not task_matches(identity, sid):
        return None, {"read": {**read, "read_status": "session_mismatch"}}
    out = {"read": read, "metadata": metadata(value)}
    if binding:
        out["binding"] = metadata(identity)
    # These fields influence whether recovery is safe. Preserve invalidity as
    # bounded field names rather than silently dropping it with private values.
    invalid = []
    role = path.parent.name
    if role == "sessions":
        if "offset" not in out["metadata"]:
            invalid.append("offset")
        if "status" in value and "status" not in out["metadata"]:
            invalid.append("status")
        if "retry_after" in value and "retry_after" not in out["metadata"]:
            invalid.append("retry_after")
        if "reconciliation_required" in value:
            gate = value["reconciliation_required"]
            if (not isinstance(gate, dict) or not isinstance(gate.get("reason"), str) or gate["reason"] not in
                    {"successful_or_unverified_write", "write_status_unknown"}):
                invalid.append("reconciliation_required")
    elif role == "admissions":
        if "processing" not in value:
            invalid.append("processing")
        if not isinstance(value.get("state_sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", value["state_sha256"]):
            invalid.append("state_sha256")
    elif role == "enrollments" and "frontier_offset" not in out["metadata"]:
        invalid.append("frontier_offset")
    elif role == "pending":
        if (value.get("request_id") and value.get("paused_request_id") == value["request_id"]
                and (not isinstance(value.get("pause_reason"), str) or value["pause_reason"] not in
                     {"failed", "backoff", "blocked", "reconciliation_required", "batch_limit"})):
            invalid.append("pause_reason")
    if invalid:
        out["invalid_fields"] = invalid
    return value, out


def linked_run(learner, linked, sid, *, provider_result=True):
    """Read one explicitly linked run. Never enumerate runs or open its audit/logs."""
    if linked is None:
        return {"read_status": "not_linked"}
    if not isinstance(linked, str) or not RUN_ID.fullmatch(linked):
        return {"read_status": "unsafe_link"}
    run, run_read = read_json(learner / "runs" / linked / "run.json")
    view = {"run_id": linked, "read": run_read}
    if run is not None and "session_id" in run and not task_matches(run, sid):
        view["read"] = {**run_read, "read_status": "session_mismatch"}
    elif run is not None:
        view["run_receipt"] = metadata(run)
        if provider_result:
            result, result_read = read_json(learner / "runs" / linked / "result.json")
            view["provider_result_read"] = result_read
            if result is not None:
                view["provider_result_claim"] = {k: v for k, v in metadata(result).items()
                                                  if k in {"outcome", "memory_ids"}}
        view["evidence"] = "linked_run_metadata_not_independent_memory_readback"
    return view


def backlog_view(state, pending):
    """Compare only the recorded snapshot; never stat or read the transcript."""
    unknown = {"state": "unknown", "current_transcript_size": "not_inspected"}
    if not isinstance(state, dict) or not isinstance(pending, dict):
        return unknown
    offset, size = state.get("offset"), pending.get("size_bytes")
    if any(type(v) is not int or not 0 <= v <= 2**63 - 1 for v in (offset, size)):
        return unknown
    # Snapshot subtraction is meaningful only for the same recorded file identity.
    if "identity" in state or "identity" in pending:
        left, right = metadata(state).get("identity"), metadata(pending).get("identity")
        if left is None or right is None:
            return unknown
    else:
        left, right = [state.get(k) for k in ("device", "inode")], [pending.get(k) for k in ("device", "inode")]
        if any(type(v) is not int or not 0 <= v < 2**64 for v in left + right):
            return unknown
    if left != right:
        return {**unknown, "state": "identity_mismatch"}
    if offset > size:
        return {**unknown, "state": "stale_snapshot"}
    return {**unknown, "state": "known_at_pending_snapshot", "bytes": size - offset}


def health_summary(learner, *, backlog=None, now=None):
    """Classify sanitized, bounded metadata. This is not a live worker probe.

    Consumers use these versioned enums instead of inferring health from an old
    success timestamp. Separate holds survive policy changes and stale pauses.
    """
    now = time.time() if now is None else now
    policy = learner.get("policy", {}).get("metadata", {})
    session = learner.get("session", {}).get("metadata", {})
    admission = learner.get("admission", {}).get("metadata", {})
    pending_view = learner.get("pending", {})
    pending = pending_view.get("metadata", {})
    migration = learner.get("migration_hold", {})
    gate = session.get("reconciliation_required", {})
    held = "reconciliation_required" in session or session.get("status") == "reconciliation_required"
    migration_held = migration.get("read", {}).get("read_status") == "ok"
    processing = admission.get("processing_present", False)
    pending_present = pending_view.get("read", {}).get("read_status") == "ok"
    pending_missing = pending_view.get("read", {}).get("read_status") == "missing"
    # A pause applies only to this request. A leftover pause from an older
    # request must not turn a queued replacement into a paused request.
    paused = bool(pending.get("request_id") and
                  pending.get("paused_request_id") == pending["request_id"])
    policy_state = "enabled" if policy.get("enabled") is True else "disabled" if policy.get("enabled") is False else "unknown"
    current = learner.get("held_run", {}) if held else learner.get("latest_run", {})
    receipt = current.get("run_receipt", {})
    holds = []
    if held:
        holds.append({"kind": "reconciliation_required", **gate})
    if migration_held:
        holds.append({"kind": "identity_migration_hold"})
    if processing:
        holds.append({"kind": "processing_marker", "liveness": "not_checked"})

    queue_state = "paused" if paused else "queued" if pending_present and pending.get("request_id") else "absent" if pending_missing else "unknown"
    progress = {"backlog": backlog or {"state": "unknown", "current_transcript_size": "not_inspected"},
                "last_completed_interval": {"evidence": "not_available_in_window"}}
    for key, source, field in (("cursor_offset", session, "offset"),
                               ("enrollment_frontier_offset", learner.get("enrollment", {}).get("metadata", {}), "frontier_offset"),
                               ("pending_snapshot_offset", pending, "size_bytes"),
                               ("last_success_timestamp_claim", session, "last_success_at")):
        if field in source:
            progress[key] = source[field]
    completed = learner.get("completed_run", {})
    completed_receipt = completed.get("run_receipt", {})
    if completed_receipt.get("status") == "succeeded":
        interval = {"evidence": "receipt_only", "run_id": completed["run_id"],
                    "start_offset": "not_recorded"}
        for key in ("end_offset", "ended_at"):
            if key in completed_receipt:
                interval[key] = completed_receipt[key]
        progress["last_completed_interval"] = interval

    acknowledgement = {"state": "unknown", "independent_persistence": "not_verified"}
    if type(receipt.get("write_calls")) is int:
        acknowledgement.update(state="acknowledged_in_run_receipt" if receipt["write_calls"] else "none_recorded",
                               acknowledged_write_count=receipt["write_calls"])
    if isinstance(receipt.get("writes"), list):
        acknowledgement["writes"] = receipt["writes"]
    provider = {"state": "completed_in_run_receipt" if receipt.get("turn_completed") is True
                          else "not_completed_in_run_receipt" if receipt.get("turn_completed") is False else "unknown"}
    if current.get("provider_result_claim"):
        provider["result_claim"] = current["provider_result_claim"]
    failure = {"class": "none_observed"}
    issues = []
    required = {"session", "admission"}
    if policy.get("mode") in {"host_sessions_v1", "host_sessions_v2"}:
        required.add("enrollment")
    for component in ("policy", "session", "admission", "enrollment", "pending", "migration_hold",
                      "latest_run", "held_run", "completed_run"):
        component_view = learner.get(component, {})
        read = component_view.get("read", component_view)
        status = read.get("read_status")
        if (status in {"unavailable", "invalid_json", "oversize", "session_mismatch", "unsafe_link"}
                or (component in required or component in {"latest_run", "held_run", "completed_run"})
                and status == "missing"):
            issues.append({"component": component, "status": status})
        if component_view.get("invalid_fields"):
            issues.append({"component": component, "status": "invalid_fields",
                           "fields": component_view["invalid_fields"]})
    if held:
        failure = {"class": "uncertain_or_partial_write", "reason": gate.get("reason", "reconciliation_required")}
    elif migration_held:
        failure = {"class": "identity_migration"}
    elif processing:
        failure = {"class": "processing_requires_inspection"}
    elif issues:
        failure = {"class": "metadata_unavailable"}
    elif progress["backlog"]["state"] == "identity_mismatch":
        failure = {"class": "transcript_identity_mismatch"}
    elif receipt.get("status") == "failed" or session.get("status") == "failed":
        reason = receipt.get("reason")
        failure = {"class": "timeout" if reason == "timeout" else "unverified_completion" if reason == "unverified_completion"
                   else "budget_limit" if reason in {"output_limit", "output_line_limit", "tool_limit"}
                   else "unexpected_tool" if reason == "unexpected_tool" else "run_failed"}
    if receipt.get("reason"):
        failure["run_reason"] = receipt["reason"]
    if type(receipt.get("tool_errors")) is int:
        failure.update(diagnostic_error_count=receipt["tool_errors"],
                       error_count_semantics="aggregate_provider_gateway_transport_not_unique_operations")

    headline, activity, action = "unknown", "unknown", "inspect_metadata"
    if held:
        headline, activity, action = "reconciliation_required", "held", "reconcile_held_run"
    elif migration_held:
        headline, activity, action = "identity_migration_hold", "held", "review_identity_migration"
    elif processing:
        headline, activity, action = "processing_unverified", "processing_unverified", "inspect_processing_attempt"
    elif failure["class"] == "transcript_identity_mismatch":
        headline, activity, action = "failed", "held", "inspect_failure"
    elif policy_state == "disabled":
        headline, activity, action = "disabled", "paused", "enable_policy"
    elif issues:
        headline, activity, action = "unknown", "unknown", "inspect_metadata"
    elif policy_state == "enabled":
        if session.get("retry_after", 0) > now:
            headline, activity, action = "backoff", "backoff", "wait_for_backoff_then_resume"
        elif paused:
            headline, activity, action = "batch_limit" if pending.get("pause_reason") == "batch_limit" else "paused", "paused", "resume_pending"
            if pending.get("pause_reason") in {"reconciliation_required", "blocked"}:
                action = "inspect_failure"
            elif pending.get("pause_reason") not in {"failed", "backoff", "batch_limit"}:
                headline, activity, action = "unknown", "unknown", "inspect_metadata"
        elif failure["class"] != "none_observed":
            headline, activity, action = "failed", "paused", "inspect_failure"
        elif queue_state == "queued":
            headline, activity, action = "queued", "queued", "none"
        elif pending_missing and session and admission.get("processing_present") is False:
            headline, activity, action = "idle", "idle", "none"
    activity_view = {"state": activity, "evidence": "bounded_metadata_not_worker_liveness"}
    if paused and "pause_reason" in pending:
        activity_view["pending_pause_reason"] = pending["pause_reason"]
    if "retry_after" in session:
        activity_view["retry_after"] = session["retry_after"]
    return {"schema_version": 1, "headline": headline,
            "evidence": "bounded_metadata_non_atomic_snapshot", "policy": {"state": policy_state,
                **({"mode": policy["mode"]} if "mode" in policy else {})},
            "activity": activity_view, "holds": holds, "progress": progress, "failure": failure,
            "metadata_issues": issues,
            "recovery": {"action": action, "automatic_replay_authorized": False},
            "outcomes": {"queue": {"state": queue_state}, "provider_completion": provider,
                         "native_acknowledgement": acknowledgement,
                         "independent_readback": {"state": "not_performed"}}}


def report(session_id=None, environ=None):
    env = os.environ if environ is None else environ
    sid = session_id or env.get("CODEX_THREAD_ID")
    if not sid:
        return {"status": "current_task_id_unavailable"}
    if not valid_uuid(sid):
        return {"status": "invalid_session_id"}
    sid = str(uuid.UUID(sid))
    home = Path(env.get("CODEX_HOME") or str(Path.home() / ".codex"))
    if not home.is_absolute() or ".." in home.parts:
        return {"status": "invalid_codex_home"}
    root, selection = state_root(home)
    if root is None:
        return {"status": "state_root_unavailable", "session_id": sid, "state_root": selection}
    session_hash = hashlib.sha256(sid.encode()).hexdigest()[:20]
    advice, advice_window = read_log(root / "recall-state/receipts.jsonl", lambda v: v.get("session") == session_hash)
    lifecycle, lifecycle_window = read_log(root / "lifecycle/receipts.jsonl", lambda v: v.get("session") == session_hash)
    router, router_window = read_log(root / "router-receipts.jsonl", lambda v: task_matches(v, sid))
    if selection["selection"] == "modern_host":
        learner, root_selection = root / "learner", {"selection": "shared_host", "relative_path": "learner",
                                                    "activation_evidence": "not_checked"}
    else:
        learner, root_selection = learner_root(root, sid)
    if learner is None:
        return {"status": "ok", "session_id": sid, "session_sha256_prefix": session_hash, "state_root": selection,
                "advice": {"window": advice_window, "receipts": [metadata(v) for v in advice],
                           "delivery_evidence": "receipt_only_not_model_delivery"},
                "learner": {"status": "state_root_unavailable", "state_root": root_selection,
                            "memory_readback": "not_performed", "health": health_summary({})}}
    events, event_window = read_log(learner / "events.jsonl", lambda v: task_matches(v, sid))
    state, state_view = scoped_json(learner / "sessions" / (sid + ".json"), sid)
    _, admission_view = scoped_json(learner / "admissions" / (sid + ".json"), sid, binding=True)
    pending, pending_view = scoped_json(learner / "pending" / (sid + ".json"), sid)
    _, enrollment_view = scoped_json(learner / "enrollments" / (sid + ".json"), sid)
    _, migration_view = scoped_json(learner / "migration-holds" / (sid + ".json"), sid)
    out = {"status": "ok", "session_id": sid, "session_sha256_prefix": session_hash, "state_root": selection,
           "advice": {"window": advice_window, "receipts": [metadata(v) for v in advice],
                      "delivery_evidence": "receipt_only_not_model_delivery"},
           "lifecycle": {"window": lifecycle_window, "receipts": [metadata(v) for v in lifecycle]},
           "router": {"window": router_window, "receipts": [metadata(v) for v in router],
                      "policy": policy_view(root / "learner-routes.json"),
                      "evidence": "routing_receipts_not_provider_completion"},
           "learner": {"state_root": root_selection, "window": event_window,
                       "policy": policy_view(learner / "admission.json"),
                       "events": [metadata(v) for v in events],
                       "session": state_view, "admission": admission_view, "enrollment": enrollment_view,
                       "pending": pending_view, "migration_hold": migration_view,
                       "memory_readback": "not_performed"}}
    # A run must be named by a matching event or this exact session's state.
    linked = next((v.get("run_id") for v in reversed(events) if "run_id" in v), None)
    if linked is None and state:
        linked = state.get("last_run")
    view = out["learner"]
    view["latest_run"] = linked_run(learner, linked, sid)
    safe_state = state_view.get("metadata", {})
    gate = safe_state.get("reconciliation_required", {})
    if "reconciliation_required" in safe_state or safe_state.get("status") == "reconciliation_required":
        held_id = gate.get("run_id") or safe_state.get("last_run")
        view["held_run"] = view["latest_run"] if held_id == linked else linked_run(learner, held_id, sid)
    # At most one additional successful run from this task's bounded event window.
    # Do not use last_success_at to manufacture a completed interval.
    completed_id = next((v.get("run_id") for v in reversed(events)
                         if v.get("event") == "learner_finished" and v.get("status") == "succeeded"
                         and isinstance(v.get("run_id"), str) and RUN_ID.fullmatch(v["run_id"])), None)
    if completed_id is None and safe_state.get("status") == "succeeded":
        completed_id = safe_state.get("last_run")
    if completed_id is not None:
        view["completed_run"] = view["latest_run"] if completed_id == linked else linked_run(learner, completed_id, sid, provider_result=False)
    view["health"] = health_summary(view, backlog=backlog_view(state, pending))
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session-id", help="Selected task UUID; defaults to CODEX_THREAD_ID")
    args = parser.parse_args(argv)
    try:
        value = report(args.session_id)
        output = json.dumps(value, ensure_ascii=True, indent=2)
        if len(output.encode()) > MAX_OUTPUT_BYTES:
            output = '{"status":"output_limit"}'
    except (OSError, ValueError, TypeError, KeyError, RecursionError):
        output = '{"status":"metadata_unavailable"}'
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
