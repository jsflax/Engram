"""Synthetic codec and actual private-filesystem custody; no hosted authenticity."""
import base64
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "codex/plugins/engram/scripts"))
from codex_learner import learner_publication_queue as q

VECTORS = ROOT / "Tests/Fixtures/LearnerPublicationQueue/v1.json"


def identity(number):
    return "00000000-0000-4000-8000-" + str(number).zfill(12)


class LearnerPublicationQueueTests(unittest.TestCase):
    def setUp(self):
        configured = os.environ.get("TMPDIR")
        scratch = Path(configured) if configured is not None else ROOT / ".build"
        self.assertTrue(scratch.is_absolute() and ".." not in scratch.parts)
        self.assertFalse(scratch.is_symlink())
        if configured is None:
            scratch.mkdir(mode=0o700, exist_ok=True)
        self.assertTrue(scratch.is_dir())
        self.assertEqual(scratch.resolve(strict=True), scratch)
        self.temp = tempfile.TemporaryDirectory(prefix="publication-queue-", dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        os.chmod(self.root, 0o700)
        self.vectors = json.loads(VECTORS.read_bytes())
        self.rows = {row["name"]: row for row in self.vectors["vectors"]}

    def data(self, name):
        return base64.b64decode(self.rows[name]["dataBase64"], validate=True)

    def candidate(self, number=1, kind="company"):
        value = q.decode(self.data("candidate_" + kind))
        value["operationID"] = identity(200 + number)
        value["candidateID"] = identity(100 + number)
        return q.canonical(value)

    def prepared(self, candidate):
        value = q.candidate(candidate)
        body = q._binding(candidate, value)
        body["backendDigest"] = "f" * 64
        # Deliberate noncanonical spelling: local byte hash is not backendDigest.
        return json.dumps(body, ensure_ascii=False, indent=2).encode()

    def receipt(self, candidate, prepared):
        value = q.prepared_body(prepared, candidate, q.candidate(candidate))
        return q.canonical({**value, "preparedBodySHA256": q.sha256(prepared),
                            "outcome": "committed", "committedIDs": [identity(900)]})

    def open(self, **kwargs):
        return q.LearnerPublicationQueue(str(self.root), "test-host", "test-account", **kwargs)

    def seed(self, queue, number=1, state="prepared"):
        candidate = self.candidate(number)
        op = q.candidate(candidate)["operationID"]
        queue.retain_candidate(candidate)
        prepared = self.prepared(candidate)
        if state != "candidate":
            queue.retain_prepared(op, prepared)
        if state in ("dispatch", "uncertain", "receipt"):
            queue.record_dispatch_started(op)
        if state == "uncertain":
            queue.record_uncertain(op, "lostResponse")
        receipt = self.receipt(candidate, prepared)
        if state == "receipt":
            queue.retain_receipt(op, receipt)
        return op, candidate, prepared, receipt

    def write(self, name, data):
        with open(self.root / name, "xb") as handle:
            os.chmod(handle.name, 0o600)
            handle.write(data)

    def test_shared_vectors_exact_bytes_strict_codec_and_separate_backend_digest(self):
        self.assertEqual(self.vectors["version"], 1)
        self.assertEqual(len(self.rows), len(self.vectors["vectors"]))
        self.assertEqual(len(self.rows), 27)
        for row in self.vectors["vectors"]:
            with self.subTest(vector=row["name"]):
                raw = self.data(row["name"])
                self.assertEqual(q.sha256(raw), row["sha256"])
                def inspect():
                    if row["kind"] == "candidate":
                        return q.candidate(raw)
                    if row["kind"] == "prepared":
                        candidate = self.data(row["candidate"])
                        return q.prepared_body(raw, candidate, q.candidate(candidate))
                    if row["kind"] == "receipt":
                        candidate = self.data(row["candidate"])
                        prepared = self.data(row["prepared"])
                        return q.receipt_body(raw, prepared, q.prepared_body(prepared, candidate, q.candidate(candidate)))
                    self.assertEqual(row["kind"], "json")
                    return q.decode(raw)
                if row["accepted"]:
                    self.assertEqual(q.canonical(inspect()), base64.b64decode(row["canonicalBase64"]))
                else:
                    with self.assertRaises(q.QueueError):
                        inspect()
        prepared = self.data("prepared_company")
        self.assertNotEqual(q.sha256(prepared), q.decode(prepared)["backendDigest"])

    def test_complete_four_destinations_and_hold_remain_separate_and_accounted(self):
        with self.open() as queue:
            for kind in ("private", "personal", "company", "team", "held"):
                queue.retain_candidate(self.data("candidate_" + kind))
            result = queue.recover()
            self.assertEqual(result.accounting, {"retained": 5, "heldLocal": 1, "pending": 4,
                                                "prepared": 0, "dispatchedUnknown": 0, "acknowledged": 0})
            self.assertFalse(result.session_complete)
            self.assertEqual({q.candidate(row.candidate_bytes)["destination"]["kind"] for row in result.records},
                             {"privateLocal", "personal", "company", "team", "heldLocal"})
            held = next(row for row in result.records if row.state == "heldLocal")
            with self.assertRaisesRegex(q.QueueError, "held_local"):
                queue.retain_prepared(held.operation_id, self.prepared(held.candidate_bytes))
            self.assertEqual(queue.recover(), result)

    def test_actual_close_reopen_at_every_stage_retains_exact_original_bytes(self):
        original = self.candidate()
        op = q.candidate(original)["operationID"]
        prepared = self.prepared(original)
        receipt = self.receipt(original, prepared)
        stages = [("pending", lambda x: x.retain_candidate(original)),
                  ("prepared", lambda x: x.retain_prepared(op, prepared)),
                  ("dispatchedUnknown", lambda x: x.record_dispatch_started(op)),
                  ("dispatchedUnknown", lambda x: x.record_uncertain(op, "lostResponse")),
                  ("acknowledged", lambda x: x.retain_receipt(op, receipt))]
        for state, mutation in stages:
            with self.open() as queue:
                mutation(queue)
            with self.open() as reopened:
                row, = reopened.recover().records
                self.assertEqual((row.operation_id, row.state, row.candidate_bytes), (op, state, original))
                if state != "pending":
                    self.assertEqual(row.prepared_bytes, prepared)
                    self.assertEqual(row.prepared_sha256, q.sha256(prepared))
                    self.assertNotEqual(row.prepared_sha256, row.backend_digest)
                if state == "acknowledged":
                    self.assertEqual(row.receipt_bytes, receipt)

    def test_lost_response_installs_exact_historical_receipt_once_without_retarget(self):
        with self.open() as queue:
            op, candidate, prepared, receipt = self.seed(queue, state="uncertain")
        with self.open() as queue:
            self.assertEqual(queue.recover().records[0].state, "dispatchedUnknown")
            first = queue.retain_receipt(op, receipt)
            files_before = {p.name: p.read_bytes() for p in self.root.iterdir()}
            self.assertEqual(queue.retain_receipt(op, receipt), first)
            queue.retain_candidate(candidate); queue.retain_prepared(op, prepared); queue.record_dispatch_started(op)
            self.assertEqual({p.name: p.read_bytes() for p in self.root.iterdir()}, files_before)
            with self.assertRaises(q.QueueError):
                queue.record_uncertain(op, "cancelled")
            self.assertEqual(queue.recover().records[0], first)

    def test_changed_principal_graph_evidence_payload_qualification_operation_and_prepared_refuse(self):
        with self.open() as queue:
            op, candidate, prepared, receipt = self.seed(queue, state="dispatch")
            good = q.decode(receipt)
            mutations = [{**good, "operationID": identity(999)}, {**good, "payloadSHA256": "0" * 64},
                         {**good, "coverageDigest": "0" * 64}, {**good, "qualificationDigest": "0" * 64},
                         {**good, "preparedBodySHA256": "0" * 64}, {**good, "backendDigest": "0" * 64},
                         {**good, "destination": {**good["destination"], "graphID": "foreign"}},
                         {**good, "destination": {**good["destination"], "principalID": "foreign"}}]
            before = queue.recover()
            for value in mutations:
                with self.assertRaises(q.QueueError):
                    queue.retain_receipt(op, q.canonical(value))
                self.assertEqual(queue.recover(), before)
            with self.assertRaises(q.QueueError):
                queue.retain_prepared(op, prepared + b" ")
            changed = q.decode(candidate); changed["destination"]["policyID"] = "different"
            with self.assertRaises(q.QueueError):
                queue.retain_candidate(q.canonical(changed))
            self.assertFalse((self.root / (op + ".receipt.json")).exists())

    def test_empty_queue_and_unavailable_hosted_adapter_never_complete_or_dispatch(self):
        with self.open() as queue:
            empty = queue.recover()
            self.assertEqual(empty.accounting["retained"], 0)
            self.assertFalse(empty.session_complete)
            op, _, _, _ = self.seed(queue, state="candidate")
            before = queue.recover()
            adapter = q.UnavailableHostedAdapter()
            for method in (adapter.prepare, adapter.apply, adapter.lookup):
                with self.assertRaisesRegex(q.QueueError, "hosted_adapter_unavailable"):
                    method(before.records[0])
            self.assertEqual(queue.recover(), before)
            self.assertFalse((self.root / (op + ".dispatch.json")).exists())

    def test_concurrent_owner_refusal_and_namespace_account_host_binding(self):
        with self.open() as first:
            self.seed(first, state="candidate")
            with self.assertRaises(q.QueueError):
                self.open()
            self.assertEqual(first.recover().accounting["retained"], 1)
        for host, account in (("test-host", "other"), ("other", "test-account")):
            with self.assertRaisesRegex(q.QueueError, "namespace_binding"):
                q.LearnerPublicationQueue(str(self.root), host, account)
        with self.open() as reopened:
            self.assertEqual(reopened.recover().accounting["retained"], 1)

    def test_candidate_and_operation_identity_conflicts_never_replace_bytes(self):
        with self.open() as queue:
            original = self.candidate()
            queue.retain_candidate(original)
            duplicate = q.decode(self.candidate(2))
            duplicate["candidateID"] = q.candidate(original)["candidateID"]
            with self.assertRaisesRegex(q.QueueError, "candidate_rebound"):
                queue.retain_candidate(q.canonical(duplicate))
            changed = q.decode(original); changed["content"] = "different"; changed["payloadSHA256"] = q.sha256(b"different")
            with self.assertRaisesRegex(q.QueueError, "candidate_conflict"):
                queue.retain_candidate(q.canonical(changed))
            self.assertEqual(queue.recover().records[0].candidate_bytes, original)

    def test_file_and_directory_fsync_faults_before_dispatch_return_no_dispatch_marker(self):
        for point in ("file_fsync", "directory_fsync"):
            with self.subTest(point=point):
                directory = self.root / point; directory.mkdir(mode=0o700)
                candidate = self.candidate()
                op = q.candidate(candidate)["operationID"]
                def fault(current, name):
                    if current == point and name.endswith(".candidate.json"):
                        raise OSError("synthetic durability failure")
                queue = q.LearnerPublicationQueue(str(directory), "test-host", "test-account", _fault=fault)
                with self.assertRaisesRegex(q.QueueError, "persistence_failed"):
                    queue.retain_candidate(candidate)
                with self.assertRaisesRegex(q.QueueError, "queue_unavailable"):
                    queue.recover()
                queue.close()
                self.assertFalse((directory / (op + ".dispatch.json")).exists())
                # A fully present surviving record is validated and actually
                # fsynced on reopen, never treated as transport success.
                with q.LearnerPublicationQueue(str(directory), "test-host", "test-account") as reopened:
                    self.assertEqual(reopened.recover().records[0].state, "pending")

    def test_dispatch_persistence_failure_recovers_unknown_and_preserves_all_bytes(self):
        with self.open() as queue:
            op, _, _, _ = self.seed(queue)
        def fault(point, name):
            if point == "directory_fsync" and name.endswith(".dispatch.json"):
                raise OSError("synthetic directory failure")
        queue = self.open(_fault=fault)
        with self.assertRaisesRegex(q.QueueError, "persistence_failed"):
            queue.record_dispatch_started(op)
        queue.close()
        retained = (self.root / (op + ".dispatch.json")).read_bytes()
        with self.open() as reopened:
            self.assertEqual(reopened.recover().records[0].state, "dispatchedUnknown")
        self.assertEqual((self.root / (op + ".dispatch.json")).read_bytes(), retained)

    def test_partial_write_and_corrupt_or_missing_predecessor_refuse_without_deleting(self):
        queue = self.open()
        candidate = self.candidate(); op = q.candidate(candidate)["operationID"]
        original_write = os.write
        def partial_write(descriptor, data):
            original_write(descriptor, data[:7])
            raise OSError("synthetic partial write failure")
        with patch.object(q.os, "write", side_effect=partial_write):
            with self.assertRaises(q.QueueError): queue.retain_candidate(candidate)
        queue.close()
        file = self.root / (op + ".candidate.json")
        self.assertEqual(file.read_bytes(), candidate[:7])
        with self.assertRaises(q.QueueError): self.open()
        self.assertTrue(file.exists())
        # Synthetic corruption setup only; the queue itself never repairs/deletes.
        file.write_bytes(candidate)
        with self.open() as queue:
            queue.retain_prepared(op, self.prepared(candidate)); queue.record_dispatch_started(op)
        file.write_bytes(candidate[:-1])
        with self.assertRaises(q.QueueError): self.open()
        self.assertEqual(file.read_bytes(), candidate[:-1])
        file.unlink()
        with self.assertRaises(q.QueueError): self.open()
        self.assertTrue((self.root / (op + ".prepared.json")).exists())

    def test_changed_valid_candidate_breaks_original_prepared_hash_chain(self):
        with self.open() as queue:
            op, candidate, _, _ = self.seed(queue, state="dispatch")
        value = q.decode(candidate); value["content"] = "different"; value["payloadSHA256"] = q.sha256(b"different")
        (self.root / (op + ".candidate.json")).write_bytes(q.canonical(value))
        with self.assertRaisesRegex(q.QueueError, "stage_chain"):
            self.open()

    def test_receipt_before_dispatch_and_reordered_uncertainty_refuse(self):
        with self.open() as queue:
            op, _, _, receipt = self.seed(queue)
            with self.assertRaisesRegex(q.QueueError, "stage_missing"):
                queue.retain_receipt(op, receipt)
            queue.record_dispatch_started(op); queue.retain_receipt(op, receipt)
        dispatch = (self.root / (op + ".dispatch.json")).read_bytes()
        self.write(op + ".uncertain.json", q.canonical({"version": 1, "stage": "uncertain", "operationID": op,
                   "priorSHA256": q.sha256(dispatch), "reason": "interrupted"}))
        with self.assertRaisesRegex(q.QueueError, "stage_chain"):
            self.open()

    def test_symlink_root_ancestor_member_and_unsafe_modes_refuse(self):
        with self.open(): pass
        outside = self.root.parent / (self.root.name + "-link")
        outside.symlink_to(self.root, target_is_directory=True)
        try:
            with self.assertRaises(q.QueueError):
                q.LearnerPublicationQueue(str(outside), "test-host", "test-account")
            nested = self.root / "nested"; nested.mkdir(mode=0o700)
            with self.assertRaises(q.QueueError):
                q.LearnerPublicationQueue(str(outside / "nested"), "test-host", "test-account")
            nested.rmdir()
        finally:
            outside.unlink()
        name = identity(201) + ".candidate.json"
        (self.root / name).symlink_to(self.root / "namespace.json")
        with self.assertRaises(q.QueueError): self.open()
        self.assertTrue((self.root / name).is_symlink())
        (self.root / name).unlink()
        os.link(self.root / "namespace.json", self.root / name)
        with self.assertRaises(q.QueueError): self.open()
        (self.root / name).unlink()
        os.mkfifo(self.root / name, 0o600)
        with self.assertRaisesRegex(q.QueueError, "unsafe_file"): self.open()
        (self.root / name).unlink()
        os.chmod(self.root / "namespace.json", 0o644)
        with self.assertRaises(q.QueueError): self.open()
        os.chmod(self.root / "namespace.json", 0o600)
        self.write("foreign.json", b"{}")
        with self.assertRaisesRegex(q.QueueError, "filename"): self.open()

    def test_root_or_lock_replacement_cannot_redirect_original_owner(self):
        with self.open() as queue:
            old = self.root / "old.lock"
            (self.root / ".owner.lock").rename(old)
            self.write(".owner.lock", b"")
            with self.assertRaisesRegex(q.QueueError, "lock_changed"):
                queue.recover()
            old.unlink()
        moved = self.root.parent / (self.root.name + "-moved")
        queue = self.open()
        self.root.rename(moved)
        self.root.mkdir(mode=0o700)
        try:
            with self.assertRaisesRegex(q.QueueError, "root_changed"):
                queue.recover()
        finally:
            queue.close()
            self.root.rmdir(); moved.rename(self.root)

    def test_fixed_record_evidence_and_integer_bounds_refuse_before_any_new_file(self):
        with self.open() as queue:
            before = set(self.root.iterdir())
            for raw in (b" " * (q.MAX_RECORD + 1), self.candidate() + b" " * q.MAX_RECORD):
                with self.assertRaises(q.QueueError): queue.retain_candidate(raw)
            value = q.decode(self.candidate())
            value["evidence"] = [{"id": "s" + str(i), "revision": "r", "digest": "a" * 64} for i in range(33)]
            with self.assertRaises(q.QueueError): queue.retain_candidate(q.canonical(value))
            self.assertEqual(set(self.root.iterdir()), before)
            self.assertEqual((q.MAX_RECORD, q.MAX_BODY, q.MAX_TOTAL, q.MAX_OPERATIONS, q.MAX_ENTRIES),
                             (131072, 65536, 33554432, 256, 1282))

    def test_actual_operation_capacity_refuses_without_evicting_prior_records(self):
        with self.open(): pass
        for number in range(256):
            self.write(identity(200 + number) + ".candidate.json", self.candidate(number))
        with self.open() as queue:
            before = queue.recover()
            self.assertEqual(before.accounting["retained"], 256)
            with self.assertRaisesRegex(q.QueueError, "operation_bound"):
                queue.retain_candidate(self.candidate(1000))
            self.assertEqual(queue.recover(), before)
        self.assertEqual(len(list(self.root.iterdir())), 258)

    def test_actual_aggregate_bound_is_checked_before_reading_excess_file(self):
        with self.open(): pass
        for number in range(256):
            data = self.candidate(number)
            self.write(identity(200 + number) + ".candidate.json", data + b" " * (q.MAX_RECORD - len(data)))
        with self.assertRaisesRegex(q.QueueError, "aggregate_bound"):
            self.open()
        self.assertEqual(len(list(self.root.iterdir())), 258)
        self.assertEqual((self.root / (identity(200) + ".candidate.json")).stat().st_size, q.MAX_RECORD)

    def test_lazy_entry_budget_stops_before_retaining_unbounded_directory(self):
        with self.open() as queue:
            class Entry:
                name = identity(1) + ".candidate.json"
            class Lazy:
                count = 0
                def __enter__(self): return self
                def __exit__(self, *_): pass
                def __iter__(self): return self
                def __next__(self):
                    self.count += 1
                    if self.count > q.MAX_ENTRIES + 1:
                        raise AssertionError("enumeration continued after cap")
                    return Entry()
            lazy = Lazy()
            with patch.object(q.os, "scandir", return_value=lazy):
                with self.assertRaisesRegex(q.QueueError, "entry_bound"):
                    queue._names()
            self.assertEqual(lazy.count, q.MAX_ENTRIES + 1)
            self.assertEqual(queue.recover().accounting["retained"], 0)

    def test_one_unresolved_dispatch_slot_preserves_debt_and_same_operation_replay(self):
        with self.open() as queue:
            first, _, _, receipt = self.seed(queue, number=1, state="dispatch")
            second, _, _, _ = self.seed(queue, number=2, state="prepared")
            queue.record_uncertain(first, "cancelled")
            queue.record_uncertain(first, "cancelled")
            with self.assertRaisesRegex(q.QueueError, "uncertain_conflict"):
                queue.record_uncertain(first, "unknown")
            before = queue.recover()
            self.assertEqual(queue.record_dispatch_started(first).state, "dispatchedUnknown")
            with self.assertRaisesRegex(q.QueueError, "unresolved_dispatch_capacity"):
                queue.record_dispatch_started(second)
            self.assertEqual(queue.recover(), before)
            self.assertFalse((self.root / (second + ".dispatch.json")).exists())
            queue.retain_receipt(first, receipt)
            self.assertEqual(queue.record_dispatch_started(second).state, "dispatchedUnknown")

    def test_live_instance_refuses_deletion_even_of_an_entire_pending_record(self):
        with self.open() as queue:
            op, _, _, _ = self.seed(queue, state="candidate")
            (self.root / (op + ".candidate.json")).unlink()
            with self.assertRaisesRegex(q.QueueError, "observed_history_changed"):
                queue.recover()

    def test_local_close_uncertainty_is_sticky_and_never_retries_descriptor_numbers(self):
        queue = self.open()
        queue.retain_candidate(self.candidate())
        original_close = os.close
        observed = []
        def close_then_report_error(descriptor):
            observed.append(descriptor)
            original_close(descriptor)
            raise OSError("synthetic close uncertainty")
        # The actual original closes; injection proves conservative refusal,
        # not a real OS close-error, descriptor-reuse race or transport join.
        with patch.object(q.os, "close", side_effect=close_then_report_error):
            with self.assertRaisesRegex(q.QueueError, "descriptor_close_failed"):
                queue.recover()
        self.assertGreaterEqual(len(observed), 2)
        with self.assertRaisesRegex(q.QueueError, "queue_unavailable"):
            queue.recover()
        with self.assertRaisesRegex(q.QueueError, "descriptor_close_failed"):
            queue.close()
        with patch.object(q.os, "close", wraps=original_close) as closer:
            with self.assertRaisesRegex(q.QueueError, "descriptor_close_failed"):
                queue.close()
            closer.assert_not_called()
        with self.open() as reopened:
            self.assertEqual(reopened.recover().accounting["retained"], 1)

    def test_decoder_node_depth_member_array_and_hostile_number_budgets(self):
        for raw in (b"[" * 18 + b"0" + b"]" * 18,
                    q.canonical({str(i): i for i in range(129)}),
                    q.canonical([0] * 1025), b'{"n":01}', b'{"n":Infinity}', b'\xef\xbb\xbf{}',
                    '{"é":1}'.encode()):
            with self.assertRaises(q.QueueError): q.decode(raw)
        self.assertEqual(q.decode(b'{"n":9007199254740991}')["n"], q.MAX_INTEGER)
        # 9 * 1000 scalar children stay within per-array/depth caps, but exceed nodes.
        with self.assertRaisesRegex(q.QueueError, "decode_budget"):
            q.decode(q.canonical([[0] * 1000 for _ in range(9)]))


if __name__ == "__main__":
    unittest.main()
