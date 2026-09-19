"""Portable packaging regressions; native signing is mocked with fake binaries."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("package_codex_plugin", Path(__file__).with_name("package_codex_plugin.py"))
packager = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(packager)


class PluginPackageTests(unittest.TestCase):
    def setUp(self):
        # Respect TMPDIR: owners put all test artifacts under their localdev
        # evidence directory; CI uses its configured runner scratch directory.
        self.temp = tempfile.TemporaryDirectory(prefix="engram-plugin-package-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source" / "engram"
        self.cli = self.root / "signed-cli"
        self.source.mkdir(parents=True)
        self.cli.mkdir()
        self.manifest = {
            "name": "engram", "version": "0.14.8", "skills": "./skills/",
            "mcpServers": "./.mcp.json", "interface": {"displayName": "Engram",
                **{key: "./assets/engram.png" for key in ("composerIcon", "logo", "logoDark")}},
        }
        self.write(".codex-plugin/plugin.json", json.dumps(self.manifest))
        self.write(".mcp.json", json.dumps({"mcpServers": {"memory": {"command": "./bin/memory", "args": [], "cwd": "."}}}))
        self.write("hooks/hooks.json", json.dumps({"hooks": {event: [{"hooks": [{"type": "command", "command": '/bin/sh "${CLAUDE_PLUGIN_ROOT}/scripts/engram-hook"'}]}] for event in packager.HOOKS}}))
        icon = b"\x89PNG\r\n\x1a\nfixture-icon"
        self.write("assets/engram.png", icon)
        self.write("PROVENANCE.json", json.dumps({"icon": {"copied_to": "assets/engram.png", "sha256": hashlib.sha256(icon).hexdigest()}}))
        for name in ("README.md", "LICENSE", "skills/hook-status/scripts/hook_status.py"):
            self.write(name, "fixture\n")
        for name in packager.RUNTIME_SCRIPTS:
            self.write("scripts/" + name, "# fixture\n")
        for skill in packager.SKILLS:
            self.write(f"skills/{skill}/SKILL.md", "---\nname: " + skill + "\n---\nFixture\n")
            self.write(f"skills/{skill}/agents/openai.yaml", "interface:\n  display_name: Fixture\n")
        binary = self.cli / "memory"
        binary.write_bytes(struct.pack("<II", 0xFEEDFACF, 0x0100000C) + b"fake-signed-arm64")
        binary.chmod(0o755)
        for bundle, resources in packager.RESOURCE_FILES.items():
            for relative in resources:
                path = self.cli / bundle / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"fixture resource\n")
        self.signature = patch.object(packager.subprocess, "run", side_effect=self.codesign)
        self.signature.start()
        self.addCleanup(self.signature.stop)

    @staticmethod
    def codesign(args, **kwargs):
        if args[:3] == ["/usr/bin/codesign", "--verify", "--strict"]:
            return subprocess.CompletedProcess(args, 0, "", "")
        if args[:3] == ["/usr/bin/codesign", "--display", "--verbose=4"]:
            return subprocess.CompletedProcess(args, 0, "", "Authority=Developer ID Application: Fixture\nTeamIdentifier=ABCDEFGHIJ\n")
        raise AssertionError(f"unexpected native execution: {args}")

    def write(self, relative, data):
        path = self.source / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data if isinstance(data, bytes) else data.encode())
        return path

    def build(self, output_dir="first", **changes):
        options = dict(source=self.source, cli=self.cli,
                       output=self.root / output_dir / "engram-codex-plugin-macos-arm64.tar.gz",
                       manifest_output=self.root / output_dir / "engram-codex-plugin-manifest.json",
                       version="0.14.8", source_sha="a" * 40, expected_team="ABCDEFGHIJ",
                       workflow_run="https://github.com/jsflax/Engram/actions/runs/123", run_attempt=2)
        options.update(changes)
        return packager.package(**options)

    def test_archive_is_complete_portable_and_preserves_binary(self):
        manifest = self.build()
        archive = self.root / "first" / manifest["archive"]["name"]
        self.assertEqual(manifest["archive"]["sha256"], hashlib.sha256(archive.read_bytes()).hexdigest())
        self.assertNotIn(str(self.root), json.dumps(manifest))
        self.assertNotIn("ABCDEFGHIJ", json.dumps(manifest))
        with tarfile.open(archive) as packaged:
            self.assertEqual(packaged.extractfile("engram/bin/memory").read(), (self.cli / "memory").read_bytes())
            records = {entry["path"]: entry for entry in manifest["files"]}
            actual = {entry.name.removeprefix("engram/"): entry for entry in packaged if entry.isfile()}
            self.assertEqual(set(records), set(actual))
            for path, entry in actual.items():
                contents = packaged.extractfile(entry).read()
                self.assertEqual(records[path]["sha256"], hashlib.sha256(contents).hexdigest(), path)
                self.assertEqual(records[path]["bytes"], len(contents), path)
            for entry in packaged.getmembers():
                self.assertEqual((entry.uid, entry.gid, entry.uname, entry.gname, entry.mtime), (0, 0, "", "", 0))
                self.assertIn(entry.mode, (0o644, 0o755))
            provenance = json.load(packaged.extractfile("engram/RELEASE-PROVENANCE.json"))
            self.assertEqual(provenance["source"]["pluginPath"], "codex/plugins/engram")

    def test_archive_deterministic_across_locations_mtimes_and_modes(self):
        first = self.build()
        second_source = self.root / "second-source"
        second_cli = self.root / "second-cli"
        shutil.copytree(self.source, second_source)
        shutil.copytree(self.cli, second_cli)
        for root in (second_source, second_cli):
            for path in root.rglob("*"):
                os.utime(path, (1700000000, 1700000000))
                if path.is_file():
                    path.chmod(0o777 if path.name == "memory" else 0o600)
        second = self.build("second", source=second_source, cli=second_cli)
        self.assertEqual(first, second)

    def test_missing_bundle_fails_before_output(self):
        shutil.rmtree(self.cli / "swift-crypto_Crypto.bundle")
        with self.assertRaisesRegex(ValueError, "four qualified"):
            self.build()
        self.assertFalse((self.root / "first").exists())

    def test_missing_embedding_weights_fails(self):
        (self.cli / "Engram_EngramKit.bundle/paraphrase-MiniLM-L6-v2_Embedding.mlmodelc/weights/weight.bin").unlink()
        with self.assertRaisesRegex(ValueError, "missing runtime resources"):
            self.build()

    def test_unsigned_or_wrong_team_binary_fails(self):
        with patch.object(packager.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "Signature=adhoc\nTeamIdentifier=not set\n")):
            with self.assertRaisesRegex(ValueError, "Developer ID"):
                self.build()

    def test_invalid_signature_fails(self):
        with patch.object(packager.subprocess, "run", side_effect=subprocess.CalledProcessError(1, ["codesign"])):
            with self.assertRaises(subprocess.CalledProcessError):
                self.build()

    def test_x86_native_fails(self):
        (self.cli / "memory").write_bytes(struct.pack("<II", 0xFEEDFACF, 0x01000007))
        with self.assertRaisesRegex(ValueError, "arm64"):
            self.build()

    def test_stale_native_payload_in_source_fails(self):
        self.write("bin/memory", b"stale binary")
        with self.assertRaisesRegex(ValueError, "unexpected plugin source"):
            self.build()

    def test_secret_state_and_attempt_artifacts_fail(self):
        for relative in ("scripts/auth.json", "scripts/session.jsonl", "scripts/memory.sqlite",
                         "scripts/.engram-native-attempt-123/probe.txt", "scripts/__pycache__/runner.pyc"):
            with self.subTest(relative=relative):
                path = self.write(relative, "private state")
                with self.assertRaisesRegex(ValueError, "private/state"):
                    self.build()
                path.unlink()
                while path.parent != self.source / "scripts" and path.parent.is_dir():
                    path.parent.rmdir()
                    path = path.parent

    def test_private_paths_and_actual_credentials_fail(self):
        for value in ("/Users/someone/localdev/build/receipt.json", "/home/worker/.codex/auth.json",
                      "C:\\Users\\someone\\config", "sk-proj-" + "x" * 30,
                      "-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----"):
            with self.subTest(value=value[:25]):
                self.write("PROVENANCE.json", json.dumps({"private": value}))
                with self.assertRaisesRegex(ValueError, "private absolute path|credential material"):
                    self.build()

    def test_secret_matcher_source_code_is_not_a_secret(self):
        self.write("scripts/codex_learner/transcript.py", 'PATTERN = r"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----"\n')
        self.build()

    def test_unqualified_personal_notes_are_not_shipped(self):
        self.write("scripts/private-receiving-notes.md", "A personal handoff without any credential pattern.\n")
        with self.assertRaisesRegex(ValueError, "unexpected plugin source files"):
            self.build()

    def test_links_cannot_escape_source_or_resources(self):
        resource = self.cli / "SwiftLM_SwiftLM.bundle/qwen_tokenizer.json"
        resource.unlink()
        resource.symlink_to(self.source / "README.md")
        with self.assertRaisesRegex(ValueError, "links/special"):
            self.build()

    def test_manifest_version_must_match_cache_release_version(self):
        self.manifest["version"] = "0.1.0+personal"
        self.write(".codex-plugin/plugin.json", json.dumps(self.manifest))
        with self.assertRaisesRegex(ValueError, "name/version"):
            self.build()

    def test_missing_skill_and_hook_fail(self):
        skill = self.source / "skills/recall/SKILL.md"
        content = skill.read_bytes()
        skill.unlink()
        with self.assertRaisesRegex(ValueError, "missing plugin source"):
            self.build()
        skill.write_bytes(content)
        hooks = json.loads((self.source / "hooks/hooks.json").read_text())
        del hooks["hooks"]["Stop"]
        self.write("hooks/hooks.json", json.dumps(hooks))
        with self.assertRaisesRegex(ValueError, "nine release"):
            self.build()

    def test_changed_icon_rejected_by_provenance(self):
        self.write("assets/engram.png", b"\x89PNG\r\n\x1a\nreplacement")
        with self.assertRaisesRegex(ValueError, "app-icon provenance"):
            self.build()

    def test_refuses_overwrite_or_outputs_inside_source(self):
        self.build()
        with self.assertRaisesRegex(ValueError, "overwrite"):
            self.build()
        with self.assertRaisesRegex(ValueError, "outside input"):
            self.build("second", output=self.source / "package.tar.gz")

    def test_unrelated_cli_products_are_not_shipped(self):
        (self.cli / "memory-sync").write_text("not the MCP")
        (self.cli / "codex").mkdir()
        (self.cli / "codex/install.sh").write_text("not plugin input")
        manifest = self.build()
        self.assertNotIn("bin/memory-sync", {record["path"] for record in manifest["files"]})
        self.assertFalse(any("install.sh" in record["path"] for record in manifest["files"]))

    def race_exclusive_open(self, filename):
        target = self.root / "first" / filename
        original_open = Path.open

        def racing_open(path, mode="r", *args, **kwargs):
            if path == target and mode == "xb":
                with original_open(path, "wb") as other_actor:
                    other_actor.write(b"owned by another actor")
            return original_open(path, mode, *args, **kwargs)

        with patch.object(Path, "open", racing_open):
            with self.assertRaises(FileExistsError):
                self.build()
        self.assertEqual(target.read_bytes(), b"owned by another actor")
        return target

    def test_archive_exclusive_open_race_preserves_unowned_file(self):
        self.race_exclusive_open("engram-codex-plugin-macos-arm64.tar.gz")
        self.assertFalse((self.root / "first/engram-codex-plugin-manifest.json").exists())

    def test_manifest_exclusive_open_race_preserves_unowned_file(self):
        self.race_exclusive_open("engram-codex-plugin-manifest.json")
        self.assertFalse((self.root / "first/engram-codex-plugin-macos-arm64.tar.gz").exists())

    def test_cleanup_preserves_replaced_archive_identity(self):
        target = self.root / "first/engram-codex-plugin-macos-arm64.tar.gz"

        def replace_archive(raw, files):
            raw.write(b"owned partial archive")
            target.unlink()
            target.write_bytes(b"replacement archive")
            raise RuntimeError("injected archive failure")

        with patch.object(packager, "write_archive", replace_archive):
            with self.assertRaisesRegex(RuntimeError, "injected archive failure"):
                self.build()
        self.assertEqual(target.read_bytes(), b"replacement archive")

    def test_cleanup_preserves_replaced_manifest_identity(self):
        target = self.root / "first/engram-codex-plugin-manifest.json"
        original_json = packager.json_bytes

        def replace_manifest(value):
            if "archive" in value:
                target.unlink()
                target.write_bytes(b"replacement manifest")
                raise RuntimeError("injected manifest failure")
            return original_json(value)

        with patch.object(packager, "json_bytes", replace_manifest):
            with self.assertRaisesRegex(RuntimeError, "injected manifest failure"):
                self.build()
        self.assertEqual(target.read_bytes(), b"replacement manifest")
        self.assertFalse((self.root / "first/engram-codex-plugin-macos-arm64.tar.gz").exists())

    def test_cleanup_removes_own_partial_archive(self):
        def fail_archive(raw, files):
            raw.write(b"owned partial archive")
            raise RuntimeError("injected archive failure")

        with patch.object(packager, "write_archive", fail_archive):
            with self.assertRaisesRegex(RuntimeError, "injected archive failure"):
                self.build()
        self.assertFalse((self.root / "first/engram-codex-plugin-macos-arm64.tar.gz").exists())
        self.assertFalse((self.root / "first/engram-codex-plugin-manifest.json").exists())


if __name__ == "__main__":
    unittest.main()
