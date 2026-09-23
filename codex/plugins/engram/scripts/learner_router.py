#!/usr/bin/env python3
"""Route Stop to one of three explicitly admitted task roots; never enroll."""
from __future__ import annotations

from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys

from codex_learner import admission, runner, runtime_identity, host_admission

SESSION_IDS = frozenset({
    "01a0a2fa-5cbd-77f0-8082-2ad6bb5c6fa8",  # Existing pilot.
    "01a07cab-4062-79e1-99ca-14802ffd7142",  # ROOT.
    "01a0a28e-734d-78e3-b8bb-2665002dc8e4",  # Director.
})
MAX_ROUTES_BYTES = 65536
MAX_RECEIPTS_BYTES = 131072


class RouterError(ValueError):
    pass


def require(condition, reason):
    if not condition:
        raise RouterError(reason)


def read_routes(path: Path) -> dict:
    require(path.is_absolute() and path.parent.resolve(strict=True) == path.parent,
            "routes_path_invalid")
    parent = path.parent.stat()
    require(stat.S_ISDIR(parent.st_mode) and parent.st_uid == os.getuid()
            and not parent.st_mode & 0o022, "routes_directory_not_private")
    raw, _ = admission._owned_bytes(path, private=True)
    require(len(raw) <= MAX_ROUTES_BYTES, "routes_too_large")
    policy = admission._json(raw)
    if policy.get("mode") in host_admission.MODES:
        require(set(policy) == {"schema_version", "mode", "enabled", "state_dir"}
                and type(policy["schema_version"]) is int
                and policy["schema_version"] == (2 if policy["mode"] == host_admission.MODE_V2 else 1),
                "routes_schema_invalid")
        require(policy["enabled"] is True, "routes_inactive")
        root = admission._canonical(policy["state_dir"])
        require(not admission._directory(root).st_mode & 0o077, "state_directory_not_private")
        return policy
    require(set(policy) == {"schema_version", "mode", "enabled", "routes"}
            and type(policy["schema_version"]) is int and policy["schema_version"] == 1
            and policy["mode"] == "explicit_stop_routes_v1", "routes_schema_invalid")
    require(policy["enabled"] is True, "routes_inactive")
    routes = policy["routes"]
    require(isinstance(routes, dict) and 1 <= len(routes) <= 3
            and set(routes) <= SESSION_IDS, "routes_membership_invalid")
    roots = set()
    for sid, route in routes.items():
        admission._uuid(sid, 7)
        require(isinstance(route, dict) and set(route) == {
            "enabled", "project", "state_dir", "admission_sha256"}
            and type(route["enabled"]) is bool, "route_schema_invalid")
        if not route["enabled"]:
            continue  # Candidate placeholders are inert until explicitly admitted.
        for field in ("project", "state_dir"):
            binding = route[field]
            require(isinstance(binding, dict) and set(binding) == {"path", "device", "inode"}
                    and isinstance(binding["path"], str) and Path(binding["path"]).is_absolute()
                    and all(type(binding[key]) is int and binding[key] >= 0 for key in ("device", "inode")),
                    "route_binding_invalid")
        require(isinstance(route["admission_sha256"], str)
                and re.fullmatch(r"[0-9a-f]{64}", route["admission_sha256"]), "route_digest_invalid")
        require(route["state_dir"]["path"] not in roots, "route_roots_not_distinct")
        roots.add(route["state_dir"]["path"])
    return policy


def receipt(path: Path, value: dict) -> None:
    """Bounded metadata receipt next to the private route configuration."""
    try:
        identity = runtime_identity.capture(__file__, runner, admission, host_admission)
        parent = admission._canonical(str(path.parent))
        info = admission._directory(parent)
        require(not info.st_mode & 0o022, "routes_directory_not_private")
        flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
        fd = os.open(parent / "router-receipts.jsonl", flags, 0o600)
        with os.fdopen(fd, "ab") as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                    and info.st_nlink == 1 and not info.st_mode & 0o022, "receipt_not_private_regular")
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            raw = (json.dumps({"schema_version": 1, "at": datetime.now(timezone.utc).isoformat(),
                               **value, "runtime_identity": identity}, sort_keys=True, separators=(",", ":")) + "\n").encode()
            if os.fstat(stream.fileno()).st_size + len(raw) > MAX_RECEIPTS_BYTES:
                os.ftruncate(stream.fileno(), 0)
            stream.write(raw)
            stream.flush()
    except (OSError, ValueError):
        # Receipt failure never enrolls, retries, or changes the hook decision.
        pass


def dispatch(path: Path, payload: dict, *, spawn: bool = True) -> bool:
    phase, sid = "routes", None
    try:
        policy = read_routes(path)
        if policy.get("mode") in host_admission.MODES:
            return dispatch_host(path, policy, payload, spawn=spawn)
        phase = "selection"
        require(isinstance(payload, dict) and payload.get("hook_event_name") == "Stop", "event_not_stop")
        candidate = payload.get("session_id")
        require(isinstance(candidate, str) and candidate in SESSION_IDS, "session_not_supported")
        sid = candidate
        require(payload.get("hook_session_id", sid) == sid, "hook_session_mismatch")
        require(payload.get("agent_id", sid) in (None, sid), "agent_session_mismatch")
        route = policy["routes"].get(sid)
        require(route is not None, "session_not_routed")
        require(route["enabled"], "route_inactive")
        require(payload.get("cwd") == route["project"]["path"], "project_mismatch")
        phase = "admission"
        project = admission._bound_directory(route["project"])
        root = admission._bound_directory(route["state_dir"])
        raw, _ = admission._owned_bytes(root / "admission.json", private=True)
        require(hashlib.sha256(raw).hexdigest() == route["admission_sha256"], "admission_digest_changed")
        # The unchanged validator binds initial origin metadata and frontier,
        # matching project, exact hook SID, and transcript inode before any queue.
        request = runner.validate_request(payload, root)
        binding = request["admission"]
        require(binding["policy_sha256"] == route["admission_sha256"], "admission_digest_changed")
        require(binding["project"] == route["project"] and binding["project"]["path"] == str(project)
                and binding["session_id"] == sid and binding["state_dir"] == str(root), "admission_route_mismatch")
        phase = "enqueue"
        queued = runner.enqueue(root, payload, spawn=spawn, expected_admission=binding)
        receipt(path, {"phase": phase, "status": "queued" if queued else "not_queued",
                       "reason": "queued" if queued else "enqueue_refused", "session_id": sid})
        return queued
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, RecursionError) as error:
        reason = str(error) if isinstance(error, RouterError) else "unavailable_or_invalid"
        if isinstance(error, ValueError) and re.fullmatch(r"admission_[a-z_]{1,80}", str(error)):
            reason = str(error)
        receipt(path, {"phase": phase, "status": "rejected", "reason": reason, "session_id": sid})
        return False


def dispatch_host(path: Path, policy: dict, payload: dict, *, spawn=True) -> bool:
    """One host queue; first observation enrolls, never learns historical text."""
    phase, sid = "selection", None
    event = payload.get("hook_event_name") if isinstance(payload, dict) else None
    try:
        require(isinstance(payload, dict) and event in host_admission.OBSERVE_EVENTS, "event_not_supported")
        require(not (os.environ.get(runner.GUARD) or os.environ.get("CLAUDE_MEMORY_LEARNER")
                     or os.environ.get("ENGRAM_LEARNER_ORCHESTRATED") == "1"
                     or payload.get("stop_hook_active")), "learner_recursion_guard")
        payload = dict(payload)
        if event in {"SubagentStart", "SubagentStop"} and payload.get("agent_transcript_path"):
            payload["transcript_path"] = payload["agent_transcript_path"]
        root = admission._canonical(policy["state_dir"])
        def route_guard():
            require(read_routes(path) == policy, "admission_route_mismatch")
            current, _ = host_admission.policy(root)
            require((policy["mode"], policy["schema_version"]) ==
                    (current["mode"], current["schema_version"]), "admission_route_mismatch")
        route_guard()
        if event == "SessionEnd":
            # Claude parity: cleanup belongs to lifecycle adapter, not a new learner.
            receipt(path, {"phase": "cleanup", "status": "observed", "reason": "session_end_cleanup_only",
                           "session_id": None, "hook_event": event})
            return False
        phase = "enrollment"
        with runner.lock_file(root / "enqueue.lock"):
            route_guard()
            sid, enrolled, fresh_child = host_admission.observe(root, payload)
        if (enrolled and not fresh_child) or event not in host_admission.LEARN_EVENTS:
            receipt(path, {"phase": phase, "status": "enrolled" if enrolled else "observed",
                           "reason": "first_observed_frontier" if enrolled else "frontier_preserved",
                           "session_id": sid, "hook_event": event})
            return False
        phase = "enqueue"
        queued = runner.enqueue(root, payload, spawn=spawn, route_guard=route_guard)
        receipt(path, {"phase": phase, "status": "queued" if queued else "not_queued",
                       "reason": "queued" if queued else "enqueue_refused", "session_id": sid,
                       "hook_event": event, "trigger": payload.get("trigger")})
        return queued
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, RecursionError) as error:
        reason = str(error) if isinstance(error, RouterError) else "unavailable_or_invalid"
        if isinstance(error, ValueError) and re.fullmatch(r"admission_[a-z_]{1,80}", str(error)):
            reason = str(error)
        receipt(path, {"phase": phase, "status": "rejected", "reason": reason, "session_id": sid,
                       "hook_event": event})
        return False


def main(argv=None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        print("{}")
        return 0
    path = Path(args[0])
    try:
        raw = sys.stdin.buffer.read(admission.MAX_BYTES + 1)
        require(len(raw) <= admission.MAX_BYTES, "hook_input_too_large")
        payload = admission._json(raw)
    except (OSError, ValueError, TypeError, RecursionError):
        receipt(path, {"phase": "input", "status": "rejected", "reason": "hook_input_invalid", "session_id": None})
    else:
        dispatch(path, payload)
    print("{}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
