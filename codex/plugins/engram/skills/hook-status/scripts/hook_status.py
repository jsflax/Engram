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
          "reconciliation_required"}
STATUSES = {"emitted", "empty", "invalid", "timeout", "cancelled", "cleanup_timeout", "spawn_error",
            "protocol", "tool_error", "oversize", "guard", "disabled", "no_pins", "busy", "duplicate",
            "cooldown", "circuit", "policy_denied", "policy_unavailable", "running", "succeeded", "failed",
            "enrolled_frontier", "no_visible_content", "batch_limit", "blocked", "deferred",
            "enrolled", "observed", "queued", "not_queued", "rejected", "tool_not_agent",
            "cleaned", "already_clean", "nudge_disabled", "nudge", "counted",
            "success_ignored", "unclassified_ignored", "reconciliation_required"}
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
REASONS |= {"admission_" + value for value in {
    "enrollment_activation_changed", "enrollment_origin_changed", "future_cutoff",
    "initial_metadata_required", "invalid_capture_time", "invalid_enrollment_schema",
    "invalid_host_policy_schema", "invalid_origin_time", "invalid_rollout_filename",
    "invalid_rollout_layout", "learner_transcript", "manual_compaction_not_enabled",
    "metadata_agent_mismatch", "metadata_session_mismatch", "missing_or_invalid_turn",
    "session_or_project_mismatch", "state_directory_not_private", "state_directory_symlink",
    "state_file_symlink", "transcript_outside_sessions", "unknown_inherited_boundary",
    "unowned_existing_state", "unqualified_event", "unqualified_source", "unqualified_version",
    "unsupported_policy"}}
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
                          ("router", "runner", "template", "admission", "host_admission")
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
    for key in ("offset", "end_offset", "frontier_offset", "context_chars", "elapsed_ms", "tool_calls",
                "write_calls", "tool_errors", "chars", "returncode"):
        if type(record.get(key)) is int and -128 <= record[key] <= 2**63 - 1:
            out[key] = record[key]
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
    if isinstance(gate, dict):
        view = {}
        if isinstance(gate.get("run_id"), str) and RUN_ID.fullmatch(gate["run_id"]):
            view["run_id"] = gate["run_id"]
        if isinstance(gate.get("reason"), str) and gate["reason"] in {
                "successful_or_unverified_write", "write_status_unknown"}:
            view["reason"] = gate["reason"]
        if isinstance(gate.get("memory_ids"), list):
            view["memory_ids"] = [v.lower() for v in gate["memory_ids"][:20] if valid_uuid(v)]
        out["reconciliation_required"] = view
    return out


def policy_view(path):
    value, read = read_json(path)
    out = {"read": read}
    if value is not None:
        out["metadata"] = {k: v for k, v in metadata(value).items()
                           if k in {"enabled", "activation_id", "cutoff"}}
        if value.get("mode") == "host_sessions_v1":
            out["metadata"]["mode"] = "host_sessions_v1"
        if type(value.get("schema_version")) is int and value["schema_version"] == 1:
            out["metadata"]["schema_version"] = 1
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
    return value, out


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
                            "memory_readback": "not_performed"}}
    events, event_window = read_log(learner / "events.jsonl", lambda v: task_matches(v, sid))
    state, state_view = scoped_json(learner / "sessions" / (sid + ".json"), sid)
    _, admission_view = scoped_json(learner / "admissions" / (sid + ".json"), sid, binding=True)
    _, pending_view = scoped_json(learner / "pending" / (sid + ".json"), sid)
    _, enrollment_view = scoped_json(learner / "enrollments" / (sid + ".json"), sid)
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
                       "pending": pending_view,
                       "memory_readback": "not_performed"}}
    # A run must be named by a matching event or this exact session's state.
    linked = next((v.get("run_id") for v in reversed(events) if "run_id" in v), None)
    if linked is None and state:
        linked = state.get("last_run")
    if linked is None:
        out["learner"]["latest_run"] = {"read_status": "not_linked"}
    elif not isinstance(linked, str) or not RUN_ID.fullmatch(linked):
        out["learner"]["latest_run"] = {"read_status": "unsafe_link"}
    else:
        run, run_read = read_json(learner / "runs" / linked / "run.json")
        view = {"run_id": linked, "read": run_read}
        if run is not None and "session_id" in run and not task_matches(run, sid):
            view["read"] = {**run_read, "read_status": "session_mismatch"}
        elif run is not None:
            view["run_receipt"] = metadata(run)
            result, result_read = read_json(learner / "runs" / linked / "result.json")
            view["provider_result_read"] = result_read
            if result is not None:
                view["provider_result_claim"] = {k: v for k, v in metadata(result).items() if k in {"outcome", "memory_ids"}}
            view["evidence"] = "linked_run_metadata_not_independent_memory_readback"
        out["learner"]["latest_run"] = view
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
