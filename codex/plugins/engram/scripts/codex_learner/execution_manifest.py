"""Private immutable execution evidence, not a worker or a replay authority.

The caller supplies already admitted, frozen bytes and holds a live writer or
recovery fence plus the appropriate worker coordination. Every publication
rechecks that fence through a mandatory callback. This
module does not validate admission policy, acquire the fence, contact a backend,
run a provider, mutate memory, or publish a cursor. Pinned lock identity and
generation bind the evidence; the callback must establish the actual held fence.
Dispatch requires the caller's shared writer authority. An exclusive recovery
handle may record status evidence but cannot provide a native writer descriptor.

Native requests are retained byte-for-byte and must be forwarded using the bytes
returned by ``publish_intent``. SHA256 of those bytes and sorted-key JSON are
LOCAL integrity checks, never the native binary canonical payloadDigest. Native
receipts supply that separate digest. Absence is only an observation; this module
permits at most one dispatch per operation and cannot authorize a retry.

O_EXCL files are never repaired or overwritten. A crash can leave a partial file;
that blocks the run for reconciliation. Identical complete publications can be
read and fsynced again. Successful return follows file AND containing-dir fsync.
No timestamps or mutable defaults participate in operation UUID derivation.
"""
from __future__ import annotations

import base64
import copy
import ctypes
import errno
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
import unicodedata
import uuid

from . import admission, file_identity, migration as durable, writer_fence

VERSION = 1
MAX_RECORD = 8 * 1024 * 1024
MAX_INPUT = 1024 * 1024
MAX_EVENTS = 1024
INPUT_NAMES = {"request", "admission", "cursor", "parser_state", "next_parser_state",
               "backend_route", "backend_config"}
FENCE_PROTOCOL = writer_fence.PROTOCOL
_NAMESPACE = uuid.UUID("02574c4d-46a3-531c-bc5c-9be624aa45f3")


def _require(condition, reason):
    if not condition:
        # Fixed labels only: never include private arguments or raw tool errors.
        raise ValueError("execution_manifest_" + reason)


def _keys(value, required, optional=()):
    _require(type(value) is dict and set(required) <= set(value)
             and set(value) <= set(required) | set(optional), "invalid_fields")


def _string(value, maximum=128, *, nonempty=True):
    _require(type(value) is str, "invalid_string")
    try:
        size = len(value.encode("utf-8"))
    except UnicodeError:
        raise ValueError("execution_manifest_invalid_string") from None
    _require(size <= maximum and (not nonempty or size > 0), "invalid_string")


def _identifier(value):
    _string(value)
    _require(not any(unicodedata.category(c) == "Cc" for c in value), "invalid_identifier")


def _integer(value, low=0, high=(1 << 64) - 1):
    _require(type(value) is int and low <= value <= high, "invalid_integer")


def _version(value):
    _integer(value, VERSION, VERSION)


def _uuid(value):
    _string(value, 36)
    try:
        parsed = uuid.UUID(value)
    except ValueError:
        raise ValueError("execution_manifest_invalid_uuid") from None
    _require(str(parsed) == value.lower() and len(value) == 36, "invalid_uuid")
    return str(parsed)


def _digest(value):
    _require(type(value) is str and re.fullmatch(r"[0-9a-f]{64}", value) is not None,
             "invalid_digest")


def _json(raw, maximum=MAX_RECORD):
    _require(type(raw) is bytes and 0 < len(raw) <= maximum, "invalid_record_size")
    value = admission._json(raw)
    pending, count = [(value, 0)], 0
    while pending:
        item, depth = pending.pop()
        count += 1
        _require(depth <= 32 and count <= 100000, "json_too_complex")
        if type(item) is dict:
            for key, child in item.items():
                _string(key, MAX_INPUT, nonempty=False)
                pending.append((child, depth + 1))
        elif type(item) is list:
            pending.extend((child, depth + 1) for child in item)
        elif type(item) is str:
            _string(item, MAX_RECORD, nonempty=False)
        else:
            _require(item is None or type(item) in (bool, int, float), "invalid_json_type")
            if type(item) is float:
                _require(math.isfinite(item), "nonfinite_json")
    return value


def encode(value):
    """Local sorted-key JSON bytes, explicitly NOT Swift canonical encoding."""
    try:
        raw = json.dumps(value, sort_keys=True, separators=(",", ":"),
                         ensure_ascii=False, allow_nan=False).encode("utf-8")
    except (ValueError, TypeError, UnicodeError, RecursionError):
        raise ValueError("execution_manifest_invalid_json") from None
    _json(raw)
    return raw


def sha256(raw):
    return hashlib.sha256(raw).hexdigest()


def seal_json(raw):
    """Retain exact private input bytes; formatting differences stay visible."""
    _json(raw, MAX_INPUT)
    return {"sha256": sha256(raw), "bytes_base64": base64.b64encode(raw).decode("ascii")}


def _unseal(value):
    _keys(value, {"sha256", "bytes_base64"})
    _digest(value["sha256"])
    _string(value["bytes_base64"], 4 * ((MAX_INPUT + 2) // 3))
    try:
        raw = base64.b64decode(value["bytes_base64"], validate=True)
    except ValueError:
        raise ValueError("execution_manifest_invalid_base64") from None
    _require(seal_json(raw) == value, "input_integrity_mismatch")
    return raw


def _scope(value):
    _keys(value, {"version", "storeID", "principal"})
    _version(value["version"])
    store = _uuid(value["storeID"])
    principal = value["principal"]
    _keys(principal, {"kind", "groupIds", "scopes"}, {"id"})
    _require(principal["kind"] in ("user", "agent"), "invalid_principal")
    identity = None if principal.get("id") is None else _uuid(principal["id"])
    _require(type(principal["groupIds"]) is list and len(principal["groupIds"]) <= 1024
             and type(principal["scopes"]) is list and len(principal["scopes"]) <= 1024,
             "invalid_principal")
    groups = sorted({_uuid(v) for v in principal["groupIds"]})
    for scope in principal["scopes"]:
        _string(scope, 4096, nonempty=False)
    # Match native UUID/set/String equality without normalizing mutation text.
    scopes = sorted({unicodedata.normalize("NFC", v) for v in principal["scopes"]})
    return (store, identity, principal["kind"], tuple(groups), tuple(scopes))


def _fencing(value):
    # Pin the exact writer lock inode/content, not just correlation UUIDs.
    # Structural validity is distinct from the mandatory live held-fence check.
    writer_fence.validate_binding(value)


def _manifest(value):
    _keys(value, {"version", "host", "session_id", "run_id", "inputs", "source",
                  "expected_scope", "backend", "fencing"}, {"provider_mode", "plan_policy"})
    _version(value["version"])
    # Old sealed runs have no selector. New planning runs bind their read-only
    # provider contract into the manifest digest and therefore every operation ID.
    if "provider_mode" in value:
        _require(value["provider_mode"] == "read_only_plan", "invalid_provider_mode")
        _keys(value.get("plan_policy"), {"max_tool_calls", "max_writes"})
        _integer(value["plan_policy"]["max_tool_calls"], 1, 20)
        _integer(value["plan_policy"]["max_writes"], 1, 5)
    else:
        _require("plan_policy" not in value, "orphan_plan_policy")
    for key in ("host", "session_id", "run_id"):
        _identifier(value[key])
    _uuid(value["session_id"])
    _keys(value["inputs"], INPUT_NAMES)
    for item in value["inputs"].values():
        _unseal(item)
    source = value["source"]
    _keys(source, {"identity", "start_offset", "end_offset", "excerpt_sha256"})
    file_identity.validate(source["identity"])
    _integer(source["start_offset"])
    _integer(source["end_offset"], source["start_offset"] + 1)
    _digest(source["excerpt_sha256"])
    _scope(value["expected_scope"])
    _keys(value["backend"], {"route_id", "runtime_sha256", "route_sha256", "config_sha256"})
    _identifier(value["backend"]["route_id"])
    for name in ("runtime", "route", "config"):
        _digest(value["backend"][name + "_sha256"])
    for name in ("route", "config"):
        _require(value["backend"][name + "_sha256"]
                 == value["inputs"]["backend_" + name]["sha256"], "backend_binding_mismatch")
    _fencing(value["fencing"])
    return value


def _private(path):
    path = Path(path)
    _require(not durable._directory(path).st_mode & 0o077, "directory_not_private")
    return path


def _check_fence(manifest, verify_fence):
    _require(callable(verify_fence), "fence_verifier_required")
    # Nested lock identity is immutable evidence too: a shallow copy aliases it
    # into the frozen manifest and lets a callback rewrite its internal binding.
    _require(verify_fence(copy.deepcopy(manifest["fencing"])) is True, "fence_not_held")


def _boundary(label):
    """Private test seam for actual process termination at publication edges."""


def _publish(path, raw):
    _private(path.parent)
    _boundary("before_create")
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    except FileExistsError:
        existing, identity = durable._read(path, maximum=MAX_RECORD)
        _require(existing == raw, "immutable_record_conflict")
        # A complete file can have survived a crash before fsync. Re-establish
        # durability before returning it; partial files never reach this branch.
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            _require(durable._identity(os.fstat(fd)) == identity, "file_changed")
            os.fsync(fd)
        finally:
            os.close(fd)
    else:
        try:
            _boundary("after_create")
            remaining = memoryview(raw)
            while remaining:
                written = os.write(fd, remaining)
                _require(written > 0, "short_write")
                remaining = remaining[written:]
            _boundary("after_write")
            os.fsync(fd)
            _boundary("after_file_fsync")
        finally:
            os.close(fd)
    durable._fsync(path.parent)
    _boundary("after_directory_fsync")
    _require(durable._read(path, maximum=MAX_RECORD)[0] == raw, "file_changed")


def _rename_exclusive(source, destination):
    """Atomic no-replace rename; never degrade to a check-then-overwrite."""
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == 'darwin':
        operation = libc.renamex_np
        operation.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        arguments = (os.fsencode(source), os.fsencode(destination), 4)  # RENAME_EXCL
    elif sys.platform.startswith('linux') and hasattr(libc, 'renameat2'):
        operation = libc.renameat2
        operation.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        arguments = (-100, os.fsencode(source), -100, os.fsencode(destination), 1)  # AT_FDCWD, NOREPLACE
    else:
        raise ValueError('execution_manifest_atomic_rename_unavailable')
    operation.restype = ctypes.c_int
    if operation(*arguments) != 0:
        code = ctypes.get_errno()
        if code == errno.EEXIST:
            raise FileExistsError(code, 'atomic destination exists')
        raise OSError(code, 'atomic publication refused')


def _sync_existing(path, raw):
    """Make the exact complete existing record durable without creating it."""
    actual, identity = durable._read(path, maximum=MAX_RECORD)
    _require(actual == raw, 'file_changed')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        _require(durable._identity(os.fstat(fd)) == identity, 'file_changed')
        os.fsync(fd)
    finally:
        os.close(fd)
    durable._fsync(path.parent)
    _require(durable._read(path, maximum=MAX_RECORD) == (raw, identity), 'file_changed')


def _event_paths(directory, *, planning=False):
    """Bound the entire directory, including ignored unpublished temporaries."""
    paths = []
    with os.scandir(directory) as entries:
        for count, entry in enumerate(entries):
            _require(count < 4096, 'event_directory_limit')
            if planning and entry.name.startswith('.plan-publish-'):
                continue
            paths.append(directory / entry.name)
    return sorted(paths)


def _publish_atomic(path, raw):
    """Complete bytes or no final record, including when the worker is killed.

    Leftover private temporary names are not authority. No-replace rename keeps
    the existing single-link reader contract even if killed at publication.
    """
    _private(path.parent)
    _json(raw)
    if os.path.lexists(path):
        _require(durable._read(path, maximum=MAX_RECORD)[0] == raw, 'immutable_record_conflict')
        _sync_existing(path, raw)
        return
    temporary = path.parent / ('.plan-publish-' + str(uuid.uuid4()))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        _boundary('atomic_after_create')
        remaining = memoryview(raw)
        while remaining:
            written = os.write(fd, remaining)
            _require(written > 0, 'short_write')
            remaining = remaining[written:]
        _boundary('atomic_after_write')
        os.fsync(fd)
        _boundary('atomic_after_file_fsync')
        try:
            _rename_exclusive(temporary, path)
        except FileExistsError:
            _require(durable._read(path, maximum=MAX_RECORD)[0] == raw, 'immutable_record_conflict')
        _boundary('atomic_after_rename')
    finally:
        os.close(fd)
        if os.path.lexists(temporary):
            os.unlink(temporary)
    durable._fsync(path.parent)
    _boundary('atomic_after_directory_fsync')
    _require(durable._read(path, maximum=MAX_RECORD)[0] == raw, 'file_changed')


def publish_manifest(run_dir, manifest, *, verify_fence):
    """Called before provider dispatch; input snapshots must already be admitted."""
    raw = encode(manifest)
    frozen = _manifest(_json(raw))
    _check_fence(frozen, verify_fence)
    _publish(_private(run_dir) / "execution-manifest.json", raw)
    _check_fence(frozen, verify_fence)
    return sha256(raw)


def read_manifest(run_dir):
    raw = durable._read(_private(run_dir) / "execution-manifest.json", maximum=MAX_RECORD)[0]
    return _manifest(_json(raw)), sha256(raw)


def operation_id(run_dir, call_id):
    """Same immutable run binding + unique upstream call ID => same UUIDv5."""
    _identifier(call_id)
    _, manifest_hash = read_manifest(run_dir)
    return str(uuid.uuid5(_NAMESPACE, manifest_hash + ":" + call_id))


def _mutation(value):
    _keys(value, {"kind", "request"})
    kind, request = value["kind"], value["request"]
    _require(kind in ("remember", "update", "connect"), "unsupported_mutation")
    if kind == "connect":
        _keys(request, {"sourceId", "targetId", "relation"})
        _uuid(request["sourceId"])
        _uuid(request["targetId"])
        _require(request["relation"] in ("relates_to", "contradicts", "supersedes", "derived_from",
                                          "part_of", "summarized_by"), "unsupported_relation")
        return
    text = {"content", "topic", "project", "source"} | (set() if kind == "remember"
                                                       else {"append", "prepend", "find", "replace"})
    _keys(request, {"content", "isPrivate"} if kind == "remember" else {"id", "undelete"},
          text | {"importance", "expiresInDays", "isPrivate"} | ({"parentId"} if kind == "remember" else set()))
    for key in text:
        if request.get(key) is not None:
            _string(request[key], MAX_INPUT, nonempty=False)
    if kind == "remember":
        _require(type(request["content"]) is str and bool(request["content"])
                 and type(request["isPrivate"]) is bool,
                 "invalid_remember")
        if request.get("parentId") is not None:
            _uuid(request["parentId"])
    else:
        _uuid(request["id"])
        _require(request["undelete"] is False, "unsupported_undelete")
        edits = sum(request.get(k) is not None for k in ("content", "append", "prepend", "find"))
        _require(edits <= 1 and (request.get("find") is None) == (request.get("replace") is None),
                 "conflicting_content_edits")
        _require(any(request.get(k) is not None for k in text | {"importance", "expiresInDays", "isPrivate"}),
                 "empty_update")
        _require(request.get("isPrivate") is None or type(request["isPrivate"]) is bool, "invalid_privacy")
    if request.get("importance") is not None:
        _integer(request["importance"], 1 if kind == "remember" else 0, 5)
    if request.get("expiresInDays") is not None:
        _integer(request["expiresInDays"], -(1 << 63), (1 << 63) - 1)


def _request(raw, manifest, expected_id):
    request = _json(raw, MAX_INPUT)
    _keys(request, {"version", "operationID", "expectedScope", "provenance", "mutation"})
    _version(request["version"])
    _require(_uuid(request["operationID"]) == expected_id, "operation_id_mismatch")
    _require(_scope(request["expectedScope"]) == _scope(manifest["expected_scope"]), "scope_mismatch")
    provenance = request["provenance"]
    _keys(provenance, {"host", "sessionID", "runID", "source"})
    source = manifest["source"]
    _require(provenance == {"host": manifest["host"], "sessionID": manifest["session_id"],
                           "runID": manifest["run_id"], "source": {
                               "startOffset": source["start_offset"], "endOffset": source["end_offset"],
                               "excerptDigest": source["excerpt_sha256"]}}, "provenance_mismatch")
    # Equality alone would allow bools in place of integer offsets.
    _integer(provenance["source"]["startOffset"])
    _integer(provenance["source"]["endOffset"], 1)
    _mutation(request["mutation"])
    return request


def _intent_path(run_dir, operation):
    return Path(run_dir) / ("operation-" + _uuid(operation) + ".json")


def publish_intent(run_dir, call_id, native_request_raw, *, verify_fence, atomic=False):
    """Persist BEFORE dispatch. Forward only these returned exact request bytes."""
    manifest, manifest_hash = read_manifest(run_dir)
    operation = operation_id(run_dir, call_id)
    request = _request(native_request_raw, manifest, operation)
    record = {"version": VERSION, "manifest_sha256": manifest_hash, "call_id": call_id,
              "operation_id": operation, "request": seal_json(native_request_raw),
              "local_json_sha256": sha256(encode(request))}
    _check_fence(manifest, verify_fence)
    (_publish_atomic if atomic else _publish)(_intent_path(run_dir, operation), encode(record))
    _check_fence(manifest, verify_fence)
    return read_intent(run_dir, operation)[0]


def read_intent(run_dir, operation):
    manifest, manifest_hash = read_manifest(run_dir)
    raw = durable._read(_intent_path(run_dir, operation), maximum=MAX_RECORD)[0]
    value = _json(raw)
    _keys(value, {"version", "manifest_sha256", "call_id", "operation_id", "request", "local_json_sha256"})
    _version(value["version"])
    _require(value["manifest_sha256"] == manifest_hash and value["operation_id"] == _uuid(operation)
             == operation_id(run_dir, value["call_id"]), "intent_binding_mismatch")
    native_raw = _unseal(value["request"])
    request = _request(native_raw, manifest, _uuid(operation))
    _require(value["local_json_sha256"] == sha256(encode(request)), "input_integrity_mismatch")
    return native_raw, request


def _receipt(receipt, request, prior=None):
    _keys(receipt, {"version", "operationID", "scope", "payloadDigest", "mutation", "outcome",
                    "memoryIDs", "edgeIDs", "committedAt"})
    _version(receipt["version"])
    _require(_uuid(receipt["operationID"]) == _uuid(request["operationID"]), "receipt_operation_mismatch")
    _require(_scope(receipt["scope"]) == _scope(request["expectedScope"]), "receipt_scope_mismatch")
    _require(receipt["mutation"] == request["mutation"]["kind"], "receipt_mutation_mismatch")
    _digest(receipt["payloadDigest"])
    _require(receipt["outcome"] in ("applied", "unchanged"), "invalid_receipt_outcome")
    ids = []
    for key in ("memoryIDs", "edgeIDs"):
        values = receipt[key]
        _require(type(values) is list and len(values) <= 128, "invalid_receipt_ids")
        normalized = [_uuid(v) for v in values]
        _require(len(set(normalized)) == len(values), "duplicate_receipt_ids")
        ids.extend(values)
    _require(len(ids) <= 128, "invalid_receipt_ids")
    # Native Codable's default Date representation: finite seconds since 2001.
    _require(type(receipt["committedAt"]) in (int, float)
             and -1e12 < receipt["committedAt"] < 1e12
             and math.isfinite(receipt["committedAt"]), "invalid_receipt_date")
    if prior is not None:
        _require(receipt["payloadDigest"] == prior["payloadDigest"], "native_payload_digest_conflict")
        normalized = dict(receipt, scope=_scope(receipt["scope"]), operationID=_uuid(receipt["operationID"]))
        previous = dict(prior, scope=_scope(prior["scope"]), operationID=_uuid(prior["operationID"]))
        for key in ("memoryIDs", "edgeIDs"):
            normalized[key] = [_uuid(value) for value in receipt[key]]
            previous[key] = [_uuid(value) for value in prior[key]]
        _require(normalized == previous, "native_receipt_changed")


def _response(response, request, prior):
    _require(type(response) is dict, "invalid_response")
    kind = response.get("kind")
    if kind == "committed":
        _keys(response, {"kind", "receipt"})
        _receipt(response["receipt"], request, prior)
        return response["receipt"]
    if kind == "absent":
        _keys(response, {"kind", "operationID", "scope"})
        _require(prior is None, "committed_operation_became_absent")
        _require(_uuid(response["operationID"]) == _uuid(request["operationID"])
                 and _scope(response["scope"]) == _scope(request["expectedScope"]), "status_binding_mismatch")
    else:
        _keys(response, {"kind", "reason"})
        _require(kind == "unavailable" and response["reason"] in
                 ("transport_error", "backend_error", "invalid_response", "writer_unfenced"), "invalid_response")
    return prior


def read_evidence(run_dir, operation):
    """Validate the complete contiguous hash chain; never interpret absence as safe."""
    _, request = read_intent(run_dir, operation)
    manifest, manifest_hash = read_manifest(run_dir)
    directory = Path(run_dir) / ("evidence-" + _uuid(operation))
    if not directory.exists():
        _require(not directory.is_symlink(), "unsafe_evidence_directory")
        return []
    _private(directory)
    paths = _event_paths(directory, planning=manifest.get('provider_mode') == 'read_only_plan')
    _require(len(paths) <= MAX_EVENTS, "too_many_events")
    result, previous, prior, dispatched = [], None, None, False
    for index, path in enumerate(paths):
        _require(path.name == f"{index:06d}.json", "event_sequence_invalid")
        raw = durable._read(path, maximum=MAX_RECORD)[0]
        event = _json(raw)
        _keys(event, {"version", "sequence", "previous_sha256", "manifest_sha256", "operation_id", "evidence"})
        _version(event["version"])
        _integer(event["sequence"], index, index)
        _require(event["previous_sha256"] == previous and event["manifest_sha256"] == manifest_hash
                 and event["operation_id"] == _uuid(operation), "event_binding_mismatch")
        evidence = event["evidence"]
        _require(type(evidence) is dict, "invalid_evidence")
        if evidence.get("kind") == "dispatch":
            _keys(evidence, {"kind", "request_sha256", "fencing"})
            _fencing(evidence["fencing"])
            _require(not dispatched and prior is None, "redispatch_requires_reconciliation")
            _require(evidence["request_sha256"] == sha256(read_intent(run_dir, operation)[0])
                     and encode(evidence["fencing"]) == encode(manifest["fencing"]), "dispatch_binding_mismatch")
            dispatched = True
        else:
            prior = _response(evidence, request, prior)
        previous = sha256(raw)
        result.append(event)
    return result


def _append(run_dir, operation, evidence, verify_fence, *, atomic=False):
    manifest, manifest_hash = read_manifest(run_dir)
    events = read_evidence(run_dir, operation)
    _require(len(events) < MAX_EVENTS, "too_many_events")
    directory = Path(run_dir) / ("evidence-" + _uuid(operation))
    _check_fence(manifest, verify_fence)
    durable._mkdir(directory)
    previous = None if not events else sha256(durable._read(
        directory / f"{len(events)-1:06d}.json", maximum=MAX_RECORD)[0])
    event = {"version": VERSION, "sequence": len(events), "previous_sha256": previous,
             "manifest_sha256": manifest_hash, "operation_id": _uuid(operation), "evidence": evidence}
    _check_fence(manifest, verify_fence)
    (_publish_atomic if atomic else _publish)(directory / f"{len(events):06d}.json", encode(event))
    _check_fence(manifest, verify_fence)
    return read_evidence(run_dir, operation)[-1]


def record_dispatch(run_dir, operation, *, verify_fence, atomic=False):
    """Record one dispatch before forwarding persisted bytes; never grant replay."""
    events = read_evidence(run_dir, operation)
    _require(not any(e["evidence"]["kind"] in ("dispatch", "committed") for e in events),
             "redispatch_requires_reconciliation")
    manifest, _ = read_manifest(run_dir)
    native_raw, _ = read_intent(run_dir, operation)
    _append(run_dir, operation, {"kind": "dispatch", "request_sha256": sha256(native_raw),
                                "fencing": manifest["fencing"]}, verify_fence, atomic=atomic)
    return native_raw


def record_response(run_dir, operation, response, *, verify_fence, atomic=False):
    """Append a content-free native receipt/status observation, not raw MCP prose."""
    response = _json(encode(response))
    events = read_evidence(run_dir, operation)
    _, request = read_intent(run_dir, operation)
    receipts = [e["evidence"]["receipt"] for e in events if e["evidence"]["kind"] == "committed"]
    _response(response, request, receipts[-1] if receipts else None)
    return _append(run_dir, operation, response, verify_fence, atomic=atomic)
