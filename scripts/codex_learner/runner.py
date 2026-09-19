"""Native hooks enqueue work; one worker learns bounded incremental excerpts.

No memory database is opened here. All learning uses the installed Codex account
and the configured Engram MCP, with other integrations and shell access disabled.
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import tomllib
import uuid

from .transcript import inspect_rollout, read_excerpt

EVENTS = {"Stop", "PreCompact", "SessionEnd"}
GUARD = "ENGRAM_CODEX_LEARNER"
READ_TOOLS = {"recall", "graph", "list_topics", "stats", "timeline"}
WRITE_TOOLS = {"remember", "update", "connect"}
DEFAULTS = {"min_chars": 400, "max_chars": 24000, "max_scan_bytes": 8 * 1024 * 1024,
            "wall_seconds": 600, "max_tool_calls": 12, "max_writes": 5,
            "max_runs_per_worker": 4, "retry_seconds": 300}


def utc() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def private_dir(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)
    return path


def atomic_json(path: Path, value: object) -> None:
    private_dir(path.parent)
    temp = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        with temp.open("x", encoding="utf-8") as f:
            os.chmod(temp, 0o600)
            json.dump(value, f, ensure_ascii=False, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def load_json(path: Path, default: object = None):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return {} if default is None else default


def event_log(root: Path, event: str, **fields) -> None:
    private_dir(root)
    fd = os.open(root / "events.jsonl", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.write(fd, (json.dumps({"time": utc(), "event": event, **fields}) + "\n").encode())
    finally:
        os.close(fd)


@contextlib.contextmanager
def lock_file(path: Path, blocking: bool = True):
    private_dir(path.parent)
    f = path.open("a+")
    os.chmod(path, 0o600)
    acquired = False
    try:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
            acquired = True
        except BlockingIOError:
            pass
        yield acquired
    finally:
        if acquired:
            fcntl.flock(f, fcntl.LOCK_UN)
        f.close()


def settings(root: Path) -> dict:
    result = {**DEFAULTS, **load_json(root / "settings.json")}
    # Local configuration can lower budgets, not accidentally remove bounds.
    for key, low, high in (("min_chars", 0, 10000), ("max_chars", 1000, 48000),
                           ("max_scan_bytes", 4096, 32 * 1024 * 1024),
                           ("wall_seconds", 10, 900), ("max_tool_calls", 1, 20),
                           ("max_writes", 1, 5), ("max_runs_per_worker", 1, 8),
                           ("retry_seconds", 10, 3600)):
        result[key] = max(low, min(high, int(result[key])))
    return result


def codex_home() -> Path:
    return Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).expanduser().resolve()


def automatic_hooks_allowed() -> bool:
    """A configured Engram plugin replaces legacy automatic hooks, even paused.

    Unreadable/invalid policy declines automatic work. Explicit enqueue/retry
    remain operator actions; no pending work or cursor is adopted or removed.
    """
    path = codex_home() / "config.toml"
    try:
        if path.is_symlink():
            return False
        config = tomllib.loads(path.read_text())
    except FileNotFoundError:
        return True
    except (OSError, ValueError):
        return False
    plugins = config.get("plugins", {})
    return isinstance(plugins, dict) and not any(
        name.partition("@")[0] in {"engram", "engram-hooks"} for name in plugins)


def validate_request(payload: dict, root: Path) -> dict:
    event = payload.get("hook_event_name")
    if event not in EVENTS:
        raise ValueError("unsupported_event")
    sid = payload.get("session_id", "")
    if not isinstance(sid, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,100}", sid):
        raise ValueError("invalid_session_id")
    raw_path = payload.get("transcript_path")
    if not isinstance(raw_path, str) or not raw_path:
        raise ValueError("missing_transcript")
    path = Path(raw_path).expanduser().resolve(strict=True)
    st = path.stat()
    if not path.is_file() or st.st_uid != os.getuid():
        raise ValueError("transcript_not_owned_regular_file")
    meta = inspect_rollout(str(path))
    agent_id = payload.get("agent_id")
    if agent_id is not None and agent_id != meta.session_id:
        raise ValueError("transcript_session_mismatch")
    if meta.session_id != sid:
        # Native subagent hooks carry the parent/logical session ID while their
        # transcript belongs to the child. Bind to the child's canonical ID only
        # when its own metadata proves that relationship and an inherited-history
        # boundary. A manually forked root cannot use this exception.
        source = meta.source if isinstance(meta.source, dict) else {}
        subagent = source.get("subagent")
        spawn = subagent.get("thread_spawn") if isinstance(subagent, dict) else None
        parent = spawn.get("parent_thread_id") if isinstance(spawn, dict) else None
        aliases = {meta.parent_session_id, meta.hook_session_id}
        if (not isinstance(parent, str) or not parent or not meta.fork_boundary_known
                or sid not in aliases
                or not re.fullmatch(r"[A-Za-z0-9_-]{1,100}", meta.session_id)):
            raise ValueError("transcript_session_mismatch")
    if "engram-session-learner" in str(meta.source):
        raise ValueError("learner_transcript")
    return {"session_id": meta.session_id, "hook_session_id": sid,
            "transcript_path": str(path), "cwd": meta.cwd or payload.get("cwd"),
            "model": payload.get("model"), "event": event, "turn_id": payload.get("turn_id"),
            "requested_at": utc(), "size_bytes": st.st_size, "mtime_ns": st.st_mtime_ns,
            "device": st.st_dev, "inode": st.st_ino, "request_id": uuid.uuid4().hex}


def enqueue(root: Path, payload: dict, *, spawn: bool = True) -> bool:
    if os.environ.get(GUARD) or os.environ.get("CLAUDE_MEMORY_LEARNER"):
        return False
    if payload.get("stop_hook_active"):
        return False
    try:
        request = validate_request(payload, root)
    except (ValueError, OSError) as exc:
        supplied_id = payload.get("session_id")
        safe_id = supplied_id if isinstance(supplied_id, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,100}", supplied_id) else None
        event_log(root, "rejected", hook_session_id=safe_id, reason=str(exc)[:160])
        return False
    sid = request["session_id"]
    with lock_file(root / "enqueue.lock"):
        pending = root / "pending" / (sid + ".json")
        previous = load_json(pending)
        # A final flush wins over a redundant Stop for the same snapshot.
        if previous.get("size_bytes") == request["size_bytes"] and previous.get("event") in {"PreCompact", "SessionEnd"}:
            request["event"] = previous["event"]
        atomic_json(pending, request)
    event_log(root, "queued", session_id=sid, hook_event=request["event"], request_id=request["request_id"])
    if spawn:
        spawn_worker(root)
    return True


def spawn_worker(root: Path) -> None:
    entry = Path(__file__).resolve().parents[1] / "codex_learner.py"
    log = root / "worker.log"
    with log.open("ab") as out:
        os.chmod(log, 0o600)
        subprocess.Popen([sys.executable, str(entry), "worker", "--state-dir", str(root)],
                         stdin=subprocess.DEVNULL, stdout=out, stderr=out,
                         start_new_session=True, close_fds=True)


def toml_value(value) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, list):
        return "[" + ",".join(toml_value(x) for x in value) + "]"
    if isinstance(value, dict):
        return "{" + ",".join(json.dumps(k) + "=" + toml_value(v) for k, v in value.items() if v is not None) + "}"
    raise TypeError("unsupported TOML value")


def learner_command(root: Path, run_dir: Path, request: dict, config: dict) -> list[str]:
    home = codex_home()
    try:
        user_config = tomllib.loads((home / "config.toml").read_text())
    except FileNotFoundError:
        user_config = {}
    memory = user_config.get("mcp_servers", {}).get("memory")
    if not isinstance(memory, dict) or memory.get("enabled") is False:
        raise ValueError("memory_mcp_not_configured")
    allowed = READ_TOOLS | WRITE_TOOLS
    if memory.get("enabled_tools") is not None:
        allowed = allowed.intersection(memory["enabled_tools"])
    allowed = allowed.difference(memory.get("disabled_tools", []))
    if "recall" not in allowed or not (allowed & WRITE_TOOLS):
        raise ValueError("memory_mcp_policy_disallows_learning")
    # Do not inherit arbitrary servers, plugins, hooks, shell tools or project config.
    memory = {k: v for k, v in memory.items() if k in {
        "command", "args", "env", "env_vars", "cwd", "url", "http_headers",
        "env_http_headers", "bearer_token_env_var", "startup_timeout_sec", "tool_timeout_sec"}}
    if not memory.get("command") or memory.get("url"):
        raise ValueError("learner_requires_stdio_memory_mcp")
    transport_path = run_dir / "transport.json"
    atomic_json(transport_path, {"transport": memory, "audit_path": str(run_dir / "mcp-audit.jsonl"),
                               "provenance": "codex-session:" + request["session_id"],
                               "allowed_tools": sorted(allowed),
                               "max_tool_calls": config["max_tool_calls"], "max_writes": config["max_writes"]})
    memory = {"command": sys.executable, "args": [str(Path(__file__).with_name("memory_proxy.py")), str(transport_path)],
              "enabled": True, "required": True, "enabled_tools": sorted(allowed),
              "default_tools_approval_mode": "prompt",
              "tools": {tool: {"approval_mode": "approve"} for tool in sorted(allowed)},
              "startup_timeout_sec": memory.get("startup_timeout_sec", 30),
              "tool_timeout_sec": memory.get("tool_timeout_sec", 120)}
    binary = config.get("codex_bin") or shutil.which("codex")
    if not binary:
        candidate = Path.home() / ".local/bin/codex"
        if candidate.is_file():
            binary = str(candidate)
    if not binary:
        raise ValueError("codex_binary_not_found")
    argv = [binary, "exec", "--ignore-user-config", "--ephemeral", "--skip-git-repo-check",
            "--sandbox", "read-only", "--json", "--color", "never", "--cd", str(run_dir / "workspace"),
            "--output-schema", str(run_dir / "schema.json"),
            "--output-last-message", str(run_dir / "result.json")]
    model = request.get("model") or user_config.get("model")
    if model:
        argv += ["--model", model]
    effort = user_config.get("model_reasoning_effort")
    if effort:
        argv += ["-c", "model_reasoning_effort=" + toml_value(effort)]
    overrides = {"mcp_servers": {"memory": memory}, "approval_policy": "never",
                 "notify": [], "web_search": "disabled"}
    for key, value in overrides.items():
        argv += ["-c", key + "=" + toml_value(value)]
    for feature in ("hooks", "shell_tool", "plugins", "apps", "multi_agent", "computer_use",
                    "browser_use", "in_app_browser", "image_generation", "view_image", "goals"):
        argv += ["--disable", feature]
    return argv + ["-"]


RESULT_SCHEMA = {"type": "object", "additionalProperties": False,
                 "properties": {"outcome": {"type": "string", "enum": ["stored", "no_new_memories", "failed"]},
                                "summary": {"type": "string"},
                                "memory_ids": {"type": "array", "items": {"type": "string"}}},
                 "required": ["outcome", "summary", "memory_ids"]}


def observe_event(event: dict, observed: dict) -> None:
    kind = event.get("type")
    if kind in {"error", "turn.failed"}:
        observed["provider_error"] = True
    if kind == "turn.completed":
        observed["turn_completed"] = True
    if kind not in {"item.started", "item.completed"}:
        return
    item = event.get("item", {})
    if item.get("type") in {"command_execution", "file_change", "web_search", "collab_tool_call", "image_generation"}:
        observed["unexpected_tool"] = True
    if kind != "item.completed":
        return
    if item.get("type") != "mcp_tool_call":
        return
    key = item.get("id") or hashlib.sha256(json.dumps(item, sort_keys=True).encode()).hexdigest()
    if key in observed["seen"]:
        return
    observed["seen"].add(key)
    observed["tool_calls"] += 1
    server, tool = item.get("server"), item.get("tool")
    if server != "memory" or tool not in READ_TOOLS | WRITE_TOOLS:
        observed["unexpected_tool"] = True
        return
    result = item.get("result") or {}
    failed = item.get("status") != "completed" or bool(item.get("error")) or result.get("isError", False)
    if failed:
        observed["tool_errors"] += 1
        return
    if tool in WRITE_TOOLS:
        observed["write_calls"] += 1
        texts = " ".join(x.get("text", "") for x in result.get("content", []) if x.get("type") == "text")
        ids = re.findall(r"\b[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\b", texts)
        observed["writes"].append({"tool": tool, "memory_ids": sorted(set(ids))})


def audit_tools(path: Path) -> dict:
    """Independent MCP receipts, not the model's claim or provider event shape."""
    calls, results = {}, {}
    errors = 0
    try:
        for line in path.read_text().splitlines():
            entry = json.loads(line)
            key = str(entry["id"])
            if entry.get("event") == "tool_call":
                if key in calls or entry.get("tool") not in READ_TOOLS | WRITE_TOOLS:
                    errors += 1
                calls[key] = entry["tool"]
            elif entry.get("event") == "tool_result":
                if key in results:
                    errors += 1
                results[key] = entry
    except (OSError, ValueError, KeyError, TypeError):
        errors += 1
    writes = []
    for key, tool in calls.items():
        result = results.get(key, {})
        if result.get("ok") is not True or result.get("tool") != tool:
            errors += 1
        elif tool in WRITE_TOOLS:
            ids = result.get("memory_ids", [])
            if not isinstance(ids, list) or not ids or any(not isinstance(i, str) or not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", i) for i in ids):
                errors += 1
            else:
                writes.append({"tool": tool, "memory_ids": ids})
    errors += len(set(results) - set(calls))
    return {"tool_calls": len(calls), "write_calls": len(writes), "writes": writes, "tool_errors": errors}


def run_codex(root: Path, run_dir: Path, request: dict, excerpt, config: dict) -> dict:
    private_dir(run_dir / "workspace")
    atomic_json(run_dir / "schema.json", RESULT_SCHEMA)
    system = Path(__file__).with_name("learner_prompt.md").read_text()
    provenance = "codex-session:" + request["session_id"] + "; transcript bytes " + str(excerpt.next_offset) + "; " + utc()
    prompt = system + "\n\nSource provenance: " + provenance + "\nWorking-directory context: " + str(request.get("cwd"))
    prompt += "\n\n<untrusted_visible_session_excerpt>\n" + excerpt.text + "\n</untrusted_visible_session_excerpt>\n"
    argv = learner_command(root, run_dir, request, config)
    env = dict(os.environ)
    env[GUARD] = "1"
    env["CLAUDE_MEMORY_LEARNER"] = "1"
    observed = {"seen": set(), "tool_calls": 0, "write_calls": 0, "writes": [],
                "tool_errors": 0, "provider_error": False, "unexpected_tool": False, "turn_completed": False}
    initial = {"status": "running", "started_at": utc(), "session_id": request["session_id"],
               "event": request["event"], "end_offset": excerpt.next_offset}
    atomic_json(run_dir / "run.json", initial)
    stdout_path, stderr_path = run_dir / "provider.jsonl", run_dir / "stderr.log"
    prompt_path = run_dir / "prompt.txt"
    with prompt_path.open("x", encoding="utf-8") as prompt_file:
        prompt_path.chmod(0o600)
        prompt_file.write(prompt)
    reason = None
    with stdout_path.open("wb") as output, stderr_path.open("wb") as error, prompt_path.open("rb") as prompt_input:
        stdout_path.chmod(0o600)
        stderr_path.chmod(0o600)
        proc = subprocess.Popen(argv, stdin=prompt_input, stdout=output, stderr=error,
                                cwd=run_dir / "workspace", env=env, start_new_session=True)
        deadline = time.monotonic() + config["wall_seconds"]
        try:
            with stdout_path.open("r", encoding="utf-8", errors="replace") as stream:
                while True:
                    while True:
                        position = stream.tell()
                        line = stream.readline()
                        if not line.endswith("\n"):
                            stream.seek(position)
                            break
                        try:
                            observe_event(json.loads(line), observed)
                        except (ValueError, TypeError, AttributeError):
                            observed["provider_error"] = True
                    finished = proc.poll() is not None
                    if time.monotonic() >= deadline:
                        reason = "timeout"
                    elif stdout_path.stat().st_size + stderr_path.stat().st_size > 32 * 1024 * 1024:
                        reason = "output_limit"
                    elif observed["tool_calls"] > config["max_tool_calls"] or observed["write_calls"] > config["max_writes"]:
                        reason = "tool_limit"
                    elif observed["unexpected_tool"]:
                        reason = "unexpected_tool"
                    if reason:
                        if not finished:
                            with contextlib.suppress(ProcessLookupError):
                                os.killpg(proc.pid, signal.SIGTERM)
                            try:
                                proc.wait(timeout=3)
                            except subprocess.TimeoutExpired:
                                with contextlib.suppress(ProcessLookupError):
                                    os.killpg(proc.pid, signal.SIGKILL)
                                proc.wait()
                        break
                    if finished:
                        # The child can finish between the previous read and poll.
                        for line in stream:
                            try:
                                observe_event(json.loads(line), observed)
                            except (ValueError, TypeError, AttributeError):
                                observed["provider_error"] = True
                        break
                    time.sleep(0.1)
        finally:
            if proc.poll() is None:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
    observed.pop("seen")
    # Completed MCP calls have their own receipts even when Codex wraps them in
    # code-mode events. Never accept a claimed write without an Engram response.
    provider_tool_errors = observed["tool_errors"]
    observed.update(audit_tools(run_dir / "mcp-audit.jsonl"))
    observed["tool_errors"] += provider_tool_errors
    if observed["tool_calls"] > config["max_tool_calls"] or observed["write_calls"] > config["max_writes"]:
        reason = "tool_limit"
    if observed["unexpected_tool"]:
        reason = "unexpected_tool"
    try:
        result = load_json(run_dir / "result.json")
    except (ValueError, OSError):
        result = {}
    actual_ids = {i.lower() for write in observed["writes"] for i in write["memory_ids"]}
    valid_result = (isinstance(result, dict) and set(result) == {"outcome", "summary", "memory_ids"}
                    and isinstance(result.get("summary"), str) and isinstance(result.get("memory_ids"), list))
    claimed_ids = result.get("memory_ids", []) if valid_result else []
    valid_result = valid_result and all(isinstance(i, str) for i in claimed_ids)
    if valid_result:
        valid_result = ({i.lower() for i in claimed_ids} == actual_ids)
        valid_result = valid_result and ((result["outcome"] == "stored" and bool(actual_ids))
                                         or (result["outcome"] == "no_new_memories" and not actual_ids))
    if not isinstance(result, dict):
        result = {}
    success = (not reason and proc.returncode == 0 and observed["turn_completed"]
               and not observed["provider_error"] and not observed["unexpected_tool"]
               and observed["tool_errors"] == 0 and observed["tool_calls"] > 0
               and valid_result)
    summary = {**initial, "status": "succeeded" if success else "failed", "ended_at": utc(),
               "session_id": request["session_id"], "event": request["event"],
               "returncode": proc.returncode, "reason": reason or (None if success else "unverified_completion"),
               "outcome": result.get("outcome"), **observed}
    atomic_json(run_dir / "run.json", summary)
    # No need to retain a second copy of the excerpt after the subprocess exits.
    prompt_path.unlink(missing_ok=True)
    if success:
        stdout_path.unlink(missing_ok=True)
        stderr_path.unlink(missing_ok=True)
    return summary


def process_request(root: Path, request: dict, config: dict, *, invoke=run_codex) -> str:
    sid = request["session_id"]
    state_path = root / "sessions" / (sid + ".json")
    state = load_json(state_path)
    if state.get("retry_after", 0) > time.time():
        return "backoff"
    path = Path(request["transcript_path"])
    meta = inspect_rollout(str(path))
    if meta.session_id != sid:
        raise ValueError("transcript_session_changed")
    if (request.get("device"), request.get("inode")) != (meta.device, meta.inode):
        raise ValueError("transcript_replaced_since_enqueue")
    if state and (state.get("device"), state.get("inode")) != (meta.device, meta.inode):
        raise ValueError("transcript_replaced")
    offset = state.get("offset", 0)
    if meta.size_bytes < offset:
        raise ValueError("transcript_truncated")
    excerpt = read_excerpt(str(path), offset, max_chars=config["max_chars"], max_scan_bytes=config["max_scan_bytes"],
                           recent_messages=state.get("recent_messages"), current_turn_id=state.get("current_turn_id"))
    if (excerpt.metadata.session_id, excerpt.metadata.device, excerpt.metadata.inode) != (sid, meta.device, meta.inode):
        raise ValueError("transcript_replaced_during_read")
    next_state = {"session_id": sid, "hook_session_id": request.get("hook_session_id", sid),
                  "transcript_path": str(path), "offset": excerpt.next_offset,
                  "recent_messages": excerpt.recent_messages, "current_turn_id": excerpt.current_turn_id,
                  "device": meta.device, "inode": meta.inode, "updated_at": utc()}
    if excerpt.blocked_reason and not excerpt.text:
        event_log(root, "blocked", session_id=sid, reason=excerpt.blocked_reason, offset=offset)
        return "blocked"
    if not excerpt.text:
        atomic_json(state_path, {**state, **next_state, "status": "no_visible_content"})
        return "more" if excerpt.has_more else "no_change"
    if len(excerpt.text) < config["min_chars"] and request["event"] == "Stop" and not excerpt.has_more:
        event_log(root, "deferred_short", session_id=sid, chars=len(excerpt.text))
        return "deferred"
    digest = hashlib.sha256(excerpt.text.encode()).hexdigest()
    if digest == state.get("last_excerpt_sha256"):
        atomic_json(state_path, {**state, **next_state, "status": "duplicate", "last_excerpt_sha256": digest})
        return "more" if excerpt.has_more else "no_change"
    run_dir = private_dir(root / "runs" / (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + uuid.uuid4().hex))
    try:
        result = invoke(root, run_dir, request, excerpt, config)
    except Exception as exc:
        result = {"status": "failed", "reason": type(exc).__name__, "ended_at": utc()}
        atomic_json(run_dir / "run.json", result)
    finally:
        (run_dir / "prompt.txt").unlink(missing_ok=True)
    event_log(root, "learner_finished", session_id=sid, run_id=run_dir.name,
              status=result["status"], writes=result.get("write_calls", 0))
    if result["status"] != "succeeded":
        atomic_json(state_path, {**state, "session_id": sid, "device": meta.device, "inode": meta.inode,
                                "status": "failed", "last_run": run_dir.name,
                                "retry_after": time.time() + config["retry_seconds"]})
        return "failed"
    atomic_json(state_path, {**next_state, "status": "succeeded", "last_run": run_dir.name,
                            "last_excerpt_sha256": digest, "last_success_at": utc()})
    return "more" if excerpt.has_more else "succeeded"


def worker(root: Path) -> int:
    def ready_pending():
        values = []
        for p in (root / "pending").glob("*.json"):
            try:
                r = load_json(p)
                if r and r.get("paused_request_id") != r.get("request_id"):
                    values.append((p.stat().st_mtime_ns, p, r))
            except (OSError, ValueError):
                continue
        return sorted(values, key=lambda v: v[0])

    more = {}
    with lock_file(root / "worker.lock", blocking=False) as acquired:
        if not acquired:
            return 0
        config = settings(root)
        handled = 0
        pending_dir = private_dir(root / "pending")
        while handled < config["max_runs_per_worker"]:
            candidates = ready_pending()
            if not candidates:
                break
            _, pending, request = candidates[0]
            try:
                outcome = process_request(root, request, config)
            except Exception as exc:
                event_log(root, "worker_error", session_id=request.get("session_id"), reason=type(exc).__name__)
                outcome = "blocked"
            handled += 1
            with lock_file(root / "enqueue.lock"):
                current = load_json(pending)
                if current.get("request_id") == request.get("request_id"):
                    if outcome in {"failed", "backoff", "blocked"}:
                        atomic_json(pending, {**current, "paused_request_id": request["request_id"], "pause_reason": outcome})
                    elif outcome == "more":
                        more[pending] = request["request_id"]
                    else:
                        pending.unlink(missing_ok=True)
        # Bound backlog learning per hook. Keep the cursor and remaining work;
        # the next event for this source resumes it without replaying successes.
        with lock_file(root / "enqueue.lock"):
            for pending, request_id in more.items():
                current = load_json(pending)
                if current.get("request_id") == request_id:
                    atomic_json(pending, {**current, "paused_request_id": request_id, "pause_reason": "batch_limit"})
        event_log(root, "worker_idle", handled=handled, pending=len(list(pending_dir.glob("*.json"))))
    # Recheck after releasing the leader lock: a concurrent hook may have queued
    # work while its own worker lost that lock. Never lose that last wakeup.
    with lock_file(root / "enqueue.lock"):
        if ready_pending():
            spawn_worker(root)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["hook", "worker", "status", "enqueue", "retry"])
    parser.add_argument("--state-dir", type=Path, default=codex_home() / "engram-learner")
    parser.add_argument("--input", type=Path, help="Explicit hook JSON fixture (enqueue only)")
    parser.add_argument("--session-id", help="Pending source session to retry")
    args = parser.parse_args(argv)
    root = args.state_dir.expanduser().resolve()
    if args.command == "hook":
        if not automatic_hooks_allowed():
            print("{}")
            return 0
        try:
            payload = json.loads(sys.stdin.buffer.read(1024 * 1024))
            enqueue(root, payload)
        except Exception as exc:
            event_log(root, "hook_error", reason=type(exc).__name__)
        print("{}")
        return 0
    if args.command == "enqueue":
        if not args.input:
            parser.error("enqueue requires --input")
        return 0 if enqueue(root, json.loads(args.input.read_text())) else 1
    if args.command == "worker":
        return worker(root)
    if args.command == "retry":
        if not args.session_id or not re.fullmatch(r"[A-Za-z0-9_-]{1,100}", args.session_id):
            parser.error("retry requires a valid --session-id")
        request = load_json(root / "pending" / (args.session_id + ".json"))
        if not request:
            parser.error("no pending request for this session")
        # Explicit retry respects the same backoff and transcript identity checks.
        payload = {**request, "hook_event_name": request["event"]}
        return 0 if enqueue(root, payload) else 1
    states = [load_json(p) for p in sorted((root / "sessions").glob("*.json"))] if (root / "sessions").exists() else []
    pending = [load_json(p) for p in (root / "pending").glob("*.json")]
    print(json.dumps({"state_dir": str(root), "pending": len(pending),
                      "pending_sessions": [{k: p.get(k) for k in ("session_id", "pause_reason")} for p in pending],
                      "sessions": [{k: s.get(k) for k in ("session_id", "status", "offset", "last_run", "last_success_at")} for s in states]}, indent=2))
    return 0
