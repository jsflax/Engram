"""Runner-owned authority for journaled cursor and queue transitions.

All entry points require the caller's worker -> enqueue locks. Paths come from
the executing runner, never a retained ticket. This module does not run a
provider or replay a memory operation. It keeps the active ticket reachable
until publication and queue acknowledgment are both durable.
"""
from __future__ import annotations

import copy
import datetime as dt
from dataclasses import dataclass
import os
from pathlib import Path
import uuid

from . import admission, execution_context as contexts, execution_manifest as journal
from . import host_admission, memory_config, migration as durable, operation_probe, parser_context
from . import publication_coordinator as coordinator, publication_journal as publication
from . import writer_fence, settlement, legacy_reconciliation


class Outcome(str):
    """Queue already acknowledged by the durable coordinator."""
    def __new__(cls, result, request_id):
        value = super().__new__(cls, result)
        value.request_id = request_id
        return value


def _require(ok, reason):
    if not ok:
        raise ValueError("runner_publication_" + reason)


def _same(left, right):
    return journal.encode({"value": left}) == journal.encode({"value": right})


def _record(path):
    raw, identity = durable._read(path)
    return raw, journal._json(raw), identity


def _image(plan, role, version):
    return publication._raw(plan["records"][role][version], old=version == "old")


def _reference(summary):
    return {key: summary[key] for key in ("ticket_id", "ticket_sha256")}


def _outcome(result):
    action = {"processing": "none", "more": "keep", "succeeded": "delete", "no_change": "delete",
              "deferred": "delete", "failed": "pause", "backoff": "pause", "blocked": "pause",
              "reconciliation_required": "pause"}[result]
    return {"result": result, "queue_action": action,
            "pause_reason": result if action == "pause" else None}


def _authority(record):
    return {key: value for key, value in record.items() if key != "last_event"}


@dataclass
class Execution:
    paths: contexts.ContextPaths
    context: contexts.ExecutionContext
    fence: writer_fence.HeldFence
    marker: dict

    def close(self):
        self.fence.close()

    def specification(self):
        return {**self.paths.check(), "manifest_sha256": self.context.manifest_sha256}


class Publications:
    def __init__(self, root, config_path, plugin_root, *, legacy_paths=None, legacy_verify_locks=None):
        for path in (root, plugin_root):
            _require(isinstance(path, Path) and path.is_absolute()
                     and path.resolve(strict=True) == path, "untrusted_paths")
        _require(isinstance(config_path, Path) and config_path.is_absolute()
                 and config_path.parent.resolve(strict=True) == config_path.parent
                 and not config_path.is_symlink(), "untrusted_paths")
        _require(not durable._directory(root).st_mode & 0o077, "untrusted_root")
        self.root, self.config_path, self.plugin_root = root, config_path, plugin_root
        self._legacy_paths, self._legacy_verify_locks = legacy_paths, legacy_verify_locks

    def paths(self, session_id):
        selected = admission.state_paths(self.root, session_id)
        directory = self.root / "publications"
        durable._mkdir(directory)
        return coordinator.Paths(selected["sessions"], selected["admissions"], selected["pending"],
                                 directory / session_id)

    def context_paths(self, run_id):
        journal._identifier(run_id)
        return contexts.ContextPaths(self.root, self.root / "runs" / run_id,
                                     self.config_path, self.plugin_root)

    def _current_pair(self, view):
        """Permit the journal prefix; after its receipt, allow newer last_event."""
        plan, sid = view["publication"], view["session_id"]
        paths = self.paths(sid)
        published = paths.session_directory / "journals" / view["ticket_id"] / "published.json"
        if not os.path.lexists(published):
            publication._positions(plan, publication.Paths(paths.state, paths.admission, published.parent))
            return True
        expected = {"schema_version": 1, "kind": publication.KIND, "status": "published",
                    "transition_id": view["ticket_id"], "session_id": sid, "request_id": view["request_id"],
                    "prepared_sha256": view["prepared_sha256"],
                    "admission_sha256": plan["records"]["admission"]["new"]["sha256"],
                    "state_sha256": plan["records"]["state"]["new"]["sha256"]}
        _require(_record(published)[0] == durable.encode(expected), "published_receipt_changed")
        _require(_record(paths.state)[0] == _image(plan, "state", "new"), "published_cursor_changed")
        _require(_same(_authority(_record(paths.admission)[1]),
                       _authority(journal._json(_image(plan, "admission", "new")))),
                 "published_admission_changed")
        return True

    def _source_transition(self, view, inputs, *, marker=False, advances=False):
        """Bind a proposed cursor to exactly the originally consumed interval."""
        plan = view["publication"]
        request = journal._json(journal._unseal(inputs["request"]))
        original = journal._unseal(inputs["cursor"])
        previous = journal._json(original)
        old_record = journal._json(_image(plan, "admission", "old"))
        next_record = journal._json(_image(plan, "admission", "new"))
        next_state = journal._json(_image(plan, "state", "new"))
        _require(request["session_id"] == view["session_id"]
                 and request["request_id"] == view["request_id"]
                 and _same(request["admission"], view["binding"])
                 and _image(plan, "state", "old") == original, "original_inputs_changed")
        original_record = journal._json(journal._unseal(inputs["admission"]))
        expected_old = _authority(original_record)
        if not marker and view["input_evidence"]["kind"] == "execution":
            expected_old.update(processing=view["request_id"], processing_execution={
                key: view["run_evidence"][key] for key in ("run_id", "manifest_sha256")})
        _require(_same(_authority(old_record), expected_old), "original_admission_changed")
        if marker:
            _require(_image(plan, "state", "new") == original, "marker_cursor_changed")
            coordinator._marker(view, plan)
        else:
            _require(next_record.get("processing") is None and "processing_execution" not in next_record,
                     "processing_not_cleared")
            expected_record = {**old_record, "processing": None,
                               "state_sha256": durable.object_digest(next_state)}
            expected_record.pop("processing_execution", None)
            _require(_same(next_record, expected_record), "next_admission_changed")
            expected_parser = (journal._json(journal._unseal(inputs["next_parser_state"])) if advances
                               else contexts._parser_state(previous))
            _require(_same(contexts._parser_state(next_state), expected_parser), "next_parser_changed")
            for key in ("session_id", "transcript_path", "identity", "admission"):
                _require(key in next_state and _same(next_state[key], previous[key]), "next_binding_changed")
            _require("device" not in next_state and "inode" not in next_state, "legacy_cursor")
        self._current_pair(view)
        return True

    def _pin_marker(self, run_dir, summary):
        reference = _reference(summary)
        coordinator._immutable(run_dir / "processing-publication.json", reference, "processing_publication")
        return reference

    def begin(self, request, state, excerpt, config):
        """Probe and seal before journaled processing; no provider is invoked."""
        _require(request["admission"].get("mode") == host_admission.MODE_V2, "v2_required")
        runs = self.root / "runs"
        durable._mkdir(runs)
        run_id = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex
        durable._mkdir(runs / run_id)
        paths = self.context_paths(run_id)
        durable._mkdir(paths.run_dir / "workspace")
        binding = writer_fence.create(paths.run_dir, generation_id=str(uuid.uuid4()), owner_id=str(uuid.uuid4()))
        fence = writer_fence.acquire_shared(paths.run_dir, binding)
        try:
            _, memory = memory_config.resolve(self.config_path, self.plugin_root)
            transport = contexts.effective_transport(paths, memory_config.transport(memory))
            scope = operation_probe.probe_scope(transport, writer_fence=fence, expected_binding=binding)
            context = contexts.seal_execution(paths, host="codex", request=request, state=state, excerpt=excerpt,
                expected_next_parser=contexts._next_parser(excerpt), memory=memory, transport=transport,
                scope=scope, writer_fence=fence, max_chars=config["max_chars"],
                max_scan_bytes=config["max_scan_bytes"])
            manifest, digest = journal.read_manifest(paths.run_dir)
            selected = self.paths(request["session_id"])
            state_raw, current_state, _ = _record(selected.state)
            admission_raw, record, _ = _record(selected.admission)
            pending_raw, pending, _ = _record(selected.pending)
            _require(_same(current_state, state) and _same(pending, request),
                     "request_changed_before_marker")
            execution_reference = {"run_id": run_id, "manifest_sha256": digest}
            run_evidence = {**execution_reference, "has_more": excerpt.has_more}
            def validate(view, phase):
                _require(_same(view["run_evidence"], run_evidence)
                         and _same(view["input_evidence"], {"kind": "execution", **run_evidence}),
                         "marker_evidence_changed")
                context.validate_marker(manifest)
                return self._source_transition(view, manifest["inputs"], marker=True)
            summary = coordinator.start(selected, ticket_id=str(uuid.uuid4()),
                session_id=request["session_id"], request_id=request["request_id"], binding=request["admission"],
                expected_old_state_sha256=durable.digest(state_raw),
                expected_old_admission_sha256=durable.digest(admission_raw),
                expected_pending_sha256=durable.digest(pending_raw), new_state=state,
                new_admission={**record, "processing": request["request_id"], "processing_execution": execution_reference},
                input_evidence={"kind": "execution", **run_evidence}, run_evidence=run_evidence,
                outcome=_outcome("processing"), validate=validate)
            marker = self._pin_marker(paths.run_dir, summary)
            coordinator.acknowledge(selected, session_id=request["session_id"], validate=validate)
            return Execution(paths, context, fence, marker)
        except BaseException:
            fence.close()
            raise

    def parser(self, request, state, excerpt, next_state, config, *, reason):
        """No-provider publication, including empty EOF, with bounded evidence."""
        selected = self.paths(request["session_id"])
        context = parser_context.ParserContext(self.root, request["session_id"])
        evidence = context.capture(request, state, excerpt, contexts._next_parser(excerpt),
            reason=reason, max_chars=config["max_chars"], max_scan_bytes=config["max_scan_bytes"])
        state_raw, _, _ = _record(selected.state)
        admission_raw, record, _ = _record(selected.admission)
        pending_raw, pending, _ = _record(selected.pending)
        _require(_same(pending, request), "request_changed_before_parser_publication")
        result = "more" if excerpt.has_more else "no_change"
        proposed = {**state, **next_state, "admission": request["admission"], "status": reason}
        next_record = {**record, "processing": None, "state_sha256": durable.object_digest(proposed)}
        next_record.pop("processing_execution", None)
        def validate(view, phase):
            _require(_same(view["input_evidence"], {"kind": "parser", "evidence": evidence})
                     and view["run_evidence"] is None and view["outcome"]["result"] == result,
                     "parser_evidence_changed")
            context.validate_source(evidence, phase)
            _require(journal._json(_image(view["publication"], "state", "new"))["status"] == reason,
                     "parser_status_changed")
            return self._source_transition(view, evidence["inputs"], advances=True)
        coordinator.start(selected, ticket_id=str(uuid.uuid4()), session_id=request["session_id"],
            request_id=request["request_id"], binding=request["admission"],
            expected_old_state_sha256=durable.digest(state_raw),
            expected_old_admission_sha256=durable.digest(admission_raw),
            expected_pending_sha256=durable.digest(pending_raw), new_state=proposed, new_admission=next_record,
            input_evidence={"kind": "parser", "evidence": evidence}, run_evidence=None,
            outcome=_outcome(result), validate=validate)
        coordinator.acknowledge(selected, session_id=request["session_id"], validate=validate)
        return Outcome(result, request["request_id"])

    def _marker(self, paths, manifest):
        reference = _record(paths.run_dir / "processing-publication.json")[1]
        journal._keys(reference, {"ticket_id", "ticket_sha256"})
        retained = coordinator.read_completed(self.paths(manifest["session_id"]),
            session_id=manifest["session_id"], **reference)
        ticket = retained["ticket"]
        expected = {"run_id": paths.run_dir.name, "manifest_sha256": journal.sha256(journal.encode(manifest)),
                    "has_more": ticket["run_evidence"].get("has_more")}
        _require(type(expected["has_more"]) is bool and _same(ticket["run_evidence"], expected)
                 and ticket["outcome"] == _outcome("processing")
                 and _image(retained["publication"], "state", "old") == journal._unseal(manifest["inputs"]["cursor"]),
                 "marker_changed")
        return reference, retained

    def _revoke(self, paths, manifest, digest, *, view=None):
        request = journal._json(journal._unseal(manifest["inputs"]["request"]))
        def validate(binding, phase):
            _require(_same(binding, manifest["fencing"]), "fence_changed")
            contexts.validate_recovery_inputs(paths, manifest_sha256=digest)
            if view is None:
                selected = self.paths(manifest["session_id"])
                current_raw, _, _ = _record(selected.state)
                _, record, _ = _record(selected.admission)
                original = journal._json(journal._unseal(manifest["inputs"]["admission"]))
                expected = {**_authority(original), "processing": request["request_id"],
                            "processing_execution": {"run_id": paths.run_dir.name, "manifest_sha256": digest}}
                _require(current_raw == journal._unseal(manifest["inputs"]["cursor"])
                         and _same(_authority(record), expected), "processing_changed")
            else:
                self._current_pair(view)
            return True
        return writer_fence.revoke(paths.run_dir, manifest["fencing"], validate=validate)

    def _outcome_validator(self, paths, manifest, context, fence, marker_reference, settlement_sha):
        """After revocation, only a verified settlement can select cursor motion."""
        expected_execution = {"run_id": paths.run_dir.name,
                              "manifest_sha256": context.manifest_sha256}
        def validate(view, phase):
            _require(_same(view["input_evidence"], {"kind": "execution", **expected_execution})
                     and _same(view["run_evidence"], {**expected_execution,
                         "settlement_sha256": settlement_sha, "marker": marker_reference}),
                     "outcome_evidence_changed")
            reference, marker = self._marker(paths, manifest)
            _require(_same(reference, marker_reference), "marker_changed")
            verified = settlement.verify_settlement(paths.run_dir, expected_sha256=settlement_sha,
                recovery_fence=fence, validate_inputs=lambda value, _: context.validate_source_backend(value))
            success = verified["status"] == "succeeded"
            expected_result = ("more" if marker["ticket"]["run_evidence"]["has_more"] else "succeeded") if success else verified["status"]
            _require(_same(view["outcome"], _outcome(expected_result)), "outcome_changed")
            new_state = journal._json(_image(view["publication"], "state", "new"))
            _require(new_state.get("status") == verified["status"]
                     and new_state.get("last_run") == paths.run_dir.name
                     and new_state.get("settlement_sha256") == settlement_sha, "state_outcome_changed")
            if success:
                _require("reconciliation_required" not in new_state
                         and new_state.get("last_excerpt_sha256") == manifest["source"]["excerpt_sha256"],
                         "success_state_changed")
            elif verified["status"] == "reconciliation_required":
                _require(_same(new_state.get("reconciliation_required"), {
                    "run_id": paths.run_dir.name, "reason": verified["reason"],
                    "issues": verified["issues"], "memory_ids": verified["memory_ids"],
                    "settlement_sha256": settlement_sha}), "hold_changed")
            return self._source_transition(view, manifest["inputs"], advances=success)
        return validate

    def finish(self, execution, config):
        """Drain writers, freeze settlement, then publish and acknowledge."""
        execution.close()
        paths = execution.paths
        manifest, digest = journal.read_manifest(paths.run_dir)
        with self._revoke(paths, manifest, digest) as fence:
            return self._finish_revoked(paths, manifest, digest, fence, config)

    def _finish_revoked(self, paths, manifest, digest, fence, config):
        context = contexts.load_execution(paths, manifest_sha256=digest, writer_fence=fence,
                                          source_backend_only=True)
        if not os.path.lexists(paths.run_dir / "settlement.json"):
            settlement.reconcile_statuses(paths.run_dir, manifest_sha256=digest, recovery_fence=fence,
                transport=context.transport,
                validate_inputs=lambda value, _: context.validate_source_backend(value))
        verified = settlement.settle(paths.run_dir, manifest_sha256=digest, recovery_fence=fence,
            validate_inputs=lambda value, _: context.validate_source_backend(value))
        marker_reference, marker = self._marker(paths, manifest)
        request = journal._json(journal._unseal(manifest["inputs"]["request"]))
        state = journal._json(journal._unseal(manifest["inputs"]["cursor"]))
        selected = self.paths(manifest["session_id"])
        state_raw, current, _ = _record(selected.state)
        admission_raw, record, _ = _record(selected.admission)
        pending_raw, _, _ = _record(selected.pending)
        _require(_same(current, state), "cursor_changed_before_outcome")
        now = dt.datetime.now(dt.timezone.utc)
        next_state = {**state, "status": verified["status"], "last_run": paths.run_dir.name,
                      "settlement_sha256": verified["settlement_sha256"], "updated_at": now.isoformat()}
        if verified["status"] == "succeeded":
            next_state.update(journal._json(journal._unseal(manifest["inputs"]["next_parser_state"])))
            next_state.update(last_excerpt_sha256=manifest["source"]["excerpt_sha256"],
                              last_success_at=now.isoformat(), successful_coverage=verified["coverage_reference"])
            for key in ("retry_after", "reconciliation_required"):
                next_state.pop(key, None)
            result = "more" if marker["ticket"]["run_evidence"]["has_more"] else "succeeded"
        else:
            result = verified["status"]
            next_state["retry_after"] = now.timestamp() + config["retry_seconds"]
            if result == "reconciliation_required":
                next_state["reconciliation_required"] = {
                    "run_id": paths.run_dir.name, "reason": verified["reason"],
                    "issues": verified["issues"], "memory_ids": verified["memory_ids"],
                    "settlement_sha256": verified["settlement_sha256"]}
        next_record = {**record, "state_sha256": durable.object_digest(next_state), "processing": None}
        next_record.pop("processing_execution", None)
        reference = {"run_id": paths.run_dir.name, "manifest_sha256": digest}
        validate = self._outcome_validator(paths, manifest, context, fence, marker_reference,
                                           verified["settlement_sha256"])
        coordinator.start(selected, ticket_id=str(uuid.uuid4()), session_id=manifest["session_id"],
            request_id=request["request_id"], binding=request["admission"],
            expected_old_state_sha256=durable.digest(state_raw),
            expected_old_admission_sha256=durable.digest(admission_raw),
            expected_pending_sha256=durable.digest(pending_raw), new_state=next_state, new_admission=next_record,
            input_evidence={"kind": "execution", **reference},
            run_evidence={**reference, "settlement_sha256": verified["settlement_sha256"], "marker": marker_reference},
            outcome=_outcome(result), validate=validate, completed_marker=marker_reference)
        coordinator.acknowledge(selected, session_id=manifest["session_id"], validate=validate)
        return Outcome(result, request["request_id"])

    def recover(self, session_id, config):
        """Complete the exact active transition before ordinary pair validation.

        An interrupted processing marker leads to fenced settlement, never a
        second provider launch. Unjournaled old markers remain explicit holds.
        """
        selected = self.paths(session_id)
        active = coordinator._active(selected, session_id)
        legacy_selected = active is not None and active[0]["input_evidence"].get("kind") == legacy_reconciliation.KIND
        if active is None:
            legacy_selected = legacy_reconciliation.needs_recovery(self.root, session_id)
        if legacy_selected:
            _require(callable(self._legacy_paths) and callable(self._legacy_verify_locks),
                     "legacy_trusted_paths_and_locks_required")
            legacy_paths = self._legacy_paths()
            _require(type(legacy_paths) is legacy_reconciliation.LegacyPaths and legacy_paths.root == self.root
                     and legacy_paths.package_root == self.plugin_root, "legacy_paths_changed")
            resolved = legacy_reconciliation.recover_locked(legacy_paths, session_id=session_id,
                verify_locks=self._legacy_verify_locks)
            if resolved is not None:
                completed = coordinator.read_completed(selected, session_id=session_id, **resolved["publication"])
                return Outcome(legacy_reconciliation.RESULT, completed["ticket"]["request_id"])
        if active is not None:
            ticket = active[0]
            view = {**ticket, "publication": coordinator._plan(selected, ticket)}
            evidence = ticket["input_evidence"]
            if evidence.get("kind") == "parser":
                journal._keys(evidence, {"kind", "evidence"})
                frozen = evidence["evidence"]
                parser = parser_context.ParserContext(self.root, session_id)
                def validate(current, phase):
                    _require(_same(current["input_evidence"], evidence) and current["run_evidence"] is None
                             and current["outcome"]["result"] in {"more", "no_change"}, "parser_evidence_changed")
                    parser.validate_source(frozen, phase)
                    _require(journal._json(_image(current["publication"], "state", "new"))["status"] == frozen["reason"],
                             "parser_status_changed")
                    return self._source_transition(current, frozen["inputs"], advances=True)
                coordinator.acknowledge(selected, session_id=session_id, validate=validate)
                return Outcome(ticket["outcome"]["result"], ticket["request_id"])
            _require(evidence.get("kind") == "execution", "unknown_evidence")
            paths = self.context_paths(evidence["run_id"])
            manifest, digest = journal.read_manifest(paths.run_dir)
            _require(digest == evidence["manifest_sha256"] and manifest["session_id"] == session_id,
                     "execution_changed")
            if ticket["outcome"]["result"] == "processing":
                with writer_fence.acquire_shared(paths.run_dir, manifest["fencing"]) as fence:
                    context = contexts.load_execution(paths, manifest_sha256=digest, writer_fence=fence, before_marker=True)
                    def validate(current, phase):
                        _require(_same(current["run_evidence"], ticket["run_evidence"])
                                 and _same(current["input_evidence"], {"kind": "execution", **ticket["run_evidence"]})
                                 and type(ticket["run_evidence"].get("has_more")) is bool,
                                 "marker_evidence_changed")
                        context.validate_marker(manifest)
                        return self._source_transition(current, manifest["inputs"], marker=True)
                    summary = coordinator.recover(selected, session_id=session_id, validate=validate)
                    self._pin_marker(paths.run_dir, summary)
                    coordinator.acknowledge(selected, session_id=session_id, validate=validate)
            else:
                with self._revoke(paths, manifest, digest, view=view) as fence:
                    context = contexts.load_execution(paths, manifest_sha256=digest, writer_fence=fence,
                                                      source_backend_only=True)
                    validate = self._outcome_validator(paths, manifest, context, fence,
                        ticket["run_evidence"]["marker"], ticket["run_evidence"]["settlement_sha256"])
                    coordinator.acknowledge(selected, session_id=session_id, validate=validate)
                    return Outcome(ticket["outcome"]["result"], ticket["request_id"])
        _, record, _ = _record(selected.admission)
        if record.get("processing") is None:
            _require("processing_execution" not in record, "orphan_execution_reference")
            return None
        reference = record.get("processing_execution")
        _require(type(reference) is dict and set(reference) == {"run_id", "manifest_sha256"},
                 "unjournaled_processing")
        paths = self.context_paths(reference["run_id"])
        manifest, digest = journal.read_manifest(paths.run_dir)
        _require(digest == reference["manifest_sha256"] and manifest["session_id"] == session_id,
                 "processing_manifest_changed")
        self._marker(paths, manifest)
        with self._revoke(paths, manifest, digest) as fence:
            return self._finish_revoked(paths, manifest, digest, fence, config)
