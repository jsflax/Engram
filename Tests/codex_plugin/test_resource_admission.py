"""Deterministic capacity samples and real private admission locks; no host probes."""
import importlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

from suite_support import PLUGIN_ROOT, TEMP_ROOT
sys.path.insert(0, str(PLUGIN_ROOT / "scripts"))
G = importlib.import_module("codex_learner.spawn_admission")
C = G.resources


class ResourceAdmissionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(dir=TEMP_ROOT)
        self.addCleanup(temporary.cleanup)
        self.gate = Path(temporary.name) / "gate"
        self.enterContext(mock.patch.object(C, "is_darwin", return_value=True))
        self.clock = 101.0
        self.probe = mock.Mock()
        self.probe.processors.return_value = 16
        self.probe.pressure.return_value = 1
        self.enterContext(mock.patch.object(C, "DarwinProbe", return_value=self.probe))
        self.enterContext(mock.patch.object(C.time, "monotonic", side_effect=lambda: self.clock))

    def observation(self, idle=.4, pressure=1, at=101):
        return C.Sample(idle, 16, pressure, at)

    def final(self, observation, **kwargs):
        with G.lease(directory=self.gate, now=10_000, load=lambda: 95) as preflight:
            self.assertEqual(preflight.reason, "sample_required")
            identity = preflight.identity
        self.assertFalse((self.gate / "spawn-state.json").exists())
        return G.lease(directory=self.gate, now=10_000, resource_sample=observation,
                       resource_identity=identity, **kwargs)

    def test_darwin_capacity_admits_high_or_unavailable_diagnostic_load(self):
        for load in (lambda: 95, lambda: None, mock.Mock(side_effect=OSError("private failure"))):
            with self.subTest(load=load), self.final(self.observation(), load=load, cooldown=0) as result:
                self.assertTrue(result.admitted)
                self.assertEqual(result.diagnostic["cpu_idle_fraction"], .4)
                self.assertEqual(result.diagnostic["memory_pressure"], "normal")
                self.assertNotIn("load_limit", result.diagnostic)
            (self.gate / "spawn-state.json").unlink()

    def test_low_load_never_bypasses_cpu_or_memory_pressure(self):
        for idle, pressure, expected in ((.19, 1, "cpu_pressure"), (.9, 2, "memory_pressure"),
                                          (.9, 4, "memory_pressure")):
            with self.subTest(idle=idle, pressure=pressure), self.final(
                    self.observation(idle, pressure), load=lambda: 0) as result:
                self.assertEqual(result.reason, expected)
                self.assertFalse(result.admitted)
            self.assertFalse((self.gate / "spawn-state.json").exists())
        with self.final(self.observation(.20), load=lambda: 95) as result:
            self.assertTrue(result.admitted)

    def test_bad_or_stale_samples_and_final_pressure_never_spend_cooldown(self):
        values = [False, self.observation(float("nan")), self.observation(-.1), self.observation(1.1),
                  self.observation(at=98.99), self.observation(at=102), self.observation(pressure=0),
                  C.Sample(.4, 15, 1, 101)]
        for observation in values:
            with self.subTest(observation=observation), self.final(observation) as result:
                self.assertEqual(result.reason, "resource_unavailable")
        self.probe.pressure.return_value = 2
        with self.final(self.observation()) as result:
            self.assertEqual(result.reason, "memory_pressure")
        self.probe.pressure.side_effect = OSError("unavailable")
        with self.final(self.observation()) as result:
            self.assertEqual(result.reason, "resource_unavailable")
        self.assertFalse((self.gate / "spawn-state.json").exists())

    def test_concurrency_cooldown_and_persistence_still_precede_launch(self):
        with self.final(self.observation()) as admitted:
            self.assertTrue(admitted.admitted)
            before = self.probe.method_calls.copy()
            with G.lease(directory=self.gate, now=10_700) as result:
                self.assertEqual(result.reason, "concurrency")
            self.assertEqual(self.probe.method_calls, before)
        with G.lease(directory=self.gate, now=10_100) as result:
            self.assertEqual(result.reason, "cooldown")
        self.assertEqual(self.probe.method_calls, before)
        (self.gate / "spawn-state.json").unlink()
        with mock.patch.object(G, "_save", side_effect=OSError("fsync")), self.final(self.observation()) as result:
            self.assertEqual(result.reason, "state_unavailable")
            self.assertEqual(G.pass_fds(), ())

    def test_interval_counter_boundaries_and_endpoint_pressure(self):
        first = C.Reading((10, 20, 30, 40), 16, 1)
        last = C.Reading((30, 30, 50, 90), 16, 1)
        for duration in (1, 2):
            value = C.from_readings(first, last, 100, 100 + duration)
            self.assertEqual(value.idle_fraction, .20)
        for duration in (.99, 2.01, float("nan")):
            self.assertIsNone(C.from_readings(first, last, 100, 100 + duration))
        for bad in (first, C.Reading((9, 20, 40, 40), 16, 1), C.Reading(last.ticks, 15, 1),
                    C.Reading(last.ticks, 16, 0), C.Reading((True, 30, 50, 90), 16, 1)):
            self.assertIsNone(C.from_readings(first, bad, 100, 101))
        self.assertEqual(C.from_readings(C.Reading(first.ticks, 16, 4), last, 100, 101).pressure, 4)
        for at in (99, 101):
            self.assertIsNone(C.decision(self.observation(at=at))[0])

    def test_sampler_is_one_bounded_interval_and_discards_failed_reads(self):
        self.clock = 100
        self.probe.read.side_effect = [C.Reading((0, 0, 0, 0), 16, 1), C.Reading((2, 1, 2, 5), 16, 1)]
        sleeps = []
        def wait(seconds):
            sleeps.append(seconds)
            self.clock += seconds
        value = C.sample(probe=self.probe, sleep=wait)
        self.assertEqual(value, self.observation(.2))
        self.assertEqual(sleeps, [1])
        self.probe.read.side_effect = OSError("secret failure")
        self.assertIsNone(C.sample(probe=self.probe, sleep=wait))
        self.assertEqual(sleeps, [1])

    def test_final_count_change_and_late_pressure_read_invalidate_sample(self):
        self.probe.processors.return_value = 15
        self.assertEqual(C.decision(self.observation())[0], "resource_unavailable")
        self.probe.processors.return_value = 16
        def slow_pressure():
            self.clock += 2.01
            return 1
        self.probe.pressure.side_effect = slow_pressure
        self.assertEqual(C.decision(self.observation())[0], "resource_unavailable")

    def test_probe_initialization_time_counts_toward_sample_budget(self):
        self.clock = 100
        self.probe.read.side_effect = [C.Reading((0, 0, 0, 0), 16, 1), C.Reading((2, 1, 2, 5), 16, 1)]
        def initialize():
            self.clock += 2
            return self.probe
        with mock.patch.object(C, "DarwinProbe", side_effect=initialize):
            self.assertIsNone(C.sample(sleep=lambda seconds: setattr(self, "clock", self.clock + seconds)))


class ResourceWorkerTests(unittest.TestCase):
    def setUp(self):
        from test_worker_fairness import WorkerFairnessTests, R
        self.R = R
        production = G.lease
        self.fixture = WorkerFairnessTests(methodName="runTest")
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root, self.gate = self.fixture.root, self.fixture.root / "resource-gate"
        self.enterContext(mock.patch.object(C, "is_darwin", return_value=True))
        self.enterContext(mock.patch.object(G, "lease", side_effect=lambda **kwargs: production(
            directory=self.gate, now=self.fixture.now, load=lambda: 95, cooldown=0, **kwargs)))
        self.clock, self.idle, self.pressure = 500.0, .4, 1
        self.samples, self.waits = 0, []
        self.on_sample, self.on_wait = lambda: None, lambda: None
        probe = mock.Mock()
        probe.processors.return_value = 16
        probe.pressure.side_effect = lambda: self.pressure
        self.enterContext(mock.patch.object(C, "DarwinProbe", return_value=probe))
        self.enterContext(mock.patch.object(C, "sample", side_effect=self.sample))
        self.enterContext(mock.patch.object(R.time, "monotonic", side_effect=lambda: self.clock))
        self.enterContext(mock.patch.object(R.time, "sleep", side_effect=self.wait))

    def assert_unlocked(self):
        R = self.R
        self.assertEqual(G.pass_fds(), ())
        self.assertIsNone(R._PROVIDER_LOCK_FD.get())
        self.assertEqual([Path(row[0]).name for row in R._HELD_LOCKS.get()], ["worker-retry.lock"])
        for path in (self.root / "worker.lock", self.root / "enqueue.lock", self.gate / "spawn.lock"):
            with R.lock_file(path, blocking=False) as held:
                self.assertTrue(held, path.name)

    def sample(self):
        self.assert_unlocked()
        self.samples += 1
        self.clock += 1
        self.on_sample()
        return C.Sample(self.idle, 16, self.pressure, self.clock)

    def wait(self, seconds):
        self.assert_unlocked()
        self.waits.append(seconds)
        self.clock += seconds
        self.on_wait()

    def test_initial_sampling_is_coalesced_and_reselects_replaced_request(self):
        sid = self.fixture.add(1)
        path = self.root / "pending" / (sid + ".json")
        def during_sample():
            before = self.samples
            self.assertEqual(self.R.worker(self.root), 0)
            self.assertEqual(self.samples, before)
            self.R.atomic_json(path, {**json.loads(path.read_bytes()), "request_id": "replacement"})
        self.on_sample = during_sample
        seen, original = [], self.fixture.process
        def process(root, request, config):
            seen.append(request["request_id"])
            return original(root, request, config)
        with mock.patch.object(self.R, "process_request", side_effect=process):
            self.assertEqual(self.R.worker(self.root), 0)
        self.assertEqual((self.samples, self.waits, seen), (1, [], ["replacement"]))

    def test_pressure_clears_without_event_and_pre_admission_state_is_preserved(self):
        sid = self.fixture.add(1)
        before = self.fixture.protected([sid])
        self.pressure = 2
        def clear():
            self.assertEqual(self.fixture.protected([sid]), before)
            self.assertFalse((self.gate / "spawn-state.json").exists())
            self.pressure = 1
        self.on_wait = clear
        self.assertEqual(self.R.worker(self.root), 0)
        self.assertEqual((self.samples, self.waits), (2, [30]))
        self.assertEqual(self.fixture.attempts, [("pending", sid)])

    def test_paused_or_changed_policy_after_sample_never_executes(self):
        sid = self.fixture.add(1)
        path = self.root / "pending" / (sid + ".json")
        def pause():
            request = json.loads(path.read_bytes())
            self.R.atomic_json(path, {**request, "paused_request_id": request["request_id"], "pause_reason": "blocked"})
        self.on_sample = pause
        self.assertEqual(self.R.worker(self.root), 0)
        self.assertEqual(self.fixture.attempts, [])
        self.assertFalse((self.gate / "spawn-state.json").exists())
        self.fixture.add(2)
        self.on_sample = lambda: None
        with mock.patch.object(self.R.admission, "check_activation", side_effect=[{}, {"changed": True}]):
            self.assertEqual(self.R.worker(self.root), 0)
        self.assertEqual(self.fixture.attempts, [])

    def test_replaced_shared_lock_and_unavailable_probe_fail_closed(self):
        sid = self.fixture.add(1)
        before = self.fixture.protected([sid])
        def replace():
            path = self.gate / "spawn.lock"
            path.rename(self.gate / "old.lock")
            path.touch(mode=0o600)
        self.on_sample = replace
        self.assertEqual(self.R.worker(self.root), 0)
        self.assertEqual(self.fixture.protected([sid]), before)
        self.assertEqual(self.waits, [])
        with mock.patch.object(C, "sample", return_value=None):
            self.assertEqual(self.R.worker(self.root), 0)
        self.assertEqual(self.fixture.events[-1][1]["reason"], "resource_unavailable")
        self.assertFalse((self.gate / "spawn-state.json").exists())

    def test_first_sample_consumes_original_deadline_without_reset(self):
        sid = self.fixture.add(1)
        self.on_sample = lambda: setattr(self, "clock", self.clock + self.R.ADMISSION_RETRY_SECONDS)
        self.assertEqual(self.R.worker(self.root), 0)
        self.assertEqual(self.fixture.attempts, [])
        self.assertEqual(self.fixture.events[-1][0], "worker_admission_retry_exhausted")
        self.assertEqual((self.samples, self.waits), (1, []))

    def test_cpu_refusal_is_bounded_and_preserves_held_work(self):
        sid = self.fixture.add(1, recovery=True, failed=True)
        before = self.fixture.protected([sid])
        self.idle = .1
        self.assertEqual(self.R.worker(self.root), 0)
        self.assertEqual(self.fixture.protected([sid]), before)
        self.assertEqual(self.fixture.attempts, [])
        self.assertEqual(self.fixture.events[-1][0], "worker_admission_retry_exhausted")
        self.assertLessEqual(self.samples, self.R.ADMISSION_RETRY_ATTEMPTS)
        self.assertLessEqual(self.clock - 500, self.R.ADMISSION_RETRY_SECONDS + 1)

    def test_changed_runtime_after_sample_stops_before_reselection(self):
        sid = self.fixture.add(1)
        before = self.fixture.protected([sid])
        with mock.patch.object(self.R.runtime_routing, "maybe_exec", side_effect=[None, None,
                self.R.runtime_routing.Refused("routing_selection_changed")]):
            self.assertEqual(self.R.worker(self.root), 0)
        self.assertEqual(self.fixture.protected([sid]), before)
        self.assertEqual(self.fixture.attempts, [])
        self.assertEqual(self.samples, 1)


if __name__ == "__main__":
    unittest.main()
