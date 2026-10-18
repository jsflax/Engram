"""Mirror controls; loopback fixture HTTP only, no native build or real signals."""
from contextlib import redirect_stderr
from functools import partial
from http.client import HTTPConnection
from http.server import HTTPServer, SimpleHTTPRequestHandler
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('mirror_diagnostics', Path(__file__).with_name('artifact_mirror_diagnostics.py'))
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)
server_spec = importlib.util.spec_from_file_location('mirror_server', Path(__file__).with_name('artifact_mirror_server.py'))
S = importlib.util.module_from_spec(server_spec)
server_spec.loader.exec_module(S)


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
        self.command = ('/opt/python/bin/python3.12 -B ' + str(self.root / 'repo/scripts/artifact_mirror_server.py')
                        + ' --directory ' + str(self.root / 'mirror'))
        self.row = {'status': 'owned', 'pid': 12345, 'started': 'Sun Oct 18 14:55:31 2026',
                    'command': self.command, 'command_sha256': 'test-command-hash'}
        self.absent = {'status': 'absent', 'pid': 12345}

    def test_failure_retains_bounded_server_stderr_and_exact_owned_sockets(self):
        (self.root / 'private/mirror.log').write_bytes(b'x' * (M.LIMIT + 100))
        listener = {'status': 'complete', 'exit_code': 0, 'stdout': 'p12345\nn127.0.0.1:8765\n'}
        with patch.object(M, 'process', return_value=self.row), patch.object(M, 'command', return_value=listener) as command, patch.object(M, 'sample_mirror', return_value={'status': 'unavailable', 'qualified': False}) as sample:
            receipt = M.diagnose(self.root, 28)
        self.assertEqual(receipt['curl_exit_code'], 28)
        self.assertEqual(receipt['stderr']['retained_bytes'], M.LIMIT)
        self.assertTrue(receipt['stderr']['truncated'])
        self.assertEqual((self.root / 'evidence/mirror-stderr.log').read_bytes(), b'x' * M.LIMIT)
        self.assertEqual(receipt['sockets']['result'], listener)
        self.assertTrue(receipt['sockets']['qualified'])
        sample.assert_called_once_with(self.root, self.row)
        command.assert_called_once_with(['/usr/sbin/lsof', '-nP', '-a', '-p', '12345', '-iTCP:8765', '-FpcnT'])

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
                              (good.replace('/repo/scripts/artifact_mirror_server.py', '/other/artifact_mirror_server.py'), 'identity_mismatch'),
                              (good.replace(self.command, '/opt/python/bin/python3.12 -B -m http.server 8765 --bind 127.0.0.1 --directory ' + str(self.root / 'mirror')), 'identity_mismatch'),
                              (good.replace(self.command, 'unrelated --token=secret'), 'identity_mismatch')):
            with self.subTest(expected=expected), patch.object(M, 'command', return_value={'status': 'complete', 'exit_code': 0, 'stdout': row}):
                receipt = M.process(12345, self.root)
                self.assertEqual(receipt['status'], expected)
                if expected != 'owned': self.assertNotIn('command', receipt)
                self.assertNotIn('secret', json.dumps(receipt))

    def test_numeric_bind_serves_identical_artifact_when_reverse_dns_fails(self):
        data = bytes(range(256)) * 19
        (self.root / 'mirror/Sparkle-for-Swift-Package-Manager.zip').write_bytes(data)
        handler = partial(SimpleHTTPRequestHandler, directory=str(self.root / 'mirror'))
        with patch('socket.getfqdn', side_effect=AssertionError('reverse DNS must not run')) as fqdn, patch('socket.gethostbyaddr', side_effect=AssertionError('reverse DNS must not run')) as reverse, redirect_stderr(io.StringIO()):
            # The control reaches the original failure seam on this interpreter.
            with self.assertRaisesRegex(AssertionError, 'reverse DNS must not run'):
                HTTPServer(('127.0.0.1', 0), handler)
            fqdn.reset_mock()
            with S.NumericLoopbackServer(('127.0.0.1', 0), handler) as server:
                self.assertEqual(server.server_name, '127.0.0.1')
                self.assertEqual(server.server_port, server.server_address[1])
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                client = HTTPConnection('127.0.0.1', server.server_port, timeout=2)
                try:
                    for method in ('GET', 'HEAD'):
                        client.request(method, '/Sparkle-for-Swift-Package-Manager.zip')
                        response = client.getresponse()
                        self.assertEqual(response.status, 200)
                        self.assertEqual(response.version, 10)
                        self.assertEqual(int(response.getheader('Content-Length')), len(data))
                        self.assertEqual(response.read(), data if method == 'GET' else b'')
                finally:
                    client.close()
                    server.shutdown()
                    thread.join(timeout=2)
                    self.assertFalse(thread.is_alive())
            fqdn.assert_not_called()
            reverse.assert_not_called()

    def test_server_cli_keeps_fixed_loopback_port_and_standard_handler(self):
        with patch.object(S, 'NumericLoopbackServer') as server:
            S.main(['--directory', str(self.root / 'mirror')])
        args, kwargs = server.call_args
        self.assertEqual(args[0], ('127.0.0.1', 8765))
        self.assertIs(args[1].func, SimpleHTTPRequestHandler)
        self.assertEqual(args[1].keywords, {'directory': str(self.root / 'mirror')})
        self.assertEqual(kwargs, {})
        server.return_value.__enter__.return_value.serve_forever.assert_called_once_with()

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

    def test_cleanup_observes_argv_exit_transition_until_actual_absence(self):
        owned = f'12345 {os.getuid()} Sun Oct 18 14:55:31 2026 {self.command}\n'
        exited_argv = f'12345 {os.getuid()} Sun Oct 18 14:55:31 2026 (Python)\n'
        outputs = [{'status': 'complete', 'exit_code': 0, 'stdout': row}
                   for row in (owned, owned, exited_argv)]
        outputs.append({'status': 'complete', 'exit_code': 1, 'stdout': ''})
        with patch.object(M, 'command', side_effect=outputs) as command, patch.object(M.os, 'kill') as kill, patch.object(M.time, 'monotonic', side_effect=[0, 0.25]), patch.object(M.time, 'sleep') as sleep:
            receipt = M.stop(self.root)
        kill.assert_called_once_with(12345, signal.SIGTERM)
        self.assertEqual(command.call_count, 4)
        sleep.assert_called_once_with(0.1)
        self.assertEqual(receipt['after'], self.absent)
        self.assertTrue(receipt['stopped_or_not_started'])
        self.assertEqual(receipt['first_transition'], {
            'status': 'identity_mismatch', 'pid': 12345,
            'started': 'Sun Oct 18 14:55:31 2026',
            'command_sha256': M.hashlib.sha256(b'(Python)').hexdigest(),
        })
        self.assertEqual(json.loads((self.root / 'evidence/mirror-cleanup.json').read_text()), receipt)

    def test_cleanup_changed_or_reused_pid_never_qualifies_without_absence(self):
        transition = {'status': 'identity_mismatch', 'pid': 12345,
                      'started': self.row['started'], 'command_sha256': 'exited-argv'}
        reused = dict(transition, started='later birth', command_sha256='unrelated-argv')
        for final in (transition, reused):
            with self.subTest(final=final), patch.object(M, 'process', side_effect=[self.row, self.row, transition, final]) as process, patch.object(M.os, 'kill') as kill, patch.object(M.time, 'monotonic', side_effect=[0, 1, 3]), patch.object(M.time, 'sleep') as sleep:
                receipt = M.stop(self.root)
            kill.assert_called_once_with(12345, signal.SIGTERM)
            self.assertEqual(process.call_count, 4)
            sleep.assert_called_once_with(0.1)
            self.assertEqual(receipt['first_transition'], transition)
            self.assertEqual(receipt['after'], final)
            self.assertFalse(receipt['stopped_or_not_started'])
            self.assertNotIn('reaped', receipt)

    def test_process_inspection_timeout_and_output_limit_are_typed_no_raw_stderr(self):
        with patch.object(M.subprocess, 'run', side_effect=subprocess.TimeoutExpired('ps', 2)):
            self.assertEqual(M.command(['ps']), {'status': 'timeout'})
        with patch.object(M.subprocess, 'run', return_value=subprocess.CompletedProcess('ps', 0, b'x'*(M.LIMIT+1), b'secret')):
            self.assertEqual(M.command(['ps']), {'status': 'output_limit'})
        with patch.object(M.subprocess, 'run', return_value=subprocess.CompletedProcess('ps', 1, b'', b'secret')):
            self.assertEqual(M.command(['ps']), {'status': 'complete', 'exit_code': 1, 'stdout': ''})

    def test_sample_success_uses_owned_pid_private_output_and_child_only_limit(self):
        data = b'Call graph: fixture stack\n'
        def sampled(argv, **kwargs):
            self.assertEqual(argv, ['/usr/bin/sample', '12345', '1', '10', '-file', str(self.root / 'evidence/mirror-sample.txt')])
            self.assertEqual(kwargs, dict(stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL, timeout=10, preexec_fn=M.sample_limit))
            path = Path(argv[-1])
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            path.write_bytes(data)
            return subprocess.CompletedProcess(argv, 0)
        with patch.object(M, 'process', return_value=self.row), patch.object(M.subprocess, 'run', side_effect=sampled) as run:
            receipt = M.sample_mirror(self.root, self.row)
        self.assertTrue(receipt['qualified'])
        self.assertEqual(receipt['retained_bytes'], len(data))
        self.assertEqual(receipt['sha256'], M.hashlib.sha256(data).hexdigest())
        run.assert_called_once()

    def test_sample_timeout_failure_and_output_cap_retain_partial_unqualified_evidence(self):
        path = self.root / 'evidence/mirror-sample.txt'
        for status in ('timeout', 'failed', 'capped', 'unavailable'):
            with self.subTest(status=status):
                data = b'x' * (M.SAMPLE_LIMIT if status == 'capped' else 19)
                def sampled(argv, **kwargs):
                    path.write_bytes(data)
                    if status == 'timeout': raise subprocess.TimeoutExpired(argv, 10)
                    if status == 'unavailable': raise FileNotFoundError('sample unavailable')
                    return subprocess.CompletedProcess(argv, 0 if status == 'capped' else 1)
                with patch.object(M, 'process', return_value=self.row), patch.object(M.subprocess, 'run', side_effect=sampled):
                    receipt = M.sample_mirror(self.root, self.row)
                self.assertFalse(receipt['qualified'])
                self.assertEqual(receipt['status'], status if status in ('timeout', 'unavailable') else 'complete')
                self.assertEqual(receipt['retained_bytes'], len(data))
                self.assertEqual(receipt['truncated'], status == 'capped')
                self.assertEqual(path.read_bytes(), data)
                path.unlink()

    def test_sample_requires_same_owner_before_and_after(self):
        changed = dict(self.row, started='changed birth')
        with patch.object(M, 'process', return_value=changed), patch.object(M.subprocess, 'run') as run:
            receipt = M.sample_mirror(self.root, self.row)
        self.assertFalse(receipt['qualified'])
        self.assertEqual(receipt['status'], 'identity_changed')
        run.assert_not_called()
        def sampled(argv, **kwargs):
            Path(argv[-1]).write_bytes(b'partial evidence')
            return subprocess.CompletedProcess(argv, 0)
        with patch.object(M, 'process', side_effect=[self.row, changed]), patch.object(M.subprocess, 'run', side_effect=sampled):
            receipt = M.sample_mirror(self.root, self.row)
        self.assertFalse(receipt['qualified'])
        self.assertEqual(receipt['after'], changed)
        self.assertEqual(receipt['retained_bytes'], 16)

    def test_sample_refuses_existing_or_symlink_destination(self):
        path = self.root / 'evidence/mirror-sample.txt'
        outside = self.root / 'original'; outside.write_bytes(b'preserve')
        for symlink in (False, True):
            with self.subTest(symlink=symlink):
                if symlink: path.symlink_to(outside)
                else: path.write_bytes(b'preserve')
                with patch.object(M, 'process', return_value=self.row), patch.object(M.subprocess, 'run') as run:
                    receipt = M.sample_mirror(self.root, self.row)
                self.assertEqual(receipt['status'], 'output_unavailable_or_exists')
                self.assertFalse(receipt['qualified'])
                run.assert_not_called()
                self.assertEqual(path.read_bytes(), b'preserve')
                self.assertEqual(outside.read_bytes(), b'preserve')
                path.unlink()

    def test_sample_limit_does_not_raise_existing_child_hard_limit(self):
        for hard, expected in ((M.resource.RLIM_INFINITY, M.SAMPLE_LIMIT), (M.SAMPLE_LIMIT * 2, M.SAMPLE_LIMIT), (4096, 4096)):
            with self.subTest(hard=hard), patch.object(M.resource, 'getrlimit', return_value=(hard, hard)), patch.object(M.resource, 'setrlimit') as setlimit:
                M.sample_limit()
                setlimit.assert_called_once_with(M.resource.RLIMIT_FSIZE, (expected, expected))

    def test_sockets_identity_changes_never_qualify_or_query_other_pid(self):
        changed = dict(self.row, command_sha256='changed')
        with patch.object(M, 'process', return_value=changed), patch.object(M, 'command') as command:
            receipt = M.sockets(self.root, self.row)
        self.assertFalse(receipt['qualified'])
        command.assert_not_called()
        result = {'status': 'complete', 'exit_code': 1, 'stdout': ''}
        with patch.object(M, 'process', side_effect=[self.row, changed]), patch.object(M, 'command', return_value=result) as command:
            receipt = M.sockets(self.root, self.row)
        self.assertFalse(receipt['qualified'])
        self.assertEqual(receipt['after'], changed)
        command.assert_called_once_with(['/usr/sbin/lsof', '-nP', '-a', '-p', '12345', '-iTCP:8765', '-FpcnT'])

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
            self.assertIn('nohup python3 -B "$VALIDATION_ROOT/repo/scripts/artifact_mirror_server.py" --directory "$VALIDATION_ROOT/mirror"', text)
            self.assertNotIn('-m http.server', text)
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
