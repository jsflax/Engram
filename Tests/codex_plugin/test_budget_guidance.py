"""Synthetic prompt/transport tests with no provider or native child."""
import contextlib
import ctypes
import importlib
import importlib.util
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import sys
import tempfile
import types
import unittest

from suite_support import PLUGIN_ROOT, REPOSITORY_ROOT, TEMP_ROOT
from unittest import mock

SOURCE = PLUGIN_ROOT / "scripts/codex_learner"
BASE = SOURCE
PACKAGE = "_budget_guidance_under_test"
STACK = None
GUARDS = []
RUNNER = None


def forbidden(*args, **kwargs):
    raise AssertionError("Real process/native/network/database operation forbidden")


def setUpModule():
    global STACK, RUNNER
    STACK = contextlib.ExitStack()
    for obj, names in ((subprocess, ("Popen", "run", "call", "check_call", "check_output")),
                       (os, ("system", "fork", "forkpty", "posix_spawn", "posix_spawnp", "kill", "killpg",
                             "spawnl", "spawnle", "spawnlp", "spawnlpe", "spawnv", "spawnve", "spawnvp", "spawnvpe")),
                       (socket, ("socket", "create_connection")), (sqlite3, ("connect",)),
                       (ctypes, ("CDLL", "PyDLL"))):
        for name in names:
            if hasattr(obj, name):
                GUARDS.append(STACK.enter_context(mock.patch.object(obj, name, side_effect=forbidden)))
    STACK.enter_context(mock.patch.object(sys, "dont_write_bytecode", True))
    spec = importlib.util.spec_from_file_location(PACKAGE, BASE / "__init__.py",
                                                submodule_search_locations=[str(SOURCE), str(BASE)])
    module = importlib.util.module_from_spec(spec)
    sys.modules[PACKAGE] = module
    spec.loader.exec_module(module)
    RUNNER = importlib.import_module(PACKAGE + ".runner")


def tearDownModule():
    try:
        for guard in GUARDS:
            if guard.call_count:
                raise AssertionError("A forbidden real-effect path was attempted")
    finally:
        for name in list(sys.modules):
            if name == PACKAGE or name.startswith(PACKAGE + "."):
                del sys.modules[name]
        STACK.close()


class BudgetGuidanceTests(unittest.TestCase):
    def render(self, calls, writes):
        return RUNNER.render_learner_prompt((SOURCE / "learner_prompt.md").read_text(),
                                            {"max_tool_calls": calls, "max_writes": writes})

    def test_operational_four_total_one_write_guidance(self):
        result = self.render(4, 1)
        self.assertIn("4 total memory tool-call attempts, including ALL reads and writes", result)
        self.assertIn("at most 1 write attempts", result)
        self.assertIn("reserve 1 total-call slots", result)
        self.assertIn("at most 3 read attempts", result)
        self.assertIn("do not attempt another write", result)
        self.assertIn("Failed or denied attempts still consume the total budget", result)
        self.assertNotIn("3 recall calls and 5", result)
        self.assertNotIn("{{RUN_TOOL_BUDGET}}", result)

    def test_custom_budget_reserves_write_capacity_without_separate_read_allowance(self):
        result = self.render(6, 2)
        self.assertIn("6 total memory tool-call attempts", result)
        self.assertIn("at most 2 write attempts", result)
        self.assertIn("reserve 2 total-call slots", result)
        self.assertIn("at most 4 read attempts", result)
        self.assertIn("These are limits, not quotas", result)

    def test_one_call_and_large_write_cap_does_not_promise_a_write(self):
        result = self.render(1, 5)
        self.assertIn("1 total memory tool-call attempts", result)
        self.assertIn("Within that total, at most 5 write attempts", result)
        self.assertIn("no subsequent write fits the budget", result)
        self.assertIn("report failed rather than exceeding", result)
        self.assertNotIn("reserve 5", result)

    def test_write_cap_larger_than_total_reserves_only_feasible_capacity(self):
        result = self.render(3, 5)
        self.assertIn("3 total memory tool-call attempts", result)
        self.assertIn("reserve 2 total-call slots", result)
        self.assertIn("at most 1 read attempts", result)

    def test_package_fallback_defaults_remain_twelve_total_five_writes(self):
        self.assertEqual((RUNNER.DEFAULTS["max_tool_calls"], RUNNER.DEFAULTS["max_writes"]), (12, 5))
        result = self.render(12, 5)
        self.assertIn("12 total memory tool-call attempts", result)
        self.assertIn("reserve 5 total-call slots", result)
        self.assertIn("at most 7 read attempts", result)

    def test_missing_or_repeated_template_marker_refuses_instead_of_stale_guidance(self):
        config = {"max_tool_calls": 4, "max_writes": 1}
        for template in ("stale template", "{{RUN_TOOL_BUDGET}} {{RUN_TOOL_BUDGET}}"):
            with self.subTest(template=template), self.assertRaisesRegex(ValueError, "prompt_budget_marker"):
                RUNNER.render_learner_prompt(template, config)

    def test_invalid_unnormalized_limits_refuse(self):
        for calls, writes in ((0, 1), (21, 1), (4, 0), (4, 6), (True, 1), (4, 1.5)):
            with self.subTest(calls=calls, writes=writes), self.assertRaisesRegex(ValueError, "invalid_prompt_tool_budget"):
                self.render(calls, writes)

    def test_render_does_not_mutate_config_or_other_instructions(self):
        template = "Before\n{{RUN_TOOL_BUDGET}}\nAfter"
        config = {"max_tool_calls": 4, "max_writes": 1, "retry_seconds": 3600}
        before = dict(config)
        rendered = RUNNER.render_learner_prompt(template, config)
        self.assertEqual(config, before)
        self.assertTrue(rendered.startswith("Before\nHard budget"))
        self.assertTrue(rendered.endswith("\nAfter"))

    def test_real_composition_uses_same_normalized_limits_as_proxy_transport(self):
        # Exercise actual run_codex composition and learner_command. Popen is an
        # explicit in-process test double; no executable is launched or probed.
        for values in ({"max_tool_calls": 4, "max_writes": 1},
                       {"max_tool_calls": 6, "max_writes": 2},
                       {"max_tool_calls": 1, "max_writes": 5}, {}):
            with self.subTest(values=values), tempfile.TemporaryDirectory() as temp:
                root = Path(temp).resolve()
                (root / "settings.json").write_text(json.dumps({"codex_bin": "/not-executed/codex", **values}))
                (root / "config.toml").write_text('[mcp_servers.memory]\ncommand="/not-executed/memory"\ndefault_tools_approval_mode="approve"\n')
                config = RUNNER.settings(root)
                run = root / "run"; run.mkdir()
                captured = []

                class CompletedSyntheticChild:
                    returncode = 0

                    def __init__(self, argv, **kwargs):
                        captured.append(kwargs["stdin"].read().decode())
                        kwargs["stdout"].write(b'{"type":"turn.completed"}\n')
                        kwargs["stdout"].flush()

                    def poll(self):
                        return 0

                    def wait(self, timeout=None):
                        return 0

                excerpt = types.SimpleNamespace(next_offset=123, text="SYNTHETIC {{RUN_TOOL_BUDGET}} EXCERPT")
                request = {"session_id": "synthetic", "cwd": str(root), "event": "Stop"}
                with mock.patch.dict(os.environ, {"CODEX_HOME": str(root)}), mock.patch.object(
                        RUNNER.subprocess, "Popen", CompletedSyntheticChild):
                    RUNNER.run_codex(root, run, request, excerpt, config)
                transport = json.loads((run / "transport.json").read_text())
                self.assertEqual(transport["max_tool_calls"], config["max_tool_calls"])
                self.assertEqual(transport["max_writes"], config["max_writes"])
                self.assertEqual(len(captured), 1)
                instructions, body = captured[0].split("<untrusted_visible_session_excerpt>", 1)
                self.assertIn(f'{transport["max_tool_calls"]} total memory tool-call attempts', instructions)
                self.assertIn(f'at most {transport["max_writes"]} write attempts', instructions)
                self.assertNotIn("{{RUN_TOOL_BUDGET}}", instructions)
                self.assertIn("SYNTHETIC {{RUN_TOOL_BUDGET}} EXCERPT", body)
                self.assertFalse((run / "prompt.txt").exists())


if __name__ == "__main__":
    unittest.main()
