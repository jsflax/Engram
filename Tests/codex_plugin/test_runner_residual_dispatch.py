"""Worker adapter authority and routing; residual transaction tests live separately."""
import importlib
from dataclasses import replace
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

from suite_support import PLUGIN_ROOT
sys.path.insert(0, str(PLUGIN_ROOT / "scripts"))
R = importlib.import_module("codex_learner.runner")
P = importlib.import_module("codex_learner.residual_publication")
C = importlib.import_module("codex_learner.residual_context")
Q = R.runner_publication
SID = "019b7a00-0000-7123-8000-000000000021"
RUN = "20261016T210000Z-" + "a" * 32
REQUEST = "b" * 32


class RunnerResidualDispatchTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="residual-worker-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.config = self.root / "config.toml"
        self.config.write_text("")
        self.paths = C.ResidualPaths(self.root, self.root / "runs" / RUN,
                                    self.config, PLUGIN_ROOT, self.root / "store.sqlite")
        self.selector = mock.Mock(return_value=self.paths)
        self.guard = mock.Mock(return_value=True)
        self.service = Q.Publications(self.root, self.config, PLUGIN_ROOT,
            residual_paths=self.selector, residual_verify_locks=self.guard)
        self.reference = {"run_id": RUN}
        self.receipt = {"publication": {"ticket_id": "ticket", "ticket_sha256": "pin"}, "request_id": REQUEST}
        self.patch(Q.coordinator, "_active", return_value=None)
        self.discovery = self.patch(P, "needs_recovery", return_value=True)
        self.reference_read = self.patch(P, "recovery_reference", return_value=self.reference)
        self.recover = self.patch(P, "recover_locked", return_value=self.receipt)
        self.completed = self.patch(Q.coordinator, "read_completed", return_value={"ticket": {"request_id": REQUEST}})
        self.patch(Q, "_record", side_effect=AssertionError("ordinary recovery fallthrough"))
        self.patch(Q.legacy_reconciliation, "recover_locked", side_effect=AssertionError("legacy fallthrough"))
        self.patch("subprocess", "Popen", side_effect=AssertionError("provider/native invocation"))

    def patch(self, target, name, **kwargs):
        if isinstance(target, str):
            target = importlib.import_module(target)
        patcher = mock.patch.object(target, name, **kwargs)
        result = patcher.start()
        self.addCleanup(patcher.stop)
        return result

    def test_retired_missing_receipt_routes_status_only_and_uses_original_request(self):
        result = self.service.recover(SID, {})
        self.assertIsInstance(result, Q.Outcome)
        self.assertEqual(str(result), P.RESULT)
        self.assertEqual(result.request_id, REQUEST)
        self.selector.assert_called_once_with(RUN)
        self.recover.assert_called_once_with(self.paths, session_id=SID,
            verify_locks=self.guard, allow_continuation=False)

    def test_active_residual_routes_before_ordinary_execution(self):
        for result in ("processing", P.RESULT):
            with self.subTest(result=result):
                Q.coordinator._active.return_value = ({"input_evidence": {"kind": P.KIND},
                                                        "outcome": {"result": result}}, None)
                self.assertEqual(self.service.recover(SID, {}), P.RESULT)
        self.discovery.assert_not_called()

    def test_selected_noop_cannot_fall_through_to_stale_active_ticket(self):
        Q.coordinator._active.return_value = ({"input_evidence": {"kind": P.KIND}}, None)
        self.recover.return_value = None
        self.assertIsNone(self.service.recover(SID, {}))
        self.completed.assert_not_called()

    def test_missing_or_changed_reference_holds_before_path_selection(self):
        self.reference_read.return_value = None
        with self.assertRaisesRegex(ValueError, "residual_reference_missing"):
            self.service.recover(SID, {})
        self.reference_read.side_effect = ValueError("residual_publication_missing_reference")
        with self.assertRaisesRegex(ValueError, "missing_reference"):
            self.service.recover(SID, {})
        self.selector.assert_not_called()
        self.recover.assert_not_called()

    def test_current_paths_and_exact_lock_guard_are_required(self):
        for field, value in (("root", self.root / "other"), ("run_dir", self.root / "outside"),
                             ("plugin_root", self.root), ("config_path", self.root / "other.toml")):
            with self.subTest(field=field):
                self.selector.return_value = replace(self.paths, **{field: value})
                with self.assertRaisesRegex(ValueError, "residual_paths_changed"):
                    self.service.recover(SID, {})
        self.selector.return_value = self.paths
        for guard in (False, 1, None):
            with self.subTest(guard=guard):
                self.guard.return_value = guard
                with self.assertRaisesRegex(ValueError, "residual_caller_locks_changed"):
                    self.service.recover(SID, {})
        self.recover.assert_not_called()

    def test_missing_trusted_callbacks_or_changed_request_are_held(self):
        with self.assertRaisesRegex(ValueError, "residual_trusted_paths_and_locks_required"):
            Q.Publications(self.root, self.config, PLUGIN_ROOT).recover(SID, {})
        self.completed.return_value = {"ticket": {"request_id": "c" * 32}}
        with self.assertRaisesRegex(ValueError, "residual_request_changed"):
            self.service.recover(SID, {})

    def test_ordinary_recovery_does_not_resolve_store_or_residual_context(self):
        self.discovery.return_value = False
        with mock.patch.object(Q.legacy_reconciliation, "needs_recovery", return_value=False), \
             mock.patch.object(Q, "_record", return_value=(b"{}", {"processing": None}, None)):
            self.assertIsNone(self.service.recover(SID, {}))
        self.selector.assert_not_called()
        self.reference_read.assert_not_called()
        self.recover.assert_not_called()

    def test_malformed_admission_cannot_hide_residual_discovery(self):
        path = self.root / "admissions" / (SID + ".json")
        path.parent.mkdir(mode=0o700)
        path.write_bytes(b"{")
        with mock.patch.object(Q.legacy_reconciliation, "needs_recovery", return_value=False):
            self.assertIs(R.has_recoverable_transition(self.root, SID), True)
        self.discovery.assert_called_once_with(self.root, SID)
        self.assertEqual(path.read_bytes(), b"{")

    def test_run_path_uses_current_store_route_and_rejects_traversal_first(self):
        selected = mock.Mock(package_root=PLUGIN_ROOT, candidate_store=self.paths.candidate_store)
        with mock.patch.object(R, "legacy_paths", return_value=selected) as route:
            actual = R.residual_paths(self.root, RUN)
            self.assertEqual(actual.run_dir, self.paths.run_dir)
            self.assertEqual(actual.candidate_store, self.paths.candidate_store)
            self.assertEqual(actual.config_path, R.codex_home() / "config.toml")
            route.assert_called_once_with(self.root)
            route.reset_mock()
            with self.assertRaises(ValueError):
                R.residual_paths(self.root, "../outside")
            route.assert_not_called()


if __name__ == "__main__":
    unittest.main()
