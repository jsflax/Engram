"""Owned fixture-only migration/recovery tests; process/native/store effects blocked."""
import fcntl
import importlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import sys
import types
import unittest
from unittest import mock

import test_frontier as F

M = None


def setUpModule():
    global M
    F.setUpModule()
    M = importlib.import_module(F.PACKAGE + ".migration")


def tearDownModule():
    F.tearDownModule()


class MigrationFixture:
    def __init__(self, base):
        self.base = base
        self.root = F.private_directory(base / "state")
        self.sessions = F.private_directory(base / "rollouts")
        self.project = F.private_directory(base / "project")
        for name in ("enrollments", "sessions", "admissions", "pending"):
            F.private_directory(self.root / name)
        for path in (self.root / "worker.lock", self.root / "enqueue.lock", base / "learner-provider.lock"):
            path.touch(mode=0o600)
        self.policy = {"schema_version": 1, "mode": "host_sessions_v1", "enabled": True,
                       "activation_id": F.ACTIVATION, "cutoff": F.CUTOFF,
                       "state_dir": str(self.root), "sessions_dir": F.Fixture.binding(self.sessions)}
        F.write_json(self.root / "admission.json", self.policy)
        self.route = base / "routes.json"
        F.write_json(self.route, {"schema_version": 1, "mode": "host_sessions_v1", "enabled": True, "state_dir": str(self.root)})
        self.tasks = {}

    def task(self, n=1, *, cursor=True, pending=True, paused=True, gated=True):
        sid = F.uuid7(F.ORIGIN, suffix=n)
        folder = F.private_directory(self.sessions / "2026/01/02")
        path = folder / ("rollout-2026-01-02T00-00-00-" + sid + ".jsonl")
        meta = {"type": "session_meta", "ordinal": 0, "payload": {
            "id": sid, "timestamp": F.CREATED, "cwd": str(self.project), "source": "vscode", "cli_version": "fixture"}}
        path.write_text(json.dumps(meta) + "\n")
        payload = {"session_id": sid, "transcript_path": str(path), "cwd": str(self.project), "agent_id": sid}
        origin = M.host_admission._origin(self.policy, payload)
        frontier = M.admission._frontier(origin)
        entry = {**origin, **frontier, "activation_id": F.ACTIVATION, "captured_at": "2026-01-02T00:00:02Z"}
        F.write_json(self.root / "enrollments" / (sid + ".json"), entry)
        with path.open("a") as stream:
            stream.write(json.dumps({"type": "response_item", "ordinal": 1, "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "fixture durable fact"}]}}) + "\n")
        binding = M._binding(entry, self.policy, (self.root / "admission.json").read_bytes())
        state = {"session_id": sid, "transcript_path": str(path), "device": entry["device"], "inode": entry["inode"],
                 "offset": frontier["frontier_offset"], "admission": binding, "recent_messages": ["saved-dedup"],
                 "last_excerpt_sha256": "a" * 64, "current_turn_id": "turn-one", "status": "failed"}
        if gated:
            state["reconciliation_required"] = {"run_id": "historical-unknown", "memory_ids": ["unaltered-id"]}
        request = {"session_id": sid, "hook_session_id": sid, "transcript_path": str(path), "device": entry["device"],
                   "inode": entry["inode"], "cwd": str(self.project), "hook_cwd": str(self.project), "admission": binding,
                   "request_id": "fixture-request-" + str(n), "event": "Stop", "turn_id": "turn-one", "size_bytes": path.stat().st_size}
        if paused:
            request.update(paused_request_id=request["request_id"], pause_reason="reconciliation_required", backoff_until="2099-01-01")
        record = {"binding": binding, "state_sha256": M.object_digest(state), "last_event": "e" * 64, "processing": None}
        if cursor:
            F.write_json(self.root / "sessions" / (sid + ".json"), state)
            F.write_json(self.root / "admissions" / (sid + ".json"), record)
        if pending:
            F.write_json(self.root / "pending" / (sid + ".json"), request)
        self.tasks[sid] = {"entry": entry, "state": state, "record": record, "request": request, "path": path}
        return sid


class MigrationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.fixture = MigrationFixture(self.base)
        self.root, self.route = self.fixture.root, self.fixture.route
        self.uuid = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        capture = mock.patch.object(M.file_identity, "capture_fd", side_effect=lambda fd: {
            "scheme": "macos_volume_uuid_inode_v1", "volume_uuid": self.uuid, "inode": os.fstat(fd).st_ino})
        capture.start()
        self.addCleanup(capture.stop)
        self.sid = self.fixture.task()

    def prepare(self, ids=None, **kwargs):
        return M.prepare(self.root, self.route, ids or [self.sid], authorize_current_volume_adoption=True, **kwargs)

    def apply(self, plan):
        return M.apply(self.root, plan, M.digest(M.encode(plan)))

    def snapshot(self):
        return {str(p.relative_to(self.base)): p.read_bytes() for p in self.base.rglob("*") if p.is_file()}

    def test_plan_is_read_only_and_records_absence(self):
        sid2 = self.fixture.task(2, cursor=False, pending=False)
        before = self.snapshot()
        plan = self.prepare([self.sid, sid2])
        self.assertEqual(before, self.snapshot())
        self.assertFalse(plan["historical_volume_continuity_proven"])
        self.assertTrue(plan["owner_authorized_current_volume_adoption"])
        absent = [r for r in plan["records"] if r["preimage"] is None]
        self.assertEqual(len(absent), 3)

    def test_explicit_authorization_and_bounded_selection(self):
        with self.assertRaisesRegex(ValueError, "explicit_identity_adoption_authorization_required"):
            M.prepare(self.root, self.route, [self.sid])
        with self.assertRaisesRegex(ValueError, "invalid_selection"):
            self.prepare([self.sid, self.sid])
        with self.assertRaisesRegex(ValueError, "invalid_selection"):
            self.prepare([F.uuid7(F.ORIGIN, suffix=n) for n in range(33)])

    def test_apply_preserves_every_nonidentity_field_and_other_task(self):
        other = self.fixture.task(2)
        before_other = {name: path.read_bytes() for name, path in M._paths(self.root, other).items()}
        plan = self.prepare()
        result = self.apply(plan)
        self.assertEqual(result["status"], "migration_complete_held")
        self.assertFalse(result["learner_started"])
        for name, path in M._paths(self.root, other).items():
            self.assertEqual(before_other[name], path.read_bytes())
        old = self.fixture.tasks[self.sid]
        for name, key in (("sessions", "state"), ("pending", "request")):
            actual = json.loads(M._paths(self.root, self.sid)[name].read_bytes())
            original = old[key]
            self.assertEqual({k: v for k, v in actual.items() if k not in {"identity", "admission"}},
                             {k: v for k, v in original.items() if k not in {"device", "inode", "admission"}})
        record = json.loads(M._paths(self.root, self.sid)["admissions"].read_bytes())
        self.assertEqual(record["last_event"], old["record"]["last_event"])
        self.assertEqual(record["legacy_event_identity"], {"device": old["entry"]["device"], "inode": old["entry"]["inode"]})
        request = json.loads(M._paths(self.root, self.sid)["pending"].read_bytes())
        with self.assertRaisesRegex(ValueError, "migration_held"):
            M.host_admission.check(self.root, request)

    def test_previously_unpaused_request_is_ineligible_until_explicit_release(self):
        sid = self.fixture.task(2, paused=False, gated=False)
        plan = self.prepare([sid])
        self.apply(plan)
        request = json.loads(M._paths(self.root, sid)["pending"].read_bytes())
        self.assertNotIn("paused_request_id", request)
        with self.assertRaisesRegex(ValueError, "migration_held"):
            M.host_admission.check(self.root, request)
        sha = M.digest(M.encode(plan))
        release = M.prepare_release(self.root, plan, sha, [sid])
        before = {p: p.read_bytes() for p in M._paths(self.root, sid).values()}
        result = M.release(self.root, plan, sha, release, M.digest(M.encode(release)))
        self.assertFalse(result["learner_started"])
        self.assertEqual(before, {p: p.read_bytes() for p in before})
        self.assertEqual(M.host_admission.check(self.root, request), request["admission"])

    def test_disabled_route_and_policy_stay_disabled(self):
        policy = {**self.fixture.policy, "enabled": False}
        F.write_json(self.root / "admission.json", policy)
        F.write_json(self.route, {"schema_version": 1, "mode": "host_sessions_v1", "enabled": False, "state_dir": str(self.root)})
        # Rebuild this selected chain against the intentionally disabled policy.
        old = self.fixture.tasks[self.sid]
        binding = M._binding(old["entry"], policy, (self.root / "admission.json").read_bytes())
        state = {**old["state"], "admission": binding}
        F.write_json(M._paths(self.root, self.sid)["sessions"], state)
        F.write_json(M._paths(self.root, self.sid)["admissions"], {**old["record"], "binding": binding, "state_sha256": M.object_digest(state)})
        F.write_json(M._paths(self.root, self.sid)["pending"], {**old["request"], "admission": binding})
        self.apply(self.prepare())
        self.assertIs(json.loads((self.root / "admission.json").read_bytes())["enabled"], False)
        self.assertIs(json.loads(self.route.read_bytes())["enabled"], False)

    def test_later_selected_migration_retains_v2_policy_bytes_and_digest(self):
        second = self.fixture.task(2)
        first = self.prepare()
        self.apply(first)
        policy = (self.root / "admission.json").read_bytes()
        legacy = self.root / "migrations" / M.digest(M.encode(first)) / "legacy-policy.json"
        later = self.prepare([second], legacy_policy_path=legacy)
        self.apply(later)
        self.assertEqual((self.root / "admission.json").read_bytes(), policy)
        self.assertEqual(M._unb64(later["records"][-1]["candidate"]), policy)

    def test_no_pending_and_no_cursor_are_supported_without_creation(self):
        sid = self.fixture.task(2, cursor=False, pending=False)
        plan = self.prepare([sid])
        self.apply(plan)
        for name in ("admissions", "sessions", "pending"):
            self.assertFalse(M._paths(self.root, sid)[name].exists())

    def test_no_pending_existing_cursor_is_preserved(self):
        sid = self.fixture.task(2, pending=False)
        self.apply(self.prepare([sid]))
        self.assertFalse(M._paths(self.root, sid)["pending"].exists())
        self.assertTrue(M._paths(self.root, sid)["sessions"].exists())

    def test_legacy_device_drift_is_explicitly_adopted_but_inode_change_is_rejected(self):
        # Rewrite only historical device values, consistently across legacy chain.
        for path in [self.root / "admission.json", *M._paths(self.root, self.sid).values()]:
            value = json.loads(path.read_bytes())
            def walk(item):
                if isinstance(item, dict):
                    for k, v in item.items():
                        if k == "device": item[k] = v + 111
                        else: walk(v)
            walk(value)
            F.write_json(path, value)
        self._repair_fixture_chain()
        self.apply(self.prepare())

    def _repair_fixture_chain(self):
        paths = M._paths(self.root, self.sid)
        policy = json.loads((self.root / "admission.json").read_bytes())
        entry = json.loads(paths["enrollments"].read_bytes())
        binding = M._binding(entry, policy, (self.root / "admission.json").read_bytes())
        state = json.loads(paths["sessions"].read_bytes())
        state["admission"] = binding
        F.write_json(paths["sessions"], state)
        record = json.loads(paths["admissions"].read_bytes())
        record.update(binding=binding, state_sha256=M.object_digest(state))
        F.write_json(paths["admissions"], record)
        request = json.loads(paths["pending"].read_bytes())
        request["admission"] = binding
        F.write_json(paths["pending"], request)

    def test_altered_inode_metadata_or_frontier_is_rejected(self):
        path = M._paths(self.root, self.sid)["enrollments"]
        original = path.read_bytes()
        for key, value in (("inode", 1), ("initial_meta_sha256", "f" * 64), ("frontier_anchor_sha256", "f" * 64)):
            with self.subTest(key=key):
                entry = json.loads(original)
                entry[key] = value
                F.write_json(path, entry)
                with self.assertRaises(ValueError): self.prepare()
        path.write_bytes(original)

    def test_active_processing_and_state_digest_mismatch_refuse(self):
        path = M._paths(self.root, self.sid)["admissions"]
        original = json.loads(path.read_bytes())
        for change in ({"processing": "running-request"}, {"state_sha256": "0" * 64}):
            F.write_json(path, {**original, **change})
            with self.assertRaises(ValueError): self.prepare()

    def test_stale_cas_refuses_before_journal_or_hold(self):
        plan = self.prepare()
        path = M._paths(self.root, self.sid)["pending"]
        value = json.loads(path.read_bytes())
        F.write_json(path, {**value, "newer": True})
        with self.assertRaisesRegex(ValueError, "cas_mismatch"):
            self.apply(plan)
        self.assertFalse((self.root / "migrations").exists())
        self.assertFalse((self.root / "migration-holds").exists())

    def test_absent_record_creation_after_plan_refuses(self):
        sid = self.fixture.task(2, cursor=False, pending=False)
        plan = self.prepare([sid])
        F.write_json(M._paths(self.root, sid)["pending"], {"unexpected": True})
        with self.assertRaises(ValueError): self.apply(plan)

    def test_symlink_and_nonprivate_preimage_refuse(self):
        path = M._paths(self.root, self.sid)["pending"]
        original = path.read_bytes()
        path.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "unsafe_file"): self.prepare()
        path.unlink()
        replacement = self.base / "other.json"
        replacement.write_bytes(original)
        replacement.chmod(0o600)
        path.symlink_to(replacement)
        with self.assertRaisesRegex(ValueError, "unsafe_file"): self.prepare()

    def test_plan_candidate_tampering_is_recomputed_and_refused(self):
        plan = self.prepare()
        record = plan["records"][1]
        value = M.admission._json(M._unb64(record["candidate"]))
        value.pop("reconciliation_required")
        raw = M.encode(value)
        record.update(candidate=M._b64(raw), candidate_sha256=M.digest(raw))
        with self.assertRaisesRegex(ValueError, "candidate_transformation_invalid"):
            self.apply(plan)

    def test_different_current_volume_same_inode_refuses_reviewed_plan(self):
        plan = self.prepare()
        self.uuid = "bbbbbbbb-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        with self.assertRaises(ValueError): self.apply(plan)

    def test_runtime_change_refuses(self):
        plan = self.prepare()
        with mock.patch.object(M, "_runtime", return_value={"different": "0" * 64}):
            with self.assertRaisesRegex(ValueError, "runtime_changed"): self.apply(plan)

    def test_partial_every_publication_recovers_without_unpausing(self):
        for cut in ("transitional-policy", 0, 1, 2, 3, 4, "final-policy"):
            with self.subTest(cut=cut):
                other_base = F.private_directory(self.base / ("partial-" + str(cut)))
                fixture = MigrationFixture(other_base)
                sid = fixture.task(paused=False)
                plan = M.prepare(fixture.root, fixture.route, [sid], authorize_current_volume_adoption=True)
                sha = M.digest(M.encode(plan))
                real = M._publish
                def crash(record, work, index):
                    real(record, work, index)
                    if index == cut:
                        raise RuntimeError("injected interruption after atomic rename")
                with mock.patch.object(M, "_publish", side_effect=crash):
                    with self.assertRaisesRegex(RuntimeError, "injected interruption"):
                        M.apply(fixture.root, plan, sha)
                hold = fixture.root / "migration-holds" / (sid + ".json")
                self.assertEqual(hold.exists(), cut != "transitional-policy")
                result = M.recover(fixture.root, plan, sha)
                self.assertEqual(result["status"], "migration_complete_held")
                M.recover(fixture.root, plan, sha)  # Idempotent exact completed journal.
                state = json.loads(M._paths(fixture.root, sid)["sessions"].read_bytes())
                self.assertEqual(state["reconciliation_required"], fixture.tasks[sid]["state"]["reconciliation_required"])

    def test_partial_recovery_never_overwrites_newer_state(self):
        plan = self.prepare()
        real = M._publish
        def crash(record, work, index):
            real(record, work, index)
            raise RuntimeError("stop")
        with mock.patch.object(M, "_publish", side_effect=crash):
            with self.assertRaises(RuntimeError): self.apply(plan)
        path = M._paths(self.root, self.sid)["sessions"]
        F.write_json(path, {"newer": "must survive"})
        newer = path.read_bytes()
        with self.assertRaisesRegex(ValueError, "cas_mismatch"):
            M.recover(self.root, plan, M.digest(M.encode(plan)))
        self.assertEqual(path.read_bytes(), newer)

    def test_nonprefix_candidates_are_rejected(self):
        plan = self.prepare()
        target = plan["records"][2]
        Path(target["path"]).write_bytes(M._unb64(target["candidate"]))
        with self.assertRaisesRegex(ValueError, "nonprefix_publication"):
            M.recover(self.root, plan, M.digest(M.encode(plan)))

    def test_hold_replacement_or_chain_change_blocks_release(self):
        plan = self.prepare()
        self.apply(plan)
        sha = M.digest(M.encode(plan))
        release = M.prepare_release(self.root, plan, sha, [self.sid])
        hold = self.root / "migration-holds" / (self.sid + ".json")
        hold.write_bytes(hold.read_bytes())
        with self.assertRaisesRegex(ValueError, "release_hold_cas_mismatch"):
            M.release(self.root, plan, sha, release, M.digest(M.encode(release)))
        path = M._paths(self.root, self.sid)["sessions"]
        value = json.loads(path.read_bytes())
        F.write_json(path, {**value, "offset": value["offset"] + 1})
        with self.assertRaisesRegex(ValueError, "completed_chain_changed"):
            M.prepare_release(self.root, plan, sha, [self.sid])

    def test_matching_release_is_idempotent_and_does_not_retry(self):
        plan = self.prepare()
        self.apply(plan)
        sha = M.digest(M.encode(plan))
        release = M.prepare_release(self.root, plan, sha, [self.sid])
        rsha = M.digest(M.encode(release))
        M.release(self.root, plan, sha, release, rsha)
        result = M.release(self.root, plan, sha, release, rsha)
        self.assertFalse(result["learner_started"])

    def test_changed_journal_or_missing_hold_refuses_recovery(self):
        plan = self.prepare()
        self.apply(plan)
        sha = M.digest(M.encode(plan))
        hold = self.root / "migration-holds" / (self.sid + ".json")
        hold.unlink()
        with self.assertRaisesRegex(ValueError, "hold_missing_after_publication"):
            M.recover(self.root, plan, sha)

    def test_real_lock_contention_releases_earlier_locks_without_writing(self):
        for busy in (self.root / "worker.lock", self.base / "learner-provider.lock", self.root / "enqueue.lock"):
            with self.subTest(busy=busy.name):
                fd = os.open(busy, os.O_RDONLY)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    before = self.snapshot()
                    with self.assertRaises(BlockingIOError): self.prepare()
                    self.assertEqual(before, self.snapshot())
                finally:
                    os.close(fd)
                with M.Locks(self.root):
                    pass

    def test_changed_lock_identity_is_detected(self):
        with M.Locks(self.root) as locks:
            path = self.root / "worker.lock"
            path.unlink()
            path.touch(mode=0o600)
            with self.assertRaisesRegex(ValueError, "lock_changed"):
                locks.verify()

    def test_release_selected_subsets_preserves_sibling_hold(self):
        second = self.fixture.task(2)
        plan = self.prepare([self.sid, second])
        self.apply(plan)
        sha = M.digest(M.encode(plan))
        for sid in (self.sid, second):
            release = M.prepare_release(self.root, plan, sha, [sid])
            M.release(self.root, plan, sha, release, M.digest(M.encode(release)))
            self.assertFalse((self.root / "migration-holds" / (sid + ".json")).exists())
            if sid == self.sid:
                self.assertTrue((self.root / "migration-holds" / (second + ".json")).exists())

    def test_partial_release_resumes_only_matching_intent(self):
        second = self.fixture.task(2)
        plan = self.prepare([self.sid, second])
        self.apply(plan)
        sha = M.digest(M.encode(plan))
        release = M.prepare_release(self.root, plan, sha, [self.sid, second])
        rsha = M.digest(M.encode(release))
        original = M._event
        def stop(work, label, **fields):
            if label == "hold_released":
                raise RuntimeError("crash after unlink before journal receipt")
            original(work, label, **fields)
        with mock.patch.object(M, "_event", side_effect=stop):
            with self.assertRaisesRegex(RuntimeError, "crash after unlink"):
                M.release(self.root, plan, sha, release, rsha)
        first_hold = self.root / "migration-holds" / (self.sid + ".json")
        second_hold = self.root / "migration-holds" / (second + ".json")
        self.assertFalse(first_hold.exists())
        self.assertTrue(second_hold.exists())
        M.release(self.root, plan, sha, release, rsha)
        self.assertFalse(second_hold.exists())

    def test_missing_or_tampered_journal_is_not_recreated_by_recover(self):
        plan = self.prepare()
        sha = M.digest(M.encode(plan))
        with self.assertRaises((ValueError, FileNotFoundError)):
            M.recover(self.root, plan, sha)
        self.apply(plan)
        journal = self.root / "migrations" / sha / "legacy-policy.json"
        journal.write_text("{}\n")
        with self.assertRaisesRegex(ValueError, "journal_changed"):
            M.recover(self.root, plan, sha)

    def test_later_migration_requires_retained_policy_not_supplied_lookalike(self):
        second = self.fixture.task(2)
        first = self.prepare()
        self.apply(first)
        fake = self.base / "lookalike.json"
        fake.write_bytes(M._unb64(first["legacy_policy"]["bytes"]))
        fake.chmod(0o600)
        with self.assertRaisesRegex(ValueError, "legacy_policy_not_retained_journal"):
            self.prepare([second], legacy_policy_path=fake)

    def test_later_migration_pins_original_journal_source(self):
        second = self.fixture.task(2)
        first = self.prepare()
        self.apply(first)
        original = self.root / "migrations" / M.digest(M.encode(first)) / "legacy-policy.json"
        later = self.prepare([second], legacy_policy_path=original)
        original.write_bytes(original.read_bytes())  # Same bytes, newer preimage identity.
        with self.assertRaisesRegex(ValueError, "legacy_source_changed"):
            self.apply(later)

    def test_hold_first_failure_recovers_without_metadata_change(self):
        plan = self.prepare()
        sha = M.digest(M.encode(plan))
        original = M._event
        def fail(work, label, **fields):
            if label == "hold_published": raise RuntimeError("hold interrupted")
            original(work, label, **fields)
        with mock.patch.object(M, "_event", side_effect=fail):
            with self.assertRaises(RuntimeError): self.apply(plan)
        for record in plan["records"]:
            expected = plan["transitional_policy"]["candidate"] if record["path"] == str(self.root / "admission.json") else record["preimage"]
            self.assertEqual(Path(record["path"]).read_bytes(), M._unb64(expected))
        M.recover(self.root, plan, sha)

    def test_legacy_event_compatibility_is_absent_when_no_last_event(self):
        path = M._paths(self.root, self.sid)["admissions"]
        record = json.loads(path.read_bytes())
        record["last_event"] = None
        F.write_json(path, record)
        self.apply(self.prepare())
        self.assertNotIn("legacy_event_identity", json.loads(path.read_bytes()))

    def test_foreign_activation_and_route_root_are_refused(self):
        original = self.route.read_bytes()
        route = json.loads(original)
        route["state_dir"] = str(self.base)
        F.write_json(self.route, route)
        with self.assertRaisesRegex(ValueError, "invalid_route"): self.prepare()
        self.route.write_bytes(original)
        path = M._paths(self.root, self.sid)["enrollments"]
        entry = json.loads(path.read_bytes())
        entry["activation_id"] = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        F.write_json(path, entry)
        with self.assertRaisesRegex(ValueError, "legacy_enrollment_invalid"): self.prepare()

    def test_legacy_directory_inode_change_refuses(self):
        policy = json.loads((self.root / "admission.json").read_bytes())
        policy["sessions_dir"]["inode"] += 1
        F.write_json(self.root / "admission.json", policy)
        with self.assertRaisesRegex(ValueError, "legacy_directory_inode_changed"): self.prepare()

    def test_output_and_input_plan_bytes_are_private_exact_and_exclusive(self):
        plan = self.prepare()
        path = self.base / "plan.json"
        raw = M.encode(plan)
        M._new(path, raw)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(M._load_plan(path, M.digest(raw)), plan)
        with self.assertRaises(FileExistsError): M._new(path, raw)
        with self.assertRaisesRegex(ValueError, "plan_file_sha_mismatch"):
            M._load_plan(path, "0" * 64)

    def test_cli_deadline_restores_signal_handlers_on_refusal(self):
        import signal
        handlers = {n: signal.getsignal(n) for n in (signal.SIGALRM, signal.SIGTERM, signal.SIGINT)}
        with mock.patch.object(M, "prepare", side_effect=ValueError("migration_fixture_refusal")), mock.patch("builtins.print"):
            result = M.main(["plan", "--state-dir", str(self.root), "--routes", str(self.route),
                             "--session-id", self.sid, "--output", str(self.base / "unused.json")])
        self.assertEqual(result, 1)
        self.assertEqual(signal.getitimer(signal.ITIMER_REAL), (0.0, 0.0))
        self.assertEqual({n: signal.getsignal(n) for n in handlers}, handlers)

    def _advance_released_task(self, sid, *, processing=None, remove_pending=False, new_gate=False):
        paths = M._paths(self.root, sid)
        state = json.loads(paths["sessions"].read_bytes())
        state.update(offset=Path(state["transcript_path"]).stat().st_size, status="succeeded",
                     recent_messages=["newer-message"], last_excerpt_sha256="b" * 64)
        state.pop("reconciliation_required", None)
        if new_gate:
            state["reconciliation_required"] = {"run_id": "newer-uncertain-run", "memory_ids": ["newer-unverified-id"]}
        F.write_json(paths["sessions"], state)
        record = json.loads(paths["admissions"].read_bytes())
        record.update(state_sha256=M.object_digest(state), processing=processing, last_event="d" * 64)
        record.pop("legacy_event_identity", None)
        F.write_json(paths["admissions"], record)
        if remove_pending:
            paths["pending"].unlink()
        else:
            pending = json.loads(paths["pending"].read_bytes())
            pending.update(request_id="newer-request", paused_request_id="newer-request", pause_reason="newer-hold")
            F.write_json(paths["pending"], pending)
        return {name: path.read_bytes() if path.exists() else None for name, path in paths.items()}

    def test_sequential_release_after_sibling_progress_keeps_newer_bytes(self):
        second = self.fixture.task(2)
        plan = self.prepare([self.sid, second])
        self.apply(plan)
        sha = M.digest(M.encode(plan))
        first_release = M.prepare_release(self.root, plan, sha, [self.sid])
        M.release(self.root, plan, sha, first_release, M.digest(M.encode(first_release)))
        advanced = self._advance_released_task(self.sid, remove_pending=True)
        second_release = M.prepare_release(self.root, plan, sha, [second])
        M.release(self.root, plan, sha, second_release, M.digest(M.encode(second_release)))
        self.assertFalse((self.root / "migration-holds" / (second + ".json")).exists())
        self.assertEqual(advanced, {n: p.read_bytes() if p.exists() else None for n, p in M._paths(self.root, self.sid).items()})

    def test_interrupted_release_after_sibling_progress_preserves_processing_and_new_gate(self):
        second = self.fixture.task(2)
        plan = self.prepare([self.sid, second])
        self.apply(plan)
        sha = M.digest(M.encode(plan))
        release = M.prepare_release(self.root, plan, sha, [self.sid, second])
        rsha = M.digest(M.encode(release))
        original = M._event
        def stop(work, label, **fields):
            if label == "hold_released": raise RuntimeError("partial release")
            original(work, label, **fields)
        with mock.patch.object(M, "_event", side_effect=stop):
            with self.assertRaises(RuntimeError): M.release(self.root, plan, sha, release, rsha)
        advanced = self._advance_released_task(self.sid, processing="newer-interrupted-run", new_gate=True)
        M.release(self.root, plan, sha, release, rsha)
        self.assertFalse((self.root / "migration-holds" / (second + ".json")).exists())
        self.assertEqual(advanced, {n: p.read_bytes() if p.exists() else None for n, p in M._paths(self.root, self.sid).items()})

    def test_released_bad_digest_or_regressed_cursor_blocks_sibling_release(self):
        second = self.fixture.task(2)
        plan = self.prepare([self.sid, second])
        self.apply(plan)
        sha = M.digest(M.encode(plan))
        release = M.prepare_release(self.root, plan, sha, [self.sid])
        M.release(self.root, plan, sha, release, M.digest(M.encode(release)))
        self._advance_released_task(self.sid)
        path = M._paths(self.root, self.sid)["sessions"]
        state = json.loads(path.read_bytes())
        F.write_json(path, {**state, "offset": 1})
        with self.assertRaisesRegex(ValueError, "released_cursor_chain_invalid"):
            M.prepare_release(self.root, plan, sha, [second])
        record_path = M._paths(self.root, self.sid)["admissions"]
        record = json.loads(record_path.read_bytes())
        F.write_json(record_path, {**record, "state_sha256": M.object_digest(json.loads(path.read_bytes()))})
        with self.assertRaisesRegex(ValueError, "released_cursor_regressed_or_truncated"):
            M.prepare_release(self.root, plan, sha, [second])

    def _legacy_admission(self):
        base = Path(__file__).parent / "fixtures/identity_v1"
        manifest = json.loads((base / "SOURCE.json").read_bytes())
        name = "_migration_retained_v1"
        package = types.ModuleType(name)
        package.__path__ = [str(base)]
        sys.modules[name] = package
        sys.modules[name + ".transcript"] = importlib.import_module(F.PACKAGE + ".transcript")
        self.addCleanup(lambda: [sys.modules.pop(k) for k in list(sys.modules) if k == name or k.startswith(name + ".")])
        for filename, expected in manifest["files"].items():
            self.assertEqual(M.digest((base / filename).read_bytes()), expected)
        return importlib.import_module(name + ".admission")

    def test_transitional_policy_refuses_actual_retained_v1_and_current_v2_workers(self):
        unselected = self.fixture.task(2, paused=False, gated=False)
        plan = self.prepare()
        legacy = self._legacy_admission()
        self.assertEqual(legacy.check_activation(self.root)["mode"], "host_sessions_v1")
        sha = M.digest(M.encode(plan))
        original = M._event
        def stop(work, label, **fields):
            if label == "transitional_policy_published": raise RuntimeError("transition crash")
            original(work, label, **fields)
        with mock.patch.object(M, "_event", side_effect=stop):
            with self.assertRaises(RuntimeError): M.apply(self.root, plan, sha)
        for module in (legacy, M.admission):
            with self.assertRaisesRegex(ValueError, "admission_inactive"):
                module.check_activation(self.root)
        before = {p: p.read_bytes() for p in M._paths(self.root, unselected).values()}
        with mock.patch.object(F.RUNNER, "spawn_worker") as spawn, mock.patch.object(F.RUNNER, "process_request") as process:
            # The actual worker rejects before inspecting the unpaused queue.
            with self.assertRaisesRegex(ValueError, "admission_inactive"):
                F.RUNNER.worker(self.root)
            spawn.assert_not_called()
            process.assert_not_called()
        self.assertEqual(before, {p: p.read_bytes() for p in before})
        self.assertFalse((self.root / "migration-holds").exists())
        M.recover(self.root, plan, sha)

    def test_transition_and_each_hold_journal_phase_can_recover(self):
        for label in ("before_transitional_policy", "transitional_policy_published", "hold_published", "before_final_policy", "final_policy_published"):
            with self.subTest(label=label):
                base = F.private_directory(self.base / label)
                fixture = MigrationFixture(base)
                first, second = fixture.task(), fixture.task(2)
                plan = M.prepare(fixture.root, fixture.route, [first, second], authorize_current_volume_adoption=True)
                sha = M.digest(M.encode(plan))
                original = M._event
                count = 0
                def stop(work, observed, **fields):
                    nonlocal count
                    original(work, observed, **fields)
                    if observed == label:
                        count += 1
                        raise RuntimeError("phase interruption")
                with mock.patch.object(M, "_event", side_effect=stop):
                    with self.assertRaises(RuntimeError): M.apply(fixture.root, plan, sha)
                self.assertEqual(count, 1)
                M.recover(fixture.root, plan, sha)
                self.assertEqual(json.loads((fixture.root / "admission.json").read_bytes())["enabled"], True)

    def test_early_final_policy_or_unknown_transition_is_refused(self):
        plan = self.prepare()
        path = self.root / "admission.json"
        path.write_bytes(M._unb64(plan["records"][-1]["candidate"]))
        with self.assertRaisesRegex(ValueError, "final_policy_published_before_records"):
            M.recover(self.root, plan, M.digest(M.encode(plan)))
        value = json.loads(path.read_bytes())
        value["activation_id"] = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        F.write_json(path, value)
        with self.assertRaisesRegex(ValueError, "policy_cas_mismatch"):
            M.recover(self.root, plan, M.digest(M.encode(plan)))


if __name__ == "__main__":
    unittest.main()
