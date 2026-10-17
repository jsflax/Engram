"""Trusted runner selection and real lock ownership for legacy recovery."""
import importlib
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

from suite_support import PLUGIN_ROOT
import sys
sys.path.insert(0, str(PLUGIN_ROOT / "scripts"))
R = importlib.import_module("codex_learner.runner")


class RunnerLegacyEntryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="runner-legacy-entry-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.account_home = Path.home()
        self.native = self.root / "native-fixture"
        self.native.write_bytes(b"\xcf\xfa\xed\xfe" + b"never executed")
        self.native.chmod(0o700)

    def test_guard_requires_live_worker_then_enqueue_locks(self):
        self.assertFalse(R.publication_locks_owned(self.root))
        with R.lock_file(self.root / "worker.lock"):
            self.assertFalse(R.publication_locks_owned(self.root))
            with R.lock_file(self.root / "enqueue.lock"):
                self.assertIs(R.publication_locks_owned(self.root), True)
            self.assertFalse(R.publication_locks_owned(self.root))
        self.assertEqual(R._HELD_LOCKS.get(), ())

    def test_reversed_lock_order_is_not_recovery_authority(self):
        with R.lock_file(self.root / "enqueue.lock"), R.lock_file(self.root / "worker.lock"):
            self.assertFalse(R.publication_locks_owned(self.root))

    def test_replaced_lock_path_invalidates_guard(self):
        with R.lock_file(self.root / "worker.lock"), R.lock_file(self.root / "enqueue.lock"):
            path = self.root / "worker.lock"
            path.unlink()
            path.write_bytes(b"replacement")
            self.assertFalse(R.publication_locks_owned(self.root))

    def test_other_root_lock_cannot_authorize_this_root(self):
        other = self.root / "other"
        with R.lock_file(other / "worker.lock"), R.lock_file(other / "enqueue.lock"):
            self.assertFalse(R.publication_locks_owned(self.root))

    def select(self, **changes):
        declaration = {"enabled": True, "command": str(self.native), "args": [], "env": {},
                       "env_vars": [], **changes}
        with mock.patch.object(R.memory_config, "resolve", return_value=({}, declaration)), \
             mock.patch.object(R.pwd, "getpwuid", return_value=SimpleNamespace(pw_dir=str(self.account_home))):
            return R.legacy_paths(self.root)

    def test_explicit_store_comes_from_effective_transport(self):
        path = self.root / "selected.sqlite"
        selected = self.select(env={"CLAUDE_MEMORY_DB": str(path)})
        self.assertEqual(selected.candidate_store, path)
        self.assertEqual(selected.evidence_directory, self.root)

    def test_ambient_store_is_only_used_when_allowlisted(self):
        path = self.root / "allowlisted.sqlite"
        with mock.patch.dict(os.environ, {"CLAUDE_MEMORY_DB": str(path)}):
            self.assertEqual(self.select(env_vars=["CLAUDE_MEMORY_DB"]).candidate_store, path)
            self.assertEqual(self.select().candidate_store, Path.home() / ".claude/memory.sqlite")

    def test_disabled_relative_empty_or_ambiguous_store_refuses(self):
        for changes in ({"enabled": False}, {"args": ["--other-store"]},
                        {"env": {"CLAUDE_MEMORY_DB": "relative.sqlite"}},
                        {"env": {"CLAUDE_MEMORY_DB": ""}}):
            with self.subTest(changes=changes), self.assertRaisesRegex(ValueError, "legacy_reconciliation_"):
                self.select(**changes)

    def test_lazy_paths_are_not_resolved_for_ordinary_constructor(self):
        with mock.patch.object(R, "legacy_paths", side_effect=AssertionError("unexpected store read")), \
             mock.patch.object(R.runner_publication, "Publications") as constructor:
            R.publications(self.root)
        arguments = constructor.call_args.kwargs
        self.assertTrue(callable(arguments["legacy_paths"]))
        self.assertTrue(callable(arguments["legacy_verify_locks"]))
        self.assertFalse(arguments["legacy_verify_locks"]())

    def test_wrapper_missing_runtime_and_unmodelled_home_refuse(self):
        wrapper = self.root / "wrapper"
        wrapper.write_text("#!/bin/sh\nexit 1\n")
        wrapper.chmod(0o700)
        for changes in ({"command": str(wrapper)}, {"command": str(self.root / "missing")},
                        {"env": {"CFFIXED_USER_HOME": str(self.root / "other")}}):
            with self.subTest(changes=changes), self.assertRaisesRegex(ValueError, "legacy_reconciliation_"):
                self.select(**changes)
        path = self.root / "explicit.sqlite"
        self.assertEqual(self.select(env={"CFFIXED_USER_HOME": str(self.root / "other"),
            "CLAUDE_MEMORY_DB": str(path)}).candidate_store, path)

    def test_malformed_admission_cannot_hide_legacy_recovery(self):
        sid = "019b7a00-0000-7123-8000-000000000021"
        state = self.root / "sessions" / (sid + ".json")
        admission = self.root / "admissions" / (sid + ".json")
        R.atomic_json(state, {"status": "legacy_reconciled_no_new_mutation"})
        admission.parent.mkdir(mode=0o700)
        admission.write_bytes(b"{")
        before = (state.read_bytes(), admission.read_bytes())
        self.assertIs(R.has_recoverable_transition(self.root, sid), True)
        self.assertEqual((state.read_bytes(), admission.read_bytes()), before)

    def test_overridden_parent_home_requires_explicit_store(self):
        path = self.root / "explicit.sqlite"
        with mock.patch.dict(os.environ, {"HOME": str(self.root / "other")}):
            with self.assertRaisesRegex(ValueError, "legacy_reconciliation_"):
                self.select()
            self.assertEqual(self.select(env={"CLAUDE_MEMORY_DB": str(path)}).candidate_store, path)


if __name__ == "__main__":
    unittest.main()
