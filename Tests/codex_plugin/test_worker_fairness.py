"""Real bounded worker loops; synthetic admissions, never providers or native IO."""
import contextlib
import importlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "codex/plugins/engram/scripts"))
R = importlib.import_module("codex_learner.runner")
S = importlib.import_module("codex_learner.worker_schedule")


class Crash(BaseException):
    pass


class WorkerFairnessTests(unittest.TestCase):
    def setUp(self):
        fixture_root = Path(__file__).resolve().parent / ".tmp"
        fixture_root.mkdir(mode=0o700, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="worker-fairness-", dir=fixture_root)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        from suite_support import fixture_spawn_gate
        self.enterContext(fixture_spawn_gate(R.spawn_admission, self.root / "gate"))
        for name in ("pending", "sessions", "admissions", "enrollments"):
            (self.root / name).mkdir(mode=0o700)
        self.ids, self.recoverable, self.failed = [], set(), set()
        self.attempts, self.events, self.spawns = [], [], []
        self.now = 1000.0
        self.config = {**R.DEFAULTS, "max_runs_per_worker": 4, "retry_seconds": 60}
        self.service = mock.Mock()
        self.service.prepare_zero_intent_retry.return_value = None
        self.service.recover.side_effect = self.recover
        stack = self.enterContext(contextlib.ExitStack())
        for target, value in [(R.admission, {"check_activation": lambda root: {},
                                            "enrollment_ids": lambda root, policy: sorted(self.ids)}),
                              (R, {"settings": lambda root: self.config,
                                   "publications": lambda root: self.service,
                                   "has_recoverable_transition": lambda root, sid: sid in self.recoverable,
                                   "process_request": self.process,
                                   "spawn_worker": lambda root: self.spawns.append(root),
                                   "event_log": self.event}),
                              (R.time, {"time": lambda: self.now})]:
            for name, replacement in value.items():
                stack.enter_context(mock.patch.object(target, name, replacement))
        # Fail immediately if a synthetic fixture crosses a process/network boundary.
        stack.enter_context(mock.patch.object(subprocess, "Popen", side_effect=AssertionError("process forbidden")))
        stack.enter_context(mock.patch.object(socket, "socket", side_effect=AssertionError("network forbidden")))

    def sid(self, number):
        return f"019b7a00-0000-7123-8000-{number:012d}"

    def add(self, number, *, recovery=False, failed=False, paused=False):
        sid = self.sid(number)
        self.ids.append(sid)
        if recovery:
            self.recoverable.add(sid)
        if failed:
            self.failed.add(sid)
        R.atomic_json(self.root / "sessions" / (sid + ".json"),
                      {"session_id": sid, "status": "reconciliation_required" if recovery else "ready",
                       "offset": 17, "held": recovery})
        R.atomic_json(self.root / "admissions" / (sid + ".json"), {"processing": None, "fence": "unchanged"})
        R.atomic_json(self.root / "enrollments" / (sid + ".json"), {})
        request = {"session_id": sid, "request_id": "request-" + str(number),
                   "event": "Stop", "transcript_path": str(self.root / "not-read.jsonl")}
        if paused:
            request.update(paused_request_id=request["request_id"], pause_reason="reconciliation_required")
        R.atomic_json(self.root / "pending" / (sid + ".json"), request)
        return sid

    def event(self, root, name, **fields):
        self.events.append((name, fields))

    def recover(self, sid, config):
        self.attempts.append(("recovery", sid))
        if sid in self.failed:
            raise ValueError("fixture_unchanged_hold")
        self.recoverable.remove(sid)
        return None

    def process(self, root, request, config):
        sid = request["session_id"]
        self.assertNotIn(sid, self.recoverable, "ordinary lane bypassed recovery")
        self.attempts.append(("pending", sid))
        return "succeeded"

    def worker(self):
        before, spawns = len(self.attempts), len(self.spawns)
        self.assertEqual(R.worker(self.root), 0)
        current = self.attempts[before:]
        self.assertLessEqual(len(current), self.config["max_runs_per_worker"])
        return current, len(self.spawns) - spawns

    def protected(self, ids):
        return {str(p): p.read_bytes() for sid in ids for name in ("sessions", "admissions", "pending")
                if (p := self.root / name / (sid + ".json")).exists()}

    def test_four_failed_recoveries_do_not_starve_ordinary_or_later_recovery(self):
        held = [self.add(i, recovery=True, failed=True) for i in range(1, 5)]
        later = self.add(5, recovery=True, paused=True)
        healthy = self.add(9)
        before = self.protected(held)
        first, spawned = self.worker()
        self.assertIn(("pending", healthy), first)
        self.assertEqual(spawned, 1)
        self.worker()
        self.assertIn(("recovery", later), self.attempts)
        self.assertEqual([sid for lane, sid in self.attempts if lane == "recovery"], held + [later])
        self.assertEqual(self.protected(held), before)
        calls, spawned = self.worker()
        self.assertEqual((calls, spawned), ([], 0))

    def test_cap_one_persists_lane_and_recovery_cursor_across_invocations(self):
        self.config["max_runs_per_worker"] = 1
        held = [self.add(i, recovery=True, failed=True, paused=True) for i in range(1, 5)]
        later, healthy = self.add(5, recovery=True, paused=True), self.add(9)
        self.worker()
        self.assertEqual(self.attempts, [("recovery", held[0])])
        self.worker()
        self.assertEqual(self.attempts[-1], ("pending", healthy))
        for _ in range(4):
            self.worker()
        self.assertEqual([sid for lane, sid in self.attempts if lane == "recovery"], held + [later])
        self.assertEqual(self.worker(), ([], 0))

    def test_cooldown_prevents_spin_and_a_later_wake_rechecks_recovery(self):
        held = self.add(1, recovery=True, failed=True)
        before = self.protected([held])
        self.assertEqual(self.worker(), ([("recovery", held)], 0))
        self.now += 59
        self.assertEqual(self.worker(), ([], 0))
        self.now += 2
        self.assertEqual(self.worker(), ([("recovery", held)], 0))
        self.assertEqual(self.protected([held]), before)

    def test_new_ordinary_work_wakes_while_unchanged_recovery_is_cooling(self):
        held = self.add(1, recovery=True, failed=True)
        self.worker()
        healthy = self.add(2)
        self.assertEqual(self.worker(), ([("pending", healthy)], 0))
        self.assertEqual(self.attempts.count(("recovery", held)), 1)

    def test_recoverable_unpaused_request_cannot_bypass_cooldown_via_ordinary_lane(self):
        held = self.add(1, recovery=True, failed=True)
        self.worker()
        self.assertEqual(self.worker(), ([], 0))
        self.assertNotIn(("pending", held), self.attempts)

    def test_crash_during_recovery_retains_reservation_and_other_work_advances(self):
        held, healthy = self.add(1, recovery=True), self.add(2)
        def crash(sid, config):
            self.attempts.append(("recovery", sid))
            raise Crash()
        with mock.patch.object(self.service, "recover", side_effect=crash):
            with self.assertRaises(Crash):
                R.worker(self.root)
        self.assertEqual(self.worker(), ([("pending", healthy)], 0))
        self.assertEqual(self.attempts.count(("recovery", held)), 1)

    def test_crash_before_replace_does_not_dispatch_or_publish_partial_metadata(self):
        held = self.add(1, recovery=True, failed=True)
        def crash(label):
            if label == "before_replace":
                raise Crash()
        with mock.patch.object(S, "_boundary", side_effect=crash):
            with self.assertRaises(Crash):
                R.worker(self.root)
        self.assertEqual(self.attempts, [])
        self.assertFalse((self.root / S.NAME).exists())
        self.assertEqual(self.worker()[0], [("recovery", held)])

    def test_crash_after_replace_retains_valid_cursor_without_authorizing_attempt(self):
        held, healthy = self.add(1, recovery=True, failed=True), self.add(2)
        def crash(label):
            if label == "after_replace":
                raise Crash()
        with mock.patch.object(S, "_boundary", side_effect=crash):
            with self.assertRaises(Crash):
                R.worker(self.root)
        self.assertEqual(self.attempts, [])
        self.assertEqual(json.loads((self.root / S.NAME).read_bytes())["recovery_cursor"], held)
        self.assertEqual(self.worker(), ([("pending", healthy)], 0))

    def test_corrupt_advisory_metadata_is_preserved_reset_and_does_not_clear_hold(self):
        held, healthy = self.add(1, recovery=True, failed=True), self.add(2)
        before = self.protected([held])
        path = self.root / S.NAME
        path.write_bytes(b'{"version":'); path.chmod(0o600)
        self.worker()
        self.assertIn(("pending", healthy), self.attempts)
        archives = list(self.root.glob("worker-schedule-invalid-*.json"))
        self.assertEqual([p.read_bytes() for p in archives], [b'{"version":'])
        self.assertEqual(self.protected([held]), before)
        self.assertTrue(any(name == "worker_schedule_reset" for name, _ in self.events))

    def test_unpublished_partial_temp_is_not_scheduler_authority(self):
        healthy = self.add(1)
        (self.root / ".worker-schedule-unpublished.tmp").write_bytes(b'{"next_lane":')
        self.assertEqual(self.worker(), ([("pending", healthy)], 0))

    def test_interrupted_invalid_evidence_copy_cannot_block_next_worker(self):
        healthy = self.add(1)
        bad = b'{"version":'
        path = self.root / S.NAME
        path.write_bytes(bad); path.chmod(0o600)
        publish = S.durable._new
        def interrupted(target, raw):
            if target.name.startswith("worker-schedule-invalid-"):
                publish(target, raw[:3])
                raise Crash()
            return publish(target, raw)
        with mock.patch.object(S.durable, "_new", side_effect=interrupted):
            with self.assertRaises(Crash):
                R.worker(self.root)
        self.assertEqual(self.attempts, [])
        self.assertEqual(path.read_bytes(), bad)
        self.assertEqual(self.worker(), ([("pending", healthy)], 0))
        archives = sorted(p.read_bytes() for p in self.root.glob("worker-schedule-invalid-*.json"))
        self.assertEqual(archives, sorted([bad[:3], bad]))

    def test_oversized_owned_metadata_is_quarantined_without_content_read(self):
        healthy = self.add(1)
        path = self.root / S.NAME
        with path.open("wb") as stream:
            stream.truncate(S.MAX_BYTES + 1)
        path.chmod(0o600)
        before = path.stat()
        read = os.read
        def bounded_read(fd, count):
            self.assertNotEqual(os.fstat(fd).st_ino, before.st_ino, "oversized preimage was read")
            return read(fd, count)
        with mock.patch.object(os, "read", side_effect=bounded_read):
            self.assertEqual(self.worker(), ([("pending", healthy)], 0))
        archives = list(self.root.glob("worker-schedule-invalid-*/record.json"))
        self.assertEqual(len(archives), 1)
        self.assertEqual((archives[0].stat().st_ino, archives[0].stat().st_size),
                         (before.st_ino, before.st_size))
        metadata = json.loads((archives[0].parent / "identity.json").read_bytes())
        self.assertEqual(metadata["identity"]["inode"], before.st_ino)
        self.assertTrue(any(name == "worker_schedule_reset" for name, _ in self.events))

    def test_full_cooldown_table_defers_recoveries_without_blocking_ordinary_or_spinning(self):
        held = [self.add(i, recovery=True, failed=True) for i in (1, 2, 3)]
        with mock.patch.object(S, "MAX_BACKOFF", 2):
            self.assertEqual(self.worker(), ([("recovery", held[0]), ("recovery", held[1])], 0))
            healthy = self.add(9)
            self.assertEqual(self.worker(), ([("pending", healthy)], 0))
            self.now += 61
            self.assertEqual(self.worker()[0][0], ("recovery", held[2]))

    def test_symlink_scheduler_is_not_followed_or_used_to_dispatch(self):
        self.add(1)
        other = self.root / "untouched.json"
        other.write_bytes(b'{}'); other.chmod(0o600)
        (self.root / S.NAME).symlink_to(other)
        with self.assertRaises(ValueError):
            R.worker(self.root)
        self.assertEqual(other.read_bytes(), b'{}')
        self.assertEqual(self.attempts, [])

    def test_ordinary_cursor_prevents_a_rewoken_old_request_starving_other_work(self):
        self.config["max_runs_per_worker"] = 1
        first, second = self.add(1), self.add(2)
        original = self.process
        def process(root, request, config):
            result = original(root, request, config)
            return "more" if request["session_id"] == first else result
        with mock.patch.object(R, "process_request", side_effect=process):
            self.worker()
            path = self.root / "pending" / (first + ".json")
            request = json.loads(path.read_bytes())
            request.pop("paused_request_id"); request.pop("pause_reason")
            R.atomic_json(path, request)
            self.assertEqual(self.worker()[0], [("pending", second)])

    def test_new_enqueue_at_worker_exit_is_not_lost(self):
        healthy = None
        def event(root, name, **fields):
            nonlocal healthy
            if name == "worker_idle":
                healthy = self.add(1)
            self.event(root, name, **fields)
        with mock.patch.object(R, "event_log", side_effect=event):
            self.assertEqual(self.worker(), ([], 1))
        self.assertEqual(self.worker(), ([("pending", healthy)], 0))

    def test_recovery_diagnostic_only_exposes_bounded_canonical_error_codes(self):
        messages = ["settlement_gateway_installed_after_dispatch",
                    "/private/fixture/path: rejected", "private prose details", "x" * 129]
        for index, message in enumerate(messages, 1):
            sid = self.add(index, recovery=True, failed=True, paused=True)
            def fail(current, config):
                self.attempts.append(("recovery", current))
                raise ValueError(message)
            with mock.patch.object(self.service, "recover", side_effect=fail):
                self.worker()
            event = [row for name, row in self.events
                     if name == "publication_recovery_held" and row["session_id"] == sid][-1]
            expected = {"session_id": sid, "reason": "ValueError"}
            if index == 1:
                expected["error_code"] = message
            self.assertEqual(event, expected)


if __name__ == "__main__":
    unittest.main()
