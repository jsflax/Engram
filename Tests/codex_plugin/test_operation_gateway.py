"""Synthetic gateway/journal boundary checks; no native or provider invocation."""
import copy
import importlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

from suite_support import PLUGIN_ROOT, TEMP_ROOT

sys.path.insert(0, str(PLUGIN_ROOT / "scripts"))
G = importlib.import_module("codex_learner.operation_gateway")
J = importlib.import_module("codex_learner.execution_manifest")
F = importlib.import_module("codex_learner.writer_fence")
B = importlib.import_module("codex_learner.stdio_bridge")
P = importlib.import_module("codex_learner.memory_proxy")
R = importlib.import_module("codex_learner.runner")
SID = "11111111-2222-4333-8444-555555555555"
STORE = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
MEMORY = "99999999-2222-4333-8444-555555555555"


class OperationGatewayTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="operation-gateway-", dir=TEMP_ROOT)
        self.addCleanup(temporary.cleanup)
        self.run = Path(temporary.name).resolve()
        self.binding = F.create(self.run, generation_id=STORE, owner_id=MEMORY)
        self.fence = F.acquire_shared(self.run, self.binding)
        self.addCleanup(self.fence.close)
        inputs = {name: J.seal_json(J.encode({"fixture": name})) for name in J.INPUT_NAMES}
        self.scope = {"version": 1, "storeID": STORE, "principal": {
            "kind": "agent", "groupIds": [], "scopes": []}}
        self.manifest = {"version": 1, "host": "fixture-host", "session_id": SID, "run_id": "fixture-run",
                         "inputs": inputs, "expected_scope": self.scope,
                         "source": {"identity": {"scheme": "macos_volume_uuid_inode_v1", "volume_uuid": STORE,
                                                 "inode": 123}, "start_offset": 10, "end_offset": 20,
                                    "excerpt_sha256": "a" * 64},
                         "backend": {"route_id": "fixture", "runtime_sha256": "b" * 64,
                                     "route_sha256": inputs["backend_route"]["sha256"],
                                     "config_sha256": inputs["backend_config"]["sha256"]},
                         "fencing": self.binding}
        self.digest = J.publish_manifest(self.run, self.manifest, verify_fence=self.fence.verify)
        self.gateway = G.OperationGateway(self.run, manifest_sha256=self.digest, writer_fence=self.fence,
                                          validate_inputs=lambda *_: True)
        self.args = {"content": "PRIVATE exact e\u0301\r\ntext", "is_private": True,
                     "source": "codex-session:" + SID, "force": False}

    def prepare(self, call=1, tool="remember", args=None):
        return self.gateway.prepare(call, tool, self.args if args is None else args)

    def receipt(self, operation, *, tool="remember", outcome="applied"):
        return {"version": 1, "operationID": operation, "scope": copy.deepcopy(self.scope),
                "payloadDigest": "d" * 64, "mutation": tool, "outcome": outcome,
                "memoryIDs": [MEMORY], "edgeIDs": [], "committedAt": 800000000.25}

    def message(self, operation, receipt=None):
        outer = {"engram_operation": {"version": 1, "kind": "committed",
                                     "receipt": receipt or self.receipt(operation)}}
        return {"jsonrpc": "2.0", "id": 1, "result": {"isError": False, "structuredContent": outer,
                "content": [{"type": "text", "text": J.encode(outer).decode()}]}}

    def test_exact_retained_request_is_persisted_before_wire_output(self):
        operation, forwarded = self.prepare()
        raw, request = J.read_intent(self.run, operation)
        self.assertEqual(request, forwarded["params"]["arguments"])
        self.assertEqual(request["mutation"]["request"]["content"], self.args["content"])
        self.assertEqual([e["evidence"]["kind"] for e in J.read_evidence(self.run, operation)], ["dispatch"])
        queue = B._Queue(2 * J.MAX_INPUT)
        queue.append(forwarded, 2 * J.MAX_INPUT)
        wire = b"".join(queue.parts)
        self.assertIn(b'"arguments":' + raw + b"}}\n", wire)
        self.assertEqual(json.loads(wire)["params"]["name"], "operation_apply")

    def test_typed_rpc_ids_are_distinct_and_duplicate_dispatch_refused(self):
        one, _ = self.prepare(7)
        two, _ = self.prepare("7")
        self.assertNotEqual(one, two)
        with self.assertRaisesRegex(ValueError, "redispatch_requires_reconciliation"):
            self.prepare(7)
        self.assertEqual(len(J.read_evidence(self.run, one)), 1)

    def test_same_rpc_id_changed_payload_cannot_overwrite_intent(self):
        operation, _ = self.prepare()
        before = J.read_intent(self.run, operation)[0]
        with self.assertRaisesRegex(ValueError, "immutable_record_conflict"):
            self.prepare(args=dict(self.args, content="changed"))
        self.assertEqual(J.read_intent(self.run, operation)[0], before)

    def test_mapping_preserves_update_source_and_signed_expiration(self):
        value = G.mutation("update", {"id": MEMORY, "append": "\r\nexact", "source": "",
                                      "importance": 0, "expires_in_days": -2})
        self.assertEqual(value, {"kind": "update", "request": {"id": MEMORY, "append": "\r\nexact",
                         "source": "", "importance": 0, "expiresInDays": -2, "undelete": False}})
        remember = G.mutation("remember", dict(self.args, importance=0, parent_id=None))
        self.assertNotIn("importance", remember["request"])
        self.assertNotIn("parentId", remember["request"])
        self.assertNotIn("force", remember["request"])

    def test_mapping_refuses_policy_bypass_and_dropped_fields(self):
        invalid = [("remember", dict(self.args, force=True)), ("remember", dict(self.args, is_private=False)),
                   ("remember", dict(self.args, importance=True)), ("remember", dict(self.args, expires_in_days=1.5)),
                   ("update", {"id": MEMORY, "append": "x", "undelete": True}),
                   ("update", {"id": MEMORY, "source": "x", "project": "moved"}),
                   ("update", {"id": MEMORY, "append": "x", "content": "y"}),
                   ("connect", {"from": MEMORY, "to": STORE, "relation": "unknown"})]
        for tool, args in invalid:
            with self.subTest(tool=tool, keys=list(args)):
                with self.assertRaises(ValueError):
                    self.prepare(tool=tool, args=args)
        self.assertEqual(list(self.run.glob("operation-*")), [])

    def test_success_requires_durable_matching_native_receipt(self):
        operation, _ = self.prepare()
        expected = self.receipt(operation)
        self.assertEqual(self.gateway.finish(operation, self.message(operation)), expected)
        records = J.read_evidence(self.run, operation)
        self.assertEqual(records[-1]["evidence"], {"kind": "committed", "receipt": expected})
        self.assertNotEqual(J.sha256(J.read_intent(self.run, operation)[0]), expected["payloadDigest"])
        self.assertNotIn(b"PRIVATE", J.encode({"records": records}))

    def test_unchanged_is_preserved_without_claiming_applied(self):
        operation, _ = self.prepare()
        receipt = self.receipt(operation, outcome="unchanged")
        self.assertEqual(self.gateway.finish(operation, self.message(operation, receipt))["outcome"], "unchanged")

    def test_wrong_receipt_bindings_are_retained_as_unavailable(self):
        for index, field in enumerate(("scope", "operationID", "mutation", "payloadDigest")):
            operation, _ = self.prepare(index)
            receipt = self.receipt(operation)
            receipt[field] = {"version": 1, "storeID": MEMORY, "principal": self.scope["principal"]} if field == "scope" else "bad"
            self.assertIsNone(self.gateway.finish(operation, self.message(operation, receipt)))
            self.assertEqual(J.read_evidence(self.run, operation)[-1]["evidence"],
                             {"kind": "unavailable", "reason": "invalid_response"})

    def test_mismatched_text_and_boolean_version_are_not_success(self):
        for index in range(2):
            operation, _ = self.prepare(index)
            message = self.message(operation)
            if index == 0:
                message["result"]["content"][0]["text"] = '{"engram_operation":{}}'
            else:
                outer = message["result"]["structuredContent"]
                outer["engram_operation"]["version"] = True
                message["result"]["content"][0]["text"] = J.encode(outer).decode()
            self.assertIsNone(self.gateway.finish(operation, message))

    def test_transport_and_native_errors_never_mean_absence(self):
        operation, _ = self.prepare()
        self.assertIsNone(self.gateway.finish(operation, {"error": {"code": -32000}}))
        self.assertEqual(J.read_evidence(self.run, operation)[-1]["evidence"]["reason"], "transport_error")
        operation, _ = self.prepare(2)
        outer = {"engram_operation": {"version": 1, "kind": "error", "code": "storage_unavailable"}}
        message = {"result": {"isError": True, "structuredContent": outer,
                              "content": [{"type": "text", "text": J.encode(outer).decode()}]}}
        self.assertIsNone(self.gateway.finish(operation, message))
        self.assertEqual(J.read_evidence(self.run, operation)[-1]["evidence"]["reason"], "backend_error")
        with self.assertRaisesRegex(ValueError, "redispatch_requires_reconciliation"):
            self.prepare(2)

    def test_closed_or_recovery_fence_cannot_dispatch(self):
        self.fence.close()
        with self.assertRaises(ValueError):
            self.prepare()
        with F.revoke(self.run, self.binding, validate=lambda *_: True) as recovery:
            with self.assertRaisesRegex(ValueError, "recovery_descriptor_not_writable"):
                G.OperationGateway(self.run, manifest_sha256=self.digest, writer_fence=recovery,
                                   validate_inputs=lambda *_: True)

    def test_changed_manifest_pin_refused(self):
        with self.assertRaisesRegex(ValueError, "manifest_changed"):
            G.OperationGateway(self.run, manifest_sha256="0" * 64, writer_fence=self.fence,
                               validate_inputs=lambda *_: True)

    def test_current_input_validator_is_mandatory_and_checked_before_forward(self):
        with self.assertRaisesRegex(ValueError, "input_validator_required"):
            G.OperationGateway(self.run, manifest_sha256=self.digest, writer_fence=self.fence, validate_inputs=None)
        for index, denied_phase in enumerate(("before_intent", "before_dispatch_record", "before_forward")):
            calls = []
            def validate(manifest, phase):
                calls.append(phase)
                manifest["source"]["start_offset"] += 1
                return phase != denied_phase
            gateway = G.OperationGateway(self.run, manifest_sha256=self.digest, writer_fence=self.fence,
                                         validate_inputs=validate)
            with self.assertRaisesRegex(ValueError, "input_validation_refused"):
                gateway.prepare(index, "remember", self.args)
            self.assertEqual(calls[-1], denied_phase)
            self.assertEqual(J.read_manifest(self.run)[0]["source"]["start_offset"], 10)
        self.assertEqual(len(list(self.run.glob("operation-*"))), 2)
        self.assertEqual(len(list(self.run.glob("evidence-*"))), 1)

    def policy(self, *, available=True):
        class Audit:
            def __init__(self):
                self.entries = []
            def write(self, entry):
                self.entries.append(entry)
        audit = Audit()
        policy = P.Policy(audit, "codex-session:" + SID, 12, 5, operations=self.gateway)
        forwarded, response = policy.client_message({"jsonrpc": "2.0", "id": "tools", "method": "tools/list"})
        self.assertIsNone(response)
        names = ["remember", "update", "connect", "recall", "forget"]
        if available:
            names += sorted(G.TOOLS)
        message, _ = policy.server_message({"jsonrpc": "2.0", "id": "tools",
                "result": {"tools": [{"name": name, "inputSchema": {}} for name in names]}})
        self.assertEqual({tool["name"] for tool in message["result"]["tools"]},
                         {"remember", "update", "connect", "recall"})
        return policy, audit

    def policy_call(self, policy, *, arguments=None):
        return policy.client_message({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": {"name": "remember", "arguments": arguments or {"content": "private"}}})

    def audited(self, entries):
        path = self.run / "mcp-audit.jsonl"
        path.write_text("".join(json.dumps(entry) + "\n" for entry in entries))
        path.chmod(0o600)
        return R.audit_tools(path)

    def test_policy_forces_provenance_and_routes_through_durable_operation(self):
        policy, audit = self.policy()
        forwarded, denied = self.policy_call(policy, arguments={"content": "private", "source": "forged", "is_private": False})
        self.assertIsNone(denied)
        self.assertEqual(forwarded["params"]["name"], "operation_apply")
        request = forwarded["params"]["arguments"]
        self.assertEqual(request["mutation"]["request"]["source"], "codex-session:" + SID)
        self.assertIs(request["mutation"]["request"]["isPrivate"], True)
        operation = request["operationID"]
        message = self.message(operation)
        self.assertEqual(policy.server_message(message), (message, None))
        result = audit.entries[-1]
        self.assertEqual((result["tool"], result["operation_outcome"], result["memory_ids"]),
                         ("remember", "applied", [MEMORY]))
        self.assertEqual(result["operation_id"], operation)
        summary = self.audited(audit.entries)
        self.assertEqual((summary["tool_errors"], summary["attempted_write_calls"],
                          summary["applied_write_calls"], summary["unchanged_write_calls"]), (0, 1, 1, 0))
        altered = copy.deepcopy(audit.entries)
        altered[-1]["operation_payload_digest"] = "f" * 64
        self.assertGreater(self.audited(altered)["tool_errors"], 0)

    def test_policy_missing_capability_never_falls_back_to_legacy_write(self):
        policy, audit = self.policy(available=False)
        forwarded, denied = self.policy_call(policy)
        self.assertIsNone(forwarded)
        self.assertIs(denied["result"]["isError"], True)
        self.assertIs(audit.entries[-1]["forwarded"], False)
        self.assertEqual(list(self.run.glob("operation-*")), [])

    def test_native_uppercase_uuids_preserve_receipts_and_pass_audit(self):
        policy, audit = self.policy()
        forwarded, _ = self.policy_call(policy)
        operation = forwarded["params"]["arguments"]["operationID"]
        receipt = self.receipt(operation.upper())
        receipt["scope"]["storeID"] = STORE.upper()
        receipt["memoryIDs"] = ["E3BA9094-0A1C-4D91-9190-91832B280FAF"]
        message = self.message(operation, receipt)
        self.assertEqual(policy.server_message(message), (message, None))
        retained = J.read_evidence(self.run, operation)[-1]["evidence"]["receipt"]
        self.assertEqual(retained, receipt)
        entry = audit.entries[-1]
        self.assertEqual(entry["operation_id"], operation.upper())
        self.assertEqual(G.verify_audit_receipt(self.run, 1, "remember", entry), receipt)
        summary = self.audited(audit.entries)
        self.assertEqual((summary["tool_errors"], summary["attempted_write_calls"],
                          summary["applied_write_calls"], summary["unchanged_write_calls"]), (0, 1, 1, 0))
        altered = copy.deepcopy(audit.entries)
        altered[-1]["operation_id"] = STORE.upper()
        self.assertGreater(self.audited(altered)["tool_errors"], 0)

    def test_policy_unchanged_receipt_is_not_counted_as_new_memory(self):
        policy, audit = self.policy()
        forwarded, _ = self.policy_call(policy)
        operation = forwarded["params"]["arguments"]["operationID"]
        message = self.message(operation, self.receipt(operation, outcome="unchanged"))
        self.assertEqual(policy.server_message(message), (message, None))
        result = audit.entries[-1]
        self.assertIs(result["ok"], True)
        self.assertEqual(result["operation_outcome"], "unchanged")
        self.assertEqual(result["memory_ids"], [])
        summary = self.audited(audit.entries)
        self.assertEqual((summary["tool_errors"], summary["write_calls"], summary["unchanged_write_calls"]), (0, 0, 1))

    def test_audit_cannot_hide_an_extra_retained_write_intent(self):
        policy, audit = self.policy()
        forwarded, _ = self.policy_call(policy)
        operation = forwarded["params"]["arguments"]["operationID"]
        policy.server_message(self.message(operation))
        self.assertEqual(self.audited(audit.entries)["tool_errors"], 0)
        self.prepare("unaccounted")
        self.assertGreater(self.audited(audit.entries)["tool_errors"], 0)

    def test_policy_pending_failure_retains_uncertainty_without_retry(self):
        policy, audit = self.policy()
        forwarded, _ = self.policy_call(policy)
        operation = forwarded["params"]["arguments"]["operationID"]
        policy.fail_pending()
        self.assertIs(audit.entries[-1]["ok"], False)
        self.assertEqual(J.read_evidence(self.run, operation)[-1]["evidence"],
                         {"kind": "unavailable", "reason": "transport_error"})


if __name__ == "__main__":
    unittest.main()
