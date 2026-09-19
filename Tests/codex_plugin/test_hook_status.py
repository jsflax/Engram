"""Synthetic metadata-only checks; fixtures and all output stay under localdev."""
import contextlib
import hashlib
import importlib.util
import json
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import unittest

from suite_support import PLUGIN_ROOT, REPOSITORY_ROOT, TEMP_ROOT
from unittest.mock import patch

BASE = PLUGIN_ROOT
SPEC = importlib.util.spec_from_file_location("hook_status", BASE / "skills/hook-status/scripts/hook_status.py")
STATUS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STATUS)
SID = "11111111-2222-4333-8444-555555555555"
OTHER = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
DIGEST = "a" * 64
STAMP = "2026-09-17T12:00:00Z"
RUN = "20260917T120000Z-" + "b" * 32


class StatusTests(unittest.TestCase):
    def setUp(self):
        self.guards = contextlib.ExitStack()
        for target in ((subprocess, "Popen"), (socket, "create_connection"), (sqlite3, "connect")):
            self.guards.enter_context(patch.object(*target, side_effect=AssertionError("runtime forbidden")))
        tmp = TEMP_ROOT
        tmp.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=tmp)
        self.home = Path(self.temp.name)
        self.modern = self.home / "engram"
        self.legacy = self.home / "engram-gui-hooks"

    def tearDown(self):
        self.temp.cleanup()
        self.guards.close()

    def write(self, path, value, log=False):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(json.dumps(v) for v in value) + "\n" if log else json.dumps(value))

    def report(self):
        return STATUS.report(environ={"CODEX_HOME": str(self.home), "CODEX_THREAD_ID": SID})

    def test_absent_modern_uses_legacy(self):
        self.write(self.legacy / "learner/admission.json", {"enabled": False})
        result = self.report()
        self.assertEqual(result["state_root"]["selection"], "legacy_fallback")
        self.assertIs(result["learner"]["policy"]["metadata"]["enabled"], False)

    def test_modern_shared_preferred_even_with_legacy_per_task(self):
        self.write(self.modern / "learner/admission.json", {"enabled": True, "mode": "host_sessions_v1"})
        self.write(self.legacy / "learners" / SID / "admission.json", {"enabled": False})
        result = self.report()
        self.assertEqual(result["learner"]["state_root"]["selection"], "shared_host")
        self.assertTrue(result["learner"]["policy"]["metadata"]["enabled"])

    def test_modern_symlink_refuses_fallback(self):
        self.legacy.mkdir()
        self.modern.symlink_to(self.legacy, target_is_directory=True)
        self.assertEqual(self.report()["status"], "state_root_unavailable")

    def test_modern_nondirectory_refuses_fallback(self):
        self.modern.write_text("private")
        self.assertEqual(self.report()["status"], "state_root_unavailable")

    def test_unsafe_modern_learner_never_reads_legacy(self):
        self.modern.mkdir()
        self.write(self.legacy / "learner/admission.json", {"enabled": True})
        (self.modern / "learner").symlink_to(self.legacy / "learner", target_is_directory=True)
        result = self.report()
        self.assertEqual(result["learner"]["policy"]["read"]["read_status"], "unavailable")

    def test_task_scoping_and_unknown_text_redaction(self):
        sh = hashlib.sha256(SID.encode()).hexdigest()[:20]
        oh = hashlib.sha256(OTHER.encode()).hexdigest()[:20]
        self.write(self.modern / "lifecycle/receipts.jsonl", [
            {"session": sh, "event": "PostToolUse", "status": "nudge", "failure_kind": "mcp_error", "message": "secret"},
            {"session": oh, "event": "PostToolUse", "status": "counted"}], log=True)
        self.write(self.modern / "router-receipts.jsonl", [
            {"session_id": SID, "status": "queued", "reason": "queued", "hook_event": "Stop", "at": STAMP},
            {"session_id": OTHER, "status": "queued"},
            {"session_id": SID, "reason": "admission_secret"}], log=True)
        result = self.report()
        self.assertEqual(len(result["lifecycle"]["receipts"]), 1)
        self.assertEqual(len(result["router"]["receipts"]), 2)
        self.assertEqual(result["router"]["receipts"][0]["status"], "queued")
        self.assertNotIn("secret", json.dumps(result))
        self.assertNotIn(OTHER, json.dumps(result))

    def test_runtime_identity_bounded_fields_only(self):
        raw = {"schema_version": 1, "evidence": "observed_package_files", "status": "complete",
               "package": {"path": "/private/secret", "version": "0.2.0+codex.20260917123456",
                           "status": "ok", "manifest": {"sha256": DIGEST, "status": "ok"}},
               "sources": {"host_admission": {"path": "/secret.py", "sha256": DIGEST, "status": "ok"},
                           "secret": {"sha256": DIGEST}}}
        view = STATUS.metadata({"runtime_identity": raw})["runtime_identity"]
        self.assertEqual(view["sources"]["host_admission"]["sha256"], DIGEST)
        self.assertNotIn("secret", json.dumps(view))
        self.assertNotIn("path", json.dumps(view))
        raw["package"]["version"] = "private detail"
        self.assertNotIn("version", STATUS.runtime_identity(raw)["package"])

    def test_enrollment_and_policy_do_not_imply_completion(self):
        self.write(self.modern / "learner/admission.json", {"enabled": True, "mode": "host_sessions_v1",
            "activation_id": SID, "cutoff": STAMP, "sessions_dir": {"path": "/private"}})
        self.write(self.modern / "learner/enrollments" / (SID + ".json"), {"session_id": SID,
            "frontier_offset": 500, "frontier_anchor_sha256": DIGEST, "transcript_path": "/private"})
        result = self.report()
        self.assertEqual(result["learner"]["enrollment"]["metadata"]["frontier_offset"], 500)
        self.assertEqual(result["learner"]["latest_run"]["read_status"], "not_linked")
        self.assertNotIn("/private", json.dumps(result))

    def test_successful_run_retains_uuid_and_evidence_qualification(self):
        self.write(self.modern / "learner/events.jsonl", [{"session_id": SID, "run_id": RUN,
            "event": "learner_finished", "status": "succeeded"}], log=True)
        self.write(self.modern / "learner/runs" / RUN / "run.json", {"session_id": SID,
            "status": "succeeded", "turn_completed": True, "writes": [{"tool": "remember", "memory_ids": [OTHER]}]})
        self.write(self.modern / "learner/runs" / RUN / "result.json", {"outcome": "stored", "memory_ids": [OTHER], "summary": "secret"})
        result = self.report()
        run = result["learner"]["latest_run"]
        self.assertEqual(run["provider_result_claim"]["memory_ids"], [OTHER])
        self.assertEqual(result["learner"]["memory_readback"], "not_performed")
        self.assertNotIn("secret", json.dumps(result))

    def test_mismatching_run_does_not_read_provider_result(self):
        self.write(self.modern / "learner/events.jsonl", [{"session_id": SID, "run_id": RUN}], log=True)
        self.write(self.modern / "learner/runs" / RUN / "run.json", {"session_id": OTHER})
        self.write(self.modern / "learner/runs" / RUN / "result.json", {"outcome": "stored", "memory_ids": [OTHER]})
        result = self.report()["learner"]["latest_run"]
        self.assertEqual(result["read"]["read_status"], "session_mismatch")
        self.assertNotIn("provider_result_claim", result)

    def test_reconciliation_gate_exposes_only_typed_evidence(self):
        gate = {"run_id": RUN, "reason": "successful_or_unverified_write",
                "memory_ids": [OTHER, "private text"], "content": "secret"}
        self.write(self.modern / "learner/sessions" / (SID + ".json"), {"session_id": SID,
            "status": "reconciliation_required", "last_run": RUN, "reconciliation_required": gate})
        self.write(self.modern / "learner/pending" / (SID + ".json"), {"session_id": SID,
            "pause_reason": "reconciliation_required"})
        self.write(self.modern / "learner/events.jsonl", [{"session_id": SID, "run_id": RUN,
            "event": "reconciliation_required", "reason": "write_status_unknown", "memory_ids": [OTHER]}], log=True)
        result = self.report()["learner"]
        self.assertEqual(result["session"]["metadata"]["reconciliation_required"], {
            "run_id": RUN, "reason": "successful_or_unverified_write", "memory_ids": [OTHER]})
        self.assertEqual(result["pending"]["metadata"]["pause_reason"], "reconciliation_required")
        self.assertEqual(result["events"][0]["reason"], "write_status_unknown")
        self.assertEqual(result["latest_run"]["read"]["read_status"], "missing")
        self.assertNotIn("secret", json.dumps(result))
        self.assertNotIn("private text", json.dumps(result))

    def test_log_window_and_records_are_bounded(self):
        self.write(self.modern / "router-receipts.jsonl", [{"session_id": SID, "status": "queued"}] * 600, log=True)
        result = self.report()["router"]
        self.assertEqual(len(result["receipts"]), STATUS.MAX_RECORDS)
        self.assertTrue(result["window"]["line_limit_reached"])

    def test_nonselected_paths_are_never_opened(self):
        self.modern.mkdir()
        original = STATUS.open_regular
        opened = []
        def recording(path):
            opened.append(str(path))
            return original(path)
        with patch.object(STATUS, "open_regular", side_effect=recording):
            self.report()
        self.assertTrue(opened)
        self.assertFalse(any(OTHER in p for p in opened))
        self.assertTrue(all(p.startswith(str(self.modern) + "/") for p in opened))

    def test_invalid_identity_does_not_read_state(self):
        with patch.object(STATUS, "open_regular", side_effect=AssertionError("must not read")):
            result = STATUS.report("../../secret", {"CODEX_HOME": str(self.home)})
        self.assertEqual(result["status"], "invalid_session_id")

    def test_unknown_and_wrong_type_metadata_omitted(self):
        result = STATUS.metadata({"enabled": 1, "writes": True, "status": "secret", "reason": ["queued"],
                                  "failure_kind": {"mcp_error": True}, "runtime_identity": {"status": ["complete"]}})
        self.assertEqual(result, {"runtime_identity": {}})


if __name__ == "__main__":
    unittest.main()
