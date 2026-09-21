"""Explicit, selected-task host identity migration; never enqueue or run a learner.

Plans contain exact private preimages and candidates. A caller must review and pin
the plan SHA256 before apply/recover/release. Publication uses a durable journal,
a disabled transitional policy, holds, task records, route, then final policy. Recovery only
completes the same expected publication prefix; it never rolls back newer state.
Legacy volume continuity is deliberately NOT asserted by current UUID adoption.
"""
from __future__ import annotations

import argparse
import base64
import copy
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat

from . import admission, file_identity, host_admission

MAX_SELECTED = 32
MAX_PLAN_BYTES = 32 * 1024 * 1024
MODE_V1 = "host_sessions_v1"
MODE_V2 = "host_sessions_v2"
PLAN_KIND = "selected_host_identity_migration"
HOLD_KIND = "identity_migration_hold"
ORDER = "transitional_policy_then_holds_then_selected_records_then_route_then_final_policy"


def require(ok, reason):
    if not ok:
        raise ValueError("migration_" + reason)


def encode(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"),
                       ensure_ascii=False, allow_nan=False) + "\n").encode()


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def object_digest(value):
    # Match runner.admission_digest without importing the worker/provider module.
    return digest(encode(value)[:-1])


def _b64(raw):
    return None if raw is None else base64.b64encode(raw).decode("ascii")


def _unb64(value):
    if value is None:
        return None
    require(isinstance(value, str), "invalid_encoded_bytes")
    try:
        raw = base64.b64decode(value, validate=True)
    except (ValueError, TypeError) as error:
        raise ValueError("migration_invalid_encoded_bytes") from error
    require(_b64(raw) == value and len(raw) <= admission.MAX_BYTES, "invalid_encoded_bytes")
    return raw


def _canonical(path):
    path = Path(path)
    require(path.is_absolute() and str(path) == str(path.resolve(strict=True)), "noncanonical_path")
    return path


def _directory(path):
    path = _canonical(path)
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
            and not info.st_mode & 0o022, "unsafe_directory")
    return info


def _identity(info):
    return {"device": info.st_dev, "inode": info.st_ino, "uid": info.st_uid,
            "gid": info.st_gid, "mode": info.st_mode, "size": info.st_size,
            "mtime_ns": info.st_mtime_ns, "ctime_ns": info.st_ctime_ns,
            "nlink": info.st_nlink}


def _read(path, *, absent=False, private=True, maximum=admission.MAX_BYTES):
    """Descriptor-bound, bounded read with exact ownership and replacement checks."""
    path = Path(path)
    _directory(path.parent)
    try:
        before = path.lstat()
    except FileNotFoundError:
        require(absent, "missing_file")
        return None, None
    require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
            and before.st_nlink == 1 and (not private or not before.st_mode & 0o077), "unsafe_file")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        require(_identity(os.fstat(fd)) == _identity(before), "file_changed")
        require(before.st_size <= maximum, "file_too_large")
        chunks, remaining = [], maximum + 1
        while remaining:
            data = os.read(fd, min(remaining, 65536))
            if not data:
                break
            chunks.append(data)
            remaining -= len(data)
        raw = b"".join(chunks)
        require(len(raw) <= maximum and _identity(os.fstat(fd)) == _identity(before)
                == _identity(path.lstat()), "file_changed")
        return raw, _identity(before)
    finally:
        os.close(fd)


def _fsync(directory):
    fd = os.open(directory, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _new(path, raw):
    _directory(path.parent)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        with os.fdopen(fd, "wb", closefd=False) as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(fd)
    finally:
        os.close(fd)
    _fsync(path.parent)


def _mkdir(path):
    _directory(path.parent)
    try:
        path.mkdir(mode=0o700)
        _fsync(path.parent)
    except FileExistsError:
        pass
    require(not _directory(path).st_mode & 0o077, "journal_directory_not_private")


class Locks:
    """Never create or chmod app locks. Dry planning changes no application bytes."""
    def __init__(self, root):
        self.paths = [root / "worker.lock", root.parent / "learner-provider.lock", root / "enqueue.lock"]
        self.held = []

    def __enter__(self):
        try:
            for path in self.paths:
                _directory(path.parent)
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
                try:
                    info = os.fstat(fd)
                    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                            and info.st_nlink == 1 and not info.st_mode & 0o077, "unsafe_lock")
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BaseException:
                    os.close(fd)
                    raise
                self.held.append((path, fd, _identity(info)))
                self.verify()
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def verify(self):
        for path, fd, expected in self.held:
            require(_identity(path.lstat()) == _identity(os.fstat(fd)) == expected, "lock_changed")

    def __exit__(self, *_):
        while self.held:
            _, fd, _ = self.held.pop()
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)


def _runtime():
    here = Path(__file__).resolve().parent
    files = sorted(here.glob("*.py")) + [here.parent / "learner_router.py", here.parent / "codex_learner_migrate.py"]
    require(1 <= len(files) <= 32, "runtime_membership_invalid")
    return {str(path.relative_to(here.parent)): digest(_read(path, private=False)[0]) for path in files}


def _root(root):
    root = _canonical(root)
    require(not _directory(root).st_mode & 0o077, "state_directory_not_private")
    for name in ("enrollments", "admissions", "sessions", "pending"):
        require(not _directory(root / name).st_mode & 0o077, "state_directory_not_private")
    return root


def _policy(value, root, stable):
    require(set(value) == {"schema_version", "mode", "enabled", "activation_id", "cutoff",
                           "state_dir", "sessions_dir"}, "invalid_policy")
    require(type(value["schema_version"]) is int and value["schema_version"] == (2 if stable else 1)
            and value["mode"] == (MODE_V2 if stable else MODE_V1)
            and type(value["enabled"]) is bool and value["state_dir"] == str(root), "invalid_policy")
    admission._uuid(value["activation_id"], 4)
    require(admission._timestamp(value["cutoff"]) <= datetime.now(timezone.utc), "future_cutoff")
    if stable:
        admission._bound_directory(value["sessions_dir"], stable_identity=True)
    else:
        _adopt_directory(value["sessions_dir"])


def _adopt_directory(old):
    require(isinstance(old, dict) and set(old) == {"path", "device", "inode"}
            and all(type(old[k]) is int and old[k] > 0 for k in ("device", "inode")), "invalid_legacy_directory")
    actual = admission._directory_binding(old["path"], stable_identity=True)
    require(actual["identity"]["inode"] == old["inode"], "legacy_directory_inode_changed")
    return actual


def _route(value, root, stable):
    require(set(value) == {"schema_version", "mode", "enabled", "state_dir"}
            and type(value["schema_version"]) is int and value["schema_version"] == (2 if stable else 1)
            and value["mode"] == (MODE_V2 if stable else MODE_V1)
            and type(value["enabled"]) is bool and value["state_dir"] == str(root), "invalid_route")


def _paths(root, sid):
    admission._uuid(sid, 7)
    return {name: root / name / (sid + ".json") for name in ("enrollments", "sessions", "admissions", "pending")}


def _binding(entry, policy, policy_raw):
    return {**entry, "cutoff": policy["cutoff"], "policy_sha256": digest(policy_raw),
            "state_dir": policy["state_dir"], "mode": policy["mode"]}


def _replace_identity(value, entry):
    require(value.get("device") == entry["device"] and value.get("inode") == entry["inode"]
            and "identity" not in value, "legacy_transcript_binding_invalid")
    result = copy.deepcopy(value)
    del result["device"], result["inode"]
    return result


def _task_candidates(root, sid, before, legacy, legacy_raw, target, target_raw):
    """Validate old chain and current anchors, changing only durable identity fields."""
    entry = admission._json(before["enrollments"])
    require(entry.get("session_id") == sid and type(entry.get("device")) is int
            and type(entry.get("inode")) is int and entry["inode"] > 0
            and entry.get("uid") == os.getuid() and entry.get("activation_id") == legacy["activation_id"],
            "legacy_enrollment_invalid")
    payload = {"session_id": sid, "transcript_path": entry.get("transcript_path"),
               "cwd": entry.get("project", {}).get("path"), "agent_id": sid}
    origin = host_admission._origin(target, payload)
    require(origin["identity"]["inode"] == entry["inode"], "legacy_transcript_inode_changed")
    project = _adopt_directory(entry["project"])
    require(project == origin["project"], "project_identity_changed")
    adopted = _replace_identity(entry, entry)
    adopted.update(identity=origin["identity"], project=project)
    require(set(adopted) == set(origin) | admission.FRONTIER_FIELDS | {"captured_at", "activation_id"}
            and all(adopted[k] == value for k, value in origin.items()), "legacy_origin_changed")
    captured = admission._timestamp(entry["captured_at"])
    require(admission._timestamp(legacy["cutoff"]) <= captured <= datetime.now(timezone.utc), "capture_time_invalid")
    frontier = admission._frontier(origin, entry["frontier_offset"])
    require(all(entry[k] == value for k, value in frontier.items()), "legacy_frontier_changed")
    old_binding = _binding(entry, legacy, legacy_raw)
    new_binding = _binding(adopted, target, target_raw)
    result = {"enrollments": encode(adopted), "sessions": None, "admissions": None, "pending": None}
    record_raw, state_raw, request_raw = (before[n] for n in ("admissions", "sessions", "pending"))
    if record_raw is None:
        require(state_raw is None and request_raw is None, "orphan_state")
        return result
    require(state_raw is not None, "cursor_missing")
    record, state = admission._json(record_raw), admission._json(state_raw)
    require({"binding", "state_sha256", "processing", "last_event"} <= set(record)
            and record["processing"] is None and record["binding"] == old_binding, "record_binding_or_processing_invalid")
    require(record["state_sha256"] == object_digest(state) and state.get("admission") == old_binding
            and state.get("session_id") == sid and state.get("transcript_path") == entry["transcript_path"]
            and type(state.get("offset")) is int and state["offset"] >= entry["frontier_offset"], "cursor_chain_invalid")
    require(state["offset"] <= Path(entry["transcript_path"]).stat().st_size, "cursor_truncated")
    new_state = _replace_identity(state, entry)
    new_state.update(identity=origin["identity"], admission=new_binding)
    new_record = {**record, "binding": new_binding, "state_sha256": object_digest(new_state)}
    require("legacy_event_identity" not in record, "legacy_event_identity_already_present")
    if record["last_event"] is not None:
        require(isinstance(record["last_event"], str) and re.fullmatch(r"[0-9a-f]{64}", record["last_event"]), "last_event_invalid")
        new_record["legacy_event_identity"] = {"device": entry["device"], "inode": entry["inode"]}
    result.update(sessions=encode(new_state), admissions=encode(new_record))
    if request_raw is not None:
        request = admission._json(request_raw)
        require(request.get("admission") == old_binding and request.get("session_id") == sid
                and request.get("transcript_path") == entry["transcript_path"]
                and request.get("cwd") == request.get("hook_cwd") == entry["project"]["path"]
                and isinstance(request.get("request_id"), str) and bool(request["request_id"])
                and request.get("event") in host_admission.LEARN_EVENTS, "request_chain_invalid")
        if request["event"] == "Stop":
            require(isinstance(request.get("turn_id"), str) and re.fullmatch(r"[A-Za-z0-9_-]{1,100}", request["turn_id"]), "request_turn_invalid")
        if request["event"] == "PreCompact":
            require(request.get("trigger") == "auto", "request_trigger_invalid")
        # Validate hook attribution through the maintained metadata parser.
        hook_payload = {"session_id": request.get("hook_session_id"), "transcript_path": entry["transcript_path"],
                        "cwd": request["hook_cwd"], "agent_id": sid}
        require(host_admission._origin(target, hook_payload) == origin, "request_origin_invalid")
        new_request = _replace_identity(request, entry)
        new_request.update(identity=origin["identity"], admission=new_binding)
        result["pending"] = encode(new_request)
    return result


def _record(path, before, info, after):
    return {"path": str(path), "preimage": _b64(before), "preimage_sha256": None if before is None else digest(before),
            "preimage_identity": info, "candidate": _b64(after), "candidate_sha256": None if after is None else digest(after)}


def _retained_legacy(root, path, legacy_raw, current_policy_raw):
    """Later migrations must use the original bytes retained by a prior journal."""
    require(path.name == "legacy-policy.json" and path.parent.parent == root / "migrations"
            and re.fullmatch(r"[0-9a-f]{64}", path.parent.name), "legacy_policy_not_retained_journal")
    raw, _ = _read(path.parent / "plan.json", maximum=MAX_PLAN_BYTES)
    require(digest(raw) == path.parent.name, "retained_plan_digest_changed")
    old_plan = admission._json(raw)
    require(raw == encode(old_plan) and old_plan.get("kind") == PLAN_KIND
            and old_plan.get("root") == str(root)
            and _unb64(old_plan["legacy_policy"]["bytes"]) == legacy_raw
            and old_plan["legacy_policy"]["sha256"] == digest(legacy_raw)
            and old_plan["records"][-1]["path"] == str(root / "admission.json")
            and _unb64(old_plan["records"][-1]["candidate"]) == current_policy_raw,
            "retained_policy_lineage_changed")


def _build(root, route_path, session_ids, legacy_policy_path):
    policy_raw, policy_info = _read(root / "admission.json")
    current = admission._json(policy_raw)
    stable = current.get("mode") == MODE_V2
    _policy(current, root, stable)
    route_raw, route_info = _read(route_path)
    route = admission._json(route_raw)
    _route(route, root, stable)
    if legacy_policy_path is None:
        require(not stable, "retained_legacy_policy_required")
        legacy_raw, legacy_info = policy_raw, policy_info
        legacy_path = root / "admission.json"
    else:
        legacy_path = _canonical(legacy_policy_path)
        legacy_raw, legacy_info = _read(legacy_path)
    legacy = admission._json(legacy_raw)
    _policy(legacy, root, False)
    require(all(current[k] == legacy[k] for k in ("activation_id", "cutoff", "state_dir", "enabled")), "foreign_legacy_policy")
    target = {**legacy, "schema_version": 2, "mode": MODE_V2,
              "sessions_dir": _adopt_directory(legacy["sessions_dir"])}
    if stable:
        require(current == target, "current_policy_lineage_changed")
        _retained_legacy(root, legacy_path, legacy_raw, policy_raw)
        target_raw = policy_raw  # Preserve exact existing v2 hash for every later selection.
    else:
        require(legacy_raw == policy_raw, "legacy_policy_not_current")
        target_raw = encode(target)
    route_after = route_raw if stable else encode({**route, "schema_version": 2, "mode": MODE_V2})
    records, holds = [], []
    for sid in session_ids:
        paths = _paths(root, sid)
        before, infos = {}, {}
        for name, path in paths.items():
            before[name], infos[name] = _read(path, absent=name != "enrollments")
        candidate = _task_candidates(root, sid, before, legacy, legacy_raw, target, target_raw)
        for name in paths:
            records.append(_record(paths[name], before[name], infos[name], candidate[name]))
        hold = root / "migration-holds" / (sid + ".json")
        require(not os.path.lexists(hold), "existing_migration_hold")
        holds.append(str(hold))
    records.append(_record(route_path, route_raw, route_info, route_after))
    records.append(_record(root / "admission.json", policy_raw, policy_info, target_raw))
    transition_raw = encode({**current, "enabled": False}) if current["enabled"] else policy_raw
    return {"schema_version": 1, "kind": PLAN_KIND, "root": str(root), "route_path": str(route_path),
            "session_ids": session_ids, "runtime_sha256": _runtime(), "records": records, "hold_paths": holds,
            "transitional_policy": _record(root / "admission.json", policy_raw, policy_info, transition_raw),
            "legacy_policy": {"path": str(legacy_path), "bytes": _b64(legacy_raw), "sha256": digest(legacy_raw), "identity": legacy_info},
            "historical_volume_continuity_proven": False, "owner_authorized_current_volume_adoption": True,
            "learner_started": False, "publication_order": ORDER}


def prepare(root, route_path, session_ids, *, legacy_policy_path=None, authorize_current_volume_adoption=False):
    require(authorize_current_volume_adoption is True, "explicit_identity_adoption_authorization_required")
    root, route_path = _root(root), _canonical(route_path)
    require(isinstance(session_ids, (list, tuple)) and 1 <= len(session_ids) <= MAX_SELECTED
            and len(set(session_ids)) == len(session_ids), "invalid_selection")
    selected = sorted(session_ids)
    for sid in selected:
        admission._uuid(sid, 7)
    with Locks(root) as locks:
        plan = _build(root, route_path, selected, legacy_policy_path)
        require(len(encode(plan)) <= MAX_PLAN_BYTES, "plan_too_large")
        require(plan == _build(root, route_path, selected, legacy_policy_path), "snapshot_changed")
        locks.verify()
        return plan


def _validate_plan(root, plan, expected_sha):
    require(isinstance(plan, dict) and len(encode(plan)) <= MAX_PLAN_BYTES
            and digest(encode(plan)) == expected_sha, "plan_sha_mismatch")
    require(set(plan) == {"schema_version", "kind", "root", "route_path", "session_ids", "runtime_sha256",
                         "records", "hold_paths", "legacy_policy", "historical_volume_continuity_proven",
                         "owner_authorized_current_volume_adoption", "learner_started", "publication_order", "transitional_policy"}
            and type(plan["schema_version"]) is int and plan["schema_version"] == 1
            and plan["kind"] == PLAN_KIND and plan["root"] == str(root)
            and plan["publication_order"] == ORDER
            and plan.get("owner_authorized_current_volume_adoption") is True
            and plan.get("historical_volume_continuity_proven") is False and plan.get("learner_started") is False,
            "invalid_plan")
    selected = plan.get("session_ids")
    require(isinstance(selected, list) and 1 <= len(selected) <= MAX_SELECTED
            and selected == sorted(set(selected)), "invalid_selection")
    expected_paths = [str(path) for sid in selected for path in _paths(root, sid).values()]
    route_path = Path(plan["route_path"])
    require(route_path.is_absolute() and route_path not in [Path(p) for p in expected_paths]
            and route_path != root / "admission.json", "invalid_route_path")
    expected_paths += [str(route_path), str(root / "admission.json")]
    require([r["path"] for r in plan["records"]] == expected_paths, "publication_paths_changed")
    require(plan["hold_paths"] == [str(root / "migration-holds" / (sid + ".json")) for sid in selected], "hold_paths_changed")
    require(plan["runtime_sha256"] == _runtime(), "runtime_changed")
    for record in plan["records"]:
        for raw_key, sha_key in (("preimage", "preimage_sha256"), ("candidate", "candidate_sha256")):
            raw = _unb64(record[raw_key])
            require(record[sha_key] == (None if raw is None else digest(raw)), "record_digest_changed")
        require((record["preimage"] is None) == (record["candidate"] is None)
                == (record["preimage_identity"] is None), "record_absence_changed")
    legacy = plan["legacy_policy"]
    require(digest(_unb64(legacy["bytes"])) == legacy["sha256"], "legacy_policy_digest_changed")
    legacy_path = Path(legacy["path"])
    if legacy_path != root / "admission.json":
        raw, identity = _read(legacy_path)
        require(raw == _unb64(legacy["bytes"]) and identity == legacy["identity"], "legacy_source_changed")
        if admission._json(_unb64(plan["records"][-1]["preimage"]))["mode"] == MODE_V2:
            _retained_legacy(root, legacy_path, raw, _unb64(plan["records"][-1]["preimage"]))
    _validate_candidates(root, plan)
    original_raw = _unb64(plan["records"][-1]["preimage"])
    original = admission._json(original_raw)
    transition = encode({**original, "enabled": False}) if original["enabled"] else original_raw
    require(plan["transitional_policy"] == _record(root / "admission.json", original_raw,
            plan["records"][-1]["preimage_identity"], transition), "transitional_policy_changed")


def _validate_candidates(root, plan):
    records = plan["records"]
    original = admission._json(_unb64(records[-1]["preimage"]))
    _policy(original, root, original.get("mode") == MODE_V2)
    target_raw = _unb64(records[-1]["candidate"])
    target = admission._json(target_raw)
    legacy_raw = _unb64(plan["legacy_policy"]["bytes"])
    legacy = admission._json(legacy_raw)
    _policy(legacy, root, False)
    _policy(target, root, True)
    require(target == {**legacy, "schema_version": 2, "mode": MODE_V2,
                       "sessions_dir": _adopt_directory(legacy["sessions_dir"])}, "policy_transformation_invalid")
    require(all(original[k] == legacy[k] for k in ("activation_id", "cutoff", "state_dir", "enabled")), "policy_lineage_invalid")
    if original["mode"] == MODE_V1:
        require(_unb64(records[-1]["preimage"]) == legacy_raw, "policy_lineage_invalid")
    else:
        require(records[-1]["preimage"] == records[-1]["candidate"], "stable_policy_must_not_change")
    route_before = admission._json(_unb64(records[-2]["preimage"]))
    route_after = admission._json(_unb64(records[-2]["candidate"]))
    _route(route_before, root, original["mode"] == MODE_V2)
    _route(route_after, root, True)
    require(route_after == {**route_before, "schema_version": 2, "mode": MODE_V2}, "route_transformation_invalid")
    for index, sid in enumerate(plan["session_ids"]):
        batch = records[index * 4:index * 4 + 4]
        before = {Path(r["path"]).parent.name: _unb64(r["preimage"]) for r in batch}
        expected = _task_candidates(root, sid, before, legacy, legacy_raw, target, target_raw)
        require(all(_unb64(r["candidate"]) == expected[Path(r["path"]).parent.name] for r in batch), "candidate_transformation_invalid")


def _hold(sid, plan_sha):
    return encode({"schema_version": 1, "kind": HOLD_KIND, "session_id": sid, "plan_sha256": plan_sha})


def _journal(root, plan, plan_sha, *, create):
    parent, work = root / "migrations", root / "migrations" / plan_sha
    if create:
        _mkdir(parent)
        _mkdir(work)
    else:
        require(not _directory(work).st_mode & 0o077, "journal_not_private")
    files = {"plan.json": encode(plan), "legacy-policy.json": _unb64(plan["legacy_policy"]["bytes"])}
    for name, raw in files.items():
        path = work / name
        if create and not os.path.lexists(path):
            _new(path, raw)
        require(_read(path, maximum=MAX_PLAN_BYTES)[0] == raw, "journal_changed")
    return work


def _event(work, label, **fields):
    # Individual O_EXCL journal records avoid silently appending to a replaced log.
    existing = list(work.glob("event-*.json"))
    require(len(existing) < 10000, "journal_full")
    _new(work / ("event-%05d.json" % (len(existing) + 1)), encode({"event": label, **fields}))


def _match(record, *, recover):
    raw, info = _read(Path(record["path"]), absent=record["preimage"] is None)
    before, after = _unb64(record["preimage"]), _unb64(record["candidate"])
    if raw == before and (before is None or info == record["preimage_identity"]):
        return "before"
    require(recover and raw == after and before is not None, "cas_mismatch")
    return "after"


def _policy_phase(plan, *, recover):
    final = plan["records"][-1]
    raw, info = _read(Path(final["path"]))
    original, transition, candidate = (_unb64(final["preimage"]),
                                      _unb64(plan["transitional_policy"]["candidate"]),
                                      _unb64(final["candidate"]))
    if raw == original and info == final["preimage_identity"]:
        # An already disabled original is the safe transition without a rewrite.
        return "transition" if original == transition else "original"
    require(recover, "cas_mismatch")
    if raw == candidate:
        return "final"
    require(raw == transition, "policy_cas_mismatch")
    return "transition"


def _verify_prefix(plan, *, recover):
    states = [_match(r, recover=recover) for r in plan["records"][:-1]]
    phase = _policy_phase(plan, recover=recover)
    remaining = False
    published = False
    for state, record in zip(states, plan["records"][:-1]):
        if record["preimage"] == record["candidate"]:
            continue
        if state == "before":
            remaining = True
        else:
            require(not remaining, "nonprefix_publication")
            published = True
    require(not published or phase != "original", "records_published_without_transition")
    require(phase != "final" or not remaining, "final_policy_published_before_records")
    return states + ["after" if phase == "final" else "before"]


def _publish(record, work, index):
    path = Path(record["path"])
    raw = _unb64(record["candidate"])
    _match(record, recover=False)
    temporary = path.parent / (".identity-migration-" + work.name + "-" + str(index))
    if os.path.lexists(temporary):
        require(_read(temporary)[0] == raw, "staging_file_changed")
    else:
        _new(temporary, raw)
    _match(record, recover=False)
    os.replace(temporary, path)
    _fsync(path.parent)
    require(_read(path)[0] == raw, "publication_changed")


def _publish_policy(plan, work, *, final):
    """CAS the shared path against its precise current stage, never a rollback."""
    target = plan["records"][-1] if final else plan["transitional_policy"]
    path = Path(target["path"])
    expected = _unb64(plan["transitional_policy"]["candidate"] if final else target["preimage"])
    raw, info = _read(path)
    require(raw == expected, "policy_stage_changed")
    after = _unb64(target["candidate"])
    if raw == after:
        return
    record = _record(path, raw, info, after)
    _publish(record, work, "final-policy" if final else "transitional-policy")


def _run(root, plan, plan_sha, *, recovery):
    root = _root(root)
    with Locks(root) as locks:
        _validate_plan(root, plan, plan_sha)
        states = _verify_prefix(plan, recover=recovery)
        work = _journal(root, plan, plan_sha, create=not recovery)
        if _policy_phase(plan, recover=True) == "original":
            locks.verify()
            _event(work, "before_transitional_policy", candidate_sha256=plan["transitional_policy"]["candidate_sha256"])
            _publish_policy(plan, work, final=False)
            _event(work, "transitional_policy_published", candidate_sha256=plan["transitional_policy"]["candidate_sha256"])
        _mkdir(root / "migration-holds")
        # All holds must be durable before the first task record can change.
        for sid, path in zip(plan["session_ids"], plan["hold_paths"]):
            path, expected = Path(path), _hold(sid, plan_sha)
            if os.path.lexists(path):
                require(_read(path)[0] == expected, "hold_changed")
            else:
                require(all(s == "before" or r["preimage"] == r["candidate"]
                            for s, r in zip(states[:-1], plan["records"][:-1])), "hold_missing_after_publication")
                _new(path, expected)
                _event(work, "hold_published", session_id=sid)
        for index, record in enumerate(plan["records"][:-1]):
            locks.verify()
            _validate_plan(root, plan, plan_sha)
            _verify_prefix(plan, recover=True)
            for sid, path in zip(plan["session_ids"], plan["hold_paths"]):
                require(_read(Path(path))[0] == _hold(sid, plan_sha), "hold_changed")
            if record["preimage"] == record["candidate"] or _match(record, recover=True) == "after":
                continue
            _event(work, "before_publish", index=index, path=record["path"], candidate_sha256=record["candidate_sha256"])
            _publish(record, work, index)
            _event(work, "published", index=index, path=record["path"], candidate_sha256=record["candidate_sha256"])
        locks.verify()
        _validate_plan(root, plan, plan_sha)
        _verify_prefix(plan, recover=True)
        if _policy_phase(plan, recover=True) != "final":
            _event(work, "before_final_policy", candidate_sha256=plan["records"][-1]["candidate_sha256"])
            _publish_policy(plan, work, final=True)
            _event(work, "final_policy_published", candidate_sha256=plan["records"][-1]["candidate_sha256"])
        _verify_complete(root, plan, plan_sha)
        locks.verify()
        _event(work, "complete", learner_started=False)
        return {"status": "migration_complete_held", "plan_sha256": plan_sha,
                "session_ids": plan["session_ids"], "learner_started": False,
                "historical_volume_continuity_proven": False}


def apply(root, plan, plan_sha256):
    return _run(root, plan, plan_sha256, recovery=False)


def recover(root, plan, plan_sha256):
    return _run(root, plan, plan_sha256, recovery=True)


def _known_releases(root, work, plan, plan_sha):
    result = set()
    intents = list(work.glob("release-*.json"))
    require(len(intents) <= MAX_SELECTED, "too_many_release_intents")
    for path in intents:
        raw, _ = _read(path)
        value = admission._json(raw)
        require(path.name == "release-" + digest(raw) + ".json" and raw == encode(value), "release_intent_changed")
        _validate_release(root, plan, plan_sha, value)
        result.update(value["session_ids"])
    return result


def _released_chain(root, plan, sid):
    """Read-only validation of a previously released task's legitimate progress.

    Enrollment and policy remain the exact migrated anchor. Cursor, gate, pending
    and processing metadata may advance after a separately authorized release.
    No such file is rewritten by this command. All unreleased tasks still require
    exact candidate bytes in _verify_complete.
    """
    index = plan["session_ids"].index(sid)
    records = plan["records"][index * 4:index * 4 + 4]
    snapshots = {Path(r["path"]).parent.name: _read(Path(r["path"]), absent=True) for r in records}
    if all(snapshots[Path(r["path"]).parent.name][0] == _unb64(r["candidate"]) for r in records):
        # Includes deliberately disabled policies: exact already-validated chains
        # need no public activation check to prove that no progression occurred.
        return
    entry_raw = snapshots["enrollments"][0]
    require(entry_raw == _unb64(records[0]["candidate"]), "released_enrollment_changed")
    entry = admission._json(entry_raw)
    policy_raw = _unb64(plan["records"][-1]["candidate"])
    policy = admission._json(policy_raw)
    payload = {"session_id": sid, "agent_id": sid, "transcript_path": entry["transcript_path"],
               "cwd": entry["project"]["path"]}
    require(host_admission._validate_entry(root, policy, payload) == entry, "released_origin_changed")
    binding = _binding(entry, policy, policy_raw)
    record_raw, state_raw, request_raw = (snapshots[k][0] for k in ("admissions", "sessions", "pending"))
    if record_raw is None:
        require(state_raw is None and request_raw is None and records[1]["candidate"] is None,
                "released_cursor_missing")
    else:
        require(state_raw is not None, "released_cursor_missing")
        record, state = admission._json(record_raw), admission._json(state_raw)
        require({"binding", "state_sha256", "processing", "last_event"} <= set(record)
                and record["binding"] == binding and record["state_sha256"] == object_digest(state)
                and state.get("admission") == binding and state.get("session_id") == sid
                and state.get("transcript_path") == entry["transcript_path"]
                and state.get("identity") == entry["identity"] and "device" not in state and "inode" not in state,
                "released_cursor_chain_invalid")
        previous = admission._json(_unb64(records[1]["candidate"])) if records[1]["candidate"] is not None else None
        floor = previous["offset"] if previous is not None else entry["frontier_offset"]
        require(type(state.get("offset")) is int and floor <= state["offset"] <= Path(entry["transcript_path"]).stat().st_size,
                "released_cursor_regressed_or_truncated")
        if request_raw is not None:
            request = admission._json(request_raw)
            require(isinstance(request.get("request_id"), str) and bool(request["request_id"])
                    and request.get("admission") == binding and request.get("session_id") == sid
                    and request.get("identity") == entry["identity"] and "device" not in request and "inode" not in request,
                    "released_request_chain_invalid")
            require(host_admission.check(root, request) == binding, "released_request_admission_changed")
        # Processing may be non-null after an interrupted but independently
        # admitted later run. It is outside this release's mutation scope.
    for record in records:
        name = Path(record["path"]).parent.name
        require(_read(Path(record["path"]), absent=True) == snapshots[name], "released_chain_changed_during_validation")


def _verify_complete(root, plan, plan_sha, *, released=()):
    _validate_plan(root, plan, plan_sha)
    work = _journal(root, plan, plan_sha, create=False)
    authorized = _known_releases(root, work, plan, plan_sha)
    require(set(released) <= authorized, "release_intent_missing")
    absent = {sid for sid, path in zip(plan["session_ids"], plan["hold_paths"]) if not os.path.lexists(path)}
    require(absent <= authorized, "hold_missing_without_release_intent")
    for index, sid in enumerate(plan["session_ids"]):
        if sid in absent:
            _released_chain(root, plan, sid)
        else:
            for record in plan["records"][index * 4:index * 4 + 4]:
                require(_read(Path(record["path"]), absent=record["candidate"] is None)[0]
                        == _unb64(record["candidate"]), "completed_chain_changed")
    for record in plan["records"][-2:]:
        require(_read(Path(record["path"]), absent=record["candidate"] is None)[0] == _unb64(record["candidate"]), "completed_chain_changed")
    for sid, path in zip(plan["session_ids"], plan["hold_paths"]):
        if not os.path.lexists(path):
            require(sid in authorized, "hold_missing_without_release_intent")
        else:
            require(_read(Path(path))[0] == _hold(sid, plan_sha), "hold_changed")
    # _validate_candidates re-runs maintained origin/frontier checks against the
    # retained descriptors; exact postimages prove the chain without bypassing a
    # normal host check's mandatory migration hold or disabled policy.


def prepare_release(root, plan, plan_sha256, session_ids):
    root = _root(root)
    selected = sorted(session_ids)
    require(1 <= len(selected) <= MAX_SELECTED and len(set(selected)) == len(selected)
            and set(selected) <= set(plan["session_ids"]), "invalid_release_selection")
    with Locks(root) as locks:
        _verify_complete(root, plan, plan_sha256)
        records = []
        for sid in selected:
            path = root / "migration-holds" / (sid + ".json")
            raw, info = _read(path)
            records.append({"path": str(path), "bytes": _b64(raw), "identity": info})
        locks.verify()
        return {"schema_version": 1, "kind": "selected_identity_hold_release", "root": str(root),
                "migration_plan_sha256": plan_sha256, "session_ids": selected, "holds": records,
                "runtime_sha256": _runtime(), "learner_started": False}


def _validate_release(root, plan, plan_sha, release_plan):
    require(set(release_plan) == {"schema_version", "kind", "root", "migration_plan_sha256",
                                 "session_ids", "holds", "runtime_sha256", "learner_started"}
            and type(release_plan["schema_version"]) is int and release_plan["schema_version"] == 1
            and release_plan["kind"] == "selected_identity_hold_release"
            and release_plan["root"] == str(root) and release_plan["migration_plan_sha256"] == plan_sha
            and release_plan["runtime_sha256"] == plan["runtime_sha256"]
            and release_plan["learner_started"] is False, "invalid_release_plan")
    selected = release_plan["session_ids"]
    require(isinstance(selected, list) and selected == sorted(set(selected)) and 1 <= len(selected) <= MAX_SELECTED
            and set(selected) <= set(plan["session_ids"]), "invalid_release_selection")
    require([r["path"] for r in release_plan["holds"]]
            == [str(root / "migration-holds" / (sid + ".json")) for sid in selected], "release_paths_changed")
    for sid, record in zip(selected, release_plan["holds"]):
        require(set(record) == {"path", "bytes", "identity"}
                and _unb64(record["bytes"]) == _hold(sid, plan_sha), "release_hold_changed")


def release(root, plan, plan_sha256, release_plan, release_sha256):
    root = _root(root)
    require(digest(encode(release_plan)) == release_sha256, "release_sha_mismatch")
    with Locks(root) as locks:
        # An interrupted partial release requires the exact same release plan;
        # the durable release intent below is the sole evidence allowing absence.
        _validate_release(root, plan, plan_sha256, release_plan)
        selected = release_plan["session_ids"]
        work = _journal(root, plan, plan_sha256, create=False)
        intent = work / ("release-" + release_sha256 + ".json")
        absent = [sid for sid in selected if not os.path.lexists(root / "migration-holds" / (sid + ".json"))]
        if os.path.lexists(intent):
            require(_read(intent)[0] == encode(release_plan), "release_intent_changed")
        else:
            require(not absent, "hold_missing_without_release_intent")
            _verify_complete(root, plan, plan_sha256)
            for record in release_plan["holds"]:
                raw, info = _read(Path(record["path"]))
                require(raw == _unb64(record["bytes"]) and info == record["identity"], "release_hold_cas_mismatch")
            _new(intent, encode(release_plan))
        for sid, record in zip(selected, release_plan["holds"]):
            _verify_complete(root, plan, plan_sha256, released=absent)
            locks.verify()
            if sid in absent:
                continue
            path = Path(record["path"])
            raw, info = _read(path)
            require(raw == _unb64(record["bytes"]) == _hold(sid, plan_sha256)
                    and info == record["identity"], "release_hold_cas_mismatch")
            path.unlink()
            _fsync(path.parent)
            absent.append(sid)
            _event(work, "hold_released", session_id=sid, release_sha256=release_sha256)
        locks.verify()
        return {"status": "selected_migration_holds_released", "session_ids": selected, "learner_started": False}


def _load_plan(path, expected):
    raw, _ = _read(_canonical(path), maximum=MAX_PLAN_BYTES)
    require(digest(raw) == expected, "plan_file_sha_mismatch")
    plan = admission._json(raw)
    require(raw == encode(plan), "noncanonical_plan_encoding")
    return plan


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "apply", "recover", "release-plan", "release"))
    parser.add_argument("--state-dir", required=True, type=Path)
    parser.add_argument("--routes", type=Path)
    parser.add_argument("--session-id", action="append", default=[])
    parser.add_argument("--legacy-policy", type=Path)
    parser.add_argument("--authorize-current-volume-adoption", action="store_true")
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--plan-sha256")
    parser.add_argument("--release-plan", type=Path)
    parser.add_argument("--release-sha256")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    def deadline(*_):
        raise ValueError("migration_deadline_or_interruption")
    handlers = {number: signal.signal(number, deadline) for number in (signal.SIGALRM, signal.SIGTERM, signal.SIGINT)}
    signal.setitimer(signal.ITIMER_REAL, 30)
    try:
        if args.command == "plan":
            require(args.routes is not None and args.output is not None, "plan_requires_routes_and_output")
            result = prepare(args.state_dir, args.routes, args.session_id, legacy_policy_path=args.legacy_policy,
                             authorize_current_volume_adoption=args.authorize_current_volume_adoption)
        else:
            require(args.plan is not None and args.plan_sha256 is not None, "reviewed_plan_required")
            plan = _load_plan(args.plan, args.plan_sha256)
            if args.command == "release-plan":
                require(args.output is not None, "release_plan_output_required")
                result = prepare_release(args.state_dir, plan, args.plan_sha256, args.session_id)
            elif args.command == "release":
                require(args.release_plan is not None and args.release_sha256 is not None, "reviewed_release_required")
                result = release(args.state_dir, plan, args.plan_sha256,
                                 _load_plan(args.release_plan, args.release_sha256), args.release_sha256)
            else:
                result = (apply if args.command == "apply" else recover)(args.state_dir, plan, args.plan_sha256)
        if args.output is not None:
            _new(args.output, encode(result))
        print(json.dumps({"status": result.get("status", "review_required"), "sha256": digest(encode(result)), "learner_started": False}))
        return 0
    except (OSError, ValueError, TypeError, KeyError) as error:
        reason = str(error) if isinstance(error, ValueError) and re.fullmatch(r"(?:admission|migration)_[a-z_]+", str(error)) else "migration_failed"
        print(json.dumps({"status": "refused_or_partial_recovery_required", "reason": reason, "learner_started": False}))
        return 1
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        for number, handler in handlers.items():
            signal.signal(number, handler)
