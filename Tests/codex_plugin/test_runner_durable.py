"""Actual worker and process_request with a synthetic provider receipt owner."""
import copy
import importlib
import json
import unittest
from unittest import mock

import test_runner_publication as fixtures

R = importlib.import_module("codex_learner.runner")
Q, P, J = fixtures.Q, fixtures.P, fixtures.J


class RunnerDurableTests(unittest.TestCase):
    def setUp(self):
        self.f = fixtures.RunnerPublicationTests(methodName="runTest")
        self.addCleanup(self.f.doCleanups)
        self.f.setUp()
        self.root = self.f.f.root
        self.config = {**R.DEFAULTS, **self.f.config, "min_chars": 0}
        self.patch = mock.patch.object(R, "publications", return_value=self.f.service)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        self.calls = []

    def invoke(self, root, run_dir, request, excerpt, config):
        self.calls.append(request["request_id"])
        execution = R._EXECUTION.get()
        self.assertEqual(run_dir, execution.paths.run_dir)
        self.f.provider_files(execution)
        return {"status": "succeeded", "write_calls": 0}

    def process(self):
        with R.lock_file(self.root / "worker.lock"):
            return R.process_request(self.root, self.f.f.request, self.config, invoke=self.invoke, provider_mode=None)

    def worker(self):
        original = R.process_request
        with mock.patch.object(R, "settings", return_value=self.config), \
             mock.patch.object(R, "process_request", side_effect=lambda root, request, config:
                               original(root, request, config, invoke=self.invoke, provider_mode=None)), \
             mock.patch.object(R, "spawn_worker") as spawn:
            result = R.worker(self.root)
        return result, spawn

    def test_process_uses_durable_context_and_acknowledges_once(self):
        outcome = self.process()
        self.assertIsInstance(outcome, fixtures.R.Outcome)
        self.assertEqual(outcome, "succeeded")
        self.assertEqual(self.calls, [self.f.f.request["request_id"]])
        self.assertFalse(self.f.pending.exists())
        state = json.loads(self.f.f.state_path.read_bytes())
        self.assertEqual(state["offset"], self.f.f.excerpt.next_offset)
        self.assertEqual(state["status"], "succeeded")
        self.assertIn("settlement_sha256", state)

    def test_worker_does_not_delete_a_newer_request_after_older_recovery(self):
        execution = self.f.begin()
        self.f.provider_files(execution)
        execution.close()
        newer = {**self.f.f.request, "request_id": "newer-request", "turn_id": "newer-turn"}
        fixtures.write_json(self.f.pending, newer)
        # Recovery consumes one bounded worker slot, preserving newer pending.
        self.config["max_runs_per_worker"] = 1
        _, spawn = self.worker()
        self.assertEqual(json.loads(self.f.pending.read_bytes()), newer)
        self.assertEqual(self.calls, [])
        spawn.assert_called_once_with(self.root)

    def test_worker_recovers_after_pending_delete_without_invoking_provider(self):
        execution = self.f.begin()
        self.f.provider_files(execution)
        execution.close()
        def stopped(label):
            if label == "pending_mutated":
                raise RuntimeError("fixture interrupted after delete")
        with mock.patch.object(Q, "_boundary", side_effect=stopped):
            with self.assertRaises(RuntimeError):
                self.f.finish(execution)
        self.assertFalse(self.f.pending.exists())
        self.assertTrue((self.f.paths.session_directory / "active.json").exists())
        _, spawn = self.worker()
        self.assertEqual(self.calls, [])
        self.assertFalse((self.f.paths.session_directory / "active.json").exists())
        spawn.assert_not_called()

    def test_worker_never_changes_pending_when_recovery_inputs_changed(self):
        execution = self.f.begin()
        execution.close()
        self.f.f.config_path.write_text(self.f.f.config_path.read_text() + "\n# changed\n")
        # A comment doesn't change the effective route; change a selected value.
        self.f.f.config_path.write_text(self.f.f.config_path.read_text().replace("approve", "deny"))
        original = self.f.pending.read_bytes()
        _, spawn = self.worker()
        self.assertEqual(self.f.pending.read_bytes(), original)
        self.assertEqual(self.calls, [])
        spawn.assert_not_called()
        record = json.loads(self.f.f.record_path.read_bytes())
        self.assertEqual(record["processing"], self.f.f.request["request_id"])

    def test_legacy_text_hash_cannot_skip_new_visible_interval(self):
        state = {**self.f.f.state, "last_excerpt_sha256": J.sha256(self.f.f.excerpt.text.encode())}
        self.f.f.state = state
        fixtures.write_json(self.f.f.state_path, state)
        record = {**self.f.f.record, "state_sha256": fixtures.R.durable.object_digest(state)}
        self.f.f.record = record
        fixtures.write_json(self.f.f.record_path, record)
        self.assertEqual(self.process(), "succeeded")
        self.assertEqual(len(self.calls), 1)

    def test_worker_parser_eof_finishes_without_backend_or_provider(self):
        self.f.empty(records=False)
        self.f.f.config_path.unlink()
        self.worker()
        self.assertEqual(self.calls, [])
        self.f.probe_mock.assert_not_called()
        self.assertFalse(self.f.pending.exists())


if __name__ == "__main__":
    unittest.main()
