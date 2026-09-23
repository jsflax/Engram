"""Actual package composition with denied MCP policy and suppressed worker spawn."""
import importlib.util
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


if __name__ == "__main__":
    unittest.main()
