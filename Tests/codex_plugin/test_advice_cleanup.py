"""Advice outcome accounting with synthetic transport and owned fixture state."""
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest import mock

from suite_support import PLUGIN_ROOT, TEMP_ROOT

sys.path.insert(0, str(PLUGIN_ROOT / "scripts"))
import engram_hook
import learner_router
import recall_hook as recall

MEMORY_ID = "00000000-0000-4000-8000-000000000001"


class AdviceCleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=TEMP_ROOT)
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "recall-state"
        self.config = self.base / "recall.json"
        self.config.write_text(json.dumps({
            "state_dir": str(self.root), "semantic_recall": True,
            "projects": {str(self.base): "Example"}, "wall_seconds": 2,
            "cooldown_seconds": 1,
        }))
        self.payload = {"hook_event_name": "SessionStart", "source": "startup",
                        "session_id": "fixture-session", "cwd": str(self.base)}
        self.client = mock.Mock()
        self.client.call.return_value = f"[id:{MEMORY_ID}] [Example/architecture]\nUse explicit ownership."
        self.factory = mock.Mock(return_value=self.client)
        self.guards = mock.patch.dict(os.environ, {}, clear=True)
        self.guards.start()
        self.addCleanup(self.guards.stop)
        no_spawn = mock.patch("subprocess.Popen", side_effect=AssertionError("real process forbidden"))
        no_spawn.start()
        self.addCleanup(no_spawn.stop)
        recall._cancelled = False
        self.addCleanup(setattr, recall, "_cancelled", False)

    def state(self):
        return json.loads((self.root / "state.json").read_text())

    def seed_failures(self, count):
        self.root.mkdir(mode=0o700, exist_ok=True)
        recall.atomic_state(self.root, {"recent": {}, "next_allowed": 0, "failures": count})

    def receipt(self):
        return json.loads((self.root / "receipts.jsonl").read_text().splitlines()[-1])

    def invoke(self, *, now=10_000):
        original_write = os.write
        stdout_fd = sys.stdout.fileno()
        output = []
        def write(fd, data):
            if fd == stdout_fd:
                output.append(data)
                return len(data)
            return original_write(fd, data)
        with mock.patch.object(recall, "read_input", return_value=self.payload), \
             mock.patch.object(recall, "check_policy"), \
             mock.patch.object(recall, "Client", self.factory), \
             mock.patch.object(recall.time, "time", return_value=now), \
             mock.patch.object(recall.os, "write", side_effect=write):
            self.assertEqual(recall.run_hook([str(self.config)]), 0)
        self.assertEqual(len(output), 1)
        return json.loads(output[0]), self.receipt()

    def test_primary_failure_survives_cleanup_failure_and_counts_once(self):
        for method, status, phase in (("initialize", "timeout", "mcp_initialize"),
                                      ("call", "protocol", "mcp_recall")):
            for cleanup_error, cleanup_status, cleanup_kind in (
                    (recall.Failure("cleanup_timeout"), "timeout", "classified"),
                    (OSError("private cleanup fixture error"), "failed", "io")):
                with self.subTest(method=method, cleanup_status=cleanup_status):
                    self.seed_failures(1)
                    self.client.initialize.side_effect = None
                    self.client.call.side_effect = None
                    getattr(self.client, method).side_effect = recall.Failure(status)
                    self.client.close.side_effect = cleanup_error
                    output, receipt = self.invoke()
                    self.assertEqual(output, {})
                    self.assertEqual((receipt["status"], receipt["failure_phase"]), (status, phase))
                    self.assertEqual((receipt["cleanup_status"], receipt["cleanup_error_kind"]),
                                     (cleanup_status, cleanup_kind))
                    self.assertEqual(self.state()["failures"], 2)
                    self.assertEqual(self.state()["recent"], {})
                    self.assertNotIn("private cleanup fixture error", json.dumps(receipt))

    def test_cleanup_failure_allows_later_retry_then_success_dedupes(self):
        self.client.close.side_effect = recall.Failure("cleanup_timeout")
        output, receipt = self.invoke()
        self.assertEqual(output, {})
        self.assertEqual((receipt["status"], receipt["failure_phase"]), ("cleanup_timeout", "cleanup"))
        self.assertEqual((receipt["context_chars"], receipt["memory_ids"]), (0, []))
        self.assertEqual(self.state()["failures"], 1)
        self.assertEqual(self.state()["recent"], {})

        self.client.close.side_effect = None
        output, receipt = self.invoke(now=10_002)
        self.assertIn(MEMORY_ID, output["hookSpecificOutput"]["additionalContext"])
        self.assertEqual((receipt["status"], receipt["cleanup_status"]), ("emitted", "completed"))
        self.assertEqual(self.state()["failures"], 0)
        self.assertEqual(len(self.state()["recent"]), 1)
        self.assertEqual(self.factory.call_count, 2)
        output, receipt = self.invoke(now=10_004)
        self.assertEqual((output, receipt["status"]), ({}, "duplicate"))
        self.assertEqual(self.factory.call_count, 2)

    def test_success_is_committed_only_after_close(self):
        self.seed_failures(2)
        states_during_close = []
        self.client.close.side_effect = lambda: states_during_close.append(self.state())
        output, receipt = self.invoke()
        self.assertTrue(output)
        self.assertEqual(states_during_close[0]["failures"], 2)
        self.assertEqual(states_during_close[0]["recent"], {})
        self.assertEqual(self.state()["failures"], 0)
        self.assertEqual(receipt["cleanup_status"], "completed")
        self.client.close.assert_called_once()

    def test_cancellation_during_successful_close_does_not_commit_success(self):
        self.seed_failures(1)
        self.client.close.side_effect = lambda: setattr(recall, "_cancelled", True)
        output, receipt = self.invoke()
        self.assertEqual((output, receipt["status"]), ({}, "cancelled"))
        self.assertEqual(receipt["cleanup_status"], "completed")
        self.assertEqual(self.state()["failures"], 1)
        self.assertEqual(self.state()["recent"], {})

    def test_cancelled_operation_with_cleanup_failure_counts_once(self):
        def cancel():
            recall._cancelled = True
            raise recall.Failure("cancelled")
        self.client.initialize.side_effect = cancel
        self.client.close.side_effect = recall.Failure("cleanup_timeout")
        output, receipt = self.invoke()
        self.assertEqual((output, receipt["status"], receipt["failure_phase"]),
                         ({}, "cancelled", "mcp_initialize"))
        self.assertEqual(receipt["cleanup_status"], "timeout")
        self.assertEqual(self.state()["failures"], 1)

    def test_cleanup_only_timeout_is_not_hidden_by_cancellation_override(self):
        def cancel_and_fail_close():
            recall._cancelled = True
            raise recall.Failure("cleanup_timeout")
        self.client.close.side_effect = cancel_and_fail_close
        output, receipt = self.invoke()
        self.assertEqual((output, receipt["status"]), ({}, "cleanup_timeout"))
        self.assertEqual(self.state()["failures"], 1)
        self.assertEqual(self.state()["recent"], {})

    def test_state_commit_error_keeps_existing_classification(self):
        original = recall.atomic_state
        calls = 0
        def fail_commit(root, state):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("private fixture error")
            original(root, state)
        with mock.patch.object(recall, "atomic_state", side_effect=fail_commit):
            output, receipt = self.invoke()
        self.assertEqual((output, receipt["status"], receipt["failure_phase"], receipt["error_kind"]),
                         ({}, "invalid", "state_commit", "io"))
        self.assertEqual(receipt["cleanup_status"], "completed")
        self.assertNotIn("private fixture error", json.dumps(receipt))

    def test_package_entry_preserves_primary_failure_and_separate_cleanup(self):
        self.root.mkdir(mode=0o700)
        self.payload["source"] = "compact"
        self.client.call.side_effect = recall.Failure("timeout")
        self.client.close.side_effect = recall.Failure("cleanup_timeout")
        with mock.patch.object(learner_router, "dispatch"), \
             mock.patch.object(recall, "check_policy"), \
             mock.patch.object(recall, "Client", self.factory):
            output = engram_hook.dispatch(self.base, self.payload, time.monotonic())
        receipt = self.receipt()
        self.assertEqual(output, {})
        self.assertEqual((receipt["status"], receipt["failure_phase"]), ("timeout", "mcp_recall"))
        self.assertEqual(receipt["cleanup_status"], "timeout")
        self.assertEqual(self.state()["failures"], 1)


if __name__ == "__main__":
    unittest.main()
