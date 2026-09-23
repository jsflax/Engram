"""Stable identity in queue/cursor processing; providers remain in-process fakes."""
from dataclasses import replace
import contextlib
import json
import os
import unittest
from unittest import mock

import test_host as H


def setUpModule():
    H.setUpModule()


def tearDownModule():
    H.tearDownModule()


class StableRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.f = H.HostTests()
        self.f.setUp()
        self.addCleanup(self.f.doCleanups)
        self.runner = H.F.RUNNER
        self.identity = H.F.ADMISSION.file_identity
        self.volume = "11111111-2222-4333-8444-555555555555"
        patch = mock.patch.object(self.identity, "capture_fd", side_effect=self.capture)
        patch.start(); self.addCleanup(patch.stop)
        self.f.policy.update(schema_version=2, mode="host_sessions_v2",
            sessions_dir=H.F.ADMISSION._directory_binding(self.f.sessions, stable_identity=True))
        H.F.write_json(self.f.root / "admission.json", self.f.policy)
        H.F.write_json(self.f.routes, {"schema_version": 2, "mode": "host_sessions_v2",
                                      "enabled": True, "state_dir": str(self.f.root)})

    def capture(self, fd):
        return {"scheme": "macos_volume_uuid_inode_v1", "volume_uuid": self.volume,
                "inode": os.fstat(fd).st_ino}

    def queued(self):
        sid, path, payload = self.f.task()
        self.assertFalse(self.f.dispatch(payload, "SessionStart"))
        self.f.append(path, "A new durable fixture fact after the enrollment frontier.")
        self.assertTrue(self.f.dispatch(payload))
        return sid, path, payload

    def test_queue_and_completed_cursor_have_only_stable_identity(self):
        sid, _, _ = self.queued()
        request = self.f.request(sid)
        self.assertEqual(request["identity"]["volume_uuid"], self.volume)
        self.assertNotIn("device", request)
        self.assertNotIn("inode", request)
        self.assertEqual(self.f.process(sid), "succeeded")
        state = json.loads((self.f.root / "sessions" / (sid + ".json")).read_bytes())
        self.assertEqual(state["identity"], request["identity"])
        self.assertNotIn("device", state)
        self.assertNotIn("inode", state)
        self.assertGreater(state["offset"], request["admission"]["frontier_offset"])

    def test_later_device_renumbering_does_not_reject_pending_request(self):
        sid, _, _ = self.queued()
        original_inspect, original_read = self.runner.inspect_rollout, self.runner.read_excerpt
        def inspect(*args, **kwargs):
            value = original_inspect(*args, **kwargs)
            return replace(value, device=value.device + 100)
        def read(*args, **kwargs):
            value = original_read(*args, **kwargs)
            return replace(value, metadata=replace(value.metadata, device=value.metadata.device + 100))
        with mock.patch.object(self.runner, "inspect_rollout", side_effect=inspect), \
                mock.patch.object(self.runner, "read_excerpt", side_effect=read):
            self.assertEqual(self.f.process(sid), "succeeded")
        self.assertEqual(len(self.f.invocations), 1)

    def test_same_inode_on_different_volume_is_rejected_before_provider(self):
        sid, path, _ = self.queued()
        inode = path.stat().st_ino
        def changed(fd):
            value = self.capture(fd)
            if value["inode"] == inode:
                value["volume_uuid"] = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
            return value
        with mock.patch.object(self.identity, "capture_fd", side_effect=changed):
            with self.assertRaisesRegex(ValueError, "admission_enrollment_origin_changed"):
                self.f.process(sid)
        self.assertEqual(self.f.invocations, [])

    def test_identity_change_between_inspection_and_excerpt_rejects(self):
        sid, _, _ = self.queued()
        original_read = self.runner.read_excerpt
        def changed(*args, **kwargs):
            value = original_read(*args, **kwargs)
            identity = {**value.metadata.identity, "volume_uuid": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"}
            return replace(value, metadata=replace(value.metadata, identity=identity))
        with mock.patch.object(self.runner, "read_excerpt", side_effect=changed):
            with self.assertRaisesRegex(ValueError, "transcript_replaced_during_read"):
                self.f.process(sid)
        self.assertEqual(self.f.invocations, [])

    def test_legacy_last_event_stays_deduplicated_without_pending(self):
        sid, _, payload = self.queued()
        request = self.f.request(sid)
        self.assertEqual(self.f.process(sid), "succeeded")
        record_path = self.f.root / "admissions" / (sid + ".json")
        record = json.loads(record_path.read_bytes())
        historical = {"device": 99, "inode": request["identity"]["inode"]}
        fields = {key: request.get(key) for key in ("event", "turn_id", "trigger", "size_bytes")}
        record.update(last_event=self.runner.admission_digest({**fields, **historical}),
                      legacy_event_identity=historical)
        H.F.write_json(record_path, record)
        pending = self.f.root / "pending" / (sid + ".json")
        pending.unlink()
        before = record_path.read_bytes()
        self.assertFalse(self.f.dispatch(payload))
        self.assertFalse(pending.exists())
        self.assertEqual(record_path.read_bytes(), before)
        self.assertTrue(self.f.dispatch(payload, turn_id="a-new-turn"))
        record = json.loads(record_path.read_bytes())
        self.assertNotIn("legacy_event_identity", record)
        self.assertEqual(record["last_event"], self.runner.event_digest(self.f.request(sid)))

    def test_partial_route_policy_migration_never_dispatches(self):
        _, _, payload = self.f.task()
        H.F.write_json(self.f.routes, {"schema_version": 1, "mode": "host_sessions_v1",
                                      "enabled": True, "state_dir": str(self.f.root)})
        self.assertFalse(self.f.dispatch(payload, "SessionStart"))
        self.assertEqual(self.f.receipt()["reason"], "admission_route_mismatch")
        self.assertFalse((self.f.root / "enrollments").exists())

    def test_inflight_legacy_hook_rechecks_route_after_waiting_for_enrollment_lock(self):
        self.f.policy.update(schema_version=1, mode="host_sessions_v1",
                             sessions_dir=H.F.Fixture.binding(self.f.sessions))
        H.F.write_json(self.f.root / "admission.json", self.f.policy)
        route = {"schema_version": 1, "mode": "host_sessions_v1", "enabled": True,
                 "state_dir": str(self.f.root)}
        H.F.write_json(self.f.routes, route)
        _, _, payload = self.f.task()
        original = self.runner.lock_file
        @contextlib.contextmanager
        def after_migration(path, *args, **kwargs):
            H.F.write_json(self.f.routes, {**route, "schema_version": 2, "mode": "host_sessions_v2"})
            with original(path, *args, **kwargs) as held:
                yield held
        with mock.patch.object(self.runner, "lock_file", side_effect=after_migration):
            self.assertFalse(self.f.dispatch(payload, "SessionStart"))
        self.assertEqual(self.f.receipt()["reason"], "admission_route_mismatch")
        self.assertFalse((self.f.root / "enrollments").exists())
        self.assertFalse((self.f.root / "pending").exists())

    def test_route_changes_after_observation_before_queue_leave_task_bytes_unchanged(self):
        sid, path, payload = self.queued()
        protected = [self.f.root / directory / (sid + ".json")
                     for directory in ("enrollments", "sessions", "admissions", "pending")]
        before = {path: path.read_bytes() for path in protected}
        self.f.append(path, "Another appended fact at the new event.", ordinal=12)
        original = self.runner.lock_file
        acquired = 0
        @contextlib.contextmanager
        def after_observation(path, *args, **kwargs):
            nonlocal acquired
            acquired += 1
            if acquired == 2:
                H.F.write_json(self.f.routes, {"schema_version": 1, "mode": "host_sessions_v1",
                                              "enabled": True, "state_dir": str(self.f.root)})
            with original(path, *args, **kwargs) as held:
                yield held
        with mock.patch.object(self.runner, "lock_file", side_effect=after_observation):
            self.assertFalse(self.f.dispatch(payload, turn_id="new-turn"))
        self.assertEqual(acquired, 2)
        self.assertEqual(before, {path: path.read_bytes() for path in protected})
        events = [json.loads(line) for line in (self.f.root / "events.jsonl").read_text().splitlines()]
        self.assertEqual(events[-1]["reason"], "admission_route_mismatch")


if __name__ == "__main__":
    unittest.main()
