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
            self.prepare([F.uuid7(F.ORIGIN, suffix=n) for n in range(M.MAX_SELECTED + 1)])

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
        unselected = self.fixture.task(2, paused=False, gated=True)
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


class ImpactTests(unittest.TestCase):
    """Only the new first-flip cohort assertion; old suite is run by the owner."""
    setUp = MigrationTests.setUp
    prepare = MigrationTests.prepare
    apply = MigrationTests.apply
    snapshot = MigrationTests.snapshot

    def healthy(self, sid, *, processing=None):
        paths = M._paths(self.root, sid)
        state = json.loads(paths["sessions"].read_bytes())
        state.pop("reconciliation_required", None)
        F.write_json(paths["sessions"], state)
        record = json.loads(paths["admissions"].read_bytes())
        record.update(state_sha256=M.object_digest(state), processing=processing)
        F.write_json(paths["admissions"], record)

    def unchanged_refusal(self, plan, reason="impact_healthy_cohort_changed"):
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, reason):
            self.apply(plan)
        self.assertEqual(before, self.snapshot())
        self.assertFalse((self.root / "migrations").exists())
        self.assertFalse((self.root / "migration-holds").exists())

    def test_first_flip_rejects_omitted_healthy_cursor_without_pending(self):
        self.fixture.task(2, pending=False, gated=False)
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "impact_healthy_cohort_not_selected"):
            self.prepare()
        self.assertEqual(before, self.snapshot())

    def test_first_flip_rejects_omitted_enrollment_only(self):
        self.fixture.task(2, cursor=False, pending=False)
        with self.assertRaisesRegex(ValueError, "impact_healthy_cohort_not_selected"):
            self.prepare()

    def test_unchanged_selected_healthy_cohort_and_normal_paused_queue_pass(self):
        paused = self.fixture.task(2, paused=True, gated=False)
        no_cursor = self.fixture.task(3, cursor=False, pending=False)
        plan = self.prepare([self.sid, paused, no_cursor])
        self.assertEqual(plan["activation_impact"]["healthy_session_ids"], sorted([paused, no_cursor]))
        self.assertEqual(plan["activation_impact"]["max_tasks"], 500)
        result = self.apply(plan)
        self.assertEqual(result["status"], "migration_complete_held")
        sha = M.digest(M.encode(plan))
        seal = self.root / "migrations" / sha / "activation-impact.json"
        self.assertEqual(seal.read_bytes(), M._impact_seal(plan, sha))
        pending = json.loads(M._paths(self.root, paused)["pending"].read_bytes())
        self.assertEqual(pending["paused_request_id"], pending["request_id"])

    def test_new_healthy_enrollment_after_plan_refuses_with_zero_mutation(self):
        plan = self.prepare()
        self.fixture.task(2, cursor=False, pending=False)
        self.unchanged_refusal(plan)

    def test_existing_gate_cleared_after_plan_refuses_with_zero_mutation(self):
        other = self.fixture.task(2, gated=True)
        plan = self.prepare()
        self.healthy(other)
        self.unchanged_refusal(plan)

    def test_processing_completion_after_plan_refuses_with_zero_mutation(self):
        other = self.fixture.task(2, gated=False)
        self.healthy(other, processing="existing-worker-request")
        plan = self.prepare()
        self.healthy(other, processing=None)
        self.unchanged_refusal(plan)

    def test_same_membership_origin_failure_becoming_valid_is_rechecked(self):
        other = self.fixture.task(2, gated=False)
        path = M._paths(self.root, other)["enrollments"]
        original = path.read_bytes()
        value = json.loads(original)
        value["device"] += 99
        F.write_json(path, value)
        plan = self.prepare()
        path.write_bytes(original)
        self.unchanged_refusal(plan)

    def test_runtime_admissible_unusual_cursor_is_counted_not_hidden_by_conversion(self):
        other = self.fixture.task(2, gated=False)
        paths = M._paths(self.root, other)
        state = json.loads(paths["sessions"].read_bytes())
        for key in ("session_id", "transcript_path", "device", "inode"):
            del state[key]
        F.write_json(paths["sessions"], state)
        record = json.loads(paths["admissions"].read_bytes())
        record["state_sha256"] = M.object_digest(state)
        F.write_json(paths["admissions"], record)
        with self.assertRaisesRegex(ValueError, "impact_healthy_cohort_not_selected"):
            self.prepare()
        with self.assertRaisesRegex(ValueError, "cursor_chain_invalid"):
            self.prepare([self.sid, other])

    def test_damaged_pending_does_not_hide_future_event_healthy_cursor(self):
        other = self.fixture.task(2, gated=False)
        path = M._paths(self.root, other)["pending"]
        for raw in (b"not json\n", b'{"admission":"stale","request_id":null}\n'):
            with self.subTest(raw=raw):
                path.write_bytes(raw)
                with self.assertRaisesRegex(ValueError, "impact_healthy_cohort_not_selected"):
                    self.prepare()
                with self.assertRaises(ValueError):
                    self.prepare([self.sid, other])

    def test_ignored_invalid_pending_does_not_mask_gate_clear_after_plan(self):
        other = self.fixture.task(2, gated=True)
        path = M._paths(self.root, other)["pending"]
        path.write_bytes(b"not json\n")
        plan = self.prepare()
        self.healthy(other)
        self.unchanged_refusal(plan)

    def test_runner_accepted_duplicate_cursor_json_is_counted_then_conversion_refuses(self):
        other = self.fixture.task(2, gated=False)
        paths = M._paths(self.root, other)
        state = json.loads(paths["sessions"].read_bytes())
        normal = json.dumps(state)
        self.assertEqual(normal[0], "{")
        paths["sessions"].write_text('{"offset":0,' + normal[1:])
        # Runtime JSON decoding yields the same final object and valid digest.
        self.assertEqual(json.loads(paths["sessions"].read_bytes()), state)
        with self.assertRaisesRegex(ValueError, "impact_healthy_cohort_not_selected"):
            self.prepare()
        with self.assertRaisesRegex(ValueError, "admission_invalid_json"):
            self.prepare([self.sid, other])

    def test_existing_hold_cannot_hide_retained_v1_healthy_task(self):
        other = self.fixture.task(2, gated=False)
        parent = F.private_directory(self.root / "migration-holds")
        F.write_json(parent / (other + ".json"), {"existing": "must not be replaced"})
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "impact_healthy_cohort_not_selected"):
            self.prepare()
        with self.assertRaisesRegex(ValueError, "existing_migration_hold"):
            self.prepare([self.sid, other])
        self.assertEqual(before, self.snapshot())

    def test_healthy_cohort_over_selected_bound_refuses_without_expansion_or_mutation(self):
        for n in range(2, M.MAX_SELECTED + 3):
            self.fixture.task(n, cursor=False, pending=False)
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "impact_healthy_cohort_limit_exceeded"):
            self.prepare()
        self.assertEqual(before, self.snapshot())

    def test_inventory_bound_counts_non_json_entries_too(self):
        (self.root / "enrollments" / "junk-a").touch()
        (self.root / "enrollments" / "junk-b").touch()
        with mock.patch.object(M, "MAX_IMPACT_TASKS", 2):
            with self.assertRaisesRegex(ValueError, "impact_inventory_limit_exceeded"):
                self.prepare()

    def test_disabled_policy_keeps_latent_healthy_cohort_and_seals_initial_apply(self):
        self.healthy(self.sid)
        policy = {**self.fixture.policy, "enabled": False}
        F.write_json(self.root / "admission.json", policy)
        MigrationTests._repair_fixture_chain(self)
        plan = self.prepare()
        self.assertEqual(plan["activation_impact"]["healthy_session_ids"], [self.sid])
        self.assertIs(plan["activation_impact"]["policy_enabled"], False)
        self.apply(plan)
        sha = M.digest(M.encode(plan))
        self.assertTrue((self.root / "migrations" / sha / "activation-impact.json").exists())
        self.assertIs(json.loads((self.root / "admission.json").read_bytes())["enabled"], False)

    def test_recovery_after_transition_uses_seal_not_partial_record_reclassification(self):
        other = self.fixture.task(2, gated=False)
        plan = self.prepare([self.sid, other])
        sha = M.digest(M.encode(plan))
        original = M._publish
        def stop(record, work, index):
            original(record, work, index)
            if index == 0: raise RuntimeError("selected enrollment converted")
        with mock.patch.object(M, "_publish", side_effect=stop):
            with self.assertRaises(RuntimeError): self.apply(plan)
        with mock.patch.object(M, "_activation_impact", side_effect=AssertionError("must not reclassify partial records")):
            M.recover(self.root, plan, sha)

    def test_missing_seal_after_transition_refuses_recovery(self):
        plan = self.prepare()
        sha = M.digest(M.encode(plan))
        original = M._event
        def stop(work, label, **fields):
            if label == "transitional_policy_published": raise RuntimeError("suspended")
            original(work, label, **fields)
        with mock.patch.object(M, "_event", side_effect=stop):
            with self.assertRaises(RuntimeError): self.apply(plan)
        seal = self.root / "migrations" / sha / "activation-impact.json"
        seal.unlink()
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "impact_seal_missing_after_transition"):
            M.recover(self.root, plan, sha)
        self.assertEqual(before, self.snapshot())

    def test_recovery_before_transition_rechecks_newly_healthy_task(self):
        plan = self.prepare()
        sha = M.digest(M.encode(plan))
        original = M._event
        def stop(work, label, **fields):
            if label == "before_transitional_policy": raise RuntimeError("not suspended yet")
            original(work, label, **fields)
        with mock.patch.object(M, "_event", side_effect=stop):
            with self.assertRaises(RuntimeError): self.apply(plan)
        self.fixture.task(2, cursor=False, pending=False)
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "impact_healthy_cohort_changed"):
            M.recover(self.root, plan, sha)
        self.assertEqual(before, self.snapshot())

    def test_later_v2_selection_keeps_policy_hash_without_v1_rescan(self):
        other = self.fixture.task(2, gated=True)
        first = self.prepare()
        self.apply(first)
        sha = M.digest(M.encode(first))
        legacy = self.root / "migrations" / sha / "legacy-policy.json"
        policy_raw = (self.root / "admission.json").read_bytes()
        with mock.patch.object(M, "_activation_impact", side_effect=AssertionError("no v1 rescan for later v2 migration")):
            later = self.prepare([other], legacy_policy_path=legacy)
            self.assertIsNone(later["activation_impact"])
            self.apply(later)
        self.assertEqual((self.root / "admission.json").read_bytes(), policy_raw)


class Bound64Tests(unittest.TestCase):
    """Expanded selection boundary with real owned metadata and unchanged guards."""
    setUp = MigrationTests.setUp
    prepare = MigrationTests.prepare
    apply = MigrationTests.apply
    snapshot = MigrationTests.snapshot
    healthy = ImpactTests.healthy
    unchanged_refusal = ImpactTests.unchanged_refusal

    def cohort(self, *, first_healthy=True):
        if first_healthy:
            self.healthy(self.sid)
        selected = [self.sid]
        for n in range(2, 65):
            cursor = n % 4 != 0
            selected.append(self.fixture.task(n, cursor=cursor, pending=cursor,
                                              paused=n % 3 != 0, gated=False))
        self.assertEqual(len(selected), 64)
        return sorted(selected)

    def test_exact_64_healthy_tasks_prepare_without_mutation_or_changed_other_bounds(self):
        self.assertEqual(M.MAX_SELECTED, 64)
        self.assertEqual(M.MAX_IMPACT_TASKS, 500)
        self.assertEqual(M.MAX_PLAN_BYTES, 32 * 1024 * 1024)
        selected = self.cohort()
        before = self.snapshot()
        plan = self.prepare(selected)
        self.assertEqual(plan["session_ids"], selected)
        self.assertEqual(plan["activation_impact"]["healthy_session_ids"], selected)
        self.assertEqual(len(plan["records"]), 64 * 4 + 2)
        self.assertLess(len(M.encode(plan)), M.MAX_PLAN_BYTES)
        M._validate_plan(self.root, plan, M.digest(M.encode(plan)))
        self.assertEqual(before, self.snapshot())
        self.assertFalse((self.root / "migrations").exists())
        self.assertFalse((self.root / "migration-holds").exists())

    def test_64_plan_preserves_all_cursor_gate_pause_and_dedup_fields(self):
        selected = self.cohort(first_healthy=False)
        plan = self.prepare(selected)
        self.assertEqual(len(plan["activation_impact"]["healthy_session_ids"]), 63)
        found_gate = found_paused = found_unpaused = found_event_bridge = False
        for record in plan["records"]:
            name = Path(record["path"]).parent.name
            if name not in {"sessions", "pending", "admissions"} or record["preimage"] is None:
                continue
            before = json.loads(M._unb64(record["preimage"]))
            after = json.loads(M._unb64(record["candidate"]))
            if name == "admissions":
                self.assertEqual({k: v for k, v in before.items() if k not in {"binding", "state_sha256"}},
                                 {k: v for k, v in after.items() if k not in {"binding", "state_sha256", "legacy_event_identity"}})
                self.assertEqual(after["last_event"], before["last_event"])
                self.assertEqual(after["processing"], before["processing"])
                self.assertEqual(after["legacy_event_identity"],
                                 {k: before["binding"][k] for k in ("device", "inode")})
                found_event_bridge = True
                continue
            self.assertEqual({k: v for k, v in before.items() if k not in {"device", "inode", "admission"}},
                             {k: v for k, v in after.items() if k not in {"identity", "admission"}})
            found_gate |= bool(after.get("reconciliation_required"))
            if name == "pending":
                found_paused |= after.get("paused_request_id") == after["request_id"]
                found_unpaused |= after.get("paused_request_id") != after["request_id"]
        self.assertTrue(found_gate and found_paused and found_unpaused and found_event_bridge)

    def test_65_explicit_selected_tasks_refuse_before_mutation(self):
        selected = self.cohort()
        selected.append(self.fixture.task(65, cursor=False, pending=False))
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "invalid_selection"):
            self.prepare(selected)
        self.assertEqual(before, self.snapshot())
        self.assertFalse((self.root / "migrations").exists())

    def test_65_healthy_tasks_cannot_fit_by_omitting_one_from_64_selection(self):
        selected = self.cohort()
        self.fixture.task(65, cursor=False, pending=False)
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "impact_healthy_cohort_limit_exceeded"):
            self.prepare(selected)
        self.assertEqual(before, self.snapshot())

    def test_new_65th_healthy_enrollment_after_64_plan_refuses_without_journal(self):
        selected = self.cohort()
        plan = self.prepare(selected)
        self.fixture.task(65, cursor=False, pending=False)
        self.unchanged_refusal(plan, "impact_healthy_cohort_limit_exceeded")
        self.assertEqual(plan["session_ids"], selected)

    def test_new_membership_within_health_bound_still_refuses_exact_64_selection(self):
        selected = self.cohort(first_healthy=False)
        plan = self.prepare(selected)
        self.fixture.task(65, cursor=False, pending=False)
        self.unchanged_refusal(plan)

    def test_existing_gate_clear_outside_64_selection_refuses_without_mutation(self):
        selected = self.cohort(first_healthy=False)
        outsider = self.fixture.task(65, gated=True)
        plan = self.prepare(selected)
        self.healthy(outsider)
        self.unchanged_refusal(plan)

    def test_existing_processing_completion_outside_64_selection_refuses_without_mutation(self):
        selected = self.cohort(first_healthy=False)
        outsider = self.fixture.task(65, gated=False)
        self.healthy(outsider, processing="existing-run")
        plan = self.prepare(selected)
        self.healthy(outsider, processing=None)
        self.unchanged_refusal(plan)

    def test_last_selected_cursor_stale_cas_still_refuses_at_64(self):
        selected = self.cohort()
        plan = self.prepare(selected)
        cursor_sid = next(sid for sid in reversed(selected) if M._paths(self.root, sid)["sessions"].exists())
        path = M._paths(self.root, cursor_sid)["sessions"]
        state = json.loads(path.read_bytes())
        state["newer_state_must_survive"] = True
        F.write_json(path, state)
        self.unchanged_refusal(plan, "cas_mismatch")


class PublicationEfficiencyTests(unittest.TestCase):
    """Scoped native revalidation still protects every actual publication."""
    setUp = MigrationTests.setUp
    prepare = MigrationTests.prepare
    apply = MigrationTests.apply
    snapshot = MigrationTests.snapshot
    healthy = ImpactTests.healthy

    def cohort(self):
        self.healthy(self.sid)
        return [self.sid] + [self.fixture.task(n, gated=False) for n in range(2, 65)]

    def extend_frontier(self, sid):
        paths = M._paths(self.root, sid)
        entry = json.loads(paths["enrollments"].read_bytes())
        entry.update(M.admission._frontier(entry))
        F.write_json(paths["enrollments"], entry)
        binding = M._binding(entry, self.fixture.policy, (self.root / "admission.json").read_bytes())
        state = json.loads(paths["sessions"].read_bytes())
        state.update(admission=binding, offset=entry["frontier_offset"])
        F.write_json(paths["sessions"], state)
        record = json.loads(paths["admissions"].read_bytes())
        record.update(binding=binding, state_sha256=M.object_digest(state))
        F.write_json(paths["admissions"], record)
        pending = json.loads(paths["pending"].read_bytes())
        pending["admission"] = binding
        F.write_json(paths["pending"], pending)

    def assert_suspended(self):
        self.assertIs(json.loads((self.root / "admission.json").read_bytes())["enabled"], False)

    def test_late_task_frontier_drift_refuses_before_that_task_publication(self):
        other = self.fixture.task(2, gated=False)
        self.extend_frontier(other)
        plan = self.prepare([self.sid, other])
        late = self.fixture.tasks[other]["path"]
        original = M._event
        def change(work, event, **fields):
            original(work, event, **fields)
            if event == "published" and fields["index"] == 3:
                raw = late.read_bytes()
                self.assertIn(b"fixture durable fact", raw)
                late.write_bytes(raw.replace(b"fixture durable fact", b"changed durable fact"))
        with mock.patch.object(M, "_event", side_effect=change):
            with self.assertRaisesRegex(ValueError, "legacy_frontier_changed"):
                self.apply(plan)
        self.assert_suspended()
        for record in plan["records"][4:8]:
            self.assertEqual(Path(record["path"]).read_bytes(), M._unb64(record["preimage"]))

    def test_late_task_origin_drift_refuses_before_that_task_publication(self):
        other = self.fixture.task(2, gated=False)
        plan = self.prepare([self.sid, other])
        late = self.fixture.tasks[other]["path"]
        original = M._event
        def change(work, event, **fields):
            original(work, event, **fields)
            if event == "published" and fields["index"] == 3:
                late.write_bytes(late.read_bytes().replace(b'"cli_version": "fixture"', b'"cli_version": "changed"'))
        with mock.patch.object(M, "_event", side_effect=change):
            with self.assertRaisesRegex(ValueError, "legacy_origin_changed"):
                self.apply(plan)
        self.assert_suspended()
        self.assertEqual(Path(plan["records"][4]["path"]).read_bytes(), M._unb64(plan["records"][4]["preimage"]))

    def test_full_final_validation_rechecks_already_published_task_before_activation(self):
        other = self.fixture.task(2, gated=False)
        self.extend_frontier(self.sid)
        plan = self.prepare([self.sid, other])
        path = self.fixture.tasks[self.sid]["path"]
        original = M._event
        def change(work, event, **fields):
            original(work, event, **fields)
            if event == "published" and fields["index"] == len(plan["records"]) - 2:
                path.write_bytes(path.read_bytes().replace(b"fixture durable fact", b"changed durable fact"))
        with mock.patch.object(M, "_event", side_effect=change):
            with self.assertRaisesRegex(ValueError, "legacy_frontier_changed"):
                self.apply(plan)
        self.assert_suspended()
        self.assertEqual(self.route.read_bytes(), M._unb64(plan["records"][-2]["candidate"]))
        self.assertNotEqual((self.root / "admission.json").read_bytes(), M._unb64(plan["records"][-1]["candidate"]))

    def test_runtime_drift_after_first_write_refuses_next_write(self):
        plan = self.prepare()
        original_event, original_runtime = M._event, M._runtime
        changed = False
        def change(work, event, **fields):
            nonlocal changed
            original_event(work, event, **fields)
            if event == "published" and fields["index"] == 0:
                changed = True
        def runtime():
            actual = original_runtime()
            return {**actual, "changed.py": "0" * 64} if changed else actual
        with mock.patch.object(M, "_event", side_effect=change), mock.patch.object(M, "_runtime", side_effect=runtime):
            with self.assertRaisesRegex(ValueError, "runtime_changed"):
                self.apply(plan)
        self.assert_suspended()
        self.assertEqual(Path(plan["records"][1]["path"]).read_bytes(), M._unb64(plan["records"][1]["preimage"]))

    def test_global_prefix_cas_still_checks_previously_published_task(self):
        other = self.fixture.task(2, gated=False)
        plan = self.prepare([self.sid, other])
        first = M._paths(self.root, self.sid)["sessions"]
        original = M._event
        def change(work, event, **fields):
            original(work, event, **fields)
            if event == "published" and fields["index"] == 3:
                value = json.loads(first.read_bytes())
                F.write_json(first, {**value, "newer": "must remain untouched"})
        with mock.patch.object(M, "_event", side_effect=change):
            with self.assertRaisesRegex(ValueError, "cas_mismatch"):
                self.apply(plan)
        self.assert_suspended()
        self.assertEqual(json.loads(first.read_bytes())["newer"], "must remain untouched")

    def test_recovery_skips_published_prefix_native_scans_and_completes_64_under_cli_deadline(self):
        import time
        selected = self.cohort()
        plan = self.prepare(selected)
        plan_path = self.base / "reviewed-plan.json"
        plan_path.write_bytes(M.encode(plan)); plan_path.chmod(0o600)
        sha = M.digest(M.encode(plan))
        original = M._publish
        def crash(record, work, index):
            original(record, work, index)
            if index == 239:
                raise RuntimeError("injected after 60 complete tasks")
        with mock.patch.object(M, "_publish", side_effect=crash):
            with self.assertRaisesRegex(RuntimeError, "60 complete tasks"):
                self.apply(plan)
        before = {r["path"]: Path(r["path"]).read_bytes() for r in plan["records"][:240]}
        candidate_calls = []
        original_validate = M._validate_candidates
        def validate(*args, **kwargs):
            candidate_calls.append(kwargs.get("candidate_task_ids"))
            return original_validate(*args, **kwargs)
        started = time.monotonic()
        with mock.patch.object(M, "_validate_candidates", side_effect=validate), mock.patch("builtins.print") as output:
            result = M.main(["recover", "--state-dir", str(self.root), "--plan", str(plan_path), "--plan-sha256", sha])
        self.assertEqual(result, 0)
        self.assertLess(time.monotonic() - started, 30)
        self.assertEqual(json.loads(output.call_args.args[0])["status"], "migration_complete_held")
        self.assertEqual(candidate_calls.count(None), 3)  # Entry, pre-activation, completed chain.
        subsets = [value for value in candidate_calls if value is not None]
        self.assertEqual(subsets, [tuple([sid]) for sid in selected[60:] for _ in range(4)] + [()])
        self.assertEqual(before, {path: Path(path).read_bytes() for path in before})
        self.assertEqual((self.root / "admission.json").read_bytes(), M._unb64(plan["records"][-1]["candidate"]))

    def test_completed_recovery_still_revalidates_all_sources_and_origins(self):
        plan = self.prepare()
        self.apply(plan)
        source = M._runtime()
        with mock.patch.object(M, "_runtime", return_value={**source, "changed.py": "0" * 64}):
            with self.assertRaisesRegex(ValueError, "runtime_changed"):
                M.recover(self.root, plan, M.digest(M.encode(plan)))
        path = self.fixture.tasks[self.sid]["path"]
        path.write_bytes(path.read_bytes().replace(b'"cli_version": "fixture"', b'"cli_version": "changed"'))
        with self.assertRaisesRegex(ValueError, "legacy_origin_changed"):
            M.recover(self.root, plan, M.digest(M.encode(plan)))


class PublicationPlanIntegrityTests(unittest.TestCase):
    """Exact pinned bytes replace only repeated immutable parsing, never live checks."""
    setUp = MigrationTests.setUp
    prepare = MigrationTests.prepare
    apply = MigrationTests.apply
    snapshot = MigrationTests.snapshot
    assert_suspended = PublicationEfficiencyTests.assert_suspended

    def changed_plan_refuses(self, mutate):
        plan = self.prepare()
        sha = M.digest(M.encode(plan))
        original_event = M._event
        before_next = Path(plan["records"][1]["path"]).read_bytes()
        def change(work, event, **fields):
            original_event(work, event, **fields)
            if event == "published" and fields["index"] == 0:
                mutate(plan)
        with mock.patch.object(M, "_event", side_effect=change):
            with self.assertRaisesRegex(ValueError, "plan_sha_mismatch"):
                M.apply(self.root, plan, sha)
        self.assert_suspended()
        self.assertEqual(Path(plan["records"][1]["path"]).read_bytes(), before_next)

    def test_nested_record_mutation_after_first_write_refuses_pinned_sha(self):
        def mutate(plan):
            record = plan["records"][1]
            state = json.loads(M._unb64(record["candidate"]))
            state["offset"] += 1
            raw = M.encode(state)
            record.update(candidate=M._b64(raw), candidate_sha256=M.digest(raw))
        self.changed_plan_refuses(mutate)

    def test_nested_impact_mutation_after_first_write_refuses_pinned_sha(self):
        self.changed_plan_refuses(lambda plan: plan["activation_impact"].update(policy_enabled=False))

    def test_nested_transition_mutation_after_first_write_refuses_pinned_sha(self):
        self.changed_plan_refuses(lambda plan: plan["transitional_policy"]["preimage_identity"].update(mtime_ns=0))

    def test_cli_rehashed_invalid_plan_cannot_skip_full_entry_validation(self):
        plan = self.prepare()
        plan["records"][1]["candidate_sha256"] = "0" * 64
        plan_path = self.base / "altered-plan.json"
        plan_path.write_bytes(M.encode(plan))
        plan_path.chmod(0o600)
        before = self.snapshot()
        with mock.patch.object(M, "_validate_publication") as publication, mock.patch("builtins.print") as output:
            result = M.main(["apply", "--state-dir", str(self.root), "--plan", str(plan_path),
                             "--plan-sha256", M.digest(M.encode(plan))])
        self.assertNotEqual(result, 0)
        self.assertIn("record_digest_changed", output.call_args.args[0])
        publication.assert_not_called()
        self.assertEqual(self.snapshot(), before)

    def later_plan(self):
        second = self.fixture.task(2)
        first = self.prepare()
        self.apply(first)
        journal = self.root / "migrations" / M.digest(M.encode(first))
        later = self.prepare([second], legacy_policy_path=journal / "legacy-policy.json")
        return later, journal

    def assert_later_write_refuses(self, plan, change_source, reason):
        original_event = M._event
        def change(work, event, **fields):
            original_event(work, event, **fields)
            if event == "published" and fields["index"] == 0:
                change_source()
        with mock.patch.object(M, "_event", side_effect=change):
            with self.assertRaisesRegex(ValueError, reason):
                self.apply(plan)
        self.assert_suspended()
        self.assertEqual(Path(plan["records"][1]["path"]).read_bytes(), M._unb64(plan["records"][1]["preimage"]))

    def test_retained_legacy_identity_drift_after_first_write_refuses(self):
        plan, journal = self.later_plan()
        source = journal / "legacy-policy.json"
        self.assert_later_write_refuses(plan, lambda: source.write_bytes(source.read_bytes()), "legacy_source_changed")

    def test_retained_journal_lineage_drift_after_first_write_refuses(self):
        plan, journal = self.later_plan()
        source = journal / "plan.json"
        def change():
            value = json.loads(source.read_bytes())
            value["learner_started"] = True
            source.write_bytes(M.encode(value))
        self.assert_later_write_refuses(plan, change, "retained_plan_digest_changed")

    def test_later_stable_policy_reencoding_refuses_before_any_write(self):
        plan, _ = self.later_plan()
        record = plan["records"][-1]
        raw = (json.dumps(json.loads(M._unb64(record["candidate"])), indent=2) + "\n").encode()
        record.update(candidate=M._b64(raw), candidate_sha256=M.digest(raw))
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "stable_policy_must_not_change"):
            self.apply(plan)
        self.assertEqual(self.snapshot(), before)

    def test_immutable_impact_validation_only_at_full_boundaries(self):
        plan = self.prepare()
        with mock.patch.object(M, "_validate_impact", wraps=M._validate_impact) as immutable, \
                mock.patch.object(M, "_validate_publication", wraps=M._validate_publication) as publication:
            self.apply(plan)
        self.assertEqual(immutable.call_count, 3)  # Entry, pre-activation, completed chain.
        self.assertEqual(publication.call_count, 5)  # Four task records, then the route.
        self.assertEqual([call.kwargs["candidate_task_ids"] for call in publication.call_args_list],
                         [(self.sid,)] * 4 + [()])


if __name__ == "__main__":
    unittest.main()
