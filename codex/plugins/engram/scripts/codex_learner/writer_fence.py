"""Per-generation writer exclusion; no provider, native, or recovery integration.

A trusted caller pins create()'s binding in durable execution evidence before
launching writers. Shared handles may pass their descriptor directly to a known
native child. Every copy must be retained through its last possible write and
closed without explicitly unlocking. This module never deletes or replaces the
lock inode or revocation evidence. A recorded generation alone is not a fence.

Recovery obtains exclusive ownership with a finite deadline, then durably
revokes that generation. An absent memory receipt does not authorize replay.
The caller still owns worker/enqueue coordination and checks current admission,
activation, input, and policy through a mandatory exact-True validator.
"""
from __future__ import annotations

import copy
import errno
import fcntl
import math
import os
from pathlib import Path
import stat
import time
import uuid

from . import migration as durable

PROTOCOL = "inherited_shared_writer_fence_v1"
MAX_BYTES = 65536
MAX_TIMEOUT_SECONDS = 5.0
LOCK_NAME = "writer.lock"
REVOCATION_NAME = "writer.revoked.json"


def _require(ok, reason):
    if not ok:
        raise ValueError("writer_fence_" + reason)


def _boundary(label):
    """Isolated subprocess fault injection seam; no production behavior."""


def _uuid(value):
    _require(type(value) is str, "invalid_generation")
    try:
        _require(str(uuid.UUID(value)) == value, "invalid_generation")
    except (ValueError, AttributeError) as error:
        raise ValueError("writer_fence_invalid_generation") from error


def _directory(directory):
    _require(isinstance(directory, Path) and directory.is_absolute(), "invalid_directory")
    _require(not durable._directory(directory).st_mode & 0o077, "directory_not_private")
    return directory


def _lock_record(generation_id, owner_id):
    _uuid(generation_id)
    _uuid(owner_id)
    return {"version": 1, "protocol": PROTOCOL, "epoch_id": generation_id, "owner_id": owner_id}


def _binding(binding):
    _require(type(binding) is dict and set(binding) ==
             {"protocol", "epoch_id", "owner_id", "lock_sha256", "lock_identity"}, "invalid_binding")
    _require(binding["protocol"] == PROTOCOL, "invalid_binding")
    raw = durable.encode(_lock_record(binding["epoch_id"], binding["owner_id"]))
    _require(binding["lock_sha256"] == durable.digest(raw), "invalid_binding")
    identity = binding["lock_identity"]
    _require(type(identity) is dict and set(identity) ==
             {"device", "inode", "uid", "gid", "mode", "size", "mtime_ns", "ctime_ns", "nlink"}
             and all(type(v) is int for v in identity.values()), "invalid_identity")
    _require(stat.S_ISREG(identity["mode"]) and stat.S_IMODE(identity["mode"]) == 0o600
             and identity["uid"] == os.getuid() and identity["nlink"] == 1
             and identity["size"] == len(raw), "invalid_identity")
    return raw


def validate_binding(binding):
    """Validate immutable binding structure only; no held-lock assertion or IO."""
    _binding(binding)
    return True


def _sync_existing(path, raw):
    existing, identity = durable._read(path, maximum=MAX_BYTES)
    _require(existing == raw, "immutable_record_conflict")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        _require(durable._identity(os.fstat(fd)) == identity == durable._identity(path.lstat()), "record_changed")
        os.fsync(fd)
    finally:
        os.close(fd)
    durable._fsync(path.parent)


def _publish(path, raw, label, *, accept_existing=False):
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    except FileExistsError:
        _require(accept_existing, "lock_already_exists")
        _sync_existing(path, raw)
        return
    try:
        os.fchmod(fd, 0o600)
        _boundary(label + "_created")
        view = memoryview(raw)
        while view:
            written = os.write(fd, view)
            _require(written > 0, "short_write")
            view = view[written:]
        _boundary(label + "_written")
        os.fsync(fd)
        _boundary(label + "_file_fsynced")
    finally:
        os.close(fd)
    durable._fsync(path.parent)
    _boundary(label + "_directory_fsynced")


def create(directory, *, generation_id, owner_id):
    """Create one immutable lock inode; caller must durably pin the return value.

    An interrupted creation is never adopted or silently replaced. There is no
    delete/reuse API, including after revocation. No writer is started here.
    """
    directory = _directory(directory)
    _require(not os.path.lexists(directory / REVOCATION_NAME), "generation_revoked")
    raw = durable.encode(_lock_record(generation_id, owner_id))
    _publish(directory / LOCK_NAME, raw, "lock")
    actual, identity = durable._read(directory / LOCK_NAME, maximum=MAX_BYTES)
    _require(actual == raw, "lock_changed")
    result = {"protocol": PROTOCOL, "epoch_id": generation_id, "owner_id": owner_id,
              "lock_sha256": durable.digest(raw), "lock_identity": identity}
    _binding(result)
    return result


def _check_lock(directory, fd, binding):
    raw = _binding(binding)
    _directory(directory)
    path = directory / LOCK_NAME
    identity = binding["lock_identity"]
    _require(durable._identity(os.fstat(fd)) == identity == durable._identity(path.lstat()), "lock_changed")
    _require(os.pread(fd, MAX_BYTES + 1, 0) == raw, "lock_changed")
    _require(durable._identity(os.fstat(fd)) == identity == durable._identity(path.lstat()), "lock_changed")


def _revocation(binding):
    return durable.encode({"version": 1, "status": "revoked", "binding": binding})


def _validator(validate, binding, phase):
    _require(callable(validate), "validator_required")
    _require(validate(copy.deepcopy(binding), phase) is True, "validation_refused")


class HeldFence:
    """Owned descriptor. Context exit closes this copy; it never unlocks copies.

    Shared mode is a writer fence. Exclusive mode is recovery authority only
    after exact durable revocation, and cannot yield a native/writer descriptor.
    Do not duplicate/expose private descriptors or call flock on them yourself.
    """
    def __init__(self, directory, binding, fd, mode):
        self._directory = directory
        self._binding = copy.deepcopy(binding)
        self._fd = fd
        self._mode = mode
        self._revocation_identity = None

    @property
    def mode(self):
        return self._mode

    def verify(self, expected_binding):
        _require(self._fd is not None, "closed")
        _binding(expected_binding)
        _require(durable.encode(expected_binding) == durable.encode(self._binding), "generation_changed")
        _check_lock(self._directory, self._fd, self._binding)
        path = self._directory / REVOCATION_NAME
        if self._mode in ("shared", "quiescent"):
            _require(not os.path.lexists(path), "generation_revoked")
        else:
            actual, identity = durable._read(path, maximum=MAX_BYTES)
            _require(self._revocation_identity is not None and identity == self._revocation_identity
                     and actual == _revocation(self._binding), "revocation_changed")
        return True

    def pass_fds(self):
        """Trusted relay argument for shared writers only; never transport JSON."""
        _require(self._mode == "shared", "recovery_descriptor_not_writable")
        self.verify(self._binding)
        return (self._fd,)

    def binding(self):
        """Copy the verified immutable binding for a trusted native launch."""
        self.verify(self._binding)
        return copy.deepcopy(self._binding)

    def close(self):
        if self._fd is not None:
            fd, self._fd = self._fd, None
            os.close(fd)

    def __enter__(self):
        try:
            self.verify(self._binding)
            return self
        except BaseException:
            self.close()
            raise

    def __exit__(self, *_):
        self.close()

    def __del__(self):
        if getattr(self, "_fd", None) is not None:
            self.close()


def _acquire(directory, binding, mode, timeout_seconds):
    binding = copy.deepcopy(binding)
    directory = _directory(directory)
    _binding(binding)
    _require(type(timeout_seconds) in (int, float) and math.isfinite(timeout_seconds)
             and 0 <= timeout_seconds <= MAX_TIMEOUT_SECONDS, "invalid_timeout")
    fd = os.open(directory / LOCK_NAME, os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        _check_lock(directory, fd, binding)
        deadline = time.monotonic() + timeout_seconds
        while True:
            try:
                fcntl.flock(fd, (fcntl.LOCK_SH if mode == "shared" else fcntl.LOCK_EX) | fcntl.LOCK_NB)
                break
            except OSError as error:
                if error.errno not in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EINTR):
                    raise
                remaining = deadline - time.monotonic()
                _require(remaining > 0, "busy")
                time.sleep(min(0.025, remaining))
        _check_lock(directory, fd, binding)
        held = HeldFence(directory, binding, fd, mode)
        fd = None
        return held
    finally:
        if fd is not None:
            os.close(fd)


def acquire_shared(directory, binding, *, timeout_seconds=2.0):
    """Acquire shared, then reject revocation; never return an unchecked writer."""
    binding = copy.deepcopy(binding)
    held = _acquire(directory, binding, "shared", timeout_seconds)
    try:
        _boundary("shared_acquired")
        held.verify(binding)
        return held
    except BaseException:
        held.close()
        raise


def drain_and_acquire_shared(directory, binding, *, validate, timeout_seconds=2.0):
    """Drain the original generation, then resume its sealed idempotent plan.

    The caller owns worker/enqueue coordination. Exclusive acquisition proves
    no previous inherited writer descriptor remains. Unlike settlement, this
    transition does not revoke the generation: its exact manifest and operation
    IDs remain in use. The exclusive handle cannot launch a writer; it is
    downgraded to a shared handle only after current inputs are revalidated.
    """
    binding = copy.deepcopy(binding)
    _binding(binding)
    _validator(validate, binding, "before_acquire")
    held = _acquire(directory, binding, "quiescent", timeout_seconds)
    try:
        held.verify(binding)
        _boundary("plan_generation_drained")
        _validator(validate, binding, "after_acquire")
        held.verify(binding)
        # Keep conversion bounded too; flock conversion atomicity differs by
        # platform. Worker coordination excludes a competing plan owner.
        fcntl.flock(held._fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        held._mode = "shared"
        held.verify(binding)
        _validator(validate, binding, "after_downgrade")
        return held
    except BaseException:
        held.close()
        raise


def revoke(directory, binding, *, timeout_seconds=2.0, validate):
    """Bounded exclusive recovery and durable revocation of exactly one generation.

    Caller holds worker/enqueue coordination. `validate(binding, phase)` must
    return exactly True for current admission/input/policy authorization. Timeout
    proves nothing about pending writes. Keep the returned exclusive handle open
    through reconciliation/publication; it can never be passed to a writer.
    """
    binding = copy.deepcopy(binding)
    _binding(binding)
    _validator(validate, binding, "before_acquire")
    held = _acquire(directory, binding, "exclusive", timeout_seconds)
    try:
        _boundary("exclusive_acquired")
        _validator(validate, binding, "after_acquire")
        _check_lock(held._directory, held._fd, binding)
        _validator(validate, binding, "before_revocation")
        _check_lock(held._directory, held._fd, binding)
        _publish(held._directory / REVOCATION_NAME, _revocation(binding), "revocation", accept_existing=True)
        raw, held._revocation_identity = durable._read(held._directory / REVOCATION_NAME, maximum=MAX_BYTES)
        _require(raw == _revocation(binding), "revocation_changed")
        _validator(validate, binding, "after_revocation")
        held.verify(binding)
        return held
    except BaseException:
        held.close()
        raise
