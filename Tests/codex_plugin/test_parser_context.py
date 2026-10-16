"""Parser-only authority with private local fixtures and no external effects."""
import copy
from dataclasses import replace
import importlib
import os
from pathlib import Path
import unittest
from unittest import mock

import test_execution_context as fixtures

P = importlib.import_module("codex_learner.parser_context")
C, J, A, T = fixtures.C, fixtures.J, fixtures.A, fixtures.T
SID, write_json = fixtures.SID, fixtures.write_json


class ParserContextTests(unittest.TestCase):
    def setUp(self):
        # Composition avoids rerunning all execution-context tests here. This
        # fixture forbids process/socket/SQLite effects and is rooted in localdev.
        self.f = fixtures.ExecutionContextTests(methodName="runTest")
        self.f.setUp()
        self.addCleanup(self.f.doCleanups)
        self.f.fence.close()
        self.f.config_path.unlink()
        self.f.runtime.unlink()
        self.context = P.ParserContext(self.f.root, SID)

    def empty(self, records=()):
        with self.f.path.open("r+b") as stream:
            stream.truncate(self.f.frontier)
            stream.seek(self.f.frontier)
            for record in records:
                stream.write(J.encode(record) + b"\n")
        return self.excerpt()

    def excerpt(self, **changes):
        return T.read_excerpt(self.f.path, self.f.state["offset"], stable_identity=True,
                              **{**{"max_chars": 2000, "max_scan_bytes": 4096,
                                    "recent_messages": self.f.state["recent_messages"],
                                    "current_turn_id": self.f.state["current_turn_id"]}, **changes})

    def capture(self, excerpt=None, context=None, **changes):
        excerpt = self.excerpt() if excerpt is None else excerpt
        args = {"reason": "no_visible_content", "max_chars": 2000, "max_scan_bytes": 4096}
        return (context or self.context).capture(self.f.request, self.f.state, excerpt,
                                                C._next_parser(excerpt), **{**args, **changes})

    def excluded(self):
        return self.empty([
            {"type": "turn_context", "payload": {"turn_id": "next-fixture-turn"}},
            {"type": "event_msg", "payload": {"type": "agent_reasoning", "text": "PRIVATE excluded"}},
        ])

    def receipt(self, excerpt=None, **changes):
        excerpt = self.excerpt() if excerpt is None else excerpt
        source = {"identity": self.f.request["identity"], "start_offset": self.f.state["offset"],
                  "end_offset": excerpt.next_offset,
                  "interval_sha256": P._interval(self.f.path, self.f.request["identity"],
                                                  self.f.state["offset"], excerpt.next_offset),
                  "excerpt_sha256": J.sha256(excerpt.text.encode())}
        receipt = {"version": 1, "kind": "successful_interval_coverage", "status": "succeeded",
                   "session_id": SID, "run_id": "retained-success", "source": source,
                   "parser": {"runtime": C._parser_runtime(),
                              "limits": {"max_chars": 2000, "max_scan_bytes": 4096},
                              "input_sha256": J.sha256(J.encode(C._parser_state(self.f.state))),
                              "next_sha256": J.sha256(J.encode(C._next_parser(excerpt)))},
                   "execution_manifest_sha256": "a" * 64, "settlement_sha256": "b" * 64}
        receipt.update(changes)
        path = self.f.root / "runs" / "retained-success" / "successful-coverage.json"
        write_json(path, receipt)
        reference = {"version": 1, "run_id": "retained-success", "receipt_sha256": J.sha256(path.read_bytes())}
        return path, receipt, reference

    def authority(self, receipt, binding):
        # Synthetic settlement authority: production supplies the retained
        # settlement/native-journal validator rather than trusting these hashes.
        self.assertEqual(receipt["execution_manifest_sha256"], "a" * 64)
        self.assertEqual(receipt["settlement_sha256"], "b" * 64)
        self.assertEqual(binding["session_id"], SID)
        self.assertEqual(binding["admission"], self.f.request["admission"])
        self.assertEqual(binding["source"], receipt["source"])
        self.assertEqual(binding["parser"], receipt["parser"])
        return True

    def test_zero_length_eof_without_backend_and_later_append(self):
        excerpt = self.empty()
        before = {p: p.read_bytes() for p in (self.f.path, self.f.state_path, self.f.record_path)}
        evidence = self.capture(excerpt)
        self.assertEqual(evidence["source"]["start_offset"], self.f.frontier)
        self.assertEqual(evidence["source"]["end_offset"], self.f.frontier)
        self.assertEqual(evidence["source"]["interval_sha256"], J.sha256(b""))
        self.assertIs(self.context.validate_source(evidence, "before_ticket"), True)
        for path, raw in before.items():
            self.assertEqual(path.read_bytes(), raw)
        self.f.append("PRIVATE next turn must stay pending.")
        after = self.f.path.read_bytes()
        self.assertIs(self.context.validate_source(evidence, "recover_entry"), True)
        self.assertEqual(self.f.path.read_bytes(), after)
        self.assertEqual(self.f.state_path.read_bytes(), before[self.f.state_path])
        self.assertFalse((self.f.run_dir / "execution-manifest.json").exists())
        with self.assertRaises(C.ContextError):
            C._interval(self.f.path, self.f.request["identity"], self.f.frontier, self.f.frontier)

    def test_consumed_excluded_records_pin_exact_parser_output_without_plaintext(self):
        excerpt = self.excluded()
        evidence = self.capture(excerpt)
        self.assertGreater(evidence["source"]["end_offset"], self.f.frontier)
        self.assertEqual(J._json(J._unseal(evidence["inputs"]["next_parser_state"])), C._next_parser(excerpt))
        self.assertEqual(excerpt.current_turn_id, "next-fixture-turn")
        self.assertEqual(J._unseal(evidence["inputs"]["cursor"]), self.f.state_path.read_bytes())
        self.assertEqual(J._unseal(evidence["inputs"]["admission"]), self.f.record_path.read_bytes())
        self.assertNotIn("PRIVATE", J.encode(evidence).decode())
        self.assertNotIn("expected_scope", evidence)
        self.assertNotIn("writer_fence", evidence)
        self.assertIs(self.context.validate_source(evidence, "journal_replace_state"), True)

    def test_visible_and_blocked_excerpts_cannot_claim_no_visible_content(self):
        with self.assertRaisesRegex(P.ParserContextError, "visible_content_not_covered"):
            self.capture()
        for excerpt in (self.excerpt(max_chars=1), self.excerpt(max_scan_bytes=1)):
            with self.subTest(blocked=excerpt.blocked_reason), self.assertRaises(P.ParserContextError):
                self.capture(excerpt)
        self.empty()
        with self.f.path.open("ab") as stream:
            stream.write(b'{"private":')
        with self.assertRaises(P.ParserContextError):
            self.capture()

    def test_forged_empty_excerpt_before_visible_suffix_is_rejected_at_capture(self):
        excerpt = self.excerpt()
        empty = replace(excerpt, text="", next_offset=self.f.frontier,
                        recent_messages=[], current_turn_id=None, message_count=0)
        with self.assertRaisesRegex(P.ParserContextError, "original_excerpt_changed"):
            self.capture(empty)

    def test_source_edit_truncation_and_replacement_fail_closed(self):
        evidence = self.capture(self.excluded())
        original = self.f.path.read_bytes()
        for raw in (original.replace(b"PRIVATE", b"CHANGED"), original[:-1]):
            with self.subTest(size=len(raw)):
                self.f.path.write_bytes(raw)
                with self.assertRaises(P.ParserContextError):
                    self.context.validate_source(evidence, "before_ticket")
                self.f.path.write_bytes(original)
        replacement = self.f.path.with_suffix(".new")
        replacement.write_bytes(original)
        replacement.chmod(0o600)
        os.replace(replacement, self.f.path)
        with self.assertRaises(P.ParserContextError):
            self.context.validate_source(evidence, "before_ticket")

    def test_eof_incomplete_boundary_and_truncation_are_rejected(self):
        evidence = self.capture(self.empty())
        raw = self.f.path.read_bytes()
        self.f.path.write_bytes(raw[:-1] + b" ")
        with self.assertRaises(P.ParserContextError):
            self.context.validate_source(evidence, "recover_entry")
        self.f.path.write_bytes(raw[:-1])
        with self.assertRaises(P.ParserContextError):
            self.context.validate_source(evidence, "recover_entry")

    def test_parser_runtime_limits_input_and_expected_output_cannot_be_forged(self):
        evidence = self.capture(self.excluded())
        for item, mutate in [
            ("parser_state", lambda value: value["runtime"].update(sha256="0" * 64)),
            ("parser_state", lambda value: value["limits"].update(max_chars=True)),
            ("parser_state", lambda value: value["limits"].update(max_scan_bytes=1)),
            ("parser_state", lambda value: value["input"].update(current_turn_id="forged")),
            ("next_parser_state", lambda value: value.update(current_turn_id="forged")),
        ]:
            with self.subTest(item=item):
                changed = copy.deepcopy(evidence)
                value = J._json(J._unseal(changed["inputs"][item]))
                mutate(value)
                changed["inputs"][item] = J.seal_json(J.encode(value))
                with self.assertRaises(P.ParserContextError):
                    self.context.validate_source(changed, "before_ticket")
        with mock.patch.object(C, "_parser_runtime", return_value={"path": "changed", "sha256": "0" * 64}):
            with self.assertRaises(P.ParserContextError):
                self.context.validate_source(evidence, "recover_entry")

    def test_new_pending_and_mixed_target_pair_are_coordinator_owned(self):
        evidence = self.capture(self.excluded())
        pending = self.f.root / "pending" / (SID + ".json")
        write_json(pending, {**self.f.request, "request_id": "newer-request"})
        newer_admission = {**self.f.record, "last_event": "b" * 64, "state_sha256": "c" * 64}
        write_json(self.f.record_path, newer_admission)
        before = {p: p.read_bytes() for p in (pending, self.f.state_path, self.f.record_path)}
        # The journal qualifies old/new image pairs. Source checks deliberately
        # do not attempt admission's pair validator during a partial publication.
        self.assertIs(self.context.validate_source(evidence, "journal_replace_state"), True)
        for path, raw in before.items():
            self.assertEqual(path.read_bytes(), raw)

    def test_activation_enrollment_and_hold_changes_are_rechecked(self):
        evidence = self.capture(self.empty())
        for path, value in [
            (self.f.root / "admission.json", {**self.f.policy, "enabled": False}),
            (self.f.root / "admission.json", {**self.f.policy, "activation_id": fixtures.OWNER}),
            (self.f.enrollment, {**J._json(self.f.enrollment.read_bytes()), "frontier_offset": 0}),
        ]:
            with self.subTest(path=path.name):
                raw = path.read_bytes()
                write_json(path, value)
                with self.assertRaises(P.ParserContextError):
                    self.context.validate_source(evidence, "recover_entry")
                path.write_bytes(raw)
        write_json(self.f.root / "migration-holds" / (SID + ".json"), {})
        with self.assertRaises(P.ParserContextError):
            self.context.validate_source(evidence, "recover_entry")

    def test_capture_requires_original_pair_and_no_processing(self):
        excerpt = self.empty()
        for path, value in [
            (self.f.state_path, {**self.f.state, "status": "reconciliation_required"}),
            (self.f.record_path, {**self.f.record, "state_sha256": "0" * 64}),
            (self.f.record_path, {**self.f.record, "processing": "other-request"}),
            (self.f.record_path, {**self.f.record, "processing_execution": {"run_id": "other"}}),
        ]:
            with self.subTest(path=path.name):
                raw = path.read_bytes()
                write_json(path, value)
                with self.assertRaises(P.ParserContextError):
                    self.capture(excerpt)
                path.write_bytes(raw)

    def test_selected_task_root_phase_and_strict_json_validation(self):
        evidence = self.capture(self.empty())
        for change in ({"session_id": "019b7a00-0000-7123-8000-000000000099"},
                       {"version": True}, {"reason": "unknown"}, {"unknown": "PRIVATE"}):
            with self.subTest(change=list(change)), self.assertRaises(P.ParserContextError):
                self.context.validate_source({**evidence, **change}, "before_ticket")
        for phase in (None, "../private", "PRIVATE\ntext"):
            with self.assertRaises(P.ParserContextError) as raised:
                self.context.validate_source(evidence, phase)
            self.assertNotIn("PRIVATE", str(raised.exception))
        alias = self.f.base / "root-alias"
        alias.symlink_to(self.f.root, target_is_directory=True)
        with self.assertRaises(P.ParserContextError):
            P.ParserContext(alias, SID)

    def test_matching_legacy_text_hash_is_never_coverage(self):
        self.f.state["last_excerpt_sha256"] = J.sha256(self.excerpt().text.encode())
        write_json(self.f.state_path, self.f.state)
        write_json(self.f.record_path, {**self.f.record, "state_sha256": C.durable.object_digest(self.f.state)})
        with self.assertRaisesRegex(P.ParserContextError, "duplicate_coverage_required"):
            self.capture(reason="duplicate")

    def test_exact_retained_receipt_and_trusted_authority_are_required_on_every_validation(self):
        path, receipt, reference = self.receipt()
        verifier = mock.Mock(side_effect=self.authority)
        context = P.ParserContext(self.f.root, SID, verify_coverage=verifier)
        evidence = self.capture(context=context, reason="duplicate", coverage=reference)
        self.assertEqual(verifier.call_count, 1)
        self.assertIs(context.validate_source(evidence, "recover_entry"), True)
        self.assertEqual(verifier.call_count, 2)
        self.assertEqual(path.read_bytes(), J.encode(receipt) + b"\n")
        with self.assertRaisesRegex(P.ParserContextError, "duplicate_coverage_required"):
            P.ParserContext(self.f.root, SID).validate_source(evidence, "recover_entry")
        for result in (False, None, 1):
            with self.subTest(result=result), self.assertRaisesRegex(P.ParserContextError, "coverage_unverified"):
                P.ParserContext(self.f.root, SID, verify_coverage=lambda *args: result).validate_source(evidence, "recover_entry")

    def test_same_text_different_interval_or_parser_is_not_coverage(self):
        _, original, _ = self.receipt()
        mutations = [
            lambda value: value["source"].update(start_offset=self.f.frontier + 1),
            lambda value: value["source"].update(interval_sha256="0" * 64),
            lambda value: value["parser"].update(input_sha256="0" * 64),
            lambda value: value["parser"].update(next_sha256="0" * 64),
            lambda value: value["parser"]["runtime"].update(sha256="0" * 64),
        ]
        verifier = mock.Mock(return_value=True)
        context = P.ParserContext(self.f.root, SID, verify_coverage=verifier)
        for mutate in mutations:
            changed = copy.deepcopy(original)
            mutate(changed)
            _, _, reference = self.receipt(**changed)
            with self.assertRaisesRegex(P.ParserContextError, "coverage_interval_mismatch"):
                self.capture(context=context, reason="duplicate", coverage=reference)
        verifier.assert_not_called()

    def test_unsafe_missing_malformed_or_untrusted_receipts_never_gain_authority(self):
        path, receipt, reference = self.receipt()
        original = path.read_bytes()
        context = P.ParserContext(self.f.root, SID, verify_coverage=self.authority)
        for raw in (b'{"version":1,', b'{"version":1,"version":1}', b"{}", b"x" * (A.MAX_BYTES + 1)):
            path.write_bytes(raw)
            candidate = {**reference, "receipt_sha256": J.sha256(raw)}
            with self.subTest(size=len(raw)), self.assertRaises(P.ParserContextError):
                self.capture(context=context, reason="duplicate", coverage=candidate)
        path.write_bytes(original)
        for changes in ({"run_id": "../retained-success"}, {"receipt_sha256": "0" * 64}, {"version": True}):
            with self.assertRaises(P.ParserContextError):
                self.capture(context=context, reason="duplicate", coverage={**reference, **changes})
        for changes in ({"status": "failed"}, {"session_id": "other"}, {"settlement_sha256": "invalid"}):
            _, _, altered = self.receipt(**changes)
            with self.assertRaises(P.ParserContextError):
                self.capture(context=context, reason="duplicate", coverage=altered)
        path.write_bytes(original)
        path.chmod(0o644)
        with self.assertRaises(P.ParserContextError):
            self.capture(context=context, reason="duplicate", coverage=reference)
        path.chmod(0o600)
        alternate = path.with_name("private-original.json")
        path.rename(alternate)
        path.symlink_to(alternate)
        with self.assertRaises(P.ParserContextError):
            self.capture(context=context, reason="duplicate", coverage=reference)
        path.unlink()
        with self.assertRaises(P.ParserContextError):
            self.capture(context=context, reason="duplicate", coverage=reference)

    def test_callback_receives_copies_and_receipt_replacement_is_detected(self):
        path, receipt, reference = self.receipt()
        def safe(received, binding):
            self.authority(received, binding)
            received["source"]["end_offset"] = 0
            binding["source"]["identity"]["inode"] = 0
            binding["admission"]["activation_id"] = "changed"
            return True
        context = P.ParserContext(self.f.root, SID, verify_coverage=safe)
        evidence = self.capture(context=context, reason="duplicate", coverage=reference)
        self.assertEqual(evidence["source"], receipt["source"])
        self.assertIs(context.validate_source(evidence, "recover_entry"), True)
        def replace_receipt(*args):
            replacement = path.with_name("replacement.json")
            replacement.write_bytes(path.read_bytes())
            replacement.chmod(0o600)
            os.replace(replacement, path)
            return True
        changed = P.ParserContext(self.f.root, SID, verify_coverage=replace_receipt)
        with self.assertRaisesRegex(P.ParserContextError, "coverage_changed"):
            changed.validate_source(evidence, "recover_entry")


if __name__ == "__main__":
    unittest.main()
