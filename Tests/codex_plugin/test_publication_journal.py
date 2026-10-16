"""Synthetic journals only; real child SIGKILL tests never start a provider."""
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
from unittest import mock

from suite_support import PLUGIN_ROOT

sys.path.insert(0, str(PLUGIN_ROOT / "scripts"))
P = importlib.import_module("codex_learner.publication_journal")


class PublicationJournalTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="publication-")
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name).resolve()
        for name in ("states", "admissions", "journals"):
            (self.base / name).mkdir(mode=0o700)
        self.sid = "01900000-0000-7000-8000-000000000001"
        self.request_id = "frozen-request"
        self.transition = "11111111-2222-4333-8444-555555555555"
        self.binding = {"session_id": self.sid, "activation_id": "activation-one", "frontier_offset": 5,
                        "policy_sha256": "a" * 64, "identity": {"inode": 7, "volume_uuid": "fixture"}}
        self.paths = P.Paths(self.base / "states" / (self.sid + ".json"),
                             self.base / "admissions" / (self.sid + ".json"),
                             self.base / "journals" / self.transition)
        self.old_state = {"session_id": self.sid, "offset": 10, "admission": self.binding,
                          "status": "reconciliation_required", "recent_messages": ["retained"],
                          "reconciliation_required": {"run_id": "held-run", "memory_ids": ["retained-memory"]}}
        self.old_record = {"binding": self.binding, "state_sha256": P.durable.object_digest(self.old_state),
                           "processing": self.request_id, "last_event": "b" * 64}
        self.new_state = {**self.old_state, "offset": 20, "current_turn_id": "frozen-turn"}
        self.new_record = {**self.old_record, "state_sha256": P.durable.object_digest(self.new_state), "processing": None}
        self.old_raw = {"state": P.durable.encode(self.old_state), "admission": P.durable.encode(self.old_record)}
        for role, raw in self.old_raw.items():
            P.durable._new(getattr(self.paths, role), raw)
        self.pending = self.base / "pending.json"
        P.durable._new(self.pending, P.durable.encode({"request_id": self.request_id, "paused": True,
                                                     "pause_reason": "reconciliation_required"}))
        self.pending_raw = self.pending.read_bytes()
        self.policy = self.base / "policy.json"
        P.durable._new(self.policy, P.durable.encode(self.binding))
        self.policy_raw = self.policy.read_bytes()
        self.phases = []

    def validate(self, plan, phase):
        self.phases.append(phase)
        if self.pending.read_bytes() != self.pending_raw or self.policy.read_bytes() != self.policy_raw:
            raise ValueError("fixture_authorization_changed")
        self.assertEqual(plan["request_id"], self.request_id)
        return True

    def prepare(self, **overrides):
        values = dict(transition_id=self.transition, session_id=self.sid, request_id=self.request_id,
                      binding=self.binding, new_state=self.new_state, new_admission=self.new_record,
                      expected_old_state_sha256=P.durable.digest(self.old_raw["state"]),
                      expected_old_admission_sha256=P.durable.digest(self.old_raw["admission"]), validate=self.validate)
        values.update(overrides)
        return P.prepare(self.paths, **values)

    def publish(self, sha, **overrides):
        values = dict(expected_prepared_sha256=sha, session_id=self.sid, request_id=self.request_id,
                      binding=self.binding, validate=self.validate)
        values.update(overrides)
        return P.publish(self.paths, **values)

    def assert_new_pair(self):
        self.assertEqual(self.paths.state.read_bytes(), P.durable.encode(self.new_state))
        self.assertEqual(self.paths.admission.read_bytes(), P.durable.encode(self.new_record))
        self.assertEqual(self.pending.read_bytes(), self.pending_raw)
        self.assertEqual(json.loads(self.paths.state.read_bytes())["reconciliation_required"],
                         self.old_state["reconciliation_required"])

    def assert_old_pair(self):
        for role in P.ORDER:
            self.assertEqual(getattr(self.paths, role).read_bytes(), self.old_raw[role])
        self.assertEqual(self.pending.read_bytes(), self.pending_raw)

    def interrupt(self, sha, boundary):
        def crash(label):
            if label == boundary:
                raise RuntimeError("fixture_interruption")
        with mock.patch.object(P, "_boundary", side_effect=crash):
            with self.assertRaisesRegex(RuntimeError, "fixture_interruption"):
                self.publish(sha)

    def test_prepare_preserves_pair_then_publish_is_exact_and_idempotent(self):
        sha = self.prepare()
        self.assert_old_pair()
        prepared = (self.paths.journal_directory / "prepared.json").read_bytes()
        result = self.publish(sha)
        self.assertEqual(result["status"], "published")
        self.assert_new_pair()
        receipt = (self.paths.journal_directory / "published.json").read_bytes()
        identities = [getattr(self.paths, role).stat().st_ino for role in P.ORDER]
        self.assertEqual(self.publish(sha), result)
        self.assertEqual([getattr(self.paths, role).stat().st_ino for role in P.ORDER], identities)
        self.assertEqual((self.paths.journal_directory / "prepared.json").read_bytes(), prepared)
        self.assertEqual((self.paths.journal_directory / "published.json").read_bytes(), receipt)
        self.assertIn("replace_admission", self.phases)
        self.assertIn("replace_state", self.phases)

    def test_callback_cannot_mutate_frozen_plan(self):
        sha = self.prepare()
        def validator(plan, phase):
            self.validate(plan, phase)
            plan["records"]["state"]["new"] = plan["records"]["state"]["old"]
            return True
        self.publish(sha, validate=validator)
        self.assert_new_pair()

    def test_old_unjournaled_mismatch_and_missing_pair_are_not_adopted(self):
        self.paths.admission.write_bytes(P.durable.encode(self.new_record))
        with self.assertRaisesRegex(ValueError, "preimage_changed"):
            self.prepare()
        with self.assertRaisesRegex(ValueError, "state_admission_hash_mismatch"):
            self.prepare(expected_old_admission_sha256=P.durable.digest(self.paths.admission.read_bytes()))
        self.paths.state.unlink()
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertFalse(self.paths.journal_directory.exists())

    def test_wrong_old_hash_binding_request_and_proposed_regression_refuse(self):
        for change in ({"expected_old_state_sha256": "c" * 64},
                       {"binding": {**self.binding, "activation_id": "new"}},
                       {"binding": {**self.binding, "identity": {**self.binding["identity"], "inode": 7.0}}},
                       {"request_id": "new-owner"},
                       {"new_state": {**self.new_state, "offset": 4}}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.prepare(**change)
            self.assert_old_pair()
        self.assertFalse(self.paths.journal_directory.exists())

    def test_nonprefix_and_third_state_refuse_without_overwrite(self):
        sha = self.prepare()
        self.paths.state.write_bytes(P.durable.encode(self.new_state))
        before = self.paths.state.read_bytes()
        with self.assertRaisesRegex(ValueError, "nonprefix_publication"):
            self.publish(sha)
        self.assertEqual(self.paths.state.read_bytes(), before)
        self.assertEqual(self.paths.admission.read_bytes(), self.old_raw["admission"])
        self.paths.state.write_bytes(P.durable.encode({**self.new_state, "offset": 100}))
        with self.assertRaisesRegex(ValueError, "target_changed"):
            self.publish(sha)
        self.assertEqual(json.loads(self.paths.state.read_bytes())["offset"], 100)

    def test_replaced_identical_preimage_is_not_the_inspected_file(self):
        sha = self.prepare()
        temporary = self.paths.state.parent / "replacement"
        P.durable._new(temporary, self.old_raw["state"])
        os.replace(temporary, self.paths.state)
        with self.assertRaisesRegex(ValueError, "target_changed"):
            self.publish(sha)

    def test_policy_or_pending_change_stops_partial_recovery(self):
        sha = self.prepare()
        self.interrupt(sha, "admission_replaced")
        old_state = self.paths.state.read_bytes()
        self.policy.write_bytes(P.durable.encode({**self.binding, "activation_id": "next"}))
        with self.assertRaisesRegex(ValueError, "authorization_changed"):
            self.publish(sha)
        self.assertEqual(self.paths.state.read_bytes(), old_state)
        self.policy.write_bytes(self.policy_raw)
        self.pending.write_bytes(P.durable.encode({"request_id": "newer-request"}))
        with self.assertRaisesRegex(ValueError, "authorization_changed"):
            self.publish(sha)
        self.assertEqual(self.paths.state.read_bytes(), old_state)

    def test_validation_before_each_target_prevents_later_publication(self):
        sha = self.prepare()
        def reject_state(plan, phase):
            self.validate(plan, phase)
            if phase == "replace_state":
                raise ValueError("fixture_refused_state")
            return True
        with self.assertRaisesRegex(ValueError, "refused_state"):
            self.publish(sha, validate=reject_state)
        self.assertEqual(self.paths.state.read_bytes(), self.old_raw["state"])
        self.assertEqual(self.paths.admission.read_bytes(), P.durable.encode(self.new_record))
        self.publish(sha)
        self.assert_new_pair()

    def test_malformed_or_replaced_journal_and_untrusted_path_fail_closed(self):
        sha = self.prepare()
        path = self.paths.journal_directory / "prepared.json"
        raw = path.read_bytes()
        path.write_bytes(b'{"schema_version":1,"schema_version":1}')
        with self.assertRaises(ValueError):
            self.publish(P.durable.digest(path.read_bytes()))
        path.write_bytes(raw)
        forged = json.loads(raw)
        forged["paths"]["state"] = str(self.pending)
        path.write_bytes(P.durable.encode(forged))
        with self.assertRaisesRegex(ValueError, "path_binding_changed"):
            self.publish(P.durable.digest(path.read_bytes()))
        self.assert_old_pair()

    def test_unsafe_symlink_and_hardlinked_target_refuse(self):
        sha = self.prepare()
        original = self.paths.state.parent / "original"
        self.paths.state.rename(original)
        self.paths.state.symlink_to(original)
        with self.assertRaises(ValueError):
            self.publish(sha)
        self.paths.state.unlink()
        os.link(original, self.paths.state)
        with self.assertRaises(ValueError):
            self.publish(sha)
        self.assertEqual(original.read_bytes(), self.old_raw["state"])

    def test_existing_published_receipt_does_not_authorize_rewriting_successor(self):
        sha = self.prepare()
        self.publish(sha)
        self.paths.state.write_bytes(P.durable.encode({**self.new_state, "offset": 1000}))
        with self.assertRaises(ValueError):
            self.publish(sha)
        self.assertEqual(json.loads(self.paths.state.read_bytes())["offset"], 1000)

    def test_missing_target_is_never_recreated_even_after_partial_publication(self):
        for partial in (False, True):
            with self.subTest(partial=partial):
                self.setUp()
                sha = self.prepare()
                if partial:
                    self.interrupt(sha, "admission_replaced")
                admission_before = self.paths.admission.read_bytes()
                self.paths.state.unlink()
                with self.assertRaises(ValueError):
                    self.publish(sha)
                self.assertFalse(self.paths.state.exists())
                self.assertEqual(self.paths.admission.read_bytes(), admission_before)

    def test_pair_cas_is_rechecked_after_staging_and_before_replace(self):
        sha = self.prepare()
        successor = P.durable.encode({**self.new_state, "offset": 999})
        def concurrent_change(plan, phase):
            self.validate(plan, phase)
            if phase == "replace_admission":
                self.paths.state.write_bytes(successor)
            return True
        with self.assertRaisesRegex(ValueError, "target_changed"):
            self.publish(sha, validate=concurrent_change)
        self.assertEqual(self.paths.state.read_bytes(), successor)
        self.assertEqual(self.paths.admission.read_bytes(), self.old_raw["admission"])

    def test_validation_is_mandatory_and_binding_change_is_not_recovery_authority(self):
        with self.assertRaisesRegex(ValueError, "validator_required"):
            self.prepare(validate=None)
        self.assertFalse(self.paths.journal_directory.exists())
        sha = self.prepare()
        for overrides in ({"validate": None}, {"request_id": "other-request"},
                          {"binding": {**self.binding, "policy_sha256": "d" * 64}}):
            with self.subTest(overrides=overrides), self.assertRaises(ValueError):
                self.publish(sha, **overrides)
        self.assert_old_pair()

    def test_unchanged_state_and_noop_pair_do_not_require_rewrites(self):
        self.new_state, self.new_record = copy.deepcopy(self.old_state), copy.deepcopy(self.old_record)
        sha = self.prepare()
        identities = [getattr(self.paths, role).stat().st_ino for role in P.ORDER]
        self.publish(sha)
        self.assertEqual([getattr(self.paths, role).stat().st_ino for role in P.ORDER], identities)
        self.assert_old_pair()

    def test_validator_requires_exact_true_before_prepare_and_every_replacement(self):
        for refused in (False, None, 1, "yes"):
            with self.subTest(phase="prepare", refused=refused):
                with self.assertRaisesRegex(ValueError, "validation_refused"):
                    self.prepare(validate=lambda _plan, _phase: refused)
                self.assert_old_pair()
                self.assertFalse(self.paths.journal_directory.exists())
        for phase in ("entry", "replace_admission", "replace_state", "replace_receipt"):
            for refused in (False, None):
                with self.subTest(phase=phase, refused=refused):
                    self.setUp()
                    sha = self.prepare()
                    def validator(plan, current):
                        self.validate(plan, current)
                        return refused if current == phase else True
                    with self.assertRaisesRegex(ValueError, "validation_refused"):
                        self.publish(sha, validate=validator)
                    if phase in ("entry", "replace_admission"):
                        self.assert_old_pair()
                    elif phase == "replace_state":
                        self.assertEqual(self.paths.state.read_bytes(), self.old_raw["state"])
                        self.assertEqual(self.paths.admission.read_bytes(), P.durable.encode(self.new_record))
                    else:
                        self.assert_new_pair()
                    self.assertFalse((self.paths.journal_directory / "published.json").exists())
                    self.publish(sha)
                    self.assert_new_pair()

    def test_real_process_death_at_every_publication_boundary_recovers_exact_pair(self):
        boundaries = [role + suffix for role in P.ORDER for suffix in
                      ("_stage_created", "_stage_written", "_stage_file_fsynced", "_stage_directory_fsynced",
                       "_replaced", "_directory_fsynced")]
        boundaries += ["published_stage_created", "published_stage_written", "published_stage_file_fsynced",
                       "published_stage_directory_fsynced", "published_replaced", "published_directory_fsynced",
                       "publication_complete"]
        for boundary in boundaries:
            with self.subTest(boundary=boundary):
                # Distinct fixture for each real death; setUp creates only local
                # temporary files and cleanup registrations remain on this case.
                self.setUp()
                sha = self.prepare()
                data = {"state": str(self.paths.state), "admission": str(self.paths.admission),
                        "journal": str(self.paths.journal_directory), "sha": sha, "sid": self.sid,
                        "request": self.request_id, "binding": self.binding, "boundary": boundary,
                        "policy": str(self.policy), "policy_sha": P.durable.digest(self.policy_raw),
                        "pending": str(self.pending), "pending_sha": P.durable.digest(self.pending_raw)}
                script = r'''
import json, os, signal, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from codex_learner import publication_journal as P
d = json.loads(sys.argv[2])
def crash(label):
    if label == d["boundary"]: os.kill(os.getpid(), signal.SIGKILL)
def validate(plan, phase):
    assert P.durable.digest(Path(d["policy"]).read_bytes()) == d["policy_sha"]
    assert P.durable.digest(Path(d["pending"]).read_bytes()) == d["pending_sha"]
    return True
P._boundary = crash
P.publish(P.Paths(Path(d["state"]), Path(d["admission"]), Path(d["journal"])),
          expected_prepared_sha256=d["sha"], session_id=d["sid"], request_id=d["request"],
          binding=d["binding"], validate=validate)
'''
                child = subprocess.run([sys.executable, "-B", "-c", script, str(PLUGIN_ROOT / "scripts"), json.dumps(data)],
                                       capture_output=True, text=True, timeout=10)
                self.assertEqual(child.returncode, -signal.SIGKILL, child.stderr)
                self.publish(sha)
                self.assert_new_pair()
                self.assertEqual(self.publish(sha)["status"], "published")

    def test_interruption_before_prepared_evidence_never_changes_targets(self):
        for boundary in ("journal_directory_fsynced", "prepared_created", "prepared_written",
                         "prepared_file_fsynced", "prepared_directory_fsynced"):
            with self.subTest(boundary=boundary):
                self.setUp()
                def crash(label):
                    if label == boundary:
                        raise RuntimeError("fixture_prepare_interrupted")
                with mock.patch.object(P, "_boundary", side_effect=crash):
                    with self.assertRaisesRegex(RuntimeError, "prepare_interrupted"):
                        self.prepare()
                self.assert_old_pair()
                # No returned/pinned prepared digest: ordinary prepare refuses
                # to silently adopt or rewrite the retained partial attempt.
                with self.assertRaises(ValueError):
                    self.prepare()


if __name__ == "__main__":
    unittest.main()
