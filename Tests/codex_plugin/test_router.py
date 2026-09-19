"""Three explicit synthetic roots; no real process/provider/native/network work."""
import copy
import datetime as dt
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest

from suite_support import PLUGIN_ROOT, REPOSITORY_ROOT, TEMP_ROOT
from unittest import mock
import uuid

import test_frontier as F

ROUTER = None
ROUTER_SOURCE = PLUGIN_ROOT / "scripts/learner_router.py"
IDS = ("01a0a2fa-5cbd-77f0-8082-2ad6bb5c6fa8", "01a07cab-4062-79e1-99ca-14802ffd7142",
       "01a0a28e-734d-78e3-b8bb-2665002dc8e4")


def setUpModule():
    global ROUTER
    F.setUpModule()  # Real-effect guards precede imports and default capture.
    sys.modules["codex_learner"] = sys.modules[F.PACKAGE]
    sys.modules["codex_learner.runner"] = F.RUNNER
    sys.modules["codex_learner.admission"] = F.ADMISSION
    path = ROUTER_SOURCE
    spec = importlib.util.spec_from_file_location("_synthetic_router", path)
    ROUTER = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ROUTER)


def tearDownModule():
    for name in list(sys.modules):
        if name == "codex_learner" or name.startswith("codex_learner."):
            del sys.modules[name]
    F.tearDownModule()


class RouterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.fixtures = []
        for index, sid in enumerate(IDS):
            stamp = dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc) + dt.timedelta(milliseconds=uuid.UUID(sid).int >> 80)
            with mock.patch.object(F, "uuid7", return_value=sid):
                version = getattr(F.ADMISSION, "ORIGIN_VERSION_BY_SESSION", {}).get(sid, F.ADMISSION.GUI_VERSION)
                self.fixtures.append(F.Fixture(self.base / str(index), origin=stamp.isoformat(),
                                               created=(stamp + dt.timedelta(seconds=1)).isoformat(),
                                               cli_version=version))
        self.path = self.base / "routes.json"
        self.policy = {"schema_version": 1, "mode": "explicit_stop_routes_v1", "enabled": True,
                       "routes": {f.sid: {"enabled": True, "project": f.policy["project"],
                                          "state_dir": f.binding(f.root),
                                          "admission_sha256": self.digest(f.policy_path)} for f in self.fixtures}}
        self.save()

    @staticmethod
    def digest(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def save(self):
        F.write_json(self.path, self.policy)

    def dispatch(self, fixture, payload=None):
        return ROUTER.dispatch(self.path, fixture.payload if payload is None else payload, spawn=False)

    def last_receipt(self):
        return json.loads((self.base / "router-receipts.jsonl").read_text().splitlines()[-1])

    def assert_identity(self, value):
        identity = value["runtime_identity"]
        self.assertEqual(identity["evidence"], "observed_package_files")
        for name, path in (("router", Path(ROUTER.__file__)), ("runner", Path(F.RUNNER.__file__)),
                           ("template", Path(F.RUNNER.__file__).with_name("learner_prompt.md")),
                           ("admission", Path(F.ADMISSION.__file__))):
            self.assertEqual(identity["sources"][name]["path"], str(path.resolve()))
            self.assertEqual(identity["sources"][name]["sha256"], self.digest(path))
            self.assertEqual(identity["sources"][name]["status"], "ok")
        manifest = Path(ROUTER.__file__).resolve().parent.parent / ".codex-plugin/plugin.json"
        if manifest.is_file():
            self.assertEqual(identity["package"]["version"], json.loads(manifest.read_bytes())["version"])
            self.assertEqual(identity["package"]["status"], "ok")
            self.assertEqual(identity["status"], "complete")
        else:
            self.assertEqual(identity["package"]["status"], "missing")
            self.assertIsNone(identity["package"]["version"])
            self.assertEqual(identity["status"], "incomplete")

    def assert_reject(self, fixture, payload=None, reason=None):
        with mock.patch.object(F.RUNNER, "enqueue", side_effect=F.forbidden):
            self.assertFalse(self.dispatch(fixture, payload))
        value = self.last_receipt()
        self.assertEqual(value["status"], "rejected")
        self.assert_identity(value)
        if reason:
            self.assertEqual(value["reason"], reason)
        self.assertNotIn("transcript_path", value)
        self.assertNotIn("cwd", value)
        self.assertNotIn("payload", value)

    def test_each_requested_sid_enqueues_and_spawns_only_its_bound_root(self):
        for fixture in self.fixtures:
            with mock.patch.object(F.RUNNER, "spawn_worker") as spawn:
                self.assertTrue(ROUTER.dispatch(self.path, fixture.payload))
                spawn.assert_called_once_with(fixture.root)
            self.assert_identity(self.last_receipt())
            self.assertTrue(fixture.pending.exists())
            request = fixture.request()
            self.assertEqual(request["session_id"], fixture.sid)
            self.assertEqual(request["admission"]["project"], fixture.policy["project"])
            self.assertEqual(json.loads(fixture.state.read_text())["offset"], fixture.frontier)

    def test_unknown_missing_hook_sid_and_cross_project_refuse_before_enqueue(self):
        first, second, _ = self.fixtures
        for payload, reason in (({**first.payload, "session_id": "unknown"}, "session_not_supported"),
                                ({**first.payload, "session_id": None}, "session_not_supported"),
                                ({**first.payload, "hook_session_id": second.sid}, "hook_session_mismatch"),
                                ({**first.payload, "agent_id": second.sid}, "agent_session_mismatch"),
                                ({**first.payload, "cwd": str(second.project)}, "project_mismatch")):
            with self.subTest(reason=reason):
                self.assert_reject(first, payload, reason)
        self.assertTrue(all(not f.pending.exists() for f in self.fixtures))

    def test_claimed_sid_cannot_use_another_tasks_transcript(self):
        first, second, _ = self.fixtures
        self.assert_reject(first, {**first.payload, "transcript_path": str(second.path)})

    def test_missing_route_disabled_route_and_global_disable_are_intentional(self):
        first = self.fixtures[0]
        original = copy.deepcopy(self.policy)
        self.policy["routes"].pop(first.sid); self.save()
        self.assert_reject(first, reason="session_not_routed")
        self.policy = copy.deepcopy(original)
        self.policy["routes"][first.sid]["enabled"] = False; self.save()
        self.assert_reject(first, reason="route_inactive")
        self.policy = original; self.policy["enabled"] = False; self.save()
        self.assert_reject(first, reason="routes_inactive")

    def test_disabled_candidate_placeholders_do_not_touch_future_directories(self):
        first, second, _ = self.fixtures
        self.policy["routes"][second.sid] = {"enabled": False, "project": None, "state_dir": None, "admission_sha256": None}
        self.save()
        self.assertTrue(self.dispatch(first))
        self.assert_reject(second, reason="route_inactive")

    def test_unapproved_fourth_sid_duplicate_json_and_duplicate_state_root_refuse(self):
        first, second, _ = self.fixtures
        original = copy.deepcopy(self.policy)
        self.policy["routes"][F.uuid7(F.ORIGIN)] = self.policy["routes"][first.sid]; self.save()
        self.assert_reject(first, reason="routes_membership_invalid")
        self.policy = copy.deepcopy(original)
        self.policy["routes"][second.sid]["state_dir"] = self.policy["routes"][first.sid]["state_dir"]; self.save()
        self.assert_reject(first, reason="route_roots_not_distinct")
        raw = json.dumps(original)
        self.path.write_text(raw[:-1] + ',"routes":{}}')
        self.assert_reject(first, reason="admission_invalid_json")

    def test_changed_project_or_state_identity_refuses_before_admission(self):
        first = self.fixtures[0]
        for field in ("project", "state_dir"):
            original = copy.deepcopy(self.policy)
            self.policy["routes"][first.sid][field]["inode"] += 1; self.save()
            self.assert_reject(first, reason="admission_directory_identity_changed")
            self.policy = original

    def test_route_cannot_remap_sid_to_another_existing_admission_root(self):
        first, second, _ = self.fixtures
        self.policy["routes"].pop(second.sid)
        self.policy["routes"][first.sid]["state_dir"] = second.binding(second.root)
        self.policy["routes"][first.sid]["admission_sha256"] = self.digest(second.policy_path)
        self.save()
        self.assert_reject(first, reason="admission_session_not_enrolled")
        self.assertFalse(second.pending.exists())

    def test_changed_policy_digest_frontier_and_transcript_inode_refuse(self):
        first = self.fixtures[0]
        original = copy.deepcopy(first.policy)
        first.policy["cutoff"] = "2020-01-01T00:00:00Z"; first.save_policy()
        self.assert_reject(first, reason="admission_digest_changed")
        first.policy = original
        first.policy["enrollments"][first.sid]["frontier_anchor_sha256"] = "0" * 64; first.save_policy()
        self.policy["routes"][first.sid]["admission_sha256"] = self.digest(first.policy_path); self.save()
        self.assert_reject(first, reason="admission_frontier_anchor_changed")
        replacement = first.path.with_suffix(".new")
        replacement.write_bytes(first.path.read_bytes()); replacement.replace(first.path)
        self.assert_reject(first, reason="admission_enrollment_origin_changed")

    def test_existing_pilot_binding_and_cursor_continue_without_rebinding(self):
        first = self.fixtures[0]
        original_policy = first.policy_path.read_bytes()
        self.assertTrue(F.RUNNER.enqueue(first.root, first.payload, spawn=False))
        first.worker()
        binding = json.loads(first.state.read_text())["admission"]
        cursor = json.loads(first.state.read_text())["offset"]
        first.append_turn(F.TURN2, "Only the later synthetic marker is cyan.")
        first.payload["turn_id"] = F.TURN2
        self.assertTrue(self.dispatch(first))
        first.worker()
        self.assertEqual(first.policy_path.read_bytes(), original_policy)
        self.assertEqual(json.loads(first.state.read_text())["admission"], binding)
        self.assertGreater(json.loads(first.state.read_text())["offset"], cursor)
        self.assertEqual(len(first.invocations), 1)
        self.assertIn("cyan", first.invocations[0]["text"])
        self.assertNotIn("amber", first.invocations[0]["text"])

    def test_late_stop_at_captured_eof_never_invokes_or_reads_before_frontier(self):
        for fixture in self.fixtures:
            self.assertTrue(self.dispatch(fixture))
            real_read = F.RUNNER.read_excerpt
            offsets = []

            def read_checked(*args, **kwargs):
                offsets.append(args[1])
                self.assertGreaterEqual(args[1], fixture.frontier)
                return real_read(*args, **kwargs)

            with mock.patch.object(F.RUNNER, "read_excerpt", side_effect=read_checked):
                fixture.worker()
            self.assertEqual(offsets, [fixture.frontier])
            self.assertEqual(fixture.invocations, [])
            self.assertEqual(json.loads(fixture.state.read_text())["offset"], fixture.frontier)
            self.assertEqual(json.loads(fixture.state.read_text())["status"], "no_visible_content")
            self.assertFalse(fixture.pending.exists())
            self.assertFalse(self.dispatch(fixture))  # Same Stop deduplicates.

    def test_new_root_never_adopts_preexisting_cursor_or_pending(self):
        fixture = self.fixtures[1]
        F.write_json(fixture.state, {"offset": 0, "session_id": fixture.sid})
        original = fixture.state.read_bytes()
        self.assertFalse(self.dispatch(fixture))
        self.assertEqual(self.last_receipt()["reason"], "enqueue_refused")
        self.assertEqual(fixture.state.read_bytes(), original)
        self.assertFalse(fixture.record.exists())
        self.assertFalse(fixture.pending.exists())

    def test_worker_ignores_other_task_queue_and_rejects_copied_old_request(self):
        first, second, _ = self.fixtures
        self.assertTrue(self.dispatch(first))
        old_request = first.request()
        foreign = second.root / "pending" / (first.sid + ".json")
        F.write_json(foreign, old_request)
        before = foreign.read_bytes()
        second.worker()
        self.assertEqual(foreign.read_bytes(), before)
        self.assertEqual(second.invocations, [])
        F.write_json(second.pending, {**old_request, "session_id": second.sid, "hook_session_id": second.sid})
        second.worker()
        self.assertEqual(second.invocations, [])
        self.assertFalse(second.state.exists())
        self.assertTrue(first.pending.exists())

    def test_old_queued_request_after_policy_rebinding_is_not_adopted(self):
        fixture = self.fixtures[1]
        fixture.append_turn(F.TURN2, "New synthetic turn must remain unprocessed on rebind.")
        fixture.payload["turn_id"] = F.TURN2
        self.assertTrue(self.dispatch(fixture))
        before = fixture.state.read_bytes()
        fixture.policy["activation_id"] = "11111111-2222-4333-8444-555555555559"
        fixture.save_policy()
        fixture.worker()
        self.assertEqual(fixture.invocations, [])
        self.assertEqual(fixture.state.read_bytes(), before)
        self.assertEqual(fixture.request()["pause_reason"], "blocked")

    def test_disabled_late_route_does_not_touch_existing_pending_or_state(self):
        fixture = self.fixtures[0]
        self.assertTrue(self.dispatch(fixture))
        before = {p: p.read_bytes() for p in (fixture.pending, fixture.state, fixture.record)}
        self.policy["routes"][fixture.sid]["enabled"] = False; self.save()
        self.assert_reject(fixture, reason="route_inactive")
        self.assertEqual({p: p.read_bytes() for p in before}, before)

    def test_policy_change_between_route_validation_and_enqueue_cannot_admit(self):
        fixture = self.fixtures[1]
        enqueue = F.RUNNER.enqueue

        def change_then_enqueue(root, payload, **kwargs):
            self.assertEqual(kwargs["expected_admission"]["policy_sha256"], self.digest(fixture.policy_path))
            fixture.policy["cutoff"] = "2020-01-01T00:00:00Z"
            fixture.save_policy()
            return enqueue(root, payload, **kwargs)

        with mock.patch.object(F.RUNNER, "enqueue", side_effect=change_then_enqueue):
            self.assertFalse(self.dispatch(fixture))
        self.assertEqual(self.last_receipt()["reason"], "enqueue_refused")
        self.assertFalse(fixture.pending.exists())
        self.assertFalse(fixture.state.exists())
        self.assertFalse(fixture.record.exists())

    def test_bounded_private_routes_and_bounded_receipts_without_payload(self):
        fixture = self.fixtures[0]
        self.path.write_bytes(b" " * (ROUTER.MAX_ROUTES_BYTES + 1))
        self.assert_reject(fixture, reason="routes_too_large")
        self.save(); self.path.chmod(0o620)
        self.assert_reject(fixture, reason="admission_policy_writable_by_others")
        self.path.chmod(0o600)
        receipts = self.base / "router-receipts.jsonl"
        receipts.write_bytes(b"x" * ROUTER.MAX_RECEIPTS_BYTES)
        self.assert_reject(fixture, {**fixture.payload, "hook_event_name": "Secret Raw Payload"}, "event_not_stop")
        self.assertLess(receipts.stat().st_size, ROUTER.MAX_RECEIPTS_BYTES)
        self.assertNotIn(b"Secret Raw Payload", receipts.read_bytes())

    def identity_package(self):
        package = self.base / "fake-package"
        sources = package / "scripts/codex_learner"
        sources.mkdir(parents=True)
        (package / ".codex-plugin").mkdir()
        (package / ".codex-plugin/plugin.json").write_text('{"version":"fixture.1"}')
        router = package / "scripts/learner_router.py"; router.write_text("# synthetic router\n")
        runner = sources / "runner.py"; runner.write_text("# synthetic runner\n")
        admission = sources / "admission.py"; admission.write_text("# synthetic admission\n")
        (sources / "learner_prompt.md").write_text("Synthetic template\n")
        return router, types.SimpleNamespace(__file__=str(runner)), types.SimpleNamespace(__file__=str(admission))

    def test_complete_identity_uses_module_paths_not_environment(self):
        router, runner, admission = self.identity_package()
        with mock.patch.dict(ROUTER.os.environ, {"CODEX_HOME": "/decoy", "CLAUDE_PLUGIN_ROOT": "/decoy"}):
            value = ROUTER.runtime_identity.capture(str(router), runner, admission)
        self.assertEqual(value["status"], "complete")
        self.assertEqual(value["package"]["path"], str(router.parent.parent))
        self.assertEqual(value["package"]["version"], "fixture.1")
        self.assertEqual(value["sources"]["runner"]["sha256"], self.digest(Path(runner.__file__)))
        self.assertEqual(value["sources"]["template"]["path"], str(Path(runner.__file__).with_name("learner_prompt.md")))

    def test_identity_reports_observed_new_bytes_without_claiming_loaded_bytecode(self):
        router, runner, admission = self.identity_package()
        first = ROUTER.runtime_identity.capture(str(router), runner, admission)
        Path(runner.__file__).write_text("# changed on disk; fake module object unchanged\n")
        second = ROUTER.runtime_identity.capture(str(router), runner, admission)
        self.assertNotEqual(first["sources"]["runner"]["sha256"], second["sources"]["runner"]["sha256"])
        self.assertEqual(second["evidence"], "observed_package_files")
        self.assertNotIn("loaded_bytecode_verified", second)
        self.assertNotIn("provider_completed", second)

    def test_identity_missing_oversize_and_hash_failure_are_explicit(self):
        router, runner, admission = self.identity_package()
        Path(admission.__file__).unlink()
        value = ROUTER.runtime_identity.capture(str(router), runner, admission)
        self.assertEqual(value["sources"]["admission"]["status"], "missing")
        self.assertIsNone(value["sources"]["admission"]["sha256"])
        Path(runner.__file__).write_bytes(b"x" * (ROUTER.runtime_identity.MAX_SOURCE_BYTES + 1))
        value = ROUTER.runtime_identity.capture(str(router), runner, admission)
        self.assertEqual(value["sources"]["runner"]["status"], "too_large")
        with mock.patch.object(ROUTER.runtime_identity.hashlib, "sha256", side_effect=ValueError("synthetic hash failure")):
            value = ROUTER.runtime_identity.capture(str(router), runner, admission)
        self.assertEqual(value["sources"]["router"]["status"], "hash_failed")
        self.assertIsNone(value["sources"]["router"]["sha256"])
        self.assertEqual(value["status"], "incomplete")

    def test_bad_or_missing_package_version_is_never_invented(self):
        router, runner, admission = self.identity_package()
        manifest = router.parent.parent / ".codex-plugin/plugin.json"
        for raw in ('{}', '{"version":"one","version":"two"}', '{', '{"version":false}'):
            manifest.write_text(raw)
            value = ROUTER.runtime_identity.capture(str(router), runner, admission)
            self.assertEqual(value["package"]["status"], "invalid_manifest")
            self.assertIsNone(value["package"]["version"])
        manifest.unlink()
        value = ROUTER.runtime_identity.capture(str(router), runner, admission)
        self.assertEqual(value["package"]["status"], "missing")
        self.assertIsNone(value["package"]["version"])

    def test_identity_on_paused_admission_digest_rejection_does_not_enqueue(self):
        fixture = self.fixtures[0]
        fixture.policy["enabled"] = False; fixture.save_policy()
        self.assert_reject(fixture, reason="admission_digest_changed")
        self.assertEqual(self.last_receipt()["phase"], "admission")
        self.assertFalse(fixture.pending.exists())
        self.assertFalse(fixture.state.exists())

    def test_malformed_input_stays_empty_json_and_records_identity_without_dispatch(self):
        output = io.StringIO()
        with mock.patch.object(ROUTER.sys, "stdin", types.SimpleNamespace(buffer=io.BytesIO(b"not-json"))), \
                mock.patch.object(ROUTER.sys, "stdout", output), \
                mock.patch.object(ROUTER, "dispatch", side_effect=F.forbidden):
            self.assertEqual(ROUTER.main([str(self.path)]), 0)
        self.assertEqual(output.getvalue(), "{}\n")
        receipt = self.last_receipt()
        self.assertEqual((receipt["phase"], receipt["reason"]), ("input", "hook_input_invalid"))
        self.assert_identity(receipt)

    def test_identity_failure_does_not_change_normal_enqueue_or_receipt(self):
        observed = ROUTER.runtime_identity._observed_file

        def hash_failure(value, *args, **kwargs):
            result, raw = observed(value, *args, **kwargs)
            result["status"] = "hash_failed"; result["sha256"] = None
            return result, None

        with mock.patch.object(ROUTER.runtime_identity, "_observed_file", side_effect=hash_failure):
            self.assertTrue(self.dispatch(self.fixtures[0]))
        receipt = self.last_receipt()
        self.assertEqual(receipt["status"], "queued")
        self.assertEqual(receipt["runtime_identity"]["status"], "incomplete")
        self.assertIsNone(receipt["runtime_identity"]["sources"]["runner"]["sha256"])


if __name__ == "__main__":
    unittest.main()
