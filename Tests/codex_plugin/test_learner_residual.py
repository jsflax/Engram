"""CLI orchestration against real private coordination/fence/publication files.

The fixture native executable is never launched. Trusted synthetic adapter calls
write only the disposable SQLite fixture; native process behavior is separately
qualified by the driver matrix.
"""
import contextlib
import fcntl
import io
import json
import os
import subprocess
import unittest
from unittest import mock

from residual_context_fixture import ResidualContextFixture, J, SID
import learner_residual as CLI


class ResidualCLITests(unittest.TestCase):
    def fixture(self, *, sealed=True):
        f = ResidualContextFixture()
        self.addCleanup(f.close)
        if sealed:
            f.seal(prepare_driver=False)
        f.writer.close()
        return f

    def arguments(self, f, command, *, pins=True):
        value = [command, '--root', str(f.root), '--config', str(f.config),
                 '--package-root', str(f.plugin), '--candidate-store', str(f.store), '--session-id', SID]
        if pins:
            value += ['--run-id', f.run_dir.name, '--manifest-sha256', f.context.manifest_sha256,
                      '--context-sha256', f.context.context_sha256]
        return value

    def invoke(self, args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), mock.patch.object(subprocess, 'Popen',
                side_effect=AssertionError('No provider/native launch in orchestration fixture')):
            code = CLI.main(args)
        raw = output.getvalue()
        self.assertNotIn('PRIVATE', raw)
        return code, json.loads(raw)

    def test_prepare_seals_only_and_same_effective_route_is_probed(self):
        f = self.fixture(sealed=False)
        review = f.base / 'cli-reviewed.json'
        review.write_bytes(f.reviewed_raw); review.chmod(0o600)
        before, history, rows = f.current(), f.history_snapshot(), f.rows()
        calls = []
        def probe(transport, *, writer_fence, expected_binding):
            self.assertIs(writer_fence.verify(expected_binding), True)
            self.assertEqual(transport['env']['CLAUDE_MEMORY_DB'], str(f.store))
            self.assertTrue(transport['cwd'].endswith('/workspace'))
            calls.append(transport)
            return f.scope
        args = self.arguments(f, 'prepare', pins=False) + ['--review', str(review),
            '--review-sha256', f.reviewed_sha256, '--evidence-directory', str(f.evidence)]
        with mock.patch.object(CLI.operation_probe, 'probe_scope', side_effect=probe):
            code, result = self.invoke(args)
        self.assertEqual((code, result['status']), (0, 'prepared'))
        self.assertEqual(len(calls), 1)
        run = f.root / 'runs' / result['run_id']
        self.assertTrue((run / 'execution-manifest.json').exists())
        self.assertTrue((run / 'residual-context.json').exists())
        self.assertFalse((run / 'residual-generation-000.json').exists())
        self.assertEqual(f.current(), before)
        self.assertEqual(f.history_snapshot(), history)
        self.assertEqual(f.rows(), rows)
        self.assertFalse(result['cursor_changed'])
        self.assertEqual(result['memory_mutations_requested'], 0)

    def test_execute_releases_enqueue_preserves_newer_pending_and_repeat_never_writes(self):
        f = self.fixture()
        history = f.history_snapshot()
        calls, pending = [], []
        def execute(raw, writer, check):
            # Enqueue is available while worker/provider remain held.
            fd = os.open(f.root / 'enqueue.lock', os.O_RDONLY)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                if not pending:
                    f.newer_pending(); pending.append(f.pending_path.read_bytes())
            finally:
                os.close(fd)
            calls.append(J._json(raw)['operationID'])
            return f.execute(raw, writer, check)
        with mock.patch.object(CLI.N, 'executor', return_value=execute), f.synthetic_probe():
            code, result = self.invoke(self.arguments(f, 'execute'))
            self.assertEqual((code, result['status']), (0, 'reconciled_with_residuals'))
            self.assertEqual(len(set(calls)), 5)
            self.assertEqual(f.pending_path.read_bytes(), pending[0])
            self.assertEqual(f.history_snapshot(), history)
            self.assertEqual(result['historical_run_status'], 'failed')
            self.assertFalse(result['provider_invoked'])
            self.assertFalse((f.run_dir / 'successful-coverage.json').exists())
            again, repeated = self.invoke(self.arguments(f, 'execute'))
            self.assertEqual(again, 2)
            self.assertEqual(len(calls), 5)
            recovered, done = self.invoke(self.arguments(f, 'recover'))
            self.assertEqual((recovered, done['status']), (0, 'already_reconciled'))
            self.assertEqual(len(calls), 5)

    def test_absence_requires_explicit_continuation_and_preserves_operation_ids(self):
        f = self.fixture()
        old_state = f.state_path.read_bytes()
        attempts = []
        def no_ack(raw, writer, check):
            attempts.append(J._json(raw)['operationID'])
            raise ValueError('synthetic transport interruption before mutation')
        with mock.patch.object(CLI.N, 'executor', return_value=no_ack), f.synthetic_probe():
            code, held = self.invoke(self.arguments(f, 'execute'))
            self.assertEqual(code, 2)
            self.assertEqual(held['memory_ids'], [])
            self.assertEqual(len(attempts), 1)
            code, _ = self.invoke(self.arguments(f, 'recover'))
            self.assertEqual(code, 2)
            self.assertEqual(len(attempts), 1)
        self.assertEqual(f.state_path.read_bytes(), old_state)
        retained = CLI.D.ResidualDriver(f.run_dir, manifest_sha256=f.context.manifest_sha256,
            review_sha256=f.context.review_sha256, validate_inputs=lambda *_: False)
        exact = {label: retained._intent(label)[1] for label in retained.operations}
        resumed = []
        def commit(raw, writer, check):
            resumed.append(raw)
            self.assertIn(raw, exact.values())
            return f.execute(raw, writer, check)
        with mock.patch.object(CLI.N, 'executor', return_value=commit), f.synthetic_probe():
            code, result = self.invoke(self.arguments(f, 'continue-absent'))
        self.assertEqual((code, result['status']), (0, 'reconciled_with_residuals'), result)
        self.assertEqual(resumed, list(exact.values()))
        self.assertEqual(J._json(resumed[0])['operationID'], attempts[0])
        self.assertTrue((f.run_dir / 'residual-writers/001/writer.lock').exists())

    def test_inert_pre_marker_generation_is_not_replayed(self):
        f = self.fixture()
        writer = CLI.F.acquire_shared(f.run_dir, f.binding)
        try:
            CLI.D.ResidualDriver.prepare(f.run_dir, reviewed_raw=f.reviewed_raw,
                reviewed_sha256=f.reviewed_sha256, manifest_sha256=f.context.manifest_sha256,
                writer=writer, validate_inputs=f.context.validate_inputs)
        finally:
            writer.close()
        before = f.current()
        with mock.patch.object(CLI.N, 'executor', side_effect=AssertionError('No orphan dispatch')):
            code, result = self.invoke(self.arguments(f, 'execute'))
        self.assertEqual(code, 2)
        self.assertEqual(result['reason'], 'residual_cli_incomplete_or_consumed_preparation')
        self.assertEqual(f.current(), before)

    def test_missing_pins_busy_locks_and_changed_selection_fail_without_dispatch(self):
        f = self.fixture()
        before = f.current()
        with mock.patch.object(CLI.N, 'executor', side_effect=AssertionError('No unauthorized dispatch')):
            code, result = self.invoke(self.arguments(f, 'execute', pins=False))
            self.assertEqual(code, 2)
            self.assertEqual(result['reason'], 'residual_cli_missing_execution_pins')
            fd = os.open(f.root / 'worker.lock', os.O_RDONLY)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                code, result = self.invoke(self.arguments(f, 'execute'))
                self.assertEqual(code, 2)
            finally:
                os.close(fd)
            with mock.patch.object(CLI.R, 'load_context', side_effect=ValueError('PRIVATE secret path')):
                code, result = self.invoke(self.arguments(f, 'execute'))
                self.assertEqual(code, 2)
                self.assertEqual(result['reason'], 'residual_cli_unavailable_or_changed')
        self.assertEqual(f.current(), before)


if __name__ == '__main__':
    unittest.main()
