"""Recoverable publication of an existing admitted state/admission pair.

This primitive does not authorize learning, execute a provider, touch pending,
or infer completion. The caller holds worker -> enqueue locks and supplies a
validator that rechecks activation, request/fence and frozen input evidence and
returns exactly True. False, None, and other truthy values all fail closed.
Recovery requires the original externally pinned prepared SHA; a journal is
never its own authority. Only its frozen admissions-then-state publication may
finish. Old unjournaled mismatches remain failures, never auto-repaired.
"""
from __future__ import annotations

import base64
import copy
from dataclasses import dataclass
import os
from pathlib import Path
import re
import uuid

from . import admission, migration as durable

MAX_JOURNAL_BYTES = 8 * admission.MAX_BYTES
KIND = "admitted_pair_publication"
ORDER = ("admission", "state")


@dataclass(frozen=True)
class Paths:
    """Trusted caller paths. Journal strings are checked, never followed."""
    state: Path
    admission: Path
    journal_directory: Path


def _require(ok, reason):
    if not ok:
        raise ValueError("publication_" + reason)


def _boundary(label):
    """No-op crash seam; fixtures replace this in an isolated child process."""


def _new(path, raw, label):
    durable._directory(path.parent)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
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


def _json(raw):
    return admission._json(raw)


def _sync_existing(path, expected):
    """Finish a durability boundary interrupted after bytes became visible."""
    raw, identity = durable._read(path, maximum=MAX_JOURNAL_BYTES)
    _require(raw == expected, "publication_changed")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        _require(durable._identity(os.fstat(fd)) == identity == durable._identity(path.lstat()), "publication_changed")
        os.fsync(fd)
    finally:
        os.close(fd)
    durable._fsync(path.parent)


def _identifier(value):
    _require(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,100}", value), "invalid_identifier")


def _sha(value):
    _require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value), "invalid_sha256")


def _paths(paths, session_id, transition_id):
    _require(isinstance(paths, Paths), "invalid_paths")
    _identifier(session_id)
    try:
        _require(str(uuid.UUID(transition_id, version=4)) == transition_id, "invalid_transition_id")
    except (ValueError, TypeError, AttributeError) as error:
        raise ValueError("publication_invalid_transition_id") from error
    for path in (paths.state, paths.admission, paths.journal_directory):
        _require(isinstance(path, Path) and path.is_absolute(), "invalid_paths")
        durable._directory(path.parent)
        _require(path.parent / path.name == path and path.name not in ("", ".", ".."), "invalid_paths")
    _require(paths.state != paths.admission and paths.state.name == paths.admission.name == session_id + ".json"
             and paths.journal_directory.name == transition_id, "path_binding_changed")
    return {"state": str(paths.state), "admission": str(paths.admission),
            "journal_directory": str(paths.journal_directory)}


def _image(raw, identity=None):
    _require(isinstance(raw, bytes) and len(raw) <= admission.MAX_BYTES, "record_too_large")
    value = {"bytes": base64.b64encode(raw).decode("ascii"), "sha256": durable.digest(raw)}
    if identity is not None:
        value["identity"] = identity
    return value


def _raw(image, *, old=False):
    keys = {"bytes", "sha256", "identity"} if old else {"bytes", "sha256"}
    _require(isinstance(image, dict) and set(image) == keys and isinstance(image["bytes"], str), "invalid_image")
    _sha(image["sha256"])
    try:
        raw = base64.b64decode(image["bytes"], validate=True)
    except (ValueError, TypeError) as error:
        raise ValueError("publication_invalid_image") from error
    _require(len(raw) <= admission.MAX_BYTES and _image(raw) == {k: image[k] for k in ("bytes", "sha256")},
             "image_digest_changed")
    _json(raw)
    if old:
        expected = {"device", "inode", "uid", "gid", "mode", "size", "mtime_ns", "ctime_ns", "nlink"}
        _require(isinstance(image["identity"], dict) and set(image["identity"]) == expected
                 and all(type(v) is int for v in image["identity"].values()), "invalid_old_identity")
    return raw


def _pair(state, record, session_id, request_id, binding):
    # Python's equality conflates 7 with 7.0 and 1 with True. The binding is
    # exact versioned JSON evidence, not a permissive dictionary comparison.
    _require(state.get("session_id") == session_id
             and durable.encode(state.get("admission")) == durable.encode(binding)
             and durable.encode(record.get("binding")) == durable.encode(binding), "admission_binding_changed")
    _require({"state_sha256", "last_event", "processing"}.issubset(record)
             and record["state_sha256"] == durable.object_digest(state), "state_admission_hash_mismatch")
    _require(record["processing"] in (None, request_id), "processing_owner_changed")
    _require(type(state.get("offset")) is int and type(binding.get("frontier_offset")) is int
             and state["offset"] >= binding["frontier_offset"] >= 0, "invalid_cursor")


def _validate_plan(plan, paths, session_id, request_id, binding):
    _identifier(request_id)
    _require(isinstance(binding, dict) and binding.get("session_id") == session_id, "invalid_binding")
    _require(isinstance(plan, dict) and set(plan) == {"schema_version", "kind", "status", "transition_id",
             "session_id", "request_id", "binding", "paths", "records", "publication_order"}, "invalid_journal")
    _require(type(plan["schema_version"]) is int and plan["schema_version"] == 1 and plan["kind"] == KIND
             and plan["status"] == "prepared" and plan["publication_order"] == list(ORDER), "invalid_journal")
    _require(plan["session_id"] == session_id and plan["request_id"] == request_id
             and durable.encode(plan["binding"]) == durable.encode(binding),
             "journal_binding_changed")
    _require(plan["paths"] == _paths(paths, session_id, plan["transition_id"]), "path_binding_changed")
    _require(isinstance(plan["records"], dict) and set(plan["records"]) == set(ORDER), "invalid_records")
    objects = {}
    for role in ORDER:
        record = plan["records"][role]
        _require(isinstance(record, dict) and set(record) == {"old", "new"}, "invalid_records")
        for version in ("old", "new"):
            objects[role, version] = _json(_raw(record[version], old=version == "old"))
    for version in ("old", "new"):
        _pair(objects["state", version], objects["admission", version], session_id, request_id, binding)
    _require(objects["state", "new"]["offset"] >= objects["state", "old"]["offset"], "cursor_regression")


def _check_validator(validate, plan, phase):
    _require(callable(validate), "validator_required")
    # Do not let a callback rewrite the frozen internal proposal by aliasing it.
    _require(validate(copy.deepcopy(plan), phase) is True, "validation_refused")


def prepare(paths, *, transition_id, session_id, request_id, binding,
            expected_old_state_sha256, expected_old_admission_sha256,
            new_state, new_admission, validate):
    """Freeze an already-authorized proposal before either target changes.

    Expected old hashes bind the caller's inspected inputs, including formatting.
    This does not create a missing enrollment/state pair. The return value must
    be pinned by the caller's durable execution evidence before publication.
    """
    path_binding = _paths(paths, session_id, transition_id)
    _sha(expected_old_state_sha256)
    _sha(expected_old_admission_sha256)
    records = {}
    for role, expected, proposed in (("admission", expected_old_admission_sha256, new_admission),
                                      ("state", expected_old_state_sha256, new_state)):
        raw, identity = durable._read(getattr(paths, role))
        _require(durable.digest(raw) == expected, "preimage_changed")
        records[role] = {"old": _image(raw, identity), "new": _image(durable.encode(proposed))}
    plan = {"schema_version": 1, "kind": KIND, "status": "prepared", "transition_id": transition_id,
            "session_id": session_id, "request_id": request_id, "binding": copy.deepcopy(binding),
            "paths": path_binding, "records": records, "publication_order": list(ORDER)}
    _validate_plan(plan, paths, session_id, request_id, binding)
    raw = durable.encode(plan)
    _require(len(raw) <= MAX_JOURNAL_BYTES, "journal_too_large")
    _check_validator(validate, plan, "prepare")
    # Callback or another writer cannot publish a proposal before it has a
    # durable journal. Even matching candidate bytes are not an old preimage.
    _require("new" not in _positions(plan, paths), "preimage_changed")
    _require(not os.path.lexists(paths.journal_directory), "journal_already_exists")
    paths.journal_directory.mkdir(mode=0o700)
    durable._fsync(paths.journal_directory.parent)
    _boundary("journal_directory_fsynced")
    _new(paths.journal_directory / "prepared.json", raw, "prepared")
    return durable.digest(raw)


def _positions(plan, paths):
    positions = []
    for role in ORDER:
        record = plan["records"][role]
        raw, identity = durable._read(getattr(paths, role))
        before, after = _raw(record["old"], old=True), _raw(record["new"])
        if raw == before and identity == record["old"]["identity"]:
            positions.append("same" if before == after else "old")
        elif raw == after and before != after:
            positions.append("new")
        else:
            raise ValueError("publication_target_changed")
    # Only the admissions-then-state prefix can have been published here.
    _require(positions != ["old", "new"], "nonprefix_publication")
    return positions


def _load(paths, expected_sha, session_id, request_id, binding):
    _sha(expected_sha)
    info = durable._directory(paths.journal_directory)
    _require(not info.st_mode & 0o077, "journal_not_private")
    raw, _ = durable._read(paths.journal_directory / "prepared.json", maximum=MAX_JOURNAL_BYTES)
    _require(durable.digest(raw) == expected_sha, "prepared_digest_changed")
    plan = _json(raw)
    _validate_plan(plan, paths, session_id, request_id, binding)
    _require(durable.encode(plan) == raw, "noncanonical_journal")
    return plan


def publish(paths, *, expected_prepared_sha256, session_id, request_id, binding, validate):
    """Publish or recover the exact frozen transition; never overwrite a successor.

    The caller must still hold worker -> enqueue locks on every invocation.
    `validate(plan, phase)` must return exactly True after checking current
    activation/pending/fence/input evidence, including when both files already
    match and only a receipt is missing. Exceptions propagate; all other return
    values refuse publication. This grants no permission to replay provider writes.
    """
    plan = _load(paths, expected_prepared_sha256, session_id, request_id, binding)
    _check_validator(validate, plan, "entry")
    # On recovery, visible prepared bytes may precede their original fsync.
    # Re-establish both barriers before either target is allowed to change.
    _sync_existing(paths.journal_directory / "prepared.json", durable.encode(plan))
    result = {"schema_version": 1, "kind": KIND, "status": "published",
              "transition_id": plan["transition_id"], "session_id": session_id,
              "request_id": request_id, "prepared_sha256": expected_prepared_sha256,
              "admission_sha256": plan["records"]["admission"]["new"]["sha256"],
              "state_sha256": plan["records"]["state"]["new"]["sha256"]}
    receipt = paths.journal_directory / "published.json"
    existing, _ = durable._read(receipt, absent=True)
    if existing is not None:
        _require(existing == durable.encode(result) and "old" not in _positions(plan, paths), "published_pair_changed")
        for role in ORDER:
            _sync_existing(getattr(paths, role), _raw(plan["records"][role]["new"]))
        _sync_existing(receipt, existing)
        return result

    for index, role in enumerate(ORDER):
        # Reload immutable authority and validate the entire pair before EACH
        # publication; an unrelated newer target blocks even a different role.
        _require(_load(paths, expected_prepared_sha256, session_id, request_id, binding) == plan, "prepared_changed")
        _check_validator(validate, plan, "before_" + role)
        positions = _positions(plan, paths)
        if positions[index] != "old":
            _sync_existing(getattr(paths, role), _raw(plan["records"][role]["new"]))
            continue
        path = getattr(paths, role)
        raw = _raw(plan["records"][role]["new"])
        # A partial staging file from a killed process is not authority. Leave
        # it intact and construct a fresh O_EXCL stage from the frozen proposal.
        stage = path.parent / (".engram-publication-" + plan["transition_id"] + "-" + role + "-" + uuid.uuid4().hex)
        _new(stage, raw, role + "_stage")
        _check_validator(validate, plan, "replace_" + role)
        _require(_load(paths, expected_prepared_sha256, session_id, request_id, binding) == plan, "prepared_changed")
        _require(_positions(plan, paths) == positions, "target_changed")
        _require(durable._read(stage)[0] == raw, "staging_changed")
        os.replace(stage, path)
        _boundary(role + "_replaced")
        durable._fsync(path.parent)
        _boundary(role + "_directory_fsynced")
        _require(durable._read(path)[0] == raw, "publication_changed")

    _check_validator(validate, plan, "before_receipt")
    _require(_load(paths, expected_prepared_sha256, session_id, request_id, binding) == plan, "prepared_changed")
    _require("old" not in _positions(plan, paths), "publication_incomplete")
    # The immutable final receipt appears only after complete staged bytes are
    # fsynced. A killed writer cannot leave a truncated published.json that
    # prevents otherwise valid recovery of an already-published pair.
    stage = paths.journal_directory / (".published-" + uuid.uuid4().hex)
    _new(stage, durable.encode(result), "published_stage")
    _check_validator(validate, plan, "replace_receipt")
    _require(_load(paths, expected_prepared_sha256, session_id, request_id, binding) == plan, "prepared_changed")
    _require("old" not in _positions(plan, paths), "publication_incomplete")
    _require(not os.path.lexists(receipt), "receipt_appeared")
    _require(durable._read(stage)[0] == durable.encode(result), "staging_changed")
    os.replace(stage, receipt)
    _boundary("published_replaced")
    durable._fsync(paths.journal_directory)
    _boundary("published_directory_fsynced")
    _boundary("publication_complete")
    return result
