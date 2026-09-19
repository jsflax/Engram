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

        def interrupted_cleanup(deadline):
            runner.signals.append(signal.SIGTERM)
            return cleanup(deadline)

        with patch.object(runner, "cleanup", side_effect=interrupted_cleanup):
            self.assertEqual(runner.run(), 128 + signal.SIGTERM)
        self.assertEqual(self.receipt()["reason"], "signal")
        self.assertEqual(self.receipt()["child_exit_code"], 0)

    def test_zero_exit_first_observed_after_runtime_budget_cannot_pass(self):
        runner = self.runner("pass", timeout=0.1)
        refresh = runner.refresh
        first = True

        def delayed_snapshot():
            nonlocal first
            if first:
                first = False
                time.sleep(0.25)
            return refresh()

        with patch.object(runner, "refresh", side_effect=delayed_snapshot):
            self.assertEqual(runner.run(), 124)
        self.assertEqual(self.receipt()["reason"], "timeout")
        self.assertEqual(self.receipt()["child_exit_code"], 0)


if __name__ == "__main__":
    unittest.main()
