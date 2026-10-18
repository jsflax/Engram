"""Mirror diagnostics controls; no server, network, native build or real signals."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('mirror_diagnostics', Path(__file__).with_name('artifact_mirror_diagnostics.py'))
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)


class MirrorDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        base = Path(os.environ.get('ENGRAM_CI_TEST_ROOT', str(Path.home() / 'localdev/engram-ci-python-fixtures')))
        base.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='mirror-diagnostics-', dir=base)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        for name in ('private', 'evidence', 'mirror'):
            (self.root / name).mkdir()
        (self.root / 'private/mirror.pid').write_text('12345\n')
        self.command = '/opt/python/bin/python3.12 -B -m http.server 8765 --bind 127.0.0.1 --directory ' + str(self.root / 'mirror')
        self.row = {'status': 'owned', 'pid': 12345, 'started': 'Sun Oct 18 14:55:31 2026',
                    'command': self.command, 'command_sha256': 'test-command-hash'}
        self.absent = {'status': 'absent', 'pid': 12345}

    def test_failure_retains_bounded_server_stderr_and_exact_listener_only(self):
        (self.root / 'private/mirror.log').write_bytes(b'x' * (M.LIMIT + 100))
        listener = {'status': 'complete', 'exit_code': 0, 'stdout': 'p12345\nn127.0.0.1:8765\n'}
        with patch.object(M, 'process', return_value=self.row), patch.object(M, 'command', return_value=listener) as command:
            receipt = M.diagnose(self.root, 28)
        self.assertEqual(receipt['curl_exit_code'], 28)
        self.assertEqual(receipt['stderr']['retained_bytes'], M.LIMIT)
        self.assertTrue(receipt['stderr']['truncated'])
        self.assertEqual((self.root / 'evidence/mirror-stderr.log').read_bytes(), b'x' * M.LIMIT)
        self.assertEqual(receipt['listener'], listener)
        command.assert_called_once_with(['/usr/sbin/lsof', '-nP', '-a', '-p', '12345', '-iTCP:8765', '-sTCP:LISTEN', '-FpcnT'])

    def test_exited_server_keeps_stderr_without_broad_listener_scan(self):
        (self.root / 'private/mirror.log').write_text('startup fixture error\n')
        with patch.object(M, 'process', return_value=self.absent), patch.object(M, 'command') as command:
            receipt = M.diagnose(self.root, 7)
        command.assert_not_called()
        self.assertEqual(receipt['process'], self.absent)
        self.assertEqual(receipt['curl_exit_code'], 7)
        self.assertEqual((self.root / 'evidence/mirror-stderr.log').read_text(), 'startup fixture error\n')

    def test_exact_command_uid_and_path_required_unexpected_argv_not_retained(self):
        good = f'12345 {os.getuid()} Sun Oct 18 14:55:31 2026 {self.command}\n'
        for row, expected in ((good, 'owned'), (good.replace('/mirror\n', '/other\n'), 'identity_mismatch'),
                              (good.replace('12345 ', '12346 ', 1), 'identity_mismatch'),
                              (good.replace(f' {os.getuid()} ', ' 999999 ', 1), 'identity_mismatch'),
                              (good.replace(self.command, 'unrelated --token=secret'), 'identity_mismatch')):
            with self.subTest(expected=expected), patch.object(M, 'command', return_value={'status': 'complete', 'exit_code': 0, 'stdout': row}):
                receipt = M.process(12345, self.root)
                self.assertEqual(receipt['status'], expected)
                if expected != 'owned': self.assertNotIn('command', receipt)
                self.assertNotIn('secret', json.dumps(receipt))

    def test_pid_and_stderr_symlinks_refuse_without_following_or_signal(self):
        outside = self.root / 'outside'; outside.write_text('not diagnostic input')
        (self.root / 'private/mirror.log').symlink_to(outside)
        with patch.object(M, 'process', return_value=self.absent):
            self.assertEqual(M.diagnose(self.root, 28)['stderr']['status'], 'unavailable_or_unsafe')
        pid = self.root / 'private/mirror.pid'; pid.unlink(); pid.symlink_to(outside)
        with patch.object(M.os, 'kill') as kill:
            self.assertFalse(M.stop(self.root)['stopped_or_not_started'])
        kill.assert_not_called()
        self.assertFalse((self.root / 'evidence/mirror-stderr.log').exists())

    def test_cleanup_rechecks_birth_command_and_absence_before_signal(self):
        for changed in (dict(self.row, started='later birth'), dict(self.row, command_sha256='changed'),
                        {'status': 'inspection_failed', 'pid': 12345}, self.absent):
            with self.subTest(changed=changed), patch.object(M, 'process', side_effect=[self.row, changed]), patch.object(M.os, 'kill') as kill:
                receipt = M.stop(self.root)
                self.assertIsNone(receipt['signal'])
                self.assertEqual(receipt['after'], changed)
                kill.assert_not_called()

    def test_cleanup_terminates_only_confirmed_owner_and_observes_exit(self):
        with patch.object(M, 'process', side_effect=[self.row, self.row, self.absent]), patch.object(M.os, 'kill') as kill:
            receipt = M.stop(self.root)
        kill.assert_called_once_with(12345, signal.SIGTERM)
        self.assertEqual(receipt['signal'], 'SIGTERM')
        self.assertTrue(receipt['stopped_or_not_started'])

    def test_cleanup_remains_bounded_and_never_claims_alive_owner_was_reaped(self):
        with patch.object(M, 'process', return_value=self.row), patch.object(M.os, 'kill') as kill, patch.object(M.time, 'monotonic', side_effect=[0, 4]):
            receipt = M.stop(self.root)
        kill.assert_called_once_with(12345, signal.SIGTERM)
        self.assertFalse(receipt['stopped_or_not_started'])
        self.assertNotIn('reaped', receipt)

    def test_process_inspection_timeout_and_output_limit_are_typed_no_raw_stderr(self):
        with patch.object(M.subprocess, 'run', side_effect=subprocess.TimeoutExpired('ps', 2)):
            self.assertEqual(M.command(['ps']), {'status': 'timeout'})
        with patch.object(M.subprocess, 'run', return_value=subprocess.CompletedProcess('ps', 0, b'x'*(M.LIMIT+1), b'secret')):
            self.assertEqual(M.command(['ps']), {'status': 'output_limit'})
        with patch.object(M.subprocess, 'run', return_value=subprocess.CompletedProcess('ps', 1, b'', b'secret')):
            self.assertEqual(M.command(['ps']), {'status': 'complete', 'exit_code': 1, 'stdout': ''})

    def test_workflow_preserves_curl_failure_even_when_diagnostics_fail(self):
        repo = Path(__file__).parents[1]
        blocks = []
        for workflow in ('native-validation.yml', 'visualizer-validation.yml'):
            text = (repo / '.github/workflows' / workflow).read_text()
            section = text.split('          mirror_status=0\n', 1)[1].split('          fi\n', 1)[0]
            block = 'mirror_status=0\n' + '\n'.join(line[10:] for line in section.splitlines()) + '\nfi\n'
            blocks.append(block)
            self.assertIn('for attempt in 1 2 3 4 5;', text)
            self.assertIn('curl -sSf --max-time 2', text)
            self.assertIn('curl -sSf --max-time 5', block)
            self.assertIn('artifact_mirror_diagnostics.py" stop --root "$VALIDATION_ROOT"', text)
            for status in (0, 28):
                code = f'curl() {{ return {status}; }}\npython3() {{ echo "$*"; return 99; }}\n' + block
                result = subprocess.run(['/bin/bash', '-eu', '-o', 'pipefail', '-c', code],
                                        env=dict(os.environ, VALIDATION_ROOT=str(self.root)),
                                        capture_output=True, text=True, timeout=2)
                self.assertEqual(result.returncode, status)
                self.assertEqual(bool(result.stdout), bool(status))
                if status: self.assertIn('--curl-status 28', result.stdout)
        self.assertEqual(blocks[0], blocks[1])


if __name__ == '__main__':
    unittest.main()
