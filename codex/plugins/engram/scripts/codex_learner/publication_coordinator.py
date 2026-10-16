"""Publish one frozen learner transition and acknowledge its original queue slot.

The caller holds worker -> enqueue locks throughout every API call. Trusted
Paths, mandatory exact-True validators, and immutable input/run evidence supply
authority; neither a journal nor a missing queue file supplies it. This module
never runs a provider, reconstructs a cursor, or clears an unjournaled hold.

An O_EXCL active index pins a complete ticket before pair publication. Partial
indexes fail closed; unindexed tickets are inert. A durable ack-intent precedes
any pending mutation. Completed evidence is retained forever; only its exact
active index is unlinked. The next transition can then start for the same request.
"""
from __future__ import annotations

import copy
from dataclasses import dataclass
import os
from pathlib import Path
import uuid

from . import admission, migration as durable, publication_journal as publication

MAX_TICKET = publication.MAX_JOURNAL_BYTES


@dataclass(frozen=True)
class Paths:
    state: Path
    admission: Path
    pending: Path
    session_directory: Path


def _require(ok, reason):
    if not ok:
        raise ValueError("publication_coordinator_" + reason)


def _boundary(label):
    """Isolated fixture crash seam; not an execution or authorization hook."""


def _same(left, right):
    return durable.encode(left) == durable.encode(right)


def _uuid(value):
    try:
        _require(type(value) is str and str(uuid.UUID(value, version=4)) == value, "invalid_ticket_id")
    except (ValueError, TypeError, AttributeError):
        raise ValueError("publication_coordinator_invalid_ticket_id") from None


def _paths(paths, session_id, *, create=False):
    _require(type(paths) is Paths, "invalid_paths")
    publication._identifier(session_id)
    for path in (paths.state, paths.admission, paths.pending, paths.session_directory):
        _require(type(path) is type(Path()) and path.is_absolute(), "invalid_paths")
        durable._directory(path.parent)
        _require(path.name not in ("", ".", ".."), "invalid_paths")
    _require(len({paths.state, paths.admission, paths.pending}) == 3
             and all(path.name == session_id + ".json" for path in (paths.state, paths.admission, paths.pending))
             and paths.session_directory.name == session_id, "path_binding_changed")
    _require(not paths.session_directory.is_symlink(), "unsafe_directory")
    if create:
        durable._mkdir(paths.session_directory)
        for name in ("tickets", "journals", "records"):
            durable._mkdir(paths.session_directory / name)
    if os.path.lexists(paths.session_directory):
        _require(not durable._directory(paths.session_directory).st_mode & 0o077, "directory_not_private")
        active = os.path.lexists(paths.session_directory / "active.json")
        for name in ("tickets", "journals", "records"):
            child = paths.session_directory / name
            # Container creation precedes all authority. A crash between these
            # mkdirs leaves no active ticket and may safely be completed by the
            # next start; never adopt an orphan ticket or journal in doing so.
            if not os.path.lexists(child) and not active:
                continue
            _require(not durable._directory(child).st_mode & 0o077,
                     "directory_not_private")
    return {name: str(getattr(paths, name)) for name in paths.__dataclass_fields__}


def _journal(paths, ticket_id):
    return publication.Paths(paths.state, paths.admission, paths.session_directory / "journals" / ticket_id)


def _ticket_path(paths, ticket_id):
    return paths.session_directory / "tickets" / (ticket_id + ".json")


def _record_path(paths, ticket_id, name):
    return paths.session_directory / "records" / ticket_id / (name + ".json")


def _json(raw):
    return admission._json(raw)


def _read(path, *, absent=False):
    return durable._read(path, absent=absent, maximum=MAX_TICKET)


def _new(path, raw, label):
    _require(len(raw) <= MAX_TICKET, "record_too_large")
    durable._directory(path.parent)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        _boundary(label + "_created")
        rest = memoryview(raw)
        while rest:
            written = os.write(fd, rest)
            _require(written > 0, "short_write")
            rest = rest[written:]
        _boundary(label + "_written")
        os.fsync(fd)
        _boundary(label + "_file_fsynced")
    finally:
        os.close(fd)
    durable._fsync(path.parent)
    _boundary(label + "_directory_fsynced")


def _immutable(path, value, label):
    """Install a complete record; partial staging files are never authoritative."""
    raw = durable.encode(value)
    current, _ = _read(path, absent=True)
    if current is not None:
        _require(current == raw, "immutable_record_changed")
        publication._sync_existing(path, raw)
        return raw
    stage = path.parent / ("." + label + "-" + uuid.uuid4().hex)
    _new(stage, raw, label + "_stage")
    _require(not os.path.lexists(path), "immutable_record_appeared")
    _require(_read(stage)[0] == raw, "staging_changed")
    os.replace(stage, path)  # All cooperating writers hold worker -> enqueue.
    _boundary(label + "_installed")
    durable._fsync(path.parent)
    _boundary(label + "_directory_fsynced")
    return raw


def _outcome(value):
    _require(type(value) is dict and set(value) == {"result", "queue_action", "pause_reason"}, "invalid_outcome")
    _require(value["result"] in {"processing", "succeeded", "no_change", "more", "failed",
                                 "reconciliation_required", "backoff", "blocked", "deferred"}, "invalid_outcome")
    _require(value["queue_action"] in {"none", "delete", "pause", "keep"}, "invalid_outcome")
    expected_action = {"processing": "none", "more": "keep", "succeeded": "delete", "no_change": "delete",
                       "deferred": "delete", "failed": "pause", "reconciliation_required": "pause",
                       "backoff": "pause", "blocked": "pause"}
    _require(value["queue_action"] == expected_action[value["result"]], "outcome_action_mismatch")
    if value["queue_action"] == "pause":
        _require(value["pause_reason"] == value["result"], "invalid_pause_reason")
    else:
        _require(value["pause_reason"] is None, "invalid_outcome")
    _require((value["queue_action"] == "none") == (value["result"] == "processing"), "invalid_marker_outcome")


def _pending(raw, session_id):
    value = _json(raw)
    _require(type(value) is dict and value.get("session_id") == session_id, "invalid_pending")
    publication._identifier(value.get("request_id"))
    return value


def _ticket(ticket, paths, session_id):
    _require(type(ticket) is dict and set(ticket) == {"version", "ticket_id", "session_id", "request_id",
             "binding", "paths", "prepared_sha256", "input_evidence", "run_evidence", "outcome", "pending"},
             "invalid_ticket")
    _require(type(ticket["version"]) is int and ticket["version"] == 1, "invalid_ticket")
    _uuid(ticket["ticket_id"])
    publication._identifier(ticket["request_id"])
    publication._sha(ticket["prepared_sha256"])
    _require(ticket["session_id"] == session_id and ticket["paths"] == _paths(paths, session_id),
             "ticket_binding_changed")
    _require(type(ticket["binding"]) is dict and ticket["binding"].get("session_id") == session_id
             and type(ticket["input_evidence"]) is dict and bool(ticket["input_evidence"])
             and (ticket["run_evidence"] is None or type(ticket["run_evidence"]) is dict), "invalid_evidence")
    _outcome(ticket["outcome"])
    original = _pending(publication._raw(ticket["pending"], old=True), session_id)
    _require(original["request_id"] == ticket["request_id"]
             and _same(original.get("admission"), ticket["binding"]), "pending_binding_changed")


def _plan(paths, ticket):
    plan = publication._load(_journal(paths, ticket["ticket_id"]), ticket["prepared_sha256"],
                             ticket["session_id"], ticket["request_id"], ticket["binding"])
    if ticket["outcome"]["result"] == "processing":
        _marker(ticket, plan)
    return plan


def _marker(ticket, plan):
    _require(publication._raw(plan["records"]["state"]["old"], old=True)
             == publication._raw(plan["records"]["state"]["new"]), "marker_changes_state")
    old = _json(publication._raw(plan["records"]["admission"]["old"], old=True))
    new = _json(publication._raw(plan["records"]["admission"]["new"]))
    evidence = ticket["run_evidence"]
    _require(type(evidence) is dict and {"run_id", "manifest_sha256"} <= set(evidence), "marker_missing_run")
    publication._identifier(evidence["run_id"])
    publication._sha(evidence["manifest_sha256"])
    execution = {key: evidence[key] for key in ("run_id", "manifest_sha256")}
    _require(old.get("processing") is None and "processing_execution" not in old
             and _same(new, {**old, "processing": ticket["request_id"], "processing_execution": execution}),
             "invalid_marker_transition")


def _validate(validate, ticket, plan, phase):
    _require(callable(validate), "validator_required")
    view = {**ticket, "publication": plan}
    _require(validate(copy.deepcopy(view), phase) is True, "validation_refused")


def _active(paths, session_id):
    _paths(paths, session_id)
    if not os.path.lexists(paths.session_directory):
        return None
    path = paths.session_directory / "active.json"
    raw, identity = _read(path, absent=True)
    if raw is None:
        return None
    index = _json(raw)
    _require(type(index) is dict and set(index) == {"ticket_id", "ticket_sha256"}
             and durable.encode(index) == raw, "invalid_active_index")
    _uuid(index["ticket_id"])
    publication._sha(index["ticket_sha256"])
    ticket_raw, _ = _read(_ticket_path(paths, index["ticket_id"]))
    _require(durable.digest(ticket_raw) == index["ticket_sha256"], "ticket_digest_changed")
    ticket = _json(ticket_raw)
    _ticket(ticket, paths, session_id)
    _require(ticket["ticket_id"] == index["ticket_id"] and durable.encode(ticket) == ticket_raw, "invalid_ticket")
    return ticket, index, raw, identity


def _guard_active(paths, active):
    _require(_read(paths.session_directory / "active.json") == (active[2], active[3]), "active_changed")
    _require(_read(_ticket_path(paths, active[0]["ticket_id"]))[0] == durable.encode(active[0]), "ticket_changed")
    _require(durable.digest(_read(_journal(paths, active[0]["ticket_id"]).journal_directory / "prepared.json")[0])
             == active[0]["prepared_sha256"], "prepared_changed")


def _published(paths, ticket, plan):
    expected = {"schema_version": 1, "kind": publication.KIND, "status": "published",
                "transition_id": ticket["ticket_id"], "session_id": ticket["session_id"],
                "request_id": ticket["request_id"], "prepared_sha256": ticket["prepared_sha256"],
                "admission_sha256": plan["records"]["admission"]["new"]["sha256"],
                "state_sha256": plan["records"]["state"]["new"]["sha256"]}
    path = _journal(paths, ticket["ticket_id"]).journal_directory / "published.json"
    raw, _ = _read(path, absent=True)
    if raw is None:
        return None
    _require(raw == durable.encode(expected), "published_receipt_changed")
    publication._sync_existing(path, raw)
    return expected


def _summary(active, status):
    ticket, index = active[:2]
    return {"ticket_id": ticket["ticket_id"], "ticket_sha256": index["ticket_sha256"],
            "outcome": copy.deepcopy(ticket["outcome"]), "status": status}


def start(paths, *, ticket_id, session_id, request_id, binding,
          expected_old_state_sha256, expected_old_admission_sha256, expected_pending_sha256,
          new_state, new_admission, input_evidence, run_evidence, outcome, validate,
          original_pending=None, completed_marker=None):
    """Freeze, pin and publish a new pair; leave queue acknowledgment explicit.

    `validate(view, phase)` sees a deep copy of the ticket plus `publication`
    plan. During journal_prepare the ticket's prepared_sha256 is still None.
    Every callback must return exactly True. A killed unindexed attempt is inert
    and cannot be adopted; callers use a fresh ticket ID after validating inputs.
    """
    path_binding = _paths(paths, session_id, create=True)
    _uuid(ticket_id)
    _require(_active(paths, session_id) is None, "active_conflict")
    # If a prior process died after unlink but before fsync, make the observed
    # empty active slot durable before another transition can occupy it.
    durable._fsync(paths.session_directory)
    publication._sha(expected_pending_sha256)
    pending_raw, pending_identity = durable._read(paths.pending)
    _require(durable.digest(pending_raw) == expected_pending_sha256, "pending_preimage_changed")
    pending_image = publication._image(pending_raw, pending_identity)
    if original_pending is not None or completed_marker is not None:
        _require(type(completed_marker) is dict and set(completed_marker) == {"ticket_id", "ticket_sha256"},
                 "invalid_marker_reference")
        marker = read_completed(paths, session_id=session_id, ticket_id=completed_marker["ticket_id"],
                                ticket_sha256=completed_marker["ticket_sha256"])["ticket"]
        _require(marker["outcome"]["result"] == "processing" and outcome["result"] != "processing"
                 and marker["request_id"] == request_id and _same(marker["binding"], binding)
                 and type(run_evidence) is dict and _same(run_evidence.get("marker"), completed_marker)
                 and all(run_evidence.get(key) == marker["run_evidence"][key]
                         for key in ("run_id", "manifest_sha256")), "marker_binding_changed")
        _require(original_pending is None or _same(original_pending, marker["pending"]), "original_pending_changed")
        pending_image = marker["pending"]
    draft = {"version": 1, "ticket_id": ticket_id, "session_id": session_id, "request_id": request_id,
             "binding": copy.deepcopy(binding), "paths": path_binding, "prepared_sha256": None,
             "input_evidence": copy.deepcopy(input_evidence), "run_evidence": copy.deepcopy(run_evidence),
             "outcome": copy.deepcopy(outcome), "pending": copy.deepcopy(pending_image)}
    # Validate every field before creating the journal; only its digest is not known yet.
    _ticket({**draft, "prepared_sha256": "0" * 64}, paths, session_id)
    _queue_position(paths, draft, _ack_intent(draft, "0" * 64), intent_exists=False)
    def before_prepare(plan, _phase):
        if outcome["result"] == "processing":
            _marker(draft, plan)
        _validate(validate, draft, plan, "journal_prepare")
        _require(_active(paths, session_id) is None, "active_conflict")
        _require(durable._read(paths.pending) == (pending_raw, pending_identity), "pending_preimage_changed")
        return True
    prepared = publication.prepare(_journal(paths, ticket_id), transition_id=ticket_id,
        session_id=session_id, request_id=request_id, binding=binding,
        expected_old_state_sha256=expected_old_state_sha256,
        expected_old_admission_sha256=expected_old_admission_sha256,
        new_state=new_state, new_admission=new_admission, validate=before_prepare,
        preserve_state_bytes=outcome["result"] == "processing")
    ticket = {**draft, "prepared_sha256": prepared}
    plan = _plan(paths, ticket)
    _validate(validate, ticket, plan, "before_ticket")
    _new(_ticket_path(paths, ticket_id), durable.encode(ticket), "ticket")
    durable._mkdir(paths.session_directory / "records" / ticket_id)
    _validate(validate, ticket, plan, "before_index")
    _require(_active(paths, session_id) is None, "active_conflict")
    _require(durable._read(paths.pending) == (pending_raw, pending_identity), "pending_preimage_changed")
    index = {"ticket_id": ticket_id, "ticket_sha256": durable.digest(durable.encode(ticket))}
    _new(paths.session_directory / "active.json", durable.encode(index), "index")
    return recover(paths, session_id=session_id, validate=validate)


def recover(paths, *, session_id, validate):
    """Finish only the active pinned publication; never acknowledge or replay."""
    active = _active(paths, session_id)
    if active is None:
        return None
    ticket = active[0]
    plan = _plan(paths, ticket)
    _validate(validate, ticket, plan, "recover_entry")
    _guard_active(paths, active)
    # Re-establish durability if the previous process died before its fsync.
    publication._sync_existing(_ticket_path(paths, ticket["ticket_id"]), durable.encode(ticket))
    publication._sync_existing(paths.session_directory / "active.json", active[2])
    if _published(paths, ticket, plan) is None:
        def validator(current, phase):
            _validate(validate, ticket, current, "journal_" + phase)
            _guard_active(paths, active)
            return True
        publication.publish(_journal(paths, ticket["ticket_id"]),
            expected_prepared_sha256=ticket["prepared_sha256"], session_id=session_id,
            request_id=ticket["request_id"], binding=ticket["binding"], validate=validator)
    else:
        # A newer enqueue may change last_event/pending after durable publication.
        # The validator checks current cursor and authoritative admission fields;
        # no pair file is republished once the immutable receipt exists.
        _validate(validate, ticket, plan, "already_published")
    _guard_active(paths, active)
    return _summary(active, "published")


def _ack_intent(ticket, ticket_sha):
    action = ticket["outcome"]["queue_action"]
    original = publication._raw(ticket["pending"], old=True)
    target = None
    if action == "pause":
        pending = _json(original)
        target = publication._image(durable.encode({**pending, "paused_request_id": ticket["request_id"],
                                                    "pause_reason": ticket["outcome"]["pause_reason"]}))
    elif action == "keep":
        target = publication._image(original)
    return {"version": 1, "ticket_id": ticket["ticket_id"], "ticket_sha256": ticket_sha,
            "action": action, "original": ticket["pending"], "target": target}


def _queue_position(paths, ticket, intent, *, intent_exists):
    if intent["action"] == "none":
        return "none", None, None
    raw, identity = durable._read(paths.pending, absent=True)
    old = publication._raw(intent["original"], old=True)
    if raw == old and identity == intent["original"]["identity"]:
        return "original", raw, identity
    if raw is None:
        _require(intent_exists and intent["action"] == "delete", "pending_missing_without_ack")
        return "target", None, None
    current = _pending(raw, ticket["session_id"])
    if current["request_id"] != ticket["request_id"]:
        return "newer", raw, identity
    if intent_exists and intent["action"] == "pause" and raw == publication._raw(intent["target"]):
        return "target", raw, identity
    raise ValueError("publication_coordinator_pending_changed")


def _complete(paths, active, plan, intent, position):
    disposition, raw, identity = position
    published = _published(paths, active[0], plan)
    _require(published is not None, "published_receipt_missing")
    return {"version": 1, "ticket_id": active[0]["ticket_id"], "ticket_sha256": active[1]["ticket_sha256"],
            "published_sha256": durable.digest(durable.encode(published)),
            "ack_intent_sha256": durable.digest(durable.encode(intent)),
            "outcome": active[0]["outcome"], "disposition": disposition,
            "pending": None if raw is None else publication._image(raw, identity)}


def _check_completion(paths, active, plan, intent, raw):
    completion = _json(raw)
    _require(type(completion) is dict and set(completion) == {"version", "ticket_id", "ticket_sha256",
             "published_sha256", "ack_intent_sha256", "outcome", "disposition", "pending"}, "invalid_completion")
    position = (completion["disposition"], None, None)
    _require(position[0] in {"none", "original", "target", "newer"}, "invalid_completion")
    if completion["pending"] is not None:
        position = (position[0], publication._raw(completion["pending"], old=True), completion["pending"]["identity"])
    _require(raw == durable.encode(_complete(paths, active, plan, intent, position)), "completion_changed")
    return completion


def read_completed(paths, *, session_id, ticket_id, ticket_sha256):
    """Read caller-pinned historical evidence, never adopt a current pair or replay.

    The caller must independently authenticate this reference as its run's
    marker. Complete publication, acknowledgment and completion are checked.
    """
    _paths(paths, session_id)
    _uuid(ticket_id)
    publication._sha(ticket_sha256)
    raw, _ = _read(_ticket_path(paths, ticket_id))
    _require(durable.digest(raw) == ticket_sha256, "ticket_digest_changed")
    ticket = _json(raw)
    _ticket(ticket, paths, session_id)
    _require(ticket["ticket_id"] == ticket_id and durable.encode(ticket) == raw, "invalid_ticket")
    active = (ticket, {"ticket_id": ticket_id, "ticket_sha256": ticket_sha256})
    plan = _plan(paths, ticket)
    _require(_published(paths, ticket, plan) is not None, "published_receipt_missing")
    intent = _ack_intent(ticket, ticket_sha256)
    _require(_read(_record_path(paths, ticket_id, "ack-intent"))[0] == durable.encode(intent), "ack_intent_changed")
    completion = _check_completion(paths, active, plan, intent, _read(_record_path(paths, ticket_id, "completion"))[0])
    return copy.deepcopy({"ticket": ticket, "publication": plan, "completion": completion})


def acknowledge(paths, *, session_id, validate):
    """Durably acknowledge the frozen outcome, then retire its exact active index.

    A different request is preserved. Same-ID unrelated changes refuse. Missing
    pending is accepted as our delete only after a complete durable ack-intent.
    Returns None if no active ticket; it never reconstructs or restarts work.
    """
    if recover(paths, session_id=session_id, validate=validate) is None:
        return None
    active = _active(paths, session_id)
    _require(active is not None, "active_disappeared")
    ticket = active[0]
    plan = _plan(paths, ticket)
    intent = _ack_intent(ticket, active[1]["ticket_sha256"])
    intent_path = _record_path(paths, ticket["ticket_id"], "ack-intent")
    complete_path = _record_path(paths, ticket["ticket_id"], "completion")
    complete_raw, _ = _read(complete_path, absent=True)
    intent_raw, _ = _read(intent_path, absent=True)
    if complete_raw is None:
        _validate(validate, ticket, plan, "before_ack_intent")
        _guard_active(paths, active)
        if intent_raw is not None:
            _require(intent_raw == durable.encode(intent), "ack_intent_changed")
        _queue_position(paths, ticket, intent, intent_exists=intent_raw is not None)
        _immutable(intent_path, intent, "ack_intent")
        _validate(validate, ticket, plan, "before_ack")
        _guard_active(paths, active)
        _require(_read(intent_path)[0] == durable.encode(intent), "ack_intent_changed")
        position = _queue_position(paths, ticket, intent, intent_exists=True)
        if position[0] == "original" and intent["action"] in {"delete", "pause"}:
            stage = None
            if intent["action"] == "pause":
                stage = paths.pending.parent / (".ack-pause-" + uuid.uuid4().hex)
                _new(stage, publication._raw(intent["target"]), "ack_pending_stage")
            _validate(validate, ticket, plan, "replace_pending")
            _guard_active(paths, active)
            _require(_read(intent_path)[0] == durable.encode(intent), "ack_intent_changed")
            _require(_queue_position(paths, ticket, intent, intent_exists=True) == position, "pending_changed")
            if stage is None:
                paths.pending.unlink()
            else:
                _require(_read(stage)[0] == publication._raw(intent["target"]), "staging_changed")
                os.replace(stage, paths.pending)
            _boundary("pending_mutated")
            durable._fsync(paths.pending.parent)
            _boundary("pending_directory_fsynced")
        position = _queue_position(paths, ticket, intent, intent_exists=True)
        if position[1] is not None:
            publication._sync_existing(paths.pending, position[1])
        elif intent["action"] == "delete":
            durable._fsync(paths.pending.parent)
        _validate(validate, ticket, plan, "before_completion")
        _guard_active(paths, active)
        _require(_queue_position(paths, ticket, intent, intent_exists=True) == position, "pending_changed")
        completion = _complete(paths, active, plan, intent, position)
        complete_raw = _immutable(complete_path, completion, "completion")
    else:
        # A completed acknowledgment is historical evidence; a newer queue slot
        # need not equal its snapshot and must never be deleted during retirement.
        _require(intent_raw == durable.encode(intent), "ack_intent_changed")
        completion = _check_completion(paths, active, plan, intent, complete_raw)
        publication._sync_existing(complete_path, complete_raw)
    _validate(validate, ticket, plan, "before_retire")
    _guard_active(paths, active)
    _require(_read(complete_path)[0] == complete_raw, "completion_changed")
    _boundary("before_retire")
    (paths.session_directory / "active.json").unlink()
    _boundary("active_unlinked")
    durable._fsync(paths.session_directory)
    _boundary("active_directory_fsynced")
    return {**_summary(active, "completed"), "disposition": completion["disposition"]}
