"""Private synthetic state only, including actual child SIGKILL boundaries."""
import copy
import importlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
import uuid
from unittest import mock

from suite_support import PLUGIN_ROOT

sys.path.insert(0, str(PLUGIN_ROOT / "scripts"))
C = importlib.import_module("codex_learner.publication_coordinator")
P = C.publication


class PublicationCoordinatorTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="publication-coordinator-")
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name).resolve()
        for name in ("states", "admissions", "pending", "publications"):
            (self.base / name).mkdir(mode=0o700)
        self.sid, self.request = "fixture-session", "fixture-request"
        self.ticket_id = "11111111-2222-4333-8444-555555555555"
        self.paths = C.Paths(self.base / "states" / (self.sid + ".json"),
                             self.base / "admissions" / (self.sid + ".json"),
                             self.base / "pending" / (self.sid + ".json"),
                             self.base / "publications" / self.sid)
        self.binding = {"session_id": self.sid, "frontier_offset": 5, "activation_id": "fixture-activation"}
        self.old_state = {"session_id": self.sid, "offset": 10, "admission": self.binding,
                          "recent_messages": ["preserved"], "current_turn_id": "old-turn"}
        self.old_record = {"binding": self.binding, "state_sha256": C.durable.object_digest(self.old_state),
                           "processing": self.request, "last_event": "a" * 64}
        self.new_state = {**self.old_state, "offset": 20, "status": "succeeded"}
        self.new_record = {**self.old_record, "state_sha256": C.durable.object_digest(self.new_state), "processing": None}
        self.pending = {"session_id": self.sid, "request_id": self.request, "admission": self.binding,
                        "size_bytes": 100, "event": "Stop"}
        self.policy = self.base / "policy.json"
        for path, value in ((self.paths.state, self.old_state), (self.paths.admission, self.old_record),
                            (self.paths.pending, self.pending), (self.policy, self.binding)):
            C.durable._new(path, C.durable.encode(value))
        self.input_evidence = {"policy_sha256": C.durable.digest(self.policy.read_bytes()), "source_interval_sha256": "b" * 64}
        self.run_evidence = {"run_id": "fixture-run", "manifest_sha256": "c" * 64, "reconciliation_sha256": "d" * 64}
        self.outcome = {"result": "succeeded", "queue_action": "delete", "pause_reason": None}
        self.phases = []

    def values(self, **overrides):
        values = dict(ticket_id=self.ticket_id, session_id=self.sid, request_id=self.request, binding=self.binding,
                      expected_old_state_sha256=C.durable.digest(self.paths.state.read_bytes()),
                      expected_old_admission_sha256=C.durable.digest(self.paths.admission.read_bytes()),
                      expected_pending_sha256=C.durable.digest(self.paths.pending.read_bytes()),
                      new_state=self.new_state, new_admission=self.new_record, input_evidence=self.input_evidence,
                      run_evidence=self.run_evidence, outcome=self.outcome, validate=self.validate)
        values.update(overrides)
        return values

    def validate(self, ticket, phase):
        self.phases.append(phase)
        if C.durable.digest(self.policy.read_bytes()) != ticket["input_evidence"]["policy_sha256"]:
            raise ValueError("fixture_policy_changed")
        plan = ticket["publication"]
        raws = [P._raw(plan["records"]["state"][kind], old=kind == "old") for kind in ("old", "new")]
        if self.paths.state.read_bytes() not in raws:
            raise ValueError("fixture_cursor_changed")
        # Permit mixed pairs and newer enqueue metadata, but not changed authority.
        def authority(value):
            return {k: value.get(k) for k in ("binding", "state_sha256", "processing", "processing_execution")}
        current = authority(json.loads(self.paths.admission.read_bytes()))
        allowed = [authority(json.loads(P._raw(plan["records"]["admission"][kind], old=kind == "old")))
                   for kind in ("old", "new")]
        if not any(C._same(current, candidate) for candidate in allowed):
            raise ValueError("fixture_admission_changed")
        return True

    def start(self, **overrides):
        return C.start(self.paths, **self.values(**overrides))

    def recover(self, **overrides):
        return C.recover(self.paths, session_id=self.sid, validate=overrides.get("validate", self.validate))

    def ack(self, **overrides):
        return C.acknowledge(self.paths, session_id=self.sid, validate=overrides.get("validate", self.validate))

    def active(self):
        return self.paths.session_directory / "active.json"

    def record(self, name):
        return self.paths.session_directory / "records" / self.ticket_id / (name + ".json")

    def assert_new_pair(self):
        self.assertEqual(json.loads(self.paths.state.read_bytes()), self.new_state)
        self.assertEqual(json.loads(self.paths.admission.read_bytes()), self.new_record)

    def interrupt(self, callback, boundary):
        def crash(label):
            if label == boundary:
                raise RuntimeError("fixture_interruption")
        with mock.patch.object(C, "_boundary", side_effect=crash), mock.patch.object(P, "_boundary", side_effect=crash):
            with self.assertRaisesRegex(RuntimeError, "fixture_interruption"):
                callback()

    def test_delete_publishes_then_acknowledges_and_retains_completed_evidence(self):
        original = self.paths.pending.read_bytes()
        started = self.start()
        self.assertEqual(started["status"], "published")
        self.assert_new_pair()
        self.assertEqual(self.paths.pending.read_bytes(), original)
        self.assertFalse(self.record("ack-intent").exists())
        result = self.ack()
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["disposition"], "target")
        self.assertFalse(self.paths.pending.exists())
        self.assertFalse(self.active().exists())
        self.assertTrue(self.record("ack-intent").exists())
        self.assertTrue(self.record("completion").exists())
        self.assertIsNone(self.recover())
        self.assertIsNone(self.ack())

    def test_incomplete_unindexed_container_can_resume_without_adopting_orphans(self):
        for count in range(3):
            with self.subTest(created_children=count):
                self.setUp()
                self.paths.session_directory.mkdir(mode=0o700)
                for name in ("tickets", "journals", "records")[:count]:
                    (self.paths.session_directory / name).mkdir(mode=0o700)
                before = [path.read_bytes() for path in (self.paths.state, self.paths.admission, self.paths.pending)]
                self.assertIsNone(self.recover())
                self.assertEqual(before, [path.read_bytes() for path in (self.paths.state, self.paths.admission, self.paths.pending)])
                self.start()
                self.ack()
                self.assert_new_pair()

    def test_active_or_unsafe_partial_container_never_authorizes_repair(self):
        for kind in ("active", "file", "symlink"):
            with self.subTest(kind=kind):
                self.setUp()
                self.paths.session_directory.mkdir(mode=0o700)
                if kind == "active":
                    C.durable._new(self.active(), b"{}\n")
                elif kind == "file":
                    C.durable._new(self.paths.session_directory / "tickets", b"{}\n")
                else:
                    (self.paths.session_directory / "tickets").symlink_to(self.base / "pending")
                before = [path.read_bytes() for path in (self.paths.state, self.paths.admission, self.paths.pending)]
                with self.assertRaises((OSError, ValueError)):
                    self.recover()
                self.assertEqual(before, [path.read_bytes() for path in (self.paths.state, self.paths.admission, self.paths.pending)])

    def test_pause_is_frozen_and_more_keeps_original_then_allows_next_batch(self):
        for action in ("pause", "keep"):
            with self.subTest(action=action):
                self.setUp()
                self.outcome = {"result": "failed" if action == "pause" else "more", "queue_action": action,
                                "pause_reason": "failed" if action == "pause" else None}
                pending_raw = self.paths.pending.read_bytes()
                self.start()
                self.ack()
                current = json.loads(self.paths.pending.read_bytes())
                if action == "pause":
                    self.assertEqual(current, {**self.pending, "paused_request_id": self.request, "pause_reason": "failed"})
                else:
                    self.assertEqual(self.paths.pending.read_bytes(), pending_raw)
                    self.ticket_id = str(uuid.uuid4())
                    self.new_state = {**self.new_state, "offset": 30}
                    self.new_record = {**self.new_record, "state_sha256": C.durable.object_digest(self.new_state)}
                    self.start()
                    self.ack()
                    self.assertEqual(json.loads(self.paths.state.read_bytes())["offset"], 30)
                    self.assertEqual(self.paths.pending.read_bytes(), pending_raw)

    def test_parser_only_empty_and_duplicate_need_no_native_run_evidence(self):
        for status in ("no_visible_content", "duplicate"):
            with self.subTest(status=status):
                self.setUp()
                self.run_evidence = None
                self.new_state = {**self.old_state, "status": status}
                self.new_record = {**self.old_record, "state_sha256": C.durable.object_digest(self.new_state), "processing": None}
                self.outcome = {"result": "no_change", "queue_action": "delete", "pause_reason": None}
                self.start()
                self.ack()
                self.assertEqual(json.loads(self.paths.state.read_bytes())["offset"], 10)
                self.assertFalse(self.paths.pending.exists())

    def test_marker_retains_exact_indented_state_and_pins_execution_without_queue_ack(self):
        self.old_record["processing"] = None
        original = (json.dumps(self.old_state, indent=2) + "\n").encode()
        self.paths.state.write_bytes(original)
        self.paths.admission.write_bytes(C.durable.encode(self.old_record))
        self.new_state = copy.deepcopy(self.old_state)
        self.new_record = {**self.old_record, "processing": self.request,
                           "processing_execution": {k: self.run_evidence[k] for k in ("run_id", "manifest_sha256")}}
        self.outcome = {"result": "processing", "queue_action": "none", "pause_reason": None}
        inode = self.paths.state.stat().st_ino
        pending = self.paths.pending.read_bytes()
        self.interrupt(self.start, "admission_replaced")
        self.recover()
        self.ack()
        self.assertEqual(self.paths.state.read_bytes(), original)
        self.assertEqual(self.paths.state.stat().st_ino, inode)
        self.assertEqual(self.paths.pending.read_bytes(), pending)
        self.assertEqual(json.loads(self.paths.admission.read_bytes()), self.new_record)
        self.assertTrue(self.record("completion").exists())

    def test_invalid_marker_and_semantic_bool_alias_refuse_before_journal(self):
        self.old_record["processing"] = None
        self.paths.admission.write_bytes(C.durable.encode(self.old_record))
        self.outcome = {"result": "processing", "queue_action": "none", "pause_reason": None}
        self.new_state = copy.deepcopy(self.old_state)
        self.new_record = {**self.old_record, "processing": self.request}
        with self.assertRaisesRegex(ValueError, "invalid_marker_transition"):
            self.start()
        self.assertFalse(self.active().exists())
        self.new_state["offset"] = 10.0
        with self.assertRaisesRegex(ValueError, "preserved_state_changed"):
            self.start()

    def completed_marker(self):
        self.old_record["processing"] = None
        self.paths.admission.write_bytes(C.durable.encode(self.old_record))
        self.new_state = copy.deepcopy(self.old_state)
        self.new_record = {**self.old_record, "processing": self.request,
                           "processing_execution": {k: self.run_evidence[k] for k in ("run_id", "manifest_sha256")}}
        self.outcome = {"result": "processing", "queue_action": "none", "pause_reason": None}
        started = self.start()
        self.ack()
        reference = {k: started[k] for k in ("ticket_id", "ticket_sha256")}
        marker = C.read_completed(self.paths, session_id=self.sid, ticket_id=reference["ticket_id"],
                                  ticket_sha256=reference["ticket_sha256"])
        self.ticket_id = str(uuid.uuid4())
        self.new_state = {**self.old_state, "offset": 20, "status": "succeeded"}
        self.new_record = {**self.old_record, "processing": None, "state_sha256": C.durable.object_digest(self.new_state)}
        self.run_evidence = {**self.run_evidence, "marker": reference}
        self.outcome = {"result": "succeeded", "queue_action": "delete", "pause_reason": None}
        return reference, marker["ticket"]["pending"]

    def test_completed_marker_original_pending_allows_newer_enqueue_before_outcome_publication(self):
        reference, original = self.completed_marker()
        newer = {**self.pending, "request_id": "newer-stop", "size_bytes": 300}
        self.paths.pending.write_bytes(C.durable.encode(newer))
        current = json.loads(self.paths.admission.read_bytes())
        self.paths.admission.write_bytes(C.durable.encode({**current, "last_event": "f" * 64}))
        self.new_record["last_event"] = "f" * 64
        started = self.start(completed_marker=reference, original_pending=original)
        self.assertEqual(started["status"], "published")
        self.assertEqual(self.ack()["disposition"], "newer")
        self.assertEqual(json.loads(self.paths.pending.read_bytes()), newer)
        self.assert_new_pair()

    def test_marker_reference_pending_and_completion_are_required_and_cannot_be_forged(self):
        reference, original = self.completed_marker()
        for change in ({"completed_marker": {**reference, "ticket_sha256": "0" * 64}},
                       {"original_pending": {**original, "sha256": "0" * 64}},
                       {"run_evidence": {**self.run_evidence, "manifest_sha256": "0" * 64}}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.start(**{**dict(completed_marker=reference, original_pending=original), **change})
            self.assertFalse(self.active().exists())
        self.paths.pending.write_bytes(C.durable.encode({**self.pending, "size_bytes": 999}))
        with self.assertRaisesRegex(ValueError, "pending_changed"):
            self.start(completed_marker=reference, original_pending=original)
        self.paths.pending.unlink()
        with self.assertRaises((OSError, ValueError)):
            self.start(completed_marker=reference, original_pending=original)
        completion = self.paths.session_directory / "records" / reference["ticket_id"] / "completion.json"
        completion.unlink()
        with self.assertRaises((OSError, ValueError)):
            C.read_completed(self.paths, session_id=self.sid, ticket_id=reference["ticket_id"],
                             ticket_sha256=reference["ticket_sha256"])

    def test_active_conflict_cannot_publish_second_transition(self):
        self.start()
        before = self.paths.state.read_bytes(), self.paths.admission.read_bytes(), self.paths.pending.read_bytes()
        with self.assertRaisesRegex(ValueError, "active_conflict"):
            self.start(ticket_id=str(uuid.uuid4()))
        self.assertEqual(before, (self.paths.state.read_bytes(), self.paths.admission.read_bytes(), self.paths.pending.read_bytes()))

    def test_more_cannot_delete_pending_and_failed_cannot_drop_its_pause(self):
        for result in ("more", "failed", "reconciliation_required", "legacy_reconciled_no_new_mutation"):
            with self.subTest(result=result), self.assertRaisesRegex(ValueError, "outcome_action_mismatch"):
                self.start(outcome={"result": result, "queue_action": "delete", "pause_reason": None})
            self.assertFalse(self.active().exists())
            self.assertEqual(json.loads(self.paths.pending.read_bytes()), self.pending)

    def test_legacy_reconciliation_keeps_original_pause_and_distinct_outcome(self):
        self.pending.update(paused_request_id=self.request, pause_reason="batch_limit", provenance="retained")
        self.paths.pending.write_bytes(C.durable.encode(self.pending))
        original = self.paths.pending.read_bytes()
        self.outcome = {"result": "legacy_reconciled_no_new_mutation", "queue_action": "keep", "pause_reason": None}
        started = self.start()
        acknowledged = self.ack()
        completed = C.read_completed(self.paths, session_id=self.sid,
            **{key: started[key] for key in ("ticket_id", "ticket_sha256")})
        self.assertEqual(acknowledged["disposition"], "original")
        self.assertEqual(completed["completion"]["outcome"], self.outcome)
        self.assertEqual(self.paths.pending.read_bytes(), original)

    def test_completion_proof_rejects_forged_legal_queue_positions(self):
        for forgery in ("none", "target", "same-id-newer", "changed-original", "unadmitted-newer"):
            with self.subTest(forgery=forgery):
                self.setUp()
                self.outcome = {"result": "legacy_reconciled_no_new_mutation", "queue_action": "keep", "pause_reason": None}
                started = self.start()
                self.interrupt(self.ack, "before_retire")
                completion = json.loads(self.record("completion").read_bytes())
                if forgery in ("none", "target"):
                    completion.update(disposition=forgery, pending=None)
                elif forgery == "same-id-newer":
                    completion["disposition"] = "newer"
                else:
                    pending = json.loads(P._raw(completion["pending"], old=True))
                    pending["provenance"] = "altered"
                    if forgery == "unadmitted-newer":
                        completion["disposition"] = "newer"
                        pending["request_id"] = "another-request"
                        pending["admission"] = {**self.binding, "activation_id": "unrelated-activation"}
                    raw = C.durable.encode(pending)
                    identity = {**completion["pending"]["identity"], "size": len(raw)}
                    completion["pending"] = P._image(raw, identity)
                self.record("completion").write_bytes(C.durable.encode(completion))
                current = [path.read_bytes() for path in (self.paths.state, self.paths.admission, self.paths.pending)]
                with self.assertRaisesRegex(ValueError, "invalid_completion"):
                    C.read_completed(self.paths, session_id=self.sid,
                        **{key: started[key] for key in ("ticket_id", "ticket_sha256")})
                with self.assertRaisesRegex(ValueError, "invalid_completion"):
                    self.ack()
                self.assertTrue(self.active().exists())
                self.assertEqual(current, [path.read_bytes() for path in (self.paths.state, self.paths.admission, self.paths.pending)])

    def test_completion_proof_binds_delete_and_pause_to_their_actual_target(self):
        for action in ("delete", "pause"):
            with self.subTest(action=action):
                self.setUp()
                self.outcome = {"result": "failed" if action == "pause" else "succeeded", "queue_action": action,
                                "pause_reason": "failed" if action == "pause" else None}
                started = self.start()
                self.interrupt(self.ack, "before_retire")
                completion = json.loads(self.record("completion").read_bytes())
                if action == "delete":
                    completion["disposition"] = "none"
                else:
                    pending = json.loads(P._raw(completion["pending"], old=True))
                    pending["pause_reason"] = "backoff"
                    raw = C.durable.encode(pending)
                    completion["pending"] = P._image(raw, {**completion["pending"]["identity"], "size": len(raw)})
                self.record("completion").write_bytes(C.durable.encode(completion))
                with self.assertRaisesRegex(ValueError, "invalid_completion_position"):
                    C.read_completed(self.paths, session_id=self.sid,
                        **{key: started[key] for key in ("ticket_id", "ticket_sha256")})

    def test_completion_proof_does_not_accept_pending_for_processing_marker(self):
        reference, original = self.completed_marker()
        path = self.paths.session_directory / "records" / reference["ticket_id"] / "completion.json"
        completion = json.loads(path.read_bytes())
        completion.update(disposition="newer", pending=original)
        path.write_bytes(C.durable.encode(completion))
        with self.assertRaisesRegex(ValueError, "invalid_completion_position"):
            C.read_completed(self.paths, session_id=self.sid, **reference)

    def test_completed_newer_queue_proof_requires_safe_file_identity(self):
        for key, value in (("mode", 0o100644), ("mode", 0o010600), ("uid", os.getuid() + 1),
                           ("nlink", 2), ("size", 0), ("inode", 0)):
            with self.subTest(key=key, value=value):
                self.setUp()
                started = self.start()
                newer = {**self.pending, "request_id": "newer-request"}
                self.paths.pending.write_bytes(C.durable.encode(newer))
                self.interrupt(self.ack, "before_retire")
                completion = json.loads(self.record("completion").read_bytes())
                self.assertEqual(completion["disposition"], "newer")
                completion["pending"]["identity"][key] = value
                self.record("completion").write_bytes(C.durable.encode(completion))
                with self.assertRaisesRegex(ValueError, "invalid_completion_pending_identity"):
                    C.read_completed(self.paths, session_id=self.sid,
                        **{field: started[field] for field in ("ticket_id", "ticket_sha256")})

    def test_unindexed_orphan_is_inert_and_never_adopted(self):
        self.interrupt(self.start, "ticket_directory_fsynced")
        self.assertIsNone(self.recover())
        self.assertEqual(json.loads(self.paths.state.read_bytes()), self.old_state)
        with self.assertRaises(ValueError):
            self.start()
        self.start(ticket_id=str(uuid.uuid4()))
        self.assert_new_pair()

    def test_partial_active_index_blocks_without_pair_or_pending_mutation(self):
        self.interrupt(self.start, "index_created")
        for action in (self.recover, self.ack, lambda: self.start(ticket_id=str(uuid.uuid4()))):
            with self.assertRaises(ValueError):
                action()
        self.assertEqual(json.loads(self.paths.state.read_bytes()), self.old_state)
        self.assertEqual(json.loads(self.paths.pending.read_bytes()), self.pending)

    def test_broken_session_symlink_and_replaced_active_index_refuse(self):
        self.paths.session_directory.symlink_to(self.base / "missing")
        with self.assertRaises(ValueError):
            self.recover()
        self.paths.session_directory.unlink()
        self.start()
        original = self.active().read_bytes()
        def replace_index(view, phase):
            self.validate(view, phase)
            if phase == "before_retire":
                stage = self.paths.session_directory / "replacement-index"
                C.durable._new(stage, original)
                os.replace(stage, self.active())
            return True
        with self.assertRaisesRegex(ValueError, "active_changed"):
            self.ack(validate=replace_index)
        self.assertTrue(self.active().exists())
        self.assertTrue(self.record("completion").exists())

    def test_missing_or_preexisting_ack_target_is_not_our_ack_without_intent(self):
        for action in ("delete", "pause"):
            with self.subTest(action=action):
                self.setUp()
                self.outcome = {"result": "failed" if action == "pause" else "succeeded", "queue_action": action,
                                "pause_reason": "failed" if action == "pause" else None}
                self.start()
                if action == "delete":
                    self.paths.pending.unlink()
                else:
                    self.paths.pending.write_bytes(C.durable.encode({**self.pending, "paused_request_id": self.request, "pause_reason": "failed"}))
                with self.assertRaises(ValueError):
                    self.ack()
                self.assertTrue(self.active().exists())
                self.assertFalse(self.record("ack-intent").exists())

    def test_newer_enqueue_after_publication_is_preserved_same_id_change_refuses(self):
        for same_id in (False, True):
            with self.subTest(same_id=same_id):
                self.setUp()
                self.start()
                admission = {**self.new_record, "last_event": "e" * 64}
                self.paths.admission.write_bytes(C.durable.encode(admission))
                pending = {**self.pending, "request_id": self.request if same_id else "newer-request", "size_bytes": 200}
                self.paths.pending.write_bytes(C.durable.encode(pending))
                preserved = self.paths.pending.read_bytes(), self.paths.admission.read_bytes()
                self.recover()  # Does not republish the older admission image.
                if same_id:
                    with self.assertRaisesRegex(ValueError, "pending_changed"):
                        self.ack()
                    self.assertTrue(self.active().exists())
                else:
                    self.assertEqual(self.ack()["disposition"], "newer")
                    self.assertFalse(self.active().exists())
                self.assertEqual(preserved, (self.paths.pending.read_bytes(), self.paths.admission.read_bytes()))

    def test_same_request_unchanged_pending_and_new_last_event_can_ack(self):
        self.start()
        updated = C.durable.encode({**self.new_record, "last_event": "f" * 64})
        self.paths.admission.write_bytes(updated)
        self.ack()
        self.assertFalse(self.paths.pending.exists())
        self.assertEqual(self.paths.admission.read_bytes(), updated)

    def test_changed_pair_without_published_receipt_is_still_strict(self):
        self.interrupt(self.start, "publication_complete")
        receipt = self.paths.session_directory / "journals" / self.ticket_id / "published.json"
        receipt.unlink()
        newer = C.durable.encode({**self.new_record, "last_event": "e" * 64})
        self.paths.admission.write_bytes(newer)
        with self.assertRaises(ValueError):
            self.recover()
        self.assertEqual(self.paths.admission.read_bytes(), newer)

    def test_pending_cas_rechecks_after_validator_and_refuses_identical_replacement(self):
        self.start()
        original = self.paths.pending.read_bytes()
        def replacement(view, phase):
            self.validate(view, phase)
            if phase == "replace_pending":
                temporary = self.paths.pending.parent / "replacement"
                C.durable._new(temporary, original)
                os.replace(temporary, self.paths.pending)
            return True
        with self.assertRaisesRegex(ValueError, "pending_changed"):
            self.ack(validate=replacement)
        self.assertEqual(self.paths.pending.read_bytes(), original)
        self.assertFalse(self.record("completion").exists())

    def test_policy_and_unrelated_cursor_changes_refuse_even_after_publication(self):
        for target in ("policy", "state"):
            with self.subTest(target=target):
                self.setUp()
                self.start()
                path = self.policy if target == "policy" else self.paths.state
                path.write_bytes(C.durable.encode({"unrelated": "change"}))
                with self.assertRaises(ValueError):
                    self.ack()
                self.assertTrue(self.paths.pending.exists())
                self.assertFalse(self.record("ack-intent").exists())

    def test_exact_true_validator_and_callback_aliasing(self):
        for refused in (False, None, 1, "yes"):
            with self.subTest(refused=refused), self.assertRaisesRegex(ValueError, "validation_refused"):
                self.start(validate=lambda _ticket, _phase: refused)
            self.assertFalse(self.active().exists())
        def mutate(view, phase):
            self.validate(view, phase)
            view["outcome"]["queue_action"] = "keep"
            view["publication"]["records"]["state"]["new"] = view["publication"]["records"]["state"]["old"]
            return True
        self.start(validate=mutate)
        self.ack(validate=mutate)
        self.assertFalse(self.paths.pending.exists())
        self.assert_new_pair()

    def test_validation_refusal_at_ack_boundaries_leaves_only_recoverable_prefix(self):
        for phase in ("before_ack_intent", "before_ack", "replace_pending", "before_completion", "before_retire"):
            for refused in (False, None):
                with self.subTest(phase=phase, refused=refused):
                    self.setUp()
                    self.start()
                    def validator(view, current):
                        self.validate(view, current)
                        return refused if current == phase else True
                    with self.assertRaisesRegex(ValueError, "validation_refused"):
                        self.ack(validate=validator)
                    self.assertTrue(self.active().exists())
                    if phase in {"before_ack_intent", "before_ack", "replace_pending"}:
                        self.assertEqual(json.loads(self.paths.pending.read_bytes()), self.pending)
                    self.ack()
                    self.assertFalse(self.active().exists())
                    self.assertFalse(self.paths.pending.exists())

    def test_ticket_index_ack_and_completion_tampering_fail_closed(self):
        for target in ("ticket", "index", "ack-intent", "completion"):
            with self.subTest(target=target):
                self.setUp()
                self.start()
                if target in {"ack-intent", "completion"}:
                    self.interrupt(self.ack, "before_retire" if target == "completion" else "ack_intent_directory_fsynced")
                path = self.record(target) if target in {"ack-intent", "completion"} else (
                    self.active() if target == "index" else self.paths.session_directory / "tickets" / (self.ticket_id + ".json"))
                path.write_bytes(b'{"version":1,"version":2}\n')
                with self.assertRaises(ValueError):
                    self.ack()
                self.assertTrue(self.active().exists())

    def test_completed_ack_retirement_preserves_newer_pending(self):
        self.start()
        self.interrupt(self.ack, "completion_directory_fsynced")
        newer = {**self.pending, "request_id": "next-request"}
        C.durable._new(self.paths.pending, C.durable.encode(newer))
        self.paths.admission.write_bytes(C.durable.encode({**self.new_record, "last_event": "e" * 64}))
        self.ack()
        self.assertEqual(json.loads(self.paths.pending.read_bytes()), newer)
        self.assertFalse(self.active().exists())

    def test_real_sigkill_at_pin_publication_ack_and_retirement_boundaries(self):
        cases = [(phase, "start", "delete") for phase in
                 ("ticket_created", "ticket_file_fsynced", "ticket_directory_fsynced", "index_created",
                  "index_written", "index_file_fsynced", "index_directory_fsynced",
                  "admission_replaced", "state_replaced", "published_replaced")]
        cases += [(phase, "ack", action) for action in ("delete", "pause") for phase in
                  ("ack_intent_stage_created", "ack_intent_installed", "ack_intent_directory_fsynced",
                   "pending_mutated", "pending_directory_fsynced", "completion_stage_created",
                   "completion_installed", "completion_directory_fsynced", "before_retire", "active_unlinked",
                   "active_directory_fsynced")]
        for phase, method, action in cases:
            with self.subTest(phase=phase, action=action):
                self.setUp()
                if action == "pause":
                    self.outcome = {"result": "failed", "queue_action": "pause", "pause_reason": "failed"}
                kwargs = self.values()
                kwargs.pop("validate")
                if method == "ack":
                    self.start()
                payload = {"paths": {k: str(getattr(self.paths, k)) for k in self.paths.__dataclass_fields__},
                           "kwargs": kwargs, "phase": phase, "method": method}
                script = r'''
import json, os, signal, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from codex_learner import publication_coordinator as C
d=json.loads(sys.argv[2]); paths=C.Paths(**{k:Path(v) for k,v in d["paths"].items()})
def crash(label):
    if label == d["phase"]: os.kill(os.getpid(), signal.SIGKILL)
C._boundary=crash; C.publication._boundary=crash
if d["method"] == "start": C.start(paths, **d["kwargs"], validate=lambda _t,_p: True)
else: C.acknowledge(paths,session_id=d["kwargs"]["session_id"],validate=lambda _t,_p: True)
'''
                child = subprocess.run([sys.executable, "-B", "-c", script, str(PLUGIN_ROOT / "scripts"), json.dumps(payload)],
                                       capture_output=True, text=True, timeout=10)
                self.assertEqual(child.returncode, -signal.SIGKILL, child.stderr)
                if phase.startswith("ticket_"):
                    self.assertIsNone(self.recover())
                    self.assertEqual(json.loads(self.paths.state.read_bytes()), self.old_state)
                    self.assertEqual(json.loads(self.paths.pending.read_bytes()), self.pending)
                elif phase == "index_created":
                    with self.assertRaises(ValueError):
                        self.recover()
                    self.assertEqual(json.loads(self.paths.state.read_bytes()), self.old_state)
                else:
                    self.recover()
                    self.ack()
                    self.assert_new_pair()
                    self.assertFalse(self.active().exists())
                    if action == "delete":
                        self.assertFalse(self.paths.pending.exists())
                    else:
                        self.assertEqual(json.loads(self.paths.pending.read_bytes())["pause_reason"], "failed")


if __name__ == "__main__":
    unittest.main(verbosity=2)
