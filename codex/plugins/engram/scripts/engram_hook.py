#!/usr/bin/env python3
"""Portable Engram hook entry point. Bootstrap owned state, never user settings.

Host configuration is created once, and explicit disabled policies survive all
subsequent invocations. No transcript is read and no provider is launched here;
validated enrollment, recall and learning belong to their respective adapters.
"""
from __future__ import annotations

from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import signal
import sys
import time
import uuid

EVENTS = {"SessionStart", "UserPromptSubmit", "SubagentStart", "PreToolUse",
          "PostToolUse", "Stop", "SubagentStop", "PreCompact", "SessionEnd"}
MAX_INPUT = 65536


def private_dir(path: Path) -> None:
    path.mkdir(mode=0o700, exist_ok=True)
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or info.st_mode & 0o077):
        raise ValueError("state_directory_not_private")


def initial_json(path: Path, value: dict) -> None:
    """Called while holding setup.lock; never replace existing user policy."""
    if path.exists() or path.is_symlink():
        info = path.lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_nlink != 1 or info.st_mode & 0o077):
            raise ValueError("state_file_not_private")
        return
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def initialize(codex_home: Path) -> Path:
    if not codex_home.is_absolute() or codex_home.resolve(strict=True) != codex_home:
        raise ValueError("codex_home_not_canonical")
    sessions = codex_home / "sessions"
    info = sessions.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError("sessions_not_owned_directory")
    root = codex_home / "engram"
    private_dir(root)
    fd = os.open(root / "setup.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        lock_info = os.fstat(fd)
        if (not stat.S_ISREG(lock_info.st_mode) or lock_info.st_uid != os.getuid()
                or lock_info.st_nlink != 1 or lock_info.st_mode & 0o077):
            raise ValueError("setup_lock_not_private")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for name in ("recall-state", "lifecycle", "learner"):
            private_dir(root / name)
        initial_json(root / "recall.json", {
            "state_dir": str(root / "recall-state"),
            "codex_config_path": str(codex_home / "config.toml"),
            "prompt_recall": True, "semantic_recall": True, "infer_project": True,
            "relevant_project_recall": True,
            "tool_recall": True, "projects": {}, "selected_memory_ids": [],
            "wall_seconds": 2, "cooldown_seconds": 1, "context_chars": 6000})
        initial_json(root / "learner-routes.json", {
            "schema_version": 1, "mode": "host_sessions_v1", "enabled": True,
            "state_dir": str(root / "learner")})
        initial_json(root / "learner" / "admission.json", {
            "schema_version": 1, "mode": "host_sessions_v1", "enabled": True,
            "activation_id": str(uuid.uuid4()),
            "cutoff": datetime.now(timezone.utc).isoformat(),
            "state_dir": str(root / "learner"),
            "sessions_dir": {"path": str(sessions), "device": info.st_dev, "inode": info.st_ino}})
        initial_json(root / "learner" / "settings.json", {
            "min_chars": 400, "max_chars": 12000, "max_scan_bytes": 8 * 1024 * 1024,
            "wall_seconds": 300, "max_tool_calls": 12, "max_writes": 3,
            "max_runs_per_worker": 4, "retry_seconds": 300})
        initial_json(root / "lifecycle.json", {
            "schema_version": 1, "state_dir": str(root / "lifecycle"),
            "recall_config": str(root / "recall.json"), "nudges": True})
    finally:
        os.close(fd)
    return root


def dispatch(root: Path, payload: dict, start: float) -> dict:
    import recall_hook
    import learner_router
    event = payload.get("hook_event_name")
    if event not in EVENTS:
        raise ValueError("unsupported_event")
    # Enrollment must occur before recall's bounded transport call.
    if event in {"SessionStart", "UserPromptSubmit", "SubagentStart", "Stop", "SubagentStop", "PreCompact"}:
        if os.environ.get("ENGRAM_LEARNER_ORCHESTRATED") != "1":
            learner_router.dispatch(root / "learner-routes.json", payload)
    if event in {"SessionStart", "UserPromptSubmit", "SubagentStart"}:
        config = recall_hook.config_at(root / "recall.json")
        audit = {"invocation_id": str(uuid.uuid4()), "event": event,
                 "status": "invalid", "memory_ids": [], "context_chars": 0}
        result = {}
        try:
            result = recall_hook.execute(config, payload, start, Path(config["state_dir"]), audit)
        except recall_hook.Failure as exc:
            audit.update(status=str(exc), failure_phase=audit.get("_phase"), error_kind="classified")
        finally:
            audit.pop("_phase", None)
            context = result.get("hookSpecificOutput", {}).get("additionalContext", "")
            audit["context_sha256"] = hashlib.sha256(context.encode()).hexdigest() if context else None
            audit["elapsed_ms"] = round((time.monotonic() - start) * 1000)
            recall_hook.receipt(Path(config["state_dir"]), audit)
        return result
    if event in {"PreToolUse", "PostToolUse", "SessionEnd"}:
        import lifecycle_hook
        return lifecycle_hook.dispatch(lifecycle_hook.load_config(root / "lifecycle.json"), payload, start)
    return {}


def main(argv=None) -> int:
    start = time.monotonic()
    args = sys.argv[1:] if argv is None else argv
    result = {}
    previous = {}
    recall_hook = None
    try:
        import recall_hook
        if any(key in os.environ for key in recall_hook.RECURSION_ENV):
            return 0
        codex_home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).expanduser().resolve(strict=True)
        root = initialize(codex_home)
        if args == ["--initialize"]:
            result = {"state_root": str(root), "initialized": True}
        elif not args:
            import recall_hook
            recall_hook._cancelled = False
            for sig in (signal.SIGTERM, signal.SIGINT):
                previous[sig] = signal.signal(sig, recall_hook.cancel_hook)
            try:
                payload = recall_hook.read_input(start + 2.8)
            except recall_hook.Failure:
                raise ValueError("invalid_hook_input") from None
            if not isinstance(payload, dict):
                raise ValueError("invalid_payload")
            try:
                result = dispatch(root, payload, start)
            except recall_hook.Failure:
                raise ValueError("hook_adapter_unavailable") from None
        else:
            raise ValueError("invalid_arguments")
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, RecursionError):
        # Fixed diagnostic only: hook input, exception text and secrets stay out.
        print("Engram: hook unavailable; inspect Engram hook-status.", file=sys.stderr)
    finally:
        if recall_hook is not None and recall_hook._cancelled:
            result = {}
        for sig, handler in previous.items():
            signal.signal(sig, handler)
        try:
            os.write(sys.stdout.fileno(), (json.dumps(result, separators=(",", ":")) + "\n").encode())
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
