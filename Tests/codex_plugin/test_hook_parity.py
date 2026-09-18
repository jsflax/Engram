import hashlib
import json
import os
import re
from pathlib import Path
import sys
import tempfile
import time
import unittest

from suite_support import PLUGIN_ROOT, REPOSITORY_ROOT, TEMP_ROOT
from unittest import mock

HERE = PLUGIN_ROOT
sys.path.insert(0, str(HERE / "scripts"))
import recall_hook as recall
import lifecycle_hook as lifecycle

MEMORY_ID = "00000000-0000-4000-8000-000000000001"


class HookParityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fixture-", dir=TEMP_ROOT)
        self.base = Path(self.temp.name)
        self.root = self.base / "lifecycle"
        self.recall_root = self.base / "recall"
        self.project = self.base / "Example"
        self.project.mkdir()
        (self.project / ".git").mkdir()
        self.config = {"schema_version": 1, "state_dir": str(self.root),
                       "recall_config": str(self.base / "recall.json"), "nudges": True}
        Path(self.config["recall_config"]).write_text(json.dumps({
            "state_dir": str(self.recall_root), "projects": {}, "semantic_recall": True,
            "infer_project": True, "prompt_recall": True, "cooldown_seconds": 0.1}))
        self.env = mock.patch.dict(os.environ, {}, clear=True)
        self.env.start()
        # No test may start native memory, an actual provider, or any subprocess.
        self.spawn_guard = mock.patch("subprocess.Popen", side_effect=AssertionError("unexpected child process"))
        self.spawn_guard.start()
        recall._cancelled = False

    def tearDown(self):
        self.spawn_guard.stop()
        self.env.stop()
        self.temp.cleanup()

    def payload(self, event="PreToolUse", index=1, **kw):
        return {"hook_event_name": event, "session_id": "fixture-session", "turn_id": "fixture-turn",
                "cwd": str(self.project), "tool_name": "spawn_agent", "tool_use_id": f"call-{index}",
                "tool_input": {"message": "Find prior rendering decisions"}, **kw}

    def run_lifecycle(self, payload, output=None):
        fake = mock.Mock(return_value=output or {})
        result = lifecycle.dispatch(self.config, payload, time.monotonic(), recall_call=fake)
        return result, fake

    def receipts(self):
        return [json.loads(line) for line in (self.root / "receipts.jsonl").read_text().splitlines()]

    def run_recall(self, payload):
        calls = []
        class FakeClient:
            def __init__(self, config, deadline):
                pass
            def initialize(self):
                pass
            def call(self, request_id, name, arguments):
                calls.append((name, arguments))
                return f"[id:{MEMORY_ID}] [Example/architecture]\nUse explicit ownership."
            def close(self):
                pass
        config = recall.config_at(Path(self.config["recall_config"]))
        root = lifecycle.private_root(config["state_dir"])
        audit = {}
        with mock.patch.object(recall, "check_policy") as policy, mock.patch.object(recall, "Client", FakeClient):
            result = recall.execute(config, payload, time.monotonic(), root, audit)
        return result, calls, audit, policy

    def test_pretool_emits_real_event_and_task_query(self):
        result, calls, _, policy = self.run_recall(self.payload())
        self.assertEqual(result["hookSpecificOutput"]["hookEventName"], "PreToolUse")
        self.assertEqual(calls, [("recall", {"query": "Find prior rendering decisions", "limit": 3, "depth": 0, "project": "Example"})])
        policy.assert_called_once()

    def test_observed_collaboration_tool_name_recalls_without_alias(self):
        payload = self.payload(tool_name="collaborationspawn_agent")
        result, calls, _, _ = self.run_recall(payload)
        self.assertEqual(result["hookSpecificOutput"]["hookEventName"], "PreToolUse")
        self.assertEqual(calls[0][1]["query"], payload["tool_input"]["message"])
        output, fake = self.run_lifecycle(payload, result)
        fake.assert_called_once_with(self.config["recall_config"], payload, mock.ANY)
        self.assertIn(MEMORY_ID, output["hookSpecificOutput"]["additionalContext"])

    def test_agent_matcher_and_handler_agree_on_exact_names(self):
        definition = json.loads((HERE / "hooks/hooks.json").read_text())
        matcher = definition["hooks"]["PreToolUse"][0]["matcher"]
        for name in recall.AGENT_TOOL_NAMES:
            self.assertIsNotNone(re.fullmatch(matcher, name))
            self.assertEqual(recall.agent_query(self.payload(tool_name=name)), "Find prior rendering decisions")
        for name in ("unrelatedspawn_agent", "mcp__collaborationspawn_agent", "collaborationspawn_agent_extra"):
            self.assertIsNone(re.fullmatch(matcher, name))
            with self.assertRaisesRegex(recall.Failure, "tool_not_agent"):
                recall.agent_query(self.payload(tool_name=name))

    def test_claude_description_precedes_prompt(self):
        payload = self.payload(tool_name="Agent", tool_input={"description": "description", "prompt": "prompt"})
        self.assertEqual(recall.agent_query(payload), "description")

    def test_task_query_is_bounded(self):
        self.assertEqual(len(recall.agent_query(self.payload(tool_input={"message": "x" * 8000}))), 4096)

    def test_session_start_semantic_recall_no_fixed_pin(self):
        result, calls, _, _ = self.run_recall(self.payload("SessionStart", source="startup"))
        self.assertEqual(calls[0][0], "recall")
        self.assertIn("Example project overview", calls[0][1]["query"])
        self.assertIn(MEMORY_ID, result["hookSpecificOutput"]["additionalContext"])

    def test_subagent_start_semantic_recall(self):
        _, calls, _, _ = self.run_recall(self.payload("SubagentStart", agent_id="child", agent_type="research"))
        self.assertTrue(calls[0][1]["query"].endswith("research"))

    def test_prompt_recall_preserved(self):
        _, calls, _, _ = self.run_recall(self.payload("UserPromptSubmit", prompt="user query"))
        self.assertEqual(calls[0][1]["query"], "user query")

    def test_project_explicit_mapping_and_repository_inference(self):
        config = recall.config_at(Path(self.config["recall_config"]))
        nested = self.project / "src"
        nested.mkdir()
        self.assertEqual(recall.project_for(config, {"cwd": str(nested)}), "Example")
        config["projects"][str(nested)] = "ActualProject"
        self.assertEqual(recall.project_for(config, {"cwd": str(nested)}), "ActualProject")

    def test_recall_filters_unrelated_projects_but_keeps_global(self):
        other = "00000000-0000-4000-8000-000000000002"
        raw = f"[id:{MEMORY_ID}] [Other/topic]\nWrong project\n[id:{other}] [global/preferences]\nShared preference"
        self.assertEqual([v[0] for v in recall.blocks(raw, project="Example")], [other])

    def test_inferred_relevance_keeps_cross_project_provenance(self):
        raw = f"[id:{MEMORY_ID}] [Orbital/architecture]\nUseful rendering decision"
        items = recall.blocks(raw, project="orbital-director", allow_other_projects=True)
        self.assertEqual(items, [(MEMORY_ID, "Project/topic: Orbital/architecture\nUseful rendering decision")])
        rendered, ids = recall.render(items, 6000)
        self.assertEqual(ids, [MEMORY_ID])
        self.assertIn("untrusted data", rendered)
        self.assertIn("    Project/topic: Orbital/architecture", rendered)

    def test_host_relevance_option_only_loosens_inferred_project(self):
        path = Path(self.config["recall_config"])
        config = json.loads(path.read_text())
        config["relevant_project_recall"] = True
        config["projects"] = {str(self.project): "StrictMappedProject"}
        path.write_text(json.dumps(config))
        result, _, audit, _ = self.run_recall(self.payload())
        self.assertEqual(result, {})  # Fake returns Example; explicit mapping rejects it.
        self.assertEqual(audit["project_filter"], "exact_and_global")
        (self.recall_root / "state.json").unlink()
        config["projects"] = {}
        path.write_text(json.dumps(config))
        result, _, audit, _ = self.run_recall(self.payload(index=2))
        self.assertIn("Project/topic: Example/architecture", result["hookSpecificOutput"]["additionalContext"])
        self.assertEqual(audit["project_filter"], "semantic_relevance")

    def test_relevance_option_does_not_disable_bounds(self):
        records = [f"[id:00000000-0000-4000-8000-{n:012d}] [Other/topic]\ntext" for n in range(4)]
        with self.assertRaisesRegex(recall.Failure, "protocol"):
            recall.blocks("\n".join(records), project="Example", allow_other_projects=True)

    def test_tool_query_requires_real_agent_tool(self):
        with self.assertRaisesRegex(recall.Failure, "tool_not_agent"):
            recall.agent_query(self.payload(tool_name="Bash"))

    def test_internal_agent_exclusions(self):
        for kind in recall.INTERNAL_AGENTS:
            with self.subTest(kind=kind):
                result, fake = self.run_lifecycle(self.payload(tool_input={"agent_type": kind, "message": "private"}))
                self.assertEqual(result, {})
                fake.assert_not_called()
        self.assertFalse((self.root / "state.json").exists())

    def test_recursion_environment_guards(self):
        for key in recall.RECURSION_ENV:
            with self.subTest(key=key), mock.patch.dict(os.environ, {key: ""}):
                result, fake = self.run_lifecycle(self.payload())
                self.assertEqual(result, {})
                fake.assert_not_called()

    def test_mcp_failure_only_classifies_explicit_result(self):
        self.assertEqual(lifecycle.failure_kind(self.payload("PostToolUse", tool_name="mcp__memory__recall", tool_response={"isError": True})), "mcp_error")
        self.assertEqual(lifecycle.failure_kind(self.payload("PostToolUse", tool_name="mcp__memory__recall", tool_response={"content": []})), "success")

    def test_nonzero_bash_exit(self):
        self.assertEqual(lifecycle.failure_kind(self.payload("PostToolUse", tool_name="Bash", tool_response={"exit_code": 2})), "nonzero_exit")
        self.assertEqual(lifecycle.failure_kind(self.payload("PostToolUse", tool_name="Bash", tool_response={"exit_code": 0})), "success")
        self.assertEqual(lifecycle.failure_kind(self.payload("PostToolUse", tool_name="Bash", tool_response={"exit_code": True})), "unknown")

    def test_arbitrary_text_does_not_trigger_failure(self):
        result, fake = self.run_lifecycle(self.payload("PostToolUse", tool_name="Bash", tool_response="error: Process exited with code 1"))
        self.assertEqual(result, {})
        fake.assert_not_called()
        self.assertEqual(self.receipts()[-1]["status"], "unclassified_ignored")
        self.assertFalse((self.root / "state.json").exists())

    def test_successful_tool_does_not_count_or_recall(self):
        result, fake = self.run_lifecycle(self.payload("PostToolUse", tool_name="Bash", tool_response={"exit_code": 0}))
        self.assertEqual(result, {})
        fake.assert_not_called()
        self.assertFalse((self.root / "state.json").exists())

    def test_nudge_matches_first_15_then_every_30_participating_calls(self):
        emitted = []
        for index in range(1, 46):
            event = "PreToolUse" if index % 2 else "PostToolUse"
            kwargs = {} if index % 2 else {"tool_name": "Bash", "tool_response": {"exit_code": 1}}
            result, _ = self.run_lifecycle(self.payload(event, index, **kwargs))
            if result:
                emitted.append(index)
                self.assertEqual(set(result), {"hookSpecificOutput"})
                self.assertEqual(result["hookSpecificOutput"]["hookEventName"], event)
                self.assertIn("Do not spawn a duplicate", result["hookSpecificOutput"]["additionalContext"])
        self.assertEqual(emitted, [15, 45])

    def test_nudge_merges_without_losing_recall_context(self):
        for index in range(1, 15):
            self.run_lifecycle(self.payload(index=index))
        output = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": "stored context"}}
        result, _ = self.run_lifecycle(self.payload(index=15), output)
        self.assertTrue(result["hookSpecificOutput"]["additionalContext"].startswith("stored context\n\n"))

    def test_replayed_tool_does_not_advance_nudge_counter(self):
        for _ in range(20):
            self.assertEqual(self.run_lifecycle(self.payload())[0], {})
        state = json.loads((self.root / "state.json").read_text())
        self.assertEqual(next(iter(state["sessions"].values()))["count"], 1)

    def test_orchestrator_suppresses_nudge_but_preserves_recall(self):
        with mock.patch.dict(os.environ, {"ENGRAM_LEARNER_ORCHESTRATED": "1"}):
            _, fake = self.run_lifecycle(self.payload())
            fake.assert_called_once()
        self.assertFalse((self.root / "state.json").exists())

    def test_session_end_only_cleans_own_ephemeral_counter(self):
        self.run_lifecycle(self.payload())
        self.run_lifecycle(self.payload(session_id="other-session"))
        marker = self.root / "cursor.json"
        marker.write_text("keep learner progress")
        result, fake = self.run_lifecycle(self.payload("SessionEnd"))
        self.assertEqual(result, {})
        fake.assert_not_called()
        state = json.loads((self.root / "state.json").read_text())
        self.assertEqual(set(state["sessions"]), {hashlib.sha256(b"other-session").hexdigest()[:20]})
        self.assertEqual(marker.read_text(), "keep learner progress")

    def test_receipts_never_contain_tool_payloads(self):
        self.run_lifecycle(self.payload("PostToolUse", tool_name="Bash", tool_response={"exit_code": 1, "output": "secret-output"}, tool_input={"command": "secret-command"}))
        text = (self.root / "receipts.jsonl").read_text()
        self.assertNotIn("secret", text)
        self.assertNotIn("fixture-session", text)

    def test_counter_state_remains_bounded_across_many_tasks(self):
        for session in range(40):
            for call in range(35):
                self.run_lifecycle(self.payload(index=call, session_id=f"task-{session}"))
        path = self.root / "state.json"
        self.assertLess(path.stat().st_size, recall.MAX_STATE)
        self.assertEqual(len(json.loads(path.read_text())["sessions"]), 20)

    def test_private_root_rejects_symlink(self):
        actual = self.base / "actual"
        actual.mkdir(mode=0o700)
        link = self.base / "link"
        link.symlink_to(actual, target_is_directory=True)
        with self.assertRaises(recall.Failure):
            lifecycle.private_root(str(link))

    def test_lifecycle_does_not_accept_unimplemented_event(self):
        result, fake = self.run_lifecycle(self.payload("PostToolUseFailure"))
        self.assertEqual(result, {})
        fake.assert_not_called()


if __name__ == "__main__":
    unittest.main()
