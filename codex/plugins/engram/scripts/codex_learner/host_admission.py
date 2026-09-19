"""Automatic per-task frontiers for one explicitly enabled local Codex host.

The user's installation enables this host policy, not a task allowlist. A task's
first observed event records EOF and never backfills existing history. Subsequent
Stop and automatic PreCompact events can learn only appended visible messages.
Local metadata is provenance, not authentication against the account owner.
"""
from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import re

from . import admission
from .transcript import inspect_rollout

MODE = "host_sessions_v1"
OBSERVE_EVENTS = {"SessionStart", "UserPromptSubmit", "SubagentStart", "SubagentStop", "Stop", "PreCompact", "SessionEnd"}
LEARN_EVENTS = {"Stop", "SubagentStop", "PreCompact"}


def mode(root):
    raw, _ = admission._owned_bytes(root / "admission.json", private=True)
    return admission._json(raw).get("mode") == MODE


def policy(root):
    root = admission._canonical(str(root))
    info = admission._directory(root)
    admission._require(not info.st_mode & 0o077, "state_directory_not_private")
    raw, _ = admission._owned_bytes(root / "admission.json", private=True)
    value = admission._json(raw)
    admission._require(set(value) == {"schema_version", "mode", "enabled", "activation_id", "cutoff",
                                      "state_dir", "sessions_dir"}, "invalid_host_policy_schema")
    admission._require(type(value["schema_version"]) is int and value["schema_version"] == 1
                       and value["mode"] == MODE, "unsupported_policy")
    admission._require(value["enabled"] is True, "inactive")
    admission._uuid(value["activation_id"], 4)
    admission._require(admission._timestamp(value["cutoff"]) <= datetime.now(timezone.utc), "future_cutoff")
    admission._require(value["state_dir"] == str(root), "state_dir_mismatch")
    admission._bound_directory(value["sessions_dir"])
    return value, raw


def _origin(value, payload):
    sid = payload.get("session_id")
    path = admission._canonical(payload.get("transcript_path"))
    sessions = admission._bound_directory(value["sessions_dir"])
    admission._require(path.is_relative_to(sessions), "transcript_outside_sessions")
    parts = path.relative_to(sessions).parts
    admission._require(len(parts) == 4 and re.fullmatch(r"\d{4}/\d{2}/\d{2}", "/".join(parts[:3])),
                       "invalid_rollout_layout")
    raw, info = admission._owned_bytes(path, first_line=True)
    record = admission._json(raw)
    meta = record.get("payload")
    admission._require(record.get("type") == "session_meta" and isinstance(meta, dict), "initial_metadata_required")
    canonical_sid = meta.get("id", meta.get("session_id"))
    admission._uuid(canonical_sid, 7)
    admission._require(re.fullmatch(r"rollout-" + re.escape("-".join(parts[:3]))
                       + r"T\d{2}-\d{2}-\d{2}-" + re.escape(canonical_sid) + r"\.jsonl", parts[3]) is not None,
                       "invalid_rollout_filename")
    parsed = inspect_rollout(path)
    admission._require(parsed.session_id == canonical_sid and parsed.fork_boundary_known, "unknown_inherited_boundary")
    if sid != canonical_sid:
        source = parsed.source if isinstance(parsed.source, dict) else {}
        subagent = source.get("subagent")
        spawn = subagent.get("thread_spawn") if isinstance(subagent, dict) else None
        admission._require(isinstance(spawn, dict) and bool(spawn.get("parent_thread_id"))
                           and sid in {parsed.parent_session_id, parsed.hook_session_id}, "metadata_session_mismatch")
    admission._require(payload.get("agent_id") in (None, canonical_sid), "metadata_agent_mismatch")
    source = meta.get("source")
    admission._require(isinstance(source, (str, dict)) and bool(source), "unqualified_source")
    admission._require("engram-session-learner" not in str(source), "learner_transcript")
    version = meta.get("cli_version")
    admission._require(isinstance(version, str) and 0 < len(version) <= 128, "unqualified_version")
    project = admission._canonical(meta.get("cwd"))
    project_info = admission._directory(project)
    admission._require(payload.get("cwd") == str(project), "project_mismatch")
    created = admission._timestamp(meta.get("timestamp"))
    admission._require(created <= datetime.now(timezone.utc), "invalid_origin_time")
    return {"session_id": canonical_sid, "transcript_path": str(path), "device": info.st_dev,
            "inode": info.st_ino, "uid": info.st_uid, "initial_meta_bytes": len(raw),
            "initial_meta_sha256": hashlib.sha256(raw).hexdigest(), "source": source,
            "cli_version": version, "origin_metadata_timestamp": admission._utc(created),
            "project": {"path": str(project), "device": project_info.st_dev, "inode": project_info.st_ino}}


def _entry_path(root, sid):
    admission._uuid(sid, 7)
    parent = root / "enrollments"
    admission._require(not parent.is_symlink(), "state_directory_symlink")
    if parent.exists():
        admission._directory(parent)
    path = parent / (sid + ".json")
    admission._require(not path.is_symlink(), "state_file_symlink")
    return path


def _validate_entry(root, value, payload):
    origin = _origin(value, payload)
    raw, _ = admission._owned_bytes(_entry_path(root, origin["session_id"]), private=True)
    entry = admission._json(raw)
    admission._require(set(entry) == set(origin) | admission.FRONTIER_FIELDS | {"captured_at", "activation_id"},
                       "invalid_enrollment_schema")
    admission._require(entry["activation_id"] == value["activation_id"], "enrollment_activation_changed")
    admission._require(all(entry[key] == item for key, item in origin.items()), "enrollment_origin_changed")
    captured = admission._timestamp(entry["captured_at"])
    admission._require(admission._timestamp(value["cutoff"]) <= captured <= datetime.now(timezone.utc),
                       "invalid_capture_time")
    frontier = admission._frontier(origin, entry["frontier_offset"])
    admission._require(all(entry[key] == item for key, item in frontier.items()), "frontier_anchor_changed")
    return entry


def observe(root, payload):
    """Register a task at observed EOF; caller holds the root's enqueue lock.

    Returns (canonical task id, newly enrolled, fresh child eligible immediately). Existing entries are validated,
    never re-captured, even on SessionStart/resume/compaction or package upgrades.
    """
    value, _ = policy(root)
    event = payload.get("hook_event_name")
    admission._require(event in OBSERVE_EVENTS, "unqualified_event")
    if event == "PreCompact":
        admission._require(payload.get("trigger") == "auto", "manual_compaction_not_enabled")
    origin = _origin(value, payload)
    path = _entry_path(root, origin["session_id"])
    if path.exists():
        _validate_entry(root, value, payload)
        return origin["session_id"], False, False
    # Never adopt state from another admission or silently reset missing entries.
    for state_path in admission.state_paths(root, origin["session_id"]).values():
        admission._require(not state_path.exists(), "unowned_existing_state")
    parsed = inspect_rollout(origin["transcript_path"])
    # A newly spawned child can finish before any child-start hook exposes its
    # transcript. Its known inherited-history boundary keeps the initial visible
    # excerpt child-only, and the cutoff excludes pre-installation children.
    source = parsed.source if isinstance(parsed.source, dict) else {}
    subagent = source.get("subagent")
    spawn = subagent.get("thread_spawn") if isinstance(subagent, dict) else None
    fresh_child = (event == "SubagentStop" and isinstance(spawn, dict)
                   and bool(spawn.get("parent_thread_id")) and parsed.fork_boundary_known
                   and admission._timestamp(origin["origin_metadata_timestamp"]) >= admission._timestamp(value["cutoff"]))
    frontier = admission._frontier(origin, parsed.start_offset if fresh_child else None)
    entry = {**origin, **frontier, "captured_at": admission._utc(datetime.now(timezone.utc)),
             "activation_id": value["activation_id"]}
    # Import here to avoid a module cycle; publication is a metadata-only atomic write.
    from .runner import atomic_json
    atomic_json(path, entry)
    return origin["session_id"], True, fresh_child


def check(root, request):
    value, raw = policy(root)
    admission._require(request.get("event") in LEARN_EVENTS, "unqualified_event")
    if request["event"] == "Stop":
        admission._require(isinstance(request.get("turn_id"), str)
                           and re.fullmatch(r"[A-Za-z0-9_-]{1,100}", request["turn_id"]), "missing_or_invalid_turn")
    elif request["event"] == "PreCompact":
        admission._require(request.get("trigger") == "auto", "manual_compaction_not_enabled")
    payload = {"session_id": request.get("hook_session_id"), "transcript_path": request.get("transcript_path"),
               "cwd": request.get("hook_cwd"), "agent_id": request.get("session_id")}
    entry = _validate_entry(root, value, payload)
    admission._require(request.get("session_id") == entry["session_id"]
                       and request.get("cwd") == entry["project"]["path"], "session_or_project_mismatch")
    admission._require(all(request.get(key) == entry[key] for key in ("device", "inode")), "transcript_identity_changed")
    return {**entry, "cutoff": value["cutoff"], "policy_sha256": hashlib.sha256(raw).hexdigest(),
            "state_dir": str(root), "mode": MODE}


def enrollment_ids(root):
    parent = root / "enrollments"
    admission._require(not parent.is_symlink(), "state_directory_symlink")
    if not parent.exists():
        return []
    admission._directory(parent)
    result = []
    for path in parent.glob("*.json"):
        try:
            admission._uuid(path.stem, 7)
        except ValueError:
            continue
        result.append(path.stem)
    return sorted(result)
