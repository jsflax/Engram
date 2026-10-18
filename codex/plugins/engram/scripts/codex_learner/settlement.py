"""Verify frozen learner completion after exclusive writer revocation.

No provider, memory mutation or replay is performed here. The optional bounded
reconciliation probe invokes only native scope/status reads before settlement.
The process owner records dispatch before Popen and observation after cleanup;
recovery only reads those immutable records. Caller holds worker coordination
and an actual revoked exclusive HeldFence throughout settlement/publication.
"""
from __future__ import annotations

import copy
import os
from pathlib import Path

from . import execution_manifest as journal, migration as durable
from . import operation_gateway as gateway, operation_probe, writer_fence

READ_TOOLS = {"recall", "graph", "list_topics", "stats", "timeline"}
WRITE_TOOLS = {"remember", "update", "connect"}
FIXED = ("provider-dispatch.json", "provider-observation.json", "mcp-audit.jsonl", "result.json")
MAX_FILES = 4096
MAX_TOTAL = 32 * 1024 * 1024
ABSENCE_CHECKPOINT = "absent-status-reconciliation.json"


def _require(ok, reason):
    if not ok:
        raise ValueError("settlement_" + reason)


def _same(left, right):
    return journal.encode(left) == journal.encode(right)


def _manifest(run_dir, expected=None):
    _require(isinstance(run_dir, Path) and run_dir.is_absolute(), "untrusted_run_path")
    journal._private(run_dir)
    manifest, digest = journal.read_manifest(run_dir)
    if expected is not None:
        _require(digest == expected, "manifest_changed")
    return manifest, digest


def _validate(manifest, fence, validate, phase):
    _require(type(fence) is writer_fence.HeldFence and fence.mode == "exclusive", "exclusive_fence_required")
    _require(fence.verify(manifest["fencing"]) is True, "fence_changed")
    _require(callable(validate) and validate(copy.deepcopy(manifest), phase) is True, "input_validation_refused")
    _require(fence.verify(manifest["fencing"]) is True, "fence_changed")


def record_provider_dispatch(run_dir, manifest_sha256, validate_inputs):
    """Actual process owner calls immediately BEFORE Popen; never infer launch."""
    manifest, digest = _manifest(run_dir, manifest_sha256)
    _require(callable(validate_inputs) and validate_inputs(copy.deepcopy(manifest), "before_provider_dispatch") is True,
             "input_validation_refused")
    _require(not os.path.lexists(run_dir / "provider-dispatch.json"), "provider_already_dispatched")
    raw = journal.encode({"version": 1, "manifest_sha256": digest})
    journal._publish(run_dir / "provider-dispatch.json", raw)
    _require(validate_inputs(copy.deepcopy(manifest), "after_provider_dispatch") is True, "input_validation_refused")
    _manifest(run_dir, digest)
    return journal.sha256(raw)


def _observation(value):
    journal._keys(value, {"started", "terminated", "returncode", "turn_completed", "provider_error",
                          "unexpected_tool", "tool_errors", "reason"})
    for key in ("started", "terminated", "turn_completed", "provider_error", "unexpected_tool"):
        _require(type(value[key]) is bool, "invalid_observation")
    journal._integer(value["tool_errors"], 0, 100000)
    _require(value["reason"] is None or type(value["reason"]) is str and len(value["reason"]) <= 256,
             "invalid_observation")
    code = value["returncode"]
    _require(code is None or type(code) is int and -(1 << 31) <= code < (1 << 31), "invalid_observation")
    _require((not value["started"] and code is None and not value["turn_completed"])
             or (value["started"] and ((value["terminated"] and type(code) is int)
                                      or (not value["terminated"] and code is None))), "invalid_observation")
    return value


def persist_observation(run_dir, observation):
    """Seal observations supplied only by the actual provider process owner.

    These are trusted process facts, not provider-authored JSON. Recovery must
    never call this to invent termination or success from missing evidence.
    """
    _, digest = _manifest(run_dir)
    _observation(observation)
    raw = journal.encode({"version": 1, "manifest_sha256": digest, "observation": copy.deepcopy(observation)})
    if observation["started"]:
        dispatch = durable._read(run_dir / "provider-dispatch.json")[0]
        _require(dispatch == journal.encode({"version": 1, "manifest_sha256": digest}), "provider_dispatch_missing")
    journal._publish(run_dir / "provider-observation.json", raw)
    return journal.sha256(raw)


def _snapshot(run_dir):
    """Bounded inventory, including orphan evidence directories and partial files."""
    files, raw_fixed, total = {}, {}, 0
    def read(path, relative, absent=False):
        nonlocal total
        raw, identity = durable._read(path, absent=absent, maximum=journal.MAX_RECORD)
        if raw is not None:
            total += len(raw)
            _require(total <= MAX_TOTAL and len(files) < MAX_FILES, "evidence_limit")
        files[relative] = None if raw is None else {"sha256": journal.sha256(raw), "identity": identity}
        return raw
    for name in FIXED:
        raw_fixed[name] = read(run_dir / name, name, True)
    planning = journal.read_manifest(run_dir)[0].get('provider_mode') == 'read_only_plan'
    if planning:
        for name in ('proposal.json', 'learner-plan.json'):
            raw_fixed[name] = read(run_dir / name, name, True)
        directory = run_dir / 'plan-attempts'
        if os.path.lexists(directory):
            journal._private(directory)
            children = journal._event_paths(directory, planning=True)
            _require(len(children) <= journal.MAX_EVENTS, 'evidence_limit')
            for index, child in enumerate(children):
                _require(child.name == f'{index:06d}.json', 'invalid_plan_attempt_sequence')
                read(child, 'plan-attempts/' + child.name)
    # Keep old settlement snapshots byte-compatible when no new checkpoint exists.
    checkpoint = run_dir / ABSENCE_CHECKPOINT
    raw_fixed[ABSENCE_CHECKPOINT] = (read(checkpoint, ABSENCE_CHECKPOINT)
                                        if os.path.lexists(checkpoint) else None)
    operation_ids, evidence_ids = set(), set()
    with os.scandir(run_dir) as entries:
        for count, entry in enumerate(entries):
            _require(count < MAX_FILES, "run_directory_limit")
            if entry.name.startswith("operation-"):
                _require(entry.name.endswith(".json"), "invalid_operation_file")
                operation = journal._uuid(entry.name[10:-5])
                _require(entry.name == "operation-" + operation + ".json", "invalid_operation_file")
                operation_ids.add(operation)
                read(run_dir / entry.name, entry.name)
            elif entry.name.startswith("evidence-"):
                operation = journal._uuid(entry.name[9:])
                _require(entry.name == "evidence-" + operation, "invalid_evidence_directory")
                evidence_ids.add(operation)
                directory = run_dir / entry.name
                journal._private(directory)
                children = journal._event_paths(directory, planning=planning)
                _require(len(children) <= journal.MAX_EVENTS, "evidence_limit")
                for index, child in enumerate(children):
                    _require(child.name == f"{index:06d}.json", "invalid_evidence_sequence")
                    read(child, entry.name + "/" + child.name)
    _require(len(operation_ids) <= 64 and evidence_ids <= operation_ids, "orphan_or_excess_operations")
    return files, raw_fixed, sorted(operation_ids)


def _revocation_evidence(run_dir, manifest):
    raw, identity = durable._read(run_dir / writer_fence.REVOCATION_NAME)
    _require(_same(journal._json(raw), {"version": 1, "status": "revoked",
                                       "binding": manifest["fencing"]}), "revocation_changed")
    return {"sha256": journal.sha256(raw), "identity": identity}


def _absence_checkpoint(run_dir, manifest, digest, files, raw, operations):
    """Validate post-revocation proof, never interpret a bare absent event as safe.

    This proof can only make a clean failed run retryable with its cursor intact.
    It cannot authorize replay, clear an old hold, or create successful coverage.
    """
    if raw is None:
        return set()
    value = journal._json(raw)
    journal._keys(value, {"version", "kind", "manifest_sha256", "fencing", "revocation",
                          "inventory_sha256", "operation_ids"})
    journal._version(value["version"])
    inventory = {key: item for key, item in files.items() if key != ABSENCE_CHECKPOINT}
    _require(value["kind"] == "revoked_all_operations_absent"
             and value["manifest_sha256"] == digest
             and _same(value["fencing"], manifest["fencing"])
             and _same(value["revocation"], _revocation_evidence(run_dir, manifest))
             and value["inventory_sha256"] == journal.sha256(journal.encode(inventory))
             and type(value["operation_ids"]) is list
             and value["operation_ids"] == operations and 0 < len(operations) <= 32,
             "absence_checkpoint_changed")
    for operation in operations:
        events = journal.read_evidence(run_dir, operation)
        kinds = [event["evidence"]["kind"] for event in events]
        _require(bool(kinds) and kinds[0] == "dispatch" and kinds[-1] == "absent"
                 and "committed" not in kinds, "absence_checkpoint_unsettled")
    return set(operations)


def reconcile_statuses(run_dir, *, manifest_sha256, recovery_fence, transport,
                       validate_inputs, limits=None):
    """Recover observations for unresolved dispatches; never replay a mutation.

    Must precede the first immutable settlement. Only the exact sealed route is
    launched, with no writer FD inherited; the caller retains the revoked EX
    fence throughout. A missing/failed provider outcome remains a hold even if
    a committed receipt is recovered. Absence grants no dispatch authority.
    """
    manifest, digest = _manifest(run_dir, manifest_sha256)
    selected_transport = copy.deepcopy(transport)
    route = journal._json(journal._unseal(manifest["inputs"]["backend_route"]))
    _require(type(route) is dict and "transport" in route
             and _same(selected_transport, route["transport"]), "backend_route_changed")
    _validate(manifest, recovery_fence, validate_inputs, "before_status_reconciliation")
    _require(not os.path.lexists(run_dir / "settlement.json"), "already_settled")
    baseline, fixed, operations = _snapshot(run_dir)
    if fixed[ABSENCE_CHECKPOINT] is not None:
        absent = _absence_checkpoint(run_dir, manifest, digest, baseline,
                                     fixed[ABSENCE_CHECKPOINT], operations)
        _validate(manifest, recovery_fence, validate_inputs, "after_absence_checkpoint_read")
        _require(_same(_snapshot(run_dir)[0], baseline), "evidence_changed")
        return {"requested": len(absent), "committed": 0, "absent": len(absent), "already_committed": 0}
    requests, event_counts, already_committed = [], {}, 0
    for operation in operations:
        _, request = journal.read_intent(run_dir, operation)
        events = journal.read_evidence(run_dir, operation)
        kinds = [event["evidence"]["kind"] for event in events]
        if "committed" in kinds:
            _require(bool(kinds) and kinds[0] == "dispatch", "invalid_dispatch_evidence")
            already_committed += 1
        elif "dispatch" in kinds:
            _require(kinds[0] == "dispatch", "invalid_dispatch_evidence")
            requests.append(request)
            event_counts[operation] = len(events)
        else:
            _require(not events, "undispatched_evidence")
    _require(len(requests) <= 32, "status_probe_limit")

    def validate(phase, *, check_inventory=True):
        _validate(manifest, recovery_fence, validate_inputs, phase)
        _manifest(run_dir, digest)
        _require(not os.path.lexists(run_dir / "settlement.json"), "already_settled")
        if check_inventory:
            _require(_same(_snapshot(run_dir)[0], baseline), "evidence_changed")
        return True

    validate("before_status_probe")
    responses = operation_probe.probe_statuses(
        selected_transport, recovery_fence=recovery_fence, expected_binding=manifest["fencing"],
        expected_scope=manifest["expected_scope"], requests=requests, validate_inputs=validate,
        limits=limits) if requests else []
    _require(len(responses) == len(requests), "status_count_changed")
    counts = {"requested": len(requests), "committed": 0, "absent": 0,
              "already_committed": already_committed}
    for request, response in zip(requests, responses):
        validate("before_status_evidence")
        operation = request["operationID"]
        # Revalidate the fixed response before appending; no generic error can
        # enter this path as absence. record_response rechecks its entire chain.
        journal._response(response, request, None)
        _require(response["kind"] in ("committed", "absent"), "invalid_status")
        def verify_append(binding):
            validate("status_evidence_boundary", check_inventory=False)
            return recovery_fence.verify(binding)
        event = journal.record_response(run_dir, operation, response, verify_fence=verify_append)
        current = _snapshot(run_dir)[0]
        name = f"evidence-{operation}/{event_counts[operation]:06d}.json"
        _require(name not in baseline and name in current
                 and current[name]["sha256"] == journal.sha256(journal.encode(event))
                 and _same({key: value for key, value in current.items() if key != name}, baseline),
                 "evidence_changed")
        baseline = current
        counts[response["kind"]] += 1
        validate("after_status_evidence")
    validate("after_status_reconciliation")
    if requests and counts["absent"] == len(operations) == len(requests) and not already_committed:
        # The exact native probe completed, cleaned up, and revalidated the held
        # EX fence before any evidence was appended. Publish only after ALL
        # selected operations were freshly observed absent on the sealed route.
        validate("before_absence_checkpoint")
        checkpoint = {"version": 1, "kind": "revoked_all_operations_absent",
            "manifest_sha256": digest, "fencing": manifest["fencing"],
            "revocation": _revocation_evidence(run_dir, manifest),
            "inventory_sha256": journal.sha256(journal.encode(baseline)), "operation_ids": operations}
        checkpoint_raw = journal.encode(checkpoint)
        journal._publish(run_dir / ABSENCE_CHECKPOINT, checkpoint_raw)
        current, fixed, selected = _snapshot(run_dir)
        _require(ABSENCE_CHECKPOINT not in baseline
                 and current[ABSENCE_CHECKPOINT]["sha256"] == journal.sha256(checkpoint_raw)
                 and _same({key: item for key, item in current.items() if key != ABSENCE_CHECKPOINT}, baseline),
                 "evidence_changed")
        baseline = current
        validate("after_absence_checkpoint")
        _absence_checkpoint(run_dir, manifest, digest, current, fixed[ABSENCE_CHECKPOINT], selected)
    return counts


def _operations(run_dir, operation_ids, verified_absent=frozenset()):
    records, applied, unchanged, uncertain = [], [], [], False
    for operation in operation_ids:
        mutation = None
        try:
            _, request = journal.read_intent(run_dir, operation)
            mutation = request["mutation"]["kind"]
            events = journal.read_evidence(run_dir, operation)
            kinds = [event["evidence"]["kind"] for event in events]
            receipts = [event["evidence"]["receipt"] for event in events if event["evidence"]["kind"] == "committed"]
            receipt = receipts[-1] if receipts else None
            dispatched = "dispatch" in kinds
            settled = dispatched and kinds[0] == "dispatch" and kinds[-1] == "committed" and receipt is not None
            absent = operation in verified_absent and dispatched and kinds[-1] == "absent" and receipt is None
            uncertain |= dispatched and not settled and not absent or receipt is not None and not settled
            # A later unavailable observation cannot erase an already validated
            # commit. Keep its effect IDs while retaining the uncertainty hold.
            if receipt is not None:
                (applied if receipt["outcome"] == "applied" else unchanged).append(receipt)
            records.append({"operation_id": operation, "mutation": mutation,
                            "dispatched": dispatched, "settled": settled, "receipt": receipt})
        except (ValueError, TypeError, KeyError, OSError):
            # One malformed intent/chain must not discard validated effects of
            # other operations. Unknown dispatch is explicit, never absence.
            uncertain = True
            records.append({"operation_id": operation, "mutation": mutation, "dispatched": None,
                            "settled": False, "receipt": None, "evidence_valid": False})
    return records, applied, unchanged, uncertain


def _audit(raw, run_dir, observation, verified_absent=frozenset()):
    _require(raw is not None and raw.endswith(b"\n") and len(raw) <= 4 * 1024 * 1024, "audit_missing_or_partial")
    calls, results, started, finished, interrupted = {}, {}, False, False, False
    for index, line in enumerate(raw.splitlines()):
        _require(index < 1024, "audit_limit")
        value = journal._json(line, journal.MAX_INPUT)
        _require(type(value) is dict and not finished, "invalid_audit_order")
        event = value.get("event")
        if event == "relay_started":
            _require(value == {"event": event} and not started and not calls, "invalid_audit_start")
            started = True
            continue
        _require(started, "audit_not_started")
        if event == "relay_finished":
            journal._keys(value, {"event", "child_reaped", "cleanup_overrun"},
                          {"peak_inflight", "peak_client_queue_bytes", "peak_server_queue_bytes"})
            _require(value["child_reaped"] is True and value["cleanup_overrun"] is False, "audit_cleanup_failed")
            for key in set(value) - {"event", "child_reaped", "cleanup_overrun"}:
                journal._integer(value[key])
            finished = True
            continue
        _require(not interrupted, "audit_after_interrupt")
        if event == "relay_interrupted":
            failed_no_effect = (bool(verified_absent) and observation is not None
                                and observation["started"] and observation["terminated"]
                                and not observation["unexpected_tool"])
            _require(value == {"event": event} and observation is not None
                     and (_provider_clean(observation) or failed_no_effect)
                     and bool(calls) and set(calls) == set(results)
                     and (all(v["ok"] is True for v in results.values()) or failed_no_effect),
                     "audit_unclean_interrupt")
            interrupted = True
            continue
        if event == "initialize_compat":
            _require(value == {"event": event, "omitted_capability": "codex/auth-change"}, "invalid_audit_compat")
            continue
        _require(event in {"tool_call", "tool_result"}, "audit_failure_or_unknown_event")
        key = gateway.call_key(value.get("id"))
        tool = value.get("tool")
        _require(tool in READ_TOOLS | WRITE_TOOLS, "audit_tool_invalid")
        if event == "tool_call":
            journal._keys(value, {"event", "id", "tool"})
            _require(key not in calls, "audit_duplicate_id")
            calls[key] = value
        else:
            journal._keys(value, {"event", "id", "tool", "ok", "memory_ids", "forwarded"},
                          {"operation_version", "operation_id", "operation_outcome", "operation_payload_digest"})
            _require(key in calls and calls[key]["tool"] == tool and key not in results
                     and type(value["ok"]) is bool and type(value["forwarded"]) is bool
                     and type(value["memory_ids"]) is list, "invalid_audit_result")
            results[key] = value
    _require(started and finished and set(calls) == set(results), "audit_incomplete")
    forwarded, errors = [], 0
    for key, call in calls.items():
        result = results[key]
        if call["tool"] in WRITE_TOOLS and result["forwarded"]:
            if result["ok"]:
                gateway.verify_audit_receipt(run_dir, call["id"], call["tool"], result)
            else:
                operation = journal.operation_id(run_dir, gateway.call_key(call["id"]))
                _require(operation in verified_absent and result["memory_ids"] == []
                         and not any(name.startswith("operation_") for name in result),
                         "audit_failed_write_unverified")
                _, request = journal.read_intent(run_dir, operation)
                _require(request["mutation"]["kind"] == call["tool"], "audit_tool_changed")
            forwarded.append(call["id"])
        else:
            _require(not any(name.startswith("operation_") for name in result)
                     and not result["memory_ids"], "unexpected_audit_receipt")
            _require(result["forwarded"] or result["ok"] is False, "invalid_local_denial")
        errors += result["ok"] is not True
    gateway.verify_audit_coverage(run_dir, forwarded)
    return {"tool_calls": len(calls), "tool_errors": errors, "forwarded_writes": len(forwarded)}


def _provider_clean(value):
    return (value["started"] and value["terminated"] and value["returncode"] == 0
            and value["turn_completed"] and not value["provider_error"] and not value["unexpected_tool"]
            and value["tool_errors"] == 0 and value["reason"] is None)


def _result(raw, memory_ids):
    value = journal._json(raw, journal.MAX_INPUT)
    journal._keys(value, {"outcome", "summary", "memory_ids"})
    journal._string(value["summary"], journal.MAX_INPUT, nonempty=False)
    _require(type(value["memory_ids"]) is list, "invalid_provider_result")
    ids = [journal._uuid(item) for item in value["memory_ids"]]
    _require(len(ids) == len(set(ids)) and set(ids) == set(memory_ids), "provider_ids_mismatch")
    _require(value["outcome"] == ("stored" if ids else "no_new_memories"), "provider_outcome_mismatch")


# Reviewed 0.15.1 durable gateway/launcher contract. This recognizes the
# historical write-ahead protocol, never grants old runtime execution authority.
PINNED_DURABLE_0151 = {'runner.py': '5023d137ba790c8979417ca63c5a181fe4323d1bc6b9e489c135bd26928a379c', 'memory_proxy.py': '2c8670ca9591f649e5abcacec20ae865381fc295c516fa9e2969945947d263bd', 'operation_gateway.py': '333eabc06b20ff6a7c0b4dda05b70fad2b80c91b07faf40778edcedb602205e6', 'execution_manifest.py': 'ca886dbbb7a6f15e83ebac253fa6137665282996b548523d0a27267666df3a50', 'stdio_bridge.py': '737089019694cc0fdde0cfed724d28e31d96bda9addf303d53268f6c9815fb05', 'writer_fence.py': 'e55e1c6a993cdf84ea0ff5acab01b84ef72495f58f7f78ff6648fc57a9ca44e3'}
ZERO_RETRY = "zero-intent-retry.json"
ZERO_KIND = "zero_intent_retry"


def _gateway_contract(plugin_root):
    root = Path(plugin_root)
    _require(root.is_absolute() and root.resolve(strict=True) == root, "unbound_gateway")
    current_root = Path(__file__).resolve().parent
    evidence, hashes, current = {}, {}, {}
    for name in PINNED_DURABLE_0151:
        path = root / "scripts" / "codex_learner" / name
        value, identity = durable._read(path, private=False, maximum=1024 * 1024)
        _require(not identity["mode"] & 0o022, "unsafe_gateway")
        hashes[name] = journal.sha256(value)
        evidence[name] = {"sha256": hashes[name], "identity": identity}
        current[name] = journal.sha256(durable._read(current_root / name, private=False,
                                                    maximum=1024 * 1024)[0])
    _require(hashes == PINNED_DURABLE_0151 or hashes == current, "unknown_gateway_contract")
    return evidence


def zero_intent_proof(run_dir, manifest, digest):
    """Prove no learner mutation, not provider success or zero DB housekeeping.

    Only the known durable launcher/gateway qualifies. That gateway fsyncs an
    intent and dispatch before forwarding every allowed mutation, without raw
    fallback. A revoked EX owner separately drains it before using this proof.
    Missing audit alone is never the proof; the bound write-ahead protocol is.
    """
    _require(manifest.get("provider_mode") is None, "not_legacy_durable_run")
    files, raw, operations = _snapshot(run_dir)
    _require(not operations and raw[ABSENCE_CHECKPOINT] is None
             and raw["mcp-audit.jsonl"] is None and raw["result.json"] is None,
             "not_zero_intent_startup")
    _require(not any(os.path.lexists(run_dir / name) for name in
                     ("learner-plan.json", "plan-attempts", "successful-coverage.json")),
             "unexpected_execution_evidence")
    _require(raw["provider-dispatch.json"] == journal.encode({"version": 1, "manifest_sha256": digest}),
             "provider_dispatch_missing")
    value = journal._json(raw["provider-observation.json"])
    journal._keys(value, {"version", "manifest_sha256", "observation"})
    journal._version(value["version"])
    owner = _observation(value["observation"])
    _require(value["manifest_sha256"] == digest and owner["started"] and owner["terminated"]
             and not owner["unexpected_tool"], "zero_intent_owner_unproven")
    route = journal._json(journal._unseal(manifest["inputs"]["backend_route"]))
    backend = journal._json(journal._unseal(manifest["inputs"]["backend_config"]))
    transport_raw, identity = durable._read(run_dir / "transport.json", maximum=journal.MAX_INPUT)
    config = journal._json(transport_raw, journal.MAX_INPUT)
    journal._keys(config, {"execution", "transport", "audit_path", "provenance",
                          "max_tool_calls", "max_writes", "allowed_tools"})
    expected_paths = route["paths"]
    _require(expected_paths["run_dir"] == str(run_dir)
             and expected_paths["root"] == str(run_dir.parent.parent)
             and _same(config["execution"], {**expected_paths, "manifest_sha256": digest})
             and _same(config["transport"], route["transport"])
             and config["audit_path"] == str(run_dir / "mcp-audit.jsonl")
             and config["provenance"] == "codex-session:" + manifest["session_id"],
             "unbound_durable_gateway")
    from . import memory_config, learner_settings
    allowed = sorted(memory_config.allowed_tools(backend["memory"], READ_TOOLS | WRITE_TOOLS))
    limits = learner_settings.bounded({} if backend["settings"] is None else backend["settings"]["value"])
    _require(config["allowed_tools"] == allowed and all(type(config[name]) is int
             and 0 <= config[name] <= limits[name] for name in ("max_tool_calls", "max_writes")),
             "gateway_policy_changed")
    contract = _gateway_contract(expected_paths["plugin_root"])
    # The known files must have been in place before the trusted owner logged
    # dispatch; known replacement bytes installed afterward do not prove what ran.
    dispatched = files["provider-dispatch.json"]["identity"]["mtime_ns"]
    _require(max(identity["mtime_ns"], identity["ctime_ns"]) <= dispatched,
             "gateway_configuration_installed_after_dispatch")
    _require(all(max(item["identity"]["mtime_ns"], item["identity"]["ctime_ns"]) <= dispatched
                 for item in contract.values()), "gateway_installed_after_dispatch")
    revocation = _revocation_evidence(run_dir, manifest)
    _require(_same(_snapshot(run_dir)[0], files), "evidence_changed")
    return {"version": 1, "kind": "durable_zero_intent", "manifest_sha256": digest,
            "fencing": manifest["fencing"], "revocation": revocation, "files": files,
            "transport": {"sha256": journal.sha256(transport_raw), "identity": identity},
            "gateway_contract": contract}


def original_zero_intent_hold(run_dir, expected_sha256):
    """Authenticate old classification unchanged before deriving a failure."""
    raw, identity = durable._read(run_dir / "settlement.json", maximum=journal.MAX_RECORD)
    _require(journal.sha256(raw) == expected_sha256, "settlement_digest_changed")
    value = journal._json(raw)
    manifest, digest = _manifest(run_dir, value.get("manifest_sha256"))
    _require(raw == journal.encode(_compute(run_dir, manifest, digest, zero_intent=False))
             and value["status"] == "reconciliation_required"
             and value["reason"] == "unverified_completion"
             and value["issues"] == ["audit_unsettled"]
             and value["operations"] == [] and value["memory_ids"] == []
             and all(value[name] == 0 for name in ("attempted_write_calls", "applied_write_calls",
                                                   "unchanged_write_calls")), "not_original_zero_intent_hold")
    proof = zero_intent_proof(run_dir, manifest, digest)
    _require(durable._read(run_dir / "settlement.json", maximum=journal.MAX_RECORD) == (raw, identity),
             "settlement_changed")
    return value, {"sha256": expected_sha256, "identity": identity}, proof


def _compute(run_dir, manifest, digest, *, zero_intent=True):
    if manifest.get('provider_mode') == 'read_only_plan':
        return _compute_plan(run_dir, manifest, digest)
    files, raw, operation_ids = _snapshot(run_dir)
    issues = []
    verified_absent = set()
    try:
        verified_absent = _absence_checkpoint(run_dir, manifest, digest, files,
                                              raw[ABSENCE_CHECKPOINT], operation_ids)
    except (ValueError, TypeError, KeyError, OSError):
        issues.append("invalid_absence_reconciliation")
    records, applied, unchanged, uncertain = _operations(run_dir, operation_ids, verified_absent)
    uncertain |= bool(issues)
    if any(record.get("evidence_valid") is False for record in records):
        issues.append("invalid_operation_evidence")
    observation, dispatch = None, raw["provider-dispatch.json"]
    if dispatch is not None and dispatch != journal.encode({"version": 1, "manifest_sha256": digest}):
        issues.append("invalid_provider_dispatch")
        uncertain = True
    if raw["provider-observation.json"] is not None:
        try:
            value = journal._json(raw["provider-observation.json"])
            journal._keys(value, {"version", "manifest_sha256", "observation"})
            journal._version(value["version"])
            _require(value["manifest_sha256"] == digest, "observation_manifest_changed")
            observation = _observation(value["observation"])
            _require(not observation["started"] or dispatch is not None, "provider_dispatch_missing")
        except (ValueError, TypeError, KeyError):
            observation = None
            issues.append("invalid_provider_observation")
            uncertain = True
    never_dispatched = (dispatch is None and raw["provider-observation.json"] is None
                        and raw["mcp-audit.jsonl"] is None and raw["result.json"] is None and not operation_ids)
    positive_no_start = (observation is not None and not observation["started"] and observation["terminated"]
                         and not operation_ids and raw["mcp-audit.jsonl"] is None and raw["result.json"] is None)
    audit = None
    if not (never_dispatched or positive_no_start):
        try:
            audit = _audit(raw["mcp-audit.jsonl"], run_dir, observation, verified_absent)
        except (ValueError, TypeError, KeyError, OSError):
            issues.append("audit_unsettled")
            uncertain = True
    if observation is None and not never_dispatched:
        issues.append("provider_observation_missing")
        uncertain = True
    elif observation is not None and not observation["terminated"]:
        issues.append("provider_not_terminated")
        uncertain = True
    if verified_absent and observation is not None and observation["unexpected_tool"]:
        issues.append("unexpected_provider_effect")
        uncertain = True
    memory_ids = sorted({journal._uuid(value) for receipt in applied for value in receipt["memoryIDs"]})
    result_valid = False
    if observation is not None and _provider_clean(observation):
        try:
            _result(raw["result.json"], memory_ids)
            result_valid = True
        except (ValueError, TypeError, KeyError):
            issues.append("provider_result_unverified")
    success = (not uncertain and not issues and observation is not None and _provider_clean(observation)
               and audit is not None and audit["tool_calls"] > 0 and audit["tool_errors"] == 0 and result_valid
               and len(records) == len(applied) + len(unchanged))
    no_effect = None
    if zero_intent and issues == ["audit_unsettled"] and not operation_ids:
        try:
            no_effect = zero_intent_proof(run_dir, manifest, digest)
            uncertain, issues = False, []
        except (ValueError, TypeError, KeyError, OSError):
            pass  # Unbound/partial evidence retains the original conservative hold.
    status = "succeeded" if success else ("reconciliation_required" if uncertain or applied else "failed")
    reason = "verified_completion" if success else ("never_dispatched" if never_dispatched else
             "provider_not_started" if positive_no_start else
             "verified_zero_intent_failure" if no_effect is not None else
             "verified_no_effect_failure" if verified_absent and not uncertain and not issues and not applied else
             "unverified_completion")
    return {"version": 1, "kind": "learner_settlement", "manifest_sha256": digest,
            "session_id": manifest["session_id"], "run_id": manifest["run_id"], "fencing": manifest["fencing"],
            "source": {key: manifest["source"][key] for key in ("start_offset", "end_offset")},
            "status": status, "reason": reason, "issues": sorted(set(issues)), "files": files,
            "operations": records, "attempted_write_calls": sum(record["dispatched"] is True for record in records),
            "applied_write_calls": len(applied), "unchanged_write_calls": len(unchanged),
            "memory_ids": memory_ids, "audit": audit,
            **({"zero_intent_proof": no_effect} if no_effect is not None else {})}


def _compute_plan(run_dir, manifest, digest):
    """Planning failure is zero-write; partial execution remains the SAME run.

    Read-only mode is immutable in the execution manifest and enforced by the
    proxy. Missing provider terminal/proposal evidence cannot strand a session
    when no complete plan or execution artifacts ever existed. Once a plan is
    sealed, only exact native receipts for its ENTIRE cohort grant coverage.
    """
    from . import learner_plan as P, planned_execution as E
    P.manifest_policy(manifest)
    files, raw, operation_ids = _snapshot(run_dir)
    records, applied, unchanged, _ = _operations(run_dir, operation_ids)
    memory_ids = sorted({journal._uuid(value) for receipt in applied for value in receipt['memoryIDs']})
    status, reason, issues, audit = 'failed', 'planning_not_complete', [], None
    if raw['learner-plan.json'] is None:
        try:
            P.operation_inventory(run_dir)
            _require(not any(name.startswith('plan-attempts/') for name in files), 'unplanned_attempts')
        except (ValueError, TypeError, KeyError, OSError):
            status, reason, issues = 'reconciliation_required', 'unverified_completion', ['unplanned_execution_evidence']
    else:
        try:
            plan, _ = P.read_plan(run_dir)
            progress = E.inspect_plan(run_dir)
            records, memory_ids, audit = progress['operations'], progress['memory_ids'], plan['audit']
            applied = [record['receipt'] for record in records
                       if record['receipt'] is not None and record['receipt']['outcome'] == 'applied']
            unchanged = [record['receipt'] for record in records
                         if record['receipt'] is not None and record['receipt']['outcome'] == 'unchanged']
            status = 'succeeded' if progress['status'] == 'complete' else 'pending'
            reason = 'verified_completion' if status == 'succeeded' else 'plan_pending'
        except (ValueError, TypeError, KeyError, OSError):
            status, reason, issues = 'reconciliation_required', 'unverified_completion', ['invalid_complete_plan']
    return {'version': 1, 'kind': 'learner_settlement', 'manifest_sha256': digest,
            'session_id': manifest['session_id'], 'run_id': manifest['run_id'], 'fencing': manifest['fencing'],
            'source': {key: manifest['source'][key] for key in ('start_offset', 'end_offset')},
            'status': status, 'reason': reason, 'issues': issues, 'files': files, 'operations': records,
            'attempted_write_calls': sum(record['dispatched'] is True for record in records),
            'applied_write_calls': len(applied), 'unchanged_write_calls': len(unchanged),
            'memory_ids': memory_ids, 'audit': audit}


def _coverage(manifest, manifest_sha, settlement_sha):
    parser = journal._json(journal._unseal(manifest["inputs"]["parser_state"]))
    journal._keys(parser, {"version", "input", "limits", "runtime", "interval_sha256"})
    journal._digest(parser["interval_sha256"])
    return {"version": 1, "kind": "successful_interval_coverage", "status": "succeeded",
            "session_id": manifest["session_id"], "run_id": manifest["run_id"],
            "source": {**manifest["source"], "interval_sha256": parser["interval_sha256"]},
            "parser": {"runtime": parser["runtime"], "limits": parser["limits"],
                       "input_sha256": journal.sha256(journal.encode(parser["input"])),
                       "next_sha256": manifest["inputs"]["next_parser_state"]["sha256"]},
            "execution_manifest_sha256": manifest_sha, "settlement_sha256": settlement_sha}


def settle(run_dir, *, manifest_sha256, recovery_fence, validate_inputs, provider_observation=None):
    manifest, digest = _manifest(run_dir, manifest_sha256)
    _validate(manifest, recovery_fence, validate_inputs, "before_settlement")
    if provider_observation is not None:
        persist_observation(run_dir, provider_observation)
    settlement = _compute(run_dir, manifest, digest)
    _require(settlement['status'] != 'pending', 'plan_not_complete')
    _validate(manifest, recovery_fence, validate_inputs, "before_settlement_publication")
    _require(_same(settlement, _compute(run_dir, manifest, digest)), "evidence_changed")
    raw = journal.encode(settlement)
    publish = journal._publish_atomic if manifest.get('provider_mode') == 'read_only_plan' else journal._publish
    publish(run_dir / "settlement.json", raw)
    _validate(manifest, recovery_fence, validate_inputs, "after_settlement_publication")
    _require(_same(settlement, _compute(run_dir, manifest, digest)), "evidence_changed")
    result = {**copy.deepcopy(settlement), "settlement_sha256": journal.sha256(raw), "coverage_reference": None}
    if settlement["status"] == "succeeded":
        coverage = _coverage(manifest, digest, result["settlement_sha256"])
        _validate(manifest, recovery_fence, validate_inputs, "before_coverage_publication")
        _require(_same(settlement, _compute(run_dir, manifest, digest)), "evidence_changed")
        coverage_raw = journal.encode(coverage)
        publish(run_dir / "successful-coverage.json", coverage_raw)
        _validate(manifest, recovery_fence, validate_inputs, "after_coverage_publication")
        result["coverage_reference"] = {"version": 1, "run_id": manifest["run_id"],
                                        "receipt_sha256": journal.sha256(coverage_raw)}
    _manifest(run_dir, digest)
    _require(_same(settlement, _compute(run_dir, manifest, digest)), "evidence_changed")
    return result


def verify_settlement(run_dir, *, expected_sha256, recovery_fence, validate_inputs):
    raw, identity = durable._read(run_dir / "settlement.json", maximum=journal.MAX_RECORD)
    _require(journal.sha256(raw) == expected_sha256, "settlement_digest_changed")
    value = journal._json(raw)
    manifest, digest = _manifest(run_dir, value.get("manifest_sha256"))
    _validate(manifest, recovery_fence, validate_inputs, "verify_settlement")
    _require(raw in (journal.encode(_compute(run_dir, manifest, digest)),
                     journal.encode(_compute(run_dir, manifest, digest, zero_intent=False))),
             "settlement_evidence_changed")
    _require(durable._read(run_dir / "settlement.json", maximum=journal.MAX_RECORD) == (raw, identity), "settlement_changed")
    _validate(manifest, recovery_fence, validate_inputs, "after_verify_settlement")
    _manifest(run_dir, digest)
    _require(raw in (journal.encode(_compute(run_dir, manifest, digest)),
                     journal.encode(_compute(run_dir, manifest, digest, zero_intent=False))),
             "settlement_evidence_changed")
    return copy.deepcopy(value)


def verify_coverage(run_dir, receipt, binding, *, recovery_fence, validate_inputs):
    """Exact-True parser_context callback for a caller-selected trusted run path."""
    manifest, digest = _manifest(run_dir, receipt.get("execution_manifest_sha256"))
    value = verify_settlement(run_dir, expected_sha256=receipt.get("settlement_sha256"),
                              recovery_fence=recovery_fence, validate_inputs=validate_inputs)
    _require(value["status"] == "succeeded" and _same(receipt, _coverage(manifest, digest, receipt["settlement_sha256"])),
             "coverage_not_successful")
    request = journal._json(journal._unseal(manifest["inputs"]["request"]))
    expected = {"session_id": manifest["session_id"], "run_id": manifest["run_id"], "source": receipt["source"],
                "parser": receipt["parser"], "admission": request["admission"]}
    _require(_same(binding, expected), "coverage_binding_changed")
    raw, _ = durable._read(run_dir / "successful-coverage.json")
    _require(raw == journal.encode(receipt), "coverage_changed")
    return True
