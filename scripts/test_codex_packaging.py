"""Exercise installer boundaries in a temporary home, without CLI/model work."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import unittest


SCRIPTS = Path(__file__).resolve().parent


class CodexPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="engram install test ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.codex_home = self.home / "custom codex"
        self.codex_home.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), CODEX_HOME=str(self.codex_home),
                        PATH=f"{self.bin}:/usr/bin:/bin", ENGRAM_CODEX_PYTHON=sys.executable)
        self.payload = self.root / "payload"
        self.payload.mkdir()
        shutil.copy(SCRIPTS / "install_codex_support.sh", self.payload)
        (self.payload / "install_codex_learner.py").write_text(
            "import json, os, pathlib, sys\n"
            "pathlib.Path(os.environ['HOME'], 'installer-call.json').write_text(json.dumps(sys.argv[1:]))\n"
        )

    def run_shell(self, script, *args):
        return subprocess.run(["/bin/bash", str(script), *args], env=self.env,
                              text=True, capture_output=True, timeout=20)

    def fake_command(self, name, body):
        file = self.bin / name
        file.write_text("#!/bin/bash\nset -eu\n" + body)
        file.chmod(0o755)

    def test_support_passes_custom_home_and_interpreter_with_spaces(self):
        result = self.run_shell(self.payload / "install_codex_support.sh", "install")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads((self.home / "installer-call.json").read_text())
        self.assertEqual(args, ["install", "--source-dir", str(self.payload),
                                "--python", sys.executable, "--codex-home", str(self.codex_home),
                                "--memory-command", str(self.home / ".claude/bin/memory")])

    def test_missing_python_skips_install_but_does_not_claim_uninstall(self):
        self.env["ENGRAM_CODEX_PYTHON"] = str(self.root / "missing python")
        install = self.run_shell(self.payload / "install_codex_support.sh", "install")
        uninstall = self.run_shell(self.payload / "install_codex_support.sh", "uninstall")
        self.assertEqual(install.returncode, 0)
        self.assertIn("Python 3.11+ required", install.stderr)
        self.assertNotEqual(uninstall.returncode, 0)
        self.assertFalse((self.home / "installer-call.json").exists())

    def test_download_installs_codex_without_claude_and_preserves_signatures(self):
        staging = self.root / "staging"
        staging.mkdir()
        shutil.copytree(self.payload, staging / "codex")
        for binary in ("memory", "memory-hooks", "memory-sync"):
            (staging / binary).write_bytes(b"signed-release-fixture")
        archive = self.root / "release.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            for child in staging.iterdir():
                tar.add(child, arcname=child.name)
        self.fake_command("curl", """case "$*" in
  *api.github.com*) echo '{"browser_download_url":"https://example.invalid/engram-macos-arm64.tar.gz"}' ;;
  *) cat """ + shlex.quote(str(archive)) + " ;;\nesac\n")
        self.fake_command("codesign", "echo 'unexpected signing' >&2\nexit 99\n")
        result = self.run_shell(SCRIPTS / "install.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("'claude' CLI not found", result.stdout)
        args = json.loads((self.home / "installer-call.json").read_text())
        self.assertEqual(args[0], "install")
        self.assertEqual(args[2], str(self.home / ".claude/bin/codex"))
        for binary in ("memory", "memory-hooks", "memory-sync"):
            self.assertEqual((self.home / ".claude/bin" / binary).read_bytes(), b"signed-release-fixture")
        self.assertNotIn("unexpected signing", result.stderr)

    def test_download_selects_cli_archive_with_plugin_asset_in_either_order(self):
        staging = self.root / "staging"
        staging.mkdir()
        for binary in ("memory", "memory-hooks", "memory-sync"):
            (staging / binary).write_bytes(b"signed-cli-fixture")
        archive = self.root / "cli-release.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            for child in staging.iterdir():
                tar.add(child, arcname=child.name)
        release = self.root / "release.json"
        cli = {"name": "engram-macos-arm64.tar.gz",
               "browser_download_url": "https://example.invalid/engram-macos-arm64.tar.gz"}
        plugin = {"name": "engram-codex-plugin-macos-arm64.tar.gz",
                  "browser_download_url": "https://example.invalid/engram-codex-plugin-macos-arm64.tar.gz"}
        self.fake_command("curl", """case "$*" in
  *api.github.com*) cat """ + shlex.quote(str(release)) + """ ;;
  *https://example.invalid/engram-macos-arm64.tar.gz) cat """ + shlex.quote(str(archive)) + """ ;;
  *) echo 'unexpected non-CLI download' >&2; exit 99 ;;
esac
""")
        for assets in ([plugin, cli], [cli, plugin]):
            with self.subTest(first_asset=assets[0]["name"]):
                release.write_text(json.dumps({"assets": assets}, indent=2))
                result = self.run_shell(SCRIPTS / "install.sh")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                for binary in ("memory", "memory-hooks", "memory-sync"):
                    self.assertEqual((self.home / ".claude/bin" / binary).read_bytes(), b"signed-cli-fixture")
                self.assertNotIn("unexpected non-CLI download", result.stderr)

    def test_uninstall_keeps_payload_when_hook_removal_cannot_run(self):
        installed = self.home / ".claude/bin/codex"
        installed.parent.mkdir(parents=True)
        shutil.copytree(self.payload, installed)
        self.env["ENGRAM_CODEX_PYTHON"] = str(self.root / "missing python")
        result = self.run_shell(SCRIPTS / "uninstall.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((installed / "install_codex_learner.py").exists())
        self.assertIn("Keeping Codex installer payload", result.stdout)

    def test_source_install_packages_codex_and_signs_local_binaries(self):
        source = self.root / "source"
        scripts = source / "scripts"
        scripts.mkdir(parents=True)
        for name in ("install.sh", "package_codex_learner.sh", "install_codex_support.sh"):
            shutil.copy(SCRIPTS / name, scripts)
        shutil.copy(self.payload / "install_codex_learner.py", scripts)
        (scripts / "codex_learner").mkdir()
        for name in ("codex_learner.py", "codex_learner/__init__.py", "codex_learner/transcript.py",
                     "codex_learner/runner.py", "codex_learner/memory_proxy.py", "codex_learner/learner_prompt.md"):
            (scripts / name).write_text("# packaged fixture\n")
        self.fake_command("swift", """
mkdir -p .build/release/Engram_EngramKit.bundle .build/release/swift-transformers_Hub.bundle .build/release/SwiftLM_SwiftLM.bundle
for binary in Engram EngramHooks EngramDaemon; do echo local-build > ".build/release/$binary"; done
""")
        self.fake_command("codesign", 'echo "$*" >> "$HOME/signing-calls"\n')
        result = self.run_shell(scripts / "install.sh", "--from-source")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        args = json.loads((self.home / "installer-call.json").read_text())
        self.assertEqual(args[0], "install")
        self.assertEqual(len((self.home / "signing-calls").read_text().splitlines()), 3)
        self.assertTrue((self.home / ".claude/bin/codex/codex_learner/learner_prompt.md").is_file())

    def test_package_is_self_contained_and_omits_tests_and_bytecode(self):
        target = self.root / "packaged"
        result = self.run_shell(SCRIPTS / "package_codex_learner.sh", str(target))
        self.assertEqual(result.returncode, 0, result.stderr)
        # Invoke from another working directory, using only the shipped files.
        result = subprocess.run([sys.executable, str(target / "install_codex_learner.py"), "--help"],
                                cwd=self.root, env=self.env, text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        files = [p.relative_to(target).as_posix() for p in target.rglob("*") if p.is_file()]
        self.assertIn("codex_learner/learner_prompt.md", files)
        self.assertIn("codex_learner/memory_proxy.py", files)
        self.assertFalse(any("test_" in p or "__pycache__" in p for p in files), files)

    def test_packaged_install_registers_memory_and_preserves_user_settings(self):
        target = self.root / "packaged"
        result = self.run_shell(SCRIPTS / "package_codex_learner.sh", str(target))
        self.assertEqual(result.returncode, 0, result.stderr)
        memory = self.home / ".claude/bin/memory"
        memory.parent.mkdir(parents=True)
        memory.write_text("#!/bin/sh\nexit 99\n")  # Installer must not run the server.
        memory.chmod(0o755)
        config = self.codex_home / "config.toml"
        original_config = '# Preserve this comment.\nmodel = "custom-model"\n[mcp_servers.other]\ncommand = "/custom/server"\n'
        config.write_text(original_config)
        hooks = self.codex_home / "hooks.json"
        user_group = {"hooks": [{"type": "command", "command": "user-owned-hook"}]}
        original_hooks = {"hooks": {"Stop": [user_group]}}
        hooks.write_text(json.dumps(original_hooks))
        result = self.run_shell(target / "install_codex_support.sh", "install")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        parsed = tomllib.loads(config.read_text())
        self.assertEqual(parsed["mcp_servers"]["memory"]["command"], str(memory))
        self.assertEqual(parsed["mcp_servers"]["other"]["command"], "/custom/server")
        self.assertTrue(config.read_text().startswith(original_config))
        self.assertIn(user_group, json.loads(hooks.read_text())["hooks"]["Stop"])
        first_config = config.read_bytes()
        first_hooks = hooks.read_bytes()
        result = self.run_shell(target / "install_codex_support.sh", "install")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(config.read_bytes(), first_config)
        self.assertEqual(hooks.read_bytes(), first_hooks)
        result = self.run_shell(target / "install_codex_support.sh", "uninstall")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(hooks.read_text()), original_hooks)
        self.assertEqual(config.read_text(), original_config)

    def test_packaged_install_preserves_existing_disabled_memory_server(self):
        target = self.root / "packaged"
        result = self.run_shell(SCRIPTS / "package_codex_learner.sh", str(target))
        self.assertEqual(result.returncode, 0, result.stderr)
        memory = self.home / ".claude/bin/memory"
        memory.parent.mkdir(parents=True)
        memory.write_text("#!/bin/sh\nexit 99\n")
        memory.chmod(0o755)
        config = self.codex_home / "config.toml"
        original = '[mcp_servers.memory]\nurl = "https://custom.invalid/mcp"\nenabled = false\n'
        config.write_text(original)
        for action in ("install", "uninstall"):
            result = self.run_shell(target / "install_codex_support.sh", action)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(config.read_text(), original)


if __name__ == "__main__":
    unittest.main()
