"""Installed-registry routing with disposable files and owned synthetic children.

Never invoke a real Codex/provider/native executable, or rewrite HOME/CODEX_HOME.
"""
import contextlib
import importlib
import io
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

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "codex/plugins/engram/scripts"))
T = importlib.import_module("codex_learner.runtime_routing")
R = importlib.import_module("codex_learner.runner")
H = importlib.import_module("engram_hook")
REAL_DISCOVER = T._discover


class Executed(BaseException):
    pass


class RuntimeRoutingTests(unittest.TestCase):
    def setUp(self):
        base = Path(__file__).resolve().parent / ".tmp"
        base.mkdir(mode=0o700, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="routing-", dir=base)
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.home = self.base / "codex"
        self.home.mkdir(mode=0o700)
        self.config = self.home / "config.toml"
        self.config.write_text('[plugins."engram@personal"]\nenabled = true\n')
        self.old = self.package("0.15.4")
        self.new = self.package("0.15.5")
        self.row = {"pluginId": "engram@personal", "name": "engram",
                    "marketplaceName": "personal", "version": "0.15.5",
                    "installed": True, "enabled": True,
                    "source": {"source": "local", "path": "/unused-marketplace-source"}}
        self.registry = {"installed": [self.row], "available": []}
        self.cli = self.base / "synthetic-cli"
        self.cli.write_text("#!/bin/sh\nexit 99\n")
        self.cli.chmod(0o700)
        self.discovery = self.enterContext(mock.patch.object(T, "_discover", side_effect=lambda *a: self.registry))
        self.enterContext(mock.patch.object(T, "codex_binary", return_value=str(self.cli)))
        # This default makes any unplanned process or exec an immediate failure.
        self.process = self.enterContext(mock.patch.object(subprocess, "Popen", side_effect=AssertionError("unexpected process")))
        self.exec = self.enterContext(mock.patch.object(os, "execve", side_effect=Executed))
        self.inherited = dict(os.environ)
        self.addCleanup(self.assertEqual, dict(os.environ), self.inherited)

    def package(self, version, *, market="personal"):
        root = self.home / "plugins/cache" / market / "engram" / version
        (root / ".codex-plugin").mkdir(parents=True)
        (root / ".codex-plugin/plugin.json").write_text(json.dumps({"name": "engram", "version": version}))
        (root / "scripts/codex_learner").mkdir(parents=True)
        for name in ("engram_hook.py", "codex_learner.py", "codex_learner/__init__.py", "codex_learner/runtime_routing.py"):
            (root / "scripts" / name).write_text("# synthetic, never executed\n")
        return root

    def select(self):
        return T.successor(self.old, home=self.home, environ=self.inherited)

    def route(self, argv=None, *, plugin=None, state=None, allow_handoff=True):
        real = T.successor
        # Inject the host path at the API seam, never via process-global env.
        with mock.patch.object(T, "successor", side_effect=lambda root, **kw: real(root, home=self.home, settings_path=kw["settings_path"] if state else None, environ=self.inherited)):
            return T.maybe_exec(plugin or self.old, "codex_learner.py", argv or ["worker"],
                                state_root=state, allow_handoff=allow_handoff)

    def test_waiting_worker_revalidates_selection_without_execing_away_retry_ownership(self):
        self.assertIsNone(self.route(plugin=self.new, allow_handoff=False))
        with self.assertRaisesRegex(T.Refused, "routing_selection_changed"):
            self.route(plugin=self.old, allow_handoff=False)
        self.exec.assert_not_called()
        self.process.assert_not_called()

    def test_selected_installed_version_not_marketplace_or_highest_directory(self):
        self.package("99.0.0")
        self.row["source"]["path"] = str(self.package("0.1.0"))
        target, _ = self.select()
        self.assertEqual(target, self.new)
        self.discovery.assert_called_once_with(str(self.cli), "personal", self.home, self.inherited)
        with self.assertRaises(Executed):
            self.route(["worker", "--state-dir", str(self.base / "retained-state")])
        command, args, env = self.exec.call_args.args
        self.assertEqual(command, sys.executable)
        self.assertEqual(args, [sys.executable, "-B", str(self.new / "scripts/codex_learner.py"), "worker", "--state-dir", str(self.base / "retained-state")])
        self.assertEqual(env, dict(self.inherited, CLAUDE_PLUGIN_ROOT=str(self.new), **{T.HOP: "1"}))
        self.process.assert_not_called()

    def test_disabled_ambiguous_or_invalid_registry_never_delegates(self):
        original = json.loads(json.dumps(self.registry))
        cases = [None, {}, {"installed": {}}, {"installed": []},
                 {"installed": [self.row, self.row]},
                 *({"installed": [{**self.row, key: value}]} for key, value in
                   (("enabled", False), ("installed", False), ("enabled", 1),
                    ("marketplaceName", "other"), ("version", "../0.15.5"), ("version", "0.15.05")))]
        for value in cases:
            with self.subTest(value=value):
                self.registry = value
                with self.assertRaises(T.Refused): self.select()
        self.registry = original
        for text in ('[plugins."engram@personal"]\nenabled=false\n',
                     '[features]\nplugins=false\n[plugins."engram@personal"]\nenabled=true\n'):
            self.config.write_text(text)
            self.discovery.reset_mock()
            with self.assertRaisesRegex(T.Refused, "routing_plugin_disabled"): self.select()
            self.discovery.assert_not_called()
        self.exec.assert_not_called()

    def test_downgrade_prerelease_and_build_metadata_rules(self):
        self.package("0.15.3")
        for value in ("0.15.3", "0.15.4-rc.1", "0.15.4+different"):
            self.row["version"] = value
            with self.subTest(value=value), self.assertRaises(T.Refused): self.select()
        for bad in ("01.2.3", "1.2", "1.2.3-01", "1.2.3-", "1.2.3+", 1):
            with self.subTest(bad=bad), self.assertRaises(T.Refused): T._version(bad)
        self.assertLess(T._version("1.0.0-rc.9"), T._version("1.0.0-rc.10"))
        self.assertLess(T._version("1.0.0-rc.10"), T._version("1.0.0"))
        self.assertEqual(T._version("1.0.0+codex.20261018"), T._version("1.0.0"))

    def test_untrusted_target_manifest_symlink_and_hardlink_refuse(self):
        path = self.new / "scripts/codex_learner.py"
        path.chmod(0o666)
        with self.assertRaisesRegex(T.Refused, "routing_unsafe_path"): self.select()
        path.chmod(0o644)
        path.unlink(); path.symlink_to(self.old / "scripts/codex_learner.py")
        with self.assertRaisesRegex(T.Refused, "routing_unsafe_path"): self.select()
        path.unlink(); os.link(self.old / "scripts/codex_learner.py", path)
        with self.assertRaisesRegex(T.Refused, "routing_unsafe_path"): self.select()
        path.unlink(); path.write_text("# restored\n")
        manifest = self.new / ".codex-plugin/plugin.json"
        manifest.write_text('{"name":"engram","version":"0.15.4"}')
        with self.assertRaisesRegex(T.Refused, "routing_manifest_mismatch"): self.select()

    def test_current_package_source_checkout_and_one_hop(self):
        self.row["version"] = "0.15.4"
        self.route()
        self.exec.assert_not_called()
        self.discovery.reset_mock()
        self.assertIsNone(T.successor(REPO / "codex/plugins/engram", home=self.home))
        self.discovery.assert_not_called()
        self.row["version"] = "0.15.5"
        env = dict(os.environ, **{T.HOP: "untrusted-value"})
        with mock.patch.object(T.os, "environ", env):
            with self.assertRaisesRegex(T.Refused, "routing_hop_limit"): self.route()
        self.exec.assert_not_called()

    def test_hook_handoff_retains_original_deadline_and_hint_cannot_extend_it(self):
        now = time.monotonic()
        deadline = now + 2.8
        original = T.successor
        with mock.patch.object(T, "successor", side_effect=lambda root, **kw: original(root, home=self.home)), \
             mock.patch.object(T.time, "monotonic", return_value=now + 0.49):
            with self.assertRaises(Executed):
                T.maybe_exec(self.old, "engram_hook.py", [], deadline=deadline)
        env = self.exec.call_args.args[2]
        self.assertEqual(float(env[T.HOOK_DEADLINE]), deadline)
        with mock.patch.object(T.os, "environ", env):
            self.assertEqual(T.hook_deadline(now + 0.5), deadline)
            self.assertLess(T.hook_deadline(now + 0.5) - (now + 0.5), 2.8)
        for hint in (str(now + 999), "nan", "garbage", str(now - 1)):
            with mock.patch.object(T.os, "environ", {T.HOP: "1", T.HOOK_DEADLINE: hint}):
                if hint == str(now + 999):
                    self.assertEqual(T.hook_deadline(now), now + 2.8)
                else:
                    with self.assertRaises(T.Refused): T.hook_deadline(now)

    def test_cleanup_timeout_still_closes_pipes_without_claiming_reap(self):
        child = mock.Mock(returncode=None, pid=123456789)
        child.wait.side_effect = subprocess.TimeoutExpired("synthetic", 0.2)
        selector = mock.MagicMock()
        selector.__enter__.return_value = selector
        selector.get_map.return_value = {1: "still open"}
        selector.select.side_effect = T.Refused("routing_discovery_timeout")
        # Use the real function retained before setUp's discovery mock.
        with mock.patch.object(T.subprocess, "Popen", return_value=child), \
             mock.patch.object(T.selectors, "DefaultSelector", return_value=selector), \
             mock.patch.object(T.os, "set_blocking"), mock.patch.object(T.os, "killpg") as kill:
            with self.assertRaisesRegex(T.Refused, "routing_discovery_cleanup_timeout"):
                REAL_DISCOVER(str(self.cli), "personal", self.home, self.inherited)
        kill.assert_called_once_with(child.pid, signal.SIGKILL)
        child.stdout.close.assert_called_once()
        child.stderr.close.assert_called_once()
        self.assertIsNone(child.returncode)

    def test_config_replacement_after_selection_refuses(self):
        chosen = self.select()
        def replace(*a, **kw):
            old = self.config.read_bytes()
            self.config.unlink(); self.config.write_bytes(old)
            return chosen
        with mock.patch.object(T, "successor", side_effect=replace):
            with self.assertRaisesRegex(T.Refused, "routing_path_changed"): T.maybe_exec(self.old, "codex_learner.py", ["worker"])
        self.exec.assert_not_called()

    def test_custom_state_route_settings_are_retained_without_state_reads(self):
        state = self.base / "custom-state"
        state.mkdir(mode=0o700)
        (state / "settings.json").write_text(json.dumps({"codex_bin": str(self.cli)}))
        (state / "plan.json").write_text('{"operation_id":"unchanged"}')
        before = {p.name: p.read_bytes() for p in state.iterdir()}
        with self.assertRaises(Executed): self.route(["worker", "--state-dir", str(state)], state=state)
        self.assertEqual(before, {p.name: p.read_bytes() for p in state.iterdir()})

    def test_hook_refusal_preserves_input_and_does_not_bootstrap(self):
        import recall_hook
        output = []
        with mock.patch.object(T, "maybe_exec", side_effect=T.Refused("routing_discovery_timeout")), \
             mock.patch.object(H, "initialize", side_effect=AssertionError("bootstrap forbidden")), \
             mock.patch.object(recall_hook, "read_input", side_effect=AssertionError("input consumed")), \
             mock.patch.object(H.os, "write", side_effect=lambda fd, raw: output.append(raw)), \
             mock.patch.object(sys, "stderr", new_callable=io.StringIO) as errors:
            self.assertEqual(H.main([]), 0)
        self.assertEqual(output, [b"{}\n"])
        self.assertEqual(errors.getvalue(), "Engram: routing_discovery_timeout\n")

    def test_worker_routes_before_lock_or_plan_and_spawn_clears_only_hop(self):
        state = self.base / "worker"
        state.mkdir()
        with mock.patch.object(T, "maybe_exec", side_effect=Executed) as route, \
             mock.patch.object(R.admission, "check_activation", side_effect=AssertionError("admission before routing")), \
             mock.patch.object(R, "lock_file", side_effect=AssertionError("lock before routing")):
            with self.assertRaises(Executed): R.worker(state)
        self.assertEqual(route.call_args.kwargs, {"state_root": state})
        env = dict(self.inherited, CLAUDE_PLUGIN_ROOT="obsolete", **{T.HOP: "1", T.HOOK_DEADLINE: "1"})
        with mock.patch.object(R.os, "environ", env), mock.patch.object(subprocess, "Popen") as spawned:
            R.spawn_worker(state)
        call = spawned.call_args
        self.assertEqual(call.args[0][1], "-B")
        self.assertEqual(call.kwargs["env"], dict(self.inherited, CLAUDE_PLUGIN_ROOT=str(REPO / "codex/plugins/engram")))
        self.assertTrue(call.kwargs["close_fds"])
        self.assertEqual(call.kwargs["stdin"], subprocess.DEVNULL)
        self.assertEqual(env[T.HOP], "1")


class WorkerBoundaryTests(unittest.TestCase):
    def fixture(self):
        # Reuse the existing synthetic real-worker fixture, never real providers.
        from test_worker_fairness import WorkerFairnessTests
        fixture = WorkerFairnessTests("runTest")
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        return fixture

    def test_selection_changes_during_batch_wait_until_next_entry(self):
        f = self.fixture()
        f.config["max_runs_per_worker"] = 2
        ids = [f.add(n) for n in (1, 2, 3)]
        route_calls, switched = [], []
        current = ["old"]
        def route(*args, **kwargs):
            route_calls.append(current[0])
            if current[0] == "new":
                switched.append(args)
                raise Executed
        def process(root, request, config):
            current[0] = "new"  # Installation while the first request is active.
            self.assertEqual(route_calls, ["old"])
            self.assertTrue(any(path == str(root / "worker.lock") for path, *_ in R._HELD_LOCKS.get()))
            return f.process(root, request, config)
        with mock.patch.object(T, "maybe_exec", side_effect=route), \
             mock.patch.object(R, "process_request", side_effect=process):
            self.assertEqual(R.worker(f.root), 0)
            self.assertEqual(f.attempts, [("pending", ids[0]), ("pending", ids[1])])
            self.assertEqual(f.spawns, [f.root])
            self.assertFalse(switched)
            before = f.protected([ids[2]])
            with self.assertRaises(Executed): R.worker(f.root)
            self.assertEqual(f.protected([ids[2]]), before)
            self.assertEqual(route_calls, ["old", "new"])
            self.assertEqual(R._HELD_LOCKS.get(), ())

    def test_selected_worker_still_loses_existing_leader_lock_without_work(self):
        f = self.fixture()
        sid = f.add(1)
        before = f.protected([sid])
        with R.lock_file(f.root / "worker.lock") as acquired:
            self.assertTrue(acquired)
            with mock.patch.object(T, "maybe_exec", return_value=None) as route:
                self.assertEqual(R.worker(f.root), 0)
                route.assert_called_once()
        self.assertEqual(f.attempts, [])
        self.assertEqual(f.spawns, [])
        self.assertEqual(f.protected([sid]), before)


class DiscoveryProcessTests(unittest.TestCase):
    def setUp(self):
        base = Path(__file__).resolve().parent / ".tmp"
        base.mkdir(mode=0o700, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="routing-child-", dir=base)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.script = self.root / "cli"
        self.original = dict(os.environ)
        self.addCleanup(self.assertEqual, dict(os.environ), self.original)

    def script_body(self, body):
        self.script.write_text('#!' + sys.executable + '\n' + body)
        self.script.chmod(0o700)

    def test_real_owned_discovery_success_preserves_cli_namespace_and_environment(self):
        self.script_body('import json, os, sys\nprint(json.dumps({"args":sys.argv[1:],"home":os.environ.get("HOME"),"codex":os.environ.get("CODEX_HOME"),"cwd":os.getcwd()}))\n')
        got = T._discover(str(self.script), "personal", self.root, self.original)
        self.assertEqual(got, {"args": ["plugin", "list", "--marketplace", "personal", "--json"],
                               "home": self.original.get("HOME"), "codex": self.original.get("CODEX_HOME"), "cwd": str(self.root)})

    def test_actual_exec_preserves_pid_stdin_arguments_and_child_only_package_root(self):
        home = self.root / "config-home"
        home.mkdir()
        (home / "config.toml").write_text('[plugins."engram@personal"]\nenabled=true\n')
        packages = []
        for version in ("1.0.0", "1.1.0"):
            package = home / "plugins/cache/personal/engram" / version
            (package / ".codex-plugin").mkdir(parents=True)
            (package / ".codex-plugin/plugin.json").write_text(json.dumps({"name":"engram","version":version}))
            (package / "scripts").mkdir()
            packages.append(package)
        target = packages[1] / "scripts/engram_hook.py"
        target.write_text('import os, sys, json\nprint(json.dumps({"pid":os.getpid(),"input":sys.stdin.read(),"args":sys.argv[1:],"plugin":os.environ.get("CLAUDE_PLUGIN_ROOT"),"hop":os.environ.get("ENGRAM_RUNTIME_ROUTED")}))\n')
        self.script_body('print(' + repr(json.dumps({"installed":[{"pluginId":"engram@personal","name":"engram","marketplaceName":"personal","version":"1.1.0","installed":True,"enabled":True}]})) + ')\n')
        code = ('import sys; from pathlib import Path; sys.path.insert(0,'
                + repr(str(REPO / "codex/plugins/engram/scripts")) + '); '
                'from codex_learner import runtime_routing as T; '
                'original=T.successor; T.successor=lambda root,**kw:original(root,home=Path('
                + repr(str(home)) + ')); T.codex_binary=lambda config:' + repr(str(self.script)) + '; '
                'T.maybe_exec(Path(' + repr(str(packages[0])) + '),"engram_hook.py",["--synthetic-event","Stop"])')
        with subprocess.Popen([sys.executable, "-B", "-c", code], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                              env=self.original) as child:
            output, errors = child.communicate("synthetic unread input", timeout=5)
        self.assertEqual(child.returncode, 0, errors)
        self.assertEqual(json.loads(output), {"pid":child.pid,"input":"synthetic unread input",
                         "args":["--synthetic-event","Stop"],"plugin":str(packages[1]),"hop":"1"})

    def test_timeout_kills_and_reaps_owned_child_with_stalled_pipe(self):
        self.script_body('import signal, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\ntime.sleep(60)\n')
        real, children = subprocess.Popen, []
        def launch(*a, **kw):
            child = real(*a, **kw); children.append(child); return child
        start = time.monotonic()
        with mock.patch.object(T.subprocess, "Popen", side_effect=launch):
            with self.assertRaisesRegex(T.Refused, "routing_discovery_timeout"):
                T._discover(str(self.script), "personal", self.root, self.original)
        self.assertLess(time.monotonic() - start, 2)
        self.assertEqual(len(children), 1)
        self.assertEqual(children[0].returncode, -signal.SIGKILL)
        with self.assertRaises(ChildProcessError): os.waitpid(children[0].pid, os.WNOHANG)
        self.assertTrue(children[0].stdout.closed and children[0].stderr.closed)

    def test_exited_parent_with_descendant_pipe_is_cleaned_before_parent_reap(self):
        pidfile = self.root / "descendant.pid"
        self.script_body('import subprocess, sys\n'
                         'p=subprocess.Popen([sys.executable,"-B","-c","import time; time.sleep(60)"])\n'
                         + 'open(' + repr(str(pidfile)) + ',"w").write(str(p.pid))\n')
        real, children = subprocess.Popen, []
        def launch(*a, **kw):
            child = real(*a, **kw); children.append(child); return child
        with mock.patch.object(T.subprocess, "Popen", side_effect=launch):
            with self.assertRaisesRegex(T.Refused, "routing_discovery_timeout"):
                T._discover(str(self.script), "personal", self.root, self.original)
        self.assertEqual(children[0].returncode, 0)  # Parent had already exited.
        with self.assertRaises(ChildProcessError): os.waitpid(children[0].pid, os.WNOHANG)
        pid = int(pidfile.read_text())
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try: os.kill(pid, 0)
            except ProcessLookupError: break
            time.sleep(0.01)
        else:
            self.fail("owned descendant survived discovery timeout")

    def test_output_limit_exit_and_malformed_stream_refuse(self):
        for body, reason in [('import os, time\nos.write(1,b"x"*300000)\ntime.sleep(30)\n', "routing_discovery_output_limit"),
                             ('import sys\nsys.exit(7)\n', "routing_discovery_failed")]:
            self.script_body(body)
            with self.subTest(reason=reason), self.assertRaisesRegex(T.Refused, reason):
                T._discover(str(self.script), "personal", self.root, self.original)
        self.script_body('print("not json")\n')
        with self.assertRaises(ValueError): T._discover(str(self.script), "personal", self.root, self.original)


if __name__ == "__main__":
    unittest.main()
