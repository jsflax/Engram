"""Normal worker continuation with a synthetic native ledger, no live stores."""
import copy
import datetime
import json
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
        self.patch.start()
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
                    'arguments': {'content': f'Synthetic fact {i}'}} for i in (1, 2)]}
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
        self.assertIsInstance(outcome, P.Continuation)
        self.assertEqual(len(self.ledger), 2)
        self.assertEqual(self.f.state_path.read_bytes(), old_state)
        run = self.provider_runs[0]
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


if __name__ == '__main__':
    unittest.main()
