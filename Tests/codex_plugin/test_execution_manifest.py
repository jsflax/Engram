"""Private synthetic execution evidence, including real Python SIGKILL edges.

No provider, native binary, database, network, live cursor or app state is used.
"""
import copy
import importlib
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from suite_support import PLUGIN_ROOT, TEMP_ROOT

sys.path.insert(0, str(PLUGIN_ROOT / "scripts"))
M = importlib.import_module("codex_learner.execution_manifest")
SID = "01a0ad92-ed03-7ee1-b9bb-ccc17d2e3e05"
STORE = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
MEMORY = "11111111-2222-4333-8444-555555555555"


def held(_binding):
    return True


class ExecutionManifestTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="manifest-", dir=TEMP_ROOT)
        self.addCleanup(self.temporary.cleanup)
        self.run = Path(self.temporary.name).resolve()
        inputs = {name: M.seal_json(M.encode({"fixture": name})) for name in M.INPUT_NAMES}
        self.scope = {"version": 1, "storeID": STORE, "principal": {
            "id": None, "kind": "agent", "groupIds": [MEMORY], "scopes": ["memory", "café"]}}
        self.manifest = {"version": 1, "host": "fixture-host", "session_id": SID,
                         "run_id": "20261016T120000Z-fixture", "inputs": inputs,
                         "source": {"identity": {"scheme": "macos_volume_uuid_inode_v1",
                                                 "volume_uuid": STORE, "inode": 123},
                                    "start_offset": 100, "end_offset": 200, "excerpt_sha256": "a" * 64},
                         "expected_scope": self.scope, "backend": {
                             "route_id": "fixture-local", "runtime_sha256": "b" * 64,
                             "route_sha256": inputs["backend_route"]["sha256"],
                             "config_sha256": inputs["backend_config"]["sha256"]},
                         "fencing": {"protocol": M.FENCE_PROTOCOL, "epoch_id": STORE, "owner_id": MEMORY}}
        self.publish()
        self.operation = M.operation_id(self.run, "call-1")
        self.request = {"version": 1, "operationID": self.operation, "expectedScope": self.scope,
                        "provenance": {"host": self.manifest["host"], "sessionID": SID,
                                       "runID": self.manifest["run_id"], "source": {
                                           "startOffset": 100, "endOffset": 200, "excerptDigest": "a" * 64}},
                        "mutation": {"kind": "remember", "request": {
                            "content": "PRIVATE exact café\ncontent", "isPrivate": True, "expiresInDays": 14}}}
        self.raw = M.encode(self.request)

    def publish(self, manifest=None, **kwargs):
        return M.publish_manifest(self.run, manifest or self.manifest, verify_fence=kwargs.get("verify_fence", held))

    def intent(self, raw=None, **kwargs):
        return M.publish_intent(self.run, "call-1", self.raw if raw is None else raw,
                                verify_fence=kwargs.get("verify_fence", held))

    def receipt(self):
        return {"version": 1, "operationID": self.operation, "scope": copy.deepcopy(self.scope),
                "payloadDigest": "d" * 64, "mutation": "remember", "outcome": "applied",
                "memoryIDs": [MEMORY], "edgeIDs": [], "committedAt": 800000000.25}

    def respond(self, receipt=None):
        return M.record_response(self.run, self.operation,
                                 {"kind": "committed", "receipt": receipt or self.receipt()}, verify_fence=held)

    def snapshots(self):
        return {str(p.relative_to(self.run)): p.read_bytes() for p in self.run.rglob("*") if p.is_file()}

    def test_manifest_exact_inputs_and_immutable_binding(self):
        before = self.snapshots()
        manifest, digest = M.read_manifest(self.run)
        self.assertEqual(manifest, self.manifest)
        self.assertEqual(digest, self.publish())
        for name in M.INPUT_NAMES:
            self.assertEqual(M._unseal(manifest["inputs"][name]), M.encode({"fixture": name}))
        changed = copy.deepcopy(manifest)
        changed["inputs"]["parser_state"] = M.seal_json(b'{"changed":true}')
        with self.assertRaisesRegex(ValueError, "immutable_record_conflict"):
            self.publish(changed)
        self.assertEqual(before, self.snapshots())

    def test_uuid_stable_and_bound_to_call_and_immutable_run(self):
        self.assertEqual(self.operation, M.operation_id(self.run, "call-1"))
        self.assertNotEqual(self.operation, M.operation_id(self.run, "call-2"))
        other = self.run / "another"
        other.mkdir(mode=0o700)
        changed = copy.deepcopy(self.manifest)
        changed["run_id"] += "-different"
        M.publish_manifest(other, changed, verify_fence=held)
        self.assertNotEqual(self.operation, M.operation_id(other, "call-1"))

    def test_exact_request_bytes_private_before_dispatch_and_receipt(self):
        raw = b" \n" + self.raw + b"\n"
        self.assertEqual(self.intent(raw), raw)
        self.assertEqual(M.record_dispatch(self.run, self.operation, verify_fence=held), raw)
        self.respond()
        self.assertEqual(len(M.read_evidence(self.run, self.operation)), 2)
        self.assertEqual(M.read_intent(self.run, self.operation)[0], raw)
        for path in self.run.rglob("*"):
            self.assertEqual(path.stat().st_mode & 0o077, 0)
            if path.is_file():
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                if path.parent != self.run:
                    self.assertNotIn(b"PRIVATE", path.read_bytes())
        intent = M._json((self.run / ("operation-" + self.operation + ".json")).read_bytes())
        self.assertNotEqual(intent["local_json_sha256"], self.receipt()["payloadDigest"])

    def test_same_operation_different_payload_or_format_refused(self):
        self.intent()
        before = self.snapshots()
        for mutate in (lambda r: r["mutation"]["request"].update(content="PRIVATE changed"),
                       lambda r: r["mutation"]["request"].update(expiresInDays=30)):
            request = copy.deepcopy(self.request)
            mutate(request)
            with self.assertRaisesRegex(ValueError, "immutable_record_conflict"):
                self.intent(M.encode(request))
        with self.assertRaisesRegex(ValueError, "immutable_record_conflict"):
            self.intent(self.raw + b"\n")
        self.assertEqual(before, self.snapshots())

    def test_request_scope_provenance_and_unknown_fields_fail_before_intent(self):
        for mutate in (lambda r: r.update(version=True), lambda r: r.update(version=2),
                       lambda r: r.update(payloadDigest="d" * 64),
                       lambda r: r.update(operationID=MEMORY),
                       lambda r: r["expectedScope"].update(storeID=MEMORY),
                       lambda r: r["provenance"]["source"].update(endOffset=201)):
            request = copy.deepcopy(self.request)
            mutate(request)
            with self.assertRaises(ValueError):
                self.intent(M.encode(request))
        self.assertEqual(len(self.snapshots()), 1)

    def test_supported_mutations_preserve_optional_and_signed_semantics(self):
        mutations = [
            {"kind": "remember", "request": {"content": "retained", "isPrivate": False, "expiresInDays": -3}},
            {"kind": "update", "request": {"id": MEMORY, "undelete": False, "append": "\r\ne\u0301  ", "expiresInDays": -2}},
            {"kind": "update", "request": {"id": MEMORY, "undelete": False, "find": "", "replace": "", "isPrivate": False}},
            {"kind": "update", "request": {"id": MEMORY, "undelete": False, "importance": 0}},
            {"kind": "update", "request": {"id": MEMORY, "undelete": False, "source": ""}},
            {"kind": "connect", "request": {"sourceId": MEMORY, "targetId": STORE, "relation": "derived_from"}}]
        for index, mutation in enumerate(mutations):
            call = "mutation-" + str(index)
            request = copy.deepcopy(self.request)
            request.update(operationID=M.operation_id(self.run, call), mutation=mutation)
            raw = M.encode(request)
            self.assertEqual(M.publish_intent(self.run, call, raw, verify_fence=held), raw)

    def test_invalid_mutation_fields_fail_closed(self):
        mutations = [
            {"kind": "forget", "request": {}},
            {"kind": "remember", "request": {"content": "", "isPrivate": False}},
            {"kind": "remember", "request": {"content": "PRIVATE", "isPrivate": 1}},
            {"kind": "remember", "request": {"content": "PRIVATE", "isPrivate": True, "importance": 0}},
            {"kind": "remember", "request": {"content": "PRIVATE", "isPrivate": True, "expiresInDays": True}},
            {"kind": "update", "request": {"id": MEMORY, "undelete": True, "append": "PRIVATE"}},
            {"kind": "update", "request": {"id": MEMORY, "undelete": False, "content": "PRIVATE", "append": "PRIVATE"}},
            {"kind": "update", "request": {"id": MEMORY, "undelete": False, "find": "PRIVATE"}},
            {"kind": "update", "request": {"id": MEMORY, "undelete": False}},
            {"kind": "connect", "request": {"sourceId": MEMORY, "targetId": STORE, "relation": "unknown"}}]
        for mutation in mutations:
            request = copy.deepcopy(self.request)
            request["mutation"] = mutation
            with self.assertRaises(ValueError) as error:
                self.intent(M.encode(request))
            self.assertNotIn("PRIVATE", str(error.exception))
        self.assertEqual(len(self.snapshots()), 1)

    def test_receipt_scope_uuid_kind_digest_and_results_are_bound(self):
        self.intent()
        self.respond()
        before = self.snapshots()
        mutations = [lambda r: r.update(operationID=MEMORY), lambda r: r["scope"].update(storeID=MEMORY),
                     lambda r: r.update(mutation="connect"), lambda r: r.update(payloadDigest="e" * 64),
                     lambda r: r.update(committedAt=800000001), lambda r: r.update(memoryIDs=[STORE]),
                     lambda r: r.update(content="PRIVATE"), lambda r: r.update(memoryIDs=[MEMORY, MEMORY])]
        for mutation in mutations:
            receipt = self.receipt()
            mutation(receipt)
            with self.assertRaises(ValueError):
                self.respond(receipt)
        self.assertEqual(before, self.snapshots())

    def test_scope_uuid_case_unordered_membership_and_unicode_equivalence(self):
        self.intent()
        receipt = self.receipt()
        receipt["operationID"] = receipt["operationID"].upper()
        receipt["memoryIDs"] = [MEMORY.upper()]
        receipt["scope"]["storeID"] = STORE.upper()
        receipt["scope"]["principal"].update(groupIds=[MEMORY.upper(), MEMORY], scopes=["cafe\u0301", "memory", "memory"])
        self.respond(receipt)
        self.respond()
        self.assertEqual(len(M.read_evidence(self.run, self.operation)), 2)

    def test_absence_never_permits_redispatch(self):
        self.intent()
        M.record_dispatch(self.run, self.operation, verify_fence=held)
        M.record_response(self.run, self.operation, {"kind": "absent", "operationID": self.operation,
                                                   "scope": self.scope}, verify_fence=held)
        with self.assertRaisesRegex(ValueError, "redispatch_requires_reconciliation"):
            M.record_dispatch(self.run, self.operation, verify_fence=held)
        self.respond()
        with self.assertRaisesRegex(ValueError, "committed_operation_became_absent"):
            M.record_response(self.run, self.operation, {"kind": "absent", "operationID": self.operation,
                                                       "scope": self.scope}, verify_fence=held)

    def test_fencing_required_and_checked_before_every_publication(self):
        before = self.snapshots()
        for verifier in (None, lambda _: False, lambda _: None):
            with self.assertRaises(ValueError):
                self.intent(verify_fence=verifier)
        self.assertEqual(before, self.snapshots())
        self.intent()
        before = self.snapshots()
        with self.assertRaisesRegex(ValueError, "fence_not_held"):
            M.record_dispatch(self.run, self.operation, verify_fence=lambda _: False)
        self.assertEqual(before, self.snapshots())
        self.assertFalse((self.run / ("evidence-" + self.operation)).exists())
        fence_calls = []
        def verifier(binding):
            fence_calls.append(binding)
            return True
        M.record_dispatch(self.run, self.operation, verify_fence=verifier)
        self.assertGreaterEqual(len(fence_calls), 3)
        self.assertTrue(all(b == self.manifest["fencing"] for b in fence_calls))

    def test_missing_prerequisite_metadata_cannot_publish(self):
        for field in ("fencing", "backend", "expected_scope"):
            value = copy.deepcopy(self.manifest)
            del value[field]
            with self.assertRaises(ValueError):
                self.publish(value)
        for field in M.INPUT_NAMES:
            value = copy.deepcopy(self.manifest)
            del value["inputs"][field]
            with self.assertRaises(ValueError):
                self.publish(value)

    def test_duplicate_json_nonfinite_surrogates_and_oversize_rejected(self):
        for raw in (b'{"version":1,"version":1}', b'{"x":NaN}', b'{"x":"\\ud800"}',
                    b'{"x":' + b'1' * (M.MAX_INPUT + 1) + b'}', b'{}\n{}', b'[]'):
            with self.assertRaises(ValueError):
                self.intent(raw)

    def test_truncated_or_malformed_records_are_not_repaired(self):
        path = self.run / ("operation-" + self.operation + ".json")
        path.write_bytes(b'{"PRIVATE":')
        path.chmod(0o600)
        before = self.snapshots()
        for action in (self.intent, lambda: M.read_intent(self.run, self.operation),
                       lambda: M.record_dispatch(self.run, self.operation, verify_fence=held)):
            with self.assertRaises(ValueError) as error:
                action()
            self.assertNotIn("PRIVATE", str(error.exception))
        self.assertEqual(before, self.snapshots())

    def test_event_truncation_gap_and_chain_tampering_fail_closed(self):
        self.intent()
        M.record_dispatch(self.run, self.operation, verify_fence=held)
        self.respond()
        directory = self.run / ("evidence-" + self.operation)
        last = directory / "000001.json"
        original = last.read_bytes()
        last.write_bytes(b'{')
        with self.assertRaises(ValueError):
            M.read_evidence(self.run, self.operation)
        last.write_bytes(original)
        altered = M._json(original)
        altered["previous_sha256"] = "0" * 64
        last.write_bytes(M.encode(altered))
        with self.assertRaisesRegex(ValueError, "event_binding_mismatch"):
            M.read_evidence(self.run, self.operation)
        last.write_bytes(original)
        last.rename(directory / "000002.json")
        with self.assertRaisesRegex(ValueError, "event_sequence_invalid"):
            M.read_evidence(self.run, self.operation)

    def test_symlink_hardlink_and_nonprivate_intent_rejected(self):
        target = self.run / "fixture.json"
        target.write_bytes(self.raw)
        target.chmod(0o600)
        path = self.run / ("operation-" + self.operation + ".json")
        path.symlink_to(target)
        with self.assertRaises(ValueError):
            self.intent()
        path.unlink()
        os.link(target, path)
        with self.assertRaises(ValueError):
            self.intent()
        path.unlink()
        self.intent()
        path.chmod(0o644)
        with self.assertRaises(ValueError):
            M.read_intent(self.run, self.operation)

    def child(self, boundary, *, dispatch=False):
        fixture = self.run / "fixture-native.json"
        fixture.write_bytes(self.raw)
        fixture.chmod(0o600)
        code = """
import os,signal,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
from codex_learner import execution_manifest as m
root=Path(sys.argv[2]); phase=sys.argv[3]
def boundary(label):
    if label==phase: os.kill(os.getpid(),signal.SIGKILL)
m._boundary=boundary
if sys.argv[4]=='dispatch':
    m.record_dispatch(root,m.operation_id(root,'call-1'),verify_fence=lambda _:True)
else:
    m.publish_intent(root,'call-1',(root/'fixture-native.json').read_bytes(),verify_fence=lambda _:True)
raise SystemExit(23)
"""
        result = subprocess.run([sys.executable, "-B", "-c", code, str(PLUGIN_ROOT / "scripts"),
                                 str(self.run), boundary, "dispatch" if dispatch else "intent"],
                                capture_output=True, timeout=20, check=False)
        self.assertEqual(result.returncode, -signal.SIGKILL, result.stderr.decode())
        self.assertEqual(result.stdout, b"")

    def test_actual_crash_before_intent_publish_never_dispatches(self):
        self.child("before_create")
        with self.assertRaises(ValueError):
            M.record_dispatch(self.run, self.operation, verify_fence=held)
        self.assertEqual(self.intent(), self.raw)
        self.assertEqual(M.read_evidence(self.run, self.operation), [])

    def test_actual_crash_after_create_leaves_blocking_partial_intent(self):
        self.child("after_create")
        path = self.run / ("operation-" + self.operation + ".json")
        self.assertEqual(path.read_bytes(), b"")
        with self.assertRaisesRegex(ValueError, "immutable_record_conflict"):
            self.intent()
        with self.assertRaises(ValueError):
            M.record_dispatch(self.run, self.operation, verify_fence=held)

    def test_actual_crash_after_intent_durability_retains_exact_stable_request(self):
        self.child("after_directory_fsync")
        self.assertEqual(M.read_intent(self.run, self.operation)[0], self.raw)
        self.assertEqual(self.intent(), self.raw)
        self.assertEqual(M.record_dispatch(self.run, self.operation, verify_fence=held), self.raw)

    def test_actual_crash_after_dispatch_durable_is_ambiguous_not_retryable(self):
        self.intent()
        self.child("after_directory_fsync", dispatch=True)
        self.assertEqual(len(M.read_evidence(self.run, self.operation)), 1)
        with self.assertRaisesRegex(ValueError, "redispatch_requires_reconciliation"):
            M.record_dispatch(self.run, self.operation, verify_fence=held)

    def test_actual_crash_during_dispatch_publication_fails_closed(self):
        self.intent()
        self.child("after_create", dispatch=True)
        directory = self.run / ("evidence-" + self.operation)
        self.assertEqual((directory / "000000.json").read_bytes(), b"")
        with self.assertRaises(ValueError):
            M.read_evidence(self.run, self.operation)
        with self.assertRaises(ValueError):
            M.record_dispatch(self.run, self.operation, verify_fence=held)

    def test_fence_lost_after_durable_record_prevents_forwarding_return(self):
        self.intent()
        calls = []
        def fence(_):
            calls.append(1)
            return len(calls) < 3
        with self.assertRaisesRegex(ValueError, "fence_not_held"):
            M.record_dispatch(self.run, self.operation, verify_fence=fence)
        self.assertEqual(len(M.read_evidence(self.run, self.operation)), 1)
        with self.assertRaisesRegex(ValueError, "redispatch_requires_reconciliation"):
            M.record_dispatch(self.run, self.operation, verify_fence=held)


if __name__ == "__main__":
    unittest.main()
