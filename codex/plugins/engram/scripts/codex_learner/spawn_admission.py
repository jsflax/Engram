"""Shared Claude/Codex lifetime lease; no PID expiry, polling or queue mutation.

One background worker across providers, plus the existing global 600s spacing.
This throttle does not guarantee inter-provider fairness. Codex's existing fair
scheduler still orders its pending work. Callers may retry a refusal after a
later event or a bounded wait, outside this lease context.
The Swift SpawnAdmission implementation uses the same files and JSON protocol.
Darwin requires a caller-collected CPU/memory sample; Linux retains the load
gate. Resource refusal never reserves a launch or changes queued work.
"""
from __future__ import annotations

import contextlib
import contextvars
import fcntl
import json
import math
import os
import signal
import subprocess
from pathlib import Path
import stat
import sys
import time
import uuid

from . import resource_admission as resources

_HELD = contextvars.ContextVar("engram_spawn_lease", default=None)


def _diagnostic_number(value):
    return type(value) in (int, float) and 0 <= value <= 2**53 and math.isfinite(value)


class Lease:
    def __init__(self, fd=None, reason=None, *, load_average=None, processors=None,
                 previous=None, cooldown=None, resource_fields=None, identity=None):
        self.fd, self.reason = fd, reason
        self.identity = identity
        diagnostic_reason = "admitted" if fd is not None and reason is None else "state_unavailable"
        if reason in {"cooldown", "load", "load_unavailable", "concurrency", "state_unavailable",
                      "cpu_pressure", "memory_pressure", "resource_unavailable"}:
            diagnostic_reason = reason
        self.diagnostic = {"schema_version": 1, "reason": diagnostic_reason}
        if resource_fields:
            self.diagnostic.update(resource_fields)
            if _diagnostic_number(load_average):
                self.diagnostic["load_average"] = load_average  # Diagnostic; no Darwin load limit.
        elif (_diagnostic_number(load_average) and _diagnostic_number(processors)
                and _diagnostic_number(2 * processors)):
            self.diagnostic.update(load_average=load_average, load_limit=2 * processors)
        if reason == "cooldown" and _diagnostic_number(previous) and _diagnostic_number(cooldown):
            eligible_after = previous + cooldown
            if _diagnostic_number(eligible_after):
                self.diagnostic["cooldown_eligible_after"] = eligible_after

    @property
    def admitted(self):
        return self.fd is not None


def pass_fds():
    """Only our internally held descriptor; no caller/environment FD authority."""
    fd = _HELD.get()
    return () if fd is None else (fd,)


def provider_argv(argv, wall_seconds):
    """Hold the lease in an owned waiting process even if the provider closes FDs."""
    held = pass_fds()
    if not held:
        return argv
    return [sys.executable, "-I", "-S", "-B", str(Path(__file__).with_name("provider_guard.py")),
            str(held[0]), str(wall_seconds), "--", *argv]


def stop_provider(process, *, guarded):
    """Cancel work without destroying the owner of its termination proof."""
    if process.poll() is not None:
        return
    with contextlib.suppress(ProcessLookupError):
        os.killpg(process.pid, signal.SIGTERM)
    if guarded:
        # The guard escalates its owned provider group and waits the actual
        # provider. Killing the guard would lose the lifetime/fence guarantee.
        process.wait()
    else:
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def provider_terminated(process, *, guarded):
    code = process.poll()
    return code is not None and (not guarded or code >= 0)


def _regular(fd):
    s = os.fstat(fd)
    if (not stat.S_ISREG(s.st_mode) or s.st_uid != os.getuid()
            or s.st_nlink != 1 or s.st_mode & 0o077):
        raise ValueError("unsafe_file")
    return s


def _same(fd, path):
    a, b = os.fstat(fd), path.lstat()
    if (a.st_dev, a.st_ino) != (b.st_dev, b.st_ino):
        raise ValueError("file_changed")


@contextlib.contextmanager
def sampling_slot(directory):
    """Legacy one-sample leadership only; private, CLOEXEC, never provider-held."""
    root = Path(directory)
    before = root.lstat()
    if (not stat.S_ISDIR(before.st_mode) or before.st_uid != os.getuid() or before.st_mode & 0o077):
        raise ValueError("unsafe_sampling_directory")
    path = root / "worker-retry.lock"
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        _regular(fd); _same(fd, path)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
            return
        yield True
        after = root.lstat()
        _regular(fd); _same(fd, path)
        if ((before.st_dev, before.st_ino) != (after.st_dev, after.st_ino)
                or not stat.S_ISDIR(after.st_mode) or after.st_uid != os.getuid()
                or after.st_mode & 0o077 or os.get_inheritable(fd)):
            raise ValueError("sampling_identity_changed")
    finally:
        os.close(fd)


def _pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_key")
        result[key] = value
    return result


def _read(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    try:
        if _regular(fd).st_size > 4096:
            raise ValueError("oversized_state")
        raw = os.read(fd, 4097)
        _same(fd, path)
        value = json.loads(raw, object_pairs_hook=_pairs)
        if (type(value) is not dict or set(value) != {"version", "lastSpawnAt"}
                or type(value["version"]) is not int or value["version"] != 1
                or type(value["lastSpawnAt"]) not in (int, float)
                or not math.isfinite(value["lastSpawnAt"]) or value["lastSpawnAt"] < 0):
            raise ValueError("invalid_state")
        return value["lastSpawnAt"]
    finally:
        os.close(fd)


def _save(path, now):
    temp = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        data = json.dumps({"version": 1, "lastSpawnAt": now}, allow_nan=False).encode()
        while data:
            n = os.write(fd, data)
            if n <= 0:
                raise OSError("short_state_write")
            data = data[n:]
        os.fsync(fd)
        os.replace(temp, path)
        parent = os.open(path.parent, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
    finally:
        os.close(fd)
        temp.unlink(missing_ok=True)


@contextlib.contextmanager
def lease(*, directory=None, now=None, load=None, processors=None, cooldown=600.0,
          resource_sample=None, resource_identity=None):
    """Nonblocking, durable admission before work. Close only; NEVER LOCK_UN.

    The owned provider guard and direct native children inherit pass_fds().
    The guard retains admission until its actual provider child is reaped, even
    when that provider closes unknown descriptors. Worker death therefore does
    not release the guard's lease. The state file is
    cooldown only, never an active marker. This lease does not poll, wait for
    admission, or probe live PIDs; a caller must exit it before waiting to retry.
    On Darwin, sample_required is an internal preflight result: the caller must
    collect capacity outside ALL execution locks, then re-enter this lease.
    """
    fd, token = None, None
    try:
        try:
            path = Path(directory) if directory is not None else Path.home() / ".claude/memory-hooks-state"
            path.mkdir(mode=0o700, parents=True, exist_ok=True)
            s = path.lstat()
            if not stat.S_ISDIR(s.st_mode) or s.st_uid != os.getuid() or s.st_mode & 0o022:
                raise ValueError("unsafe_directory")
            lock = path / "spawn.lock"
            fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
            lock_info = _regular(fd); _same(fd, lock)
            identity = (s.st_dev, s.st_ino, lock_info.st_dev, lock_info.st_ino)
            if resource_sample is not None and resource_identity != identity:
                raise ValueError("resource_preflight_identity_changed")
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            current = time.time() if now is None else now
            if not math.isfinite(current) or current < 0 or not math.isfinite(cooldown) or cooldown < 0:
                raise ValueError("invalid_clock_or_policy")
            previous = _read(path / "spawn-state.json")
            if previous is not None and current - previous < cooldown:
                result = Lease(reason="cooldown", previous=previous, cooldown=cooldown)
            else:
                count = max(1, os.cpu_count() or 1) if processors is None else max(1, processors)
                resource_fields = {}
                darwin = resources.is_darwin()
                if darwin:
                    # Optional telemetry must not veto valid measured capacity.
                    try:
                        value = os.getloadavg()[0] if load is None else load()
                    except (OSError, ValueError, TypeError, OverflowError):
                        value = None
                    if resource_sample is None:
                        reason = "sample_required"
                    else:
                        reason, resource_fields = resources.decision(resource_sample)
                else:
                    value = os.getloadavg()[0] if load is None else load()
                    reason = ("load_unavailable" if value is None or not math.isfinite(value) or value < 0
                              else "load" if value > 2 * count else None)
                if reason:
                    result = Lease(reason=reason, load_average=value, processors=None if darwin else count,
                                   resource_fields=resource_fields, identity=identity)
                else:
                    _same(fd, lock)
                    _save(path / "spawn-state.json", current)
                    token = _HELD.set(fd)
                    result = Lease(fd=fd, load_average=value, processors=None if darwin else count,
                                   resource_fields=resource_fields)
        except BlockingIOError:
            result = Lease(reason="concurrency")
        except (OSError, ValueError, TypeError, OverflowError):
            result = Lease(reason="state_unavailable")
        yield result
    finally:
        if token is not None:
            _HELD.reset(token)
        if fd is not None:
            os.close(fd)
