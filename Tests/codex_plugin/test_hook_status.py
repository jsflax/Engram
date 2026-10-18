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
REQUEST = "c" * 32
IDENTITY = {"scheme": "macos_volume_uuid_inode_v1", "volume_uuid": OTHER, "inode": 123}
DEFAULT_ADMISSION = object()


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

    def learner_fixture(self, *, enabled=True, session=None, pending=None, admission=DEFAULT_ADMISSION):
        root = self.modern / "learner"
        self.write(root / "admission.json", {"enabled": enabled, "mode": "host_sessions_v2"})
        self.write(root / "enrollments" / (SID + ".json"), {"session_id": SID, "frontier_offset": 0})
        if session is not None:
            self.write(root / "sessions" / (SID + ".json"), {"session_id": SID, "identity": IDENTITY, "offset": 0, **session})
        if pending is not None:
            self.write(root / "pending" / (SID + ".json"),
                       {"session_id": SID, "identity": IDENTITY, "request_id": REQUEST, **pending})
        if admission is DEFAULT_ADMISSION:
            admission = {"processing": None}
        if admission is not None:
            self.write(root / "admissions" / (SID + ".json"),
                       {"binding": {"session_id": SID}, "state_sha256": DIGEST, **admission})
        return root

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

    def test_v2_identity_and_migration_hold_are_distinct_from_write_gate(self):
        identity = {"scheme": "macos_volume_uuid_inode_v1", "volume_uuid": OTHER, "inode": 123}
        self.write(self.modern / "learner/admission.json", {"enabled": True,
                   "mode": "host_sessions_v2", "schema_version": 2})
        self.write(self.modern / "learner/enrollments" / (SID + ".json"),
                   {"session_id": SID, "identity": identity, "transcript_path": "/private"})
        self.write(self.modern / "learner/migration-holds" / (SID + ".json"),
                   {"session_id": SID, "kind": "identity_migration_hold", "plan_sha256": DIGEST,
                    "private_note": "never display"})
        result = self.report()["learner"]
        self.assertEqual(result["policy"]["metadata"]["mode"], "host_sessions_v2")
        self.assertEqual(result["policy"]["metadata"]["schema_version"], 2)
        self.assertEqual(result["enrollment"]["metadata"]["identity"], identity)
        self.assertEqual(result["migration_hold"]["metadata"]["kind"], "identity_migration_hold")
        self.assertNotIn("reconciliation_required", result["migration_hold"]["metadata"])
        self.assertNotIn("never display", json.dumps(result))
        self.assertNotIn("/private", json.dumps(result))

    def test_stable_identity_errors_use_exact_allowlist(self):
        for reason in ("admission_legacy_migration_required", "admission_migration_held",
                       "admission_identity_volume_changed", "admission_identity_filesystem_unsupported"):
            self.assertEqual(STATUS.metadata({"reason": reason}), {"reason": reason})
        self.assertEqual(STATUS.metadata({"reason": "admission_identity_private_path_or_secret"}), {})

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

    def test_exact_held_case_overrides_batch_limit_and_historical_success(self):
        held_run = "20260924T083200Z-b8af2a1f05fd497394bd99ea768a54cb"
        memory_id = "4e2a56cf-92a1-41b8-be82-98d3a0755e4a"
        root = self.learner_fixture(session={"offset": 685463327, "status": "reconciliation_required",
            "last_success_at": STAMP, "last_run": held_run,
            "reconciliation_required": {"run_id": held_run, "reason": "successful_or_unverified_write", "memory_ids": [memory_id]}},
            pending={"size_bytes": 700000000, "paused_request_id": REQUEST, "pause_reason": "batch_limit"})
        self.write(root / "runs" / held_run / "run.json", {"session_id": SID, "status": "failed",
            "event": "PreCompact", "end_offset": 693703649, "outcome": "failed", "tool_calls": 6,
            "write_calls": 1, "tool_errors": 3, "reason": "unverified_completion", "turn_completed": True,
            "writes": [{"tool": "remember", "memory_ids": [memory_id]}]})
        self.write(root / "events.jsonl", [{"session_id": SID, "event": "reconciliation_required", "run_id": held_run}] * 15, log=True)
        self.write(self.modern / "router-receipts.jsonl", [{"session_id": SID, "event": "Stop",
            "status": "not_queued", "reason": "enqueue_refused"}], log=True)
        health = self.report()["learner"]["health"]
        self.assertEqual(health["headline"], "reconciliation_required")
        self.assertEqual(health["policy"]["state"], "enabled")
        self.assertEqual(health["activity"]["state"], "held")
        self.assertEqual(health["activity"]["pending_pause_reason"], "batch_limit")
        self.assertEqual(health["holds"][0]["run_id"], held_run)
        self.assertEqual(health["progress"]["cursor_offset"], 685463327)
        self.assertEqual(health["progress"]["last_completed_interval"]["evidence"], "not_available_in_window")
        self.assertEqual(health["progress"]["last_success_timestamp_claim"], STAMP)
        self.assertEqual(health["failure"]["run_reason"], "unverified_completion")
        self.assertEqual(health["failure"]["diagnostic_error_count"], 3)
        self.assertEqual(health["failure"]["error_count_semantics"], "aggregate_provider_gateway_transport_not_unique_operations")
        self.assertEqual(health["outcomes"]["native_acknowledgement"]["acknowledged_write_count"], 1)
        self.assertEqual(health["outcomes"]["native_acknowledgement"]["writes"][0]["memory_ids"], [memory_id])
        self.assertEqual(health["outcomes"]["independent_readback"]["state"], "not_performed")
        self.assertFalse(health["recovery"]["automatic_replay_authorized"])

    def test_all_missing_means_unknown_not_disabled_or_caught_up(self):
        health = self.report()["learner"]["health"]
        self.assertEqual(health["headline"], "unknown")
        self.assertEqual(health["policy"]["state"], "unknown")
        self.assertEqual(health["progress"]["backlog"]["state"], "unknown")
        self.assertEqual(health["outcomes"]["queue"]["state"], "absent")
        self.assertEqual(health["outcomes"]["provider_completion"]["state"], "unknown")

    def test_disabled_policy_does_not_hide_retained_queue_or_hold(self):
        self.learner_fixture(enabled=False, session={"offset": 10}, pending={"size_bytes": 20})
        health = self.report()["learner"]["health"]
        self.assertEqual(health["headline"], "disabled")
        self.assertEqual(health["outcomes"]["queue"]["state"], "queued")
        self.learner_fixture(enabled=False, session={"status": "reconciliation_required"})
        health = self.report()["learner"]["health"]
        self.assertEqual(health["headline"], "reconciliation_required")
        self.assertEqual(health["policy"]["state"], "disabled")

    def test_processing_marker_is_not_proof_of_running_or_interrupted_worker(self):
        self.learner_fixture(session={"last_success_at": STAMP},
                             pending={"paused_request_id": REQUEST, "pause_reason": "batch_limit"},
                             admission={"processing": REQUEST})
        health = self.report()["learner"]["health"]
        self.assertEqual(health["headline"], "processing_unverified")
        self.assertEqual(health["holds"][0]["liveness"], "not_checked")
        self.assertEqual(health["recovery"]["action"], "inspect_processing_attempt")
        self.assertEqual(health["outcomes"]["provider_completion"]["state"], "unknown")

    def test_migration_and_reconciliation_remain_separate_holds(self):
        root = self.learner_fixture(session={"status": "reconciliation_required"},
                                    admission={"processing": REQUEST})
        self.write(root / "migration-holds" / (SID + ".json"), {"session_id": SID, "kind": "identity_migration_hold"})
        health = self.report()["learner"]["health"]
        self.assertEqual([v["kind"] for v in health["holds"]],
                         ["reconciliation_required", "identity_migration_hold", "processing_marker"])
        self.learner_fixture(session={"offset": 10})
        self.assertEqual(self.report()["learner"]["health"]["headline"], "identity_migration_hold")

    def test_stale_pause_cannot_pause_replacement_queue(self):
        self.learner_fixture(session={"offset": 10},
                             pending={"size_bytes": 20, "paused_request_id": "d" * 32, "pause_reason": "batch_limit"})
        health = self.report()["learner"]["health"]
        self.assertEqual(health["headline"], "queued")
        self.assertNotIn("pending_pause_reason", health["activity"])
        self.assertEqual(health["progress"]["backlog"]["bytes"], 10)
        self.learner_fixture(pending={"paused_request_id": REQUEST, "pause_reason": "batch_limit"})
        health = self.report()["learner"]["health"]
        self.assertEqual(health["headline"], "batch_limit")
        self.assertEqual(health["recovery"]["action"], "resume_pending")

    def test_backoff_uses_current_clock_and_expires_to_retained_pause(self):
        self.learner_fixture(session={"status": "failed", "retry_after": 100},
                             pending={"paused_request_id": REQUEST, "pause_reason": "failed"})
        with patch.object(STATUS.time, "time", return_value=99):
            self.assertEqual(self.report()["learner"]["health"]["headline"], "backoff")
        with patch.object(STATUS.time, "time", return_value=101):
            self.assertEqual(self.report()["learner"]["health"]["headline"], "paused")

    def test_completed_interval_requires_matching_successful_run_receipt(self):
        root = self.learner_fixture(session={"offset": 30, "status": "failed", "last_success_at": STAMP})
        self.write(root / "events.jsonl", [{"session_id": SID, "event": "learner_finished",
                                           "run_id": RUN, "status": "succeeded"}], log=True)
        self.write(root / "runs" / RUN / "run.json", {"session_id": SID, "status": "failed", "end_offset": 20})
        self.assertEqual(self.report()["learner"]["health"]["progress"]["last_completed_interval"]["evidence"], "not_available_in_window")
        self.write(root / "runs" / RUN / "run.json", {"session_id": SID, "status": "succeeded", "end_offset": 20,
            "ended_at": STAMP, "turn_completed": True, "write_calls": 0})
        health = self.report()["learner"]["health"]
        self.assertEqual(health["progress"]["last_completed_interval"], {"evidence": "receipt_only", "run_id": RUN,
            "end_offset": 20, "ended_at": STAMP, "start_offset": "not_recorded"})
        self.assertEqual(health["headline"], "failed")
        self.assertEqual(health["outcomes"]["independent_readback"]["state"], "not_performed")

    def test_gate_run_wins_over_newer_unrelated_linked_event(self):
        held_run = "20260924T083200Z-" + "e" * 32
        root = self.learner_fixture(session={"reconciliation_required": {"run_id": held_run, "reason": "write_status_unknown"}})
        self.write(root / "events.jsonl", [{"session_id": SID, "run_id": RUN, "event": "learner_finished", "status": "succeeded"}], log=True)
        self.write(root / "runs" / RUN / "run.json", {"session_id": SID, "status": "succeeded", "turn_completed": True})
        self.write(root / "runs" / held_run / "run.json", {"session_id": SID, "status": "failed", "turn_completed": False, "tool_errors": 2})
        learner = self.report()["learner"]
        self.assertEqual(learner["latest_run"]["run_id"], RUN)
        self.assertEqual(learner["held_run"]["run_id"], held_run)
        self.assertEqual(learner["health"]["outcomes"]["provider_completion"]["state"], "not_completed_in_run_receipt")
        self.assertEqual(learner["health"]["failure"]["diagnostic_error_count"], 2)

    def test_backlog_never_reads_transcript_and_requires_recorded_identity(self):
        state = {"offset": 10, "identity": IDENTITY}
        pending = {"size_bytes": 20, "identity": IDENTITY}
        self.assertEqual(STATUS.backlog_view(state, pending)["bytes"], 10)
        self.assertEqual(STATUS.backlog_view(state, {"size_bytes": 20})["state"], "unknown")
        self.assertEqual(STATUS.backlog_view(state, {**pending, "identity": {**IDENTITY, "inode": 124}})["state"], "identity_mismatch")
        self.assertEqual(STATUS.backlog_view(state, {**pending, "size_bytes": 9})["state"], "stale_snapshot")
        self.assertEqual(STATUS.backlog_view(state, {**pending, "size_bytes": True})["state"], "unknown")
        self.assertEqual(STATUS.backlog_view({"offset": 10, "device": 1, "inode": 2},
                                             {"size_bytes": 20, "device": 1, "inode": 2})["bytes"], 10)

    def test_unavailable_hold_metadata_cannot_be_idle(self):
        root = self.learner_fixture(session={"offset": 10, "status": "succeeded"})
        held = root / "migration-holds" / (SID + ".json")
        held.parent.mkdir(parents=True)
        held.write_text("not json")
        health = self.report()["learner"]["health"]
        self.assertEqual(health["headline"], "unknown")
        self.assertEqual(health["failure"]["class"], "metadata_unavailable")
        self.assertEqual(health["metadata_issues"], [{"component": "migration_hold", "status": "invalid_json"}])

    def test_idle_requires_explicit_absent_processing_and_is_not_caught_up(self):
        self.learner_fixture(session={"offset": 10, "status": "succeeded"}, admission=None)
        self.assertEqual(self.report()["learner"]["health"]["headline"], "unknown")
        self.learner_fixture(admission={"processing": None})
        health = self.report()["learner"]["health"]
        self.assertEqual(health["headline"], "idle")
        self.assertEqual(health["progress"]["backlog"]["state"], "unknown")
        self.assertEqual(health["outcomes"]["independent_readback"]["state"], "not_performed")

    def test_missing_linked_run_and_unsafe_links_do_not_report_idle(self):
        root = self.learner_fixture(session={"offset": 10, "status": "succeeded", "last_run": RUN},
                                    admission={"processing": None})
        health = self.report()["learner"]["health"]
        self.assertEqual(health["headline"], "unknown")
        self.assertIn({"component": "latest_run", "status": "missing"}, health["metadata_issues"])
        self.write(root / "events.jsonl", [{"session_id": SID, "run_id": "../private"}], log=True)
        health = self.report()["learner"]["health"]
        self.assertEqual(health["headline"], "unknown")
        self.assertIn({"component": "latest_run", "status": "unsafe_link"}, health["metadata_issues"])
        self.assertNotIn("../private", json.dumps(health))

    def test_queue_with_conflicting_file_identity_reports_failure(self):
        self.learner_fixture(session={"offset": 10},
                             pending={"size_bytes": 20, "identity": {**IDENTITY, "inode": 124}})
        health = self.report()["learner"]["health"]
        self.assertEqual(health["failure"]["class"], "transcript_identity_mismatch")
        self.assertEqual(health["outcomes"]["queue"]["state"], "queued")
        self.assertEqual(health["headline"], "failed")
        self.assertEqual(health["recovery"]["action"], "inspect_failure")

    def test_reason_count_and_timestamp_allowlists_remain_typed(self):
        self.assertEqual(STATUS.metadata({"reason": "unverified_completion"}), {"reason": "unverified_completion"})
        self.assertEqual(STATUS.metadata({"reason": "unverified_completion private text"}), {})
        self.assertEqual(STATUS.metadata({"tool_errors": -1, "write_calls": True, "retry_after": float("inf"),
                                           "offset": -1, "size_bytes": True}), {})
        self.assertEqual(STATUS.metadata({"reason": "resume_backoff", "previous_pause_reason": "backoff"}),
                         {"reason": "resume_backoff", "previous_pause_reason": "backoff"})
        self.assertEqual(STATUS.metadata({"previous_pause_reason": "private detail"}), {})
        self.assertEqual(STATUS.metadata({"previous_pause_reason": "emitted"}), {})

    def test_success_claim_is_not_native_acknowledgement_or_readback(self):
        root = self.learner_fixture(session={"last_run": RUN})
        self.write(root / "runs" / RUN / "run.json", {"session_id": SID, "status": "failed", "reason": "unverified_completion"})
        self.write(root / "runs" / RUN / "result.json", {"outcome": "stored", "memory_ids": [OTHER]})
        health = self.report()["learner"]["health"]
        self.assertEqual(health["failure"]["class"], "unverified_completion")
        self.assertEqual(health["outcomes"]["provider_completion"]["result_claim"]["outcome"], "stored")
        self.assertEqual(health["outcomes"]["native_acknowledgement"]["state"], "unknown")
        self.assertEqual(health["outcomes"]["independent_readback"]["state"], "not_performed")

    def test_malformed_processing_and_gate_remain_visible_without_private_text(self):
        self.learner_fixture(session={"reconciliation_required": "private gate"}, admission={"processing": "private processing"})
        health = self.report()["learner"]["health"]
        self.assertEqual(health["headline"], "reconciliation_required")
        self.assertEqual([v["kind"] for v in health["holds"]], ["reconciliation_required", "processing_marker"])
        self.assertNotIn("private", json.dumps(health))

    def test_empty_or_malformed_gate_cannot_be_sanitized_into_resume(self):
        for gate in ({}, None, False, [], {"reason": ["private gate"]}):
            with self.subTest(gate=gate):
                self.learner_fixture(session={"reconciliation_required": gate},
                                     pending={"paused_request_id": REQUEST, "pause_reason": "batch_limit"})
                learner = self.report()["learner"]
                self.assertIn("reconciliation_required", learner["session"]["metadata"])
                health = learner["health"]
                self.assertEqual(health["headline"], "reconciliation_required")
                self.assertEqual(health["recovery"]["action"], "reconcile_held_run")
                self.assertIn({"component": "session", "status": "invalid_fields",
                               "fields": ["reconciliation_required"]}, health["metadata_issues"])
                self.assertNotIn("private gate", json.dumps(learner))

    def test_missing_required_records_cannot_look_queued_or_idle(self):
        for queue in (True, False):
            for component, directory in (("session", "sessions"), ("admission", "admissions"),
                                         ("enrollment", "enrollments")):
                with self.subTest(queue=queue, component=component):
                    root = self.learner_fixture(session={"offset": 10}, pending={"size_bytes": 20} if queue else None)
                    if not queue:
                        (root / "pending" / (SID + ".json")).unlink(missing_ok=True)
                    (root / directory / (SID + ".json")).unlink()
                    health = self.report()["learner"]["health"]
                    self.assertEqual(health["headline"], "unknown")
                    self.assertEqual(health["recovery"]["action"], "inspect_metadata")
                    self.assertIn({"component": component, "status": "missing"}, health["metadata_issues"])

    def test_invalid_backoff_and_pause_reason_do_not_offer_resume(self):
        for field, values in (("retry_after", ["private backoff", None, True, -1, float("inf")]),
                              ("pause_reason", ["private reason", None, ["private reason"], "emitted"])):
            for value in values:
                with self.subTest(field=field, value=value):
                    session = {"retry_after": value} if field == "retry_after" else {}
                    pending = {"paused_request_id": REQUEST, "pause_reason": "batch_limit"}
                    if field == "pause_reason":
                        pending[field] = value
                    self.learner_fixture(session=session, pending=pending)
                    learner = self.report()["learner"]
                    health = learner["health"]
                    self.assertEqual(health["headline"], "unknown")
                    self.assertEqual(health["recovery"]["action"], "inspect_metadata")
                    component = "session" if field == "retry_after" else "pending"
                    self.assertIn({"component": component, "status": "invalid_fields", "fields": [field]},
                                  health["metadata_issues"])
                    self.assertNotIn("private", json.dumps(learner))

    def test_incomplete_admission_and_cursor_fields_cannot_look_idle(self):
        for directory, fields in (("sessions", ["offset"]),
                                  ("admissions", ["processing", "state_sha256"]),
                                  ("enrollments", ["frontier_offset"])):
            with self.subTest(directory=directory):
                root = self.learner_fixture(session={"offset": 10})
                path = root / directory / (SID + ".json")
                value = json.loads(path.read_text())
                for field in fields:
                    value.pop(field)
                self.write(path, value)
                health = self.report()["learner"]["health"]
                self.assertEqual(health["headline"], "unknown")
                self.assertTrue(any(issue.get("fields") == fields for issue in health["metadata_issues"]))

    def test_unknown_session_status_is_not_sanitized_into_idle(self):
        for status in ("private status", ["private status"]):
            with self.subTest(status=status):
                self.learner_fixture(session={"status": status})
                health = self.report()["learner"]["health"]
                self.assertEqual(health["headline"], "unknown")
                self.assertIn({"component": "session", "status": "invalid_fields", "fields": ["status"]},
                              health["metadata_issues"])
                self.assertNotIn("private status", json.dumps(health))

    def durable_fixture(self, *, anchored=True, status="succeeded", **changes):
        root = self.learner_fixture(session={"offset":20,"status":status,"last_run":RUN})
        self.write(root / "runs" / RUN / "run.json", {"session_id":SID,"status":"succeeded",
            "execution_manifest_sha256":DIGEST,"turn_completed":True,"write_calls":2,
            "attempted_write_calls":3,"applied_write_calls":2,"unchanged_write_calls":1})
        self.write(root / "events.jsonl", [{"session_id":SID,"event":"learner_finished","run_id":RUN,
                                           "status":"succeeded"}], log=True)
        record = {"version":1,"kind":"learner_settlement","session_id":SID,"run_id":RUN,
            "status":status,"reason":"verified_completion" if status=="succeeded" else "unverified_completion",
            "source":{"start_offset":10,"end_offset":20},"attempted_write_calls":3,
            "applied_write_calls":2,"unchanged_write_calls":1, "private":"never display", **changes}
        path = root / "runs" / RUN / "settlement.json"
        self.write(path,record)
        if anchored:
            self.learner_fixture(session={"offset":20,"status":status,"last_run":RUN,
                                          "settlement_sha256":hashlib.sha256(path.read_bytes()).hexdigest()})
        return root,path

    def test_durable_completed_interval_requires_anchored_settlement_and_separate_counts(self):
        self.durable_fixture()
        health = self.report()["learner"]["health"]
        self.assertEqual(health["progress"]["last_completed_interval"], {
            "evidence":"anchored_settlement_receipt","run_id":RUN,"start_offset":10,"end_offset":20})
        self.assertEqual(health["outcomes"]["native_acknowledgement"], {
            "state":"recorded_in_anchored_settlement","independent_persistence":"not_verified",
            "attempted_write_calls":3,"applied_write_calls":2,"unchanged_write_calls":1})
        self.assertEqual(health["outcomes"]["recorded_settlement"]["state"], "session_hash_match")
        self.assertEqual(health["outcomes"]["write_attempts"]["evidence"],"run_receipt_only")
        self.assertEqual(health["outcomes"]["provider_completion"]["state"],"completed_in_run_receipt")
        self.assertEqual(health["outcomes"]["independent_readback"]["state"],"not_performed")
        self.assertNotIn("never display", json.dumps(self.report()))

    def test_durable_provider_success_cannot_replace_missing_unanchored_or_changed_settlement(self):
        for mode in ("missing","unanchored","changed","invalid_anchor"):
            with self.subTest(mode=mode):
                root,path = self.durable_fixture(anchored=mode!="unanchored")
                if mode=="missing": path.unlink()
                if mode=="changed": path.write_bytes(path.read_bytes()+b" ")
                if mode=="invalid_anchor": self.learner_fixture(session={"last_run":RUN,"settlement_sha256":True})
                health = self.report()["learner"]["health"]
                self.assertEqual(health["progress"]["last_completed_interval"]["evidence"],"not_available_in_window")
                self.assertEqual(health["outcomes"]["native_acknowledgement"]["state"],"unknown")
                self.assertNotEqual(health["headline"],"idle")

    def test_failed_settlement_and_new_exact_gate_reason_preserve_hold(self):
        self.durable_fixture(status="reconciliation_required")
        root = self.modern / "learner"
        state_path = root / "sessions" / (SID+".json")
        state=json.loads(state_path.read_text())
        state["reconciliation_required"]={"run_id":RUN,"reason":"unverified_completion"}
        self.write(state_path,state)
        learner=self.report()["learner"]
        self.assertNotIn("invalid_fields",learner["session"])
        self.assertEqual(learner["health"]["headline"],"reconciliation_required")
        self.assertEqual(learner["health"]["failure"]["reason"],"unverified_completion")
        self.assertEqual(learner["health"]["progress"]["last_completed_interval"]["evidence"],"not_available_in_window")
        self.assertFalse(learner["health"]["recovery"]["automatic_replay_authorized"])

    def test_verified_no_effect_failure_remains_failed_without_coverage(self):
        self.durable_fixture(status="failed", reason="verified_no_effect_failure",
                             attempted_write_calls=1, applied_write_calls=0, unchanged_write_calls=0)
        learner = self.report()["learner"]
        recorded = learner["latest_run"]["recorded_settlement"]
        self.assertEqual(recorded["binding"], "session_hash_match")
        self.assertEqual(recorded["metadata"]["reason"], "verified_no_effect_failure")
        self.assertEqual(recorded["metadata"]["status"], "failed")
        self.assertEqual(learner["health"]["progress"]["last_completed_interval"]["evidence"],
                         "not_available_in_window")
        self.assertNotEqual(learner["health"]["headline"], "reconciliation_required")
        for change in ({"status": "succeeded"}, {"applied_write_calls": 1},
                       {"unchanged_write_calls": 1}, {"attempted_write_calls": 0}):
            with self.subTest(change=change):
                values = {"status": "failed", "reason": "verified_no_effect_failure",
                          "attempted_write_calls": 1, "applied_write_calls": 0,
                          "unchanged_write_calls": 0, **change}
                self.durable_fixture(**values)
                recorded = self.report()["learner"]["latest_run"]["recorded_settlement"]
                self.assertEqual(recorded["read"]["read_status"], "invalid_json")

    def test_failed_planning_settlement_has_zero_writes_and_no_coverage(self):
        values = {"status": "failed", "reason": "planning_not_complete", "attempted_write_calls": 0,
                  "applied_write_calls": 0, "unchanged_write_calls": 0}
        self.durable_fixture(**values)
        learner = self.report()["learner"]
        recorded = learner["latest_run"]["recorded_settlement"]
        self.assertEqual(recorded["binding"], "session_hash_match")
        self.assertEqual(recorded["metadata"]["reason"], "planning_not_complete")
        self.assertEqual(learner["health"]["progress"]["last_completed_interval"]["evidence"],
                         "not_available_in_window")
        for change in ({"status": "succeeded"}, {"attempted_write_calls": 1},
                       {"attempted_write_calls": 1, "applied_write_calls": 1}):
            with self.subTest(change=change):
                self.durable_fixture(**{**values, **change})
                recorded = self.report()["learner"]["latest_run"]["recorded_settlement"]
                self.assertEqual(recorded["read"]["read_status"], "invalid_json")

    def test_settlement_schema_is_typed_scoped_bounded_and_never_reads_private_evidence(self):
        for change in ({"session_id":OTHER,"hook_session_id":SID},{"run_id":"../private"},
                       {"version":True},{"reason":"private reason"},{"attempted_write_calls":True},
                       {"applied_write_calls":4},{"source":{"start_offset":True,"end_offset":20}},
                       {"source":{"start_offset":20,"end_offset":10}}):
            with self.subTest(change=change):
                self.durable_fixture(**change)
                health=self.report()["learner"]["health"]
                self.assertEqual(health["progress"]["last_completed_interval"]["evidence"],"not_available_in_window")
                self.assertNotEqual(health["headline"],"idle")
                self.assertNotIn("private",json.dumps(health))
        root,path=self.durable_fixture()
        path.write_bytes(b"x"*(STATUS.MAX_SETTLEMENT_BYTES+1))
        self.assertEqual(self.report()["learner"]["latest_run"]["recorded_settlement"]["read"]["read_status"],"oversize")
        root,path=self.durable_fixture()
        opened=[]
        original=STATUS.open_regular
        def checked(path):
            opened.append(path.name)
            self.assertNotIn(path.name,{"execution-manifest.json","mcp-audit.jsonl","provider-observation.json","prompt.txt"})
            return original(path)
        with patch.object(STATUS,"open_regular",side_effect=checked): self.report()
        self.assertIn("settlement.json",opened)

    def test_active_publication_prevents_idle_after_processing_clear_and_pending_delete(self):
        for active in ({"ticket_id":OTHER,"ticket_sha256":DIGEST},
                       {"ticket_id":"../../private","ticket_sha256":DIGEST}, {}, None):
            with self.subTest(active=active):
                root=self.learner_fixture(session={"offset":10},admission={"processing":None})
                self.write(root/"publications"/SID/"active.json",active)
                learner=self.report()["learner"]
                self.assertEqual(learner["health"]["headline"],"publication_recovery_pending")
                self.assertEqual(learner["health"]["recovery"]["action"],"recover_publication")
                self.assertIn({"kind":"publication_recovery_pending","liveness":"not_checked"},learner["health"]["holds"])
                self.assertNotIn("private",json.dumps(learner))

    def test_active_index_symlink_duplicate_fields_and_oversize_are_recovery_pending(self):
        root=self.learner_fixture(session={"offset":10})
        path=root/"publications"/SID/"active.json"
        self.write(path,{"ticket_id":OTHER,"ticket_sha256":DIGEST})
        for raw in (b'{"ticket_id":"x","ticket_id":"y"}', b'x'*(STATUS.MAX_JSON_BYTES+1)):
            path.write_bytes(raw)
            self.assertEqual(self.report()["learner"]["health"]["headline"],"publication_recovery_pending")
        path.unlink()
        path.symlink_to(root/"private-ticket.json")
        self.assertEqual(self.report()["learner"]["health"]["headline"],"publication_recovery_pending")
        path.unlink()
        self.assertEqual(self.report()["learner"]["health"]["headline"],"idle")

    def test_processing_execution_and_orphan_anchor_are_not_idle(self):
        for reference in ({"run_id":RUN,"manifest_sha256":DIGEST}, {"run_id":"private"}, None):
            with self.subTest(reference=reference):
                self.learner_fixture(session={"offset":10},admission={"processing":None,"processing_execution":reference})
                self.assertEqual(self.report()["learner"]["health"]["headline"],"processing_unverified")
        self.learner_fixture(session={"offset":10,"settlement_sha256":DIGEST})
        self.assertNotEqual(self.report()["learner"]["health"]["headline"],"idle")

    def test_missing_held_run_receipt_stays_in_metadata_issues(self):
        self.learner_fixture(session={"reconciliation_required": {"run_id": RUN, "reason": "write_status_unknown"}})
        health = self.report()["learner"]["health"]
        self.assertEqual(health["headline"], "reconciliation_required")
        self.assertIn({"component": "held_run", "status": "missing"}, health["metadata_issues"])
        self.assertEqual(health["outcomes"]["native_acknowledgement"]["state"], "unknown")


if __name__ == "__main__":
    unittest.main()
