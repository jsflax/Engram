"""Gateway enforcement and real subprocess transport, using a fake memory server."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import re
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
REPO_ROOT = MODULE_PATH.parents[2]
PLUGIN_SPEC = importlib.util.spec_from_file_location(
    "packaged_memory_proxy", REPO_ROOT / "codex/plugins/engram/scripts/codex_learner/memory_proxy.py")
packaged_proxy = importlib.util.module_from_spec(PLUGIN_SPEC)
PLUGIN_SPEC.loader.exec_module(packaged_proxy)

# The native contract is literal here so a production parser change cannot also
# silently change the fixture it is being tested against.
CONFLICT_PREFIX = "⚠️ Near-duplicate memory detected. The new memory was NOT stored.\n\nExisting similar memories:"
CONFLICT_SUFFIX = ('\n\nTo resolve:'
                   '\n  - Use `update(id: "UUID", ...)` to modify the existing memory'
                   '\n  - Use `remember(..., force: true)` to keep both'
                   '\n  - Use `forget(id: "UUID")` to remove the old one, then `remember` the new one')
CONFLICT_TEXT = CONFLICT_PREFIX + f"\n  [id:{ID_A}] (distance: 0.123, term overlap: 90%) PRIVATE_CONFLICT_SENTINEL" + CONFLICT_SUFFIX


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
        self.assertIs(forwarded["params"]["arguments"]["force"], False)
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


class LearnerToolContractTests(unittest.TestCase):
    def setUp(self):
        self.audit = CaptureAudit()
        self.policy = proxy.Policy(self.audit, "codex:session:fixture", 100, 50)
        # Model the broad native API, including constraints that must not leak
        # through a property-only filter. These are synthetic descriptors; no
        # live memory server or provider is needed.
        self.native_tools = [
            {"name": "remember", "description": "NATIVE: allow public storage and force duplicates",
             "inputSchema": {"type": "object", "properties": {
                 "content": {"type": "string"}, "is_private": {"type": "boolean", "default": False},
                 "force": {"type": "boolean"}, "source": {"type": "string"}}, "required": ["content"]}},
            {"name": "update", "description": "NATIVE: query, set_project, is_private and undelete are supported",
             "inputSchema": {"type": "object", "properties": {
                 field: {"type": "string"} for field in
                 ("id", "content", "query", "project", "set_project", "is_private", "undelete")},
                 "required": ["query"], "anyOf": [{"required": ["query"]}, {"required": ["undelete"]}],
                 "dependentRequired": {"content": ["set_project"]},
                 "$defs": {"selector": {"required": ["query"]}}},
             "annotations": {"fixture": ["native metadata"]}},
            {"name": "connect", "description": "NATIVE: connect memories",
             "inputSchema": {"type": "object", "properties": {
                 "from": {"type": "string"}, "to": {"type": "string"},
                 "relation": {"type": "string", "enum": ["part_of", "unsupported_relation"]}},
                 "required": ["from", "to", "relation"]}},
            {"name": "recall", "description": "Native read description",
             "inputSchema": {"type": "object", "properties": {"query": {"type": "string"}},
                             "required": ["query"]}},
            {"name": "forget", "inputSchema": {"type": "object"}},
        ]

    def listed(self):
        self.policy.client_message({"jsonrpc": "2.0", "id": "list", "method": "tools/list"})
        response, child = self.policy.server_message({"jsonrpc": "2.0", "id": "list",
                                                     "result": {"tools": self.native_tools}})
        self.assertIsNone(child)
        return {tool["name"]: tool for tool in response["result"]["tools"]}

    def test_write_schemas_are_closed_and_drop_native_forbidden_constraints(self):
        tools = self.listed()
        expected = {
            "remember": ({"content", "project", "topic", "source", "expires_in_days",
                          "importance", "is_private", "parent_id", "force"}, ["content"]),
            "update": ({"id", "content", "append", "prepend", "find", "replace",
                        "topic", "source", "importance", "expires_in_days"}, ["id"]),
            "connect": ({"from", "to", "relation"}, ["from", "to", "relation"]),
        }
        self.assertNotIn("forget", tools)
        for name, (fields, required) in expected.items():
            with self.subTest(tool=name):
                schema = tools[name]["inputSchema"]
                self.assertEqual(schema["type"], "object")
                self.assertEqual(set(schema["properties"]), fields)
                self.assertEqual(schema["required"], required)
                self.assertIs(schema["additionalProperties"], False)
                self.assertLessEqual(set(required), set(schema["properties"]))
                self.assertNotIn("NATIVE:", tools[name]["description"])
                for keyword in ("anyOf", "dependentRequired", "$defs"):
                    self.assertNotIn(keyword, schema)
        for field in ("query", "project", "set_project", "is_private", "undelete"):
            self.assertNotIn(field, tools["update"]["inputSchema"]["properties"])
        self.assertNotIn("semantic similarity", tools["update"]["description"])

    def test_uuid_and_relation_constraints_match_runtime_exact_targeting(self):
        tools = self.listed()
        for tool, field in (("update", "id"), ("connect", "from"), ("connect", "to")):
            schema = tools[tool]["inputSchema"]["properties"][field]
            self.assertEqual(schema["type"], "string")
            for value in (ID_A, ID_B, "ABCDEF01-2345-6789-ABCD-EF0123456789",
                          "not-uuid", ID_A[:8], ID_A + "\n", "prefix" + ID_A, "{" + ID_A + "}"):
                with self.subTest(tool=tool, field=field, value=value):
                    advertised = (schema["minLength"] <= len(value) <= schema["maxLength"]
                                  and re.search(schema["pattern"], value) is not None)
                    self.assertEqual(advertised, proxy.normalized_uuid(value) is not None)
        relation = tools["connect"]["inputSchema"]["properties"]["relation"]
        self.assertEqual(set(relation["enum"]),
                         {"relates_to", "contradicts", "supersedes", "derived_from", "part_of", "summarized_by"})
        self.assertNotIn("unsupported_relation", relation["enum"])

    def test_remember_advertises_and_enforces_private_provenance_and_no_force(self):
        props = self.listed()["remember"]["inputSchema"]["properties"]
        self.assertIs(props["is_private"]["const"], True)
        self.assertIs(props["is_private"]["default"], True)
        self.assertIs(props["force"]["const"], False)
        self.assertIs(props["force"]["default"], False)
        self.assertEqual(props["source"]["const"], "codex:session:fixture")
        for index, options in enumerate(({}, {"is_private": False, "source": "untrusted"}, {"force": False})):
            request = call(index, "remember", {"content": "fixture", **options})
            before = copy.deepcopy(request)
            forwarded, denied = self.policy.client_message(request)
            self.assertIsNone(denied)
            args = forwarded["params"]["arguments"]
            self.assertIs(args["is_private"], True)
            self.assertIs(args["force"], False)
            self.assertEqual(args["source"], "codex:session:fixture")
            self.assertEqual(request, before)

    def test_listing_does_not_mutate_native_descriptors_or_read_tools(self):
        before = copy.deepcopy(self.native_tools)
        tools = self.listed()
        self.assertEqual(self.native_tools, before)
        self.assertEqual(tools["recall"], before[3])
        tools["update"]["annotations"]["fixture"].append("learner-only edit")
        tools["update"]["inputSchema"]["properties"]["id"]["description"] = "changed"
        self.assertEqual(self.native_tools, before)

    def test_schema_advertising_does_not_weaken_runtime_denials(self):
        self.listed()
        cases = [("update", {"id": ID_A, "content": "fixture", field: value})
                 for field, value in (("is_private", True), ("undelete", False),
                                      ("set_project", "other"), ("query", "fixture"), ("project", "other"))]
        cases += [("update", {"id": ID_A[:8], "append": "fixture"}),
                  ("connect", {"from": ID_A, "to": ID_B, "relation": "unsupported_relation"}),
                  ("connect", {"from": ID_A, "to": ID_B + "\n", "relation": "part_of"}),
                  ("connect", {"from": ID_A, "to": ID_B, "relation": "part_of", "extra": False}),
                  ("remember", {"content": "fixture", "force": True}),
                  ("remember", {"content": "fixture", "force": 0}),
                  ("remember", {"content": "fixture", "unknown": True})]
        for index, (name, args) in enumerate(cases):
            with self.subTest(name=name, args=args):
                forwarded, denied = self.policy.client_message(call(index, name, args))
                self.assertIsNone(forwarded)
                self.assertTrue(denied["result"]["isError"])
                self.assertIs(self.audit.records[-1]["ok"], False)
        self.assertEqual(self.policy.pending, {})

    def test_a_corrected_write_does_not_erase_the_prior_denial_receipt(self):
        self.listed()
        self.policy.client_message(call(1, "update", {"id": ID_A, "content": "fixture", "is_private": True}))
        forwarded, denied = self.policy.client_message(call(2, "update", {"id": ID_A, "content": "fixture"}))
        self.assertIsNone(denied)
        self.assertIsNotNone(forwarded)
        self.policy.server_message(result(2, f"Updated memory (id: {ID_A}, project: test)."))
        self.assertEqual([(r["id"], r["ok"]) for r in self.audit.records if r["event"] == "tool_result"],
                         [(1, False), (2, True)])


class PackagedLearnerToolContractTests(LearnerToolContractTests):
    def setUp(self):
        super().setUp()
        self.policy = packaged_proxy.Policy(self.audit, "codex:session:fixture", 100, 50)


class NoWriteContractTests(unittest.TestCase):
    def policies(self, *, max_writes=3):
        for module in (proxy, packaged_proxy):
            audit = CaptureAudit()
            yield module, audit, module.Policy(audit, "fixture", 8, max_writes)

    def test_native_warning_is_forwarded_with_only_vetted_no_write_metadata(self):
        for module, audit, policy in self.policies():
            with self.subTest(module=module.__name__):
                policy.client_message(call(1, "remember", {"content": "private"}))
                native = result(1, CONFLICT_TEXT)
                forwarded, child = policy.server_message(native)
                self.assertEqual(forwarded, native)
                self.assertIsNone(child)
                self.assertEqual(audit.records[-1], {"event": "tool_result", "id": 1,
                    "tool": "remember", "ok": True, "forwarded": True,
                    "memory_ids": [], "write_outcome": "not_stored_near_duplicate"})
                self.assertTrue(module.verified_no_write_receipt(audit.records[-1]))
                self.assertNotIn(ID_A, json.dumps(audit.records))
                self.assertNotIn("PRIVATE_CONFLICT_SENTINEL", json.dumps(audit.records))

    def test_unknown_embedded_truncated_and_mixed_responses_stay_unverified(self):
        cases = [result(1, "Unknown outcome " + ID_A),
                 result(1, "Quoted memory: " + CONFLICT_TEXT),
                 result(1, CONFLICT_PREFIX), result(1, CONFLICT_TEXT + "extra"),
                 result(1, CONFLICT_TEXT.replace("NOT stored", "stored"))]
        mixed = result(1, CONFLICT_TEXT)
        mixed["result"]["content"].append({"type": "text", "text": f"Stored memory (id: {ID_B})"})
        cases.append(mixed)
        structured = result(1, CONFLICT_TEXT)
        structured["result"]["structuredContent"] = {"stored": True}
        cases.append(structured)
        for native in cases:
            for module, audit, policy in self.policies():
                with self.subTest(module=module.__name__, response=native):
                    policy.client_message(call(1, "remember", {"content": "private"}))
                    output, _ = policy.server_message(native)
                    self.assertTrue(output["result"]["isError"])
                    self.assertIs(audit.records[-1]["ok"], False)
                    self.assertNotIn("write_outcome", audit.records[-1])

    def test_non_boolean_error_flags_and_malformed_content_never_prove_no_write(self):
        cases = []
        for flag in (True, None, 0, 1, "false", []):
            cases.append(result(1, CONFLICT_TEXT, flag))
        missing = result(1, CONFLICT_TEXT)
        del missing["result"]["isError"]
        cases.append(missing)
        for content in (None, {}, "bad", [None], [{"type": "text", "text": None}]):
            native = result(1, CONFLICT_TEXT)
            native["result"]["content"] = content
            cases.append(native)
        for native in cases:
            for module, audit, policy in self.policies():
                with self.subTest(module=module.__name__, response=native):
                    policy.client_message(call(1, "remember", {"content": "private"}))
                    policy.server_message(native)
                    self.assertIs(audit.records[-1]["ok"], False)
                    self.assertNotIn("write_outcome", audit.records[-1])

    def test_conflict_does_not_verify_other_tools_and_consumes_attempt_budget(self):
        for module, audit, policy in self.policies(max_writes=1):
            with self.subTest(module=module.__name__):
                policy.client_message(call(1, "remember", {"content": "private"}))
                policy.server_message(result(1, CONFLICT_TEXT))
                forwarded, denied = policy.client_message(call(2, "update", {"id": ID_A, "append": "new"}))
                self.assertIsNone(forwarded)
                self.assertTrue(denied["result"]["isError"])
                self.assertEqual(policy.write_calls, 2)
                self.assertEqual(policy.total_calls, 2)
        for module, audit, policy in self.policies():
            policy.client_message(call(1, "update", {"id": ID_A, "append": "new"}))
            policy.server_message(result(1, CONFLICT_TEXT))
            self.assertIs(audit.records[-1]["ok"], False)

    def test_parser_contract_matches_native_source_and_packaged_copy(self):
        native = (REPO_ROOT / "Sources/EngramKit/MemoryTools+Core.swift").read_text()
        start = native.index('var warning = ')
        end = native.index('return CallTool.Result(content: [.text(warning)], isError: false)', start)
        body = native[start:end]
        prefix = re.search(r'var warning = (".*")', body)[1]
        suffix = ''.join(json.loads(value) for value in re.findall(r'warning \+= (".*")', body)
                         if '\\(mGid' not in value)
        self.assertEqual(json.loads(prefix), CONFLICT_PREFIX)
        self.assertEqual(suffix, CONFLICT_SUFFIX)
        for module in (proxy, packaged_proxy):
            self.assertEqual(module.NEAR_DUPLICATE_PREFIX, CONFLICT_PREFIX)
            self.assertEqual(module.NEAR_DUPLICATE_SUFFIX, CONFLICT_SUFFIX)


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
