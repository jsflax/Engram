"""Read-only policy regressions using owned fixtures; never launch memory/Codex."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

from suite_support import PLUGIN_ROOT, REPOSITORY_ROOT, TEMP_ROOT
from unittest import mock


HERE = Path(__file__).resolve().parent
STAGE = PLUGIN_ROOT
SPEC = importlib.util.spec_from_file_location(
    "engram_release_memory_policy", STAGE / "scripts/codex_learner/memory_config.py")
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)


class MemoryPolicyTests(unittest.TestCase):
    def setUp(self):
        scratch = TEMP_ROOT
        scratch.mkdir(exist_ok=True)
        tmp = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.config = self.root / "codex/config.toml"
        self.config.parent.mkdir()
        for target in ("subprocess.Popen", "socket.socket", "sqlite3.connect"):
            guard = mock.patch(target, side_effect=AssertionError("external access forbidden"))
            guard.start()
            self.addCleanup(guard.stop)

    def package(self, marketplace=None, *, name="engram", version="1.2.3"):
        if marketplace is None:
            root = self.root / "source" / name
        else:
            root = self.config.parent / "plugins/cache" / marketplace / name / version
        (root / ".codex-plugin").mkdir(parents=True)
        (root / ".codex-plugin/plugin.json").write_text(json.dumps({
            "name": name, "version": version}))
        (root / ".mcp.json").write_text(json.dumps({"mcpServers": {"memory": {
            "command": "./bin/memory", "cwd": ".", "env_vars": ["HOME"],
            "default_tools_approval_mode": "auto",
            "tools": {"recall": {"approval_mode": "approve"},
                      "remember": {"approval_mode": "approve"}}}}}))
        return root

    def resolve(self, root, *entries, prefix=""):
        text = prefix + "\n"
        for identity, policy in entries:
            text += "[plugins." + json.dumps(identity) + "]\n" + policy + "\n"
        self.config.write_text(text)
        return POLICY.resolve(self.config, root)[1]

    def assert_error(self, reason, root, *entries, **kwargs):
        with self.assertRaisesRegex(ValueError, "^" + reason + "$"):
            self.resolve(root, *entries, **kwargs)

    def test_personal_and_team_cache_names_use_their_own_policy(self):
        for marketplace in ("personal", "engram-team", "Team_2026"):
            with self.subTest(marketplace=marketplace):
                root = self.package(marketplace)
                memory = self.resolve(root, ("engram@" + marketplace, "enabled = true"))
                self.assertEqual(memory["command"], str(root / "bin/memory"))
                self.assertEqual(memory["cwd"], str(root))
                self.assertEqual(POLICY.allowed_tools(memory, {"recall", "remember", "delete"}),
                                 {"recall", "remember"})

    def test_cache_identity_disambiguates_policies_without_merging(self):
        root = self.package("team")
        memory = self.resolve(root, ("engram@personal", "enabled = false"),
                              ("engram@team", 'enabled = true\n'
                               '[plugins."engram@team".mcp_servers.memory]\n'
                               'disabled_tools = ["remember"]'))
        self.assertEqual(POLICY.allowed_tools(memory, {"recall", "remember"}), {"recall"})

    def test_disabled_bound_identity_cannot_fall_through_to_another_marketplace(self):
        root = self.package("personal")
        self.assert_error("memory_plugin_disabled", root,
                          ("engram@personal", "enabled = false"),
                          ("engram@team", "enabled = true"))

    def test_missing_bound_identity_cannot_use_another_marketplace(self):
        root = self.package("team")
        self.assert_error("memory_plugin_disabled", root,
                          ("engram@personal", "enabled = true"))

    def test_source_package_uses_unique_matching_identity(self):
        root = self.package()
        memory = self.resolve(root, ("other@personal", "enabled = true"),
                              ("engram@colleagues", "enabled = true"))
        self.assertTrue(memory["enabled"])
        self.assertEqual(memory["command"], str(root / "bin/memory"))

    def test_source_rejects_multiple_identities_even_when_one_is_disabled(self):
        root = self.package()
        for enabled in ("true", "false"):
            with self.subTest(enabled=enabled):
                self.assert_error("memory_plugin_identity_ambiguous", root,
                                  ("engram@personal", "enabled = " + enabled),
                                  ("engram@team", "enabled = true"))

    def test_source_disabled_identity_is_not_ignored(self):
        self.assert_error("memory_plugin_disabled", self.package(),
                          ("engram@team", "enabled = false"))

    def test_no_matching_identity_is_disabled(self):
        self.assert_error("memory_plugin_disabled", self.package(),
                          ("engram-other@personal", "enabled = true"))

    def test_malformed_matching_identity_is_rejected(self):
        root = self.package()
        for identity in ("engram", "engram@", "engram@../team", "engram@team@other"):
            with self.subTest(identity=identity):
                self.assert_error("memory_plugin_identity_invalid", root,
                                  (identity, "enabled = true"))

    def test_manifest_name_and_version_must_match_cache(self):
        root = self.package("team")
        manifest = root / ".codex-plugin/plugin.json"
        for value in ({"name": "other", "version": "1.2.3"},
                      {"name": "engram", "version": "1.2.4"}):
            with self.subTest(value=value):
                manifest.write_text(json.dumps(value))
                self.assert_error("memory_plugin_identity_invalid", root,
                                  ("engram@team", "enabled = true"))

    def test_malformed_manifest_is_not_used_to_guess_policy(self):
        root = self.package()
        manifest = root / ".codex-plugin/plugin.json"
        for raw in ('{"name":"engram","name":"other","version":"1.2.3"}',
                    '{"name":"engram","version":3}',
                    '{"name":"engram","version":"../outside"}',
                    '{"name":"engram/bad","version":"1.2.3"}', '[]', '{'):
            with self.subTest(raw=raw):
                manifest.write_text(raw)
                with self.assertRaises(ValueError):
                    self.resolve(root, ("engram@team", "enabled = true"))

    def test_missing_manifest_never_falls_back_to_a_hardcoded_identity(self):
        root = self.package()
        (root / ".codex-plugin/plugin.json").unlink()
        with self.assertRaises(OSError):
            self.resolve(root, ("engram@personal", "enabled = true"))

    def test_symlink_manifest_is_rejected(self):
        root = self.package()
        manifest = root / ".codex-plugin/plugin.json"
        target = self.root / "external-manifest.json"
        manifest.rename(target)
        manifest.symlink_to(target)
        with self.assertRaises(OSError):
            self.resolve(root, ("engram@team", "enabled = true"))

    def test_cache_alias_resolves_to_original_disabled_namespace(self):
        root = self.package("personal")
        alias = self.root / "source-alias"
        alias.symlink_to(root, target_is_directory=True)
        self.assert_error("memory_plugin_disabled", alias,
                          ("engram@personal", "enabled = false"),
                          ("engram@team", "enabled = true"))

    def test_bad_cache_shape_cannot_fall_back_to_unique_config(self):
        root = self.package("team")
        nested = root / "nested"
        nested.mkdir()
        (root / ".codex-plugin").rename(nested / ".codex-plugin")
        (root / ".mcp.json").rename(nested / ".mcp.json")
        self.assert_error("memory_plugin_identity_invalid", nested,
                          ("engram@team", "enabled = true"))

    def test_explicit_global_disabled_memory_wins_without_plugin_files(self):
        root = self.root / "absent-package"
        memory = self.resolve(root, ("engram@team", "enabled = true"), prefix=
                              '[mcp_servers.memory]\ncommand = "/fixture/memory"\n'
                              'enabled = false\ndefault_tools_approval_mode = "approve"\n')
        self.assertFalse(memory["enabled"])
        self.assertEqual(POLICY.allowed_tools(memory, {"recall", "remember"}), set())
        self.assertEqual(memory["command"], "/fixture/memory")

    def test_global_memory_remains_usable_when_plugins_feature_is_disabled(self):
        memory = self.resolve(self.root / "absent-package", prefix=
                              '[features]\nplugins = false\n[mcp_servers.memory]\n'
                              'command = "/fixture/global"\n'
                              'default_tools_approval_mode = "approve"\n')
        self.assertEqual(POLICY.allowed_tools(memory, {"recall"}), {"recall"})

    def test_disabled_plugins_feature_and_non_boolean_policy_fail_closed(self):
        root = self.package("team")
        self.assert_error("memory_plugin_disabled", root,
                          ("engram@team", "enabled = true"), prefix='[features]\nplugins = false\n')
        self.assert_error("memory_config_invalid", root,
                          ("engram@team", 'enabled = "true"'))

    def test_team_server_disable_and_tool_budget_overlay_remain_effective(self):
        root = self.package("team")
        policy = ('enabled = true\n[plugins."engram@team".mcp_servers.memory]\n'
                  'enabled = false\ndefault_tools_approval_mode = "approve"')
        memory = self.resolve(root, ("engram@team", policy))
        self.assertEqual(POLICY.allowed_tools(memory, {"recall", "remember"}), set())
        policy = ('enabled = true\n[plugins."engram@team".mcp_servers.memory]\n'
                  'enabled_tools = ["recall"]\n'
                  '[plugins."engram@team".mcp_servers.memory.tools.recall]\n'
                  'approval_mode = "prompt"\noutput_token_limit = 24')
        memory = self.resolve(root, ("engram@team", policy))
        self.assertEqual(POLICY.allowed_tools(memory, {"recall", "remember"}), set())
        self.assertEqual(memory["tools"]["recall"]["output_token_limit"], 24)

    def test_malformed_toml_and_duplicate_plugin_entries_fail_closed(self):
        root = self.package("team")
        with self.assertRaises(ValueError):
            self.resolve(root, ("engram@team", "enabled = true"),
                         ("engram@team", "enabled = false"))
        with self.assertRaises(ValueError):
            self.resolve(root, prefix="plugins = [")


if __name__ == "__main__":
    unittest.main(verbosity=2)
