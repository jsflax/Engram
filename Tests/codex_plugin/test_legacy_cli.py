"""Packaged reconciliation CLI creates a private reviewable plan only."""
import contextlib
import importlib
import io
import json
from pathlib import Path
import unittest

from legacy_fixture import LegacyFixture, load_runtime, SID, RUN_ID, PLUGIN, digest

L = load_runtime()
CLI = importlib.import_module("learner_reconcile")


class LegacyCLITests(unittest.TestCase):
    def fixture(self):
        fixture = LegacyFixture(L)
        self.addCleanup(fixture.close)
        return fixture

    def prepare(self, fixture, output):
        args = ["prepare", "--root", str(fixture.root), "--evidence-directory", str(fixture.evidence),
            "--package-root", str(PLUGIN), "--candidate-store", str(fixture.store), "--session-id", SID,
            "--legacy-run-id", RUN_ID, "--reviewed-bundle-sha256", fixture.review_sha256,
            "--reconciliation-id", fixture.reconciliation_id, "--output", str(output)]
        stream = io.StringIO()
        with contextlib.redirect_stdout(stream):
            status = CLI.main(args)
        return status, json.loads(stream.getvalue())

    def test_packaged_prepare_publishes_private_plan_and_no_live_state(self):
        f = self.fixture()
        before, history, database = f.current(), f.history_snapshot(), f.store.read_bytes()
        output = f.base / "reviewable-plan.json"
        status, result = self.prepare(f, output)
        self.assertEqual(status, 0)
        self.assertEqual(result, {"status": "prepared", "id": f.reconciliation_id,
            "plan_sha256": digest(output.read_bytes()), "live_changes": False})
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        self.assertEqual(f.current(), before)
        self.assertEqual(f.history_snapshot(), history)
        self.assertEqual(f.store.read_bytes(), database)
        self.assertFalse((f.root / "reconciliations").exists())
        self.assertNotIn("importlib", Path(CLI.__file__).read_text())

    def test_output_requires_absolute_owned_private_nonsymlink_parent(self):
        f = self.fixture()
        public = f.base / "public"
        public.mkdir(mode=0o755)
        link = f.base / "link"
        link.symlink_to(f.evidence, target_is_directory=True)
        for output in (Path("relative-plan.json"), public / "plan.json", link / "plan.json"):
            with self.subTest(output=str(output)):
                before = f.current()
                status, result = self.prepare(f, output)
                self.assertEqual(status, 2)
                self.assertEqual(result["status"], "held")
                self.assertTrue(result["reason"].startswith("legacy_reconciliation_"))
                self.assertEqual(f.current(), before)
                self.assertFalse(output.exists())

    def test_prepare_requires_explicit_review_import_directory(self):
        f = self.fixture()
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            status = CLI.main(["prepare", "--root", str(f.root), "--package-root", str(PLUGIN),
                "--candidate-store", str(f.store), "--session-id", SID])
        self.assertEqual(status, 2)
        self.assertEqual(json.loads(output.getvalue()), {"status": "held",
            "reason": "legacy_reconciliation_missing_prepare_arguments"})

    def test_older_installation_prepare_does_not_create_publication_container(self):
        f = self.fixture()
        (f.root / "publications").rmdir()
        before, history, database = f.current(), f.history_snapshot(), f.store.read_bytes()
        output = f.base / "reviewable-plan.json"
        status, result = self.prepare(f, output)
        self.assertEqual(status, 0)
        self.assertFalse(result["live_changes"])
        self.assertFalse((f.root / "publications").exists())
        self.assertEqual(f.current(), before)
        self.assertEqual(f.history_snapshot(), history)
        self.assertEqual(f.store.read_bytes(), database)


if __name__ == "__main__":
    unittest.main()
