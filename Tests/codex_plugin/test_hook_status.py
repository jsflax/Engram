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
    def test_advice_cleanup_diagnostics_are_fixed_enums_only(self):
        self.assertEqual(STATUS.metadata({
            "status": "timeout", "failure_phase": "mcp_initialize", "error_kind": "classified",
            "cleanup_status": "timeout", "cleanup_error_kind": "classified",
        }), {"status": "timeout", "failure_phase": "mcp_initialize", "error_kind": "classified",
             "cleanup_status": "timeout", "cleanup_error_kind": "classified"})
        for value in ("private exception message", {"private": "data"}, [], None, False):
            with self.subTest(value=value):
                self.assertEqual(STATUS.metadata({"cleanup_status": value, "cleanup_error_kind": value}), {})
        for status in ("completed", "timeout", "failed"):
            self.assertEqual(STATUS.metadata({"cleanup_status": status}), {"cleanup_status": status})

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

    def report(self, sid=SID):
        return STATUS.report(environ={"CODEX_HOME": str(self.home), "CODEX_THREAD_ID": sid})

    def admission_event(self, reason="load", *, sid=SID, request=REQUEST, stamp=STAMP, **facts):
        if reason == "load" and not facts:
            facts = {"load_average": 50.0, "load_limit": 32}
        return {"event": "worker_admitted" if reason == "admitted" else "worker_admission_deferred",
                "session_id": sid, "request_id": request, "lane": "pending", "time": stamp,
                "reason": reason, "admission": {"schema_version": 1, "reason": reason, **facts}}

    def admission_report(self, rows, *, now=None, session=None, pending=None):
        root = self.learner_fixture(session={"status": "succeeded", **(session or {})},
            pending={"event": "Stop", "size_bytes": 1000, **(pending or {})})
        self.write(root / "events.jsonl", rows, log=True)
        epoch = STATUS.dt.datetime.fromisoformat(STAMP.replace("Z", "+00:00")).timestamp()
        with patch.object(STATUS.time, "time", return_value=epoch + 10 if now is None else now), \
             patch.object(STATUS.os, "getloadavg", side_effect=AssertionError("status must not sample load")):
            return self.report()

    def test_selected_worker_load_deferral_has_facts_age_and_no_scheduled_wake(self):
        value = self.admission_report([self.admission_event()])
        health = value["learner"]["health"]
        decision = health["worker_admission"]
        self.assertEqual(health["headline"], "admission_deferred")
        self.assertEqual(health["recovery"]["action"], "wait_for_eligible_event")
        self.assertFalse(health["recovery"]["automatic_replay_authorized"])
        self.assertEqual(decision["candidate_binding"], "selected_pending_request")
        self.assertEqual(decision["age_seconds"], 10)
        self.assertEqual(decision["decision"]["load_average"], 50)
        self.assertEqual(decision["decision"]["load_limit"], 32)
        self.assertEqual(decision["next_attempt"],
                         {"policy": "next_eligible_lifecycle_event", "scheduled_at": None})
        self.assertEqual(health["outcomes"]["queue"]["state"], "queued")
        self.assertEqual(health["failure"]["class"], "none_observed")

    def test_health_without_admission_has_typed_not_observed_default(self):
        health = STATUS.health_summary({})
        self.assertEqual(health["headline"], "unknown")
        self.assertEqual(health["worker_admission"], STATUS.worker_admission_view(None, SID, {}))
        self.assertEqual(health["worker_admission"]["state"], "not_observed")
        self.assertIsNone(health["worker_admission"]["next_attempt"]["scheduled_at"])

    def test_other_candidate_or_previous_request_is_not_selected_deferral(self):
        for changed, binding in (({"sid": OTHER}, "other_session"),
                                 ({"request": "d" * 32}, "previous_selected_request")):
            with self.subTest(binding=binding):
                value = self.admission_report([self.admission_event(**changed)])
                health = value["learner"]["health"]
                self.assertEqual(health["headline"], "queued")
                self.assertEqual(health["worker_admission"]["candidate_binding"], binding)
                if binding == "other_session":
                    self.assertNotIn(OTHER, json.dumps(value["learner"]["worker_admission"]))
                    self.assertEqual(value["learner"]["events"], [])

    def test_legacy_global_reason_is_historical_advisory_only(self):
        value = self.admission_report([{"event": "worker_admission_deferred", "reason": "load", "time": STAMP,
                                        "private": "/secret/path"}])
        health = value["learner"]["health"]
        self.assertEqual(health["headline"], "queued")
        self.assertEqual(health["worker_admission"]["state"], "historical_advisory")
        self.assertEqual(health["worker_admission"]["scope"], "shared_worker")
        self.assertNotIn("secret", json.dumps(value))

    def test_later_admission_for_any_candidate_supersedes_selected_deferral(self):
        for admitted_sid in (SID, OTHER):
            with self.subTest(sid=admitted_sid):
                value = self.admission_report([self.admission_event(),
                    self.admission_event("admitted", sid=admitted_sid, load_average=0, load_limit=32)])
                self.assertEqual(value["learner"]["health"]["headline"], "queued")
                self.assertEqual(value["learner"]["worker_admission"]["state"], "admitted")
                self.assertNotEqual(value["learner"]["health"]["activity"]["state"], "processing_unverified")

    def test_stale_or_future_deferral_cannot_claim_current_admission_state(self):
        epoch = STATUS.dt.datetime.fromisoformat(STAMP.replace("Z", "+00:00")).timestamp()
        for now, freshness in ((epoch + 601, "stale"), (epoch - 1, "clock_skew")):
            value = self.admission_report([self.admission_event()], now=now)
            self.assertEqual(value["learner"]["health"]["headline"], "queued")
            self.assertEqual(value["learner"]["worker_admission"]["freshness"], freshness)

    def test_cooldown_eligibility_is_not_a_scheduled_wake_and_can_expire(self):
        epoch = STATUS.dt.datetime.fromisoformat(STAMP.replace("Z", "+00:00")).timestamp()
        row = self.admission_event("cooldown", cooldown_eligible_after=epoch + 100)
        value = self.admission_report([row])
        next_attempt = value["learner"]["worker_admission"]["next_attempt"]
        self.assertEqual(next_attempt["eligible_after"], epoch + 100)
        self.assertIsNone(next_attempt["scheduled_at"])
        self.assertEqual(value["learner"]["health"]["headline"], "admission_deferred")
        expired = self.admission_report([row], now=epoch + 101)
        self.assertEqual(expired["learner"]["worker_admission"]["next_attempt"]["eligibility"], "elapsed")
        self.assertEqual(expired["learner"]["health"]["headline"], "queued")

    def test_concurrency_and_unavailable_decisions_do_not_claim_provider_failure(self):
        for reason in ("concurrency", "load_unavailable", "state_unavailable"):
            with self.subTest(reason=reason):
                value = self.admission_report([self.admission_event(reason)])
                health = value["learner"]["health"]
                self.assertEqual(health["headline"], "admission_deferred")
                self.assertEqual(health["worker_admission"]["reason"], reason)
                self.assertEqual(health["failure"]["class"], "none_observed")
                self.assertFalse(health["recovery"]["automatic_replay_authorized"])

    def test_malformed_latest_decision_blocks_fallback_without_leaking_content(self):
        row = self.admission_event()
        invalid = [dict(row, admission={**row["admission"], "private": "SECRET_PATH"}),
                   dict(row, admission={"schema_version": 1, "reason": "load", "load_average": True, "load_limit": 0}),
                   dict(row, admission={"schema_version": 1, "reason": "load", "load_average": float("nan"), "load_limit": 1}),
                   dict(row, admission={"schema_version": 1, "reason": "load", "load_average": 10**400, "load_limit": 1}),
                   dict(row, lane=[]), dict(row, time="SECRET_TIMESTAMP"), dict(row, reason={}),
                   dict(row, admission={"schema_version": 1, "reason": "private"})]
        for changed in invalid:
            with self.subTest(fields=changed.keys()):
                value = self.admission_report([row, changed])
                self.assertEqual(value["learner"]["worker_admission"]["state"], "unknown")
                self.assertEqual(value["learner"]["health"]["headline"], "queued")
                self.assertNotIn("SECRET", json.dumps(value))

    def test_worker_admission_does_not_override_session_holds_backoff_or_pause(self):
        epoch = STATUS.dt.datetime.fromisoformat(STAMP.replace("Z", "+00:00")).timestamp()
        for session, pending, expected in [
            ({"retry_after": epoch + 100}, {}, "backoff"),
            ({}, {"paused_request_id": REQUEST, "pause_reason": "batch_limit"}, "batch_limit"),
            ({"status": "reconciliation_required", "reconciliation_required": {"reason": "write_status_unknown"}}, {}, "reconciliation_required")]:
            value = self.admission_report([self.admission_event()], session=session, pending=pending)
            self.assertEqual(value["learner"]["health"]["headline"], expected)

    def test_admission_observation_uses_same_bounded_log_read(self):
        real = STATUS.read_bounded
        with patch.object(STATUS, "read_bounded", wraps=real) as reads:
            value = self.admission_report([self.admission_event()])
        event_reads = [c for c in reads.call_args_list if c.args[0].name == "events.jsonl"]
        self.assertEqual(len(event_reads), 1)
        self.assertEqual(event_reads[0].args[1], STATUS.MAX_LOG_BYTES)
        self.assertTrue(event_reads[0].kwargs["tail"])
        self.assertLessEqual(len(STATUS.render_report(value).encode()) + 1, STATUS.MAX_OUTPUT_BYTES)

    def test_startup_failure_fixed_codes_surface_without_changing_hold_or_replay(self):
        root = self.learner_fixture(session={"status": "reconciliation_required", "last_run": RUN,
            "reconciliation_required": {"run_id": RUN, "reason": "unverified_completion"}})
        diagnostic = {"stage": "execution_context", "reason": "execution_context_backend_changed"}
        self.write(root / "runs" / RUN / "run.json", {"session_id": SID, "status": "failed",
            "reason": "unverified_completion", "gateway_startup_failure": diagnostic})
        health = self.report()["learner"]["health"]
        self.assertEqual(health["failure"]["gateway_startup_failure"], diagnostic)
        self.assertEqual(health["headline"], "reconciliation_required")
        self.assertFalse(health["recovery"]["automatic_replay_authorized"])
        for changed in ({"stage": "private-path", "reason": "execution_context_backend_changed"},
                        {"stage": "execution_context", "reason": "secret value"},
                        {**diagnostic, "exception": "private payload"},
                        {"stage": [], "reason": {}}):
            with self.subTest(fields=list(changed)):
                self.assertNotIn("gateway_startup_failure", STATUS.metadata({"gateway_startup_failure": changed}))

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

    def test_shared_hook_session_selects_concrete_actor_and_isolates_siblings(self):
        sibling = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
        root_hash, child_hash, sibling_hash = [hashlib.sha256(v.encode()).hexdigest()[:20]
                                               for v in (SID, OTHER, sibling)]
        for component, relative in (("advice", "recall-state/receipts.jsonl"),
                                    ("lifecycle", "lifecycle/receipts.jsonl")):
            self.write(self.modern / relative, [
                {"session": root_hash, "agent": None, "status": "emitted"},
                {"session": root_hash, "agent": child_hash, "event": "SubagentStart", "status": "empty"},
                {"session": root_hash, "agent": sibling_hash, "status": "timeout"}], log=True)
            root = self.report()[component]
            self.assertEqual([r["status"] for r in root["receipts"]], ["emitted"])
            self.assertEqual(root["receipts"][0]["attribution"], "session_match_agent_unspecified")
            self.assertEqual([r["agent"] for r in root["related_receipts"]], [child_hash, sibling_hash])
            self.assertTrue(all(r["attribution"] == "shared_session_other_agent" for r in root["related_receipts"]))
            child = self.report(OTHER)[component]
            self.assertEqual([r["agent"] for r in child["receipts"]], [child_hash])
            self.assertEqual(child["receipts"][0]["attribution"], "selected_agent")
            self.assertEqual(child["related_receipts"], [])
            self.assertNotIn(sibling_hash, json.dumps(child))

    def test_explicit_actor_wins_and_legacy_or_invalid_actor_stays_limited(self):
        root_digest = hashlib.sha256(SID.encode()).hexdigest()
        other_digest = hashlib.sha256(OTHER.encode()).hexdigest()
        self.write(self.modern / "recall-state/receipts.jsonl", [
            {"session": other_digest[:20], "agent": root_digest, "status": "emitted"},
            {"session": root_digest[:20], "status": "empty"},
            {"session": root_digest[:20], "agent": None, "status": "guard"},
            {"session": root_digest[:20], "agent": other_digest, "status": "timeout"},
            *[{"session": root_digest[:20], "agent": bad, "status": "invalid"}
              for bad in ([], {}, True, "", "PRIVATE_ACTOR")]], log=True)
        view = self.report()["advice"]
        self.assertEqual([r["attribution"] for r in view["receipts"]],
                         ["selected_agent", "session_match_agent_unspecified", "session_match_agent_unspecified"])
        self.assertEqual(view["related_matching_records"], 6)
        self.assertEqual(view["related_receipts"][0]["attribution"], "shared_session_other_agent")
        self.assertTrue(all(r["attribution"] == "session_match_invalid_agent" for r in view["related_receipts"][1:]))
        self.assertNotIn("PRIVATE", json.dumps(view))

    def test_router_canonical_actor_precedes_shared_hook_session(self):
        self.write(self.modern / "router-receipts.jsonl", [
            {"session_id": SID, "hook_session_id": OTHER, "status": "observed"},
            {"session_id": OTHER, "hook_session_id": SID, "hook_event": "SubagentStop", "status": "queued"},
            {"hook_session_id": SID, "status": "not_queued"},
            {"session_id": None, "hook_session_id": SID, "status": "rejected"},
            {"session_id": "PRIVATE_ID", "hook_session_id": SID, "status": "rejected"}], log=True)
        root = self.report()["router"]
        self.assertEqual([r["attribution"] for r in root["receipts"]],
                         ["selected_task", "hook_session_match_task_unspecified"])
        self.assertEqual([r["attribution"] for r in root["related_receipts"]],
                         ["shared_hook_session_other_task", "hook_session_match_invalid_task", "hook_session_match_invalid_task"])
        child = self.report(OTHER)["router"]
        self.assertEqual(len(child["receipts"]), 1)
        self.assertEqual(child["receipts"][0]["session_id"], OTHER)
        self.assertEqual(child["receipts"][0]["attribution"], "selected_task")
        self.assertNotIn("PRIVATE", json.dumps(root))

    def test_child_learner_event_cannot_link_parent_to_child_run(self):
        root = self.learner_fixture(session={"status": "succeeded"})
        self.write(root / "events.jsonl", [{"session_id": OTHER, "hook_session_id": SID,
            "event": "learner_finished", "status": "failed", "run_id": RUN}], log=True)
        self.write(root / "runs" / RUN / "run.json", {"session_id": OTHER, "hook_session_id": SID,
            "status": "failed", "reason": "unverified_completion"})
        original, opened = STATUS.open_regular, []
        def selected_only(path):
            opened.append(Path(path))
            self.assertNotIn("runs", Path(path).parts)
            self.assertNotIn(OTHER, str(path))
            return original(path)
        with patch.object(STATUS, "open_regular", side_effect=selected_only):
            parent = self.report()["learner"]
        self.assertEqual(parent["events"], [])
        self.assertEqual(parent["latest_run"]["read_status"], "not_linked")
        self.assertEqual(parent["health"]["failure"]["class"], "none_observed")
        child = self.report(OTHER)["learner"]
        self.assertEqual(child["events"][0]["attribution"], "selected_task")
        self.assertEqual(child["latest_run"]["run_id"], RUN)
        self.assertEqual(child["latest_run"]["identity_attribution"], "selected_task")

    def test_scoped_json_rejects_conflicting_or_malformed_canonical_identity(self):
        path = self.modern / "learner/sessions" / (SID + ".json")
        for canonical in (OTHER, None, [], "PRIVATE_ID"):
            with self.subTest(canonical=canonical):
                self.write(path, {"session_id": canonical, "hook_session_id": SID, "offset": 0})
                value, view = STATUS.scoped_json(path, SID)
                self.assertIsNone(value)
                self.assertEqual(view["read"]["read_status"], "session_mismatch")
        self.write(path, {"hook_session_id": SID, "offset": 0})
        value, view = STATUS.scoped_json(path, SID)
        self.assertIsNotNone(value)
        self.assertEqual(view["identity_attribution"], "hook_session_match_task_unspecified")
        self.write(path, {"binding": {"session_id": OTHER, "hook_session_id": SID}})
        self.assertIsNone(STATUS.scoped_json(path, SID, binding=True)[0])

    def test_linked_run_canonical_identity_cannot_fall_back_to_root(self):
        root = self.learner_fixture()
        for identity in ({"session_id": OTHER, "hook_session_id": SID},
                         {"session_id": None, "hook_session_id": SID},
                         {"hook_session_id": OTHER}):
            self.write(root / "runs" / RUN / "run.json", {**identity, "status": "failed"})
            original = STATUS.open_regular
            def no_private_result(path):
                self.assertNotEqual(Path(path).name, "result.json")
                return original(path)
            with patch.object(STATUS, "open_regular", side_effect=no_private_result):
                result = STATUS.linked_run(root, RUN, SID)
            self.assertEqual(result["read"]["read_status"], "session_mismatch")
        self.write(root / "runs" / RUN / "run.json", {"hook_session_id": SID, "status": "succeeded"})
        self.assertEqual(STATUS.linked_run(root, RUN, SID)["identity_attribution"],
                         "hook_session_match_task_unspecified")

    def test_related_receipts_share_one_bounded_read_and_do_not_evict_selected(self):
        sh, oh = [hashlib.sha256(v.encode()).hexdigest()[:20] for v in (SID, OTHER)]
        self.write(self.modern / "recall-state/receipts.jsonl", [
            {"session": sh, "agent": sh, "status": "emitted"},
            *[{"session": sh, "agent": oh, "status": "empty"}] * 25], log=True)
        original = STATUS.read_bounded
        with patch.object(STATUS, "read_bounded", wraps=original) as reads:
            view = self.report()["advice"]
        selected_reads = [c for c in reads.call_args_list if str(c.args[0]).endswith("recall-state/receipts.jsonl")]
        self.assertEqual(len(selected_reads), 1)
        self.assertEqual(selected_reads[0].args[1], STATUS.MAX_LOG_BYTES)
        self.assertTrue(selected_reads[0].kwargs["tail"])
        self.assertEqual(view["window"]["matching_records"], 1)
        self.assertEqual(view["receipts"][0]["status"], "emitted")
        self.assertEqual(view["related_matching_records"], 25)
        self.assertEqual(len(view["related_receipts"]), STATUS.MAX_RECORDS)

    def test_subagent_stop_survives_selected_report_without_widening_metadata(self):
        # Stored metadata fixtures exercise reporting, not host hook delivery.
        root = self.learner_fixture(pending={"event": "SubagentStop",
            "hook_session_id": SID, "prompt": "PRIVATE_SUBAGENT_BODY"})
        self.write(self.modern / "router-receipts.jsonl", [
            {"session_id": SID, "hook_event": "SubagentStop", "status": "queued", "at": STAMP,
             "last_assistant_message": "PRIVATE_SUBAGENT_BODY"},
            {"session_id": OTHER, "hook_event": "SubagentStop", "status": "queued"},
            {"session_id": SID, "hook_event": "SubagentStop PRIVATE_EVENT", "status": "observed"}], log=True)
        self.write(root / "events.jsonl", [
            {"session_id": SID, "event": "queued", "hook_event": "SubagentStop", "request_id": REQUEST},
            {"session_id": OTHER, "event": "queued", "hook_event": "SubagentStop"}], log=True)
        rendered = STATUS.render_report(self.report())
        result = json.loads(rendered)
        router = result["router"]["receipts"]
        self.assertEqual(len(router), 2)
        self.assertEqual(router[0]["hook_event"], "SubagentStop")
        self.assertEqual(router[0]["status"], "queued")
        self.assertNotIn("hook_event", router[1])
        events = result["learner"]["events"]
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["event"], "queued")
        self.assertEqual(events[0]["hook_event"], "SubagentStop")
        self.assertEqual(result["learner"]["pending"]["metadata"]["event"], "SubagentStop")
        self.assertEqual(result["learner"]["memory_readback"], "not_performed")
        self.assertNotIn("PRIVATE_", rendered)
        self.assertTrue(all(row["session_id"] == SID for row in router + events))

    def test_runtime_identity_bounded_fields_only(self):
        raw = {"schema_version": 1, "evidence": "observed_package_files", "status": "complete",
               "package": {"path": "/private/secret", "version": "0.2.0+codex.20260917123456",
                           "status": "ok", "manifest": {"sha256": DIGEST, "status": "ok"}},
               "sources": {"host_admission": {"path": "/secret.py", "sha256": DIGEST, "status": "ok"},
                           "project_template": {"path": "/secret.md", "sha256": DIGEST, "status": "ok"},
                           "secret": {"sha256": DIGEST}}}
        view = STATUS.metadata({"runtime_identity": raw})["runtime_identity"]
        self.assertEqual(view["sources"]["host_admission"]["sha256"], DIGEST)
        self.assertEqual(view['sources']['project_template']['sha256'], DIGEST)
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

    def test_parser_reasons_are_exact_codes_without_private_exception_text(self):
        for reason in ("partial_final_record", "record_exceeds_scan_limit", "message_exceeds_char_limit",
                       "ambiguous_fork_history", "missing_fork_ordinal"):
            self.assertEqual(STATUS.metadata({"reason": reason}), {"reason": reason})
            self.assertEqual(STATUS.metadata({"reason": reason + " private body"}), {})

    def test_current_blocked_input_reason_overrides_historical_success(self):
        root = self.learner_fixture(session={"offset": 100, "status": "succeeded", "last_run": RUN},
            pending={"size_bytes": 200, "paused_request_id": REQUEST, "pause_reason": "blocked"})
        self.write(root / "runs" / RUN / "run.json", {"session_id": SID, "status": "succeeded"})
        event = {"session_id": SID, "event": "blocked", "request_id": REQUEST,
                 "offset": 100, "reason": "message_exceeds_char_limit"}
        self.write(root / "events.jsonl", [event], log=True)
        health = self.report()["learner"]["health"]
        self.assertEqual(health["failure"], {"class": "input_blocked",
            "reason": "message_exceeds_char_limit", "reason_evidence": "matching_request_and_cursor_event"})
        self.assertEqual(health["holds"], [])
        self.assertEqual(health["headline"], "paused")
        self.assertEqual(health["recovery"], {"action": "inspect_failure", "automatic_replay_authorized": False})

    def test_old_or_mismatched_blocker_is_history_not_current_diagnosis(self):
        root = self.learner_fixture(session={"offset": 100},
            pending={"size_bytes": 200, "paused_request_id": REQUEST, "pause_reason": "blocked"})
        for fields in ({}, {"request_id": "d" * 32}, {"request_id": REQUEST, "offset": 99},
                       {"request_id": REQUEST, "reason": "private exception"}):
            self.write(root / "events.jsonl", [{"session_id": SID, "event": "blocked",
                "offset": 100, "reason": "message_exceeds_char_limit", **fields}], log=True)
            health = self.report()["learner"]["health"]
            self.assertEqual(health["failure"], {"class": "input_blocked", "reason_evidence": "not_available_in_window"})
        self.write(root / "pending" / (SID + ".json"), {"session_id": SID, "identity": IDENTITY,
            "request_id": REQUEST, "paused_request_id": REQUEST, "pause_reason": "batch_limit"})
        self.assertEqual(self.report()["learner"]["health"]["failure"]["class"], "none_observed")

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
