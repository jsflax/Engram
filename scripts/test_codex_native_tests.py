"""Exercise native-test supervision using disposable Python child processes."""

import importlib.util
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
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).with_name("run_native_tests.py")
SPEC = importlib.util.spec_from_file_location("native_test_runner", SCRIPT)
HARNESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HARNESS)


class RequiredSwiftTestsTests(unittest.TestCase):
    names = ('testPreparationCentroidsUseFirstEncodePositionsAndCadence',
             'testPreparationRegroupAndCapacityGrowth', 'testPreparationAsyncDirtyDispatch')

    @classmethod
    def output(cls):
        return '\n'.join(f'✔ Test {name}() passed after 0.003 seconds.' for name in cls.names) + \
            '\n✔ Test run with 3 tests in 1 suite passed after 0.010 seconds.\n'

    def test_exact_named_passes_accept_ansi_and_arbitrary_completion_order(self):
        lines = self.output().splitlines()
        output = '\n'.join('\x1b[32m' + line + '\x1b[0m' for line in reversed(lines[:-1])) + '\n' + lines[-1]
        self.assertTrue(HARNESS.required_swift_tests(output, self.names)['matched'])

    def test_zero_missing_duplicate_unexpected_and_ambiguous_totals_refuse(self):
        good = self.output()
        first = good.splitlines()[0] + '\n'
        for output in ('', '✔ Test run with 0 tests passed after 0.001 seconds.\n',
                       good.replace(first, ''), first + good,
                       good.replace(self.names[0], 'testOther'),
                       good.replace('with 3 tests', 'with 2 tests'), good + good.splitlines()[-1]):
            with self.subTest(output=output):
                self.assertFalse(HARNESS.required_swift_tests(output, self.names)['matched'])

    def test_skip_failure_and_missing_metal_cannot_qualify(self):
        for line in ('↷ Test ' + self.names[0] + '() skipped.',
                     '✘ Test ' + self.names[0] + '() failed after 0.001 seconds with 1 issue.',
                     '✘ Suite "ForceEngine" failed after 0.001 seconds with 1 issue.'):
            with self.subTest(line=line):
                self.assertFalse(HARNESS.required_swift_tests(self.output() + line, self.names)['matched'])
        self.assertFalse(HARNESS.required_swift_tests(
            '✘ Test ' + self.names[0] + '() recorded an issue: Expectation failed: (Self.device → nil)\n',
            self.names)['matched'])

    def test_cli_passes_required_identities_and_preserves_gate_exit(self):
        args = ['runner', '--diagnostics-dir', '/fixture/diagnostics']
        for name in self.names:
            args += ['--require-swift-test', name]
        args += ['--', 'swift', 'test', '--skip-build']
        with patch.object(HARNESS.sys, 'argv', args), patch.object(HARNESS, 'Runner') as runner:
            runner.return_value.run.return_value = 125
            self.assertEqual(HARNESS.main(), 125)
        self.assertEqual(runner.call_args.kwargs['required_tests'], list(self.names))
        self.assertEqual(runner.call_args.args[0], ['swift', 'test', '--skip-build'])


class NativeTestRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="native-test-supervisor-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sample = self.root / "sample"
        self.sample.write_text("#!" + sys.executable + "\n" +
                               "import sys\nfrom pathlib import Path\n"
                               "Path(sys.argv[-1]).write_text('fixture stack for ' + sys.argv[1])\n")
        self.sample.chmod(0o700)

    def runner(self, program, **overrides):
        options = dict(timeout=5, silence=60, sample_tool=str(self.sample),
                       sample_timeout=0.3, sample_seconds=0.01,
                       cleanup_grace=0.2, console=io.BytesIO())
        options.update(overrides)
        return HARNESS.Runner([sys.executable, "-c", program],
                              self.root / "diagnostics", **options)

    def receipt(self):
        return json.loads((self.root / "diagnostics/receipt.json").read_text())

    def test_required_pass_gate_uses_actual_child_output_and_preserves_failure(self):
        good = RequiredSwiftTestsTests.output()
        scenarios = ((good, 0, 0, 65536),
                     ('✔ Test run with 0 tests passed after 0.001 seconds.\n', 0, 125, 65536),
                     (good, 7, 7, 65536), (good, 0, 125, 32))
        for index, (output, child_exit, expected_exit, cap) in enumerate(scenarios):
            with self.subTest(index=index):
                runner = self.runner(f'import sys; print({output!r}, flush=True); sys.exit({child_exit})',
                                     required_tests=RequiredSwiftTestsTests.names, log_limit=cap)
                runner.directory = self.root / str(index)
                self.assertEqual(runner.run(), expected_exit)
                receipt = json.loads((runner.directory / 'receipt.json').read_text())
                self.assertEqual(receipt['child_exit_code'], child_exit)
                self.assertEqual(receipt['cleanup']['remaining'], [])
                self.assertEqual(receipt['cleanup']['signals'], [])
                self.assertEqual(receipt['required_swift_tests']['matched'], index in (0, 2))

    def test_cli_preserves_exact_arguments_output_and_failure_exit(self):
        command = [sys.executable, "-c",
                   "import json,sys; print(json.dumps(sys.argv[1:])); sys.exit(7)",
                   "argument with spaces", "--filter", "A|B", "--skip", "C"]
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--diagnostics-dir", str(self.root / "diagnostics"),
             "--timeout-seconds", "5", "--", *command],
            capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(json.loads(result.stdout), command[3:])
        receipt = self.receipt()
        self.assertEqual(receipt["command"], command)
        self.assertEqual(receipt["child_exit_code"], 7)
        self.assertEqual(receipt["cleanup"]["remaining"], [])

    def test_capped_log_keeps_draining_and_streaming_all_output(self):
        runner = self.runner("import sys; sys.stdout.write('x' * (2 * 1024**2) + 'FINISHED')",
                             log_limit=127)
        self.assertEqual(runner.run(), 0)
        receipt = self.receipt()
        self.assertEqual(receipt["saved_log_bytes"], 127)
        self.assertEqual((self.root / "diagnostics/output.log").stat().st_size, 127)
        self.assertEqual(receipt["output_bytes"], 2 * 1024**2 + 8)
        self.assertTrue(receipt["log_truncated"])
        self.assertTrue(runner.console.getvalue().endswith(b"FINISHED"))
        self.assertTrue(receipt["reader_complete"])

    def test_silence_collects_diagnostics_but_eventual_success_still_passes(self):
        runner = self.runner("import time; time.sleep(0.7); print('completed')", silence=0.1)
        self.assertEqual(runner.run(), 0)
        receipt = self.receipt()
        self.assertEqual(receipt["reason"], "exit")
        self.assertEqual([item["reason"] for item in receipt["diagnostics"]], ["silence"])
        self.assertTrue(list((self.root / "diagnostics").glob("*.sample.txt")))
        self.assertEqual(receipt["cleanup"]["signals"], [])

    def test_success_allows_short_lived_descendant_to_exit_without_signaling(self):
        program = ("import subprocess; "
                   "child=subprocess.Popen(['/bin/sleep','0.6']); print(child.pid,flush=True)")
        runner = self.runner(program)
        self.assertEqual(runner.run(), 0)
        receipt = self.receipt()
        self.assertEqual(receipt["reason"], "exit")
        self.assertEqual(receipt["child_exit_code"], 0)
        self.assertEqual(receipt["cleanup"], {"signals": [], "remaining": [], "errors": []})
        child_pid = int(runner.console.getvalue().strip())
        current = HARNESS.processes().get(child_pid)
        self.assertTrue(current is None or "Z" in current["state"], current)
        self.assertTrue(receipt["reader_complete"])

    def test_success_requiring_descendant_signal_fails_and_records_executable_identity(self):
        program = ("import subprocess; "
                   "child=subprocess.Popen(['/bin/sleep','30']); print(child.pid,flush=True)")
        runner = self.runner(program)
        self.assertEqual(runner.run(), 125)
        receipt = self.receipt()
        self.assertEqual(receipt["reason"], "cleanup_required")
        self.assertEqual(receipt["child_exit_code"], 0)
        child_pid = int(runner.console.getvalue().strip())
        self.assertEqual(len(receipt["cleanup"]["signals"]), 1)
        target = receipt["cleanup"]["signals"][0]
        self.assertEqual(target["pid"], child_pid)
        self.assertEqual(target["signal"], "SIGTERM")
        self.assertEqual(Path(target["command"]).name, "sleep")
        self.assertTrue(target["started"])
        self.assertEqual(target["group"], runner.child.pid)
        self.assertIn("parent", target)
        self.assertIn("state", target)
        self.assertEqual(receipt["cleanup"]["remaining"], [])
        self.assertEqual(receipt["cleanup"]["errors"], [])
        current = HARNESS.processes().get(child_pid)
        self.assertTrue(current is None or "Z" in current["state"], current)
        self.assertTrue(receipt["reader_complete"])

    def test_timeout_cleans_detached_descendant_that_ignores_term(self):
        child_program = "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(30)"
        program = ("import subprocess,sys,time; "
                   f"child=subprocess.Popen([sys.executable,'-c',{child_program!r}],start_new_session=True); "
                   "print(child.pid,flush=True); time.sleep(30)")
        runner = self.runner(program, timeout=1.2)
        self.assertEqual(runner.run(), 124)
        receipt = self.receipt()
        child_pid = int(runner.console.getvalue().strip())
        self.assertIn({"pid": child_pid, "signal": "SIGKILL"},
                      [{"pid": entry["pid"], "signal": entry["signal"]}
                       for entry in receipt["cleanup"]["signals"]])
        self.assertEqual(receipt["cleanup"]["remaining"], [])
        current = HARNESS.processes().get(child_pid)
        self.assertTrue(current is None or "Z" in current["state"], current)
        self.assertTrue(receipt["reader_complete"])

    def test_unresponsive_sampler_is_bounded_and_does_not_change_timeout_exit(self):
        self.sample.write_text("#!" + sys.executable + "\nimport time\ntime.sleep(30)\n")
        runner = self.runner("import time; time.sleep(30)", timeout=0.3, sample_timeout=0.15)
        start = time.monotonic()
        self.assertEqual(runner.run(), 124)
        self.assertLess(time.monotonic() - start, 3)
        self.assertIn("TimeoutExpired", self.receipt()["diagnostics"][0]["samples"][0]["error"])
        self.assertEqual(self.receipt()["cleanup"]["remaining"], [])

    def test_reused_pid_is_never_signaled(self):
        runner = self.runner("pass")
        runner.child = Mock(pid=100)
        runner.child.poll.return_value = 0
        old = {"pid": 200, "parent": 1, "group": 200, "started": "old", "state": "S", "command": "old"}
        reused = dict(old, started="new", command="unrelated")
        runner.known = {200: old}
        with patch.object(HARNESS, "processes", return_value={200: reused}), \
                patch.object(HARNESS.os, "kill") as kill:
            receipt = runner.cleanup(time.monotonic() + 2)
        kill.assert_not_called()
        self.assertEqual(receipt["remaining"], [])

    def test_each_signal_revalidates_birth_and_records_current_executable(self):
        old = {"pid": 200, "parent": 100, "group": 200, "started": "old", "state": "S", "command": "launcher"}
        for started in ("old", "reused"):
            with self.subTest(started=started):
                runner = self.runner("pass")
                runner.child = Mock(pid=100)
                runner.child.poll.return_value = 0
                runner.known = {200: old}
                current = dict(old, parent=1, command="actual-helper", started=started)
                snapshots = iter([{200: old}, {200: current}])
                with patch.object(HARNESS, "processes", side_effect=lambda **kwargs: next(snapshots, {})), \
                        patch.object(HARNESS.os, "kill") as kill:
                    receipt = runner.cleanup(time.monotonic() + 2)
                if started == "old":
                    kill.assert_called_once_with(200, signal.SIGTERM)
                    self.assertEqual(receipt["signals"], [dict(current, signal="SIGTERM")])
                else:
                    kill.assert_not_called()
                    self.assertEqual(receipt["signals"], [])
                self.assertEqual(receipt["remaining"], [])

    def test_cleanup_inventory_obeys_remaining_deadline_and_never_signals_after_it(self):
        runner = self.runner("pass")
        runner.child = Mock(pid=100)
        runner.child.poll.return_value = 0
        item = {"pid": 200, "parent": 1, "group": 200, "started": "old", "state": "S", "command": "helper"}
        runner.known = {200: item}
        now, budgets = [0.0], []

        def inventory(timeout):
            budgets.append(timeout)
            now[0] += 0.1
            return {200: item}

        with patch.object(HARNESS.time, "monotonic", side_effect=lambda: now[0]), \
                patch.object(HARNESS, "processes", side_effect=inventory), \
                patch.object(HARNESS.os, "kill") as kill:
            receipt = runner.cleanup(0.15)
        kill.assert_not_called()
        self.assertEqual(len(budgets), 2)
        self.assertAlmostEqual(budgets[0], 0.15)
        self.assertAlmostEqual(budgets[1], 0.05)
        self.assertEqual(receipt["signals"], [])
        self.assertTrue(receipt["errors"])

    def test_cancellation_during_natural_exit_grace_proceeds_immediately_to_cleanup(self):
        runner = self.runner("pass")
        runner.child = Mock(pid=100)
        runner.child.poll.return_value = 0
        item = {"pid": 200, "parent": 1, "group": 200, "started": "old", "state": "S", "command": "helper"}
        runner.known = {200: item}
        calls = []

        def inventory(timeout):
            calls.append(timeout)
            if len(calls) == 1:
                runner.signals.append(signal.SIGTERM)
            return {200: item} if len(calls) <= 3 else {}

        with patch.object(HARNESS, "processes", side_effect=inventory), \
                patch.object(HARNESS.time, "sleep") as sleep, \
                patch.object(HARNESS.os, "kill") as kill:
            receipt = runner.cleanup(time.monotonic() + 15, successful_exit=True)
        self.assertLessEqual(calls[0], 1)
        self.assertEqual(calls[1], 2)
        sleep.assert_not_called()
        kill.assert_called_once_with(200, signal.SIGTERM)
        self.assertEqual(receipt["signals"], [dict(item, signal="SIGTERM")])

    def test_natural_exit_grace_timeout_is_recorded_and_other_inventory_errors_remain_failures(self):
        for error in (subprocess.TimeoutExpired("ps", 1), OSError("inventory unavailable")):
            with self.subTest(error=type(error).__name__):
                runner = self.runner("pass")
                runner.child = Mock(pid=100)
                runner.child.poll.return_value = 0
                with patch.object(HARNESS, "processes", side_effect=[error, {}, {}, {}, {}, {}]) as inventory, \
                        patch.object(HARNESS.os, "kill") as kill:
                    receipt = runner.cleanup(time.monotonic() + 15, successful_exit=True)
                self.assertGreater(inventory.call_count, 1)
                kill.assert_not_called()
                self.assertEqual(receipt["signals"], [])
                self.assertEqual(receipt["remaining"], [])
                if isinstance(error, subprocess.TimeoutExpired):
                    self.assertEqual(receipt["natural_exit_grace_timeout"], repr(error))
                    self.assertEqual(receipt["errors"], [])
                else:
                    self.assertEqual(receipt["errors"], [repr(error)])

    def test_natural_exit_grace_expiring_between_poll_and_inventory_is_not_a_cleanup_error(self):
        runner = self.runner("pass")
        runner.child = Mock(pid=100)
        now = [0.0]

        def poll():
            now[0] = 1.01
            return 0

        runner.child.poll.side_effect = poll
        with patch.object(HARNESS.time, "monotonic", side_effect=lambda: now[0]), \
                patch.object(HARNESS, "processes", return_value={}) as inventory, \
                patch.object(HARNESS.os, "kill") as kill:
            receipt = runner.cleanup(15, successful_exit=True)
        kill.assert_not_called()
        self.assertEqual(inventory.call_args_list[0].kwargs["timeout"], 2)
        self.assertEqual(receipt, {"signals": [], "remaining": [], "errors": []})

    def test_observed_descendant_remains_owned_after_reparenting_and_exec(self):
        runner = self.runner("pass")
        runner.child = Mock(pid=100)
        runner.child.poll.return_value = 0
        old = {"pid": 200, "parent": 100, "group": 200, "started": "same", "state": "S", "command": "launcher"}
        current = dict(old, parent=1, command="swiftpm-testing")
        runner.known = {200: old}
        with patch.object(HARNESS, "processes", return_value={200: current}):
            self.assertEqual(runner.refresh(), {200: current})

    def test_unreadable_inventory_cannot_report_success(self):
        runner = self.runner("import time; time.sleep(30)")
        with patch.object(HARNESS, "processes", side_effect=OSError("fixture ps unavailable")):
            self.assertEqual(runner.run(), 125)
        receipt = self.receipt()
        self.assertEqual(receipt["reason"], "supervisor_error")
        self.assertTrue(receipt["cleanup"]["errors"])
        self.assertIsNotNone(runner.child.returncode)
        with self.assertRaises(ProcessLookupError):
            os.kill(runner.child.pid, 0)
        self.assertTrue(any(item.get("direct_child_fallback")
                            for item in receipt["cleanup"]["signals"]))

    def test_transient_inventory_timeout_preserves_progress_and_known_ownership(self):
        ready, release = self.root / "ready", self.root / "release"
        runner = self.runner(
            "import time\nfrom pathlib import Path\n"
            "for i in range(15): print(i,flush=True)\n"
            f"Path({str(ready)!r}).touch()\n"
            "deadline=time.monotonic()+5\n"
            f"while not Path({str(release)!r}).exists():\n"
            " if time.monotonic() >= deadline: raise TimeoutError('fixture release not received')\n"
            " time.sleep(0.01)\n"
            "for i in range(15,30): print(i,flush=True)\n")
        calls, known, child = [], {}, []
        now = [0.0]

        def advance(seconds):
            now[0] += seconds

        def inventory(timeout):
            calls.append(timeout)
            if len(calls) == 1:
                deadline = time.monotonic() + 2
                while not ready.exists():
                    if time.monotonic() >= deadline:
                        self.fail("child did not reach the bounded handshake")
                    time.sleep(0.01)
            if len(calls) == 2:
                known.update(runner.known)
                self.assertIn(runner.child.pid, known)
                child.append(runner.child)
                raise subprocess.TimeoutExpired("fixture ps", timeout)
            if len(calls) == 3:
                self.assertIs(runner.child, child[0])
                self.assertEqual(runner.known, known)
                self.assertIsNone(runner.child.poll())
            if len(calls) == 4:
                # The previous snapshot recovered while the child was still
                # waiting. Only now may it emit the remaining output and exit.
                release.touch()
                runner.child.wait(timeout=2)
            if runner.child.poll() is not None:
                return {}
            return {runner.child.pid: {
                "pid": runner.child.pid, "parent": os.getpid(), "group": runner.child.pid,
                "started": "fixture child", "state": "S", "command": sys.executable}}

        # Test monitor ordering, not host ps latency or a three-second sleep
        # racing the five-second budget. Other fixtures exercise real ps/time.
        clock = Mock(monotonic=lambda: now[0], sleep=advance)
        try:
            with patch.object(HARNESS, "time", clock), \
                    patch.object(HARNESS, "processes", side_effect=inventory):
                self.assertEqual(runner.run(), 0)
        finally:
            if getattr(runner, "child", None) is not None and runner.child.poll() is None:
                runner.child.kill()
                runner.child.wait(timeout=2)
        receipt = self.receipt()
        observation = receipt["monitoring_inventory"]
        self.assertEqual(observation["timeout_count"], 1)
        self.assertEqual(observation["recovery_count"], 1)
        self.assertFalse(observation["pending_timeout"])
        self.assertGreater(observation["last_recovery_elapsed_seconds"],
                           observation["last_timeout_elapsed_seconds"])
        self.assertEqual(calls[:3], [2, 2, 2])
        self.assertEqual(runner.console.getvalue().splitlines(),
                         [str(i).encode() for i in range(30)])
        self.assertEqual(receipt["child_exit_code"], 0)
        self.assertEqual(receipt["cleanup"], {"signals": [], "remaining": [], "errors": []})
        self.assertEqual(receipt["errors"], [])
        self.assertTrue(receipt["reader_complete"])

    def test_persistent_inventory_timeout_at_zero_exit_cannot_pass(self):
        runner = self.runner("print('completed',flush=True)")
        with patch.object(HARNESS, "processes", side_effect=subprocess.TimeoutExpired("fixture ps", 2)):
            self.assertEqual(runner.run(), 125)
        receipt = self.receipt()
        self.assertEqual(receipt["child_exit_code"], 0)
        self.assertEqual(receipt["reason"], "inventory_unresolved")
        self.assertTrue(receipt["monitoring_inventory"]["pending_timeout"])
        self.assertEqual(receipt["monitoring_inventory"]["recovery_count"], 0)
        self.assertTrue(receipt["cleanup"]["errors"])

    def test_post_exit_fresh_inventory_cannot_clear_monitoring_timeout(self):
        runner = self.runner("import time; time.sleep(1.2)")
        processes = HARNESS.processes
        calls = []

        def inventory(timeout):
            calls.append(timeout)
            if len(calls) == 1:
                raise subprocess.TimeoutExpired("fixture ps", timeout)
            if len(calls) == 2:
                runner.child.wait(timeout=2)
            return processes(timeout=timeout)

        with patch.object(HARNESS, "processes", side_effect=inventory):
            self.assertEqual(runner.run(), 125)
        receipt = self.receipt()
        self.assertEqual(receipt["child_exit_code"], 0)
        self.assertEqual(receipt["reason"], "inventory_unresolved")
        self.assertTrue(receipt["monitoring_inventory"]["pending_timeout"])
        self.assertEqual(receipt["monitoring_inventory"]["recovery_count"], 0)
        self.assertEqual(receipt["cleanup"], {"signals": [], "remaining": [], "errors": []})

    def test_persistent_inventory_timeout_remains_runtime_bounded_and_reaps_child(self):
        runner = self.runner("import time; time.sleep(30)", timeout=1.2)
        start = time.monotonic()
        with patch.object(HARNESS, "processes", side_effect=subprocess.TimeoutExpired("fixture ps", 2)):
            self.assertEqual(runner.run(), 124)
        self.assertLess(time.monotonic() - start, 3)
        receipt = self.receipt()
        self.assertEqual(receipt["reason"], "timeout")
        self.assertGreaterEqual(receipt["monitoring_inventory"]["timeout_count"], 2)
        self.assertTrue(receipt["monitoring_inventory"]["pending_timeout"])
        self.assertEqual(receipt["monitoring_inventory"]["recovery_count"], 0)
        self.assertTrue(receipt["cleanup"]["errors"])
        self.assertIsNotNone(runner.child.returncode)
        self.assertTrue(any(item.get("direct_child_fallback")
                            for item in receipt["cleanup"]["signals"]))
        with self.assertRaises(ProcessLookupError):
            os.kill(runner.child.pid, 0)

    def test_pending_inventory_timeout_preserves_child_failure_and_signal_precedence(self):
        for index, (child_exit, received_signal, expected) in enumerate(
                ((7, None, 7), (0, signal.SIGTERM, 128 + signal.SIGTERM))):
            with self.subTest(child_exit=child_exit, received_signal=received_signal):
                runner = self.runner(f'import sys; sys.exit({child_exit})')
                runner.directory = self.root / str(index)
                processes = HARNESS.processes
                first = True

                def inventory(timeout):
                    nonlocal first
                    if first:
                        first = False
                        runner.child.wait(timeout=2)
                        if received_signal is not None:
                            runner.signals.append(received_signal)
                        raise subprocess.TimeoutExpired("fixture ps", timeout)
                    return processes(timeout=timeout)

                with patch.object(HARNESS, "processes", side_effect=inventory):
                    self.assertEqual(runner.run(), expected)
                receipt = json.loads((runner.directory / "receipt.json").read_text())
                self.assertEqual(receipt["child_exit_code"], child_exit)
                self.assertEqual(receipt["reason"], "signal" if received_signal else "exit")
                self.assertTrue(receipt["monitoring_inventory"]["pending_timeout"])
                self.assertEqual(receipt["cleanup"], {"signals": [], "remaining": [], "errors": []})

    def test_empty_or_malformed_inventory_is_an_error(self):
        for output in ("", "unexpected process format\n"):
            with self.subTest(output=output), \
                    patch.object(HARNESS.subprocess, "check_output", return_value=output), \
                    self.assertRaises(RuntimeError):
                HARNESS.processes()

    def test_cancellation_propagates_and_cleans_owned_child(self):
        output = self.root / "diagnostics"
        wrapper = subprocess.Popen(
            [sys.executable, str(SCRIPT), "--diagnostics-dir", str(output),
             "--timeout-seconds", "5", "--", sys.executable, "-c",
             "import time; print('ready',flush=True); time.sleep(30)"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual(wrapper.stdout.readline().strip(), b"ready")
            wrapper.send_signal(signal.SIGTERM)
            _, stderr = wrapper.communicate(timeout=10)
            self.assertEqual(wrapper.returncode, 128 + signal.SIGTERM, stderr)
            receipt = self.receipt()
            self.assertEqual(receipt["reason"], "signal")
            self.assertEqual(receipt["cleanup"]["remaining"], [])
        finally:
            if wrapper.poll() is None:
                wrapper.kill()
                wrapper.wait(timeout=2)

    def test_signal_recorded_during_success_cleanup_cannot_report_success(self):
        runner = self.runner("pass")
        cleanup = runner.cleanup

        def interrupted_cleanup(deadline, **kwargs):
            runner.signals.append(signal.SIGTERM)
            return cleanup(deadline, **kwargs)

        with patch.object(runner, "cleanup", side_effect=interrupted_cleanup):
            self.assertEqual(runner.run(), 128 + signal.SIGTERM)
        self.assertEqual(self.receipt()["reason"], "signal")
        self.assertEqual(self.receipt()["child_exit_code"], 0)

    def test_zero_exit_first_observed_after_runtime_budget_cannot_pass(self):
        runner = self.runner("pass", timeout=0.1)
        refresh = runner.refresh
        first = True

        def delayed_snapshot(**kwargs):
            nonlocal first
            if first:
                first = False
                time.sleep(0.25)
            return refresh(**kwargs)

        with patch.object(runner, "refresh", side_effect=delayed_snapshot):
            self.assertEqual(runner.run(), 124)
        self.assertEqual(self.receipt()["reason"], "timeout")
        self.assertEqual(self.receipt()["child_exit_code"], 0)


if __name__ == "__main__":
    unittest.main()
