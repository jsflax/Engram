"""Standalone runner parity for recovered provider stream notices.

The provider is an in-process fake; no native store, network or child is opened.
The real runner still checks the independent audit and its final result.
"""
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from codex_learner import runner as R

MEMORY = "a1111111-2222-4333-8444-555555555555"
TEST_ROOT = Path(os.environ.get("ENGRAM_CI_TEST_ROOT", str(Path.home() / "localdev/engram-ci-python-fixtures")))


class ProviderNoticeTests(unittest.TestCase):
    def run_provider(self, before, after=(), *, code=0, start=True, complete=True, audit_ok=True):
        if TEST_ROOT.is_symlink():
            raise RuntimeError("unsafe test root")
        TEST_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="standalone-notices-", dir=TEST_ROOT) as directory:
            base = Path(directory)
            run = base / "run"

            def provider(_argv, **kwargs):
                R.atomic_json(run / "result.json", {"outcome": "stored", "summary": "Synthetic fact.",
                                                    "memory_ids": [MEMORY]})
                audit = [{"event": "tool_call", "id": 1, "tool": "remember"},
                         {"event": "tool_result", "id": 1, "tool": "remember", "ok": audit_ok,
                          "memory_ids": [MEMORY] if audit_ok else []}]
                (run / "mcp-audit.jsonl").write_text("".join(json.dumps(x) + "\n" for x in audit))
                events = ([{"type": "turn.started"}] if start else []) + list(before)
                events += ([{"type": "turn.completed"}] if complete else []) + list(after)
                kwargs["stdout"].write(b"".join(json.dumps(x).encode() + b"\n" for x in events))
                kwargs["stdout"].flush()
                return SimpleNamespace(pid=123456789, returncode=code, poll=lambda: code, wait=lambda **_: code)

            with mock.patch.object(R, "learner_command", return_value=["never-executed"]), \
                 mock.patch.object(R.subprocess, "Popen", side_effect=provider), \
                 mock.patch.object(R.os, "killpg", side_effect=AssertionError("no child exists")):
                return R.run_codex(base / "state", run, {"session_id": "synthetic", "event": "Stop",
                    "cwd": str(base)}, SimpleNamespace(text="Synthetic visible fact.", next_offset=42), R.DEFAULTS)

    def test_nonterminal_notices_allow_verified_completion(self):
        # Arbitrary prose deliberately avoids relying on an English retry message.
        result = self.run_provider([{"type": "error", "message": "Synthetic notice one"},
                                    {"type": "error", "message": "Synthetic notice two"}])
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(result["provider_notices"], 2)
        self.assertFalse(result["provider_error"])
        self.assertEqual(result["writes"], [{"tool": "remember", "memory_ids": [MEMORY]}])

    def test_terminal_or_unverified_outcomes_are_not_forgiven(self):
        notice = {"type": "error", "message": "Synthetic notice"}
        cases = [
            {"before": [notice, {"type": "turn.failed", "error": {"message": "Synthetic failure"}}]},
            {"before": [notice], "after": [notice]},
            {"before": [{"type": "error", "message": "Synthetic notice", "unknown": True}]},
            {"before": [{"type": "error", "message": ""}]},
            {"before": [notice], "complete": False},
            {"before": [notice], "code": 1},
            {"before": [notice], "audit_ok": False},
            {"before": [notice], "start": False},
            {"before": [notice, {"type": "turn.started"}]},
            {"before": [notice], "after": [{"type": "turn.started"}]},
            {"before": [notice], "after": [{"type": "turn.completed"}]},
            {"before": [notice], "after": [{"type": "item.started", "item": {}}]},
            {"before": [notice], "after": [{"type": "item.completed", "item": {}}]},
        ]
        for case in cases:
            with self.subTest(case=case):
                self.assertEqual(self.run_provider(**case)["status"], "failed")


if __name__ == "__main__":
    unittest.main()
