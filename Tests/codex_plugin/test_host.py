"""Host admission and lifecycle integration; providers are explicit in-process fakes."""
import contextlib
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest

from suite_support import PLUGIN_ROOT, REPOSITORY_ROOT, TEMP_ROOT
from unittest import mock
import uuid

import test_frontier as F

ROUTER = None
HOST = None


def setUpModule():
    global ROUTER, HOST
    F.setUpModule()
    sys.modules['codex_learner'] = sys.modules[F.PACKAGE]
    sys.modules['codex_learner.runner'] = F.RUNNER
    sys.modules['codex_learner.admission'] = F.ADMISSION
    path = F.SOURCE.parent / 'learner_router.py'
    spec = importlib.util.spec_from_file_location('_host_router', path)
    ROUTER = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ROUTER)
    HOST = ROUTER.host_admission


def tearDownModule():
    for name in list(sys.modules):
        if name == 'codex_learner' or name.startswith('codex_learner.'):
            del sys.modules[name]
    F.tearDownModule()


class HostTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name).resolve()
        self.root = F.private_directory(self.base / 'state')
        self.home = F.private_directory(self.base / 'codex')
        self.sessions = F.private_directory(self.home / 'sessions')
        self.project = F.private_directory(self.base / 'project')
        self.policy = {'schema_version': 1, 'mode': 'host_sessions_v1', 'enabled': True,
                       'activation_id': str(uuid.uuid4()), 'cutoff': '2026-01-01T00:00:00Z',
                       'state_dir': str(self.root), 'sessions_dir': F.Fixture.binding(self.sessions)}
        F.write_json(self.root / 'admission.json', self.policy)
        self.routes = self.base / 'routes.json'
        F.write_json(self.routes, {'schema_version': 1, 'mode': 'host_sessions_v1',
                                  'enabled': True, 'state_dir': str(self.root)})
        F.write_json(self.root / 'settings.json', {'min_chars': 1, 'max_runs_per_worker': 8})
        env = mock.patch.dict(os.environ, {'CODEX_HOME': str(self.home)})
        env.start(); self.addCleanup(env.stop)
        self.invocations = []

    def task(self, n=1, *, source='vscode', version='future-codex-version', parent=None, created='2026-01-02T00:00:00Z'):
        sid = F.uuid7('2026-01-02T00:00:00Z', suffix=n)
        folder = F.private_directory(self.sessions / '2026/01/02')
        path = folder / ('rollout-2026-01-02T00-00-00-' + sid + '.jsonl')
        meta = {'id': sid, 'timestamp': created, 'cwd': str(self.project), 'source': source,
                'cli_version': version, 'history_mode': 'paginated'}
        if parent:
            meta.update(session_id=parent, subagent_history_start_ordinal=10,
                        source={'subagent': {'thread_spawn': {'parent_thread_id': parent}}})
        path.write_text(json.dumps({'type': 'session_meta', 'ordinal': 0, 'payload': meta}) + '\n')
        payload = {'session_id': parent or sid, 'agent_id': sid if parent else None,
                   'transcript_path': str(path), 'cwd': str(self.project),
                   'turn_id': 'turn-one', 'model': 'fake-never-executed'}
        return sid, path, payload

    def append(self, path, text, ordinal=11):
        with path.open('a') as stream:
            stream.write(json.dumps({'type': 'response_item', 'ordinal': ordinal,
                                    'payload': {'type': 'message', 'role': 'user',
                                                'content': [{'type': 'input_text', 'text': text}]}}) + '\n')

    def dispatch(self, payload, event='Stop', **values):
        return ROUTER.dispatch(self.routes, {**payload, 'hook_event_name': event, **values}, spawn=False)

    def receipt(self):
        return json.loads((self.base / 'router-receipts.jsonl').read_text().splitlines()[-1])

    def request(self, sid):
        return json.loads((self.root / 'pending' / (sid + '.json')).read_text())

    def invoke(self, root, run_dir, request, excerpt, config):
        self.invocations.append((request, excerpt))
        return {'status': 'succeeded', 'write_calls': 0}

    def process(self, sid):
        return F.RUNNER.process_request(self.root, self.request(sid), F.RUNNER.settings(self.root), invoke=self.invoke)

    def test_all_tasks_share_queue_and_preserve_current_model(self):
        tasks = [self.task(i, source='cli' if i % 2 else 'vscode') for i in range(1, 6)]
        for sid, path, payload in tasks:
            self.assertFalse(self.dispatch(payload, 'SessionStart'))
            self.append(path, 'Durable new fact for ' + sid)
            self.assertTrue(self.dispatch(payload))
            self.assertEqual(self.request(sid)['model'], 'fake-never-executed')
        original = F.RUNNER.process_request
        with mock.patch.object(F.RUNNER, 'process_request', side_effect=lambda r,q,c: original(r,q,c,invoke=self.invoke)), mock.patch.object(F.RUNNER, 'spawn_worker') as spawn:
            F.RUNNER.worker(self.root)
        self.assertEqual(len(self.invocations), 5)
        spawn.assert_not_called()
        self.assertEqual(len({q['session_id'] for q,e in self.invocations}), 5)

    def test_first_stop_baselines_eof_and_never_imports_old_history(self):
        sid, path, payload = self.task()
        self.append(path, 'OLD HISTORICAL FACT')
        old_size = path.stat().st_size
        self.assertFalse(self.dispatch(payload))
        self.assertEqual(self.receipt()['status'], 'enrolled')
        self.append(path, 'NEW FACT AFTER ACTIVATION')
        self.assertTrue(self.dispatch(payload, turn_id='turn-two'))
        self.assertEqual(self.request(sid)['admission']['frontier_offset'], old_size)
        self.assertEqual(self.process(sid), 'succeeded')
        self.assertIn('NEW FACT', self.invocations[0][1].text)
        self.assertNotIn('OLD HISTORICAL', self.invocations[0][1].text)

    def test_resume_does_not_recapture_or_skip_new_text(self):
        sid, path, payload = self.task()
        self.dispatch(payload, 'SessionStart')
        original = (self.root / 'enrollments' / (sid + '.json')).read_bytes()
        self.append(path, 'NEW CONTENT')
        self.dispatch(payload, 'SessionStart')
        self.assertEqual(original, (self.root / 'enrollments' / (sid + '.json')).read_bytes())
        self.assertTrue(self.dispatch(payload))
        self.assertEqual(self.process(sid), 'succeeded')

    def test_precompact_preserves_cause_and_does_not_need_turn_id(self):
        sid, path, payload = self.task()
        self.dispatch(payload, 'UserPromptSubmit')
        self.append(path, 'BEFORE COMPACTION')
        self.assertTrue(self.dispatch(payload, 'PreCompact', trigger='auto', turn_id=None))
        request = self.request(sid)
        self.assertEqual((request['event'], request['trigger']), ('PreCompact', 'auto'))
        self.assertEqual(self.process(sid), 'succeeded')
        self.assertEqual(self.invocations[0][0]['event'], 'PreCompact')

    def test_stop_coalescing_preserves_automatic_precompact_trigger(self):
        sid, path, payload = self.task()
        self.dispatch(payload, 'SessionStart')
        self.append(path, 'DURABLE CONTENT BEFORE COMPACTION')
        self.assertTrue(self.dispatch(payload, 'PreCompact', trigger='auto'))
        self.assertTrue(self.dispatch(payload, 'Stop'))
        request = self.request(sid)
        self.assertEqual((request['event'], request['trigger']), ('PreCompact', 'auto'))
        self.assertEqual(self.process(sid), 'succeeded')
        self.assertEqual(self.invocations[0][0]['trigger'], 'auto')

    def test_existing_retry_cli_refuses_same_snapshot_without_replaying_failure(self):
        sid, path, payload = self.task()
        self.dispatch(payload, 'SessionStart')
        self.append(path, 'DURABLE CONTENT')
        self.assertTrue(self.dispatch(payload))
        original = F.RUNNER.process_request
        def fail(*args):
            return {'status': 'failed', 'write_calls': 1}
        with mock.patch.object(F.RUNNER, 'process_request', side_effect=lambda r,q,c: original(r,q,c,invoke=fail)), mock.patch.object(F.RUNNER, 'spawn_worker'):
            F.RUNNER.worker(self.root)
        pending = self.root / 'pending' / (sid + '.json')
        state = self.root / 'sessions' / (sid + '.json')
        before = pending.read_bytes(), state.read_bytes()
        self.assertEqual(json.loads(before[0])['pause_reason'], 'reconciliation_required')
        with mock.patch.object(F.RUNNER, 'spawn_worker') as spawn:
            self.assertEqual(F.RUNNER.main(['retry', '--state-dir', str(self.root), '--session-id', sid]), 1)
        spawn.assert_not_called()
        self.assertEqual((pending.read_bytes(), state.read_bytes()), before)

    def test_manual_compaction_and_session_end_do_not_launch(self):
        sid, path, payload = self.task()
        self.dispatch(payload, 'SessionStart')
        self.append(path, 'SOME TEXT')
        self.assertFalse(self.dispatch(payload, 'PreCompact', trigger='manual'))
        self.assertFalse(self.dispatch(payload, 'SessionEnd'))
        self.assertEqual(self.receipt()['reason'], 'session_end_cleanup_only')
        self.assertFalse((self.root / 'pending' / (sid + '.json')).exists())

    def test_recursion_and_orchestrated_guards_do_not_enroll(self):
        sid, path, payload = self.task()
        for name in ('ENGRAM_CODEX_LEARNER', 'CLAUDE_MEMORY_LEARNER', 'ENGRAM_LEARNER_ORCHESTRATED'):
            with self.subTest(name=name), mock.patch.dict(os.environ, {name: '1'}):
                self.assertFalse(self.dispatch(payload, 'SessionStart'))
                self.assertEqual(self.receipt()['reason'], 'learner_recursion_guard')
        self.assertFalse((self.root / 'enrollments').exists())

    def test_disabled_policy_and_origin_mutation_fail_closed(self):
        sid, path, payload = self.task()
        self.dispatch(payload, 'SessionStart')
        self.append(path, 'SOME TEXT')
        self.policy['enabled'] = False
        F.write_json(self.root / 'admission.json', self.policy)
        self.assertFalse(self.dispatch(payload))
        self.assertEqual(self.receipt()['reason'], 'admission_inactive')
        self.policy['enabled'] = True
        F.write_json(self.root / 'admission.json', self.policy)
        path.write_text(path.read_text().replace('future-codex-version', 'different-codex-version'))
        self.assertFalse(self.dispatch(payload))
        self.assertEqual(self.receipt()['reason'], 'admission_enrollment_origin_changed')

    def test_missing_enrollment_never_adopts_old_cursor(self):
        sid, path, payload = self.task()
        self.dispatch(payload, 'SessionStart')
        self.append(path, 'SOME TEXT')
        self.assertTrue(self.dispatch(payload))
        (self.root / 'enrollments' / (sid + '.json')).unlink()
        self.assertFalse(self.dispatch(payload, 'SessionStart'))
        self.assertEqual(self.receipt()['reason'], 'admission_unowned_existing_state')

    def test_fresh_child_stop_only_learns_child_ordinals(self):
        parent = F.uuid7('2026-01-02T00:00:00Z', suffix=100)
        sid, path, payload = self.task(parent=parent)
        self.append(path, 'INHERITED PARENT CONTENT', ordinal=3)
        self.append(path, 'NEW CHILD CONTENT', ordinal=11)
        # Subagent hooks may carry a parent transcript_path and an explicit child path.
        self.assertTrue(self.dispatch({**payload, 'transcript_path': '/unused-parent-path'}, 'SubagentStop',
                                      agent_transcript_path=str(path), turn_id=None))
        self.assertEqual(self.request(sid)['event'], 'SubagentStop')
        self.assertEqual(self.process(sid), 'succeeded')
        text = self.invocations[0][1].text
        self.assertIn('NEW CHILD CONTENT', text)
        self.assertNotIn('INHERITED PARENT', text)
        self.assertEqual(self.invocations[0][0]['session_id'], sid)

    def test_old_child_baselines_instead_of_replaying(self):
        self.policy['cutoff'] = '2026-01-03T00:00:00Z'
        F.write_json(self.root / 'admission.json', self.policy)
        parent = F.uuid7('2026-01-02T00:00:00Z', suffix=100)
        sid, path, payload = self.task(parent=parent)
        self.append(path, 'OLD CHILD CONTENT')
        self.assertFalse(self.dispatch(payload, 'SubagentStop'))
        self.assertFalse((self.root / 'pending' / (sid + '.json')).exists())

    def test_unknown_child_boundary_is_rejected(self):
        parent = F.uuid7('2026-01-02T00:00:00Z', suffix=100)
        sid, path, payload = self.task(parent=parent)
        record = json.loads(path.read_text())
        del record['payload']['subagent_history_start_ordinal']
        path.write_text(json.dumps(record) + '\n')
        self.assertFalse(self.dispatch(payload, 'SubagentStop'))
        self.assertEqual(self.receipt()['reason'], 'admission_unknown_inherited_boundary')

    def test_failed_provider_keeps_cursor_and_does_not_claim_success(self):
        sid, path, payload = self.task()
        self.dispatch(payload, 'SessionStart')
        self.append(path, 'DURABLE NEW TEXT')
        self.dispatch(payload)
        before = self.request(sid)['admission']['frontier_offset']
        result = F.RUNNER.process_request(self.root, self.request(sid), F.RUNNER.settings(self.root),
                                         invoke=lambda *args: {'status': 'failed', 'write_calls': 1})
        self.assertEqual(result, 'reconciliation_required')
        state = json.loads((self.root / 'sessions' / (sid + '.json')).read_text())
        self.assertEqual(state['offset'], before)
        self.assertEqual(state['status'], 'reconciliation_required')

    def test_policy_pause_while_waiting_never_seals_processing_and_resumes(self):
        sid, path, payload = self.task()
        self.dispatch(payload, 'SessionStart')
        self.append(path, 'DURABLE NEW TEXT')
        self.dispatch(payload)
        original = F.RUNNER.provider_slot
        @contextlib.contextmanager
        def pause_before_yield():
            with original():
                self.policy['enabled'] = False
                F.write_json(self.root / 'admission.json', self.policy)
                yield
        with mock.patch.object(F.RUNNER, 'provider_slot', pause_before_yield):
            with self.assertRaisesRegex(ValueError, 'admission_inactive'):
                self.process(sid)
        record = json.loads((self.root / 'admissions' / (sid + '.json')).read_text())
        self.assertIsNone(record['processing'])
        self.assertEqual(self.invocations, [])
        self.policy['enabled'] = True
        F.write_json(self.root / 'admission.json', self.policy)
        self.assertEqual(self.process(sid), 'succeeded')
        self.assertEqual(len(self.invocations), 1)

    def failure_with_audit(self, rows, *, provider_started=True):
        sid, path, payload = self.task()
        self.dispatch(payload, 'SessionStart')
        self.append(path, 'DURABLE NEW TEXT')
        self.dispatch(payload)
        def invoke(root, run_dir, request, excerpt, config):
            F.RUNNER._PROVIDER_STARTED.set(provider_started)
            if rows is not None:
                (run_dir / 'mcp-audit.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in rows))
            return {'status': 'failed', 'write_calls': 0, 'reason': 'synthetic_failure'}
        result = F.RUNNER.process_request(self.root, self.request(sid), F.RUNNER.settings(self.root), invoke=invoke)
        state = json.loads((self.root / 'sessions' / (sid + '.json')).read_text())
        return sid, path, payload, result, state

    def test_successful_write_then_failed_turn_requires_reconciliation_and_blocks_new_events(self):
        memory_id = '11111111-2222-4333-8444-555555555555'
        sid, path, payload, result, state = self.failure_with_audit([
            {'event': 'relay_started'},
            {'event': 'tool_call', 'id': 1, 'tool': 'remember'},
            {'event': 'tool_result', 'id': 1, 'tool': 'remember', 'ok': True, 'forwarded': True, 'memory_ids': [memory_id]},
            {'event': 'relay_finished', 'child_reaped': True, 'cleanup_overrun': False}])
        self.assertEqual(result, 'reconciliation_required')
        gate = state['reconciliation_required']
        self.assertEqual(gate['reason'], 'successful_or_unverified_write')
        self.assertEqual(gate['memory_ids'], [memory_id])
        pending = self.root / 'pending' / (sid + '.json')
        before = pending.read_bytes()
        self.append(path, 'NEXT NATURAL TURN')
        self.assertFalse(self.dispatch(payload, turn_id='next-turn'))
        self.assertEqual(pending.read_bytes(), before)
        with mock.patch.object(F.RUNNER, 'run_codex', side_effect=AssertionError('provider must stay paused')):
            self.assertEqual(self.process(sid), 'reconciliation_required')

    def test_unsettled_forwarded_write_requires_reconciliation(self):
        _, _, _, result, state = self.failure_with_audit([
            {'event': 'relay_started'}, {'event': 'tool_call', 'id': 1, 'tool': 'remember'}])
        self.assertEqual(result, 'reconciliation_required')
        self.assertEqual(state['reconciliation_required']['reason'], 'successful_or_unverified_write')

    def test_known_no_write_conflict_failure_keeps_retry_without_reconciliation(self):
        _, _, _, result, state = self.failure_with_audit([
            {'event': 'relay_started'}, {'event': 'tool_call', 'id': 1, 'tool': 'remember'},
            {'event': 'tool_result', 'id': 1, 'tool': 'remember', 'ok': True,
             'forwarded': True, 'memory_ids': [], 'write_outcome': 'not_stored_near_duplicate'}])
        self.assertEqual(result, 'failed')
        self.assertNotIn('reconciliation_required', state)

    def test_unrecognized_forwarded_no_ids_response_stays_held(self):
        _, _, _, result, state = self.failure_with_audit([
            {'event': 'relay_started'}, {'event': 'tool_call', 'id': 1, 'tool': 'remember'},
            {'event': 'tool_result', 'id': 1, 'tool': 'remember', 'ok': True,
             'forwarded': True, 'memory_ids': []}])
        self.assertEqual(result, 'reconciliation_required')
        self.assertEqual(state['reconciliation_required']['reason'], 'successful_or_unverified_write')

    def test_conflict_plus_successful_write_failure_stays_held(self):
        memory_id = '11111111-2222-4333-8444-555555555555'
        _, _, _, result, state = self.failure_with_audit([
            {'event': 'relay_started'}, {'event': 'tool_call', 'id': 1, 'tool': 'remember'},
            {'event': 'tool_result', 'id': 1, 'tool': 'remember', 'ok': True,
             'forwarded': True, 'memory_ids': [], 'write_outcome': 'not_stored_near_duplicate'},
            {'event': 'tool_call', 'id': 2, 'tool': 'remember'},
            {'event': 'tool_result', 'id': 2, 'tool': 'remember', 'ok': True,
             'forwarded': True, 'memory_ids': [memory_id]}])
        self.assertEqual(result, 'reconciliation_required')
        self.assertEqual(state['reconciliation_required']['memory_ids'], [memory_id])

    def test_missing_audit_after_provider_start_is_unknown_write_status(self):
        _, _, _, result, state = self.failure_with_audit(None)
        self.assertEqual(result, 'reconciliation_required')
        self.assertEqual(state['reconciliation_required']['reason'], 'write_status_unknown')

    def test_prelaunch_failure_has_no_reconciliation_gate(self):
        _, _, _, result, state = self.failure_with_audit(None, provider_started=False)
        self.assertEqual(result, 'failed')
        self.assertNotIn('reconciliation_required', state)

    def test_read_only_provider_failure_keeps_normal_backoff_without_gate(self):
        _, _, _, result, state = self.failure_with_audit([
            {'event': 'relay_started'}, {'event': 'tool_call', 'id': 1, 'tool': 'recall'},
            {'event': 'tool_result', 'id': 1, 'tool': 'recall', 'ok': False, 'forwarded': True, 'memory_ids': []}])
        self.assertEqual(result, 'failed')
        self.assertNotIn('reconciliation_required', state)

    def test_proven_proxy_denial_before_forwarding_needs_no_reconciliation(self):
        _, _, _, result, state = self.failure_with_audit([
            {'event': 'relay_started'}, {'event': 'tool_call', 'id': 1, 'tool': 'remember'},
            {'event': 'tool_result', 'id': 1, 'tool': 'remember', 'ok': False, 'forwarded': False, 'memory_ids': []}])
        self.assertEqual(result, 'failed')
        self.assertNotIn('reconciliation_required', state)

    def test_provider_lock_blocks_overlapping_provider_across_roots(self):
        sid, path, payload = self.task()
        self.dispatch(payload, 'SessionStart')
        self.append(path, 'DURABLE TEXT')
        self.dispatch(payload)
        entered = threading.Event(); completed = threading.Event(); errors = []
        def invoke(*args):
            entered.set()
            return {'status': 'succeeded', 'write_calls': 0}
        def run():
            try:
                F.RUNNER.process_request(self.root, self.request(sid), F.RUNNER.settings(self.root), invoke=invoke)
            except BaseException as error:
                errors.append(error)
            finally:
                completed.set()
        with F.RUNNER.lock_file(self.home / 'engram' / 'learner-provider.lock'):
            thread = threading.Thread(target=run); thread.start()
            self.assertFalse(entered.wait(0.1))
        self.assertTrue(completed.wait(2)); thread.join()
        self.assertEqual(errors, [])
        self.assertTrue(entered.is_set())

    def test_bundled_cli_precedes_stale_path_without_model_override(self):
        (self.home / 'config.toml').write_text('model="configured-current-model"\n[mcp_servers.memory]\ncommand="/never-executed/memory"\ndefault_tools_approval_mode="approve"\n')
        run = F.private_directory(self.base / 'run')
        preferred = '/Applications/ChatGPT.app/Contents/Resources/codex'
        real_is_file = Path.is_file
        with mock.patch.object(Path, 'is_file', lambda path: str(path) == preferred or real_is_file(path)), mock.patch.object(F.RUNNER.os, 'access', return_value=True), mock.patch.object(F.RUNNER.shutil, 'which', return_value='/stale/path/codex') as which:
            command = F.RUNNER.learner_command(self.root, run, {'session_id': 'synthetic'}, F.RUNNER.settings(self.root))
        self.assertEqual(command[0], preferred)
        self.assertEqual(command[command.index('--model') + 1], 'configured-current-model')
        which.assert_not_called()

    def test_explicit_codex_binary_selection_remains_authoritative(self):
        (self.home / 'config.toml').write_text('[mcp_servers.memory]\ncommand="/never-executed/memory"\ndefault_tools_approval_mode="approve"\n')
        run = F.private_directory(self.base / 'run')
        config = {**F.RUNNER.settings(self.root), 'codex_bin': '/explicit/selected/codex'}
        command = F.RUNNER.learner_command(self.root, run, {'session_id': 'synthetic'}, config)
        self.assertEqual(command[0], '/explicit/selected/codex')
        self.assertNotIn('--model', command)

    def test_lock_symlink_is_rejected(self):
        target = self.base / 'target'; target.write_text('UNCHANGED')
        link = self.base / 'lock'; link.symlink_to(target)
        with self.assertRaises(OSError), F.RUNNER.lock_file(link):
            pass
        self.assertEqual(target.read_text(), 'UNCHANGED')


if __name__ == '__main__':
    unittest.main()
