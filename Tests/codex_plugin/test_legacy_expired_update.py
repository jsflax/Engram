"""Synthetic-only replacement UPDATE acceptance and fail-closed review tests."""
import copy
import datetime as dt
import json
from unittest import mock

import test_legacy_acceptance as acceptance
from expired_update_fixture import ExpiredUpdateFixture
from legacy_fixture import SID, SUCCESS_ID, DUPLICATE_ID, encode, digest, write_json

L = acceptance.L


class ExpiredUpdateAcceptanceTests(acceptance.LegacyAcceptanceTests):
    """Run the existing publication/CAS/crash contract through the new profile."""

    def fixture(self):
        value = ExpiredUpdateFixture(L)
        self.addCleanup(value.close)
        return value

    def refused(self, fixture, *, reason=None):
        before, history, database = fixture.current(), fixture.history_snapshot(), fixture.store.read_bytes()
        with self.no_external_effects(fixture):
            manager = self.assertRaisesRegex(ValueError, reason) if reason else self.assertRaises(ValueError)
            with manager:
                fixture.prepare()
        self.assertEqual(fixture.current(), before)
        self.assertEqual(fixture.history_snapshot(), history)
        self.assertEqual(fixture.store.read_bytes(), database)
        self.assertFalse((fixture.root / "reconciliations").exists())

    def test_one_old_row_thirteen_messages_and_proposal_attribution_accept(self):
        f = self.fixture()
        self.assertEqual(len(f.review["rows"]), 1)
        self.assertEqual(len(f.review["messages"]), 13)
        self.assertLess(f.review["rows"][0]["createdAt"], dt.datetime.fromisoformat(f.run_started.replace("Z", "+00:00")).timestamp())
        proposals = [c for m in f.review["messages"] for c in m["clauses"]
                     if c["attribution"] == "assistant_plan_or_proposal"]
        self.assertTrue(any(c["disposition"] == "expired_no_write_remember" for c in proposals))
        before, history, database = f.current(), f.history_snapshot(), f.store.read_bytes()
        with self.no_external_effects(f) as reads:
            plan = f.prepare()
            self.assertIn("legacy_expired_update.py", plan["runtime"])
            self.assertIn("execution_manifest.py", plan["runtime"])
            self.assertEqual(f.current(), before)
            result = f.apply(plan)
            self.completed(f, plan, result)
            self.assertEqual(f.recover(plan), result)
            self.assertEqual(f.apply(plan), result)
            self.assertGreater(len(reads), 0)
        self.assertEqual(f.history_snapshot(), history)
        self.assertEqual(f.store.read_bytes(), database)

    def test_changed_assessment_and_plan_pins_refuse(self):
        # The inherited case names the old profile's assessment; use this
        # profile's artifact while preserving its stale-pin and plan checks.
        f = self.fixture()
        write_json(f.evidence / "expired-update-coverage.json", {"changed": True})
        self.refused(f)
        f = self.fixture()
        plan, before = f.prepare(), f.current()
        altered = copy.deepcopy(plan)
        altered["next_state"]["offset"] += 1
        with self.no_external_effects(f):
            with self.assertRaises(ValueError):
                L.apply(f.paths, plan=altered, plan_sha256=f.pin(plan))
            with self.assertRaises(ValueError):
                f.apply(altered)
        self.assertEqual(f.current(), before)

    def test_update_arguments_refuse_after_all_links_are_rehashed(self):
        changes = [lambda a: a.update(id=DUPLICATE_ID), lambda a: a.update(content="PRIVATE different synthetic content"),
            lambda a: a.update(source="codex-session:another-session"), lambda a: a.update(expires_in_days=True),
            lambda a: a.update(expires_in_days=0), lambda a: a.update(expires_in_days=7),
            lambda a: a.update(expires_in_days="14"), lambda a: a.update(project="unsupported"),
            lambda a: a.update(restore=True), lambda a: a.pop("source")]
        for index, change in enumerate(changes):
            with self.subTest(case=index):
                f = self.fixture()
                change(f.update_args)
                f.rebuild_history()
                self.refused(f)

    def test_remember_arguments_refuse_after_all_links_are_rehashed(self):
        changes = [lambda a: a.update(force=True), lambda a: a.update(is_private=False),
            lambda a: a.update(expires_in_days=True), lambda a: a.update(expires_in_days=0),
            lambda a: a.update(expires_in_days=15), lambda a: a.update(source="different-provenance"),
            lambda a: a.update(id=SUCCESS_ID), lambda a: a.pop("content")]
        for index, change in enumerate(changes):
            with self.subTest(case=index):
                f = self.fixture()
                change(f.remember_args)
                f.rebuild_history()
                self.refused(f)

    def test_native_update_acknowledgement_is_not_a_prefix_or_audit_only_claim(self):
        for case in ("missing", "wrong-id", "prefix-only", "extra-text", "structured", "isError", "wrong-source", "permanent", "extra-change"):
            with self.subTest(case=case):
                f = self.fixture()
                text = f.update_result["content"][0]["text"]
                if case == "missing":
                    f.update_result["content"] = []
                elif case == "wrong-id":
                    f.update_result["content"][0]["text"] = text.replace(SUCCESS_ID.upper(), DUPLICATE_ID.upper())
                elif case == "prefix-only":
                    f.update_result["content"][0]["text"] = text.split("\n", 1)[0]
                elif case == "extra-text":
                    f.update_result["content"].append({"type": "text", "text": "contradictory synthetic result"})
                elif case == "structured":
                    f.update_result["structured_content"] = {"stored": False}
                elif case == "isError":
                    f.update_result["isError"] = True
                elif case == "wrong-source":
                    f.update_result["content"][0]["text"] = text.replace(" → codex-session:" + SID, " → unrelated-source")
                elif case == "permanent":
                    f.update_result["content"][0]["text"] = text.replace("Jan 17, 2026", "permanent")
                else:
                    f.update_result["content"][0]["text"] += "\nproject: old → new"
                f.rebuild_history()
                self.refused(f)

    def test_failed_begin_receipt_is_authoritative_and_exact(self):
        for case in ("absent", "version-bool", "version-new", "ids", "uncertain", "began", "reason", "extra", "wrong-text", "isError"):
            with self.subTest(case=case):
                f = self.fixture()
                receipt = f.remember_result["structured_content"]["engram_write_receipt"]
                if case == "absent":
                    f.remember_result["structured_content"] = None
                elif case == "version-bool":
                    receipt["schema_version"] = True
                elif case == "version-new":
                    receipt["schema_version"] = 2
                elif case == "ids":
                    receipt["memory_ids"] = [SUCCESS_ID]
                elif case == "uncertain":
                    receipt["write_outcome"] = "unknown"
                elif case == "began":
                    receipt["write_outcome"] = "rolled_back_after_transaction_started"
                elif case == "reason":
                    receipt["reason"] = "other_error"
                elif case == "extra":
                    receipt["transaction_started"] = False
                elif case == "wrong-text":
                    f.remember_result["content"][0]["text"] = "Uncertain synthetic database error"
                else:
                    f.remember_result["isError"] = False
                f.rebuild_history()
                self.refused(f)

    def test_provider_and_audit_contradictions_refuse_with_fresh_hashes(self):
        for case in ("update-status", "update-error", "remember-status", "extra-finish", "success-id", "failure-id", "failure-ok", "audit-version-bool"):
            with self.subTest(case=case):
                f = self.fixture()
                if case == "update-status":
                    f.update_finish_override["status"] = "failed"
                elif case == "update-error":
                    f.update_finish_override["error"] = {"message": "synthetic error"}
                elif case == "remember-status":
                    f.remember_finish_override["status"] = "completed"
                elif case == "extra-finish":
                    f.update_finish_override["unretained_success_flag"] = True
                elif case == "success-id":
                    f.audit_success_override["memory_ids"] = [DUPLICATE_ID]
                elif case == "failure-id":
                    f.audit_failure_override["memory_ids"] = [SUCCESS_ID]
                elif case == "failure-ok":
                    f.audit_failure_override["ok"] = True
                else:
                    f.audit_failure_override["write_outcome_version"] = True
                f.rebuild_history()
                self.refused(f)

    def test_row_provenance_and_temporal_bounds_refuse_after_report_repin(self):
        for field, value in (("source", "unrelated source"), ("content", "PRIVATE different replacement"),
                ("modifiedAt", 1.0), ("expiresAt", 1.0), ("deletedAt", 1767429190.0)):
            with self.subTest(field=field):
                f = self.fixture()
                f.change_row_and_repin(field, value)
                self.refused(f)
        for delta in (86400, 90 * 86400):
            with self.subTest(renewal_seconds=delta):
                f = self.fixture()
                f.change_row_and_repin("expiresAt", f.row_values[0]["expiresAt"] + delta)
                self.refused(f)

    def test_original_horizon_must_have_elapsed(self):
        f = self.fixture()
        now = dt.datetime.now(dt.timezone.utc)
        f.run_started = (now - dt.timedelta(seconds=10)).isoformat()
        f.run_ended = now.isoformat()
        modified = (now - dt.timedelta(seconds=5)).timestamp()
        f.change_row_and_repin("modifiedAt", modified)
        f.change_row_and_repin("expiresAt", modified + 14 * 86400)
        f.rebuild_history()
        self.refused(f)

    def test_update_clock_instants_may_be_distinct_within_original_window(self):
        f = self.fixture()
        f.change_row_and_repin("expiresAt", f.row_values[0]["expiresAt"] + 0.000001)
        with self.no_external_effects(f):
            plan = f.prepare()
        self.assertEqual(L._json(L._raw(plan["review"]))["rows"], f.review["rows"])

    def test_extra_review_row_is_not_silently_accepted(self):
        f = self.fixture()
        other = {**f.review["rows"][0], "globalId": DUPLICATE_ID}
        f.review["rows"].append(other)
        f.refresh_review()
        self.refused(f)

    def test_thirteen_message_record_and_body_coverage_is_exact(self):
        for case in ("missing", "extra", "duplicate-index", "record-offset", "record-hash", "body-hash", "chunk-hash", "role", "unmatched-id"):
            with self.subTest(case=case):
                f = self.fixture()
                message = f.review["messages"][0]
                if case == "missing":
                    f.review["messages"].pop()
                elif case == "extra":
                    f.review["messages"].append(copy.deepcopy(message))
                elif case == "duplicate-index":
                    f.review["messages"][1]["index"] = 1
                elif case == "record-offset":
                    message["record"]["start_offset"] += 1
                elif case == "record-hash":
                    message["record"]["sha256"] = "a" * 64
                elif case == "body-hash":
                    message["body"]["sha256"] = "b" * 64
                elif case == "chunk-hash":
                    message["sha256"] = "c" * 64
                elif case == "role":
                    message["role"] = "user"
                else:
                    message["memory_ids"] = [DUPLICATE_ID]
                f.refresh_review()
                self.refused(f)

    def test_every_sentence_and_clause_is_covered_and_attributed(self):
        for case in ("missing-sentence", "missing-clause", "clause-gap", "clause-overlap", "duplicate-id", "clause-hash", "unknown-disposition", "empty-reason", "proposal-as-fact", "limitation-as-fact"):
            with self.subTest(case=case):
                f = self.fixture()
                message = f.review["messages"][0]
                clause = message["clauses"][0]
                if case == "missing-sentence":
                    message["sentences"].pop()
                elif case == "missing-clause":
                    message["clauses"].pop()
                elif case == "clause-gap":
                    clause["start"] += 1
                    clause["sha256"] = digest(f.messages[0][clause["start"]:clause["end"]].encode())
                elif case == "clause-overlap":
                    duplicate = {**clause, "id": "OVERLAPPING_CLAUSE"}
                    message["clauses"].insert(1, duplicate)
                elif case == "duplicate-id":
                    message["clauses"][1]["id"] = clause["id"]
                elif case == "clause-hash":
                    clause["sha256"] = "d" * 64
                elif case == "unknown-disposition":
                    clause["disposition"] = "permanent_new_fact"
                elif case == "empty-reason":
                    clause["rationale"] = ""
                elif case == "proposal-as-fact":
                    clause["attribution"] = "assistant_plan_or_proposal"
                else:
                    clause["attribution"] = "task_scoped_limitation"
                f.refresh_review()
                self.refused(f)

    def test_semantic_report_claims_fail_even_with_relinked_independent_digest(self):
        for key, value in (("additional_eligible_operations", 1), ("unresolved_observations", 1),
                           ("semantic_review_complete", False), ("proposal", "renew_and_retry")):
            with self.subTest(key=key):
                f = self.fixture()
                f.rewrite_report("expired-update-coverage.json", lambda report: report["conclusion"].update({key: value}))
                self.refused(f)
        for key, value in (("decision", "pending"), ("message_count", 12), ("clause_count", 1),
                           ("source_anchors_verified", False), ("coverage_sha256", "a" * 64)):
            with self.subTest(independent_key=key):
                f = self.fixture()
                f.rewrite_report("expired-update-independent-review.json", lambda report: report.update({key: value}))
                self.refused(f)

    def test_diagnostic_report_cannot_hide_structural_uncertainty(self):
        for field in ("malformed_records", "inherited_records", "duplicate_messages", "redacted_messages", "excluded_records"):
            with self.subTest(field=field):
                f = self.fixture()
                def change(report):
                    report["parser_diagnostics"][field] = 1
                    if field == "excluded_records":
                        report["record_count"] = 14
                f.rewrite_report("expired-update-coverage.json", change)
                self.refused(f, reason="structural_coverage_changed" if field == "excluded_records" else None)

    def test_extra_native_mutation_is_not_hidden_by_complete_review(self):
        f = self.fixture()
        provider = [json.loads(line) for line in f.history["provider"].splitlines()]
        pair = copy.deepcopy(provider[4:6])
        for event in pair:
            event["item"]["id"] = "extra-mutation"
        provider[-1:-1] = pair
        audit = [json.loads(line) for line in f.history["audit"].splitlines()]
        pair = copy.deepcopy(audit[3:5])
        for event in pair:
            event["id"] = 4
        audit[-1:-1] = pair
        run = json.loads(f.history["run"])
        run.update(tool_calls=4, write_calls=2)
        f.history.update(provider=b"".join(encode(e) for e in provider),
                         audit=b"".join(encode(e) for e in audit), run=encode(run))
        f.sync_history()
        self.refused(f)

    def test_exact_source_and_runtime_pins_remain_apply_fences(self):
        f = self.fixture()
        plan, before = f.prepare(), f.current()
        changed = copy.deepcopy(plan["runtime"])
        first = next(iter(changed))
        changed[first]["sha256"] = "0" * 64
        with self.no_external_effects(f), mock.patch.object(L, "_runtime", return_value=changed):
            with self.assertRaises(ValueError):
                f.apply(plan)
        self.assertEqual(f.current(), before)

    def reconciliation_pause(self, fixture):
        fixture.request = {**fixture.request, "pause_reason": "reconciliation_required"}
        write_json(fixture.pending_path, fixture.request)
        return fixture.pending_path.read_bytes()

    def assert_reconciliation_result(self, fixture, plan, result, pending):
        state = json.loads(fixture.state_path.read_bytes())
        record = json.loads(fixture.record_path.read_bytes())
        self.assertEqual(state, plan["next_state"])
        self.assertEqual(state["offset"], fixture.end)
        self.assertEqual(state["admission"]["frontier_offset"], fixture.frontier)
        self.assertNotIn("reconciliation_required", state)
        self.assertEqual(state["status"], "legacy_reconciled_no_new_mutation")
        self.assertEqual(record["state_sha256"], L.durable.object_digest(state))
        self.assertIsNone(record["processing"])
        self.assertEqual(fixture.pending_path.read_bytes(), pending)
        self.assertEqual(result["native_mutations_performed"], 0)
        self.assertIs(result["historical_execution_sealed"], False)
        self.assertFalse((fixture.root / "publications" / SID / "active.json").exists())

    def test_reconciliation_pause_prepare_apply_recover_preserves_exact_request(self):
        f = self.fixture()
        pending = self.reconciliation_pause(f)
        before, history, database = f.current(), f.history_snapshot(), f.store.read_bytes()
        with self.no_external_effects(f):
            plan = f.prepare()
            self.assertEqual(f.current(), before)
            result = f.apply(plan)
            self.assert_reconciliation_result(f, plan, result, pending)
            self.assertEqual(f.recover(plan), result)
            self.assertEqual(f.apply(plan), result)
        self.assertEqual(f.history_snapshot(), history)
        self.assertEqual(f.store.read_bytes(), database)

    def test_reconciliation_pause_sigkill_recovers_publication_and_retirement(self):
        for boundary in ("admission_replaced", "before_retire"):
            with self.subTest(boundary=boundary):
                f = self.fixture()
                pending = self.reconciliation_pause(f)
                plan, history, database = f.prepare(), f.history_snapshot(), f.store.read_bytes()
                with self.no_external_effects(f):
                    self.kill_at(f, plan, boundary)
                    result = f.recover(plan)
                    self.assert_reconciliation_result(f, plan, result, pending)
                    self.assertEqual(f.recover(plan), result)
                self.assertEqual(f.history_snapshot(), history)
                self.assertEqual(f.store.read_bytes(), database)

    def test_reconciliation_pause_unknown_or_mismatched_request_refuses_prepare(self):
        for change in ({"pause_reason": "manual_review_required"},
                       {"paused_request_id": "different-request"},
                       {"paused_request_id": None}, {"pause_reason": None}):
            with self.subTest(change=change):
                f = self.fixture()
                self.reconciliation_pause(f)
                write_json(f.pending_path, {**f.request, **change})
                self.refused(f, reason="unsupported_pending_pause")

    def test_reconciliation_pause_changes_cannot_bypass_apply_or_crash_recovery(self):
        for boundary in (None, "before_retire"):
            for change in ({"pause_reason": "manual_review_required"},
                           {"paused_request_id": "different-request"},
                           {"pause_reason": "batch_limit"}):
                with self.subTest(boundary=boundary, change=change):
                    f = self.fixture()
                    self.reconciliation_pause(f)
                    plan, history, database = f.prepare(), f.history_snapshot(), f.store.read_bytes()
                    with self.no_external_effects(f):
                        if boundary:
                            self.kill_at(f, plan, boundary)
                        write_json(f.pending_path, {**f.request, **change})
                        before = f.current()
                        with self.assertRaises(ValueError):
                            f.recover(plan) if boundary else f.apply(plan)
                        self.assertEqual(f.current(), before)
                    self.assertEqual(f.history_snapshot(), history)
                    self.assertEqual(f.store.read_bytes(), database)


if __name__ == "__main__":
    import unittest
    unittest.main()
