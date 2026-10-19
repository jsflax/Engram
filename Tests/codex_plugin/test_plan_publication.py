"""Normal worker continuation with a synthetic native ledger, no live stores."""
import copy
import datetime
import json
import shutil
from pathlib import Path
import threading
import unittest
from types import SimpleNamespace
from unittest import mock

import test_runner_reconnect as fixtures
from codex_learner import learner_plan as L, native_executor as N
from codex_learner import writer_fence as F

R, P, J, SID = fixtures.R, fixtures.P, fixtures.J, fixtures.SID


class PlanPublicationTests(unittest.TestCase):
    def setUp(self):
        self.f = fixtures.RunnerReconnectTests(methodName='runTest')
        self.addCleanup(self.f.doCleanups)
        self.f.setUp()
        self.provider_runs, self.calls, self.ledger = [], [], {}
        self.failed = False
        self.patch = mock.patch.object(N, 'executor', return_value=self.apply)
        self.factory = self.patch.start()
        self.addCleanup(self.patch.stop)

    def planning(self, root, run_dir, request, excerpt, config):
        self.provider_runs.append(run_dir)
        execution = R._EXECUTION.get()
        manifest, digest = J.read_manifest(run_dir)
        self.assertEqual(manifest['provider_mode'], L.MODE)
        P.settlement.record_provider_dispatch(run_dir, digest,
            lambda value, phase: execution.context.validate_inputs(value, 'before_intent'))
        if not self.failed:
            audit = [{'event': 'relay_started'}, {'event': 'tool_call', 'id': 1, 'tool': 'recall'},
                {'event': 'tool_result', 'id': 1, 'tool': 'recall', 'ok': True,
                 'forwarded': True, 'memory_ids': []},
                {'event': 'relay_finished', 'child_reaped': True, 'cleanup_overrun': False}]
            J.durable._new(run_dir / 'mcp-audit.jsonl', b''.join(J.encode(row) + b'\n' for row in audit))
            proposal = {'schema_version': 1, 'outcome': 'proposed', 'summary': 'Synthetic complete plan',
                'operations': [{'key': f'op_{i}', 'tool': 'remember',
                    'arguments': {'content': f'Synthetic fact {i}', 'is_private': i == 2}} for i in (1, 2)]}
            J.durable._new(run_dir / 'proposal.json', J.encode(proposal))
        P.settlement.persist_observation(run_dir, {'started': True, 'terminated': True,
            'returncode': 1 if self.failed else 0, 'turn_completed': not self.failed,
            'provider_error': self.failed, 'unexpected_tool': False, 'tool_errors': 0,
            'reason': 'provider_failed' if self.failed else None})
        return {'status': 'failed' if self.failed else 'planned', 'write_calls': 0}

    def process(self):
        with R.lock_file(self.f.root / 'worker.lock'):
            return R.process_request(self.f.root, self.f.request, self.f.config, invoke=self.planning)

    def apply(self, raw, writer, check):
        check('before_native_forward')
        request = J._json(raw)
        operation = request['operationID']
        self.calls.append((operation, raw))
        if operation not in self.ledger:
            memory = 'a1111111-2222-4333-8444-' + f'{len(self.ledger)+1:012d}'
            self.ledger[operation] = {'version': 1, 'operationID': operation, 'scope': self.f.scope,
                'payloadDigest': 'd' * 64, 'mutation': 'remember', 'outcome': 'applied',
                'memoryIDs': [memory], 'edgeIDs': [], 'committedAt': 800000000.25}
            if len(self.ledger) == 2:
                # The real native ledger committed, but the transport lost its
                # acknowledgement. The retry must address this SAME operation.
                raise TimeoutError('synthetic lost acknowledgement')
        outer = {'engram_operation': {'version': 1, 'kind': 'committed', 'receipt': self.ledger[operation]}}
        return {'jsonrpc': '2.0', 'id': operation, 'result': {'isError': False,
            'structuredContent': outer, 'content': [{'type': 'text', 'text': J.encode(outer).decode()}]}}

    def test_partial_commit_resumes_without_provider_replay_or_enqueue_lock(self):
        old_state = self.f.state_path.read_bytes()
        outcome = self.process()
        self.assertEqual(self.factory.call_args.kwargs['limits'].deadline_seconds, 30.0)
        self.assertTrue(callable(self.factory.call_args.kwargs['diagnostic']))
        self.assertEqual(N.P.ProbeLimits().deadline_seconds, 10.0)
        self.assertIsInstance(outcome, P.Continuation)
        self.assertEqual(len(self.ledger), 2)
        self.assertEqual(self.f.state_path.read_bytes(), old_state)
        run = self.provider_runs[0]
        self.assertEqual(J.read_manifest(run)[0]['plan_policy']['privacy'], J.PROJECT_SYNC_PRIVACY)
        plan = L.read_plan(run)[0]
        self.assertEqual([J._json(J._unseal(op['request']))['mutation']['request']['isPrivate']
                          for op in plan['operations']], [False, True])
        plan_before = (run / L.PLAN_NAME).read_bytes()
        self.assertFalse((run / F.REVOCATION_NAME).exists())
        before_calls = list(self.calls)
        with mock.patch.object(R, 'settings', return_value=self.f.config), mock.patch.object(R, 'spawn_worker') as spawn:
            self.assertEqual(R.worker(self.f.root), 0)
        self.assertEqual(self.calls, before_calls)
        spawn.assert_not_called()  # Backoff must not create an immediate worker loop.

        # A new natural lifecycle event arrives while resumed native execution
        # is in flight. It can take enqueue.lock and preserve its newer request.
        self.f.append('Synthetic later fact while the original plan is pending.')
        observed, errors = [], []
        original_apply = self.apply
        def while_native(raw, writer, check):
            def hook():
                try:
                    with R.lock_file(self.f.root / 'enqueue.lock', blocking=False) as acquired:
                        observed.append(acquired)
                    if acquired:
                        payload = {'session_id': SID, 'transcript_path': str(self.f.path),
                            'cwd': str(self.f.project), 'hook_event_name': 'Stop', 'turn_id': 'later-turn'}
                        observed.append(R.enqueue(self.f.root, payload, spawn=False))
                except BaseException as error:
                    errors.append(error)
            child = threading.Thread(target=hook)
            child.start(); child.join(timeout=60)
            self.assertFalse(child.is_alive())
            self.assertEqual(errors, [])
            return original_apply(raw, writer, check)
        class Future(datetime.datetime):
            @classmethod
            def now(cls, tz=None):
                return datetime.datetime.now(tz) + datetime.timedelta(hours=1)
        with R.lock_file(self.f.root / 'worker.lock'):
            with R.lock_file(self.f.root / 'enqueue.lock'):
                ready = self.f.service.recover(SID, self.f.config)
            with mock.patch.object(P, 'dt', SimpleNamespace(datetime=Future, timezone=datetime.timezone)), \
                 mock.patch.object(N, 'executor', return_value=while_native):
                result = R.complete_ready_plan(self.f.root, self.f.service, ready, self.f.config)
        self.assertEqual(result, 'succeeded')
        self.assertEqual(observed, [True, True])
        self.assertEqual(len(self.provider_runs), 1)
        self.assertEqual(len(self.ledger), 2)
        self.assertEqual(len(self.calls), 3)
        self.assertEqual(self.calls[1], self.calls[2])
        self.assertEqual((run / L.PLAN_NAME).read_bytes(), plan_before)
        state = json.loads(self.f.state_path.read_bytes())
        self.assertGreater(state['offset'], self.f.frontier)
        self.assertFalse(R.requires_reconciliation(state))
        self.assertEqual(json.loads(self.f.pending.read_bytes())['turn_id'], 'later-turn')
        self.assertTrue((run / 'successful-coverage.json').exists())

    def prepare_upgrade(self, *, explicit=False):
        C = fixtures.C
        parent = self.f.base / 'plugins/cache/personal/engram'
        roots = [parent / version for version in ('0.15.3', '0.15.4')]
        parser_bytes = Path(C.transcript.__file__).read_bytes()
        for index, root in enumerate(roots):
            root.mkdir(parents=True, mode=0o700)
            fixtures.write(root / '.codex-plugin/plugin.json',
                           {'name': 'engram', 'version': root.name})
            fixtures.write(root / '.mcp.json', {'mcpServers': {'memory': {
                'command': './memory', 'cwd': '.', 'args': [],
                'default_tools_approval_mode': 'approve'}}})
            native = root / 'memory'
            native.write_bytes(b'\xcf\xfa\xed\xfe' + bytes([index]) * 128)
            native.chmod(0o700)
            parser = root / 'scripts/codex_learner/transcript.py'
            parser.parent.mkdir(parents=True, mode=0o700)
            parser.write_bytes(parser_bytes); parser.chmod(0o600)
        self.old_plugin, self.new_plugin = roots
        self.f.service.plugin_root = self.old_plugin
        self.config_path = self.f.service.config_path
        self.plugin_config = '[plugins."engram@personal"]\nenabled = true\n'
        if explicit:
            self.plugin_config += ('[mcp_servers.memory]\ncommand = ' + json.dumps(str(self.old_plugin / 'memory'))
                + '\nargs = []\ndefault_tools_approval_mode = "approve"\n')
        self.config_path.write_text(self.plugin_config)
        self.upgraded = P.Publications(self.f.root, self.config_path, self.new_plugin)
        with mock.patch.object(C.transcript, '__file__', str(self.old_plugin / 'scripts/codex_learner/transcript.py')):
            self.assertIsInstance(self.process(), P.Continuation)
        run = self.provider_runs[0]
        self.assertEqual(len(self.ledger), 2)
        self.assertFalse((run / F.REVOCATION_NAME).exists())
        self.manifest_before = (run / 'execution-manifest.json').read_bytes()
        self.plan_before = (run / L.PLAN_NAME).read_bytes()
        self.state_before = self.f.state_path.read_bytes()
        return run

    def resume_upgrade(self):
        class Future(datetime.datetime):
            @classmethod
            def now(cls, tz=None):
                return datetime.datetime.now(tz) + datetime.timedelta(hours=1)
        with mock.patch.object(fixtures.C.transcript, '__file__',
                               str(self.new_plugin / 'scripts/codex_learner/transcript.py')), \
             mock.patch.object(P, 'dt', SimpleNamespace(datetime=Future, timezone=datetime.timezone)), \
             R.lock_file(self.f.root / 'worker.lock'):
            with R.lock_file(self.f.root / 'enqueue.lock'):
                ready = self.upgraded.recover(SID, self.f.config)
            return R.complete_ready_plan(self.f.root, self.upgraded, ready, self.f.config)

    def test_upgrade_resumes_exact_original_native_plan_with_current_executor(self):
        run = self.prepare_upgrade()
        self.assertEqual(self.resume_upgrade(), 'succeeded')
        self.assertEqual(len(self.provider_runs), 1)
        self.assertEqual(len(self.ledger), 2)
        self.assertEqual(len(self.calls), 3)
        self.assertEqual(self.calls[1], self.calls[2])
        self.assertEqual(self.factory.call_args.args[1]['command'], str(self.old_plugin / 'memory'))
        self.assertEqual(self.factory.call_args.kwargs['limits'].deadline_seconds, 30.0)
        self.assertEqual((run / 'execution-manifest.json').read_bytes(), self.manifest_before)
        self.assertEqual((run / L.PLAN_NAME).read_bytes(), self.plan_before)
        self.assertGreater(json.loads(self.f.state_path.read_bytes())['offset'], self.f.frontier)
        self.assertTrue((run / 'successful-coverage.json').exists())
        # New plans still resolve the active package. No global route rewrites.
        paths = self.upgraded.context_paths(run.name)
        _, current = fixtures.C._backend(paths, stable_path=True)
        self.assertEqual(current['runtime']['path'], str(self.new_plugin / 'memory'))

    def test_upgrade_refuses_policy_settings_parser_and_foreign_namespace_changes(self):
        run = self.prepare_upgrade()
        protected = [self.f.state_path, self.f.admission_path, self.f.pending,
                     run / 'execution-manifest.json', run / L.PLAN_NAME]
        before = {path: path.read_bytes() for path in protected}
        def refused():
            with self.assertRaises(ValueError): self.resume_upgrade()
            self.assertEqual(len(self.calls), 2)
            self.assertFalse((run / F.REVOCATION_NAME).exists())
            for path, raw in before.items(): self.assertEqual(path.read_bytes(), raw)
        changes = [
            (self.config_path, self.plugin_config.replace('true', 'false').encode()),
            (self.config_path, (self.plugin_config + '[plugins."engram@personal".mcp_servers.memory]\ndisabled_tools = ["remember"]\n').encode()),
            (self.config_path, (self.plugin_config + '[mcp_servers.memory]\ncommand = ' + json.dumps(str(self.new_plugin / 'memory')) + '\ndefault_tools_approval_mode = "approve"\n').encode()),
            (self.f.root / 'settings.json', J.encode({**self.f.config, 'max_tool_calls': 1})),
            (self.new_plugin / 'scripts/codex_learner/transcript.py', b'# changed current parser\n'),
            (self.old_plugin / 'scripts/codex_learner/transcript.py', b'# changed retained parser\n'),
            (self.new_plugin / '.codex-plugin/plugin.json', J.encode({'name': 'foreign', 'version': '0.15.4'})),
            (self.old_plugin / '.codex-plugin/plugin.json', J.encode({'name': 'foreign', 'version': '0.15.3'})),
        ]
        for path, changed in changes:
            with self.subTest(path=path.name, changed=changed[:40]):
                old = path.read_bytes()
                try: path.write_bytes(changed); refused()
                finally: path.write_bytes(old)
        self.assertEqual(self.resume_upgrade(), 'succeeded')

    def test_upgrade_refuses_replaced_retained_native_even_with_identical_bytes(self):
        run = self.prepare_upgrade()
        native = self.old_plugin / 'memory'
        other = native.with_name('replacement')
        other.write_bytes(native.read_bytes()); other.chmod(0o700); other.replace(native)
        with self.assertRaisesRegex(ValueError, 'backend_changed'): self.resume_upgrade()
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(self.f.state_path.read_bytes(), self.state_before)
        self.assertFalse((run / F.REVOCATION_NAME).exists())

    def test_upgrade_keeps_explicit_native_route_and_rejects_env_or_other_marketplace(self):
        run = self.prepare_upgrade(explicit=True)
        self.config_path.write_text(self.plugin_config + 'env = { PRIVATE_ROUTE_FLAG = "changed" }\n')
        with self.assertRaisesRegex(ValueError, 'backend_changed'): self.resume_upgrade()
        self.assertEqual(len(self.calls), 2)
        self.config_path.write_text(self.plugin_config)
        original_root = self.new_plugin
        foreign = original_root.parents[2] / 'other-market/engram/0.15.4'
        foreign.parent.mkdir(parents=True, mode=0o700)
        shutil.copytree(original_root, foreign)
        self.config_path.write_text(self.plugin_config + '[plugins."engram@other-market"]\nenabled = true\n')
        self.new_plugin = foreign; self.upgraded.plugin_root = foreign
        with self.assertRaisesRegex(ValueError, 'retained_plugin_namespace_changed'): self.resume_upgrade()
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(self.f.state_path.read_bytes(), self.state_before)
        self.assertFalse((run / F.REVOCATION_NAME).exists())
        self.new_plugin = original_root; self.upgraded.plugin_root = original_root
        self.config_path.write_text(self.plugin_config)
        self.assertEqual(self.resume_upgrade(), 'succeeded')
        self.assertEqual(self.factory.call_args.args[1]['command'], str(self.old_plugin / 'memory'))
        self.assertEqual(self.calls[1], self.calls[2])
        self.assertEqual(len(self.ledger), 2)

    def test_upgraded_publication_recovers_partial_pair_without_native_replay(self):
        run = self.prepare_upgrade()
        def crash(label):
            if label == 'admission_replaced': raise RuntimeError('synthetic metadata interruption')
        with mock.patch.object(P.publication, '_boundary', side_effect=crash):
            with self.assertRaisesRegex(RuntimeError, 'synthetic metadata interruption'):
                self.resume_upgrade()
        self.assertTrue((run / F.REVOCATION_NAME).exists())
        self.assertEqual(self.f.state_path.read_bytes(), self.state_before)
        self.assertEqual(len(self.calls), 3)
        settlement = (run / 'settlement.json').read_bytes()
        with mock.patch.object(fixtures.C.transcript, '__file__',
                               str(self.new_plugin / 'scripts/codex_learner/transcript.py')), \
             R.lock_file(self.f.root / 'worker.lock'), R.lock_file(self.f.root / 'enqueue.lock'):
            outcome = self.upgraded.recover(SID, self.f.config)
        self.assertEqual(outcome, 'succeeded')
        self.assertEqual(len(self.calls), 3)
        self.assertEqual(len(self.provider_runs), 1)
        self.assertEqual((run / 'settlement.json').read_bytes(), settlement)
        self.assertEqual((run / 'execution-manifest.json').read_bytes(), self.manifest_before)
        self.assertEqual((run / L.PLAN_NAME).read_bytes(), self.plan_before)
        self.assertGreater(json.loads(self.f.state_path.read_bytes())['offset'], self.f.frontier)
        self.assertIsNone(json.loads(self.f.admission_path.read_bytes())['processing'])

    def test_failed_planning_turn_has_no_writes_and_uses_retry_backoff(self):
        self.failed = True
        result = self.process()
        self.assertEqual(result, 'failed')
        self.assertEqual(self.calls, [])
        state = json.loads(self.f.state_path.read_bytes())
        self.assertEqual(state['offset'], self.f.frontier)
        self.assertGreater(state['retry_after'], 0)
        self.assertFalse(R.requires_reconciliation(state))
        self.assertFalse((self.provider_runs[0] / L.PLAN_NAME).exists())

    def test_slow_initial_probe_releases_enqueue_and_rechecks_newer_request(self):
        before_state = self.f.state_path.read_bytes()
        def probe(transport, *, writer_fence, expected_binding):
            self.assertTrue(writer_fence.verify(expected_binding))
            with R.lock_file(self.f.root / 'enqueue.lock', blocking=False) as acquired:
                self.assertTrue(acquired)
            payload = {'session_id': SID, 'transcript_path': str(self.f.path),
                'cwd': str(self.f.project), 'hook_event_name': 'Stop', 'turn_id': 'during-probe'}
            self.assertTrue(R.enqueue(self.f.root, payload, spawn=False))
            return copy.deepcopy(self.f.scope)
        with mock.patch.object(P.operation_probe, 'probe_scope', side_effect=probe):
            with self.assertRaisesRegex(ValueError, 'request_changed_before_marker'):
                self.process()
        self.assertEqual(self.provider_runs, [])
        self.assertEqual(self.calls, [])
        self.assertEqual(self.f.state_path.read_bytes(), before_state)
        self.assertIsNone(json.loads(self.f.admission_path.read_bytes())['processing'])
        self.assertEqual(json.loads(self.f.pending.read_bytes())['turn_id'], 'during-probe')


class OversizedMessageTests(unittest.TestCase):
    """Prospective selection uses whole records and the existing sealed limit."""

    def setUp(self):
        self.p = PlanPublicationTests(methodName='runTest')
        self.addCleanup(self.p.doCleanups)
        self.p.setUp()
        self.f = self.p.f
        self.f.config['max_scan_bytes'] = 128 * 1024
        fixtures.write(self.f.root / 'settings.json', self.f.config)

    @staticmethod
    def message(text):
        return {'type': 'event_msg', 'payload': {'type': 'user_message', 'message': text}}

    def replace_records(self, *records, partial=b''):
        with self.f.path.open('r+b') as stream:
            stream.truncate(self.f.frontier)
            stream.seek(self.f.frontier)
            for record in records:
                stream.write(J.encode(record) + b'\n')
            stream.write(partial)

    def preimages(self):
        return [path.read_bytes() for path in
                (self.f.state_path, self.f.admission_path, self.f.pending, self.f.root / 'settings.json')]

    def select(self):
        class Selected(Exception):
            pass
        before = self.preimages()
        with mock.patch.object(self.f.service, 'prepare', side_effect=Selected) as prepare, \
             mock.patch.object(R, 'read_excerpt', wraps=R.read_excerpt) as reads:
            with self.assertRaises(Selected):
                self.p.process()
        self.assertEqual(self.preimages(), before)
        self.assertEqual(self.p.provider_runs, [])
        self.assertEqual(self.p.calls, [])
        return prepare.call_args.args[2:4], reads.call_args_list

    def test_small_message_keeps_configured_target_and_single_read(self):
        (excerpt, config), reads = self.select()
        self.assertIs(config, self.f.config)
        self.assertEqual(config['max_chars'], 2000)
        self.assertEqual(excerpt.text, '[USER]\nSynthetic first visible fact.')
        self.assertEqual(len(reads), 1)

    def test_fallback_restarts_original_parser_and_preserves_whole_mirrored_text(self):
        secret = 'sk-proj-' + 'x' * 32
        body = 'é界' * 1500 + ' ' + secret
        self.replace_records(
            {'type': 'turn_context', 'payload': {'turn_id': 'oversized-turn'}},
            self.message(body),
            {'type': 'response_item', 'payload': {'type': 'message', 'role': 'user',
                'id': 'mirror', 'content': [{'type': 'input_text', 'text': body}]}},
            self.message('yes'), self.message('yes'))
        (excerpt, config), reads = self.select()
        self.assertEqual(len(reads), 2)
        for call in reads:
            self.assertEqual(call.args, (str(self.f.path), self.f.frontier))
            self.assertEqual(call.kwargs['recent_messages'], [])
            self.assertIsNone(call.kwargs['current_turn_id'])
            self.assertEqual(call.kwargs['max_scan_bytes'], 128 * 1024)
        self.assertEqual([call.kwargs['max_chars'] for call in reads], [2000, 48000])
        self.assertEqual(excerpt.text, '[USER]\n' + 'é界' * 1500
                         + ' [REDACTED]\n\n[USER]\nyes\n\n[USER]\nyes')
        self.assertEqual(excerpt.message_count, 3)
        self.assertEqual(excerpt.diagnostics['duplicate_messages'], 1)
        self.assertEqual(excerpt.diagnostics['redacted_messages'], 1)
        self.assertEqual(excerpt.current_turn_id, 'oversized-turn')
        self.assertEqual(excerpt.next_offset, self.f.path.stat().st_size)
        self.assertFalse(excerpt.has_more)
        self.assertIsNone(excerpt.blocked_reason)
        self.assertIsNot(config, self.f.config)
        self.assertEqual(config, {**self.f.config, 'max_chars': 48000})
        self.assertEqual(self.f.config['max_chars'], 2000)

    def test_fallback_does_not_consume_a_following_record_beyond_ceiling(self):
        self.replace_records(self.message('a' * 30000))
        first_end = self.f.path.stat().st_size
        self.f.append('b' * 25000)
        (excerpt, _), _ = self.select()
        self.assertEqual(excerpt.text, '[USER]\n' + 'a' * 30000)
        self.assertEqual(excerpt.next_offset, first_end)
        self.assertTrue(excerpt.has_more)
        self.assertIsNone(excerpt.blocked_reason)
        following = fixtures.T.read_excerpt(self.f.path, excerpt.next_offset, max_chars=48000,
            max_scan_bytes=self.f.config['max_scan_bytes'], recent_messages=excerpt.recent_messages,
            current_turn_id=excerpt.current_turn_id, stable_identity=True)
        self.assertEqual(following.text, '[USER]\n' + 'b' * 25000)
        self.assertEqual(following.next_offset, self.f.path.stat().st_size)

    def test_refusals_keep_cursor_settings_and_scan_bound_without_preparing(self):
        cases = ((262145, 1024 * 1024, 2000, False, 'read_only_plan', 3),
                 (262145, 1024 * 1024, 48000, False, 'read_only_plan', 2),
                 (5000, 4096, 2000, False, 'read_only_plan', 1),
                 (3000, 128 * 1024, 2000, True, 'read_only_plan', 1),
                 (3000, 128 * 1024, 2000, False, None, 1))
        for chars, scan, limit, partial, mode, expected_reads in cases:
            with self.subTest(chars=chars, scan=scan, limit=limit, partial=partial, mode=mode):
                self.f.config.update(max_scan_bytes=scan, max_chars=limit)
                fixtures.write(self.f.root / 'settings.json', self.f.config)
                record = self.message('z' * chars)
                self.replace_records(partial=J.encode(record)) if partial else self.replace_records(record)
                before = self.preimages()
                with mock.patch.object(self.f.service, 'prepare') as prepare, \
                     mock.patch.object(R, 'read_excerpt', wraps=R.read_excerpt) as reads:
                    result = R.process_request(self.f.root, self.f.request, self.f.config,
                                               invoke=self.p.planning, provider_mode=mode)
                self.assertEqual(result, 'blocked')
                prepare.assert_not_called()
                self.assertEqual(reads.call_count, expected_reads)
                self.assertTrue(all(call.kwargs['max_scan_bytes'] == scan for call in reads.call_args_list))
                self.assertEqual(self.preimages(), before)
                self.assertEqual(self.p.provider_runs, [])
                self.assertEqual(self.p.calls, [])
                self.assertFalse((self.f.root / 'runs').exists())
                event = json.loads((self.f.root / 'events.jsonl').read_text().splitlines()[-1])
                self.assertEqual(event['request_id'], self.f.request['request_id'])
                self.assertEqual(event['offset'], self.f.frontier)

    def test_large_assistant_message_is_whole_and_following_record_remains_pending(self):
        self.f.config['max_scan_bytes'] = 1024 * 1024
        fixtures.write(self.f.root / 'settings.json', self.f.config)
        body = 'x' * 184448
        self.replace_records({'type': 'response_item', 'payload': {'type': 'message',
            'role': 'assistant', 'channel': 'final', 'content': [{'type': 'output_text', 'text': body}]}})
        first_end = self.f.path.stat().st_size
        self.f.append('next ' + 'y' * 100000)
        (excerpt, config), reads = self.select()
        self.assertEqual([call.kwargs['max_chars'] for call in reads], [2000, 48000, 262144])
        self.assertEqual(excerpt.text, '[ASSISTANT]\n' + body)
        self.assertEqual(len(excerpt.text), 184460)
        self.assertEqual(excerpt.next_offset, first_end)
        self.assertEqual(excerpt.message_count, 1)
        self.assertTrue(excerpt.has_more)
        self.assertEqual(config, {**self.f.config, 'max_chars': 262144})

    def test_large_fallback_respects_smaller_scan_allowance_and_exact_char_boundary(self):
        self.f.config['max_scan_bytes'] = 65536
        fixtures.write(self.f.root / 'settings.json', self.f.config)
        self.replace_records(self.message('s' * 60000))
        (excerpt, config), reads = self.select()
        self.assertEqual(excerpt.text, '[USER]\n' + 's' * 60000)
        self.assertEqual(config['max_chars'], 65536)
        self.assertEqual([call.kwargs['max_chars'] for call in reads], [2000, 48000, 65536])
        self.f.config['max_scan_bytes'] = 1024 * 1024
        fixtures.write(self.f.root / 'settings.json', self.f.config)
        self.replace_records(self.message('b' * (262144 - len('[USER]\n'))))
        (excerpt, config), _ = self.select()
        self.assertEqual(len(excerpt.text), 262144)
        self.assertEqual(excerpt.next_offset, self.f.path.stat().st_size)
        self.assertEqual(config['max_chars'], 262144)

    def test_changed_selection_with_no_visible_text_keeps_parser_only_target(self):
        self.replace_records(self.message('x' * 184448))
        self.f.config['max_scan_bytes'] = 1024 * 1024
        before = self.preimages()
        refused = fixtures.T.read_excerpt(self.f.path, self.f.frontier, max_chars=2000,
            max_scan_bytes=self.f.config['max_scan_bytes'], stable_identity=True)
        from dataclasses import replace
        empty = replace(refused, blocked_reason=None)
        with mock.patch.object(R, 'read_excerpt', side_effect=[refused, refused, empty]), \
             mock.patch.object(self.f.service, 'parser', return_value='parser-only') as parser, \
             mock.patch.object(self.f.service, 'prepare') as prepare:
            self.assertEqual(self.p.process(), 'parser-only')
        self.assertIs(parser.call_args.args[4], self.f.config)
        self.assertEqual(parser.call_args.args[4]['max_chars'], 2000)
        prepare.assert_not_called()
        self.assertEqual(self.preimages(), before)

    def test_large_provider_failure_keeps_cursor_and_creates_no_plan(self):
        self.f.config['max_scan_bytes'] = 1024 * 1024
        fixtures.write(self.f.root / 'settings.json', self.f.config)
        self.replace_records(self.message('x' * 184448))
        self.p.failed = True
        self.assertEqual(self.p.process(), 'failed')
        self.assertEqual(json.loads(self.f.state_path.read_bytes())['offset'], self.f.frontier)
        self.assertEqual(self.p.calls, [])
        self.assertFalse((self.p.provider_runs[0] / L.PLAN_NAME).exists())

    def resume(self):
        class Future(datetime.datetime):
            @classmethod
            def now(cls, tz=None):
                return datetime.datetime.now(tz) + datetime.timedelta(hours=1)
        with mock.patch.object(P, 'dt', SimpleNamespace(datetime=Future, timezone=datetime.timezone)), \
             mock.patch.object(R, 'read_excerpt', side_effect=AssertionError('old plan must recover first')):
            return self.p.process()

    def test_effective_limit_is_sealed_and_lost_ack_resumes_exact_plan(self):
        self.replace_records(self.message('a' * 3000))
        self.check_sealed_limit_and_resume(48000)

    def test_large_effective_limit_is_sealed_and_lost_ack_resumes_exact_plan(self):
        self.f.config['max_scan_bytes'] = 1024 * 1024
        fixtures.write(self.f.root / 'settings.json', self.f.config)
        self.replace_records(self.message('a' * 184448))
        self.check_sealed_limit_and_resume(262144)

    def check_sealed_limit_and_resume(self, maximum):
        before = self.preimages()
        self.assertIsInstance(self.p.process(), P.Continuation)
        run = self.p.provider_runs[0]
        manifest, _ = J.read_manifest(run)
        parser = J._json(J._unseal(manifest['inputs']['parser_state']))
        configuration = J._json(J._unseal(manifest['inputs']['backend_config']))
        self.assertEqual(parser['limits'], {'max_chars': maximum, 'max_scan_bytes': self.f.config['max_scan_bytes']})
        self.assertEqual(parser['input'], {'offset': self.f.frontier, 'recent_messages': [], 'current_turn_id': None})
        self.assertEqual(configuration['settings']['sha256'], J.sha256(before[3]))
        self.assertEqual(configuration['settings']['value']['max_chars'], 2000)
        self.assertEqual(parser['runtime']['sha256'], J.sha256(Path(fixtures.T.__file__).read_bytes()))
        self.assertEqual(self.f.state_path.read_bytes(), before[0])
        self.assertEqual((self.f.root / 'settings.json').read_bytes(), before[3])
        sealed = [(run / name).read_bytes() for name in ('execution-manifest.json', L.PLAN_NAME)]
        self.assertEqual(self.resume(), 'succeeded')
        self.assertEqual([(run / name).read_bytes() for name in ('execution-manifest.json', L.PLAN_NAME)], sealed)
        self.assertEqual(len(self.p.provider_runs), 1)
        self.assertEqual(len(self.p.ledger), 2)
        self.assertEqual(self.p.calls[1], self.p.calls[2])
        self.assertEqual(json.loads(self.f.state_path.read_bytes())['offset'], self.f.path.stat().st_size)
        self.assertTrue((run / 'successful-coverage.json').exists())
        self.assertEqual((self.f.root / 'settings.json').read_bytes(), before[3])

    def test_existing_smaller_sealed_plan_recovers_before_new_oversized_suffix(self):
        self.assertIsInstance(self.p.process(), P.Continuation)
        run = self.p.provider_runs[0]
        sealed = [(run / name).read_bytes() for name in ('execution-manifest.json', L.PLAN_NAME)]
        manifest, _ = J.read_manifest(run)
        self.assertEqual(J._json(J._unseal(manifest['inputs']['parser_state']))['limits']['max_chars'], 2000)
        end = manifest['source']['end_offset']
        self.f.append('new complete suffix ' + 'x' * 49000)
        self.assertEqual(self.resume(), 'succeeded')
        self.assertEqual([(run / name).read_bytes() for name in ('execution-manifest.json', L.PLAN_NAME)], sealed)
        self.assertEqual(len(self.p.provider_runs), 1)
        self.assertEqual(len(self.p.ledger), 2)
        self.assertEqual(self.p.calls[1], self.p.calls[2])
        self.assertEqual(json.loads(self.f.state_path.read_bytes())['offset'], end)


if __name__ == '__main__':
    unittest.main()
