"""Independent public API acceptance, using real journals and actual SIGKILL."""
import contextlib
import copy
import fcntl
import json
import os
from pathlib import Path
import signal
import shutil
import socket
import sqlite3
import subprocess
import sys
import time
import unittest
from unittest import mock

from legacy_fixture import (LegacyFixture, load_runtime, SID, RUN_ID, SUCCESS_ID,
                            DUPLICATE_ID, encode, digest, write_json)

L = load_runtime()
HARNESS_POPEN = subprocess.Popen


class LegacyAcceptanceTests(unittest.TestCase):
    def fixture(self):
        value = LegacyFixture(L)
        self.addCleanup(value.close)
        return value

    @contextlib.contextmanager
    def no_external_effects(self, fixture):
        original_connect = sqlite3.connect
        reads = []
        def read_only(database, *args, **kwargs):
            self.assertEqual(database, fixture.store.as_uri() + "?mode=ro")
            self.assertIs(kwargs.get("uri"), True)
            connection = original_connect(database, *args, **kwargs)
            reads.append(database)
            return connection
        with contextlib.ExitStack() as stack:
            for module, name in ((subprocess, "Popen"), (subprocess, "run"),
                                 (subprocess, "call"), (socket, "socket"), (os, "system")):
                stack.enter_context(mock.patch.object(module, name,
                    side_effect=AssertionError("provider/native/network forbidden")))
            stack.enter_context(mock.patch.object(sqlite3, "connect", side_effect=read_only))
            yield reads

    def completed(self, fixture, plan, result, *, pending=None):
        state = json.loads(fixture.state_path.read_bytes())
        record = json.loads(fixture.record_path.read_bytes())
        self.assertEqual(state, plan["next_state"])
        self.assertEqual(state["offset"], fixture.end)
        self.assertEqual(state["admission"]["frontier_offset"], fixture.frontier)
        self.assertNotIn("reconciliation_required", state)
        self.assertEqual(state["status"], "legacy_reconciled_no_new_mutation")
        for key in ("last_run", "last_success_at", "last_excerpt_sha256", "unrelated_field"):
            self.assertEqual(state[key], fixture.state[key])
        self.assertEqual(record["state_sha256"], L.durable.object_digest(state))
        self.assertIsNone(record["processing"])
        self.assertNotIn("processing_execution", record)
        self.assertEqual(fixture.pending_path.read_bytes(), pending or encode(fixture.request))
        self.assertEqual(json.loads(fixture.pending_path.read_bytes())["pause_reason"], "batch_limit")
        self.assertEqual(result["kind"], "legacy_interval_reconciliation")
        self.assertEqual(result["historical_run_status"], "failed")
        self.assertIs(result["historical_execution_sealed"], False)
        self.assertEqual(result["native_mutations_performed"], 0)
        self.assertEqual(result["source_binding_grade"], "current_bounded_reconstruction")
        self.assertFalse((fixture.root / "publications" / SID / "active.json").exists())
        self.assertFalse(list(fixture.root.rglob("execution-manifest.json")))
        self.assertFalse(list(fixture.root.rglob("successful-interval-coverage.json")))
        self.assertNotIn(b"PRIVATE", encode(result))
        for directory in (fixture.root / "reconciliations", fixture.root / "publications"):
            for path in directory.rglob("*"):
                if path.is_file():
                    self.assertEqual(path.stat().st_mode & 0o777, 0o600, path.name)

    def test_prepare_apply_recover_preserves_history_pause_and_rows(self):
        f = self.fixture()
        before, history, database = f.current(), f.history_snapshot(), f.store.read_bytes()
        with self.no_external_effects(f) as reads:
            plan = f.prepare()
            self.assertEqual(f.current(), before)
            self.assertFalse((f.root / "reconciliations").exists())
            result = f.apply(plan)
            self.completed(f, plan, result)
            self.assertEqual(f.recover(plan), result)
            self.assertEqual(f.apply(plan), result)
            self.assertGreater(len(reads), 0)
        self.assertEqual(f.history_snapshot(), history)
        self.assertEqual(f.store.read_bytes(), database)
        self.assertEqual(json.loads(history["runs/" + RUN_ID + "/run.json"][0])["write_calls"], 1)
        self.assertEqual(len(f.review["attempts"]), 2)

    def test_first_upgrade_creates_publications_only_when_applying(self):
        f = self.fixture()
        (f.root / "publications").rmdir()
        before, history, database = f.current(), f.history_snapshot(), f.store.read_bytes()
        with self.no_external_effects(f):
            plan = f.prepare()
            self.assertEqual(f.current(), before)
            self.assertFalse((f.root / "publications").exists())
            result = f.apply(plan)
            self.completed(f, plan, result)
            self.assertEqual(f.recover(plan), result)
        self.assertEqual(f.history_snapshot(), history)
        self.assertEqual(f.store.read_bytes(), database)

    def test_source_append_and_unrelated_database_access_changes_are_allowed(self):
        f = self.fixture()
        plan = f.prepare()
        f.append("Later appended message stays beyond the selected interval.")
        f.update_row("accessCount=accessCount+1,lastAccessedAt=?", (time.time(),))
        with contextlib.closing(sqlite3.connect(f.store)) as db:
            db.execute("INSERT INTO Memory(globalId,content) VALUES (?,?)", ("91111111-2222-4333-8444-555555555555", "unrelated"))
            db.commit()
        current_store, current_source = f.store.read_bytes(), f.path.read_bytes()
        result = f.apply(plan)
        self.completed(f, plan, result)
        self.assertEqual(f.path.read_bytes(), current_source)
        self.assertEqual(f.store.read_bytes(), current_store)
        self.assertLess(f.end, f.path.stat().st_size)

    def test_newer_pending_already_present_is_the_preserved_ticket_request(self):
        f = self.fixture()
        pending, record = f.newer_pending()
        plan = f.prepare()
        result = f.apply(plan)
        self.completed(f, plan, result, pending=pending)
        self.assertEqual(json.loads(f.record_path.read_bytes())["last_event"], json.loads(record)["last_event"])
        self.assertEqual(json.loads(L.publication._raw(plan["inputs"]["pending"], old=True))["request_id"], "newer-stop-request")
        self.assertNotEqual(f.review["historical_request_id"], "newer-stop-request")

    def test_changed_source_refuses_without_publication(self):
        for change in ("interval", "truncate", "replace"):
            with self.subTest(change=change):
                f = self.fixture()
                plan, before = f.prepare(), f.current()
                source = f.path.read_bytes()
                if change == "interval":
                    f.path.write_bytes(source[:f.start] + source[f.start:].replace(b"PRIVATE", b"CHANGED", 1))
                elif change == "truncate":
                    f.path.write_bytes(source[:-1])
                else:
                    replacement = f.path.with_suffix(".replacement")
                    replacement.write_bytes(source)
                    replacement.chmod(0o600)
                    os.replace(replacement, f.path)
                with self.assertRaises(ValueError):
                    f.apply(plan)
                self.assertEqual(f.current(), before)

    def test_changed_targeted_semantic_rows_refuse(self):
        for assignment, parameters in (("content=?", ("changed",)), ("expiresAt=?", (time.time() + 86400,)),
                                       ("deletedAt=?", (time.time(),)), ("modifiedAt=modifiedAt+1", ())):
            with self.subTest(assignment=assignment):
                f = self.fixture()
                plan, before = f.prepare(), f.current()
                f.update_row(assignment, parameters)
                changed_store = f.store.read_bytes()
                with self.assertRaises(ValueError):
                    f.apply(plan)
                self.assertEqual(f.current(), before)
                self.assertEqual(f.store.read_bytes(), changed_store)

    def test_changed_assessment_and_plan_pins_refuse(self):
        f = self.fixture()
        before = f.current()
        write_json(f.evidence / "legacy-reconciliation-assessment.json", {"reviewed": False, "changed": True})
        with self.assertRaises(ValueError):
            f.prepare()
        self.assertEqual(f.current(), before)
        f = self.fixture()
        plan, before = f.prepare(), f.current()
        altered = copy.deepcopy(plan)
        altered["next_state"]["offset"] += 1
        with self.assertRaises(ValueError):
            L.apply(f.paths, plan=altered, plan_sha256=f.pin(plan))
        with self.assertRaises(ValueError):
            f.apply(altered)
        self.assertEqual(f.current(), before)

    def test_incomplete_message_mapping_and_unexpired_intent_refuse(self):
        for change in ("missing-message", "unexpired"):
            with self.subTest(change=change):
                f = self.fixture()
                if change == "missing-message":
                    f.review["messages"].pop()
                else:
                    f.review["rows"][0]["expiresAt"] = time.time() + 86400
                    f.update_row("expiresAt=?", (f.review["rows"][0]["expiresAt"],))
                f.write_review()
                before = f.current()
                with self.assertRaises(ValueError):
                    f.prepare()
                self.assertEqual(f.current(), before)

    def test_selected_processing_or_v1_policy_refuses(self):
        for change in ("processing", "v1"):
            with self.subTest(change=change):
                f = self.fixture()
                if change == "processing":
                    write_json(f.record_path, {**f.record, "processing": "active-request"})
                else:
                    write_json(f.root / "admission.json", {**f.policy, "schema_version": 1, "mode": "host_sessions_v1"})
                before = f.current()
                with self.assertRaises(ValueError):
                    f.prepare()
                self.assertEqual(f.current(), before)

    def test_unsupported_pause_is_held(self):
        f = self.fixture()
        write_json(f.pending_path, {**f.request, "pause_reason": "manual_review_required"})
        before = f.current()
        with self.assertRaises(ValueError):
            f.prepare()
        self.assertEqual(f.current(), before)

    def test_unexplained_non_mcp_provider_tool_is_held_even_when_summary_says_false(self):
        f = self.fixture()
        events = [json.loads(raw) for raw in f.history["provider"].splitlines()]
        events.insert(-1, {"type": "item.completed", "item": {
            "id": "unexpected-shell", "type": "command_execution", "command": "never execute this", "exit_code": 0}})
        raw = b"".join(encode(event) for event in events)
        (f.run_dir / "provider.jsonl").write_bytes(raw)
        f.history["provider"] = raw
        f.review["history"]["provider"] = digest(raw)
        f.write_assessments()
        f.write_review()
        before = f.current()
        with self.assertRaises(ValueError):
            f.prepare()
        self.assertEqual(f.current(), before)

    def kill_at(self, fixture, plan, boundary):
        # CoreFoundation-based file identity must execute in a fresh interpreter
        # on macOS, not an os.fork child inheriting initialized native threads.
        plan_path = fixture.base / "crash-plan.json"
        write_json(plan_path, plan)
        child = HARNESS_POPEN([sys.executable, str(Path(__file__).with_name("legacy_crash_child.py")),
            str(plan_path), boundary, str(fixture.evidence)], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1", "TMPDIR": str(fixture.base)})
        try:
            stdout, stderr = child.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            child.kill()
            child.communicate()
            self.fail("SIGKILL fixture timed out")
        self.assertEqual(child.returncode, -signal.SIGKILL,
                         (stdout + stderr).decode(errors="replace") or "boundary was not reached: " + boundary)

    def test_sigkill_unindexed_or_partial_authority_never_advances(self):
        boundaries = ["legacy_plan_stage_created", "legacy_plan_stage_file_fsynced", "legacy_plan_installed",
                      "plan_durable", "journal_directory_fsynced", "ticket_file_fsynced", "index_created"]
        for boundary in boundaries:
            with self.subTest(boundary=boundary):
                f = self.fixture()
                plan, before, history, store = f.prepare(), f.current(), f.history_snapshot(), f.store.read_bytes()
                with self.no_external_effects(f):
                    self.kill_at(f, plan, boundary)
                    with self.assertRaises(ValueError):
                        f.recover(plan)
                self.assertEqual(f.current(), before)
                self.assertEqual(f.history_snapshot(), history)
                self.assertEqual(f.store.read_bytes(), store)

    def test_sigkill_indexed_publication_and_retirement_prefixes_recover_exactly(self):
        boundaries = ["index_file_fsynced", "admission_replaced", "state_replaced", "published_replaced",
            "legacy_publication_reference_installed", "publication_reference_durable", "ack_intent_stage_file_fsynced",
            "ack_intent_installed", "completion_stage_file_fsynced", "completion_installed", "before_retire",
            "active_unlinked", "active_directory_fsynced", "legacy_receipt_stage_file_fsynced",
            "legacy_receipt_installed", "receipt_durable"]
        for boundary in boundaries:
            with self.subTest(boundary=boundary):
                f = self.fixture()
                plan, history, store = f.prepare(), f.history_snapshot(), f.store.read_bytes()
                with self.no_external_effects(f):
                    self.kill_at(f, plan, boundary)
                    result = f.recover(plan)
                    self.completed(f, plan, result)
                    self.assertEqual(f.recover(plan), result)
                self.assertEqual(f.history_snapshot(), history)
                self.assertEqual(f.store.read_bytes(), store)

    def test_newer_pending_and_last_event_after_publication_survive_recovery(self):
        for boundary in ("published_directory_fsynced", "active_unlinked", "receipt_durable"):
            with self.subTest(boundary=boundary):
                f = self.fixture()
                plan = f.prepare()
                self.kill_at(f, plan, boundary)
                pending, admission = f.newer_pending()
                result = f.recover(plan)
                self.completed(f, plan, result, pending=pending)
                self.assertEqual(f.record_path.read_bytes(), admission)

    def test_same_id_tamper_before_and_after_completion_refuses(self):
        for completed in (False, True):
            with self.subTest(completed=completed):
                f = self.fixture()
                plan = f.prepare()
                if completed:
                    f.apply(plan)
                write_json(f.pending_path, {**f.request, "fixture_provenance": "tampered-same-request"})
                before = f.current()
                with self.assertRaises(ValueError):
                    f.recover(plan) if completed else f.apply(plan)
                self.assertEqual(f.current(), before)

    def test_retired_publication_without_retained_reference_refuses(self):
        f = self.fixture()
        plan = f.prepare()
        f.apply(plan)
        (f.root / "reconciliations" / plan["id"] / "publication-reference.json").unlink()
        before = f.current()
        with self.assertRaises(ValueError):
            f.recover(plan)
        self.assertEqual(f.current(), before)

    def test_forged_completed_queue_disposition_is_not_recovery_authority(self):
        for forgery in ("none", "target", "same-id-newer", "changed-original", "unadmitted-newer"):
            with self.subTest(forgery=forgery):
                f = self.fixture()
                plan = f.prepare()
                self.kill_at(f, plan, "before_retire")
                completion_path = f.root / "publications" / SID / "records" / plan["id"] / "completion.json"
                completion = json.loads(completion_path.read_bytes())
                if forgery in ("none", "target"):
                    completion.update(disposition=forgery, pending=None)
                elif forgery == "same-id-newer":
                    completion["disposition"] = "newer"
                else:
                    pending = json.loads(L.publication._raw(completion["pending"], old=True))
                    pending["fixture_provenance"] = "forged"
                    if forgery == "unadmitted-newer":
                        pending["request_id"] = "another-request"
                        pending["admission"] = {**pending["admission"], "activation_id": "31111111-2222-4333-8444-555555555555"}
                        completion["disposition"] = "newer"
                    raw = encode(pending)
                    identity = {**completion["pending"]["identity"], "size": len(raw)}
                    completion["pending"] = L.publication._image(raw, identity)
                write_json(completion_path, completion)
                before = f.current()
                with self.assertRaises(ValueError):
                    f.recover(plan)
                self.assertEqual(f.current(), before)
                self.assertFalse((f.root / "reconciliations" / plan["id"] / "receipt.json").exists())


    @contextlib.contextmanager
    def caller_locks(self, fixture):
        # Match the runner's existing worker -> enqueue ownership. A separately
        # held provider flock makes accidental reverse-order acquisition fail.
        held = L.durable.Locks(fixture.root)
        held.paths = [fixture.root / "worker.lock", fixture.root / "enqueue.lock"]
        with held:
            provider_fd = os.open(fixture.base / "learner-provider.lock", os.O_RDONLY | os.O_NOFOLLOW)
            try:
                fcntl.flock(provider_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                def verify():
                    held.verify()
                    return True
                with mock.patch.object(L.durable, "Locks", side_effect=AssertionError("adapter reacquired locks")):
                    yield verify
            finally:
                fcntl.flock(provider_fd, fcntl.LOCK_UN)
                os.close(provider_fd)

    def tree_snapshot(self, fixture):
        return {str(path.relative_to(fixture.root)): (path.read_bytes(), path.stat().st_mode)
                for path in fixture.root.rglob("*") if path.is_file()}

    def test_locked_adapter_recovers_active_prefix_without_provider_lock(self):
        for boundary in ("index_file_fsynced", "published_directory_fsynced"):
            with self.subTest(boundary=boundary):
                f = self.fixture()
                plan, history, store = f.prepare(), f.history_snapshot(), f.store.read_bytes()
                self.kill_at(f, plan, boundary)
                with self.no_external_effects(f), self.caller_locks(f) as verify:
                    result = L.recover_locked(f.paths, session_id=SID, verify_locks=verify)
                self.completed(f, plan, result)
                self.assertEqual(f.history_snapshot(), history)
                self.assertEqual(f.store.read_bytes(), store)

    def test_locked_adapter_recovers_retired_missing_receipt_and_keeps_newer_pending(self):
        f = self.fixture()
        plan, history, store = f.prepare(), f.history_snapshot(), f.store.read_bytes()
        self.kill_at(f, plan, "active_unlinked")
        work = f.root / "reconciliations" / plan["id"]
        self.assertFalse((work / "receipt.json").exists())
        newer_pending, newer_admission = f.newer_pending()
        with self.no_external_effects(f), self.caller_locks(f) as verify:
            result = L.recover_locked(f.paths, session_id=SID, verify_locks=verify)
        self.completed(f, plan, result, pending=newer_pending)
        self.assertEqual(f.record_path.read_bytes(), newer_admission)
        self.assertEqual(f.history_snapshot(), history)
        self.assertEqual(f.store.read_bytes(), store)

    def test_locked_adapter_authenticated_receipt_and_no_work_are_read_only_noops(self):
        for completed in (False, True):
            with self.subTest(completed=completed):
                f = self.fixture()
                if completed:
                    f.apply(f.prepare())
                before, store = self.tree_snapshot(f), f.store.read_bytes()
                with self.no_external_effects(f) as reads, self.caller_locks(f) as verify:
                    self.assertIsNone(L.recover_locked(f.paths, session_id=SID, verify_locks=verify))
                self.assertEqual(reads, [])
                self.assertEqual(self.tree_snapshot(f), before)
                self.assertEqual(f.store.read_bytes(), store)

    def test_locked_adapter_missing_nonexact_or_changed_guard_never_mutates(self):
        f = self.fixture()
        plan = f.prepare()
        self.kill_at(f, plan, "index_file_fsynced")
        def raises():
            raise RuntimeError("lost caller lock")
        for kind in ("missing", "none", "integer", "false", "raises", "changed"):
            with self.subTest(kind=kind), self.no_external_effects(f), self.caller_locks(f) as verify:
                checks = 0
                def changes():
                    nonlocal checks
                    checks += 1
                    return verify() if checks == 1 else False
                guard = {"missing": None, "none": lambda: None, "integer": lambda: 1,
                         "false": lambda: False, "raises": raises, "changed": changes}[kind]
                before = self.tree_snapshot(f)
                with self.assertRaises(ValueError):
                    L.recover_locked(f.paths, session_id=SID, verify_locks=guard)
                self.assertEqual(self.tree_snapshot(f), before)
                if kind == "changed":
                    self.assertEqual(checks, 2)

    def test_locked_adapter_replaced_owned_lock_refuses_without_mutation(self):
        f = self.fixture()
        plan = f.prepare()
        self.kill_at(f, plan, "index_file_fsynced")
        with self.no_external_effects(f), self.caller_locks(f) as verify:
            replacement = f.base / "replacement-worker.lock"
            replacement.write_bytes(b"")
            replacement.chmod(0o600)
            os.replace(replacement, f.root / "worker.lock")
            before = self.tree_snapshot(f)
            with self.assertRaises(ValueError):
                L.recover_locked(f.paths, session_id=SID, verify_locks=verify)
            self.assertEqual(self.tree_snapshot(f), before)

    def test_locked_adapter_forged_retired_reference_cannot_create_receipt(self):
        for forgery in ("ticket-digest", "missing-reference", "state-reference"):
            with self.subTest(forgery=forgery):
                f = self.fixture()
                plan = f.prepare()
                self.kill_at(f, plan, "active_unlinked")
                work = f.root / "reconciliations" / plan["id"]
                reference_path = work / "publication-reference.json"
                if forgery == "ticket-digest":
                    reference = json.loads(reference_path.read_bytes())
                    write_json(reference_path, {**reference, "ticket_sha256": "a" * 64})
                elif forgery == "missing-reference":
                    reference_path.unlink()
                else:
                    state = json.loads(f.state_path.read_bytes())
                    state["last_reconciliation"]["evidence_sha256"] = "b" * 64
                    write_json(f.state_path, state)
                before = self.tree_snapshot(f)
                with self.no_external_effects(f), self.caller_locks(f) as verify:
                    with self.assertRaises(ValueError):
                        L.recover_locked(f.paths, session_id=SID, verify_locks=verify)
                self.assertEqual(self.tree_snapshot(f), before)
                self.assertFalse((work / "receipt.json").exists())

    def test_locked_adapter_uses_sealed_evidence_after_import_directory_removed(self):
        f = self.fixture()
        plan, history, store = f.prepare(), f.history_snapshot(), f.store.read_bytes()
        self.kill_at(f, plan, "published_directory_fsynced")
        shutil.rmtree(f.evidence)
        self.assertFalse(f.evidence.exists())
        with self.no_external_effects(f), self.caller_locks(f) as verify:
            result = L.recover_locked(f.paths, session_id=SID, verify_locks=verify)
        self.completed(f, plan, result)
        self.assertFalse(f.evidence.exists())
        self.assertEqual(f.history_snapshot(), history)
        self.assertEqual(f.store.read_bytes(), store)



if __name__ == "__main__":
    unittest.main()
