import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
import sys
from unittest import mock

from suite_support import PLUGIN_ROOT, REPOSITORY_ROOT, TEMP_ROOT

HERE = REPOSITORY_ROOT
sys.path.insert(0, str(PLUGIN_ROOT / "scripts"))
from codex_learner import file_identity
spec = importlib.util.spec_from_file_location("bootstrap", PLUGIN_ROOT / "scripts/engram_hook.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=TEMP_ROOT)
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        (self.home / "sessions").mkdir()
        capture = mock.patch.object(file_identity, "capture_fd", side_effect=lambda fd: {
            "scheme": "macos_volume_uuid_inode_v1",
            "volume_uuid": "11111111-2222-4333-8444-555555555555", "inode": os.fstat(fd).st_ino})
        capture.start(); self.addCleanup(capture.stop)

    def test_portable_state_and_no_pilot_pins(self):
        root = module.initialize(self.home)
        recall = json.loads((root / "recall.json").read_text())
        policy = json.loads((root / "learner/admission.json").read_text())
        self.assertEqual(recall["selected_memory_ids"], [])
        self.assertTrue(recall["semantic_recall"])
        self.assertEqual(policy["sessions_dir"]["path"], str(self.home / "sessions"))
        self.assertEqual(policy["mode"], "host_sessions_v2")
        self.assertEqual(policy["schema_version"], 2)
        self.assertEqual(set(policy["sessions_dir"]), {"path", "identity"})
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

    def test_existing_v1_policy_is_not_seeded_with_current_volume(self):
        root = module.initialize(self.home)
        path = root / "learner/admission.json"
        value = json.loads(path.read_bytes())
        info = (self.home / "sessions").stat()
        value.update(schema_version=1, mode="host_sessions_v1",
                     sessions_dir={"path": str(self.home / "sessions"), "device": info.st_dev, "inode": info.st_ino})
        path.write_text(json.dumps(value))
        route = root / "learner-routes.json"
        route.write_text(json.dumps({"schema_version": 1, "mode": "host_sessions_v1",
                                    "enabled": False, "state_dir": str(root / "learner")}))
        before = {p: p.read_bytes() for p in root.rglob("*.json")}
        with mock.patch.object(file_identity, "capture_fd", side_effect=AssertionError("implicit migration")):
            module.initialize(self.home)
        self.assertEqual(before, {p: p.read_bytes() for p in root.rglob("*.json")})

    def test_unavailable_stable_identity_never_creates_legacy_fallback(self):
        with mock.patch.object(file_identity, "capture_fd", side_effect=ValueError("admission_identity_unavailable")):
            with self.assertRaises(ValueError):
                module.initialize(self.home)
        self.assertFalse((self.home / "engram/learner/admission.json").exists())
        self.assertFalse((self.home / "engram/learner-routes.json").exists())

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
