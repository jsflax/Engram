"""Native hooks enqueue work; one worker learns bounded incremental excerpts.

Learning uses the installed Codex account and configured Engram MCP, with other
integrations and shell access disabled. Explicit retrospective recovery may read
exact historical memory rows through the separate read-only reconciliation API.
"""
from __future__ import annotations

import argparse
import contextlib
import contextvars
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
import tomllib
import uuid

from .transcript import inspect_rollout, read_excerpt
from .memory_proxy import verified_no_write_receipt, audit_planning_tools, PLANNING_MODE, read_startup_failure
from . import admission, memory_config, host_admission, operation_gateway, learner_settings
from . import runner_publication, settlement, worker_schedule, runtime_routing

EVENTS = {"Stop", "SubagentStop", "PreCompact", "SessionEnd"}
GUARD = "ENGRAM_CODEX_LEARNER"
_PROVIDER_LOCK_FD = contextvars.ContextVar("engram_provider_lock_fd", default=None)
_PROVIDER_STARTED = contextvars.ContextVar("engram_provider_started", default=None)
_EXECUTION = contextvars.ContextVar("engram_execution", default=None)
_HELD_LOCKS = contextvars.ContextVar("engram_held_locks", default=())
READ_TOOLS = {"recall", "graph", "list_topics", "stats", "timeline"}
WRITE_TOOLS = {"remember", "update", "connect"}
DEFAULTS = learner_settings.DEFAULTS


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


def load_pending(path: Path) -> dict:
    """Ignore a damaged queue record without blocking other source sessions."""
    try:
        request = load_json(path)
    except (OSError, ValueError):
        return {}
    if not isinstance(request, dict):
        return {}
    sid, request_id, event = request.get("session_id"), request.get("request_id"), request.get("event")
    if (not isinstance(sid, str) or re.fullmatch(r"[A-Za-z0-9_-]{1,100}", sid) is None
            or sid != path.stem or not isinstance(request_id, str) or not request_id
            or not isinstance(event, str) or event not in EVENTS
            or not isinstance(request.get("transcript_path"), str) or not request["transcript_path"]):
        return {}
    return request


def event_log(root: Path, event: str, **fields) -> None:
    private_dir(root)
    fd = os.open(root / "events.jsonl", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.write(fd, (json.dumps({"time": utc(), "event": event, **fields}) + "\n").encode())
    finally:
        os.close(fd)


@contextlib.contextmanager
def lock_file(path: Path, blocking: bool = True, *, descriptor: bool = False):
    private_dir(path.parent)
    flags = os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC
    f = os.fdopen(os.open(path, flags, 0o600), "a+")
    info = os.fstat(f.fileno())
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
        f.close()
        raise ValueError("lock_not_owned_regular")
    acquired = False
    token = None
    try:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
            acquired = True
        except BlockingIOError:
            pass
        if acquired:
            # Losing contenders must not change metadata of another owner's lock.
            os.fchmod(f.fileno(), 0o600)
            token = _HELD_LOCKS.set((*_HELD_LOCKS.get(), (str(path.absolute()), f.fileno(),
                                                        info.st_dev, info.st_ino)))
        yield f.fileno() if acquired and descriptor else acquired
    finally:
        if token is not None:
            _HELD_LOCKS.reset(token)
        if acquired:
            fcntl.flock(f, fcntl.LOCK_UN)
        f.close()



@contextlib.contextmanager
def provider_slot():
    """Keep the host slot held in the provider if its worker dies unexpectedly.

    The descriptor only comes from our owned lock, never settings or an external
    environment value. The provider inherits the same open-file description, so
    abrupt worker exit cannot free its flock while that provider remains alive.
    """
    with lock_file(codex_home() / "engram" / "learner-provider.lock", descriptor=True) as fd:
        token = _PROVIDER_LOCK_FD.set(fd)
        try:
            yield
        finally:
            _PROVIDER_LOCK_FD.reset(token)


def settings(root: Path) -> dict:
    return learner_settings.bounded(load_json(root / "settings.json"))


def codex_home() -> Path:
    return Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).expanduser().resolve()


def publications(root: Path):
    return runner_publication.Publications(root, codex_home() / "config.toml",
        Path(__file__).resolve().parents[2], legacy_paths=lambda: legacy_paths(root),
        legacy_verify_locks=lambda: publication_locks_owned(root),
        residual_paths=lambda run_id: residual_paths(root, run_id),
        residual_verify_locks=lambda: publication_locks_owned(root),
        native_diagnostic=lambda value: event_log(root, "native_plan_diagnostic", **value))


def publication_locks_owned(root: Path) -> bool:
    """Verify the current caller still owns its worker -> enqueue descriptors."""
    required = [str((root / name).absolute()) for name in ("worker.lock", "enqueue.lock")]
    found = []
    try:
        for path, fd, device, inode in _HELD_LOCKS.get():
            if path not in required:
                continue
            descriptor, current = os.fstat(fd), os.stat(path, follow_symlinks=False)
            if (not stat.S_ISREG(current.st_mode) or current.st_uid != os.getuid()
                    or current.st_nlink != 1 or (descriptor.st_dev, descriptor.st_ino) != (device, inode)
                    or (current.st_dev, current.st_ino) != (device, inode)):
                return False
            found.append(path)
    except OSError:
        return False
    return found == required


def legacy_paths(root: Path):
    """Choose a current local store lazily; never follow a retained plan path."""
    from . import legacy_reconciliation, stdio_bridge, execution_context
    package = Path(__file__).resolve().parents[2]
    _, memory = memory_config.resolve(codex_home() / "config.toml", package)
    if memory.get("enabled") is not True:
        raise ValueError("legacy_reconciliation_memory_disabled")
    argv, environment, _ = stdio_bridge._transport(memory_config.transport(memory))
    # Arbitrary wrapper arguments may choose another store. Only the same
    # no-argument route supported by durable execution is eligible here.
    if len(argv) != 1:
        raise ValueError("legacy_reconciliation_store_selection_unavailable")
    try:
        execution_context._runtime(argv[0])
    except (OSError, ValueError):
        raise ValueError("legacy_reconciliation_store_selection_unavailable") from None
    if "CLAUDE_MEMORY_DB" in environment:
        store = Path(environment["CLAUDE_MEMORY_DB"])
        if not environment["CLAUDE_MEMORY_DB"] or not store.is_absolute():
            raise ValueError("legacy_reconciliation_store_selection_unavailable")
    else:
        # Foundation's default home is the account home, whereas Path.home()
        # can follow an overridden HOME. Require an explicit store for those
        # environments instead of guessing which database native will open.
        try:
            account_home = Path(pwd.getpwuid(os.getuid()).pw_dir)
        except (KeyError, OSError):
            raise ValueError("legacy_reconciliation_store_selection_unavailable") from None
        if ("CFFIXED_USER_HOME" in environment
                or not account_home.is_absolute()
                or Path.home() != account_home
                or environment.get("HOME", str(account_home)) != str(account_home)):
            raise ValueError("legacy_reconciliation_store_selection_unavailable")
        store = account_home / ".claude" / "memory.sqlite"
    # evidence_directory is unused during recovery; all review bytes are frozen
    # in the plan beneath this current trusted root.
    return legacy_reconciliation.LegacyPaths(root, root, package, store)


def residual_paths(root: Path, run_id: str):
    """Resolve recovery from the checked run ID and current native store route."""
    from . import residual_context, residual_publication
    residual_publication._run_id(run_id)
    selected = legacy_paths(root)
    return residual_context.ResidualPaths(root, root / "runs" / run_id,
        codex_home() / "config.toml", selected.package_root, selected.candidate_store)


def has_recoverable_transition(root: Path, session_id: str) -> bool:
    if os.path.lexists(root / "publications" / session_id / "active.json"):
        return True
    try:
        selected = admission.state_paths(root, session_id)
        state = load_json(selected["sessions"])
        if runner_publication.zero_intent_candidate(state):
            return True
        pending = load_pending(selected["pending"])
        if (state.get("status") == "failed" and type(state.get("zero_intent_retry")) is dict
                and state["zero_intent_retry"].get("run_id") == state.get("last_run")
                and pending.get("paused_request_id") == pending.get("request_id")
                and pending.get("pause_reason") == "failed"
                and type(state.get("retry_after", 0)) in (int, float)
                and 0 <= state.get("retry_after", 0) <= time.time()):
            return True
        record = load_json(selected["admissions"])
        if isinstance(record, dict) and record.get("processing_execution") is not None:
            return True
    except (OSError, ValueError):
        # A damaged admission must not hide a retained legacy recovery proof
        # when its pending request is paused. Recovery will surface the hold.
        pass
    try:
        from . import legacy_reconciliation
        if legacy_reconciliation.needs_recovery(root, session_id):
            return True
    except (OSError, ValueError):
        pass
    from . import residual_publication
    return residual_publication.needs_recovery(root, session_id)


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
    stable = admission.check_activation(root).get("mode") == host_admission.MODE_V2
    meta = inspect_rollout(str(path), **({"stable_identity": True} if stable else {}))
    if (st.st_dev, st.st_ino) != (meta.device, meta.inode):
        raise ValueError("transcript_replaced_during_validation")
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
    request = {"session_id": meta.session_id, "hook_session_id": sid,
            "transcript_path": str(path), "cwd": meta.cwd or payload.get("cwd"),
            "hook_cwd": payload.get("cwd"),
            "model": payload.get("model"), "event": event, "turn_id": payload.get("turn_id"),
            "trigger": payload.get("trigger"),
            "requested_at": utc(), "size_bytes": st.st_size, "mtime_ns": st.st_mtime_ns,
            "device": st.st_dev, "inode": st.st_ino, "request_id": uuid.uuid4().hex}
    if stable:
        request.pop("device")
        request.pop("inode")
        request["identity"] = meta.identity
    request["admission"] = admission.check(root, request)
    return request


def admission_digest(value: object) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     ensure_ascii=False, allow_nan=False).encode()).hexdigest()


def transcript_identity_fields(binding: dict) -> dict:
    if binding.get("mode") == host_admission.MODE_V2:
        return {"identity": binding["identity"]}
    return {"device": binding["device"], "inode": binding["inode"]}


def event_digest(request: dict) -> str:
    fields = {key: request.get(key) for key in ("event", "turn_id", "trigger", "size_bytes")}
    fields.update(transcript_identity_fields({**request, "mode": request["admission"].get("mode")}))
    return admission_digest(fields)


def legacy_event_matches(record: dict, request: dict) -> bool:
    """One-way migration bridge using retained historical constants, never st_dev now."""
    if "legacy_event_identity" not in record:
        return False
    previous = record["legacy_event_identity"]
    if (request["admission"].get("mode") != host_admission.MODE_V2
            or not isinstance(previous, dict) or set(previous) != {"device", "inode"}
            or any(type(previous[key]) is not int or previous[key] < 0 for key in previous)):
        raise ValueError("admission_invalid_legacy_event_identity")
    fields = {key: request.get(key) for key in ("event", "turn_id", "trigger", "size_bytes")}
    return record["last_event"] == admission_digest({**fields, **previous})


def admitted_record(root: Path, request: dict, *, create: bool = False) -> dict:
    """Called under enqueue.lock; never adopt a cursor or queue from another activation."""
    binding = admission.check(root, request)
    if request.get("admission") != binding:
        raise ValueError("admission_request_binding_changed")
    sid = request["session_id"]
    paths = admission.state_paths(root, sid)
    record_path, state_path = paths["admissions"], paths["sessions"]
    if not record_path.exists():
        if not create:
            raise ValueError("admission_missing_durable_record")
        if state_path.exists() or paths["pending"].exists():
            raise ValueError("admission_unowned_existing_state")
        state = {"session_id": sid, "transcript_path": binding["transcript_path"],
                 **transcript_identity_fields(binding),
                 "offset": binding["frontier_offset"], "admission": binding,
                 "recent_messages": [], "current_turn_id": None, "status": "enrolled_frontier"}
        record = {"binding": binding, "state_sha256": admission_digest(state),
                  "last_event": None, "processing": None}
        # Held under enqueue.lock. Both files publish atomically; interruption
        # between them leaves a receipt with a missing cursor and fails closed.
        atomic_json(record_path, record)
        atomic_json(state_path, state)
        return record
    record = load_json(record_path)
    if not isinstance(record, dict) or record.get("binding") != binding:
        raise ValueError("admission_durable_binding_changed")
    if not {"state_sha256", "last_event", "processing"}.issubset(record):
        raise ValueError("admission_incomplete_durable_record")
    expected = record["state_sha256"]
    if expected is None or not state_path.exists() or admission_digest(load_json(state_path)) != expected:
        raise ValueError("admission_cursor_missing_or_changed")
    state = load_json(state_path)
    if (type(state.get("offset")) is not int or state["offset"] < binding["frontier_offset"]
            or state.get("admission") != binding):
        raise ValueError("admission_cursor_before_frontier")
    if binding.get("mode") == host_admission.MODE_V2 and (
            state.get("identity") != binding["identity"] or "device" in state or "inode" in state):
        raise ValueError("admission_cursor_binding_changed")
    return record


def commit_admitted_state(root: Path, request: dict, state: dict) -> None:
    """A crash between the two writes fails closed; it cannot reset an old cursor."""
    sid = request["session_id"]
    with lock_file(root / "enqueue.lock"):
        record = admitted_record(root, request)
        if record["processing"] not in (None, request["request_id"]):
            raise ValueError("admission_processing_changed")
        state = {**state, "admission": request["admission"]}
        atomic_json(root / "admissions" / (sid + ".json"),
                    {**record, "state_sha256": admission_digest(state), "processing": None})
        atomic_json(root / "sessions" / (sid + ".json"), state)


def requires_reconciliation(state: dict) -> bool:
    # Only a supported recovery transition may remove a gate. A malformed or
    # partially published gate cannot grant permission to replay uncertain work.
    return "reconciliation_required" in state or state.get("status") == "reconciliation_required"


def enqueue(root: Path, payload: dict, *, spawn: bool = True, expected_admission: dict | None = None,
            route_guard=None) -> bool:
    if os.environ.get(GUARD) or os.environ.get("CLAUDE_MEMORY_LEARNER") or os.environ.get("ENGRAM_LEARNER_ORCHESTRATED") == "1":
        return False
    if payload.get("stop_hook_active"):
        return False
    try:
        request = validate_request(payload, root)
        if expected_admission is not None and request["admission"] != expected_admission:
            raise ValueError("admission_expected_binding_changed")
    except (ValueError, OSError) as exc:
        supplied_id = payload.get("session_id")
        safe_id = supplied_id if isinstance(supplied_id, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,100}", supplied_id) else None
        event_log(root, "rejected", hook_session_id=safe_id, reason=str(exc)[:160])
        return False
    sid = request["session_id"]
    try:
        with lock_file(root / "enqueue.lock"):
            # Trusted router callback, never obtained from hook input or config.
            # Revalidate after waiting behind any policy/route migration.
            if route_guard is not None:
                route_guard()
            record = admitted_record(root, request, create=True)
            state = load_json(root / "sessions" / (sid + ".json"))
            if requires_reconciliation(state):
                gate = state.get("reconciliation_required")
                gate = gate if isinstance(gate, dict) else {}
                event_log(root, "reconciliation_required", session_id=sid,
                          run_id=state.get("last_run"), reason=gate.get("reason"), memory_ids=gate.get("memory_ids", []))
                if spawn and runner_publication.zero_intent_candidate(state):
                    spawn_worker(root)
                return False
            event_key = event_digest(request)
            if record["last_event"] == event_key or legacy_event_matches(record, request):
                event_log(root, "duplicate_event", session_id=sid)
                return False
            # The durable receipt precedes the queue. A crash cannot mint a
            # second request for the same Stop or silently discard its cursor.
            next_record = {**record, "last_event": event_key}
            next_record.pop("legacy_event_identity", None)
            atomic_json(root / "admissions" / (sid + ".json"), next_record)
            pending = root / "pending" / (sid + ".json")
            previous = load_pending(pending)
            # A final flush wins over a redundant Stop for the same snapshot.
            if previous.get("size_bytes") == request["size_bytes"] and previous.get("event") in {"PreCompact", "SessionEnd"}:
                request["event"] = previous["event"]
                # Compaction admission depends on its actual trigger as well as
                # its event. Preserve the validated cause across Stop coalescing.
                request["trigger"] = previous.get("trigger")
            atomic_json(pending, request)
    except (ValueError, OSError) as exc:
        event_log(root, "rejected", session_id=sid, reason=str(exc)[:160])
        # Only the worker may recover a known interrupted pair; it owns the
        # worker -> enqueue lock order and checks the pinned publication.
        if spawn and os.path.lexists(root / "publications" / sid / "active.json"):
            spawn_worker(root)
        return False
    event_log(root, "queued", session_id=sid, hook_event=request["event"], request_id=request["request_id"])
    if spawn:
        spawn_worker(root)
    return True


def _resume_request_locked(root, session_id, request, state):
    """Existing ordinary retry checks; caller owns worker -> enqueue locks."""
    paths = admission.state_paths(root, session_id)
    record = admitted_record(root, request)
    if record["processing"] is not None:
        raise ValueError("admission_interrupted_processing")
    if requires_reconciliation(state):
        raise ValueError("reconciliation_required")
    if (request.get("paused_request_id") != request["request_id"]
            or request.get("pause_reason") not in {"failed", "backoff", "blocked", "batch_limit"}):
        raise ValueError("resume_request_not_safely_paused")
    retry_after = state.get("retry_after", 0)
    if type(retry_after) not in (int, float) or not 0 <= retry_after <= time.time():
        raise ValueError("resume_backoff")
    stable = request["admission"].get("mode") == host_admission.MODE_V2
    meta = inspect_rollout(request["transcript_path"], **({"stable_identity": True} if stable else {}))
    identity = {"identity": meta.identity} if stable else {"device": meta.device, "inode": meta.inode}
    if (meta.session_id != session_id
            or any(request.get(k) != v or state.get(k) != v for k, v in identity.items())):
        raise ValueError("resume_transcript_identity_changed")
    size = request.get("size_bytes")
    if type(size) is not int or size < 0 or meta.size_bytes < max(state["offset"], size):
        raise ValueError("resume_transcript_truncated")
    resumed = dict(request)
    resumed.pop("paused_request_id")
    resumed.pop("pause_reason")
    atomic_json(paths["pending"], resumed)
    return record


def _resume_zero_intent_locked(root, session_id):
    paths = admission.state_paths(root, session_id)
    state, request = load_json(paths["sessions"]), load_pending(paths["pending"])
    if (state.get("status") == "failed" and type(state.get("zero_intent_retry")) is dict
            and state["zero_intent_retry"].get("run_id") == state.get("last_run")
            and request.get("paused_request_id") == request.get("request_id")
            and request.get("pause_reason") == "failed"):
        _resume_request_locked(root, session_id, request, state)
        return True
    return False


def resume_pending(root: Path, session_id: str, *, spawn: bool = True) -> bool:
    """Resume the same paused request without treating it as a new hook event.

    Reconciliation and interrupted execution need their own recovery evidence.
    This path only releases an ordinary pause after rechecking its exact cursor,
    admission and transcript identity. Lock order matches the worker.
    """
    if (os.environ.get(GUARD) or os.environ.get("CLAUDE_MEMORY_LEARNER")
            or os.environ.get("ENGRAM_LEARNER_ORCHESTRATED") == "1"):
        return False
    if not isinstance(session_id, str) or re.fullmatch(r"[A-Za-z0-9_-]{1,100}", session_id) is None:
        return False
    try:
        admission.check_activation(root)
        paths = admission.state_paths(root, session_id)
        pending_path, state_path = paths["pending"], paths["sessions"]
        expected_request = load_pending(pending_path)
        expected_state = load_json(state_path)
        if not expected_request or not isinstance(expected_state, dict):
            raise ValueError("resume_missing_request_or_state")
        with lock_file(root / "worker.lock", blocking=False) as acquired:
            if not acquired:
                raise ValueError("resume_worker_active")
            ready = None
            if (runner_publication.zero_intent_candidate(expected_state)
                    or (type(expected_state.get("zero_intent_retry")) is dict
                        and os.path.lexists(root / "publications" / session_id / "active.json"))):
                publisher = publications(root)
                ready = publisher.prepare_zero_intent_retry(session_id, settings(root))
            if ready is not None:
                try:
                    with lock_file(root / "enqueue.lock"):
                        publisher.finish_zero_intent_retry(ready)
                        expected_request = load_pending(pending_path)
                        expected_state = load_json(state_path)
                finally:
                    ready.close()
            with lock_file(root / "enqueue.lock"):
                admission.state_paths(root, session_id)
                request = load_pending(pending_path)
                state = load_json(state_path)
                if request != expected_request or state != expected_state:
                    raise ValueError("resume_request_or_state_changed")
                if (ready is not None and request.get("paused_request_id") != request.get("request_id")
                        and request["request_id"] != runner_publication.journal._json(runner_publication.journal._unseal(ready.manifest["inputs"]["request"]))["request_id"]):
                    # The authenticated correction preserved a newer admitted
                    # request. Wake it without inventing/removing pause fields.
                    record = admitted_record(root, request)
                else:
                    record = _resume_request_locked(root, session_id, request, state)
    except (ValueError, OSError, KeyError, TypeError) as exc:
        event_log(root, "resume_refused", session_id=session_id, reason=str(exc)[:160])
        return False
    # Queue publication already succeeded. A diagnostic failure must neither
    # describe this as a refused/no-change resume nor suppress its wakeup.
    try:
        event_log(root, "resumed", session_id=session_id, request_id=request["request_id"],
                  previous_pause_reason=request.get("pause_reason"), state_sha256=record["state_sha256"])
    finally:
        if spawn:
            spawn_worker(root)
    return True


def spawn_worker(root: Path) -> None:
    entry = Path(__file__).resolve().parents[1] / "codex_learner.py"
    log = root / "worker.log"
    with log.open("ab") as out:
        os.chmod(log, 0o600)
        env = dict(os.environ, CLAUDE_PLUGIN_ROOT=str(entry.parent.parent))
        env.pop(runtime_routing.HOP, None)  # New independent batch, not an exec hop.
        env.pop(runtime_routing.HOOK_DEADLINE, None)
        subprocess.Popen([sys.executable, "-B", str(entry), "worker", "--state-dir", str(root)],
                         env=env, stdin=subprocess.DEVNULL, stdout=out, stderr=out,
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


def learner_command(root: Path, run_dir: Path, request: dict, config: dict, *, planning=False) -> list[str]:
    plugin_root = Path(__file__).resolve().parents[2]  # Executing immutable package, never a stale cache pin.
    # During migration an already loaded runner may still require the legacy
    # whole-file pin. Honor it as well as any memory pin, parsing the exact bytes
    # checked here rather than rereading a possibly changed configuration.
    config_path = codex_home() / "config.toml"
    legacy = config.get("expected_codex_config_sha256")
    config_bytes = None
    if legacy is not None:
        config_bytes = memory_config.read_bytes(config_path, memory_config.MAX_CONFIG)
        if not isinstance(legacy, str) or hashlib.sha256(config_bytes).hexdigest() != legacy:
            raise ValueError("diagnostic_codex_config_changed")
    user_config, memory = memory_config.resolve(config_path, plugin_root, config_bytes=config_bytes)
    expected = config.get("expected_memory_config_sha256")
    if expected is not None and (not isinstance(expected, str) or
            re.fullmatch(r"[0-9a-f]{64}", expected) is None or
            memory_config.fingerprint(memory) != expected):
        raise ValueError("memory_config_changed")
    allowed = memory_config.allowed_tools(memory, READ_TOOLS | WRITE_TOOLS)
    if "recall" not in allowed or not (allowed & WRITE_TOOLS):
        raise ValueError("memory_mcp_policy_disallows_learning")
    if planning:
        allowed = allowed.intersection(READ_TOOLS)
    tool_policies = {tool: {**memory["tools"].get(tool, {}), "approval_mode": "approve"}
                     for tool in sorted(allowed)}
    memory = memory_config.transport(memory)
    execution = _EXECUTION.get()
    execution_config = {}
    if planning and execution is None:
        raise ValueError("planning_requires_durable_execution")
    if execution is not None:
        if execution.paths.root != root or execution.paths.run_dir != run_dir:
            raise ValueError("execution_paths_changed")
        manifest, _ = runner_publication.journal.read_manifest(run_dir)
        if manifest.get("provider_mode") != (PLANNING_MODE if planning else None):
            raise ValueError("provider_mode_changed")
        if planning and any(manifest["plan_policy"][name] != config[name]
                            for name in ("max_tool_calls", "max_writes")):
            raise ValueError("planning_budget_changed")
        execution.context.validate_inputs(manifest, "before_intent")
        memory = execution.context.transport
        execution_config = {"execution": execution.specification()}
    if planning:
        execution_config["provider_mode"] = PLANNING_MODE
    transport_path = run_dir / "transport.json"
    atomic_json(transport_path, {"transport": memory, "audit_path": str(run_dir / "mcp-audit.jsonl"),
                               "provenance": "codex-session:" + request["session_id"],
                               "allowed_tools": sorted(allowed),
                               "max_tool_calls": config["max_tool_calls"], "max_writes": config["max_writes"],
                               **execution_config})
    memory = {"command": sys.executable, "args": [str(Path(__file__).with_name("memory_proxy.py")), str(transport_path)],
              "enabled": True, "required": True, "enabled_tools": sorted(allowed),
              "default_tools_approval_mode": "prompt",
              "tools": tool_policies,
              "startup_timeout_sec": memory.get("startup_timeout_sec", 30),
              "tool_timeout_sec": memory.get("tool_timeout_sec", 120)}
    binary = runtime_routing.codex_binary(config)
    argv = [binary, "exec", "--ignore-user-config", "--ephemeral", "--skip-git-repo-check",
            "--sandbox", "read-only", "--json", "--color", "never", "--cd", str(run_dir / "workspace"),
            "--output-schema", str(run_dir / "schema.json"),
            "--output-last-message", str(run_dir / ("proposal.json" if planning else "result.json"))]
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


def observe_event(event: dict, observed: dict, *, planning=False) -> None:
    kind = event.get("type")
    if kind == "turn.started":
        observed["provider_turn_starts"] = observed.get("provider_turn_starts", 0) + 1
        if observed["provider_turn_starts"] != 1 or observed["turn_completed"]:
            observed["provider_error"] = True
    if kind == "error":
        # Codex emits nonterminal error notices while reconnecting a stream.
        # A later completed turn still needs every independent receipt/result
        # check. Terminal failures, malformed notices and post-completion errors
        # remain sticky; notice prose never grants completion authority.
        observed["provider_notices"] = observed.get("provider_notices", 0) + 1
        if (set(event) != {"type", "message"} or type(event.get("message")) is not str
                or not event["message"] or observed["turn_completed"]
                or observed.get("provider_turn_starts") != 1):
            observed["provider_error"] = True
    if kind == "turn.failed":
        observed["provider_error"] = True
    if kind == "turn.completed":
        if observed["turn_completed"] or observed.get("provider_turn_starts") != 1:
            observed["provider_error"] = True
        observed["turn_completed"] = True
    if kind not in {"item.started", "item.completed"}:
        return
    if observed["turn_completed"]:
        observed["provider_error"] = True
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
    if server != "memory" or tool not in (READ_TOOLS if planning else READ_TOOLS | WRITE_TOOLS):
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


def audit_tools(path: Path, *, allow_clean_interrupt: bool = False) -> dict:
    """Independent MCP receipts, not the model's claim or provider event shape."""
    calls, results = {}, {}
    errors = 0
    relay_starts = relay_finishes = 0
    interrupt_seen = interrupt_finished = False
    interrupt_prefix_valid = True
    try:
        for line in path.read_text().splitlines():
            entry = json.loads(line)
            if not isinstance(entry, dict):
                raise ValueError("invalid audit record")
            event = entry.get("event")
            # Only a fully completed provider turn may tolerate a terminal
            # interrupt after all audited calls, followed by clean child cleanup.
            if interrupt_seen:
                if interrupt_finished or event != "relay_finished":
                    raise ValueError("event after relay interruption")
                interrupt_finished = True
                if entry.get("child_reaped") is not True or entry.get("cleanup_overrun") is not False:
                    errors += 1
                continue
            # Transport lifecycle metadata has no JSON-RPC request ID.
            if event == "relay_started":
                relay_starts += 1
                interrupt_prefix_valid &= not calls and not results
                continue
            if event == "initialize_compat":
                continue
            if event == "relay_finished":
                relay_finishes += 1
                if entry.get("child_reaped") is not True or entry.get("cleanup_overrun") is not False:
                    errors += 1
                continue
            if event == "relay_interrupted":
                if allow_clean_interrupt is not True:
                    errors += 1
                    continue
                if (errors or relay_starts != 1 or relay_finishes
                        or not interrupt_prefix_valid or not calls
                        or set(calls) != set(results)
                        or any(results[key].get("ok") is not True
                               or results[key].get("tool") != tool
                               for key, tool in calls.items())):
                    raise ValueError("interruption before settled successful calls")
                interrupt_seen = True
                continue
            if event in {"relay_failed", "relay_cleanup_failed"}:
                errors += 1
                continue
            if event not in {"tool_call", "tool_result"}:
                raise ValueError("unknown audit event")
            request_id = entry["id"]
            if not isinstance(request_id, (str, int)) or isinstance(request_id, bool):
                raise ValueError("invalid audit request ID")
            key = (type(request_id), request_id)
            if entry.get("event") == "tool_call":
                if key in calls or entry.get("tool") not in READ_TOOLS | WRITE_TOOLS:
                    errors += 1
                calls[key] = entry["tool"]
            elif entry.get("event") == "tool_result":
                interrupt_prefix_valid &= key in calls
                if key in results:
                    errors += 1
                results[key] = entry
    except (OSError, ValueError, KeyError, TypeError):
        errors += 1
    if interrupt_seen and not interrupt_finished:
        errors += 1
    writes = []
    durable_run = os.path.lexists(path.parent / "execution-manifest.json")
    durable_receipts = durable_run or any(any(key.startswith("operation_") for key in result)
                                         for result in results.values())
    unchanged = operation_failures = 0
    for key, tool in calls.items():
        result = results.get(key, {})
        if result.get("ok") is not True or result.get("tool") != tool:
            errors += 1
            operation_failures += tool in WRITE_TOOLS
        elif tool in WRITE_TOOLS and (durable_run or any(key.startswith("operation_") for key in result)):
            try:
                receipt = operation_gateway.verify_audit_receipt(path.parent, key[1], tool, result)
                if receipt["outcome"] == "applied":
                    writes.append({"tool": tool, "memory_ids": receipt["memoryIDs"]})
                else:
                    unchanged += 1
            except (OSError, ValueError, KeyError, TypeError):
                errors += 1
                operation_failures += 1
        elif "write_outcome" in result:
            if not verified_no_write_receipt(result):
                errors += 1
        elif tool in WRITE_TOOLS:
            ids = result.get("memory_ids", [])
            if not isinstance(ids, list) or not ids or any(not isinstance(i, str) or not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", i) for i in ids):
                errors += 1
            else:
                writes.append({"tool": tool, "memory_ids": ids})
    errors += len(set(results) - set(calls))
    if durable_run:
        try:
            operation_gateway.verify_audit_coverage(path.parent, [key[1] for key, tool in calls.items()
                if tool in WRITE_TOOLS and results.get(key, {}).get("forwarded") is True])
        except (OSError, ValueError, KeyError, TypeError):
            errors += 1
    summary = {"tool_calls": len(calls), "write_calls": len(writes), "writes": writes, "tool_errors": errors}
    if durable_receipts:
        summary.update(attempted_write_calls=sum(tool in WRITE_TOOLS for tool in calls.values()),
                       applied_write_calls=len(writes), unchanged_write_calls=unchanged,
                       operation_failures=operation_failures)
    return summary


def render_learner_prompt(template: str, config: dict, *, planning=False) -> str:
    """Use the same normalized numeric limits supplied to the enforcing proxy."""
    total, writes = config["max_tool_calls"], config["max_writes"]
    if (type(total) is not int or not 1 <= total <= 20
            or type(writes) is not int or not 1 <= writes <= 5):
        raise ValueError("invalid_prompt_tool_budget")
    marker = "{{RUN_TOOL_BUDGET}}"
    if template.count(marker) != 1:
        raise ValueError("missing_or_duplicate_prompt_budget_marker")
    if planning:
        budget = (f"Hard budget for this run: {total} total read tool attempts plus proposed operations. "
                  f"At most {writes} proposed operations may appear in the complete plan. "
                  "Every read attempt consumes one slot, including failed or denied attempts; each proposed "
                  "operation also consumes one slot. A successful recall must precede the proposal. "
                  "Reserve enough slots for your full plan before making more reads. "
                  "If a needed operation cannot fit, report failed with no operations; do not silently omit "
                  "unfinished work or claim no_new_memories. These are limits, not quotas.")
        return template.replace(marker, budget)
    budget = (f"Hard budget for this run: {total} total memory tool-call attempts, including ALL reads and writes. "
              f"Within that total, at most {writes} write attempts (remember/update/connect) are permitted. "
              "Failed or denied attempts still consume the total budget. Track both counts before every call; "
              "never retry after reaching either applicable limit. Once the write allowance is used, "
              "do not attempt another write. Finish with the requested result based on actual receipts.")
    reserve = min(writes, total - 1)  # A recall must precede any proposed write.
    if reserve:
        budget += (f" If planning to use the full feasible write allowance, reserve {reserve} total-call slots "
                   f"for writes and use at most {total - reserve} read attempts. These are limits, not quotas.")
    else:
        budget += " With only one total call, use it for recall; no subsequent write fits the budget."
    budget += (" If a needed write cannot fit after the required recall, report failed rather than exceeding "
               "the budget or claiming no_new_memories. Stop early when no durable new information remains.")
    return template.replace(marker, budget)


def run_planner(root: Path, run_dir: Path, request: dict, excerpt, config: dict) -> dict:
    """Collect a complete write-free proposal; no return value grants execution."""
    if _EXECUTION.get() is None:
        raise ValueError("planning_requires_durable_execution")
    return run_codex(root, run_dir, request, excerpt, config, planning=True)


def private_proposal(path: Path) -> bytes:
    """Privatize only the completed provider's owned, bounded output inode.

    The CLI controls creation permissions for --output-last-message. Tightening
    them is preparation for sealing, never evidence that its proposal succeeded.
    """
    maximum = runner_publication.journal.MAX_INPUT
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        state = os.fstat(fd)
        named = path.lstat()
        if (not stat.S_ISREG(state.st_mode) or state.st_uid != os.getuid()
                or state.st_nlink != 1 or state.st_size > maximum
                or (state.st_dev, state.st_ino) != (named.st_dev, named.st_ino)):
            raise ValueError("unsafe_provider_proposal")
        os.fchmod(fd, 0o600)
        normalized = runner_publication.durable._identity(os.fstat(fd))
    finally:
        os.close(fd)
    raw, identity = runner_publication.durable._read(path, maximum=maximum)
    if identity != normalized:
        raise ValueError("provider_proposal_changed")
    return raw


def run_codex(root: Path, run_dir: Path, request: dict, excerpt, config: dict, *, planning=False) -> dict:
    _PROVIDER_STARTED.set(False)
    private_dir(run_dir / "workspace")
    if planning:
        from . import learner_plan
        manifest, _ = runner_publication.journal.read_manifest(run_dir)
        schema, template_name = learner_plan.provider_contract(manifest)
    else:
        schema, template_name = RESULT_SCHEMA, "learner_prompt_legacy.md"
    atomic_json(run_dir / "schema.json", schema)
    system = render_learner_prompt(Path(__file__).with_name(template_name).read_text(), config, planning=planning)
    provenance = "codex-session:" + request["session_id"]
    if not planning:
        provenance += "; transcript bytes " + str(excerpt.next_offset) + "; " + utc()
    prompt = system + "\n\nSource provenance: " + provenance + "\nWorking-directory context: " + str(request.get("cwd"))
    prompt += "\n\n<untrusted_visible_session_excerpt>\n" + excerpt.text + "\n</untrusted_visible_session_excerpt>\n"
    argv = (learner_command(root, run_dir, request, config, planning=True) if planning
            else learner_command(root, run_dir, request, config))
    env = dict(os.environ)
    env[GUARD] = "1"
    env["CLAUDE_MEMORY_LEARNER"] = "1"
    observed = {"seen": set(), "tool_calls": 0, "write_calls": 0, "writes": [],
                "tool_errors": 0, "provider_error": False, "provider_notices": 0, "provider_turn_starts": 0,
                "unexpected_tool": False, "turn_completed": False}
    initial = {"status": "running", "started_at": utc(), "session_id": request["session_id"],
               "event": request["event"], "end_offset": excerpt.next_offset}
    execution = _EXECUTION.get()
    if execution is not None:
        initial["execution_manifest_sha256"] = execution.context.manifest_sha256
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
        if execution is not None:
            settlement.record_provider_dispatch(run_dir, execution.context.manifest_sha256,
                lambda manifest, _phase: execution.context.validate_inputs(manifest, "before_intent"))
        proc = subprocess.Popen(argv, stdin=prompt_input, stdout=output, stderr=error,
                                cwd=run_dir / "workspace", env=env, start_new_session=True,
                                pass_fds=(() if _PROVIDER_LOCK_FD.get() is None else (_PROVIDER_LOCK_FD.get(),)))
        _PROVIDER_STARTED.set(True)
        deadline = time.monotonic() + config["wall_seconds"]
        try:
            with stdout_path.open("r", encoding="utf-8", errors="replace") as stream:
                while True:
                    finished_before_read = proc.poll() is not None
                    batch_exhausted = True
                    line = ""
                    # A continuously writing child must not keep us inside the
                    # drain loop past the watchdog or output budget checks.
                    for _ in range(64):
                        if time.monotonic() >= deadline:
                            break
                        position = stream.tell()
                        line = stream.readline(1024 * 1024 + 1)
                        if len(line) > 1024 * 1024:
                            reason = "output_line_limit"
                            break
                        if not line.endswith("\n"):
                            stream.seek(position)
                            batch_exhausted = False
                            break
                        try:
                            observe_event(json.loads(line), observed, planning=planning)
                        except (ValueError, TypeError, AttributeError, RecursionError):
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
                    if finished_before_read and not batch_exhausted:
                        # Any partial final frame is invalid. A process that
                        # finished during this read gets another bounded pass.
                        if line:
                            observed["provider_error"] = True
                        break
                    if finished or batch_exhausted:
                        continue
                    time.sleep(0.1)
        finally:
            if proc.poll() is None:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
    observed.pop("seen")
    if execution is not None:
        settlement.persist_observation(run_dir, {
            "started": True, "terminated": proc.poll() is not None,
            "returncode": proc.returncode, "turn_completed": observed["turn_completed"],
            "provider_error": observed["provider_error"], "unexpected_tool": observed["unexpected_tool"],
            "tool_errors": observed["tool_errors"], "reason": reason})
    # Completed MCP calls have their own receipts even when Codex wraps them in
    # code-mode events. Never accept a claimed write without an Engram response.
    provider_tool_errors = observed["tool_errors"]
    allow_clean_interrupt = (
        reason is None and proc.returncode == 0 and observed["turn_completed"]
        and not observed["provider_error"] and not observed["unexpected_tool"]
        and provider_tool_errors == 0)
    audit = audit_planning_tools if planning else audit_tools
    observed.update(audit(run_dir / "mcp-audit.jsonl", allow_clean_interrupt=allow_clean_interrupt))
    observed["tool_errors"] += provider_tool_errors
    if observed["tool_calls"] > config["max_tool_calls"] or observed["write_calls"] > config["max_writes"]:
        reason = "tool_limit"
    if observed["unexpected_tool"]:
        reason = "unexpected_tool"
    result_path = run_dir / ("proposal.json" if planning else "result.json")
    if planning:
        try:
            journal = runner_publication.journal
            raw = private_proposal(result_path)
            result = journal._json(raw, journal.MAX_INPUT)
            manifest, _ = journal.read_manifest(run_dir)
            backend = journal._json(journal._unseal(manifest["inputs"]["backend_config"]))
            learner_plan.validate_proposal(result, provenance="codex-session:" + request["session_id"],
                allowed_tools=memory_config.allowed_tools(backend["memory"], READ_TOOLS | WRITE_TOOLS),
                max_tool_calls=config["max_tool_calls"], max_writes=config["max_writes"],
                read_calls=observed["read_calls"],
                privacy_policy=learner_plan.manifest_policy(manifest)['privacy_policy'])
            valid_result = result["outcome"] in {"proposed", "no_new_memories"}
            observed["proposal_sha256"] = hashlib.sha256(raw).hexdigest()
        except (ValueError, OSError, TypeError, KeyError, UnicodeError, RecursionError):
            result, valid_result = {}, False
    else:
        try:
            result = load_json(result_path)
        except (ValueError, OSError):
            result = {}
    actual_ids = {i.lower() for write in observed["writes"] for i in write["memory_ids"]}
    if not planning:
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
    summary = {**initial, "status": ("planned" if planning else "succeeded") if success else "failed", "ended_at": utc(),
               "session_id": request["session_id"], "event": request["event"],
               "returncode": proc.returncode, "reason": reason or (None if success else "unverified_completion"),
               "outcome": result.get("outcome"), **observed}
    if not success and execution is not None:
        diagnostic = read_startup_failure(run_dir, execution.context.manifest_sha256)
        if diagnostic is not None:
            summary["gateway_startup_failure"] = diagnostic
    atomic_json(run_dir / "run.json", summary)
    # No need to retain a second copy of the excerpt after the subprocess exits.
    prompt_path.unlink(missing_ok=True)
    if success:
        stdout_path.unlink(missing_ok=True)
        stderr_path.unlink(missing_ok=True)
    return summary



def failure_reconciliation(run_dir: Path, provider_started: bool | None) -> dict | None:
    """Use independent gateway receipts to decide whether replay may duplicate a write.

    Absence of a receipt is not absence of a write after a provider started. The
    proxy records calls durably before forwarding, and marks locally denied calls
    forwarded=False. Old receipts lacking that field remain conservative.
    """
    if provider_started is False:
        return None  # The real runner proves no subprocess was created.
    unknown = {"reason": "write_status_unknown", "memory_ids": []}
    def unique_fields(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError("duplicate audit field")
            value[key] = item
        return value
    try:
        raw = memory_config.read_bytes(run_dir / "mcp-audit.jsonl", 1024 * 1024)
        if not raw or not raw.endswith(b"\n"):
            return unknown
        calls, results = {}, {}
        started = False
        request_timed_out = False
        for line in raw.splitlines():
            entry = json.loads(line, object_pairs_hook=unique_fields)
            if not isinstance(entry, dict):
                return unknown
            event = entry.get("event")
            if event == "relay_started":
                if request_timed_out:
                    return unknown
                started = True
                continue
            if event == "request_timeout":
                # The trusted relay fsyncs each tool_call before forwarding it.
                # This exact event terminates its message pump; cleanup may add
                # failed pending results, but cannot forward another request.
                # A timeout before any write therefore needs backoff, not a
                # reconciliation gate. Earlier writes remain risky below.
                if not started or request_timed_out or set(entry) != {"event"}:
                    return unknown
                request_timed_out = True
                continue
            if request_timed_out and (event in {"tool_call", "initialize_compat"}
                                      or (event == "tool_result" and
                                          (entry.get("ok") is not False or entry.get("forwarded") is not True
                                           or "write_outcome" in entry or "write_outcome_version" in entry))):
                return unknown
            if event in {"relay_finished", "relay_interrupted", "relay_failed", "relay_cleanup_failed", "initialize_compat"}:
                continue
            if event not in {"tool_call", "tool_result"}:
                return unknown
            request_id = entry.get("id")
            if (not isinstance(request_id, (str, int)) or isinstance(request_id, bool)
                    or entry.get("tool") not in READ_TOOLS | WRITE_TOOLS):
                return unknown
            key = (type(request_id), request_id)
            table = calls if event == "tool_call" else results
            if key in table:
                return unknown
            table[key] = entry
        if not started or set(results) - set(calls):
            return unknown
        ids, risky = set(), False
        for key, call in calls.items():
            if call["tool"] not in WRITE_TOOLS:
                continue
            result = results.get(key)
            if result is not None and result.get("tool") != call["tool"]:
                return unknown
            if result is not None and "write_outcome" in result:
                if verified_no_write_receipt(result):
                    # Vetted native conflict or failed BEGIN; this attempt
                    # stored nothing. Any earlier risky attempt remains risky.
                    continue
                return unknown  # Contradictory/unknown outcome metadata is unsafe.
            if result is not None and result.get("forwarded") is False and result.get("ok") is False:
                continue  # A denied call is proved not to have reached Engram.
            risky = True
            if result is not None and result.get("ok") is True:
                values = result.get("memory_ids", [])
                if isinstance(values, list):
                    ids.update(i.lower() for i in values if isinstance(i, str) and re.fullmatch(
                        r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", i))
        return {"reason": "successful_or_unverified_write", "memory_ids": sorted(ids)} if risky else None
    except (OSError, ValueError, TypeError, RecursionError):
        return unknown


def complete_ready_plan(root, publisher, outcome, config):
    """Keep the worker lock, but release enqueue while native I/O is pending."""
    if not isinstance(outcome, runner_publication.PlanReady):
        return outcome
    pending = publisher.continue_plan(outcome, config)
    if pending is not None:
        return pending
    with lock_file(root / "enqueue.lock"):
        return publisher.recover(outcome.session_id, config, plan_finished=outcome.run_id)


def process_request(root: Path, request: dict, config: dict, *, invoke=None,
                    provider_mode="read_only_plan") -> str:
    if invoke is None:
        invoke = run_planner
    sid = request["session_id"]
    state_path = root / "sessions" / (sid + ".json")
    publisher = publications(root)
    with lock_file(root / "enqueue.lock"):
        recovered = publisher.recover(sid, config)
    if recovered is not None:
        return complete_ready_plan(root, publisher, recovered, config)
    with lock_file(root / "enqueue.lock"):
        record = admitted_record(root, request)
        if record["processing"] is not None:
            raise ValueError("admission_interrupted_processing")
        state = load_json(state_path)
        if state and state.get("admission") != request["admission"]:
            raise ValueError("admission_cursor_binding_changed")
    if requires_reconciliation(state):
        return "reconciliation_required"
    if state.get("retry_after", 0) > time.time():
        return "backoff"
    path = Path(request["transcript_path"])
    stable = request["admission"].get("mode") == host_admission.MODE_V2
    stable_kwargs = {"stable_identity": True} if stable else {}
    meta = inspect_rollout(str(path), **stable_kwargs)
    if meta.session_id != sid:
        raise ValueError("transcript_session_changed")
    observed_identity = {"identity": meta.identity} if stable else {"device": meta.device, "inode": meta.inode}
    if any(request.get(key) != value for key, value in observed_identity.items()):
        raise ValueError("transcript_replaced_since_enqueue")
    if state and any(state.get(key) != value for key, value in observed_identity.items()):
        raise ValueError("transcript_replaced")
    offset = state["offset"]  # Durable admission requires a cursor at/after the sealed frontier.
    if meta.size_bytes < offset:
        raise ValueError("transcript_truncated")
    def select_excerpt(max_chars):
        selected = read_excerpt(str(path), offset, max_chars=max_chars, max_scan_bytes=config["max_scan_bytes"],
                                recent_messages=state.get("recent_messages"), current_turn_id=state.get("current_turn_id"),
                                **stable_kwargs)
        if (selected.metadata.session_id, selected.metadata.device, selected.metadata.inode) != (sid, meta.device, meta.inode):
            raise ValueError("transcript_replaced_during_read")
        if stable and selected.metadata.identity != meta.identity:
            raise ValueError("transcript_replaced_during_read")
        return selected

    excerpt = select_excerpt(config["max_chars"])
    if (provider_mode == "read_only_plan" and not excerpt.text
            and excerpt.blocked_reason == "message_exceeds_char_limit" and config["max_chars"] < 48000):
        # The configured target normally bounds batches. One whole first message
        # may use the existing ceiling; retry from the ORIGINAL cursor/parser
        # state, never the refused excerpt's partially scanned state. This copied
        # effective limit is sealed below; shared settings and old plans stay exact.
        config = {**config, "max_chars": 48000}
        excerpt = select_excerpt(config["max_chars"])
    next_state = {"session_id": sid, "hook_session_id": request.get("hook_session_id", sid),
                  "transcript_path": str(path), "offset": excerpt.next_offset,
                  "recent_messages": excerpt.recent_messages, "current_turn_id": excerpt.current_turn_id,
                  **observed_identity, "updated_at": utc()}
    if excerpt.blocked_reason and not excerpt.text:
        event_log(root, "blocked", session_id=sid, reason=excerpt.blocked_reason, offset=offset)
        return "blocked"
    if not excerpt.text:
        with lock_file(root / "enqueue.lock"):
            return publisher.parser(request, state, excerpt, next_state, config, reason="no_visible_content")
    if len(excerpt.text) < config["min_chars"] and request["event"] in {"Stop", "SubagentStop"} and not excerpt.has_more:
        event_log(root, "deferred_short", session_id=sid, chars=len(excerpt.text))
        return "deferred"
    # Equal visible text at a different byte interval is not prior successful
    # coverage. The parser already deduplicates mirrored transcript records;
    # any remaining visible interval must receive its own verified completion.
    # Do not seal a processing marker while waiting for a provider. Pausing a
    # policy during that wait must be reversible without implying a write began.
    with provider_slot():
        admission.check(root, request)
        with lock_file(root / "enqueue.lock"):
            record = admitted_record(root, request)
            if record["processing"] is not None:
                raise ValueError("admission_interrupted_processing")
            current = load_json(state_path)
            if requires_reconciliation(current):
                return "reconciliation_required"
            if admission_digest(current) != admission_digest(state):
                raise ValueError("admission_cursor_changed_while_waiting")
        # Native startup can wait on the store. Keep lifecycle hook enqueueing
        # available while the worker probes and freezes this execution.
        prepared = publisher.prepare(request, state, excerpt, config, provider_mode=provider_mode)
        try:
            with lock_file(root / "enqueue.lock"):
                execution = publisher.begin_prepared(prepared, request, state, excerpt)
                run_dir = execution.paths.run_dir
        except BaseException:
            prepared.close()
            raise
        token = _PROVIDER_STARTED.set(None)
        execution_token = _EXECUTION.set(execution)
        try:
            result = invoke(root, run_dir, request, excerpt, config)
        except Exception as exc:
            result = {"status": "failed", "reason": type(exc).__name__, "ended_at": utc()}
            atomic_json(run_dir / "run.json", result)
        finally:
            _EXECUTION.reset(execution_token)
            _PROVIDER_STARTED.reset(token)
            (run_dir / "prompt.txt").unlink(missing_ok=True)
            execution.close()
    event_log(root, "learner_finished", session_id=sid, run_id=run_dir.name,
              status=result["status"], writes=result.get("write_calls", 0))
    with lock_file(root / "enqueue.lock"):
        outcome = publisher.finish(execution, config)
    outcome = complete_ready_plan(root, publisher, outcome, config)
    event_log(root, "learner_settled", session_id=sid, run_id=run_dir.name, status=str(outcome))
    return outcome


def worker(root: Path) -> int:
    try:
        runtime_routing.maybe_exec(Path(__file__).absolute().parents[2], "codex_learner.py",
                                   ["worker", "--state-dir", str(root)], state_root=root)
    except runtime_routing.Refused as exc:
        # Refusal is not leadership or progress; preserve every queued plan.
        print("Engram: " + str(exc), file=sys.stderr)
        return 0
    # A missing/inactive policy must not even inspect or pause an old queue.
    active_policy = admission.check_activation(root)
    invalid_pending = set()
    recovery_failures = set()
    deferred_plans = set()
    recovery_cache = {}

    def recoverable(sid):
        if sid not in recovery_cache:
            recovery_cache[sid] = has_recoverable_transition(root, sid)
        return recovery_cache[sid]

    def ready_pending():
        values = []
        for sid in admission.enrollment_ids(root, active_policy):
            if sid in recovery_failures or sid in deferred_plans:
                continue
            p = admission.state_paths(root, sid)["pending"]
            if not p.exists():
                continue
            try:
                r = load_pending(p)
                if not r:
                    invalid_pending.add(p)
                elif (r.get("paused_request_id") != r.get("request_id")
                      and not recoverable(sid)):
                    values.append((p.stat().st_mtime_ns, p, r))
            except (OSError, ValueError):
                continue
        return sorted(values, key=lambda v: v[0])

    def recovery_session(schedule):
        # A missing or paused queue slot cannot hide an active publication.
        for sid in schedule.order("recovery", admission.enrollment_ids(root, active_policy)):
            if (sid in recovery_failures or sid in deferred_plans
                    or not schedule.eligible(sid, time.time())):
                continue
            if recoverable(sid):
                return sid
        return None

    def select_work(schedule):
        # Persisted lane and SID cursors prevent a short-lived worker from
        # restarting forever at the same held cohort, including when cap == 1.
        first = schedule.value["next_lane"]
        for lane in (first, "pending" if first == "recovery" else "recovery"):
            if lane == "recovery":
                sid = recovery_session(schedule)
                if sid is not None:
                    return lane, sid, None
            else:
                candidates = {p.stem: (p, request) for _, p, request in ready_pending()}
                ordered = schedule.order("pending", candidates)
                if ordered:
                    sid = ordered[0]
                    return lane, sid, candidates[sid]
        return None

    more = {}
    with lock_file(root / "worker.lock", blocking=False) as acquired:
        if not acquired:
            return 0
        config = settings(root)
        schedule = worker_schedule.Schedule(root)
        if schedule.reset:
            event_log(root, "worker_schedule_reset", reason="invalid_advisory_metadata_preserved")
        handled = 0
        pending_dir = private_dir(root / "pending")
        while handled < config["max_runs_per_worker"]:
            with lock_file(root / "enqueue.lock"):
                choice = select_work(schedule)
            if choice is None:
                break
            lane, sid, pending_work = choice
            # Scheduler publication is outside enqueue.lock and grants no
            # execution authority. Existing operation checks still run below.
            schedule.reserve(lane, sid, time.time(), config["retry_seconds"])
            if lane == "recovery":
                try:
                    publisher = publications(root)
                    ready = publisher.prepare_zero_intent_retry(sid, config)
                    try:
                        with lock_file(root / "enqueue.lock"):
                            recovered = (publisher.finish_zero_intent_retry(ready) if ready is not None
                                         else publisher.recover(sid, config))
                    finally:
                        if ready is not None:
                            ready.close()
                    recovered = complete_ready_plan(root, publisher, recovered, config)
                    with lock_file(root / "enqueue.lock"):
                        try:
                            _resume_zero_intent_locked(root, sid)
                        except (ValueError, OSError, KeyError, TypeError):
                            # Preserve a future backoff/changed admission. A new
                            # lifecycle event can retry; never spin this worker.
                            deferred_plans.add(sid)
                    if isinstance(recovered, runner_publication.Continuation):
                        deferred_plans.add(sid)
                    if recovered == "more":
                        with lock_file(root / "enqueue.lock"):
                            path = admission.state_paths(root, sid)["pending"]
                            if load_pending(path).get("request_id") == recovered.request_id:
                                more[path] = recovered.request_id
                except Exception as exc:
                    # Preserve an unfinished transition's pending preimage.
                    recovery_failures.add(sid)
                    fields = {"reason": type(exc).__name__}
                    code = str(exc)
                    if re.fullmatch(r"[a-z][a-z0-9_]{0,127}", code):
                        fields["error_code"] = code
                    event_log(root, "publication_recovery_held", session_id=sid, **fields)
                recovery_cache.pop(sid, None)
                if (sid not in recovery_failures and sid not in deferred_plans
                        and not recoverable(sid)):
                    schedule.recovered(sid)
                handled += 1
                continue
            pending, request = pending_work
            try:
                outcome = process_request(root, request, config)
            except Exception as exc:
                from .native_executor import failure_fields
                details = failure_fields(exc)
                event_log(root, "worker_error", session_id=request.get("session_id"),
                          reason=details.pop('exception_type'), **details)
                outcome = "blocked"
                if has_recoverable_transition(root, request["session_id"]):
                    recovery_failures.add(request["session_id"])
            handled += 1
            recovery_cache.pop(sid, None)
            if isinstance(outcome, runner_publication.Continuation):
                # Preserve the processing marker and exact pending preimage.
                # A later hook resumes this plan after its bounded backoff.
                deferred_plans.add(request["session_id"])
                continue
            # Only the latest outcome for this queue slot may pause it for the
            # batch limit. An earlier successful batch must not mask a hold.
            more.pop(pending, None)
            with lock_file(root / "enqueue.lock"):
                current = load_pending(pending)
                if request["session_id"] in recovery_failures:
                    continue
                if isinstance(outcome, runner_publication.Outcome):
                    # The coordinator already sealed the old request's queue
                    # decision. A recovered older run may have preserved this
                    # newer pending request, which must be processed next.
                    if outcome == "more" and current.get("request_id") == outcome.request_id:
                        more[pending] = outcome.request_id
                    continue
                if current.get("request_id") == request.get("request_id"):
                    if outcome in {"failed", "backoff", "blocked", "reconciliation_required"}:
                        atomic_json(pending, {**current, "paused_request_id": request["request_id"], "pause_reason": outcome})
                    elif outcome == "more":
                        more[pending] = request["request_id"]
                    else:
                        pending.unlink(missing_ok=True)
        # Bound backlog learning per hook. Keep the cursor and remaining work;
        # the next event for this source resumes it without replaying successes.
        with lock_file(root / "enqueue.lock"):
            for pending, request_id in more.items():
                if pending.stem in recovery_failures:
                    continue
                current = load_pending(pending)
                if (current.get("request_id") == request_id
                        and current.get("paused_request_id") != request_id):
                    atomic_json(pending, {**current, "paused_request_id": request_id, "pause_reason": "batch_limit"})
        event_log(root, "worker_idle", handled=handled, pending=len(list(pending_dir.glob("*.json"))),
                  invalid_pending=len(invalid_pending))
    # Recheck after releasing the leader lock: a concurrent hook may have queued
    # work while its own worker lost that lock. Recheck recovery eligibility too,
    # without respawning solely for unchanged held/cooling work. No timer loop:
    # a later natural event wakes expired backoff.
    with lock_file(root / "enqueue.lock"):
        recovery_cache.clear()
        if select_work(schedule) is not None:
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
        try:
            payload = json.loads(sys.stdin.buffer.read(1024 * 1024))
            enqueue(root, payload)
        except Exception as exc:
            # A full/unwritable state directory must not turn a logging failure
            # into a failure of the user's original Codex hook.
            with contextlib.suppress(Exception):
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
        return 0 if resume_pending(root, args.session_id) else 1
    states = [load_json(p) for p in sorted((root / "sessions").glob("*.json"))] if (root / "sessions").exists() else []
    pending = [load_json(p) for p in (root / "pending").glob("*.json")]
    print(json.dumps({"state_dir": str(root), "pending": len(pending),
                      "pending_sessions": [{k: p.get(k) for k in ("session_id", "pause_reason")} for p in pending],
                      "sessions": [{k: s.get(k) for k in ("session_id", "status", "offset", "last_run", "last_success_at")} for s in states]}, indent=2))
    return 0
