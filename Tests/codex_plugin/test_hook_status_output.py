"""Aggregate-output regressions using synthetic, bounded, selected metadata only."""
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from suite_support import PLUGIN_ROOT, TEMP_ROOT

SPEC = importlib.util.spec_from_file_location(
    "hook_status_output_subject", PLUGIN_ROOT / "skills/hook-status/scripts/hook_status.py")
STATUS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STATUS)
SID = "11111111-2222-4333-8444-555555555555"
OTHER = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
RUN = "20261017T120000Z-" + "b" * 32
DIGEST = "a" * 64
STAMP = "2026-10-17T12:00:00Z"


class OutputTests(unittest.TestCase):
    def setUp(self):
        self.guards = contextlib.ExitStack()
        self.addCleanup(self.guards.close)
        for target in ((subprocess, "Popen"), (socket, "create_connection"), (sqlite3, "connect")):
            self.guards.enter_context(patch.object(*target, side_effect=AssertionError("runtime forbidden")))
        TEMP_ROOT.mkdir(parents=True, exist_ok=True)
        self.temp = self.guards.enter_context(tempfile.TemporaryDirectory(dir=TEMP_ROOT))
        self.home = Path(self.temp)
        real_open = STATUS.open_regular
        def fixture_only(path):
            if not Path(path).is_relative_to(self.home):
                raise AssertionError("non-fixture metadata read")
            return real_open(path)
        self.guards.enter_context(patch.object(STATUS, "open_regular", side_effect=fixture_only))

    def write(self, path, value, *, log=False):
        path.parent.mkdir(parents=True, exist_ok=True)
        raw = ("\n".join(json.dumps(row) for row in value) + "\n") if log else json.dumps(value)
        if log:
            self.assertLessEqual(max(map(len, raw.encode().splitlines())), STATUS.MAX_LINE_BYTES)
            self.assertLessEqual(len(value), STATUS.MAX_RECORDS)
            self.assertLessEqual(len(raw.encode()), STATUS.MAX_LOG_BYTES)
        else:
            self.assertLessEqual(len(raw.encode()), STATUS.MAX_JSON_BYTES)
        path.write_text(raw)

    def fixture_report(self, *, records, saturated=False):
        root = self.home / "engram"
        learner = root / "learner"
        identity = {"scheme": "macos_volume_uuid_inode_v1", "volume_uuid": OTHER, "inode": 123}
        gate = {"run_id": RUN, "reason": "successful_or_unverified_write", "memory_ids": [OTHER]}
        self.write(learner / "admission.json", {"enabled": True, "mode": "host_sessions_v2"})
        self.write(learner / "sessions" / (SID + ".json"), {"session_id": SID, "identity": identity,
            "offset": 2000, "status": "reconciliation_required", "last_run": RUN,
            "reconciliation_required": gate})
        self.write(learner / "pending" / (SID + ".json"), {"session_id": SID, "identity": identity,
            "size_bytes": 3000, "pause_reason": "batch_limit", "request_id": "c" * 32})
        self.write(learner / "admissions" / (SID + ".json"), {"binding": {"session_id": SID},
            "state_sha256": DIGEST, "processing": None})
        self.write(learner / "enrollments" / (SID + ".json"), {"session_id": SID, "frontier_offset": 100})
        self.write(learner / "runs" / RUN / "run.json", {"session_id": SID, "status": "failed",
            "reason": "unverified_completion", "writes": [{"tool": "remember", "memory_ids": [OTHER]}]})
        self.write(learner / "runs" / RUN / "result.json", {"outcome": "failed"})
        runtime = {"schema_version": 1, "evidence": "observed_package_files", "status": "complete",
            "package": {"version": "0.15.0", "status": "ok", "manifest": {"status": "ok", "sha256": DIGEST}},
            "sources": {name: {"status": "ok", "sha256": DIGEST} for name in
                        ("router", "runner", "template", "admission", "host_admission", "file_identity")}}
        row = {"session_id": SID, "session": hashlib.sha256(SID.encode()).hexdigest()[:20],
               "runtime_identity": runtime, "status": "emitted", "at": STAMP,
               "message": "SECRET_BODY_MUST_NOT_LEAVE_METADATA"}
        if saturated:
            row["memory_ids"] = [OTHER] * 20
            row["writes"] = [{"tool": "remember", "memory_ids": [OTHER] * 20}] * 5
        for relative in ("recall-state/receipts.jsonl", "lifecycle/receipts.jsonl", "router-receipts.jsonl", "learner/events.jsonl"):
            self.write(root / relative, [row] * records, log=True)
        value = STATUS.report(environ={"CODEX_HOME": str(self.home), "CODEX_THREAD_ID": SID})
        self.assertEqual(value["session_id"], SID)
        self.assertNotIn("SECRET_BODY", json.dumps(value))
        self.assertEqual(value["learner"]["health"]["headline"], "reconciliation_required")
        return value

    def main_output(self, value):
        before = copy.deepcopy(value)
        stream = io.StringIO()
        with patch.object(STATUS, "report", return_value=value) as report, contextlib.redirect_stdout(stream):
            self.assertEqual(STATUS.main(["--session-id", SID]), 0)
        report.assert_called_once_with(SID)
        self.assertEqual(value, before)
        output = stream.getvalue()
        self.assertLessEqual(len(output.encode()), STATUS.MAX_OUTPUT_BYTES)
        return output, json.loads(output)

    def test_small_main_keeps_original_pretty_format_and_status(self):
        for value in ({"status": "invalid_session_id"}, {"status": "ok", "session_id": SID}):
            with self.subTest(status=value["status"]):
                output, parsed = self.main_output(value)
                self.assertEqual(output, json.dumps(value, ensure_ascii=True, indent=2) + "\n")
                self.assertEqual(parsed, value)

    def test_bounded_rich_receipts_compact_without_losing_any_evidence(self):
        value = self.fixture_report(records=8)
        pretty_size = len((json.dumps(value, ensure_ascii=True, indent=2) + "\n").encode())
        compact_size = len((json.dumps(value, ensure_ascii=True, separators=(",", ":")) + "\n").encode())
        self.assertGreater(pretty_size, STATUS.MAX_OUTPUT_BYTES)
        self.assertLessEqual(compact_size, STATUS.MAX_OUTPUT_BYTES)
        output, parsed = self.main_output(value)
        self.assertEqual(parsed, value)
        self.assertEqual(len(output.encode()), compact_size)

    def test_compact_overflow_keeps_exact_session_health_and_explicit_omissions(self):
        value = self.fixture_report(records=12, saturated=True)
        compact_size = len((json.dumps(value, ensure_ascii=True, separators=(",", ":")) + "\n").encode())
        self.assertGreater(compact_size, STATUS.MAX_OUTPUT_BYTES)
        _, parsed = self.main_output(value)
        self.assertEqual(parsed["status"], "output_limit")
        self.assertEqual(parsed["report_status"], value["status"])
        self.assertEqual(parsed["session_id"], SID)
        self.assertEqual(parsed["learner"]["health"], value["learner"]["health"])
        self.assertFalse(parsed["learner"]["health"]["recovery"]["automatic_replay_authorized"])
        self.assertFalse(parsed["output"]["complete"])
        self.assertEqual(parsed["output"]["maximum_bytes"], STATUS.MAX_OUTPUT_BYTES)
        self.assertEqual(parsed["output"]["full_compact_bytes"], compact_size)
        expected = ["advice", "lifecycle", "router"] + ["learner." + key for key in value["learner"] if key != "health"]
        self.assertEqual(parsed["output"]["omitted_sections"], sorted(expected))

    def test_printed_newline_is_within_the_byte_budget(self):
        value = {"status": "ok", "session_id": SID}
        limit = len(json.dumps(value, ensure_ascii=True, indent=2).encode())
        with patch.object(STATUS, "MAX_OUTPUT_BYTES", limit):
            _, parsed = self.main_output(value)
        self.assertEqual(parsed, value)

    def test_future_oversize_health_is_explicitly_unavailable_never_partial_or_ok(self):
        value = {"status": "ok", "session_id": SID,
                 "learner": {"health": {"future_schema": "x" * STATUS.MAX_OUTPUT_BYTES}}}
        _, parsed = self.main_output(value)
        self.assertEqual(parsed["status"], "output_limit")
        self.assertEqual(parsed["session_id"], SID)
        self.assertNotIn("learner", parsed)
        self.assertEqual(parsed["output"]["health"], "unavailable_within_output_budget")
        self.assertEqual(parsed["output"]["omitted_sections"], ["learner.health"])
        self.assertFalse(parsed["output"]["complete"])


if __name__ == "__main__":
    unittest.main()
