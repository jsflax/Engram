"""Explicit GUI frontier admission; no enrollment occurs inside hooks.

Local Codex origin metadata is trusted evidence, not authentication against
forgery by the same user. This module never enrolls sessions or writes state.
"""
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import uuid

MAX_BYTES = 1024 * 1024
LINEAGE_KEYS = (
    "forked_from_id", "parent_thread_id", "forked_from_ordinal_exclusive",
    "subagent_history_start_ordinal", "history_base",
)


def _require(condition, reason):
    if not condition:
        raise ValueError("admission_" + reason)


def _object(pairs):
    result = {}
    for key, value in pairs:
        _require(key not in result, "duplicate_json_key")
        result[key] = value
    return result


def _json(raw):
    def invalid_constant(value):
        raise ValueError("admission_nonfinite_json")
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=_object,
                           parse_constant=invalid_constant)
    except (UnicodeError, ValueError, RecursionError) as error:
        raise ValueError("admission_invalid_json") from error
    _require(isinstance(value, dict), "json_not_object")
    return value


def _canonical(value):
    _require(isinstance(value, str) and bool(value), "invalid_path")
    path = Path(value)
    _require(path.is_absolute() and str(path) == value
             and path.resolve(strict=True) == path, "noncanonical_path")
    return path


def _directory(path):
    info = path.stat(follow_symlinks=False)
    _require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid(),
             "directory_not_owned")
    return info


def _bound_directory(value):
    _require(isinstance(value, dict) and set(value) == {"path", "device", "inode"},
             "invalid_directory_binding")
    path = _canonical(value["path"])
    info = _directory(path)
    _require(all(type(value[key]) is int and value[key] >= 0 for key in ("device", "inode"))
             and (info.st_dev, info.st_ino) == (value["device"], value["inode"]),
             "directory_identity_changed")
    return path


def _owned_bytes(path, *, first_line=False, private=False):
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
    with os.fdopen(os.open(path, flags), "rb") as stream:
        info = os.fstat(stream.fileno())
        _require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid(),
                 "file_not_owned_regular")
        _require(not private or not info.st_mode & 0o022, "policy_writable_by_others")
        _require(first_line or info.st_size <= MAX_BYTES, "record_too_large")
        raw = stream.readline(MAX_BYTES + 1) if first_line else stream.read(MAX_BYTES + 1)
    _require(len(raw) <= MAX_BYTES, "record_too_large")
    _require(not first_line or raw.endswith(b"\n"), "initial_metadata_incomplete")
    return raw, info


def _uuid(value, version):
    _require(isinstance(value, str), "invalid_uuid")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as error:
        raise ValueError("admission_invalid_uuid") from error
    _require(str(parsed) == value and parsed.variant == uuid.RFC_4122
             and parsed.version == version, "unqualified_uuid")
    return parsed


def _timestamp(value):
    _require(isinstance(value, str), "timestamp_missing")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        _require(parsed.tzinfo is not None and parsed.utcoffset() is not None,
                 "timestamp_without_timezone")
        return parsed.astimezone(timezone.utc)
    except (ValueError, OverflowError) as error:
        raise ValueError("admission_invalid_timestamp") from error


def _utc(value):
    return value.isoformat().replace("+00:00", "Z")


GUI_VERSION = "0.154.0-alpha.6.2"
# Exact task-scoped origin exception proposed for separate review, not a version allowlist.
# Initial metadata remains unchanged on resume and is sealed into enrollment.
ORIGIN_VERSION_BY_SESSION = {
    "01a07cab-4062-79e1-99ca-14802ffd7142": "0.153.2",
}
ANCHOR_BYTES = 4096
ORIGIN_FIELDS = {"session_id", "transcript_path", "device", "inode", "uid",
                 "initial_meta_sha256", "initial_meta_bytes", "source", "cli_version",
                 "origin_id_timestamp", "origin_metadata_timestamp"}
FRONTIER_FIELDS = {"frontier_offset", "frontier_anchor_start", "frontier_anchor_sha256"}


def _validated(action):
    try:
        return action()
    except ValueError as error:
        if str(error).startswith("admission_"):
            raise
        raise ValueError("admission_unavailable_or_invalid") from error
    except (OSError, TypeError, KeyError, OverflowError, RuntimeError) as error:
        raise ValueError("admission_unavailable_or_invalid") from error


def _origin(project, sessions, path, sid):
    origin = _uuid(sid, 7)
    path = _canonical(str(path))
    _require(path.is_relative_to(sessions), "transcript_outside_sessions")
    parts = path.relative_to(sessions).parts
    _require(len(parts) == 4 and re.fullmatch(r"\d{4}/\d{2}/\d{2}", "/".join(parts[:3])),
             "invalid_rollout_layout")
    match = re.fullmatch(r"rollout-(" + re.escape("-".join(parts[:3]))
                         + r"T\d{2}-\d{2}-\d{2})-" + re.escape(sid) + r"\.jsonl", parts[3])
    _require(match is not None, "invalid_rollout_filename")
    try:
        datetime.strptime(match.group(1), "%Y-%m-%dT%H-%M-%S")
    except ValueError as error:
        raise ValueError("admission_invalid_rollout_date") from error
    raw, info = _owned_bytes(path, first_line=True)
    record = _json(raw)
    payload = record.get("payload")
    _require(record.get("type") == "session_meta" and isinstance(payload, dict), "initial_metadata_required")
    _require(payload.get("id") == sid and ("session_id" not in payload or payload["session_id"] == sid),
             "metadata_session_mismatch")
    _require(payload.get("cwd") == str(project), "metadata_project_mismatch")
    required_version = ORIGIN_VERSION_BY_SESSION.get(sid, GUI_VERSION)
    _require(payload.get("source") == "vscode" and payload.get("cli_version") == required_version
             and payload.get("history_mode") == "paginated", "unqualified_gui_metadata")
    _require(all(payload.get(key) is None for key in LINEAGE_KEYS), "inherited_session")
    created = _timestamp(payload.get("timestamp"))
    origin_time = datetime(1970, 1, 1, tzinfo=timezone.utc) + timedelta(milliseconds=origin.int >> 80)
    _require(origin_time <= created <= datetime.now(timezone.utc), "invalid_origin_time")
    return {"session_id": sid, "transcript_path": str(path), "device": info.st_dev,
            "inode": info.st_ino, "uid": info.st_uid, "initial_meta_bytes": len(raw),
            "initial_meta_sha256": hashlib.sha256(raw).hexdigest(), "source": payload["source"],
            "cli_version": payload["cli_version"], "origin_id_timestamp": _utc(origin_time),
            "origin_metadata_timestamp": _utc(created)}


def _frontier(origin, offset=None):
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
    with os.fdopen(os.open(origin["transcript_path"], flags), "rb") as stream:
        info = os.fstat(stream.fileno())
        _require(stat.S_ISREG(info.st_mode) and (info.st_dev, info.st_ino, info.st_uid)
                 == (origin["device"], origin["inode"], os.getuid()), "transcript_identity_changed")
        # Capture only the observed EOF. A partial tail is never rounded backwards.
        offset = info.st_size if offset is None else offset
        _require(type(offset) is int and origin["initial_meta_bytes"] <= offset <= info.st_size,
                 "frontier_truncated_or_invalid")
        start = max(0, offset - ANCHOR_BYTES)
        stream.seek(start)
        data = stream.read(offset - start)
        _require(len(data) == offset - start and data.endswith(b"\n"), "frontier_not_complete_line")
    return {"frontier_offset": offset, "frontier_anchor_start": start,
            "frontier_anchor_sha256": hashlib.sha256(data).hexdigest()}


def capture(project: dict, sessions_dir: dict, transcript_path: str, session_id: str) -> dict:
    """Read-only, explicitly invoked capture; installer owns publication and activation.

    Reads initial metadata and at most 4096 boundary bytes. Returns hashes only,
    never history text. This function is never called by check or the hook path.
    """
    def run():
        origin = _origin(_bound_directory(project), _bound_directory(sessions_dir), transcript_path, session_id)
        frontier = _frontier(origin)
        return {**origin, **frontier, "captured_at": _utc(datetime.now(timezone.utc))}
    return _validated(run)


def _policy(root):
    root = _canonical(str(root))
    _directory(root)
    raw, _ = _owned_bytes(root / "admission.json", private=True)
    policy = _json(raw)
    _require(policy.get("enabled") is True, "inactive")
    _require(set(policy) == {"schema_version", "mode", "enabled", "activation_id", "cutoff",
                            "state_dir", "project", "sessions_dir", "enrollments"}, "invalid_policy_schema")
    _require(type(policy["schema_version"]) is int and policy["schema_version"] == 1
             and policy["mode"] == "explicit_frontier_v1", "unsupported_policy")
    _uuid(policy["activation_id"], 4)
    cutoff = _timestamp(policy["cutoff"])
    _require(policy["state_dir"] == str(root), "state_dir_mismatch")
    project, sessions = _bound_directory(policy["project"]), _bound_directory(policy["sessions_dir"])
    enrolled = policy["enrollments"]
    _require(isinstance(enrolled, dict) and len(enrolled) == 1, "one_explicit_enrollment_required")
    sid, entry = next(iter(enrolled.items()))
    _require(isinstance(entry, dict) and set(entry) == ORIGIN_FIELDS | FRONTIER_FIELDS | {"captured_at"},
             "invalid_enrollment_schema")
    _require(all(type(entry[key]) is int and entry[key] >= 0 for key in
                 ("device", "inode", "uid", "initial_meta_bytes", "frontier_offset", "frontier_anchor_start")),
             "invalid_enrollment_numbers")
    actual = _origin(project, sessions, entry["transcript_path"], sid)
    _require(all(entry[key] == actual[key] for key in ORIGIN_FIELDS), "enrollment_origin_changed")
    captured = _timestamp(entry["captured_at"])
    _require(cutoff <= captured <= datetime.now(timezone.utc)
             and _timestamp(actual["origin_metadata_timestamp"]) <= captured, "invalid_capture_time")
    frontier = _frontier(actual, entry["frontier_offset"])
    _require(all(entry[key] == frontier[key] for key in FRONTIER_FIELDS), "frontier_anchor_changed")
    return policy, raw, entry


def check_activation(root: Path) -> dict:
    from . import host_admission
    if host_admission.mode(root):
        return _validated(lambda: host_admission.policy(root)[0])
    return _validated(lambda: _policy(root)[0])


def enrollment_ids(root: Path, policy: dict) -> list[str]:
    if policy.get("mode") == "host_sessions_v1":
        from .host_admission import enrollment_ids as host_ids
        return host_ids(root)
    return list(policy["enrollments"])


def check(root: Path, request: dict) -> dict:
    from . import host_admission
    if host_admission.mode(root):
        return _validated(lambda: host_admission.check(root, request))
    def run():
        _require(isinstance(request, dict) and request.get("event") == "Stop", "unqualified_event")
        _require(isinstance(request.get("turn_id"), str)
                 and re.fullmatch(r"[A-Za-z0-9_-]{1,100}", request["turn_id"]) is not None,
                 "missing_or_invalid_turn")
        policy, raw, entry = _policy(root)
        sid = request.get("session_id")
        _require(sid == entry["session_id"] and request.get("hook_session_id") == sid, "session_not_enrolled")
        _require(request.get("cwd") == policy["project"]["path"]
                 and request.get("hook_cwd") == policy["project"]["path"], "project_mismatch")
        _require(all(request.get(key) == entry[key] for key in ("transcript_path", "device", "inode"))
                 and all(type(request.get(key)) is int for key in ("device", "inode")), "transcript_identity_changed")
        return {**entry, "activation_id": policy["activation_id"], "cutoff": policy["cutoff"],
                "policy_sha256": hashlib.sha256(raw).hexdigest(), "project": dict(policy["project"]),
                "state_dir": policy["state_dir"], "mode": policy["mode"]}
    return _validated(run)


def state_paths(root: Path, sid: str) -> dict:
    """Reject symlink/special-file state paths before cursor/receipt adoption."""
    _uuid(sid, 7)
    result = {}
    for name in ("admissions", "sessions", "pending"):
        parent = root / name
        _require(not parent.is_symlink(), "state_directory_symlink")
        if parent.exists():
            _directory(parent)
        path = parent / (sid + ".json")
        _require(not path.is_symlink(), "state_file_symlink")
        if path.exists():
            info = path.stat(follow_symlinks=False)
            _require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid(), "state_not_owned_regular")
        result[name] = path
    return result
