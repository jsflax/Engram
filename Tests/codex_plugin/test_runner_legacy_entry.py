"""Trusted runner selection and real lock ownership for legacy recovery."""
import importlib
import os
from pathlib import Path
import tempfile
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
        declaration = {"enabled": True, "command": "/trusted/engram", "args": [], "env": {},
                       "env_vars": [], **changes}
        with mock.patch.object(R.memory_config, "resolve", return_value=({}, declaration)):
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


if __name__ == "__main__":
    unittest.main()
