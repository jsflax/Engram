"""Read-only provider composition with synthetic processes and real private files.

No provider/native/database/network runs or HOME/CODEX_HOME changes. The whole
worker integration has separate tests; these exercise the actual runner loop,
proxy policy, immutable observation and plan sealing with a synthetic input scope.
"""
import copy
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "codex/plugins/engram/scripts"))
from codex_learner import runner as R, memory_proxy as M, learner_plan as L
from codex_learner import execution_manifest as J, writer_fence as F

SID = "019b7a00-0000-7123-8000-000000000073"
STORE = "11111111-2222-4333-8444-555555555555"
OWNER = "21111111-2222-4333-8444-555555555555"
TEST_ROOT = Path(os.environ.get("ENGRAM_CI_TEST_ROOT", str(Path.home() / "localdev/engram-ci-python-fixtures")))


def call(number, name, arguments):
    return {"jsonrpc": "2.0", "id": number, "method": "tools/call",
            "params": {"name": name, "arguments": arguments}}


def write(path, value):
    path.write_bytes(J.encode(value)); path.chmod(0o600)


def good_audit():
    return [{"event": "relay_started"}, {"event": "tool_call", "id": 1, "tool": "recall"},
            {"event": "tool_result", "id": 1, "tool": "recall", "ok": True,
             "memory_ids": [], "forwarded": True},
            {"event": "relay_finished", "child_reaped": True, "cleanup_overrun": False}]


def audit_bytes(rows):
    return b"".join(J.encode(row) + b"\n" for row in rows)


class PlanningPolicyTests(unittest.TestCase):
    def setUp(self):
        self.rows = []
        self.policy = M.Policy(SimpleNamespace(write=self.rows.append), "codex-session:" + SID,
                               8, 5, list(M.ALLOWED_TOOLS), provider_mode=M.PLANNING_MODE)

    def test_hidden_mutations_and_native_operation_methods_are_never_forwarded(self):
        for index, tool in enumerate(("remember", "update", "connect", "operation_apply", "operation_scope",
                                      "operation_status", "forget"), 1):
            with self.subTest(tool=tool):
                forwarded, response = self.policy.client_message(call(index, tool, {"content": "private fixture"}))
                self.assertIsNone(forwarded)
                self.assertTrue(response["result"]["isError"])
                self.assertFalse(self.rows[-1]["forwarded"])
        self.assertEqual(self.policy.pending, {})
        self.assertNotIn("private fixture", json.dumps(self.rows))
        with self.assertRaisesRegex(M.ProxyError, "mutation authority"):
            M.Policy(SimpleNamespace(write=self.rows.append), "p", 8, 5,
                     provider_mode=M.PLANNING_MODE, operations=object())

    def test_discovery_and_actual_read_preserve_only_configured_read_capabilities(self):
        policy = M.Policy(SimpleNamespace(write=self.rows.append), "p", 2, 5,
                          ["recall", "remember"], provider_mode=M.PLANNING_MODE)
        policy.client_message({"jsonrpc": "2.0", "id": "list", "method": "tools/list"})
        tools = [{"name": name, "description": "native", "inputSchema": {"type": "object"}}
                 for name in ("recall", "graph", "remember", "operation_apply")]
        response, child = policy.server_message({"jsonrpc": "2.0", "id": "list", "result": {"tools": tools}})
        self.assertIsNone(child)
        self.assertEqual(response["result"]["tools"], [tools[0]])
        message = call(1, "recall", {"query": "private fixture"})
        self.assertEqual(policy.client_message(message), (message, None))
        reply = {"jsonrpc": "2.0", "id": 1, "result": {"isError": False, "content": []}}
        self.assertEqual(policy.server_message(reply), (reply, None))
        self.assertIsNone(policy.client_message(call(2, "graph", {}))[0])
        self.assertIsNone(policy.client_message(call(3, "recall", {}))[0])
        self.assertEqual(policy.total_calls, 3)

    def test_read_audit_requires_complete_successful_lifecycle_and_recall(self):
        rows = good_audit()
        self.assertEqual(M.audit_planning_bytes(audit_bytes(rows))["tool_errors"], 0)
        interrupted = rows[:-1] + [{"event": "relay_interrupted"}, rows[-1]]
        self.assertEqual(M.audit_planning_bytes(audit_bytes(interrupted))["tool_errors"], 1)
        self.assertEqual(M.audit_planning_bytes(audit_bytes(interrupted), allow_clean_interrupt=True)["tool_errors"], 0)
        changes = {
            "missing_finish": rows[:-1],
            "unreaped": rows[:-1] + [{**rows[-1], "child_reaped": False}],
            "failed_read": rows[:2] + [{**rows[2], "ok": False}] + rows[3:],
            "unpaired": rows[:1] + rows[2:],
            "duplicate_result": rows[:3] + [rows[2]] + rows[3:],
            "write_call": rows[:1] + [{**rows[1], "tool": "remember"}] + rows[2:],
            "claimed_write_id": rows[:2] + [{**rows[2], "memory_ids": [STORE]}] + rows[3:],
            "post_finish": rows + [rows[1]],
            "missing_recall": [{**r, "tool": "stats"} if "tool" in r else r for r in rows],
            "extra_start_fields": [{**rows[0], "unexpected": True}] + rows[1:],
            "extra_finish_fields": rows[:-1] + [{**rows[-1], "unexpected": True}],
            "boolean_peak": rows[:-1] + [{**rows[-1], "peak_inflight": True}],
        }
        for name, altered in changes.items():
            with self.subTest(name=name):
                self.assertEqual(M.audit_planning_bytes(audit_bytes(altered), allow_clean_interrupt=True)["tool_errors"], 1)
        self.assertEqual(M.audit_planning_bytes(audit_bytes(rows).rstrip())["tool_errors"], 1)
        duplicated = audit_bytes(rows).replace(b'"event":"relay_started"', b'"event":"relay_started","event":"relay_started"')
        self.assertEqual(M.audit_planning_bytes(duplicated)["tool_errors"], 1)


class RunnerPlanningTests(unittest.TestCase):
    def setUp(self):
        if TEST_ROOT.is_symlink():
            raise RuntimeError("unsafe test root")
        TEST_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
        temp = tempfile.TemporaryDirectory(prefix="runner-planning-", dir=TEST_ROOT)
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        (self.root / "runs").mkdir(mode=0o700)
        self.run = self.root / "runs" / "fixture-run"; self.run.mkdir(mode=0o700)
        self.host = self.root / "host"; self.host.mkdir(mode=0o700)
        (self.host / "config.toml").write_text('[mcp_servers.memory]\ncommand="/never-executed/memory"\ndefault_tools_approval_mode="approve"\n')
        (self.host / "config.toml").chmod(0o600)
        self.config = {**R.DEFAULTS, "codex_bin": "/never-executed/codex", "max_tool_calls": 4, "max_writes": 2}
        self.memory = R.memory_config.resolve(self.host / "config.toml", self.root)[1]
        self.transport = R.memory_config.transport(self.memory)
        self.binding = F.create(self.run, generation_id=STORE, owner_id=OWNER)
        self.fence = F.acquire_shared(self.run, self.binding); self.addCleanup(self.fence.close)
        inputs = {name: J.seal_json(J.encode({"fixture": name})) for name in J.INPUT_NAMES}
        inputs["backend_config"] = J.seal_json(J.encode({"memory": self.memory, "settings": None}))
        self.manifest = {"version": 1, "host": "fixture-host", "session_id": SID, "run_id": "fixture-run",
            "provider_mode": M.PLANNING_MODE, "plan_policy": {"max_tool_calls": 4, "max_writes": 2},
            "inputs": inputs, "source": {"identity": {"scheme": "macos_volume_uuid_inode_v1", "volume_uuid": STORE,
                "inode": 123}, "start_offset": 100, "end_offset": 200, "excerpt_sha256": "a" * 64},
            "expected_scope": {"version": 1, "storeID": STORE, "principal": {"kind": "agent", "groupIds": [], "scopes": []}},
            "backend": {"route_id": "fixture-local", "runtime_sha256": "b" * 64,
                "route_sha256": inputs["backend_route"]["sha256"], "config_sha256": inputs["backend_config"]["sha256"]},
            "fencing": self.binding}
        digest = J.publish_manifest(self.run, self.manifest, verify_fence=self.fence.verify)
        self.context = SimpleNamespace(manifest_sha256=digest, transport=self.transport, validate_inputs=lambda *args: True)
        self.execution = SimpleNamespace(paths=SimpleNamespace(root=self.root, run_dir=self.run), context=self.context,
            specification=lambda: {"root": str(self.root), "run_dir": str(self.run),
                "config_path": str(self.host / "config.toml"), "plugin_root": str(self.root), "manifest_sha256": digest})
        token = R._EXECUTION.set(self.execution); self.addCleanup(R._EXECUTION.reset, token)
        self.request = {"session_id": SID, "event": "Stop", "cwd": str(self.root)}
        self.excerpt = SimpleNamespace(text="Synthetic newly learned fact", next_offset=200)
        self.proposal = {"schema_version": 1, "outcome": "proposed", "summary": "One proposed fact",
            "operations": [{"key": "op_1", "tool": "remember", "arguments": {"content": "Synthetic fact", "expires_in_days": 7}}]}
        # Exercise the CLI's strict schema shape, including nullable unused args.
        for choice in L.PROPOSAL_SCHEMA["properties"]["operations"]["items"]["anyOf"]:
            if choice["properties"]["tool"]["const"] == "remember":
                for name in choice["properties"]["arguments"]["properties"]:
                    self.proposal["operations"][0]["arguments"].setdefault(name, None)
        self.failed_turn = False; self.complete = True; self.read_error = False; self.cleanup = True
        self.extra_events = []; self.code = 0; self.mutation_attempt = False
        self.patch(R, "codex_home", return_value=self.host)
        for obj, name in ((socket, "socket"), (sqlite3, "connect"), (subprocess, "run"), (os, "killpg")):
            self.patch(obj, name, side_effect=AssertionError("external effect forbidden"))
        self.patch(R.operation_gateway.OperationGateway, "prepare", side_effect=AssertionError("provider mutation forbidden"))
        self.patch(R.subprocess, "Popen", side_effect=self.provider)

    def patch(self, obj, name, **kwargs):
        patch = mock.patch.object(obj, name, **kwargs); result = patch.start(); self.addCleanup(patch.stop); return result

    def provider(self, argv, **kwargs):
        self.assertEqual(argv[0], "/never-executed/codex")
        self.assertEqual(argv[argv.index("--output-last-message") + 1], str(self.run / "proposal.json"))
        transport = json.loads((self.run / "transport.json").read_text())
        self.assertEqual(transport["provider_mode"], M.PLANNING_MODE)
        self.assertEqual(set(transport["allowed_tools"]), M.READ_TOOLS)
        prompt = kwargs["stdin"].read().decode()
        self.actual_prompt = prompt
        self.actual_schema = json.loads((self.run / 'schema.json').read_text())
        self.assertIn("No memory is stored during this planning turn", prompt)
        with _audit_context(self.run / "mcp-audit.jsonl") as audit:
            audit.write({"event": "relay_started"})
            policy = M.Policy(audit, "codex-session:" + SID, 4, 2, list(M.ALLOWED_TOOLS), provider_mode=M.PLANNING_MODE)
            forwarded, _ = policy.client_message(call(1, "recall", {"query": "Synthetic fact"}))
            self.assertEqual(forwarded["params"]["name"], "recall")
            policy.server_message({"jsonrpc": "2.0", "id": 1,
                "result": {"isError": self.read_error, "content": []}})
            if self.mutation_attempt:
                forwarded, _ = policy.client_message(call(2, "remember", {"content": "must not store"}))
                self.assertIsNone(forwarded)
            audit.write({"event": "relay_interrupted"})
            if self.cleanup:
                audit.write({"event": "relay_finished", "child_reaped": True, "cleanup_overrun": False})
        write(self.run / "proposal.json", self.proposal)
        # --output-last-message may use the CLI's ordinary creation umask.
        (self.run / "proposal.json").chmod(0o644)
        events = [{"type": "turn.started"}, {"type": "error", "message": "Synthetic reconnect notice"}]
        if self.failed_turn:
            events.append({"type": "turn.failed", "error": {"message": "Synthetic failure"}})
        if self.complete:
            events.append({"type": "turn.completed"})
        events += self.extra_events
        for event in events:
            kwargs["stdout"].write(J.encode(event) + b"\n")
        kwargs["stdout"].flush()
        return SimpleNamespace(returncode=self.code, poll=lambda: self.code, wait=lambda **kwargs: self.code)

    def invoke(self):
        return R.run_planner(self.root, self.run, self.request, self.excerpt, self.config)

    def test_new_manifest_selects_project_prompt_schema_and_preserves_false(self):
        # Construct a fresh manifest before provider dispatch; never migrate one.
        (self.run / 'execution-manifest.json').unlink()
        self.manifest['plan_policy']['privacy'] = J.PROJECT_SYNC_PRIVACY
        digest = J.publish_manifest(self.run, self.manifest, verify_fence=self.fence.verify)
        self.context.manifest_sha256 = digest
        specification = self.execution.specification()
        specification['manifest_sha256'] = digest
        self.execution.specification = lambda: specification
        self.proposal['operations'][0]['arguments']['is_private'] = False
        self.assertEqual(self.invoke()['status'], 'planned')
        self.assertIn('Private means device-local', self.actual_prompt)
        self.assertIn('exposed-group settings', self.actual_prompt)
        self.assertNotIn('host enforces is_private=true', self.actual_prompt)
        choice = next(c for c in self.actual_schema['properties']['operations']['items']['anyOf']
                      if c['properties']['tool']['const'] == 'remember')
        field = choice['properties']['arguments']['properties']['is_private']
        self.assertEqual(field['type'], 'boolean')
        self.assertNotIn('const', field); self.assertNotIn('anyOf', field)
        plan = L.seal_plan(self.run, verify_fence=self.fence.verify, validate_inputs=lambda *_: True)
        self.assertIs(J._json(J._unseal(plan['operations'][0]['request']))['mutation']['request']['isPrivate'], False)
        self.assertFalse(list(self.run.glob('operation-*')))

    def test_old_interrupted_planning_uses_original_prompt_schema_and_private_default(self):
        self.assertNotIn('privacy', self.manifest['plan_policy'])
        self.assertEqual(self.invoke()['status'], 'planned')
        self.assertIn('host enforces is_private=true', self.actual_prompt)
        self.assertNotIn('Private means device-local', self.actual_prompt)
        self.assertEqual(self.actual_schema, L.PROPOSAL_SCHEMA)
        template = Path(R.__file__).with_name('learner_prompt.md').read_text()
        self.assertTrue(self.actual_prompt.startswith(R.render_learner_prompt(template, self.config, planning=True)))
        plan = L.seal_plan(self.run, verify_fence=self.fence.verify, validate_inputs=lambda *_: True)
        self.assertIs(J._json(J._unseal(plan['operations'][0]['request']))['mutation']['request']['isPrivate'], True)

    def test_complete_provider_returns_plan_without_any_mutation_or_stored_claim(self):
        result = self.invoke()
        self.assertEqual(result["status"], "planned")
        self.assertEqual(result["write_calls"], 0)
        self.assertEqual(result["writes"], [])
        self.assertFalse((self.run / "result.json").exists())
        self.assertFalse((self.run / "provider.jsonl").exists())
        self.assertFalse((self.run / "stderr.log").exists())
        self.assertEqual((self.run / "proposal.json").stat().st_mode & 0o777, 0o600)
        self.assertFalse(list(self.run.glob("operation-*")))
        plan = L.seal_plan(self.run, verify_fence=self.fence.verify, validate_inputs=lambda *args: True)
        self.assertEqual(len(plan["operations"]), 1)
        self.assertFalse(list(self.run.glob("operation-*")))
        self.assertEqual(J._json(J._unseal(plan["operations"][0]["request"]))["mutation"]["request"]["isPrivate"], True)

    def startup_diagnostic(self):
        diagnostic = M._StartupDiagnostic()
        diagnostic.bind(SimpleNamespace(run_dir=self.run), self.manifest, self.context.manifest_sha256, J)
        diagnostic.stage = "execution_context"
        diagnostic.record(ValueError("execution_context_backend_changed"))

    def test_failed_provider_reports_bound_startup_code_without_authorizing_a_plan(self):
        def failed_provider(*args, **kwargs):
            self.startup_diagnostic()
            return SimpleNamespace(returncode=1, poll=lambda: 1, wait=lambda **kwargs: 1)
        with mock.patch.object(R.subprocess, "Popen", side_effect=failed_provider):
            result = self.invoke()
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["reason"], "unverified_completion")
        self.assertEqual(result["gateway_startup_failure"],
                         {"stage": "execution_context", "reason": "execution_context_backend_changed"})
        self.assertEqual(result["write_calls"], 0)
        self.assertFalse(list(self.run.glob("operation-*")))
        with self.assertRaises(ValueError):
            L.seal_plan(self.run, verify_fence=self.fence.verify, validate_inputs=lambda *args: True)
        settled = R.settlement._compute(self.run, self.manifest, self.context.manifest_sha256)
        self.assertEqual((settled["status"], settled["reason"]), ("failed", "planning_not_complete"))

    def test_diagnostic_is_not_a_success_or_plan_validation_input(self):
        self.startup_diagnostic()
        result = self.invoke()
        self.assertEqual(result["status"], "planned")
        self.assertNotIn("gateway_startup_failure", result)
        plan = L.seal_plan(self.run, verify_fence=self.fence.verify, validate_inputs=lambda *args: True)
        self.assertEqual(len(plan["operations"]), 1)
        self.assertFalse(list(self.run.glob("operation-*")))

    def test_failed_terminal_cannot_authorize_even_a_valid_complete_proposal(self):
        self.failed_turn = True
        self.assertEqual(self.invoke()["status"], "failed")
        with self.assertRaisesRegex(ValueError, "provider_not_complete"):
            L.seal_plan(self.run, verify_fence=self.fence.verify, validate_inputs=lambda *args: True)
        self.assertFalse(list(self.run.glob("operation-*")))

    def test_provider_mutation_attempt_is_denied_and_invalidates_the_whole_proposal(self):
        self.mutation_attempt = True
        self.assertEqual(self.invoke()["status"], "failed")
        with self.assertRaisesRegex(ValueError, "read_audit_failed"):
            L.seal_plan(self.run, verify_fence=self.fence.verify, validate_inputs=lambda *args: True)
        self.assertFalse(list(self.run.glob("operation-*")))

    def test_missing_cleanup_cannot_authorize_the_proposal(self):
        self.cleanup = False
        self.assertEqual(self.invoke()["status"], "failed")
        with self.assertRaisesRegex(ValueError, "read_audit_failed"):
            L.seal_plan(self.run, verify_fence=self.fence.verify, validate_inputs=lambda *args: True)

    def test_invalid_full_plan_is_rejected_before_any_operation_is_published(self):
        self.proposal["operations"].append({"key": "op_2", "tool": "connect",
            "arguments": {"from": {"operation_key": "op_1"}, "to": STORE, "relation": "part_of"}})
        self.assertEqual(self.invoke()["status"], "failed")
        with self.assertRaises(ValueError):
            L.seal_plan(self.run, verify_fence=self.fence.verify, validate_inputs=lambda *args: True)
        self.assertFalse(list(self.run.glob("operation-*")))

    def test_legacy_runner_cannot_downgrade_a_planning_manifest(self):
        with self.assertRaisesRegex(ValueError, "provider_mode_changed"):
            R.learner_command(self.root, self.run, self.request, self.config)
        with self.assertRaisesRegex(ValueError, "planning_budget_changed"):
            R.learner_command(self.root, self.run, self.request, {**self.config, "max_writes": 1}, planning=True)
        self.assertFalse((self.run / "transport.json").exists())

    def test_proxy_refuses_transport_mode_or_budget_downgrade_before_relay(self):
        from codex_learner import stdio_bridge
        R.learner_command(self.root, self.run, self.request, self.config, planning=True)
        config = json.loads((self.run / "transport.json").read_text())
        variants = [{key: value for key, value in config.items() if key != "provider_mode"},
                    {**config, "provider_mode": "legacy"}, {**config, "max_writes": 1}]
        with mock.patch.object(stdio_bridge, "run_relay") as relay:
            for changed in variants:
                with self.subTest(change=changed.get("provider_mode"), writes=changed["max_writes"]):
                    with self.assertRaisesRegex(M.ProxyError, "provider mode|planning budgets"):
                        M.run(changed)
            relay.assert_not_called()

    def test_proposal_privatization_never_follows_symlink_or_modifies_hardlinked_file(self):
        original = self.root / "other.json"
        original.write_text("{}"); original.chmod(0o644)
        proposal = self.run / "proposal.json"
        proposal.symlink_to(original)
        with self.assertRaises(OSError):
            R.private_proposal(proposal)
        proposal.unlink()
        os.link(original, proposal)
        with self.assertRaisesRegex(ValueError, "unsafe_provider_proposal"):
            R.private_proposal(proposal)
        self.assertEqual(original.stat().st_mode & 0o777, 0o644)

    def test_proposal_replaced_after_privatization_cannot_be_accepted(self):
        proposal = self.run / "proposal.json"
        proposal.write_text("{}"); proposal.chmod(0o644)
        original_read = R.runner_publication.durable._read

        def replaced(path, **kwargs):
            replacement = self.run / "replacement.json"
            write(replacement, {"unexpected": "different inode"})
            os.replace(replacement, path)
            return original_read(path, **kwargs)

        with mock.patch.object(R.runner_publication.durable, "_read", side_effect=replaced):
            with self.assertRaisesRegex(ValueError, "provider_proposal_changed"):
                R.private_proposal(proposal)


class _audit_context:
    def __init__(self, path): self.path = path
    def __enter__(self): self.audit = M.Audit(self.path); return self.audit
    def __exit__(self, *args): self.audit.close()


if __name__ == "__main__":
    unittest.main()
