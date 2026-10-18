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

    def test_changed_reviewed_row_reports_fixed_reason_without_dispatch(self):
        from test_reviewed_accounting import AccountingFixture
        f = AccountingFixture()
        self.addCleanup(f.close)
        f.writer.close()
        review = f.base / 'cli-reviewed.json'
        review.write_bytes(f.reviewed_raw); review.chmod(0o600)
        f.base_fixture.update_row('content=?', ('PRIVATE changed after review',))
        before, rows = f.current(), f.store.read_bytes()
        args = self.arguments(f, 'prepare', pins=False) + ['--review', str(review),
            '--review-sha256', f.reviewed_sha256, '--evidence-directory', str(f.evidence)]
        with mock.patch.object(CLI.operation_probe, 'probe_scope', return_value=f.scope):
            code, result = self.invoke(args)
        self.assertEqual(code, 2)
        self.assertEqual(result['reason'], 'legacy_reconciliation_readback_changed')
        self.assertEqual(f.current(), before)
        self.assertEqual(f.store.read_bytes(), rows)
        self.assertFalse(result['provider_invoked'])

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



class CoordinationLockTests(unittest.TestCase):
    """Real overlapping flock owners, isolated from providers and live stores."""
    def setUp(self):
        from pathlib import Path
        import tempfile
        from residual_test_support import TEMP_ROOT, PLUGIN_ROOT, runtime
        self.runtime = runtime('runner')
        self.scripts = PLUGIN_ROOT / 'scripts'
        TEMP_ROOT.mkdir(mode=0o700, exist_ok=True)
        temporary = tempfile.TemporaryDirectory(prefix='coordination-', dir=TEMP_ROOT)
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name).resolve()
        self.root = self.base / 'learner'
        self.root.mkdir(mode=0o700)
        self.paths = [self.root / 'worker.lock', self.base / 'learner-provider.lock',
                      self.root / 'enqueue.lock']
        for path in self.paths:
            path.touch(mode=0o600)

    @contextlib.contextmanager
    def owner(self, kind):
        with contextlib.ExitStack() as stack:
            if kind == 'residual':
                locks = stack.enter_context(CLI.Coordination(self.root).worker())
                stack.enter_context(locks.enqueue())
                verify = locks.verify
            elif kind == 'migration':
                locks = stack.enter_context(J.durable.Locks(self.root))
                verify = locks.verify
            else:
                stack.enter_context(self.runtime.lock_file(self.paths[0]))
                stack.enter_context(self.runtime.lock_file(self.paths[1]))
                stack.enter_context(self.runtime.lock_file(self.paths[2]))
                verify = lambda: self.assertTrue(self.runtime.publication_locks_owned(self.root))
            yield verify

    def contender(self, path, *, legacy, standalone=False):
        import sys
        if legacy:
            # Released runners fchmod before trying flock, including on failure.
            script = '''import fcntl,json,os,sys
fd=os.open(sys.argv[2],os.O_RDWR|os.O_NOFOLLOW|os.O_CLOEXEC)
try:
 os.fchmod(fd,0o600)
 try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB); acquired=True
 except BlockingIOError: acquired=False
 print(json.dumps({'acquired':acquired}))
finally: os.close(fd)
'''
        else:
            script = '''import json,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
from codex_learner import runner
with runner.lock_file(Path(sys.argv[2]),blocking=False) as acquired:
 print(json.dumps({'acquired':acquired}))
'''
        child = subprocess.run([sys.executable, '-B', '-c', script,
            str(self.scripts.parents[3] / 'scripts' if standalone else self.scripts),
            str(path)], capture_output=True, text=True, timeout=10)
        self.assertEqual(child.returncode, 0, child.stderr)
        self.assertEqual(json.loads(child.stdout), {'acquired': False})

    def test_legacy_losing_contenders_do_not_invalidate_existing_owners(self):
        for kind in ('residual', 'migration', 'normal'):
            with self.subTest(owner=kind), self.owner(kind) as verify:
                for path in self.paths:
                    before = J.durable._identity(path.lstat())
                    self.contender(path, legacy=True)
                    after = J.durable._identity(path.lstat())
                    self.assertEqual({k for k in before if before[k] != after[k]}, {'ctime_ns'})
                    verify()

    def test_current_losing_contenders_leave_all_file_metadata_unchanged(self):
        for kind in ('residual', 'migration', 'normal'):
            with self.subTest(owner=kind), self.owner(kind) as verify:
                before = [J.durable._identity(p.lstat()) for p in self.paths]
                for path in self.paths:
                    self.contender(path, legacy=False)
                self.assertEqual([J.durable._identity(p.lstat()) for p in self.paths], before)
                verify()

    def test_standalone_losing_contenders_leave_existing_locks_unchanged(self):
        for kind in ('residual', 'migration', 'normal'):
            with self.subTest(owner=kind), self.owner(kind) as verify:
                before = J.durable._identity(self.paths[0].lstat())
                self.contender(self.paths[0], legacy=False, standalone=True)
                self.assertEqual(J.durable._identity(self.paths[0].lstat()), before)
                verify()

    def test_immutable_identity_still_detects_ctime_and_lock_identity_keeps_other_fields(self):
        from types import SimpleNamespace
        fields = ('st_dev', 'st_ino', 'st_uid', 'st_gid', 'st_mode', 'st_size',
                  'st_mtime_ns', 'st_ctime_ns', 'st_nlink')
        values = {k: getattr(self.paths[0].lstat(), k) for k in fields}
        before = SimpleNamespace(**values)
        for key in fields:
            with self.subTest(field=key):
                after = SimpleNamespace(**{**values, key: values[key] + 1})
                self.assertNotEqual(J.durable._identity(before), J.durable._identity(after))
                if key == 'st_ctime_ns':
                    self.assertEqual(J.durable._lock_identity(before), J.durable._lock_identity(after))
                else:
                    self.assertNotEqual(J.durable._lock_identity(before), J.durable._lock_identity(after))

    def test_path_and_safety_changes_still_invalidate_coordination(self):
        for kind in ('residual', 'migration'):
            for change in ('replace', 'symlink', 'mode', 'hardlink', 'size', 'mtime'):
                with self.subTest(owner=kind, change=change):
                    path = self.paths[0]
                    with self.owner(kind) as verify:
                        if change == 'replace':
                            path.unlink(); path.touch(mode=0o600)
                        elif change == 'symlink':
                            target = self.base / 'saved-worker'
                            path.rename(target); path.symlink_to(target)
                        elif change == 'mode':
                            path.chmod(0o640)
                        elif change == 'hardlink':
                            os.link(path, self.base / 'extra-link')
                        elif change == 'size':
                            path.write_bytes(b'changed')
                        else:
                            info = path.stat()
                            os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns + 1_000_000_000))
                        with self.assertRaisesRegex(ValueError, 'lock_changed'):
                            verify()
                    path.unlink()
                    for extra in (self.base / 'saved-worker', self.base / 'extra-link'):
                        extra.unlink(missing_ok=True)
                    path.touch(mode=0o600)

    def test_unsafe_locks_are_refused_before_acquisition(self):
        for kind in ('residual', 'migration'):
            for change in ('symlink', 'mode', 'hardlink'):
                with self.subTest(owner=kind, change=change):
                    path = self.paths[0]
                    extra = self.base / 'extra'
                    if change == 'symlink':
                        path.rename(extra); path.symlink_to(extra)
                    elif change == 'mode':
                        path.chmod(0o644)
                    else:
                        os.link(path, extra)
                    with self.assertRaises((OSError, ValueError)):
                        with self.owner(kind):
                            self.fail('Unsafe coordination lock admitted')
                    path.unlink(); extra.unlink(missing_ok=True); path.touch(mode=0o600)

    def test_current_winner_still_normalizes_owned_lock_permissions(self):
        path = self.paths[0]
        path.chmod(0o640)
        with self.runtime.lock_file(path, blocking=False) as acquired:
            self.assertIs(acquired, True)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_busy_cli_reports_specific_reason_without_recovery_dispatch(self):
        output = io.StringIO()
        arguments = ['recover', '--root', str(self.root), '--config', str(self.base),
            '--package-root', str(self.base), '--candidate-store', str(self.base), '--session-id', SID]
        with self.runtime.lock_file(self.paths[0]), contextlib.redirect_stdout(output), \
                mock.patch.object(CLI, '_base_paths'), \
                mock.patch.object(CLI, '_retained_summary', return_value={}), \
                mock.patch.object(CLI, '_recover', side_effect=AssertionError('Busy lock dispatched recovery')):
            code = CLI.main(arguments)
        result = json.loads(output.getvalue())
        self.assertEqual(code, 2)
        self.assertEqual(result['reason'], 'residual_cli_coordination_busy')
        self.assertEqual(result['status'], 'held')
        self.assertFalse(result['provider_invoked'])
        self.assertFalse(result['successful_coverage'])


if __name__ == '__main__':
    unittest.main()
