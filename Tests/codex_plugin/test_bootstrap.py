import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

from suite_support import PLUGIN_ROOT, REPOSITORY_ROOT, TEMP_ROOT

HERE = REPOSITORY_ROOT
spec = importlib.util.spec_from_file_location("bootstrap", PLUGIN_ROOT / "scripts/engram_hook.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=TEMP_ROOT)
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        (self.home / "sessions").mkdir()

    def test_portable_state_and_no_pilot_pins(self):
        root = module.initialize(self.home)
        recall = json.loads((root / "recall.json").read_text())
        policy = json.loads((root / "learner/admission.json").read_text())
        self.assertEqual(recall["selected_memory_ids"], [])
        self.assertTrue(recall["semantic_recall"])
        self.assertEqual(policy["sessions_dir"]["path"], str(self.home / "sessions"))
        self.assertEqual(policy["mode"], "host_sessions_v1")
        self.assertEqual(root.stat().st_mode & 0o777, 0o700)
        for path in root.rglob("*.json"):
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_disabled_policy_and_custom_settings_survive(self):
        root = module.initialize(self.home)
        admission = root / "learner/admission.json"
        value = json.loads(admission.read_text())
        value["enabled"] = False
        admission.write_text(json.dumps(value))
        settings = root / "learner/settings.json"
        settings.write_text('{"max_writes":1}')
        before = {p: p.read_bytes() for p in root.rglob("*.json")}
        module.initialize(self.home)
        self.assertEqual(before, {p: p.read_bytes() for p in root.rglob("*.json")})

    def test_symlink_root_rejected(self):
        other = self.home / "other"
        other.mkdir()
        (self.home / "engram").symlink_to(other, target_is_directory=True)
        with self.assertRaises(ValueError):
            module.initialize(self.home)
        self.assertEqual(list(other.iterdir()), [])

    def test_symlink_file_never_overwritten(self):
        root = module.initialize(self.home)
        path = root / "recall.json"
        path.unlink()
        target = self.home / "untouched"
        target.write_text("original")
        path.symlink_to(target)
        with self.assertRaises(ValueError):
            module.initialize(self.home)
        self.assertEqual(target.read_text(), "original")

    def test_shared_root_rejected_without_chmod(self):
        root = self.home / "engram"
        root.mkdir(mode=0o755)
        with self.assertRaises(ValueError):
            module.initialize(self.home)
        self.assertEqual(root.stat().st_mode & 0o777, 0o755)


if __name__ == "__main__":
    unittest.main()
