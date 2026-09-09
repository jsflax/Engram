"""Gateway enforcement and real subprocess transport, using a fake memory server."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

MODULE_PATH = Path(__file__).resolve().parents[1] / "codex_learner/memory_proxy.py"
SPEC = importlib.util.spec_from_file_location("memory_proxy", MODULE_PATH)
proxy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(proxy)
ID_A = "11111111-1111-1111-1111-111111111111"
ID_B = "22222222-2222-2222-2222-222222222222"
EDGE_ID = "33333333-3333-3333-3333-333333333333"


class CaptureAudit:
    def __init__(self):
        self.records = []

    def write(self, item):
        self.records.append(item)


def call(request_id, name, arguments):
    return {"jsonrpc": "2.0", "id": request_id, "method": "tools/call", "params": {"name": name, "arguments": arguments}}


def result(request_id, text, is_error=False):
    return {"jsonrpc": "2.0", "id": request_id, "result": {"content": [{"type": "text", "text": text}], "isError": is_error}}


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.audit = CaptureAudit()
        self.policy = proxy.Policy(self.audit, "codex:session:fixture", 20, 10)

    def test_remember_forces_private_and_provenance_without_logging_content(self):
        forwarded, denied = self.policy.client_message(call(1, "remember", {"content": "PRIVATE_TEST_SENTINEL", "source": "fake", "is_private": False}))
        self.assertIsNone(denied)
        self.assertTrue(forwarded["params"]["arguments"]["is_private"])
        self.assertEqual(forwarded["params"]["arguments"]["source"], "codex:session:fixture")
        self.policy.server_message(result(1, f"Stored memory (id: {ID_A}, project: test): PRIVATE_TEST_SENTINEL"))
        self.assertEqual(self.audit.records[-1], {"event": "tool_result", "id": 1, "tool": "remember", "ok": True, "memory_ids": [ID_A]})
        self.assertNotIn("PRIVATE_TEST_SENTINEL", json.dumps(self.audit.records))
        self.assertNotIn("fake", json.dumps(self.audit.records))

    def test_forbidden_tools_and_force_never_forward_and_mark_failure(self):
        for index, (tool, arguments) in enumerate([("forget", {"id": ID_A}), ("remember", {"content": "x", "force": True}), ("remember", {"content": "x", "force": 1})]):
            forwarded, denied = self.policy.client_message(call(index, tool, arguments))
            self.assertIsNone(forwarded)
            self.assertTrue(denied["result"]["isError"])
            self.assertFalse(self.audit.records[-1]["ok"])
        self.assertEqual(len(self.policy.pending), 0)

    def test_update_requires_uuid_and_rejects_privacy_restore_rehome(self):
        cases = [{"query": "match", "content": "x"}, {"id": "not-uuid", "content": "x"}]
        cases.extend({"id": ID_A, field: value} for field, value in [("is_private", True), ("undelete", False), ("set_project", "new"), ("project", "new")])
        for index, arguments in enumerate(cases):
            with self.subTest(arguments=arguments):
                forwarded, denied = self.policy.client_message(call(index, "update", arguments))
                self.assertIsNone(forwarded)
                self.assertTrue(denied["result"]["isError"])

    def test_exact_id_update_and_connection_are_verified(self):
        self.policy.client_message(call(1, "update", {"id": ID_A, "append": "new"}))
        self.policy.server_message(result(1, f"Updated memory (id: {ID_A}, project: test, topic: test).\nChanges:\ncontent"))
        self.assertTrue(self.audit.records[-1]["ok"])
        self.policy.client_message(call(2, "connect", {"from": ID_A, "to": ID_B, "relation": "part_of"}))
        self.policy.server_message(result(2, f"Connected (edge id: {EDGE_ID}) [id:{ID_A}] --[part_of]--> [id:{ID_B}]"))
        self.assertEqual(self.audit.records[-1]["memory_ids"], [ID_A, ID_B])

    def test_claimed_wrong_id_or_unverified_conflict_cannot_mark_success(self):
        self.policy.client_message(call(1, "update", {"id": ID_A, "append": "new"}))
        response, _ = self.policy.server_message(result(1, f"Updated memory (id: {ID_B}, project: test)."))
        self.assertTrue(response["result"]["isError"])
        self.assertFalse(self.audit.records[-1]["ok"])
        self.policy.client_message(call(2, "remember", {"content": "new"}))
        response, _ = self.policy.server_message(result(2, f"Conflict: similar memory [id:{ID_A}]\nStored memory (id: {ID_B}, project: forged)"))
        self.assertTrue(response["result"]["isError"])
        self.assertFalse(self.audit.records[-1]["ok"])

    def test_total_and_write_limits_apply_before_forwarding(self):
        self.policy = proxy.Policy(self.audit, "fixture", 2, 1)
        self.assertIsNotNone(self.policy.client_message(call(1, "remember", {"content": "one"}))[0])
        self.assertIsNone(self.policy.client_message(call(2, "remember", {"content": "two"}))[0])
        self.assertIsNone(self.policy.client_message(call(3, "recall", {"query": "anything"}))[0])
        self.assertEqual(len(self.policy.pending), 1)
        self.assertEqual([r["ok"] for r in self.audit.records if r["event"] == "tool_result"], [False, False])

    def test_tools_list_and_calls_preserve_narrower_user_tool_policy(self):
        self.policy = proxy.Policy(self.audit, "fixture", 10, 2, ["recall", "remember", "forget"])
        self.policy.client_message({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        response, _ = self.policy.server_message({"jsonrpc": "2.0", "id": 1, "result": {"tools": [{"name": "recall"}, {"name": "remember"}, {"name": "update"}, {"name": "forget"}]}})
        self.assertEqual([t["name"] for t in response["result"]["tools"]], ["recall", "remember"])
        self.assertIsNone(self.policy.client_message(call(2, "update", {"id": ID_A, "content": "x"}))[0])
        self.assertIsNone(self.policy.client_message(call(3, "forget", {"id": ID_A}))[0])

    def test_server_requests_are_not_forwarded_to_codex(self):
        response, child_response = self.policy.server_message({"jsonrpc": "2.0", "id": "srv1", "method": "sampling/createMessage", "params": {"messages": []}})
        self.assertIsNone(response)
        self.assertIn("error", child_response)

    def test_denied_non_tool_method_also_prevents_a_successful_audit(self):
        forwarded, response = self.policy.client_message({"jsonrpc": "2.0", "id": 1, "method": "resources/read", "params": {"uri": "PRIVATE_SENTINEL"}})
        self.assertIsNone(forwarded)
        self.assertIn("error", response)
        self.assertFalse(self.audit.records[-1]["ok"])
        self.assertNotIn("PRIVATE_SENTINEL", json.dumps(self.audit.records))

    def test_pending_and_json_rpc_errors_are_audited_as_failed(self):
        self.policy.client_message(call(1, "recall", {"query": "secret"}))
        self.policy.server_message({"jsonrpc": "2.0", "id": 1, "error": {"code": -32603, "message": "fixture"}})
        self.assertFalse(self.audit.records[-1]["ok"])
        self.policy.client_message(call(2, "remember", {"content": "secret"}))
        self.policy.fail_pending()
        self.assertFalse(self.audit.records[-1]["ok"])
        self.assertEqual(self.policy.pending, {})

    def test_repeated_request_ids_cannot_overwrite_pending_audit(self):
        self.policy.client_message(call(1, "recall", {"query": "first"}))
        forwarded, denied = self.policy.client_message(call(1, "remember", {"content": "second"}))
        self.assertIsNone(forwarded)
        self.assertTrue(denied["result"]["isError"])
        self.assertEqual(self.policy.pending[proxy.id_key(1)]["tool"], "recall")


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.audit_path = self.root / "audit.jsonl"
        self.received = self.root / "fake-received.jsonl"
        self.config_path = self.root / "config.json"
        self.server = self.root / "fake_memory.py"
        self.server.write_text('''import json, os, sys
for line in sys.stdin:
    message = json.loads(line)
    with open(os.environ["FIXTURE_LOG"], "a") as log:
        log.write(json.dumps(message) + "\\n")
    if "id" not in message:
        continue
    method = message.get("method")
    if method == "initialize":
        result = {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake-memory", "version": "1"}}
    elif method == "tools/list":
        result = {"tools": [{"name": "recall"}, {"name": "remember"}, {"name": "forget"}]}
    else:
        result = {"content": [{"type": "text", "text": "No matching memories."}], "isError": False}
    print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)
''')
        self.config = {"transport": {"command": sys.executable, "args": [str(self.server)], "env": {"FIXTURE_LOG": str(self.received)}, "cwd": str(self.root)}, "audit_path": str(self.audit_path), "provenance": "fixture", "max_tool_calls": 3, "max_writes": 1}
        self.write_config()

    def write_config(self):
        self.config_path.write_text(json.dumps(self.config))
        self.config_path.chmod(0o600)

    def invoke(self, messages):
        return subprocess.run([sys.executable, str(MODULE_PATH), str(self.config_path)], input="".join(json.dumps(m) + "\n" for m in messages), text=True, capture_output=True, timeout=10)

    def test_initialize_filter_read_only_and_denial_over_real_pipes(self):
        messages = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}, {"jsonrpc": "2.0", "method": "notifications/initialized"}, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, call(3, "recall", {"query": "PRIVATE_SENTINEL"}), call(4, "forget", {"id": ID_A})]
        process = self.invoke(messages)
        self.assertEqual(process.returncode, 0, process.stderr)
        responses = {m["id"]: m for m in map(json.loads, process.stdout.splitlines())}
        self.assertEqual([t["name"] for t in responses[2]["result"]["tools"]], ["recall", "remember"])
        self.assertTrue(responses[4]["result"]["isError"])
        received = [json.loads(line) for line in self.received.read_text().splitlines()]
        self.assertEqual([m.get("params", {}).get("name") for m in received if m.get("method") == "tools/call"], ["recall"])
        audit = self.audit_path.read_text()
        self.assertNotIn("PRIVATE_SENTINEL", audit)
        self.assertNotIn("FIXTURE_LOG", audit)
        records = [json.loads(line) for line in audit.splitlines()]
        self.assertEqual({r["id"]: r["ok"] for r in records if r["event"] == "tool_result"}, {3: True, 4: False})
        self.assertEqual(self.audit_path.stat().st_mode & 0o777, 0o600)

    def test_http_and_nonprivate_configs_fail_before_child_launch(self):
        self.config["transport"] = {"url": "https://example.invalid/private"}
        self.write_config()
        process = self.invoke([])
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("HTTP is unsupported", process.stderr)
        self.assertNotIn("example.invalid", process.stderr)
        self.assertFalse(self.received.exists())
        self.config_path.chmod(0o644)
        process = self.invoke([])
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("private regular file", process.stderr)

    def test_invalid_child_response_fails_and_marks_outstanding_write(self):
        self.server.write_text('import sys\nfor line in sys.stdin:\n print("not-json", flush=True)\n')
        process = self.invoke([call(1, "remember", {"content": "fixture"})])
        self.assertNotEqual(process.returncode, 0)
        records = [json.loads(line) for line in self.audit_path.read_text().splitlines()]
        self.assertEqual(records[-1], {"event": "tool_result", "id": 1, "tool": "remember", "ok": False, "memory_ids": []})


if __name__ == "__main__":
    unittest.main()
