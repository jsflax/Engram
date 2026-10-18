"""Durable, advisory worker fairness. Never admission or mutation authority.

Only the worker-lock owner writes this file. Cursors and recovery cooldowns
survive a bounded worker's exit; session/run records remain owned by their
existing validators. A reservation is durable before an attempt starts.
"""
import copy
import hashlib
import json
import math
import os
import re
import stat
import uuid

from . import admission, migration as durable

NAME = "worker-schedule.json"
MAX_BYTES = 1024 * 1024
MAX_BACKOFF = 4096
LANES = ("recovery", "pending")


def _require(ok, reason):
    if not ok:
        raise ValueError("worker_schedule_" + reason)


def _boundary(label):
    """Pure fixture crash seam; never an authorization callback."""


def _sid(value):
    return isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,100}", value) is not None


def _empty():
    return {"version": 1, "next_lane": "recovery", "recovery_cursor": None,
            "pending_cursor": None, "recovery_backoff": {}}


def _decode(raw):
    value = admission._json(raw)
    _require(type(value) is dict and set(value) == set(_empty())
             and type(value["version"]) is int and value["version"] == 1
             and value["next_lane"] in LANES, "invalid_metadata")
    for lane in LANES:
        cursor = value[lane + "_cursor"]
        _require(cursor is None or _sid(cursor), "invalid_metadata")
    backoff = value["recovery_backoff"]
    _require(type(backoff) is dict and len(backoff) <= MAX_BACKOFF, "invalid_metadata")
    for sid, until in backoff.items():
        _require(_sid(sid) and type(until) is int and 0 <= until <= 2**53, "invalid_metadata")
    return value


def _quarantine_oversize(path):
    """Move an owned oversized hint aside without reading or copying its bytes."""
    durable._directory(path.parent)
    try:
        before = path.lstat()
    except FileNotFoundError:
        return False
    _require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
             and before.st_nlink == 1 and not before.st_mode & 0o077, "unsafe_metadata")
    if before.st_size <= MAX_BYTES:
        return False
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        identity = durable._identity(before)
        _require(durable._identity(os.fstat(fd)) == identity, "metadata_changed")
        # A new private directory makes the destination exclusive. Rename keeps
        # the full oversized preimage without allocating another large file.
        archive = path.parent / ("worker-schedule-invalid-" + uuid.uuid4().hex)
        archive.mkdir(mode=0o700)
        durable._new(archive / "identity.json", durable.encode({
            "version": 1, "reason": "oversized_advisory_metadata",
            "maximum_bytes": MAX_BYTES, "identity": identity}))
        _require(durable._identity(path.lstat()) == identity
                 == durable._identity(os.fstat(fd)), "metadata_changed")
        os.rename(path, archive / "record.json")
        after = os.fstat(fd)
        _require((after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
                 == (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
                 and durable._identity((archive / "record.json").lstat())
                 == durable._identity(after), "metadata_changed")
        durable._fsync(archive)
        durable._fsync(path.parent)
        return True
    finally:
        os.close(fd)


class Schedule:
    def __init__(self, root):
        self.path = root / NAME
        self.reset = _quarantine_oversize(self.path)
        self.raw, _ = durable._read(self.path, absent=True, maximum=MAX_BYTES)
        if self.raw is None:
            self.value = _empty()
            return
        try:
            self.value = _decode(self.raw)
        except (ValueError, TypeError, KeyError, RecursionError):
            # Corrupt *owned regular* metadata cannot strand the whole queue.
            # Preserve exact bounded bytes, then atomically reset hints only.
            # A unique archive prevents an interrupted evidence write from
            # becoming a conflicting authority file on the next reset attempt.
            # Unsafe paths fail in _read, outside this reset branch.
            digest = hashlib.sha256(self.raw).hexdigest()
            archive = root / ("worker-schedule-invalid-" + digest + "-" + uuid.uuid4().hex + ".json")
            durable._new(archive, self.raw)
            self.value = _empty()
            self._save(self.value)
            self.reset = True

    def _save(self, value):
        raw = durable.encode(value)
        _require(len(raw) <= MAX_BYTES, "metadata_too_large")
        temp = self.path.with_name(".worker-schedule-" + uuid.uuid4().hex + ".tmp")
        try:
            durable._new(temp, raw)
            _boundary("before_replace")
            current, _ = durable._read(self.path, absent=True, maximum=MAX_BYTES)
            _require(current == self.raw, "metadata_changed")
            os.replace(temp, self.path)
            _boundary("after_replace")
            durable._fsync(self.path.parent)
            self.raw, self.value = raw, value
        finally:
            temp.unlink(missing_ok=True)

    def order(self, lane, values):
        _require(lane in LANES, "invalid_lane")
        values = sorted(values)
        cursor = self.value[lane + "_cursor"]
        if cursor is None:
            return values
        return [sid for sid in values if sid > cursor] + [sid for sid in values if sid <= cursor]

    def eligible(self, sid, now):
        until = self.value["recovery_backoff"].get(sid, 0)
        # Bad clock jumps cannot turn an advisory hint into an indefinite hold.
        if now < until <= now + 3601:
            return False
        # At the bounded metadata limit, defer new recovery reservations until
        # a later wake frees cooldown space. Ordinary work remains eligible;
        # evicting live cooldowns here would allow an unending held-only loop.
        active = sum(now < value <= now + 3601
                     for value in self.value["recovery_backoff"].values())
        return active < MAX_BACKOFF

    def reserve(self, lane, sid, now, retry_seconds):
        _require(lane in LANES and _sid(sid) and type(retry_seconds) is int
                 and 10 <= retry_seconds <= 3600, "invalid_reservation")
        value = copy.deepcopy(self.value)
        value["recovery_backoff"] = {key: until for key, until in value["recovery_backoff"].items()
                                     if now < until <= now + 3601}
        if lane == "recovery":
            _require(sid in value["recovery_backoff"] or len(value["recovery_backoff"]) < MAX_BACKOFF,
                     "backoff_capacity")
            # Prearmed even for a crash during recovery. This never suppresses
            # normal admission/fence validation when that recovery is retried.
            value["recovery_backoff"][sid] = math.ceil(now) + retry_seconds
        value[lane + "_cursor"] = sid
        value["next_lane"] = "pending" if lane == "recovery" else "recovery"
        self._save(value)

    def recovered(self, sid):
        if sid in self.value["recovery_backoff"]:
            value = copy.deepcopy(self.value)
            del value["recovery_backoff"][sid]
            self._save(value)
