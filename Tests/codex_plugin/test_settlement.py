"""Real file/fence evidence; no provider or native invocation."""
import copy
import importlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from suite_support import PLUGIN_ROOT

sys.path.insert(0, str(PLUGIN_ROOT / "scripts"))
S = importlib.import_module("codex_learner.settlement")
J, F, G = S.journal, S.writer_fence, S.gateway
SID = "01900000-0000-7000-8000-000000000001"
STORE = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
MEMORY = "11111111-2222-4333-8444-555555555555"


class SettlementTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="settlement-")
        self.addCleanup(temporary.cleanup)
        self.run = Path(temporary.name).resolve()
        self.binding = F.create(self.run, generation_id=STORE, owner_id=MEMORY)
        self.writer = F.acquire_shared(self.run, self.binding)
        self.addCleanup(self.writer.close)
        self.recovery = None
        binding = {"session_id": SID, "activation_id": "fixture"}
        values = {name: {"fixture": name} for name in J.INPUT_NAMES}
        values["request"] = {"session_id": SID, "request_id": "fixture-request", "admission": binding}
        values["parser_state"] = {"version": 1, "input": {"offset": 10, "recent_messages": [], "current_turn_id": None},
            "limits": {"max_chars": 24000, "max_scan_bytes": 8388608},
            "runtime": {"path": "/fixture/parser.py", "sha256": "b" * 64}, "interval_sha256": "c" * 64}
        values["next_parser_state"] = {"offset": 20, "recent_messages": [], "current_turn_id": None}
        inputs = {name: J.seal_json(J.encode(value)) for name, value in values.items()}
        self.scope = {"version": 1, "storeID": STORE, "principal": {"kind": "agent", "groupIds": [], "scopes": []}}
        self.manifest = {"version": 1, "host": "fixture-host", "session_id": SID, "run_id": "fixture-run",
            "inputs": inputs, "expected_scope": self.scope, "source": {
                "identity": {"scheme": "macos_volume_uuid_inode_v1", "volume_uuid": STORE, "inode": 123},
                "start_offset": 10, "end_offset": 20, "excerpt_sha256": "a" * 64},
            "backend": {"route_id": "fixture", "runtime_sha256": "b" * 64,
                        "route_sha256": inputs["backend_route"]["sha256"], "config_sha256": inputs["backend_config"]["sha256"]},
            "fencing": self.binding}
        self.digest = J.publish_manifest(self.run, self.manifest, verify_fence=self.writer.verify)
        self.gateway = G.OperationGateway(self.run, manifest_sha256=self.digest, writer_fence=self.writer,
                                          validate_inputs=lambda *_: True)
        self.observation = {"started": True, "terminated": True, "returncode": 0, "turn_completed": True,
                            "provider_error": False, "unexpected_tool": False, "tool_errors": 0, "reason": None}
        self.audit = [{"event": "relay_started"}]
        self.result = {"outcome": "no_new_memories", "summary": "Private fixture summary", "memory_ids": []}

    def dispatch(self):
        S.record_provider_dispatch(self.run, self.digest, lambda *_: True)

    def write(self, call=1, outcome="applied"):
        operation, _ = self.gateway.prepare(call, "remember", {"content": "private fixture", "source": "fixture", "is_private": True})
        receipt = {"version": 1, "operationID": operation, "scope": self.scope, "payloadDigest": "d" * 64,
                   "mutation": "remember", "outcome": outcome, "memoryIDs": [MEMORY], "edgeIDs": [], "committedAt": 800000000.25}
        J.record_response(self.run, operation, {"kind": "committed", "receipt": receipt}, verify_fence=self.writer.verify)
        self.audit.extend([{"event": "tool_call", "id": call, "tool": "remember"},
            {"event": "tool_result", "id": call, "tool": "remember", "ok": True,
             "forwarded": True, "memory_ids": [MEMORY] if outcome == "applied" else [],
             "operation_version": 1, "operation_id": operation, "operation_outcome": outcome,
             "operation_payload_digest": "d" * 64}])
        if outcome == "applied":
            self.result.update(outcome="stored", memory_ids=[MEMORY])
        return operation

    def read(self, call=1):
        self.audit.extend([{"event": "tool_call", "id": call, "tool": "recall"},
                           {"event": "tool_result", "id": call, "tool": "recall", "ok": True,
                            "forwarded": True, "memory_ids": []}])

    def finish_files(self, *, interrupt=False):
        entries = self.audit + ([{"event": "relay_interrupted"}] if interrupt else []) + [
            {"event": "relay_finished", "child_reaped": True, "cleanup_overrun": False}]
        S.durable._new(self.run / "mcp-audit.jsonl", b"".join(J.encode(entry) + b"\n" for entry in entries))
        S.durable._new(self.run / "result.json", J.encode(self.result))

    def revoke(self):
        if self.recovery is None:
            self.writer.close()
            self.recovery = F.revoke(self.run, self.binding, validate=lambda *_: True)
            self.addCleanup(self.recovery.close)
        return self.recovery

    def settle(self, *, observation=True, validate=None):
        return S.settle(self.run, manifest_sha256=self.digest, recovery_fence=self.revoke(),
                        validate_inputs=validate or (lambda *_: True),
                        provider_observation=self.observation if observation else None)

    def verify(self, digest, **overrides):
        return S.verify_settlement(self.run, expected_sha256=digest, recovery_fence=self.revoke(),
                                    validate_inputs=overrides.get("validate", lambda *_: True))

    def test_applied_receipt_audit_and_provider_completion_create_exact_coverage(self):
        self.dispatch(); self.write(); self.finish_files()
        result = self.settle()
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(result["applied_write_calls"], 1)
        self.assertEqual(result["memory_ids"], [MEMORY])
        self.assertEqual(self.verify(result["settlement_sha256"])["status"], "succeeded")
        receipt = json.loads((self.run / "successful-coverage.json").read_bytes())
        binding = {"session_id": SID, "run_id": "fixture-run", "source": receipt["source"], "parser": receipt["parser"],
                   "admission": J._json(J._unseal(self.manifest["inputs"]["request"]))["admission"]}
        self.assertTrue(S.verify_coverage(self.run, receipt, binding, recovery_fence=self.recovery, validate_inputs=lambda *_: True))
        self.assertEqual(receipt["source"]["interval_sha256"], "c" * 64)
        self.assertEqual(self.settle(observation=False)["settlement_sha256"], result["settlement_sha256"])

    def test_unchanged_and_read_only_complete_without_claiming_new_memory(self):
        for kind in ("unchanged", "read"):
            with self.subTest(kind=kind):
                self.setUp(); self.dispatch()
                self.write(outcome="unchanged") if kind == "unchanged" else self.read()
                self.finish_files(interrupt=True)
                result = self.settle()
                self.assertEqual(result["status"], "succeeded")
                self.assertEqual(result["applied_write_calls"], 0)
                self.assertEqual(result["memory_ids"], [])
                self.assertEqual(result["unchanged_write_calls"], kind == "unchanged")

    def test_unresolved_dispatch_absent_and_backend_errors_never_become_safe_absence(self):
        for kind in ("missing", "absent", "unavailable"):
            with self.subTest(kind=kind):
                self.setUp(); self.dispatch()
                operation, _ = self.gateway.prepare(1, "remember", {"content": "x", "source": "fixture", "is_private": True})
                if kind != "missing":
                    response = {"kind": "absent", "operationID": operation, "scope": self.scope} if kind == "absent" else {
                        "kind": "unavailable", "reason": "backend_error"}
                    J.record_response(self.run, operation, response, verify_fence=self.writer.verify)
                self.audit.extend([{"event": "tool_call", "id": 1, "tool": "remember"},
                    {"event": "tool_result", "id": 1, "tool": "remember", "ok": False, "forwarded": True, "memory_ids": []}])
                self.finish_files()
                self.assertEqual(self.settle()["status"], "reconciliation_required")
                self.assertFalse((self.run / "successful-coverage.json").exists())

    def test_no_start_requires_dispatch_and_inventory_absence_or_positive_process_observation(self):
        result = self.settle(observation=False)
        self.assertEqual((result["status"], result["reason"]), ("failed", "never_dispatched"))
        self.assertFalse((self.run / "provider-observation.json").exists())
        self.setUp(); self.dispatch()
        self.assertEqual(self.settle(observation=False)["status"], "reconciliation_required")
        self.setUp(); self.dispatch()
        self.observation.update(started=False, terminated=True, returncode=None, turn_completed=False, reason="popen_failed")
        self.assertEqual(self.settle()["reason"], "provider_not_started")

    def test_started_observation_requires_dispatch_and_dispatch_cannot_repeat(self):
        with self.assertRaises((ValueError, OSError)):
            S.persist_observation(self.run, self.observation)
        self.dispatch()
        with self.assertRaisesRegex(ValueError, "provider_already_dispatched"):
            self.dispatch()
        S.persist_observation(self.run, self.observation)
        with self.assertRaises(ValueError):
            S.persist_observation(self.run, {**self.observation, "returncode": 1})

    def test_provider_failure_after_applied_is_hold_after_unchanged_is_failed(self):
        for outcome, expected in (("applied", "reconciliation_required"), ("unchanged", "failed")):
            with self.subTest(outcome=outcome):
                self.setUp(); self.dispatch(); self.write(outcome=outcome); self.finish_files()
                self.observation.update(returncode=1, turn_completed=False, reason="provider_failed")
                self.assertEqual(self.settle()["status"], expected)

    def test_claimed_ids_no_write_mismatch_and_nonzero_provider_return_refuse_success(self):
        for failure in ("ids", "outcome", "duplicate_ids", "return", "provider_error", "unexpected_tool", "tool_errors"):
            with self.subTest(failure=failure):
                self.setUp(); self.dispatch(); self.write()
                if failure == "ids": self.result["memory_ids"] = []
                elif failure == "outcome": self.result["outcome"] = "no_new_memories"
                elif failure == "duplicate_ids": self.result["memory_ids"] = [MEMORY, MEMORY]
                elif failure == "return": self.observation["returncode"] = 1
                else: self.observation[failure] = True if failure != "tool_errors" else 1
                self.finish_files()
                self.assertEqual(self.settle()["status"], "reconciliation_required")

    def test_audit_reordering_duplicate_typed_ids_and_unknown_events_hold(self):
        for failure in ("duplicate", "before_call", "missing_finish", "unknown", "truncated", "wrong_digest", "extra_intent"):
            with self.subTest(failure=failure):
                self.setUp(); self.dispatch(); self.write()
                if failure == "duplicate": self.audit.append(copy.deepcopy(self.audit[1]))
                elif failure == "before_call": self.audit[1], self.audit[2] = self.audit[2], self.audit[1]
                elif failure == "unknown": self.audit.append({"event": "unknown"})
                elif failure == "wrong_digest": self.audit[2]["operation_payload_digest"] = "e" * 64
                elif failure == "extra_intent": self.gateway.prepare("other", "remember", {"content": "x", "source": "fixture", "is_private": True})
                self.finish_files()
                path = self.run / "mcp-audit.jsonl"
                if failure == "missing_finish": path.write_bytes(b"\n".join(path.read_bytes().splitlines()[:-1]) + b"\n")
                if failure == "truncated": path.write_bytes(path.read_bytes()[:-1])
                self.assertEqual(self.settle()["status"], "reconciliation_required")

    def test_integer_and_string_call_ids_correlate_distinct_operations(self):
        self.dispatch(); self.write(7); self.write("7"); self.finish_files()
        result = self.settle()
        self.assertEqual(result["status"], "succeeded")
        self.assertEqual(result["applied_write_calls"], 2)

    def test_partial_intent_observation_and_dispatch_stay_held(self):
        for target in ("intent", "observation", "dispatch"):
            with self.subTest(target=target):
                self.setUp(); self.dispatch(); operation = self.write(); self.finish_files()
                S.persist_observation(self.run, self.observation)
                path = self.run / ({"intent": "operation-" + operation + ".json", "observation": "provider-observation.json",
                                    "dispatch": "provider-dispatch.json"}[target])
                path.write_bytes(b'{"partial":')
                self.assertEqual(self.settle(observation=False)["status"], "reconciliation_required")

    def test_validated_commit_ids_survive_later_unavailable_without_success(self):
        self.dispatch(); operation=self.write(); self.finish_files()
        J.record_response(self.run,operation,{"kind":"unavailable","reason":"transport_error"},
                          verify_fence=self.writer.verify)
        result=self.settle()
        self.assertEqual(result["status"],"reconciliation_required")
        self.assertEqual(result["applied_write_calls"],1)
        self.assertEqual(result["attempted_write_calls"],1)
        self.assertEqual(result["memory_ids"],[MEMORY])
        self.assertFalse(result["operations"][0]["settled"])
        self.assertFalse((self.run/"successful-coverage.json").exists())

    def test_malformed_other_operation_cannot_erase_validated_commit_ids(self):
        self.dispatch(); good=self.write(1); bad=self.write(2); self.finish_files()
        path=self.run/("operation-"+bad+".json")
        path.write_bytes(b'{"partial":')
        result=self.settle()
        self.assertEqual(result["status"],"reconciliation_required")
        self.assertEqual(result["applied_write_calls"],1)
        self.assertEqual(result["memory_ids"],[MEMORY])
        self.assertIn("invalid_operation_evidence",result["issues"])
        records={item["operation_id"]:item for item in result["operations"]}
        self.assertEqual(records[good]["receipt"]["memoryIDs"],[MEMORY])
        self.assertIs(records[bad]["dispatched"],None)
        self.assertIs(records[bad]["evidence_valid"],False)
        self.assertFalse((self.run/"successful-coverage.json").exists())

    def test_live_shared_or_closed_exclusive_fence_cannot_settle(self):
        with self.assertRaisesRegex(ValueError, "exclusive_fence_required"):
            S.settle(self.run, manifest_sha256=self.digest, recovery_fence=self.writer, validate_inputs=lambda *_: True)
        self.revoke().close()
        with self.assertRaises(ValueError): self.settle(observation=False)

    def test_validator_exact_true_and_no_alias_can_publish_success(self):
        self.dispatch(); self.read(); self.finish_files()
        for refused in (False, None, 1):
            with self.subTest(refused=refused), self.assertRaisesRegex(ValueError, "input_validation_refused"):
                self.settle(validate=lambda *_: refused)
            self.assertFalse((self.run / "settlement.json").exists())
        def validator(manifest, phase):
            manifest["source"]["end_offset"] = 999
            return True
        self.assertEqual(self.settle(validate=validator)["status"], "succeeded")

    def test_evidence_change_during_validation_or_after_settlement_invalidates_coverage(self):
        self.dispatch(); self.write(); self.finish_files()
        result = self.settle()
        audit = self.run / "mcp-audit.jsonl"
        original = audit.read_bytes()
        audit.write_bytes(original + b'{"event":"relay_started"}\n')
        with self.assertRaisesRegex(ValueError, "settlement_evidence_changed"):
            self.verify(result["settlement_sha256"])
        audit.write_bytes(original)
        # Identity is part of the sealed read, so restoring bytes is no repair.
        with self.assertRaises(ValueError): self.verify(result["settlement_sha256"])

    def test_validation_side_effects_cannot_publish_or_return_stale_success(self):
        for phase in ("before_settlement_publication", "after_coverage_publication"):
            with self.subTest(phase=phase):
                self.setUp(); self.dispatch(); self.read(); self.finish_files()
                def validator(_manifest, current):
                    if current == phase:
                        path = self.run / "mcp-audit.jsonl"
                        path.write_bytes(path.read_bytes() + b'{"event":"relay_started"}\n')
                    return True
                with self.assertRaisesRegex(ValueError, "evidence_changed"):
                    self.settle(validate=validator)
                if phase == "before_settlement_publication":
                    self.assertFalse((self.run / "settlement.json").exists())
                else:
                    digest = J.sha256((self.run / "settlement.json").read_bytes())
                    with self.assertRaises(ValueError): self.verify(digest)

    def test_observation_boolean_aliases_and_forged_coverage_binding_refuse(self):
        for key in ("started", "terminated", "turn_completed", "provider_error", "unexpected_tool"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                S.persist_observation(self.run, {**self.observation, key: 1})
        self.dispatch(); self.write(); self.finish_files(); self.settle()
        receipt = json.loads((self.run / "successful-coverage.json").read_bytes())
        request = J._json(J._unseal(self.manifest["inputs"]["request"]))
        binding = {"session_id": SID, "run_id": "fixture-run", "source": receipt["source"], "parser": receipt["parser"],
                   "admission": request["admission"]}
        for field in ("source", "parser", "admission"):
            forged = copy.deepcopy(binding)
            forged[field]["unrelated"] = True
            with self.subTest(field=field), self.assertRaises(ValueError):
                S.verify_coverage(self.run, receipt, forged, recovery_fence=self.recovery, validate_inputs=lambda *_: True)

    def test_interrupted_settlement_publication_never_manufactures_coverage(self):
        self.dispatch(); self.write(); self.finish_files(); self.revoke()
        S.persist_observation(self.run, self.observation)
        def crash(label):
            if label == "after_create": raise RuntimeError("fixture_death")
        with mock.patch.object(J, "_boundary", side_effect=crash):
            with self.assertRaisesRegex(RuntimeError, "fixture_death"):
                self.settle(observation=False)
        self.assertFalse((self.run / "successful-coverage.json").exists())
        with self.assertRaises(ValueError): self.settle(observation=False)

    def test_real_sigkill_settlement_and_coverage_preserve_immutable_prefix(self):
        for target in ("settlement.json", "successful-coverage.json"):
            for boundary in ("after_create", "after_write"):
                with self.subTest(target=target, boundary=boundary):
                    self.setUp(); self.dispatch(); self.write(); self.finish_files()
                    S.persist_observation(self.run, self.observation)
                    self.writer.close()
                    payload = {"run": str(self.run), "binding": self.binding, "manifest": self.digest,
                               "target": target, "boundary": boundary}
                    script = r'''
import json, os, signal, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from codex_learner import settlement as S
d=json.loads(sys.argv[2]); run=Path(d["run"])
fence=S.writer_fence.revoke(run,d["binding"],validate=lambda *_:True)
original=S.journal._publish
current=None
def publish(path,raw):
    global current
    current=path.name
    return original(path,raw)
def boundary(label):
    if current == d["target"] and label == d["boundary"]: os.kill(os.getpid(),signal.SIGKILL)
S.journal._publish=publish; S.journal._boundary=boundary
S.settle(run,manifest_sha256=d["manifest"],recovery_fence=fence,validate_inputs=lambda *_:True)
'''
                    child = subprocess.run([sys.executable, "-B", "-c", script, str(PLUGIN_ROOT / "scripts"), json.dumps(payload)],
                                           capture_output=True, text=True, timeout=15)
                    self.assertEqual(child.returncode, -signal.SIGKILL, child.stderr)
                    self.assertEqual((self.run / target).read_bytes() == b"", boundary == "after_create")
                    if boundary == "after_create":
                        with self.assertRaises(ValueError): self.settle(observation=False)
                    else:
                        result = self.settle(observation=False)
                        self.assertEqual(result["status"], "succeeded")
                        self.assertIsNotNone(result["coverage_reference"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
