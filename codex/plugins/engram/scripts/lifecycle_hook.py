#!/usr/bin/env python3
"""Portable, advisory Codex tool hooks and narrow session cleanup.

Usage: lifecycle_hook.py /absolute/lifecycle-config.json
Config: {schema_version: 1, state_dir: <private absolute directory>,
         recall_config: <absolute recall.json>, nudges: true}

PreCompact uses learner_router.py directly. This adapter never starts a learner,
writes memory, rewrites a tool, blocks a tool, or claims all failures observable.
Only metadata goes to receipts; tool input/output is never persisted here.
"""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import sys
import time
import uuid

import recall_hook as recall

EVENTS = {"PreToolUse", "PostToolUse", "SessionEnd"}
NUDGE = (
    "Engram session learning: preserve durable decisions and resolved tool failures "
    "clearly in this task so the automatic end-of-turn learner can review them. "
    "Answer the user's request first. Do not spawn a duplicate session learner."
)


def private_root(path):
    if not isinstance(path, str) or not os.path.isabs(path) or "\0" in path:
        raise recall.Failure("invalid")
    root = Path(path)
    if root.is_symlink():
        raise recall.Failure("invalid")
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = root.stat()
    if root.resolve(strict=True) != root or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise recall.Failure("invalid")
    if info.st_mode & 0o077:
        raise recall.Failure("invalid")
    return root


def load_config(path):
    if not path.is_absolute():
        raise recall.Failure("invalid")
    value = recall.read_json(path, recall.MAX_INPUT)
    if (not isinstance(value, dict)
            or set(value) != {"schema_version", "state_dir", "recall_config", "nudges"}
            or type(value["schema_version"]) is not int or value["schema_version"] != 1
            or type(value["nudges"]) is not bool
            or not isinstance(value["recall_config"], str)
            or not os.path.isabs(value["recall_config"]) or "\0" in value["recall_config"]):
        raise recall.Failure("invalid")
    return value


def failure_kind(payload):
    """Recognize explicit tool-result failures, never guess from arbitrary text.

    These structured forms are supported when a runtime emits them. The local
    Codex 0.154.0 source omits exit status from Bash hook payloads and gates out
    MCP error results, so full failure parity requires a host runtime change.
    Other tool-specific shapes remain unknown; raw stdout cannot prove failure.
    """
    response = payload.get("tool_response")
    if not isinstance(response, dict):
        return "unknown"
    if payload.get("tool_name", "").startswith("mcp"):
        if response.get("isError") is True:
            return "mcp_error"
        if response.get("isError") is False or isinstance(response.get("content"), list):
            return "success"
        return "unknown"
    code = response.get("exit_code")
    if payload.get("tool_name") in {"Bash", "exec_command", "write_stdin"} and type(code) is int:
        return "nonzero_exit" if code != 0 else "success"
    return "unknown"


def counter(root, session, tool_id, *, cleanup=False):
    """One lock, bounded per-session counters, replay dedupe and exact cleanup."""
    fd = recall.private_fd(root / "lifecycle.lock")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            state = recall.read_json(root / "state.json", recall.MAX_STATE)
        except FileNotFoundError:
            state = {}
        if not isinstance(state, dict):
            raise recall.Failure("invalid")
        sessions = state.get("sessions", {})
        if not isinstance(sessions, dict):
            raise recall.Failure("invalid")
        if cleanup:
            existed = session in sessions
            sessions.pop(session, None)
            recall.atomic_state(root, {"sessions": sessions})
            return "cleaned" if existed else "already_clean"
        now = time.time()
        # Drop expired/corrupt bookkeeping; no receipt or learner cursor is touched.
        sessions = {key: value for key, value in sessions.items()
                    if isinstance(key, str) and re.fullmatch(r"[0-9a-f]{20}", key)
                    and isinstance(value, dict) and type(value.get("at")) in (int, float)
                    and now - 86400 < value["at"] <= now}
        row = sessions.get(session, {"count": 0, "last": 0, "recent": [], "at": now})
        if (type(row.get("count")) is not int or not 0 <= row["count"] <= 1000000000
                or type(row.get("last")) is not int or not 0 <= row["last"] <= row["count"]
                or not isinstance(row.get("recent"), list)
                or any(not isinstance(v, str) or not re.fullmatch(r"[0-9a-f]{64}", v) for v in row["recent"])):
            raise recall.Failure("invalid")
        if tool_id in row["recent"]:
            return "duplicate"
        row["count"] += 1
        row["recent"] = [*row["recent"][-31:], tool_id]
        row["at"] = now
        threshold = 15 if row["last"] == 0 else 30
        nudge = row["count"] - row["last"] >= threshold
        if nudge:
            row["last"] = row["count"]
        sessions[session] = row
        # 20 sessions * bounded 32-call dedupe stays below MAX_STATE.
        sessions = dict(sorted(sessions.items(), key=lambda item: item[1]["at"])[-20:])
        recall.atomic_state(root, {"sessions": sessions})
        return "nudge" if nudge else "counted"
    finally:
        os.close(fd)


def run_recall(path, payload, start):
    audit = {"invocation_id": str(uuid.uuid4()), "event": "PreToolUse", "status": "invalid",
             "memory_ids": [], "context_chars": 0, "context_sha256": None, "_phase": "config"}
    root, output = None, {}
    try:
        config = recall.config_at(Path(path))
        root = private_root(config["state_dir"])
        output = recall.execute(config, payload, start, root, audit)
    except recall.Failure as error:
        audit.update(status=str(error), failure_phase=audit["_phase"], error_kind="classified")
    except (OSError, ValueError, TypeError, KeyError, OverflowError, RecursionError) as error:
        audit.update(status="invalid", failure_phase=audit["_phase"], error_kind=recall.error_kind(error))
    audit.pop("_phase", None)
    if output:
        context = output["hookSpecificOutput"]["additionalContext"]
        audit["context_sha256"] = hashlib.sha256(context.encode()).hexdigest()
    audit["elapsed_ms"] = round((time.monotonic() - start) * 1000)
    recall.receipt(root, audit)
    return output


def dispatch(config, payload, start, *, recall_call=run_recall):
    root = private_root(config["state_dir"])
    audit = {"invocation_id": str(uuid.uuid4()), "event": "unknown", "status": "invalid"}
    result = {}
    try:
        event = payload.get("hook_event_name")
        if event not in EVENTS:
            raise recall.Failure("invalid")
        audit["event"] = event
        sid = payload.get("session_id")
        if not isinstance(sid, str) or not 1 <= len(sid) <= 256:
            raise recall.Failure("invalid")
        session = hashlib.sha256(sid.encode()).hexdigest()[:20]
        audit["session"] = session
        if any(key in os.environ for key in recall.RECURSION_ENV):
            raise recall.Failure("guard")
        if event == "SessionEnd":
            audit["status"] = counter(root, session, "", cleanup=True)
        else:
            name, tool_id = payload.get("tool_name"), payload.get("tool_use_id")
            if (not isinstance(name, str) or not 1 <= len(name) <= 256
                    or not isinstance(tool_id, str) or not 1 <= len(tool_id) <= 256):
                raise recall.Failure("invalid")
            audit["tool"] = hashlib.sha256(name.encode()).hexdigest()[:20]
            if event == "PreToolUse":
                # Guard excluded agents before both recall and nudge bookkeeping.
                recall.agent_query(payload)
                result = recall_call(config["recall_config"], payload, start)
            else:
                audit["failure_kind"] = failure_kind(payload)
                if audit["failure_kind"] not in {"mcp_error", "nonzero_exit"}:
                    audit["status"] = "success_ignored" if audit["failure_kind"] == "success" else "unclassified_ignored"
                    return {}
            if not config["nudges"] or os.environ.get("ENGRAM_LEARNER_ORCHESTRATED") == "1":
                audit["status"] = "nudge_disabled"
            else:
                identity = hashlib.sha256(json.dumps([event, tool_id]).encode()).hexdigest()
                audit["status"] = counter(root, session, identity)
                if audit["status"] == "nudge":
                    output = result.setdefault("hookSpecificOutput", {"hookEventName": event, "additionalContext": ""})
                    output["additionalContext"] = (output["additionalContext"] + "\n\n" + NUDGE).strip()
        return result
    except recall.Failure as error:
        audit["status"] = str(error)
        return result
    except (OSError, ValueError, TypeError, KeyError, OverflowError, RecursionError):
        audit["status"] = "invalid"
        return result
    finally:
        audit["elapsed_ms"] = round((time.monotonic() - start) * 1000)
        recall.receipt(root, audit)


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    result, previous = {}, {}
    recall._cancelled = False
    try:
        for sig in (signal.SIGTERM, signal.SIGINT):
            previous[sig] = signal.signal(sig, recall.cancel_hook)
        start = time.monotonic()
        if len(args) == 1:
            config = load_config(Path(args[0]))
            payload = recall.read_input(start + 2)
            result = dispatch(config, payload, start)
    except (recall.Failure, OSError, ValueError, TypeError, KeyError, OverflowError, RecursionError):
        pass
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    if recall._cancelled:
        result = {}
    try:
        os.write(sys.stdout.fileno(), (json.dumps(result, separators=(",", ":")) + "\n").encode())
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
