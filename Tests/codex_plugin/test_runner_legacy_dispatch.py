"""Runner dispatch and bounded discovery; no live or provider activity."""
import importlib
import json
from pathlib import Path
import sys
import unittest
from unittest import mock

from legacy_fixture import LegacyFixture, load_runtime, SID, PLUGIN, write_json

L = load_runtime()
R = importlib.import_module("codex_learner.runner_publication")

class RunnerLegacyDispatchTests(unittest.TestCase):
    def fixture(self):
        fixture = LegacyFixture(L)
        self.addCleanup(fixture.close)
        return fixture

    def publications(self, fixture, **kwargs):
        return R.Publications(fixture.root, fixture.base / "config.json", PLUGIN, **kwargs)

    def interrupt(self, fixture, boundary):
        plan = fixture.prepare()
        def stop(label):
            if label == boundary:
                raise RuntimeError("fixture interruption")
        with mock.patch.object(L.coordinator, "_boundary", side_effect=stop):
            with self.assertRaises(ValueError):
                fixture.apply(plan)
        return plan

    def test_ordinary_path_is_lazy_and_needs_no_legacy_store(self):
        f = self.fixture()
        selector = mock.Mock(side_effect=AssertionError("legacy selector must stay lazy"))
        with mock.patch.object(L, "_rows", side_effect=AssertionError("no store")):
            self.assertFalse(L.needs_recovery(f.root, SID))
            self.assertIsNone(self.publications(f, legacy_paths=selector).recover(SID, {}))
        selector.assert_not_called()

    def test_missing_receipt_recovers_through_public_runner_and_preserves_newer_pending(self):
        f = self.fixture()
        self.interrupt(f, "active_directory_fsynced")
        self.assertTrue(L.needs_recovery(f.root, SID))
        pending, record = f.newer_pending()
        history, database = f.history_snapshot(), f.store.read_bytes()
        with L.durable.Locks(f.root) as held:
            def guard():
                held.verify()
                return True
            selector = mock.Mock(return_value=f.paths)
            result = self.publications(f, legacy_paths=selector, legacy_verify_locks=guard).recover(SID, {})
        self.assertIsInstance(result, R.Outcome)
        self.assertEqual(str(result), L.RESULT)
        self.assertEqual(result.request_id, f.request["request_id"])
        self.assertEqual(f.pending_path.read_bytes(), pending)
        self.assertEqual(f.record_path.read_bytes(), record)
        self.assertEqual(f.history_snapshot(), history)
        self.assertEqual(f.store.read_bytes(), database)
        self.assertFalse(L.needs_recovery(f.root, SID))
        selector.assert_called_once_with()

    def test_active_legacy_requires_explicit_trusted_paths_and_exact_lock_guard(self):
        f = self.fixture()
        self.interrupt(f, "before_retire")
        before = f.current()
        with self.assertRaisesRegex(ValueError, "legacy_trusted_paths_and_locks_required"):
            self.publications(f).recover(SID, {})
        for result in (False, 1, None):
            with self.subTest(result=result):
                with self.assertRaisesRegex(ValueError, "caller_locks_changed"):
                    self.publications(f, legacy_paths=lambda: f.paths,
                        legacy_verify_locks=lambda: result).recover(SID, {})
                self.assertEqual(f.current(), before)
        with L.durable.Locks(f.root) as held:
            def guard():
                held.verify()
                return True
            result = self.publications(f, legacy_paths=lambda: f.paths, legacy_verify_locks=guard).recover(SID, {})
        self.assertEqual(str(result), L.RESULT)

    def test_completed_discovery_reads_only_bounded_publication_metadata_and_skips_selector(self):
        f = self.fixture()
        plan = f.prepare()
        f.apply(plan)
        work = f.root / "reconciliations" / plan["id"]
        allowed = {f.state_path, work / "receipt.json", work / "publication-reference.json",
            f.root / "publications" / SID / "records" / plan["id"] / "completion.json"}
        original = L.durable._read
        seen = []
        def bounded(path, **kwargs):
            self.assertIn(path, allowed)
            self.assertLessEqual(kwargs.get("maximum", L.admission.MAX_BYTES), L.admission.MAX_BYTES)
            seen.append(path)
            return original(path, **kwargs)
        with mock.patch.object(L.durable, "_read", side_effect=bounded):
            self.assertFalse(L.needs_recovery(f.root, SID))
        self.assertEqual(set(seen), allowed)
        selector = mock.Mock(side_effect=AssertionError("completed must not resolve store"))
        with mock.patch.object(L, "read_completed", side_effect=AssertionError("no private history scan")), \
             mock.patch.object(L, "_rows", side_effect=AssertionError("no store")):
            self.assertIsNone(self.publications(f, legacy_paths=selector).recover(SID, {}))
        selector.assert_not_called()

    def test_missing_malformed_or_changed_metadata_stays_discoverable(self):
        f = self.fixture()
        plan = f.prepare()
        f.apply(plan)
        work = f.root / "reconciliations" / plan["id"]
        receipt = work / "receipt.json"
        completion = f.root / "publications" / SID / "records" / plan["id"] / "completion.json"
        original_receipt, original_completion = receipt.read_bytes(), completion.read_bytes()
        for changed in (b"", b"{", b"{\"version\":true}"):
            receipt.write_bytes(changed)
            self.assertTrue(L.needs_recovery(f.root, SID))
        receipt.write_bytes(original_receipt)
        changed = json.loads(original_receipt)
        changed["reference"]["evidence_sha256"] = "1" * 64
        write_json(receipt, changed)
        self.assertTrue(L.needs_recovery(f.root, SID))
        receipt.write_bytes(original_receipt)
        completion.write_bytes(original_completion + b" ")
        self.assertTrue(L.needs_recovery(f.root, SID))
        completion.write_bytes(original_completion)
        receipt.unlink()
        self.assertTrue(L.needs_recovery(f.root, SID))
        with self.assertRaisesRegex(ValueError, "legacy_trusted_paths_and_locks_required"):
            self.publications(f).recover(SID, {})

    def test_malformed_historical_run_reference_stays_discoverable(self):
        f = self.fixture()
        plan = f.prepare()
        f.apply(plan)
        receipt = f.root / "reconciliations" / plan["id"] / "receipt.json"
        state, recorded = json.loads(f.state_path.read_bytes()), json.loads(receipt.read_bytes())
        state["last_reconciliation"]["legacy_run_id"] = "not-a-run"
        recorded["reference"]["legacy_run_id"] = "not-a-run"
        write_json(f.state_path, state)
        write_json(receipt, recorded)
        self.assertTrue(L.needs_recovery(f.root, SID))

    def test_missing_or_null_reference_is_an_explicit_hold_without_fallthrough(self):
        for change in ({"status": L.RESULT}, {"last_reconciliation": None}):
            with self.subTest(change=change):
                f = self.fixture()
                write_json(f.state_path, {**f.state, **change})
                before = f.current()
                self.assertTrue(L.needs_recovery(f.root, SID))
                with L.durable.Locks(f.root) as held:
                    def guard():
                        held.verify()
                        return True
                    with mock.patch.object(R, "_record", side_effect=AssertionError("ordinary recovery fallthrough")), \
                         mock.patch("subprocess.Popen", side_effect=AssertionError("provider/native invocation")):
                        with self.assertRaisesRegex(ValueError, "missing_reconciliation_reference"):
                            self.publications(f, legacy_paths=lambda: f.paths,
                                legacy_verify_locks=guard).recover(SID, {})
                self.assertEqual(f.current(), before)

    def test_malformed_reference_cannot_select_an_arbitrary_path(self):
        f = self.fixture()
        write_json(f.state_path, {**f.state, "last_reconciliation": {"id": "../../outside"}})
        self.assertTrue(L.needs_recovery(f.root, SID))
        with self.assertRaisesRegex(ValueError, "legacy_trusted_paths_and_locks_required"):
            self.publications(f).recover(SID, {})


if __name__ == "__main__":
    unittest.main()
