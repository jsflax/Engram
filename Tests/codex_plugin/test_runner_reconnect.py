"""Recovered provider notices over the real runner and v2 publication protocol.

Only the provider process and native reply are synthetic. Files, admission,
parser, immutable intents/receipts, fencing and next-request publication are real
and disposable. No HOME/CODEX_HOME changes or live provider/store access.
"""
import copy
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'codex/plugins/engram/scripts'))
from codex_learner import runner as R, execution_context as C, execution_manifest as J
from codex_learner import runner_publication as P, operation_gateway as G

A, H, T = C.admission, C.host_admission, C.transcript
SID = '019b7a00-0000-7123-8000-000000000072'
VOLUME = '11111111-2222-4333-8444-555555555555'
ACTIVATION = '21111111-2222-4333-8444-555555555555'
MEMORY = 'a1111111-2222-4333-8444-555555555555'
TEST_ROOT = Path(os.environ.get('ENGRAM_CI_TEST_ROOT', str(Path.home() / 'localdev/engram-ci-python-fixtures')))


def write(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.write_bytes(J.encode(value) + b'\n'); path.chmod(0o600)


class FinishedProvider:
    pid = 123456789  # Never passed to a process API: poll always reports exit.
    def __init__(self, code): self.returncode = code
    def poll(self): return self.returncode
    def wait(self, timeout=None): return self.returncode


class RunnerReconnectTests(unittest.TestCase):
    def setUp(self):
        if TEST_ROOT.is_symlink(): raise RuntimeError('unsafe test root')
        TEST_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
        temp = tempfile.TemporaryDirectory(prefix='runner-reconnect-', dir=TEST_ROOT)
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name).resolve()
        self.root, self.project, self.sessions, self.plugin, self.host = [self.base / name for name in
            ('learner', 'project', 'sessions', 'plugin', 'host')]
        for path in (self.root, self.project, self.sessions, self.plugin, self.host): path.mkdir(mode=0o700)
        self.path = self.sessions / '2026/01/02' / ('rollout-2026-01-02T00-00-00-' + SID + '.jsonl')
        write(self.path, {'type': 'session_meta', 'payload': {'id': SID,
            'timestamp': '2026-01-02T00:00:00Z', 'cwd': str(self.project), 'source': 'vscode',
            'cli_version': 'synthetic', 'history_mode': 'paginated'}})
        self.patch(C.file_identity, 'capture_fd', side_effect=lambda fd: {
            'scheme': C.file_identity.SCHEME, 'volume_uuid': VOLUME, 'inode': os.fstat(fd).st_ino})
        policy = {'schema_version': 2, 'mode': H.MODE_V2, 'enabled': True, 'activation_id': ACTIVATION,
            'cutoff': '2026-01-01T00:00:00Z', 'state_dir': str(self.root),
            'sessions_dir': A._directory_binding(self.sessions, stable_identity=True)}
        write(self.root / 'admission.json', policy)
        payload = {'session_id': SID, 'transcript_path': str(self.path), 'cwd': str(self.project)}
        origin = H._origin(policy, payload)
        entry = {**origin, **A._frontier(origin), 'activation_id': ACTIVATION,
                 'captured_at': '2026-01-03T00:00:00Z'}
        write(self.root / 'enrollments' / (SID + '.json'), entry)
        self.request = {**payload, 'hook_session_id': SID, 'hook_cwd': str(self.project), 'event': 'Stop',
            'turn_id': 'first-turn', 'request_id': 'first-request', 'identity': entry['identity']}
        self.request['admission'] = A.check(self.root, self.request)
        self.state_path, self.admission_path, self.pending = [self.root / name / (SID + '.json')
            for name in ('sessions', 'admissions', 'pending')]
        self.frontier = entry['frontier_offset']
        state = {'session_id': SID, 'transcript_path': str(self.path), 'identity': entry['identity'],
            'offset': self.frontier, 'recent_messages': [], 'current_turn_id': None,
            'admission': self.request['admission'], 'status': 'enrolled_frontier'}
        write(self.state_path, state)
        write(self.admission_path, {'binding': self.request['admission'], 'state_sha256': C.durable.object_digest(state),
            'last_event': 'a' * 64, 'processing': None})
        write(self.pending, self.request)
        self.append('Synthetic first visible fact.')
        native = self.plugin / 'memory'
        native.write_bytes(b'\xcf\xfa\xed\xfe' + b'never-executed' * 8); native.chmod(0o700)
        config_path = self.base / 'config.toml'
        config_path.write_text('[mcp_servers.memory]\ncommand = ' + json.dumps(str(native))
            + '\nargs = []\ndefault_tools_approval_mode = "approve"\n'); config_path.chmod(0o600)
        self.config = {**R.DEFAULTS, 'max_chars': 2000, 'max_scan_bytes': 4096, 'min_chars': 1}
        write(self.root / 'settings.json', self.config)
        self.service = P.Publications(self.root, config_path, self.plugin)
        self.scope = {'version': 1, 'storeID': VOLUME, 'principal': {'kind': 'agent', 'groupIds': [], 'scopes': []}}
        self.patch(R, 'publications', return_value=self.service)
        self.patch(R, 'codex_home', return_value=self.host)
        self.patch(R, 'learner_command', return_value=['synthetic-provider-never-executed'])
        self.patch(P.operation_probe, 'probe_scope', side_effect=lambda _, writer_fence, expected_binding:
                   copy.deepcopy(self.scope) if writer_fence.verify(expected_binding) else None)
        self.patch(P.operation_probe, 'probe_statuses', side_effect=AssertionError('unexpected native status'))
        for obj, name in ((socket, 'socket'), (sqlite3, 'connect'), (subprocess, 'run'), (os, 'killpg')):
            self.patch(obj, name, side_effect=AssertionError('external effect forbidden'))
        self.patch(R.subprocess, 'Popen', side_effect=self.provider)
        self.notices = [{'type': 'error', 'message': 'Synthetic recoverable notice, attempt 2'},
                        {'type': 'error', 'message': 'Different synthetic notice, attempt 3'}]
        self.after = []; self.failed_turn = False; self.code = 0; self.completed = True
        self.cleanup = True; self.read_error = False; self.missing_write_receipt = False; self.partial = False
        self.runs, self.applies = [], []

    def patch(self, obj, name, **kwargs):
        p = mock.patch.object(obj, name, **kwargs); result = p.start(); self.addCleanup(p.stop); return result

    def append(self, text):
        with self.path.open('ab') as stream:
            stream.write(J.encode({'type': 'event_msg', 'payload': {'type': 'user_message', 'message': text}}) + b'\n')

    def provider(self, argv, **kwargs):
        self.assertEqual(argv, ['synthetic-provider-never-executed'])
        execution = R._EXECUTION.get()
        run = execution.paths.run_dir if execution is not None else Path(kwargs['cwd']).parent
        self.runs.append(run)
        audit = [{'event': 'relay_started'}, {'event': 'tool_call', 'id': 1, 'tool': 'recall'},
            {'event': 'tool_result', 'id': 1, 'tool': 'recall', 'ok': not self.read_error,
             'forwarded': True, 'memory_ids': []}]
        operation = 'synthetic-legacy-call'
        if execution is not None:
            gateway = G.OperationGateway(run, manifest_sha256=execution.context.manifest_sha256,
                writer_fence=execution.fence, validate_inputs=execution.context.validate_inputs)
            operation, _ = gateway.prepare(2, 'remember', {'content': 'Synthetic selected fact',
                'source': 'codex-session:' + SID, 'is_private': True})
            receipt = {'version': 1, 'operationID': operation, 'scope': self.scope, 'payloadDigest': 'd' * 64,
                'mutation': 'remember', 'outcome': 'applied', 'memoryIDs': [MEMORY], 'edgeIDs': [], 'committedAt': 800000000.25}
            outer = {'engram_operation': {'version': 1, 'kind': 'committed', 'receipt': receipt}}
            if not self.missing_write_receipt:
                gateway.finish(operation, {'jsonrpc': '2.0', 'id': 2, 'result': {'isError': False,
                    'structuredContent': outer, 'content': [{'type': 'text', 'text': J.encode(outer).decode()}]}})
        self.applies.append(operation)
        audit.extend([{'event': 'tool_call', 'id': 2, 'tool': 'remember'},
            {'event': 'tool_result', 'id': 2, 'tool': 'remember', 'ok': True, 'forwarded': True,
             'memory_ids': [MEMORY], 'operation_version': 1, 'operation_id': operation,
             'operation_outcome': 'applied', 'operation_payload_digest': 'd' * 64},
            {'event': 'relay_interrupted'}])
        if execution is None:
            for row in audit:
                for key in list(row):
                    if key.startswith('operation_'): del row[key]
            if self.missing_write_receipt:
                audit = [row for row in audit if not (row.get('event') == 'tool_result' and row.get('id') == 2)]
        if self.cleanup:
            audit.append({'event': 'relay_finished', 'child_reaped': True, 'cleanup_overrun': False})
        J.durable._new(run / 'mcp-audit.jsonl', b''.join(J.encode(row) + b'\n' for row in audit))
        J.durable._new(run / 'result.json', J.encode({'outcome': 'stored', 'summary': 'Synthetic result', 'memory_ids': [MEMORY]}))
        events = [{'type': 'thread.started', 'thread_id': 'synthetic'}, {'type': 'turn.started'}, *self.notices]
        for index, tool in ((1, 'recall'), (2, 'remember')):
            failed = tool == 'recall' and self.read_error
            item = {'id': 'item_' + str(index), 'type': 'mcp_tool_call', 'server': 'memory', 'tool': tool,
                'status': 'failed' if failed else 'completed', 'error': None,
                'result': {'content': [{'type': 'text', 'text': MEMORY if tool == 'remember' else 'Synthetic read'}]}}
            events.append({'type': 'item.completed', 'item': item})
        if self.failed_turn: events.append({'type': 'turn.failed', 'error': {'message': 'Synthetic terminal failure'}})
        if self.completed: events.append({'type': 'turn.completed', 'usage': {}})
        events.extend(self.after)
        kwargs['stdout'].write(b''.join(J.encode(row) + b'\n' for row in events) + (b'{' if self.partial else b''))
        kwargs['stdout'].flush()
        return FinishedProvider(self.code)

    def process(self):
        with R.lock_file(self.root / 'worker.lock'):
            return R.process_request(self.root, self.request, self.config, invoke=R.run_codex, provider_mode=None)

    def test_recovered_notices_publish_coverage_and_next_stop_learns_new_interval(self):
        self.assertEqual(self.process(), 'succeeded')
        first = self.runs[0]; first_state = json.loads(self.state_path.read_bytes())
        summary = json.loads((first / 'run.json').read_bytes())
        self.assertEqual(summary['provider_notices'], 2)
        self.assertFalse(summary['provider_error'])
        self.assertEqual(summary['tool_errors'], 0)
        self.assertTrue((first / 'successful-coverage.json').exists())
        self.assertFalse(R.requires_reconciliation(first_state))
        self.assertFalse(self.pending.exists())
        prior = {p.name: p.read_bytes() for p in first.iterdir() if p.is_file()}
        self.append('Synthetic second new visible fact.')
        self.request = {**self.request, 'request_id': 'second-request', 'turn_id': 'second-turn'}
        write(self.pending, self.request)
        self.notices = []
        self.assertEqual(self.process(), 'succeeded')
        self.assertEqual(len(self.runs), 2)
        self.assertEqual(len(set(self.applies)), 2)
        second_manifest, _ = J.read_manifest(self.runs[1])
        self.assertEqual(second_manifest['source']['start_offset'], first_state['offset'])
        self.assertEqual(second_manifest['source']['end_offset'], self.path.stat().st_size)
        self.assertEqual(prior, {p.name: p.read_bytes() for p in first.iterdir() if p.is_file()})
        self.assertFalse(R.requires_reconciliation(json.loads(self.state_path.read_bytes())))

    def test_terminal_failure_is_sticky_even_followed_by_completion(self):
        self.failed_turn = True
        self.assert_held(durable=True)

    def test_error_after_completion_remains_fatal(self):
        self.after = [{'type': 'error', 'message': 'Synthetic late failure'}]
        self.assert_held()

    def test_second_turn_cannot_relabel_a_notice_as_same_turn_recovery(self):
        self.notices.append({'type': 'turn.started'})
        self.assert_held()

    def test_duplicate_terminal_completion_remains_fatal(self):
        self.after = [{'type': 'turn.completed', 'usage': {}}]
        self.assert_held()

    def test_unexpected_provider_tool_remains_fatal(self):
        self.notices.append({'type': 'item.completed', 'item': {'type': 'command_execution'}})
        self.assert_held()

    def test_post_completion_mutation_frame_remains_fatal(self):
        self.after = [{'type': 'item.completed', 'item': {'id': 'late', 'type': 'mcp_tool_call',
            'server': 'memory', 'tool': 'remember', 'status': 'completed',
            'result': {'content': [{'type': 'text', 'text': MEMORY}]}}}]
        self.assert_held()

    def test_malformed_notice_remains_fatal(self):
        self.notices = [{'type': 'error', 'message': {'unexpected': 'object'}}]
        self.assert_held()

    def test_nonzero_exit_is_not_recovered_by_completed_event(self):
        self.code = 1
        self.assert_held()

    def test_no_terminal_completion_is_not_recovered_by_notice(self):
        self.completed = False
        self.assert_held()

    def test_partial_final_provider_frame_remains_fatal(self):
        self.partial = True
        self.assert_held()

    def test_failed_read_does_not_become_successful_coverage(self):
        self.read_error = True
        self.assert_held()

    def test_missing_cleanup_after_interrupt_remains_held(self):
        self.cleanup = False
        self.assert_held()

    def test_missing_independent_write_receipt_remains_held(self):
        self.missing_write_receipt = True
        self.assert_held()

    def assert_held(self, *, durable=False):
        if durable:
            self.assertEqual(self.process(), 'reconciliation_required')
            self.assertTrue(R.requires_reconciliation(json.loads(self.state_path.read_bytes())))
        else:
            # Ordering/stream negatives exercise the actual provider loop and
            # independent audit/result checks without repeating durable journals.
            run = self.root / 'runs' / 'negative-stream'; run.mkdir(mode=0o700, parents=True)
            excerpt = T.read_excerpt(self.path, self.frontier, stable_identity=True,
                                     max_chars=2000, max_scan_bytes=4096)
            result = R.run_codex(self.root, run, self.request, excerpt, self.config)
            self.assertEqual(result['status'], 'failed')
        state = json.loads(self.state_path.read_bytes())
        self.assertEqual(state['offset'], self.frontier)
        self.assertFalse((self.runs[0] / 'successful-coverage.json').exists())
        self.assertEqual(len(self.applies), 1)


if __name__ == '__main__': unittest.main()
