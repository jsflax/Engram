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
from durable_host_support import DurableHost

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
        self.durable = None

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
        self.durable.provider()
        return {'status': 'succeeded', 'write_calls': 0}

    def enable_durable(self):
        if self.durable is None:
            self.durable = DurableHost(self, F)
        self.durable.migrate()

    def process(self, sid):
        state = F.RUNNER.load_json(self.root / 'sessions' / (sid + '.json'))
        if not F.RUNNER.requires_reconciliation(state):
            self.enable_durable()
        return F.RUNNER.process_request(self.root, self.request(sid), F.RUNNER.settings(self.root), invoke=self.invoke)

    def paused_for_resume(self, n=1, *, durable=False):
        sid, path, payload = self.task(n)
        self.dispatch(payload, 'SessionStart')
        self.append(path, 'DURABLE RESUME CONTENT')
        self.assertTrue(self.dispatch(payload))
        if durable:
            self.enable_durable()
        request = self.request(sid)
        F.RUNNER.atomic_json(self.root / 'pending' / (sid + '.json'),
                            {**request, 'paused_request_id': request['request_id'], 'pause_reason': 'batch_limit'})
        return sid, path, payload

    def resume_records(self, sid):
        return {name: (self.root / name / (sid + '.json')).read_bytes()
                for name in ('enrollments', 'admissions', 'sessions', 'pending')}

    def test_resume_same_snapshot_keeps_request_and_cursor_then_processes_once(self):
        sid, path, payload = self.paused_for_resume(durable=True)
        before = self.resume_records(sid)
        paused = self.request(sid)
        with mock.patch.object(F.RUNNER, 'spawn_worker') as spawn:
            self.assertEqual(F.RUNNER.main(['retry', '--state-dir', str(self.root), '--session-id', sid]), 0)
            self.assertEqual(F.RUNNER.main(['retry', '--state-dir', str(self.root), '--session-id', sid]), 1)
        spawn.assert_called_once_with(self.root)
        expected = {k: v for k, v in paused.items() if k not in ('paused_request_id', 'pause_reason')}
        self.assertEqual(self.request(sid), expected)
        self.assertEqual({k: v for k, v in self.resume_records(sid).items() if k != 'pending'},
                         {k: v for k, v in before.items() if k != 'pending'})
        self.assertFalse(self.dispatch(payload))  # Ordinary hooks still deduplicate.
        original = F.RUNNER.process_request
        with mock.patch.object(F.RUNNER, 'process_request', side_effect=lambda r,q,c: original(r,q,c,invoke=self.invoke)), \
                mock.patch.object(F.RUNNER, 'spawn_worker', side_effect=F.forbidden):
            F.RUNNER.worker(self.root)
            F.RUNNER.worker(self.root)
        self.assertEqual(len(self.invocations), 1)
        self.assertEqual(self.invocations[0][0]['request_id'], paused['request_id'])
        self.assertIn('DURABLE RESUME CONTENT', self.invocations[0][1].text)
        self.assertFalse((self.root / 'pending' / (sid + '.json')).exists())

    def test_resume_preserves_concurrently_replaced_pending_or_cursor(self):
        for index, changed in enumerate(('pending', 'cursor'), start=1):
            with self.subTest(changed=changed):
                sid, path, payload = self.paused_for_resume(index)
                original_lock = F.RUNNER.lock_file
                captured = {}
                @contextlib.contextmanager
                def race(path_to_lock, *args, **kwargs):
                    if path_to_lock.name == 'worker.lock':
                        if changed == 'pending':
                            self.append(path, 'CONCURRENT NEW TURN', ordinal=12)
                            self.assertTrue(self.dispatch(payload, turn_id='turn-two'))
                        else:
                            state = F.RUNNER.load_json(self.root / 'sessions' / (sid + '.json'))
                            F.RUNNER.commit_admitted_state(self.root, self.request(sid),
                                                          {**state, 'status': 'no_visible_content'})
                        captured.update(self.resume_records(sid))
                    with original_lock(path_to_lock, *args, **kwargs) as acquired:
                        yield acquired
                with mock.patch.object(F.RUNNER, 'lock_file', side_effect=race), \
                        mock.patch.object(F.RUNNER, 'spawn_worker') as spawn:
                    self.assertFalse(F.RUNNER.resume_pending(self.root, sid))
                spawn.assert_not_called()
                self.assertEqual(self.resume_records(sid), captured)

    def test_resume_refuses_active_worker_processing_and_reconciliation(self):
        for index, hold in enumerate(('worker', 'processing', 'reconciliation', 'pause_only'), start=1):
            with self.subTest(hold=hold):
                sid, _, _ = self.paused_for_resume(index)
                if hold == 'processing':
                    record_path = self.root / 'admissions' / (sid + '.json')
                    record = F.RUNNER.load_json(record_path)
                    F.write_json(record_path, {**record, 'processing': self.request(sid)['request_id']})
                elif hold == 'reconciliation':
                    state = F.RUNNER.load_json(self.root / 'sessions' / (sid + '.json'))
                    F.RUNNER.commit_admitted_state(self.root, self.request(sid),
                        {**state, 'status': 'reconciliation_required',
                         'reconciliation_required': {'reason': 'write_status_unknown', 'memory_ids': []}})
                elif hold == 'pause_only':
                    F.write_json(self.root / 'pending' / (sid + '.json'),
                                 {**self.request(sid), 'pause_reason': 'reconciliation_required'})
                before = self.resume_records(sid)
                lock = F.RUNNER.lock_file(self.root / 'worker.lock') if hold == 'worker' else contextlib.nullcontext()
                with lock, mock.patch.object(F.RUNNER, 'spawn_worker') as spawn:
                    self.assertFalse(F.RUNNER.resume_pending(self.root, sid))
                spawn.assert_not_called()
                self.assertEqual(self.resume_records(sid), before)

    def test_resume_respects_backoff_and_disabled_policy(self):
        sid, _, _ = self.paused_for_resume()
        state = F.RUNNER.load_json(self.root / 'sessions' / (sid + '.json'))
        deadline = time.time() + 300
        F.RUNNER.commit_admitted_state(self.root, self.request(sid), {**state, 'retry_after': deadline})
        before = self.resume_records(sid)
        with mock.patch.object(F.RUNNER, 'spawn_worker') as spawn:
            self.assertFalse(F.RUNNER.resume_pending(self.root, sid))
            self.assertEqual(self.resume_records(sid), before)
            self.policy['enabled'] = False
            F.write_json(self.root / 'admission.json', self.policy)
            with mock.patch.object(F.RUNNER.time, 'time', return_value=deadline + 1):
                self.assertFalse(F.RUNNER.resume_pending(self.root, sid))
                self.assertEqual(self.resume_records(sid), before)
                self.policy['enabled'] = True
                F.write_json(self.root / 'admission.json', self.policy)
                self.assertTrue(F.RUNNER.resume_pending(self.root, sid))
            spawn.assert_called_once_with(self.root)

    def test_resume_rejects_replaced_or_truncated_transcript(self):
        for index, change in enumerate(('replace', 'truncate'), start=1):
            with self.subTest(change=change):
                sid, path, _ = self.paused_for_resume(index)
                if change == 'replace':
                    replacement = path.with_suffix('.replacement')
                    replacement.write_bytes(path.read_bytes())
                    replacement.replace(path)
                else:
                    path.write_bytes(path.read_bytes().splitlines(keepends=True)[0])
                before = self.resume_records(sid)
                with mock.patch.object(F.RUNNER, 'spawn_worker') as spawn:
                    self.assertFalse(F.RUNNER.resume_pending(self.root, sid))
                spawn.assert_not_called()
                self.assertEqual(self.resume_records(sid), before)

    def test_resume_rejects_invalid_backoff_partial_gate_and_cursor_hash_mismatch(self):
        for index, hold in enumerate(('backoff', 'status_only', 'gate_only', 'cursor_hash'), start=1):
            with self.subTest(hold=hold):
                sid, _, _ = self.paused_for_resume(index)
                state_path = self.root / 'sessions' / (sid + '.json')
                state = F.RUNNER.load_json(state_path)
                if hold == 'backoff':
                    state['retry_after'] = 'invalid'
                elif hold == 'status_only':
                    state['status'] = 'reconciliation_required'
                elif hold == 'gate_only':
                    state['reconciliation_required'] = {'reason': 'successful_or_unverified_write'}
                else:
                    state['offset'] += 1
                if hold == 'cursor_hash':
                    F.write_json(state_path, state)
                else:
                    F.RUNNER.commit_admitted_state(self.root, self.request(sid), state)
                before = self.resume_records(sid)
                with mock.patch.object(F.RUNNER, 'spawn_worker') as spawn:
                    self.assertFalse(F.RUNNER.resume_pending(self.root, sid))
                spawn.assert_not_called()
                self.assertEqual(self.resume_records(sid), before)

    def test_published_resume_still_wakes_worker_when_diagnostic_logging_fails(self):
        sid, _, _ = self.paused_for_resume()
        request = self.request(sid)
        with mock.patch.object(F.RUNNER, 'event_log', side_effect=OSError('synthetic log failure')), \
                mock.patch.object(F.RUNNER, 'spawn_worker') as spawn:
            with self.assertRaisesRegex(OSError, 'synthetic log failure'):
                F.RUNNER.resume_pending(self.root, sid)
        spawn.assert_called_once_with(self.root)
        self.assertEqual(self.request(sid), {k: v for k, v in request.items()
                                            if k not in ('paused_request_id', 'pause_reason')})

    def test_incomplete_reconciliation_gate_cannot_resume_enqueue_or_process(self):
        for index, gate in enumerate(({}, None, False, [], ''), start=1):
            with self.subTest(gate=gate):
                sid, path, payload = self.paused_for_resume(index)
                state = F.RUNNER.load_json(self.root / 'sessions' / (sid + '.json'))
                F.RUNNER.commit_admitted_state(self.root, self.request(sid),
                                              {**state, 'reconciliation_required': gate})
                before = self.resume_records(sid)
                with mock.patch.object(F.RUNNER, 'spawn_worker') as spawn, \
                        mock.patch.object(F.RUNNER, 'run_codex', side_effect=F.forbidden):
                    self.assertFalse(F.RUNNER.resume_pending(self.root, sid))
                    self.append(path, 'NEW CONTENT CANNOT CLEAR A HOLD', ordinal=12)
                    self.assertFalse(self.dispatch(payload, turn_id='later-turn'))
                    self.assertEqual(self.process(sid), 'reconciliation_required')
                spawn.assert_not_called()
                self.assertEqual(self.invocations, [])
                self.assertEqual(self.resume_records(sid), before)

    def test_resume_rejects_special_state_files_before_reading(self):
        for index, directory in enumerate(('pending', 'sessions'), start=1):
            with self.subTest(directory=directory):
                sid, _, _ = self.paused_for_resume(index)
                path = self.root / directory / (sid + '.json')
                path.unlink()
                os.mkfifo(path, 0o600)
                original = path.lstat()
                with mock.patch.object(F.RUNNER, 'load_pending', side_effect=F.forbidden), \
                        mock.patch.object(F.RUNNER, 'load_json', side_effect=F.forbidden), \
                        mock.patch.object(F.RUNNER, 'spawn_worker') as spawn:
                    self.assertFalse(F.RUNNER.resume_pending(self.root, sid))
                spawn.assert_not_called()
                self.assertEqual(path.lstat().st_ino, original.st_ino)
                self.assertEqual(path.lstat().st_mode, original.st_mode)

    def test_worker_keeps_latest_failure_after_earlier_successful_batch(self):
        for index, outcome in enumerate(('failed', 'backoff', 'blocked', 'reconciliation_required'), start=1):
            with self.subTest(outcome=outcome):
                sid, _, _ = self.paused_for_resume(index)
                pending_path = self.root / 'pending' / (sid + '.json')
                request = {k: v for k, v in self.request(sid).items() if k not in ('paused_request_id', 'pause_reason')}
                F.write_json(pending_path, request)
                F.write_json(self.root / 'settings.json', {'max_runs_per_worker': 2})
                with mock.patch.object(F.RUNNER, 'process_request', side_effect=['more', outcome]) as process, \
                        mock.patch.object(F.RUNNER, 'spawn_worker') as spawn:
                    F.RUNNER.worker(self.root)
                    F.RUNNER.worker(self.root)
                self.assertEqual(process.call_count, 2)
                self.assertEqual(self.request(sid)['pause_reason'], outcome)
                self.assertEqual(self.request(sid)['paused_request_id'], request['request_id'])
                spawn.assert_not_called()

    def test_worker_batch_limit_preserves_concurrent_pause_of_same_request(self):
        sid, _, _ = self.paused_for_resume()
        pending_path = self.root / 'pending' / (sid + '.json')
        request = {k: v for k, v in self.request(sid).items() if k not in ('paused_request_id', 'pause_reason')}
        F.write_json(pending_path, request)
        F.write_json(self.root / 'settings.json', {'max_runs_per_worker': 1})
        def process(root, current, config):
            F.write_json(pending_path, {**current, 'paused_request_id': current['request_id'],
                                       'pause_reason': 'reconciliation_required'})
            return 'more'
        with mock.patch.object(F.RUNNER, 'process_request', side_effect=process), \
                mock.patch.object(F.RUNNER, 'spawn_worker') as spawn:
            F.RUNNER.worker(self.root)
        self.assertEqual(self.request(sid)['pause_reason'], 'reconciliation_required')
        spawn.assert_not_called()

    def test_all_tasks_share_queue_and_preserve_current_model(self):
        tasks = [self.task(i, source='cli' if i % 2 else 'vscode') for i in range(1, 6)]
        for sid, path, payload in tasks:
            self.assertFalse(self.dispatch(payload, 'SessionStart'))
            self.append(path, 'Durable new fact for ' + sid)
            self.assertTrue(self.dispatch(payload))
            self.assertEqual(self.request(sid)['model'], 'fake-never-executed')
        self.enable_durable()
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

    def test_v1_admission_remains_inspectable_but_cannot_execute_before_migration(self):
        sid, path, payload = self.task()
        self.dispatch(payload, 'SessionStart')
        self.append(path, 'NEW CONTENT REQUIRES EXPLICIT MIGRATION')
        self.assertTrue(self.dispatch(payload))
        request = self.request(sid)
        before = self.resume_records(sid)
        self.assertEqual(F.ADMISSION.check(self.root, request), request['admission'])
        with self.assertRaisesRegex(ValueError, 'v2_required'):
            F.RUNNER.process_request(self.root, request, F.RUNNER.settings(self.root), invoke=self.invoke)
        self.assertEqual(self.resume_records(sid), before)
        self.assertEqual(self.invocations, [])

    def test_migrated_frontier_learns_only_new_intervals_and_resumes_exact_parser(self):
        sid, path, payload = self.task()
        self.append(path, 'OLD AMBER HISTORY')
        self.dispatch(payload, 'SessionStart')
        frontier = json.loads((self.root / 'enrollments' / (sid + '.json')).read_bytes())['frontier_offset']
        self.append(path, 'NEW COBALT FACT', ordinal=12)
        self.assertTrue(self.dispatch(payload))
        self.assertEqual(self.process(sid), 'succeeded')
        first = json.loads((self.root / 'sessions' / (sid + '.json')).read_bytes())
        self.assertGreater(first['offset'], frontier)
        self.assertIn('NEW COBALT', self.invocations[0][1].text)
        self.assertNotIn('OLD AMBER', self.invocations[0][1].text)
        self.append(path, 'NEXT JADE FACT', ordinal=13)
        self.assertTrue(self.dispatch(payload, turn_id='next-turn'))
        self.assertEqual(self.process(sid), 'succeeded')
        second = json.loads((self.root / 'sessions' / (sid + '.json')).read_bytes())
        self.assertGreater(second['offset'], first['offset'])
        self.assertIn('NEXT JADE', self.invocations[1][1].text)
        self.assertNotIn('NEW COBALT', self.invocations[1][1].text)
        self.assertNotIn('OLD AMBER', self.invocations[1][1].text)
        self.assertEqual(json.loads((self.root / 'enrollments' / (sid + '.json')).read_bytes())['frontier_offset'], frontier)

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
        self.enable_durable()
        original = F.RUNNER.process_request
        def fail(*args):
            self.durable.provider(success=False, missing_audit=True)
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
        self.enable_durable()
        before = self.request(sid)['admission']['frontier_offset']
        def failed(*args):
            self.durable.provider(success=False, missing_audit=True)
            return {'status': 'failed', 'write_calls': 1}
        result = F.RUNNER.process_request(self.root, self.request(sid), F.RUNNER.settings(self.root),
                                         invoke=failed)
        self.assertEqual(result, 'reconciliation_required')
        state = json.loads((self.root / 'sessions' / (sid + '.json')).read_text())
        self.assertEqual(state['offset'], before)
        self.assertEqual(state['status'], 'reconciliation_required')

    def test_policy_pause_while_waiting_never_seals_processing_and_resumes(self):
        sid, path, payload = self.task()
        self.dispatch(payload, 'SessionStart')
        self.append(path, 'DURABLE NEW TEXT')
        self.dispatch(payload)
        self.enable_durable()
        policy_raw = (self.root / 'admission.json').read_bytes()
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
        # Migration seals exact canonical policy bytes. Re-enabling the same
        # activation restores those bytes, rather than changing its formatting.
        (self.root / 'admission.json').write_bytes(policy_raw)
        self.assertEqual(self.process(sid), 'succeeded')
        self.assertEqual(len(self.invocations), 1)

    def failure_with_audit(self, rows, *, provider_started=True, typed_success=False):
        sid, path, payload = self.task()
        self.dispatch(payload, 'SessionStart')
        self.append(path, 'DURABLE NEW TEXT')
        self.dispatch(payload)
        self.enable_durable()
        def invoke(root, run_dir, request, excerpt, config):
            self.durable.provider(rows=rows, success=False, started=provider_started,
                                  typed_success=typed_success, missing_audit=rows is None)
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
            {'event': 'relay_finished', 'child_reaped': True, 'cleanup_overrun': False}], typed_success=True)
        self.assertEqual(result, 'reconciliation_required')
        gate = state['reconciliation_required']
        self.assertEqual(gate['reason'], 'unverified_completion')
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
        self.assertEqual(state['reconciliation_required']['reason'], 'unverified_completion')

    def test_legacy_no_write_conflict_prose_cannot_authorize_v2_retry(self):
        _, _, _, result, state = self.failure_with_audit([
            {'event': 'relay_started'}, {'event': 'tool_call', 'id': 1, 'tool': 'remember'},
            {'event': 'tool_result', 'id': 1, 'tool': 'remember', 'ok': True,
             'forwarded': True, 'memory_ids': [], 'write_outcome': 'not_stored_near_duplicate'}])
        self.assertEqual(result, 'reconciliation_required')
        self.assertEqual(state['reconciliation_required']['memory_ids'], [])

    def test_confirmed_prelaunch_failure_resumes_after_backoff_without_a_new_hook(self):
        sid, _, payload, result, state = self.failure_with_audit(None, provider_started=False)
        self.assertEqual(result, 'failed')
        original = F.RUNNER.process_request
        with mock.patch.object(F.RUNNER, 'run_codex', side_effect=F.forbidden), \
                mock.patch.object(F.RUNNER, 'spawn_worker', side_effect=F.forbidden):
            F.RUNNER.worker(self.root)
        self.assertEqual(self.request(sid)['pause_reason'], 'failed')
        before = self.resume_records(sid)
        with mock.patch.object(F.RUNNER, 'spawn_worker') as spawn:
            self.assertFalse(F.RUNNER.resume_pending(self.root, sid))
            self.assertEqual(self.resume_records(sid), before)
            with mock.patch.object(F.RUNNER.time, 'time', return_value=state['retry_after'] + 1):
                self.assertTrue(F.RUNNER.resume_pending(self.root, sid))
            spawn.assert_called_once_with(self.root)
        self.assertFalse(self.dispatch(payload))
        with mock.patch.object(F.RUNNER.time, 'time', return_value=state['retry_after'] + 1), \
                mock.patch.object(F.RUNNER, 'process_request', side_effect=lambda r,q,c: original(r,q,c,invoke=self.invoke)), \
                mock.patch.object(F.RUNNER, 'spawn_worker', side_effect=F.forbidden):
            F.RUNNER.worker(self.root)
            F.RUNNER.worker(self.root)
        self.assertEqual(len(self.invocations), 1)
        self.assertEqual(self.invocations[0][0]['request_id'], json.loads(before['pending'])['request_id'])
        self.assertIn('DURABLE NEW TEXT', self.invocations[0][1].text)
        self.assertEqual((self.root / 'enrollments' / (sid + '.json')).read_bytes(), before['enrollments'])
        self.assertFalse((self.root / 'pending' / (sid + '.json')).exists())

    def test_legacy_begin_busy_claim_keeps_cursor_held_after_later_event(self):
        sid, path, payload, result, state = self.failure_with_audit([
            {'event': 'relay_started'}, {'event': 'tool_call', 'id': 1, 'tool': 'remember'},
            {'event': 'tool_result', 'id': 1, 'tool': 'remember', 'ok': False,
             'forwarded': True, 'memory_ids': [], 'write_outcome': 'not_stored_transaction_not_started',
             'write_outcome_version': 1},
            {'event': 'relay_finished', 'child_reaped': True, 'cleanup_overrun': False}])
        self.assertEqual(result, 'reconciliation_required')
        self.assertEqual(state['reconciliation_required']['memory_ids'], [])
        self.assertEqual(state['offset'], self.request(sid)['admission']['frontier_offset'])
        self.assertGreater(state['retry_after'], time.time())
        original = F.RUNNER.process_request
        def process(root, request, config):
            return original(root, request, config, invoke=self.invoke)
        with mock.patch.object(F.RUNNER, 'process_request', side_effect=process), \
                mock.patch.object(F.RUNNER, 'spawn_worker', side_effect=F.forbidden):
            F.RUNNER.worker(self.root)  # Respect backoff without another provider.
            paused = self.request(sid)
            self.assertEqual(paused['paused_request_id'], paused['request_id'])
            self.assertEqual(self.invocations, [])
            with mock.patch.object(F.RUNNER.time, 'time', return_value=state['retry_after'] + 1):
                F.RUNNER.worker(self.root)  # Elapsed time alone does not replay.
                self.assertEqual(self.invocations, [])
                self.append(path, 'NEXT NATURAL TURN')
                self.assertFalse(self.dispatch(payload, turn_id='next-turn'))
                with mock.patch.object(F.RUNNER, 'spawn_worker') as spawn:
                    self.assertFalse(F.RUNNER.resume_pending(self.root, sid))
                    spawn.assert_not_called()
                F.RUNNER.worker(self.root)
        self.assertEqual(self.invocations, [])
        recovered = json.loads((self.root / 'sessions' / (sid + '.json')).read_text())
        self.assertEqual(recovered, state)
        self.assertEqual(self.request(sid)['pause_reason'], 'reconciliation_required')

    def test_unrecognized_forwarded_no_ids_response_stays_held(self):
        _, _, _, result, state = self.failure_with_audit([
            {'event': 'relay_started'}, {'event': 'tool_call', 'id': 1, 'tool': 'remember'},
            {'event': 'tool_result', 'id': 1, 'tool': 'remember', 'ok': True,
             'forwarded': True, 'memory_ids': []}])
        self.assertEqual(result, 'reconciliation_required')
        self.assertEqual(state['reconciliation_required']['reason'], 'unverified_completion')

    def test_conflict_plus_successful_write_failure_stays_held(self):
        memory_id = '11111111-2222-4333-8444-555555555555'
        _, _, _, result, state = self.failure_with_audit([
            {'event': 'relay_started'}, {'event': 'tool_call', 'id': 1, 'tool': 'remember'},
            {'event': 'tool_result', 'id': 1, 'tool': 'remember', 'ok': True,
             'forwarded': True, 'memory_ids': [], 'write_outcome': 'not_stored_near_duplicate'},
            {'event': 'tool_call', 'id': 2, 'tool': 'remember'},
            {'event': 'tool_result', 'id': 2, 'tool': 'remember', 'ok': True,
             'forwarded': True, 'memory_ids': [memory_id]}], typed_success=True)
        self.assertEqual(result, 'reconciliation_required')
        self.assertEqual(state['reconciliation_required']['memory_ids'], [memory_id])

    def test_missing_audit_after_provider_start_is_unknown_write_status(self):
        _, _, _, result, state = self.failure_with_audit(None)
        self.assertEqual(result, 'reconciliation_required')
        self.assertEqual(state['reconciliation_required']['reason'], 'unverified_completion')

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
        self.enable_durable()
        entered = threading.Event(); completed = threading.Event(); errors = []
        def invoke(*args):
            entered.set()
            self.durable.provider()
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
        self.assertTrue(completed.wait(15)); thread.join(timeout=1)
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
