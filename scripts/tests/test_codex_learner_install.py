"""Behavioral installer tests; all configuration and assets live in temp dirs."""

import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import tomllib
import unittest
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[1] / "install_codex_learner.py"
SPEC = importlib.util.spec_from_file_location("installer", MODULE_PATH)
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "codex home 'quoted'"
        self.home.mkdir()
        self.state = self.home / "engram-learner"
        self.source = self.root / "packaged assets"
        for name in installer.REQUIRED_ASSETS:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("# packaged runtime\n")
        (self.source / "codex_learner/learner_prompt.md").write_text("Learn durable facts.\n")
        self.python = Path(sys.executable)
        self.hooks_path = self.home / "hooks.json"
        self.config = self.home / "config.toml"
        self.config.write_bytes(b'# retain formatting\nnotify = ["computer-use", "notify"]\n\n[other]\nsetting = true\n')
        self.config_before = self.config.read_bytes()

    def run_install(self, **kwargs):
        return installer.install(self.home, self.state, self.source, self.python, **kwargs)

    def read_hooks(self):
        return json.loads(self.hooks_path.read_text())

    def test_prepare_is_read_only_and_command_is_shell_safe(self):
        plan = installer.prepare(self.home, self.state, self.source, self.python)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.hooks_path.exists())
        self.assertEqual(plan["expected_sha256"], "absent")
        command = plan["fragment"]["hooks"]["Stop"][0]["hooks"][0]["command"]
        self.assertEqual(shlex.split(command), [str(self.python), str(Path(plan["runtime_dir"]) / "codex_learner.py"), "hook", "--state-dir", str(self.state)])

    def test_plugin_registration_skips_prepare_and_install_without_writes(self):
        for name in ("engram@personal", "engram-hooks@team"):
            for enabled in (True, False):
                with self.subTest(name=name, enabled=enabled):
                    raw = self.config_before + (f'\n[plugins."{name}"]\nenabled = {str(enabled).lower()}\n').encode()
                    self.config.write_bytes(raw)
                    for result in (installer.prepare(self.home, self.state, self.root / "absent", self.python),
                                   self.run_install(memory_command=self.root / "absent-memory")):
                        self.assertEqual(result["status"], "skipped_plugin")
                        self.assertEqual(result["plugin_ids"], [name])
                    self.assertEqual(self.config.read_bytes(), raw)
                    self.assertFalse(self.state.exists())
                    self.assertFalse(self.hooks_path.exists())

    def test_plugin_guard_preserves_old_state_and_owned_uninstall_still_works(self):
        self.run_install()
        pending = self.state / "pending" / "old.json"
        pending.parent.mkdir()
        pending.write_bytes(b'{"request_id":"preserved"}')
        cursor = self.state / "sessions" / "old.json"
        cursor.parent.mkdir()
        cursor.write_bytes(b'{"offset":167}')
        raw = self.config_before + b'\n[features]\nplugins = false\n[plugins."engram@personal"]\nenabled = false\n[mcp_servers.memory]\ncommand = "/custom/memory"\n'
        self.config.write_bytes(raw)
        before = {str(p): p.read_bytes() for p in self.home.rglob("*") if p.is_file()}
        self.assertEqual(self.run_install()["status"], "skipped_plugin")
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.home.rglob("*") if p.is_file()})
        self.assertEqual(installer.uninstall(self.home, self.state)["status"], "uninstalled")
        self.assertEqual(pending.read_bytes(), b'{"request_id":"preserved"}')
        self.assertEqual(cursor.read_bytes(), b'{"offset":167}')
        self.assertEqual(self.config.read_bytes(), raw)

    def test_unrelated_plugin_retains_fresh_legacy_setup(self):
        self.config.write_bytes(self.config_before + b'\n[plugins."engram-tools@personal"]\nenabled = true\n')
        result = self.run_install(memory_command=self.memory_executable())
        self.assertEqual(result["status"], "installed")
        self.assertEqual(result["memory_mcp"]["status"], "registered")
        self.assertEqual(set(self.read_hooks()["hooks"]), set(installer.EVENTS))

    def test_automatic_shell_respects_disabled_plugin(self):
        raw = self.config_before + b'\n[plugins."engram@personal"]\nenabled = false\n'
        self.config.write_bytes(raw)
        env = {**os.environ, "HOME": str(self.root),
               "CODEX_HOME": str(self.home), "ENGRAM_CODEX_PYTHON": str(self.python),
               "PYTHONDONTWRITEBYTECODE": "1"}
        completed = subprocess.run(["/bin/bash", str(MODULE_PATH.with_name("install_codex_support.sh")), "install"],
                                   env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(json.loads(completed.stdout)["status"], "skipped_plugin")
        self.assertEqual(self.config.read_bytes(), raw)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.hooks_path.exists())

    def test_install_is_idempotent_preserves_notify_and_has_private_backups(self):
        first = self.run_install()
        self.assertEqual(first["status"], "installed")
        original = self.hooks_path.read_bytes()
        original_mtime = self.hooks_path.stat().st_mtime_ns
        second = self.run_install()
        self.assertEqual(second["status"], "unchanged")
        self.assertIsNone(second["backup"])
        self.assertEqual(self.hooks_path.read_bytes(), original)
        self.assertEqual(self.hooks_path.stat().st_mtime_ns, original_mtime)
        self.assertEqual(self.config.read_bytes(), self.config_before)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o700)
        for path in [self.hooks_path, self.state / "install.json", Path(first["backup"])]:
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        backup = json.loads(Path(first["backup"]).read_text())
        self.assertFalse(backup["hooks_existed"])
        self.assertEqual(set(self.read_hooks()["hooks"]), set(installer.EVENTS))
        for groups in self.read_hooks()["hooks"].values():
            self.assertEqual(groups[0]["hooks"][0]["timeout"], 3)
        runtime = Path(first["runtime_dir"])
        self.assertTrue((runtime / "codex_learner/learner_prompt.md").is_file())
        self.assertNotIn(str(self.source), original.decode())

    def test_upgrade_and_uninstall_preserve_unrelated_handlers_and_data(self):
        unrelated = {"type": "command", "command": "printf unrelated", "timeout": 9}
        self.hooks_path.write_text(json.dumps({"description": "Existing config", "future": {"value": 42}, "hooks": {"Stop": [{"matcher": "custom", "hooks": [unrelated]}], "SessionStart": [{"hooks": [unrelated]}]}}))
        first = self.run_install()
        hooks = self.read_hooks()
        own = hooks["hooks"]["Stop"].pop()["hooks"][0]
        own["timeout"] = 7
        own["statusMessage"] = "User customization"
        hooks["hooks"]["Stop"][0]["hooks"].append(own)
        self.hooks_path.write_text(json.dumps(hooks))
        (self.source / "codex_learner/runner.py").write_text("# newer runtime\n")
        second = self.run_install()
        self.assertNotEqual(first["runtime_dir"], second["runtime_dir"])
        self.assertTrue(Path(first["runtime_dir"]).is_dir())
        updated = self.read_hooks()
        self.assertEqual(updated["hooks"]["Stop"][0]["matcher"], "custom")
        self.assertEqual(updated["hooks"]["Stop"][0]["hooks"][0], unrelated)
        self.assertEqual(updated["hooks"]["Stop"][0]["hooks"][1]["timeout"], 7)
        self.assertEqual(updated["hooks"]["Stop"][0]["hooks"][1]["statusMessage"], "User customization")
        result = installer.uninstall(self.home, self.state)
        self.assertEqual(result["status"], "uninstalled")
        remaining = self.read_hooks()
        self.assertEqual(remaining, {"description": "Existing config", "future": {"value": 42}, "hooks": {"Stop": [{"matcher": "custom", "hooks": [unrelated]}], "SessionStart": [{"hooks": [unrelated]}]}})
        self.assertTrue(Path(first["runtime_dir"]).exists())
        self.assertTrue(Path(second["runtime_dir"]).exists())
        self.assertEqual(installer.uninstall(self.home, self.state)["status"], "unchanged")
        self.assertEqual(self.config.read_bytes(), self.config_before)

    def test_changed_prepared_config_is_not_overwritten(self):
        plan = installer.prepare(self.home, self.state, self.source, self.python)
        newer = b'{"description":"created concurrently"}'
        self.hooks_path.write_bytes(newer)
        with self.assertRaisesRegex(installer.InstallError, "changed since preparation"):
            self.run_install(expected_sha256=plan["expected_sha256"])
        self.assertEqual(self.hooks_path.read_bytes(), newer)

    def test_late_concurrent_edit_is_not_overwritten(self):
        original = b'{"before":true}'
        concurrent = b'{"concurrent":true}'
        self.hooks_path.write_bytes(original)
        with patch.object(installer.os, "fsync", side_effect=lambda fd: self.hooks_path.write_bytes(concurrent)):
            with self.assertRaisesRegex(installer.InstallError, "Concurrent change"):
                installer.atomic_write(self.hooks_path, b"{}", original)
        self.assertEqual(self.hooks_path.read_bytes(), concurrent)
        self.assertFalse(list(self.home.glob(".hooks.json.*")))

    def test_malformed_or_duplicate_key_configuration_is_preserved(self):
        for raw in (b"{bad", b'{"hooks": {}, "hooks": {}}', b"[]", b'{"hooks":{"Stop":"wrong"}}'):
            with self.subTest(raw=raw):
                self.hooks_path.write_bytes(raw)
                with self.assertRaises(installer.InstallError):
                    self.run_install()
                self.assertEqual(self.hooks_path.read_bytes(), raw)

    def test_symlink_configuration_is_not_followed(self):
        target = self.root / "other.json"
        target.write_text("{}")
        self.hooks_path.symlink_to(target)
        with self.assertRaisesRegex(installer.InstallError, "symlink"):
            self.run_install()
        self.assertEqual(target.read_text(), "{}")

    def test_runtime_tampering_is_rejected(self):
        first = self.run_install()
        original = self.hooks_path.read_bytes()
        (Path(first["runtime_dir"]) / "codex_learner.py").write_text("# unexpected replacement\n")
        with self.assertRaisesRegex(installer.InstallError, "runtime changed"):
            self.run_install()
        self.assertEqual(self.hooks_path.read_bytes(), original)

    def test_missing_asset_and_invalid_python_abort_before_hook_write(self):
        missing = self.source / "codex_learner/runner.py"
        missing.unlink()
        with self.assertRaisesRegex(installer.InstallError, "Missing runtime asset"):
            self.run_install()
        self.assertFalse(self.hooks_path.exists())
        missing.write_text("def broken(:\n")
        with self.assertRaisesRegex(installer.InstallError, "Invalid Python"):
            self.run_install()
        self.assertFalse(self.hooks_path.exists())

    def test_edited_owned_command_requires_review_instead_of_duplication(self):
        self.run_install()
        hooks = self.read_hooks()
        hooks["hooks"]["Stop"][0]["hooks"][0]["command"] += " --custom"
        raw = json.dumps(hooks).encode()
        self.hooks_path.write_bytes(raw)
        with self.assertRaisesRegex(installer.InstallError, "was edited"):
            self.run_install()
        with self.assertRaisesRegex(installer.InstallError, "was edited"):
            installer.uninstall(self.home, self.state)
        self.assertEqual(self.hooks_path.read_bytes(), raw)

    def test_no_manifest_uninstall_does_not_claim_other_hooks(self):
        raw = b'{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}'
        self.hooks_path.write_bytes(raw)
        self.assertEqual(installer.uninstall(self.home, self.state)["status"], "not_installed")
        self.assertEqual(self.hooks_path.read_bytes(), raw)
        self.assertFalse(self.state.exists())

    def test_source_parent_and_home_spaces_do_not_break_runtime_path(self):
        first = self.run_install()
        command = self.read_hooks()["hooks"]["SessionEnd"][0]["hooks"][0]["command"]
        tokens = shlex.split(command)
        self.assertEqual(Path(tokens[1]).parent, Path(first["runtime_dir"]))
        self.assertTrue(Path(tokens[1]).is_file())
        self.assertEqual(tokens[-1], str(self.state))

    def memory_executable(self):
        executable = self.root / 'memory "executable"'
        executable.write_text("#!/bin/sh\nexit 0\n")
        executable.chmod(0o700)
        return executable

    def test_missing_memory_server_is_appended_without_rewriting_notify(self):
        executable = self.memory_executable()
        first = self.run_install(memory_command=executable)
        self.assertEqual(first["memory_mcp"]["status"], "registered")
        self.assertTrue(self.config.read_bytes().startswith(self.config_before))
        self.assertEqual(tomllib.loads(self.config.read_text())["mcp_servers"]["memory"], {"command": str(executable)})
        exact = self.config.read_bytes()
        second = self.run_install(memory_command=executable)
        self.assertEqual(second["memory_mcp"]["status"], "existing_registration_preserved")
        self.assertEqual(self.config.read_bytes(), exact)
        result = installer.uninstall(self.home, self.state)
        self.assertEqual(result["memory_mcp"]["status"], "unregistered")
        self.assertEqual(self.config.read_bytes(), self.config_before)

    def test_custom_disabled_memory_registration_is_untouched(self):
        raw = self.config_before + b'\n[mcp_servers.memory]\ncommand = "/custom/memory"\nenabled = false\n'
        self.config.write_bytes(raw)
        result = self.run_install(memory_command=self.root / "not-installed")
        self.assertEqual(result["memory_mcp"]["status"], "existing_registration_preserved")
        self.assertEqual(self.config.read_bytes(), raw)
        installer.uninstall(self.home, self.state)
        self.assertEqual(self.config.read_bytes(), raw)

    def test_modified_owned_memory_registration_is_preserved(self):
        self.run_install(memory_command=self.memory_executable())
        raw = self.config.read_bytes() + b'args = ["custom"]\n'
        self.config.write_bytes(raw)
        result = installer.uninstall(self.home, self.state)
        self.assertEqual(result["memory_mcp"]["status"], "modified_registration_preserved")
        self.assertEqual(self.config.read_bytes(), raw)

    def test_memory_unregister_preserves_later_unrelated_config_edits(self):
        self.run_install(memory_command=self.memory_executable())
        suffix = b'\n[mcp_servers.something_else]\ncommand = "other"\n'
        self.config.write_bytes(self.config.read_bytes() + suffix)
        result = installer.uninstall(self.home, self.state)
        self.assertEqual(result["memory_mcp"]["status"], "unregistered")
        self.assertEqual(self.config.read_bytes(), self.config_before + suffix)

    def test_unappendable_toml_layout_fails_without_configuration_change(self):
        raw = b'notify = ["existing"]\nmcp_servers = {}\n'
        self.config.write_bytes(raw)
        with self.assertRaisesRegex(installer.InstallError, "Cannot safely append"):
            self.run_install(memory_command=self.memory_executable())
        self.assertEqual(self.config.read_bytes(), raw)
        self.assertFalse(self.hooks_path.exists())

    def test_state_cannot_be_reused_for_another_codex_home(self):
        self.run_install()
        other = self.root / "other-home"
        with self.assertRaisesRegex(installer.InstallError, "location does not match"):
            installer.install(other, self.state, self.source, self.python)
        self.assertFalse((other / "hooks.json").exists())


if __name__ == "__main__":
    unittest.main()
