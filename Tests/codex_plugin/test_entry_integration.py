"""Actual package composition with denied MCP policy and suppressed worker spawn."""
import importlib.util
import fcntl
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest

from suite_support import PLUGIN_ROOT, REPOSITORY_ROOT, TEMP_ROOT
from unittest import mock

HERE = REPOSITORY_ROOT
sys.path.insert(0, str(PLUGIN_ROOT / "scripts"))
import engram_hook
import recall_hook
from codex_learner import runner, file_identity


class EntryIntegration(unittest.TestCase):
    def setUp(self):
        capture = mock.patch.object(file_identity, "capture_fd", side_effect=lambda fd: {
            "scheme": "macos_volume_uuid_inode_v1",
            "volume_uuid": "11111111-2222-4333-8444-555555555555", "inode": os.fstat(fd).st_ino})
        capture.start(); self.addCleanup(capture.stop)
        self.temp = tempfile.TemporaryDirectory(dir=TEMP_ROOT)
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.folder = self.home / "sessions/2026/01/02"
        self.folder.mkdir(parents=True)
        self.project = self.home / "project"
        self.project.mkdir()
        self.sid = "019b7e22-1a00-7000-8000-000000000001"
        self.path = self.folder / ("rollout-2026-01-02T00-00-00-" + self.sid + ".jsonl")
        self.path.write_text(json.dumps({"type":"session_meta", "ordinal":0, "payload":{
            "id":self.sid,"timestamp":"2026-01-02T00:00:00Z", "cwd":str(self.project),
            "source":"vscode", "cli_version":"0.154.0-alpha.6.2", "history_mode":"paginated"}})+"\n")
        (self.home / "config.toml").write_text('[mcp_servers.memory]\ncommand="/nonexistent-test-server"\nenabled=false\n')
        self.root = engram_hook.initialize(self.home)
        patch = mock.patch.dict(os.environ, {"CODEX_HOME":str(self.home)})
        patch.start(); self.addCleanup(patch.stop)
        self.payload = {"session_id":self.sid,"transcript_path":str(self.path),
                        "cwd":str(self.project),"turn_id":"test-turn"}

    def event(self, name, **fields):
        return engram_hook.dispatch(self.root, {**self.payload,"hook_event_name":name,**fields},time.monotonic())

    def append(self):
        with self.path.open("a") as f:
            f.write(json.dumps({"type":"response_item", "ordinal":1,"payload":{
                "type":"message","role":"user","content":[{"type":"input_text","text":"A durable fixture fact. "*40}]}})+"\n")

    def test_real_bootstrap_router_enroll_then_queue(self):
        with mock.patch.object(runner, "spawn_worker") as spawn:
            self.assertEqual(self.event("SessionStart",source="startup"), {})
            self.assertTrue((self.root / "learner/enrollments" / (self.sid+".json")).exists())
            self.append()
            self.assertEqual(self.event("Stop"), {})
            request = json.loads((self.root/"learner/pending"/(self.sid+".json")).read_text())
            self.assertEqual(request["event"], "Stop")
            spawn.assert_called_once()

    def test_cleanup_never_launches_learner(self):
        with mock.patch.object(runner, "spawn_worker") as spawn:
            self.assertEqual(self.event("SessionEnd"), {})
            spawn.assert_not_called()
        receipt = json.loads((self.root/"lifecycle/receipts.jsonl").read_text().splitlines()[-1])
        self.assertEqual(receipt["event"], "SessionEnd")
        self.assertEqual(receipt["status"], "already_clean")

    def test_explicit_disabled_admission_never_spawned(self):
        admission = self.root/"learner/admission.json"
        policy=json.loads(admission.read_text()); policy["enabled"]=False
        admission.write_text(json.dumps(policy))
        with mock.patch.object(runner,"spawn_worker") as spawn:
            self.event("Stop")
            spawn.assert_not_called()
        receipt=json.loads((self.root/"router-receipts.jsonl").read_text().splitlines()[-1])
        self.assertEqual(receipt["status"],"rejected")

    def test_main_stop_queues_while_other_hook_holds_setup_lock(self):
        with mock.patch.object(runner, "spawn_worker"):
            self.event("SessionStart", source="startup")
        self.append()
        policy = self.root / "learner/admission.json"
        cursor = self.root / "learner/sessions" / (self.sid + ".json")
        enrollment = self.root / "learner/enrollments" / (self.sid + ".json")
        before_policy, before_enrollment = policy.read_bytes(), enrollment.read_bytes()
        fd = os.open(self.root / "setup.lock", os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with tempfile.TemporaryFile() as output, \
                 mock.patch.object(sys, "stdout", output), \
                 mock.patch.object(engram_hook.runtime_routing, "maybe_exec"), \
                 mock.patch.object(recall_hook, "read_input", return_value={**self.payload, "hook_event_name": "Stop"}), \
                 mock.patch.object(engram_hook, "initial_json", side_effect=AssertionError("warm bootstrap write")), \
                 mock.patch.object(engram_hook, "private_dir", side_effect=AssertionError("warm directory write")), \
                 mock.patch.object(runner, "spawn_worker") as spawn:
                self.assertEqual(engram_hook.main([]), 0)
                output.seek(0)
                self.assertEqual(json.loads(output.read()), {})
            spawn.assert_called_once()
        finally:
            os.close(fd)
        request = json.loads((self.root / "learner/pending" / (self.sid + ".json")).read_bytes())
        self.assertEqual(request["event"], "Stop")
        events = [json.loads(line) for line in (self.root / "learner/events.jsonl").read_text().splitlines()]
        queued = [event for event in events if event["event"] == "queued"]
        self.assertEqual([event["request_id"] for event in queued], [request["request_id"]])
        self.assertEqual(policy.read_bytes(), before_policy)
        self.assertEqual(enrollment.read_bytes(), before_enrollment)
        self.assertEqual(json.loads(cursor.read_bytes())["offset"], json.loads(before_enrollment)["frontier_offset"])

    def test_main_incomplete_setup_stops_at_inherited_deadline(self):
        missing = self.root / "lifecycle.json"
        missing.unlink()
        policy = self.root / "learner/admission.json"
        before = policy.read_bytes()
        fd = os.open(self.root / "setup.lock", os.O_RDWR)
        now = [10.0]
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with tempfile.TemporaryFile() as output, \
                 mock.patch.object(sys, "stdout", output), \
                 mock.patch.object(sys, "stderr", io.StringIO()) as errors, \
                 mock.patch.object(engram_hook.runtime_routing, "maybe_exec"), \
                 mock.patch.object(engram_hook.runtime_routing, "hook_deadline", return_value=10.025), \
                 mock.patch.object(engram_hook.time, "monotonic", side_effect=lambda: now[0]), \
                 mock.patch.object(engram_hook.time, "sleep", side_effect=lambda seconds: now.__setitem__(0, now[0] + seconds)), \
                 mock.patch.object(recall_hook, "read_input") as read_input, \
                 mock.patch.object(engram_hook, "dispatch") as dispatch:
                self.assertEqual(engram_hook.main([]), 0)
                read_input.assert_not_called()
                dispatch.assert_not_called()
                self.assertEqual(errors.getvalue(), "Engram: hook unavailable; inspect Engram hook-status.\n")
                output.seek(0)
                self.assertEqual(json.loads(output.read()), {})
        finally:
            os.close(fd)
        self.assertAlmostEqual(now[0], 10.025)
        self.assertFalse(missing.exists())
        self.assertEqual(policy.read_bytes(), before)
        self.assertFalse((self.root / "learner/pending").exists())


if __name__ == "__main__":
    unittest.main()
