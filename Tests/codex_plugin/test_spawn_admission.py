"""Actual shared flock/guard lifetime with private files and stand-in processes."""
import contextlib
import importlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

from suite_support import PLUGIN_ROOT, REPOSITORY_ROOT, TEMP_ROOT
sys.path.insert(0, str(PLUGIN_ROOT / "scripts"))
G = importlib.import_module("codex_learner.spawn_admission")
B = importlib.import_module("codex_learner.stdio_bridge")


class SpawnAdmissionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="spawn-admission-", dir=TEMP_ROOT)
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.directory = self.root / "gate"

    def lease(self, **kwargs):
        return G.lease(directory=self.directory, now=10_000, load=lambda: 0, **kwargs)

    def test_lifetime_outlasts_clock_cooldown_and_refusal_does_not_rewrite(self):
        with self.lease() as first:
            self.assertTrue(first.admitted)
            original = (self.directory / "spawn-state.json").read_bytes()
            with G.lease(directory=self.directory, now=999_999_999, load=lambda: 0) as second:
                self.assertEqual(second.reason, "concurrency")
            self.assertEqual((self.directory / "spawn-state.json").read_bytes(), original)
            self.assertEqual(G.pass_fds(), (first.fd,))
        self.assertEqual(G.pass_fds(), ())
        with self.lease() as second:
            self.assertEqual(second.reason, "cooldown")
        with G.lease(directory=self.directory, now=10_601, load=lambda: 0) as later:
            self.assertTrue(later.admitted)

    def test_corrupt_duplicate_unknown_and_unsafe_state_are_preserved(self):
        self.directory.mkdir(mode=0o700)
        path = self.directory / "spawn-state.json"
        for raw in [b"{", b"{}", b'{"version":2,"lastSpawnAt":0}',
                    b'{"version":true,"lastSpawnAt":0}', b'{"version":1,"lastSpawnAt":true}',
                    b'{"version":1,"lastSpawnAt":0,"lastSpawnAt":1}',
                    b'{"version":1,"lastSpawnAt":NaN}', b'{"version":1,"lastSpawnAt":-1}',
                    b'{"version":1,"lastSpawnAt":0,"active":[]}']:
            path.write_bytes(raw); path.chmod(0o600)
            with self.lease() as result:
                self.assertEqual(result.reason, "state_unavailable")
                self.assertEqual(G.pass_fds(), ())
            self.assertEqual(path.read_bytes(), raw)
        path.unlink(); path.symlink_to(self.root / "absent")
        with self.lease() as result:
            self.assertEqual(result.reason, "state_unavailable")
        self.assertFalse((self.root / "absent").exists())

    def test_unavailable_load_and_fsync_failure_cannot_admit(self):
        for value in [None, float("nan"), float("inf"), -1]:
            with G.lease(directory=self.directory, load=lambda: value) as result:
                self.assertEqual(result.reason, "load_unavailable")
        self.assertFalse((self.directory / "spawn-state.json").exists())
        with mock.patch.object(G.os, "fsync", side_effect=OSError("fixture fsync failure")):
            with self.lease() as result:
                self.assertEqual(result.reason, "state_unavailable")
                self.assertEqual(G.pass_fds(), ())
        self.assertEqual(list(self.directory.glob("*.tmp")), [])

    def test_durable_state_precedes_launch_and_relay_inherits_same_lease(self):
        with self.lease() as held:
            self.assertEqual(json.loads((self.directory / "spawn-state.json").read_bytes()),
                             {"version": 1, "lastSpawnAt": 10_000})
            _, _, _, inherited = B._fenced_transport({"command": sys.executable, "args": ["-c", "pass"]})
            self.assertEqual(inherited, (held.fd,))
            with self.assertRaises(OSError):
                subprocess.Popen([str(self.root / "no-executable")], pass_fds=G.pass_fds())
        with self.lease() as refused:
            self.assertEqual(refused.reason, "cooldown")

    def test_guard_preserves_exit_and_waits_for_fd_closing_child(self):
        child = "import os,sys; os.closerange(3,256); print('fixture-output',flush=True); sys.exit(7)"
        with self.lease() as held:
            proc = subprocess.Popen(G.provider_argv([sys.executable, "-I", "-S", "-B", "-c", child], 5),
                pass_fds=G.pass_fds(), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                stdin=subprocess.DEVNULL, start_new_session=True)
            out, error = proc.communicate(timeout=8)
            self.assertEqual((proc.returncode, out, error), (7, b"fixture-output\n", b""))
        with self.lease(cooldown=0) as later:
            self.assertTrue(later.admitted)

    def test_guard_owns_timeout_after_worker_exits(self):
        with self.lease() as held:
            proc = subprocess.Popen(G.provider_argv([sys.executable, "-I", "-S", "-B", "-c",
                "import os,time; os.closerange(3,256); time.sleep(20)"], 0.15),
                pass_fds=G.pass_fds(), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            self.assertEqual(proc.wait(timeout=8), 143)
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL); proc.wait(timeout=5)
        with self.lease(cooldown=0) as later:
            self.assertTrue(later.admitted)

    def test_guarded_cancellation_reaps_term_ignoring_provider_without_killing_guard(self):
        ready = self.root / "ready"
        child = ("import os,signal,sys,time; from pathlib import Path; os.closerange(3,256); "
                 "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                 "Path(sys.argv[1]).write_text('ready'); time.sleep(20)")
        with self.lease() as held:
            proc = subprocess.Popen(G.provider_argv([sys.executable, "-I", "-S", "-B", "-c", child, str(ready)], 15),
                pass_fds=G.pass_fds(), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue(ready.exists())
            with self.lease(cooldown=0) as refused:
                self.assertEqual(refused.reason, "concurrency")
            G.stop_provider(proc, guarded=True)
            self.assertEqual(proc.returncode, 137)  # Normal guard exit after owned child SIGKILL/reap.
            self.assertTrue(G.provider_terminated(proc, guarded=True))
        finally:
            if proc.poll() is None:
                G.stop_provider(proc, guarded=True)
        with self.lease(cooldown=0) as later:
            self.assertTrue(later.admitted)
        dead_guard = mock.Mock(returncode=-signal.SIGKILL)
        dead_guard.poll.return_value = -signal.SIGKILL
        self.assertFalse(G.provider_terminated(dead_guard, guarded=True))

    def test_worker_crash_keeps_gate_until_fd_closing_provider_exits(self):
        self.crashed_worker_case(cancel=False)

    def test_worker_crash_during_cancellation_keeps_guard_until_term_ignoring_provider_is_reaped(self):
        self.crashed_worker_case(cancel=True)

    def crashed_worker_case(self, *, cancel):
        # The intermediary is the actual production guard; only the provider is
        # a stand-in. It closes every unknown FD before announcing readiness.
        ready, release = self.root / "ready", self.root / "release"
        child = ("import os,signal,sys,time; from pathlib import Path; os.closerange(3,256); "
                 "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                 "Path(sys.argv[1]).write_text(str(os.getpid())); "
                 "exec('while not Path(sys.argv[2]).exists():\\n time.sleep(.02)'); sys.exit(0)")
        parent = r'''
import json, subprocess, sys, time
sys.path.insert(0, sys.argv[1])
from codex_learner import spawn_admission as G
with G.lease(directory=sys.argv[2], now=10000, load=lambda:0) as lease:
    assert lease.admitted
    argv=[sys.executable,"-I","-S","-B","-c",sys.argv[3],sys.argv[4],sys.argv[5]]
    proc=subprocess.Popen(G.provider_argv(argv,10),pass_fds=G.pass_fds(),start_new_session=True,
                          stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    print(proc.pid,flush=True)
    time.sleep(20)
'''
        launcher = subprocess.Popen([sys.executable, "-I", "-S", "-B", "-c", parent,
            str(PLUGIN_ROOT / "scripts"), str(self.directory), child, str(ready), str(release)],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True, text=True)
        guard_pid = None
        released = False
        try:
            import selectors
            with selectors.DefaultSelector() as selector:
                selector.register(launcher.stdout, selectors.EVENT_READ)
                self.assertTrue(selector.select(timeout=5), "guard PID handshake timed out")
            guard_pid = int(launcher.stdout.readline())
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue(ready.exists())
            if cancel:
                os.killpg(guard_pid, signal.SIGTERM)
            launcher.kill(); launcher.wait(timeout=5)
            with self.lease(cooldown=0) as refused:
                self.assertEqual(refused.reason, "concurrency")
            if not cancel:
                release.write_text("exit")
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                with self.lease(cooldown=0) as result:
                    if result.admitted:
                        released = True
                        break
                time.sleep(.01)
            self.assertTrue(released, "provider exit must release guard's kernel lease")
        finally:
            release.touch()
            if launcher.poll() is None:
                launcher.kill(); launcher.wait(timeout=5)
            if guard_pid is not None and not released:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(guard_pid, signal.SIGKILL)
            launcher.stdout.close(); launcher.stderr.close()

    def test_actual_worker_refusal_preserves_invalid_schedule_and_all_pending_state(self):
        from test_worker_fairness import WorkerFairnessTests, R
        production = G.lease
        fixture = WorkerFairnessTests(methodName="runTest")
        fixture.setUp(); self.addCleanup(fixture.doCleanups)
        fixture.add(1, recovery=True, failed=True)
        fixture.add(2)
        schedule = fixture.root / "worker-schedule.json"
        for raw in (b"{invalid", b"x" * (1024 * 1024 + 1)):
            schedule.write_bytes(raw); schedule.chmod(0o600)
            before = {str(p.relative_to(fixture.root)): p.read_bytes()
                      for p in fixture.root.rglob("*") if p.is_file()}
            with production(directory=self.directory, load=lambda: 0, cooldown=0) as held:
                self.assertTrue(held.admitted)
                with mock.patch.object(R.spawn_admission, "lease", side_effect=lambda:
                        production(directory=self.directory, load=lambda: 0, cooldown=0)):
                    self.assertEqual(R.worker(fixture.root), 0)
            after = {str(p.relative_to(fixture.root)): p.read_bytes()
                     for p in fixture.root.rglob("*") if p.is_file()}
            # The coordination lock itself is created before admission.
            before.setdefault("worker.lock", b"")
            before.setdefault("enqueue.lock", b"")
            self.assertEqual(after, before)
            self.assertEqual(fixture.attempts, [])
            self.assertEqual(fixture.events[-1], ("worker_admission_deferred", {"reason": "concurrency"}))

    def test_new_unpaused_pending_during_backoff_does_not_spend_shared_cooldown(self):
        from test_worker_fairness import WorkerFairnessTests, R
        fixture = WorkerFairnessTests(methodName="runTest")
        fixture.setUp(); self.addCleanup(fixture.doCleanups)
        sid = fixture.add(1)
        state = fixture.root / "sessions" / (sid + ".json")
        value = json.loads(state.read_bytes())
        R.atomic_json(state, {**value, "retry_after": fixture.now + 120})
        before = fixture.protected([sid])
        with mock.patch.object(R.spawn_admission, "lease", side_effect=AssertionError("no eligible work")):
            self.assertEqual(R.worker(fixture.root), 0)
        self.assertEqual(fixture.protected([sid]), before)
        self.assertFalse((fixture.root / "worker-schedule.json").exists())
        self.assertFalse((fixture.root / "gate" / "spawn-state.json").exists())
        self.assertEqual(fixture.attempts, [])
        self.assertEqual(fixture.spawns, [])

    def test_actual_worker_holds_gate_through_settlement_and_releases_on_return(self):
        from test_worker_fairness import WorkerFairnessTests, R
        production = G.lease
        fixture = WorkerFairnessTests(methodName="runTest")
        fixture.setUp(); self.addCleanup(fixture.doCleanups)
        fixture.add(1)
        ordinary = R.process_request
        def process(*args):
            self.assertTrue(G.pass_fds())
            with production(directory=self.directory, load=lambda: 0, cooldown=0) as second:
                self.assertEqual(second.reason, "concurrency")
            return ordinary(*args)
        with mock.patch.object(R.spawn_admission, "lease", side_effect=lambda:
                production(directory=self.directory, load=lambda: 0, cooldown=0)), \
             mock.patch.object(R, "process_request", side_effect=process):
            self.assertEqual(R.worker(fixture.root), 0)
        self.assertEqual(G.pass_fds(), ())
        with production(directory=self.directory, load=lambda: 0, cooldown=0) as later:
            self.assertTrue(later.admitted)

    def test_legacy_shared_gate_and_guard_are_identical(self):
        for name in ("spawn_admission.py", "provider_guard.py"):
            self.assertEqual((PLUGIN_ROOT / "scripts/codex_learner" / name).read_bytes(),
                             (REPOSITORY_ROOT / "scripts/codex_learner" / name).read_bytes())


if __name__ == "__main__":
    unittest.main()
