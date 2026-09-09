"""Lifecycle and provider verification tests using synthetic, local fake Codex."""

from __future__ import annotations

import json
import dataclasses
import contextlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import tomllib
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from codex_learner import runner  # noqa: E402
from codex_learner.transcript import read_excerpt  # noqa: E402


MEMORY_ID = "15efab13-e162-4329-85f4-a859e7f9a007"


def native_record(kind, payload, ordinal=None):
    item = {"timestamp": "2026-09-09T22:00:00Z", "type": kind, "payload": payload}
    if ordinal is not None:
        item["ordinal"] = ordinal
    return item


def user_message(text, ordinal=None):
    return native_record("response_item", {"type": "message", "role": "user", "content": [{"type": "input_text", "text": text}]}, ordinal)


def mcp_event(tool="recall", *, item_id="call-1", failed=False, server="memory"):
    return {
        "type": "item.completed",
        "item": {
            "id": item_id, "type": "mcp_tool_call", "server": server, "tool": tool,
            "status": "completed", "error": None,
            "result": {"isError": failed, "content": [{"type": "text", "text": MEMORY_ID if tool == "remember" else "No existing matches."}]},
        },
    }


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "state"
        self.home = self.base / "codex-home"
        self.home.mkdir()
        self.path = self.base / "rollout.jsonl"
        self.sid = "session-123"
        self.config = {**runner.DEFAULTS, "min_chars": 0, "retry_seconds": 10}
        self.env = mock.patch.dict(os.environ, {"CODEX_HOME": str(self.home)}, clear=False)
        self.env.start()
        self.addCleanup(self.env.stop)
        self.guard = mock.patch.dict(os.environ, {}, clear=False)
        self.guard.start()
        self.addCleanup(self.guard.stop)
        os.environ.pop(runner.GUARD, None)
        os.environ.pop("CLAUDE_MEMORY_LEARNER", None)
        self.write_rollout(user_message("Preserve the existing queue and collect matched controls."))
        (self.home / "config.toml").write_text(
            'model="configured-model"\nmodel_reasoning_effort="medium"\n'
            '[mcp_servers.memory]\ncommand="/tmp/engram-memory"\nargs=["mcp"]\n'
            '[mcp_servers.unrelated]\nurl="https://unrelated.invalid/mcp"\n'
        )

    def write_rollout(self, *records, meta=None, suffix=b""):
        meta = meta or native_record("session_meta", {"id": self.sid, "cwd": str(self.base), "source": "vscode"})
        content = b"".join(json.dumps(item).encode() + b"\n" for item in [meta, *records])
        self.path.write_bytes(content + suffix)
        return len(content)

    def payload(self, **extra):
        return {"hook_event_name": "Stop", "session_id": self.sid, "transcript_path": str(self.path), **extra}

    def request(self, **extra):
        return runner.validate_request(self.payload(**extra), self.root)

    def state(self):
        return runner.load_json(self.root / "sessions" / (self.sid + ".json"))

    def success(self, *args):
        return {"status": "succeeded", "write_calls": 0, "outcome": "no_new_memories"}

    @contextlib.contextmanager
    def asynchronous_workers(self):
        """Model Popen's asynchronous return without launching real learners."""
        threads = []
        errors = []

        def spawn(root):
            def execute():
                try:
                    runner.worker(root)
                except BaseException as error:
                    errors.append(error)
            thread = threading.Thread(target=execute, daemon=True)
            threads.append(thread)
            thread.start()

        with mock.patch.object(runner, "spawn_worker", side_effect=spawn):
            try:
                yield threads
            finally:
                deadline = time.monotonic() + 10
                index = 0
                while index < len(threads):
                    threads[index].join(timeout=max(0, deadline - time.monotonic()))
                    self.assertFalse(threads[index].is_alive(), "synthetic worker did not terminate")
                    index += 1
                if errors:
                    raise errors[0]

    def fake_codex(self, *, events=None, result=None, exit_code=0, delay=0, read_stdin=True, audit_events=None, write_audit=True):
        events = events if events is not None else [mcp_event(), {"type": "turn.completed"}]
        audit_events = events if audit_events is None else audit_events
        result = result if result is not None else {"outcome": "no_new_memories", "summary": "Already represented.", "memory_ids": []}
        script = self.base / "fake-codex"
        script.write_text(
            f"#!{sys.executable}\n"
            "import json,os,pathlib,re,sys,time,tomllib\n"
            f"if {read_stdin!r}: sys.stdin.buffer.read()\n"
            f"time.sleep({delay!r})\n"
            "args=sys.argv[1:]\n"
            "overrides={}\n"
            "for i,arg in enumerate(args[:-1]):\n"
            " if arg=='-c': overrides.update(tomllib.loads(args[i+1]))\n"
            "memory=overrides.get('mcp_servers',{}).get('memory',{})\n"
            "proxy_args=memory.get('args',[])\n"
            "audit_path=None\n"
            "for arg in proxy_args:\n"
            " if str(arg).endswith('transport.json'):\n"
            "  audit_path=pathlib.Path(json.loads(pathlib.Path(arg).read_text())['audit_path'])\n"
            f"events={events!r}\n"
            f"audit_events={audit_events!r}\n"
            f"if audit_path is not None and {write_audit!r}:\n"
            " audit=[]; seen=set()\n"
            " for event in audit_events:\n"
            "  item=event.get('item',{})\n"
            "  if event.get('type')!='item.completed' or item.get('type')!='mcp_tool_call' or item.get('server')!='memory': continue\n"
            "  call_id=item['id']\n"
            "  if call_id in seen: continue\n"
            "  seen.add(call_id)\n"
            "  result=item.get('result') or {}\n"
            "  text=' '.join(part.get('text','') for part in result.get('content',[]) if part.get('type')=='text')\n"
            "  ids=re.findall(r'\\b[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\\b',text)\n"
            "  audit.append({'event':'tool_call','id':call_id,'tool':item['tool']})\n"
            "  audit.append({'event':'tool_result','id':call_id,'tool':item['tool'],'ok':item.get('status')=='completed' and not item.get('error') and not result.get('isError',False),'memory_ids':ids})\n"
            " audit_path.write_text(''.join(json.dumps(item)+'\\n' for item in audit))\n"
            "result_path=pathlib.Path(args[args.index('--output-last-message')+1])\n"
            f"result_path.write_text(json.dumps({result!r}))\n"
            "for event in events: os.write(1,(json.dumps(event)+'\\n').encode())\n"
            f"sys.exit({exit_code!r})\n"
        )
        script.chmod(0o700)
        return str(script)

    def provider_run(self, **fake_options):
        config = {**self.config, "codex_bin": self.fake_codex(**fake_options)}
        run_dir = runner.private_dir(self.root / "runs" / "fixture")
        return runner.run_codex(self.root, run_dir, self.request(), read_excerpt(self.path), config)

    def test_cursor_commits_only_after_success_and_duplicate_hook_is_noop(self):
        request = self.request()
        seen = []

        def invoke(*args):
            self.assertFalse(self.state(), "cursor must not advance before learner returns")
            seen.append(args[3].text)
            return self.success()

        self.assertEqual(runner.process_request(self.root, request, self.config, invoke=invoke), "succeeded")
        self.assertEqual(self.state()["offset"], self.path.stat().st_size)
        self.assertEqual(self.state()["status"], "succeeded")
        self.assertEqual(runner.process_request(self.root, request, self.config, invoke=invoke), "no_change")
        self.assertEqual(len(seen), 1)

    def test_failure_preserves_cursor_and_dedup_state_then_backoff(self):
        request = self.request()
        fail = mock.Mock(return_value={"status": "failed", "reason": "mcp_error"})
        self.assertEqual(runner.process_request(self.root, request, self.config, invoke=fail), "failed")
        state = self.state()
        self.assertEqual(state.get("offset", 0), 0)
        self.assertNotIn("recent_messages", state)
        self.assertGreater(state["retry_after"], time.time())
        self.assertEqual(runner.process_request(self.root, request, self.config, invoke=fail), "backoff")
        self.assertEqual(fail.call_count, 1)
        state["retry_after"] = 0
        runner.atomic_json(self.root / "sessions" / (self.sid + ".json"), state)
        self.assertEqual(runner.process_request(self.root, request, self.config, invoke=self.success), "succeeded")
        self.assertEqual(self.state()["offset"], self.path.stat().st_size)

    def test_invoke_exception_becomes_failed_backoff_without_progress(self):
        fail = mock.Mock(side_effect=RuntimeError("private provider detail"))
        self.assertEqual(runner.process_request(self.root, self.request(), self.config, invoke=fail), "failed")
        self.assertEqual(self.state().get("offset", 0), 0)
        self.assertNotIn("private provider detail", (self.root / "events.jsonl").read_text())

    def test_partial_final_record_commits_only_completed_visible_prefix(self):
        encoded = json.dumps(user_message("The later decision.")).encode() + b"\n"
        boundary = self.write_rollout(user_message("The first decision."), suffix=encoded[:40])
        seen = []

        def invoke(*args):
            seen.append(args[3].text)
            return self.success()

        self.assertEqual(runner.process_request(self.root, self.request(), self.config, invoke=invoke), "more")
        self.assertEqual(self.state()["offset"], boundary)
        self.assertEqual(runner.process_request(self.root, self.request(), self.config, invoke=invoke), "blocked")
        with self.path.open("ab") as stream:
            stream.write(encoded[40:])
        self.assertEqual(runner.process_request(self.root, self.request(), self.config, invoke=invoke), "succeeded")
        self.assertEqual(len(seen), 2)
        self.assertNotIn("first decision", seen[1])
        self.assertIn("later decision", seen[1])

    def test_short_stop_defers_but_session_end_flushes(self):
        config = {**self.config, "min_chars": 1000}
        invoke = mock.Mock(side_effect=self.success)
        self.assertEqual(runner.process_request(self.root, self.request(), config, invoke=invoke), "deferred")
        self.assertFalse(self.state())
        self.assertEqual(invoke.call_count, 0)
        request = self.request(hook_event_name="SessionEnd")
        self.assertEqual(runner.process_request(self.root, request, config, invoke=invoke), "succeeded")
        self.assertEqual(invoke.call_count, 1)

    def test_bounded_batches_cover_all_messages_without_loss(self):
        self.write_rollout(*(user_message(f"Decision {i}: keep this distinct finding.") for i in range(5)))
        config = {**self.config, "max_chars": 90}
        seen = []
        request = self.request()

        def invoke(*args):
            excerpt = args[3]
            self.assertLessEqual(len(excerpt.text), 90)
            seen.append(excerpt.text)
            return self.success()

        for _ in range(6):
            outcome = runner.process_request(self.root, request, config, invoke=invoke)
            if outcome != "more":
                break
        self.assertEqual(outcome, "succeeded")
        self.assertEqual(self.state()["offset"], self.path.stat().st_size)
        for i in range(5):
            self.assertEqual("\n".join(seen).count(f"Decision {i}:"), 1)

    def test_unknown_fork_never_invokes_learner(self):
        self.write_rollout(user_message("Inherited content."), meta=native_record("session_meta", {"id": self.sid, "forked_from_id": "parent", "source": "vscode"}))
        invoke = mock.Mock(side_effect=self.success)
        self.assertEqual(runner.process_request(self.root, self.request(), self.config, invoke=invoke), "blocked")
        invoke.assert_not_called()
        self.assertFalse(self.state())

    def test_materialized_fork_uses_own_id_and_excludes_parent_content(self):
        self.write_rollout(
            user_message("Inherited content.", 2), user_message("New fork decision.", 3),
            meta=native_record("session_meta", {"id": self.sid, "session_id": "parent", "forked_from_id": "parent", "subagent_history_start_ordinal": 3, "source": "vscode"}, 0),
        )
        seen = []

        def invoke(*args):
            seen.append(args[3].text)
            self.assertEqual(args[3].metadata.parent_session_id, "parent")
            return self.success()

        self.assertEqual(runner.process_request(self.root, self.request(), self.config, invoke=invoke), "succeeded")
        self.assertNotIn("Inherited", seen[0])
        self.assertIn("New fork", seen[0])

    def test_replaced_rollout_between_enqueue_and_first_run_is_rejected(self):
        request = self.request()
        replacement = self.path.with_name("replacement.jsonl")
        replacement.write_bytes(self.path.read_bytes())
        replacement.replace(self.path)
        invoke = mock.Mock(side_effect=self.success)
        with self.assertRaisesRegex(ValueError, "replaced|identity"):
            runner.process_request(self.root, request, self.config, invoke=invoke)
        invoke.assert_not_called()

    def test_truncation_after_committed_cursor_is_rejected(self):
        request = self.request()
        runner.process_request(self.root, request, self.config, invoke=self.success)
        self.write_rollout()
        with self.assertRaisesRegex(ValueError, "truncated"):
            runner.process_request(self.root, request, self.config, invoke=self.success)

    def test_replacement_between_metadata_inspection_and_excerpt_read_rejected(self):
        request = self.request()
        excerpt = read_excerpt(self.path)
        changed = dataclasses.replace(excerpt, metadata=dataclasses.replace(excerpt.metadata, inode=excerpt.metadata.inode + 1))
        invoke = mock.Mock(side_effect=self.success)
        with mock.patch.object(runner, "read_excerpt", return_value=changed):
            with self.assertRaisesRegex(ValueError, "replaced|identity"):
                runner.process_request(self.root, request, self.config, invoke=invoke)
        invoke.assert_not_called()

    def test_recursion_guards_prevent_queue_and_worker_spawn(self):
        for guard in (runner.GUARD, "CLAUDE_MEMORY_LEARNER"):
            with self.subTest(guard=guard), mock.patch.dict(os.environ, {guard: "1"}), mock.patch.object(runner, "spawn_worker") as spawn:
                self.assertFalse(runner.enqueue(self.root, self.payload()))
                spawn.assert_not_called()
        with mock.patch.object(runner, "spawn_worker") as spawn:
            self.assertFalse(runner.enqueue(self.root, self.payload(stop_hook_active=True)))
            spawn.assert_not_called()
        self.assertFalse((self.root / "pending").exists())

    def test_session_mismatch_and_learner_source_rejected(self):
        with self.assertRaisesRegex(ValueError, "mismatch"):
            runner.validate_request(self.payload(session_id="wrong-id"), self.root)
        self.write_rollout(user_message("loop"), meta=native_record("session_meta", {"id": self.sid, "source": "engram-session-learner"}))
        with self.assertRaisesRegex(ValueError, "learner_transcript"):
            self.request()

    def test_duplicate_queued_events_preserve_final_flush_priority(self):
        self.assertTrue(runner.enqueue(self.root, self.payload(hook_event_name="SessionEnd"), spawn=False))
        self.assertTrue(runner.enqueue(self.root, self.payload(), spawn=False))
        pending = list((self.root / "pending").glob("*.json"))
        self.assertEqual(len(pending), 1)
        self.assertEqual(runner.load_json(pending[0])["event"], "SessionEnd")
        self.assertEqual(pending[0].stat().st_mode & 0o777, 0o600)

    def test_worker_caps_one_request_and_waits_for_new_source_event(self):
        runner.enqueue(self.root, self.payload(), spawn=False)
        process = mock.Mock(return_value="more")
        with mock.patch.object(runner, "process_request", process), mock.patch.object(runner, "spawn_worker") as spawn:
            self.assertEqual(runner.worker(self.root), 0)
            self.assertEqual(process.call_count, runner.DEFAULTS["max_runs_per_worker"])
            pending_path = self.root / "pending" / (self.sid + ".json")
            paused = runner.load_json(pending_path)
            self.assertEqual(paused.get("paused_request_id"), paused["request_id"])
            self.assertEqual(runner.worker(self.root), 0)
            self.assertEqual(process.call_count, runner.DEFAULTS["max_runs_per_worker"])
            spawn.assert_not_called()
            runner.enqueue(self.root, self.payload(), spawn=False)
            refreshed = runner.load_json(pending_path)
            self.assertNotEqual(refreshed["request_id"], paused["request_id"])
            self.assertNotEqual(refreshed.get("paused_request_id"), refreshed["request_id"])
            process.return_value = "succeeded"
            self.assertEqual(runner.worker(self.root), 0)
            self.assertEqual(process.call_count, runner.DEFAULTS["max_runs_per_worker"] + 1)
            self.assertFalse(pending_path.exists())

    def test_worker_pauses_failed_backoff_and_blocked_requests_without_respawn(self):
        for outcome in ("failed", "backoff", "blocked"):
            with self.subTest(outcome=outcome):
                runner.enqueue(self.root, self.payload(), spawn=False)
                process = mock.Mock(return_value=outcome)
                with mock.patch.object(runner, "process_request", process), mock.patch.object(runner, "spawn_worker") as spawn:
                    self.assertEqual(runner.worker(self.root), 0)
                    paused = runner.load_json(self.root / "pending" / (self.sid + ".json"))
                    self.assertEqual(paused.get("paused_request_id"), paused["request_id"])
                    self.assertEqual(runner.worker(self.root), 0)
                    self.assertEqual(process.call_count, 1)
                    spawn.assert_not_called()

    def test_new_request_arriving_during_processing_is_not_lost(self):
        runner.enqueue(self.root, self.payload(), spawn=False)
        seen = []

        def process(root, request, config):
            seen.append(request["request_id"])
            if len(seen) == 1:
                # The competing worker cannot acquire the active worker lock.
                runner.enqueue(self.root, self.payload())
            return "succeeded"

        with mock.patch.object(runner, "process_request", side_effect=process), self.asynchronous_workers():
            self.assertEqual(runner.worker(self.root), 0)
        self.assertEqual(len(seen), 2)
        self.assertNotEqual(seen[0], seen[1])
        self.assertFalse((self.root / "pending" / (self.sid + ".json")).exists())

    def test_enqueue_at_worker_lock_release_gets_successor_wakeup(self):
        runner.enqueue(self.root, self.payload(), spawn=False)
        original_lock = runner.lock_file
        injected = False

        @contextlib.contextmanager
        def inject_before_release(path, blocking=True):
            nonlocal injected
            with original_lock(path, blocking=blocking) as acquired:
                yield acquired
                if path == self.root / "worker.lock" and acquired and not injected:
                    injected = True
                    # Simulate an enqueuer launching a losing worker after the
                    # active worker's final queue scan, before lock release.
                    runner.enqueue(self.root, self.payload())
                    for child in children:
                        child.join(timeout=2)
                        self.assertFalse(child.is_alive(), "competing worker must lose the held leader lock")

        process = mock.Mock(return_value="succeeded")
        with mock.patch.object(runner, "lock_file", side_effect=inject_before_release), mock.patch.object(runner, "process_request", process), self.asynchronous_workers() as children:
            self.assertEqual(runner.worker(self.root), 0)
        self.assertTrue(injected)
        self.assertEqual(process.call_count, 2)
        self.assertFalse((self.root / "pending" / (self.sid + ".json")).exists())

    def test_command_is_ephemeral_and_has_only_memory_capability(self):
        run_dir = runner.private_dir(self.root / "runs" / "config-test")
        config = {**self.config, "codex_bin": self.fake_codex()}
        argv = runner.learner_command(self.root, run_dir, self.request(), config)
        self.assertIn("--ignore-user-config", argv)
        self.assertIn("--ephemeral", argv)
        self.assertEqual(argv[argv.index("--sandbox") + 1], "read-only")
        overrides = {}
        disabled = set()
        for index, arg in enumerate(argv[:-1]):
            if arg == "-c":
                overrides.update(tomllib.loads(argv[index + 1]))
            elif arg == "--disable":
                disabled.add(argv[index + 1])
        self.assertEqual(set(overrides["mcp_servers"]), {"memory"})
        self.assertEqual(set(overrides["mcp_servers"]["memory"]["enabled_tools"]), runner.READ_TOOLS | runner.WRITE_TOOLS)
        self.assertEqual(overrides["web_search"], "disabled")
        self.assertEqual(overrides["approval_policy"], "never")
        self.assertTrue({"hooks", "shell_tool", "plugins", "apps", "multi_agent", "computer_use", "image_generation"}.issubset(disabled))
        self.assertEqual(argv[argv.index("--model") + 1], "configured-model")
        self.assertNotIn("unrelated.invalid", " ".join(argv))

    def test_missing_memory_config_fails_without_provider(self):
        (self.home / "config.toml").write_text('model="configured-model"\n')
        with self.assertRaisesRegex(ValueError, "memory_mcp_not_configured"):
            runner.learner_command(self.root, self.root, self.request(), self.config)

    def test_provider_verified_recall_only_completion_succeeds(self):
        result = self.provider_run()
        self.assertEqual(result["status"], "succeeded")
        self.assertTrue(result["turn_completed"])
        self.assertEqual(result["tool_calls"], 1)
        self.assertEqual(result["write_calls"], 0)

    def test_provider_verified_write_completion_succeeds(self):
        result = self.provider_run(
            events=[mcp_event(), mcp_event("remember", item_id="call-2"), {"type": "turn.completed"}],
            result={"outcome": "stored", "summary": "Stored one finding.", "memory_ids": [MEMORY_ID]},
        )
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(result["write_calls"], 1)
        self.assertEqual(result["writes"][0]["memory_ids"], [MEMORY_ID])

    def test_claimed_memory_id_must_match_observed_successful_write(self):
        result = self.provider_run(
            events=[mcp_event(), mcp_event("remember", item_id="call-2"), {"type": "turn.completed"}],
            result={"outcome": "stored", "summary": "Invented receipt.", "memory_ids": ["00000000-0000-0000-0000-000000000000"]},
        )
        self.assertEqual(result["status"], "failed")

    def test_provider_waiting_without_reading_large_stdin_is_timed_out(self):
        config = {**self.config, "codex_bin": self.fake_codex(delay=3, read_stdin=False), "wall_seconds": 0.2}
        run_dir = runner.private_dir(self.root / "runs" / "timeout")
        excerpt = dataclasses.replace(read_excerpt(self.path), text="[USER]\n" + "A" * 48_000)
        result = runner.run_codex(self.root, run_dir, self.request(), excerpt, config)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["reason"], "timeout")

    def test_provider_claim_without_tools_is_not_accepted(self):
        result = self.provider_run(events=[{"type": "turn.completed"}])
        self.assertEqual(result["status"], "failed")

    def test_provider_reported_tool_calls_without_gateway_audit_rejected(self):
        result = self.provider_run(write_audit=False)
        self.assertEqual(result["status"], "failed")

    def test_gateway_audit_is_independent_of_provider_tool_event_shape(self):
        result = self.provider_run(events=[{"type": "turn.completed"}], audit_events=[mcp_event()])
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(result["tool_calls"], 1)

    def test_failed_mcp_call_does_not_commit_claimed_success(self):
        result = self.provider_run(events=[mcp_event(failed=True), {"type": "turn.completed"}])
        self.assertEqual(result["status"], "failed")
        self.assertGreaterEqual(result["tool_errors"], 1)

    def test_provider_error_or_nonzero_exit_rejects_claimed_success(self):
        result = self.provider_run(events=[mcp_event(), {"type": "error", "message": "fixture failure"}, {"type": "turn.completed"}])
        self.assertEqual(result["status"], "failed")
        result = self.provider_run(exit_code=1)
        self.assertEqual(result["status"], "failed")

    def test_repeated_provider_tool_event_counted_once(self):
        item = mcp_event()
        result = self.provider_run(events=[item, item, {"type": "turn.completed"}])
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(result["tool_calls"], 1)

    def test_unexpected_memory_server_rejected(self):
        result = self.provider_run(events=[mcp_event(server="unrelated"), {"type": "turn.completed"}])
        self.assertEqual(result["status"], "failed")
        self.assertTrue(result["unexpected_tool"])

    def test_non_memory_command_execution_rejected(self):
        command = {"type": "item.completed", "item": {"id": "command-1", "type": "command_execution", "status": "completed", "command": "should never execute"}}
        result = self.provider_run(events=[mcp_event(), command, {"type": "turn.completed"}])
        self.assertEqual(result["status"], "failed")
        self.assertTrue(result["unexpected_tool"])

    def test_provider_exit_after_over_budget_writes_still_rejected(self):
        events = [mcp_event("remember", item_id=f"write-{i}") for i in range(6)] + [{"type": "turn.completed"}]
        result = self.provider_run(events=events, result={"outcome": "stored", "summary": "Too many writes.", "memory_ids": [MEMORY_ID]})
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["reason"], "tool_limit")

    def test_hook_entrypoint_recursion_guard_is_fail_open(self):
        entry = Path(runner.__file__).resolve().parents[1] / "codex_learner.py"
        env = {**os.environ, runner.GUARD: "1"}
        completed = subprocess.run([sys.executable, str(entry), "hook", "--state-dir", str(self.root)], input=json.dumps(self.payload()), text=True, capture_output=True, env=env, timeout=15)
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(json.loads(completed.stdout), {})
        self.assertFalse((self.root / "pending").exists())


if __name__ == "__main__":
    unittest.main()
