"""Passive residual receipts stay distinct from provider success and readback."""
import copy
import hashlib
import json
import unittest
from unittest.mock import patch

import test_hook_status as base

STATUS = base.STATUS
RID = '01234567-89ab-4cde-8f01-23456789abcd'
MEMORY = '01234567-89ab-4cde-8f01-23456789abce'
NEW_MEMORY = '01234567-89ab-4cde-8f01-23456789abcf'
RESIDUAL_RUN = '20261016T210000Z-' + 'd' * 32


class ResidualHealthTests(unittest.TestCase):
    setUp = base.StatusTests.setUp
    tearDown = base.StatusTests.tearDown
    write = base.StatusTests.write
    report = base.StatusTests.report
    learner_fixture = base.StatusTests.learner_fixture

    def private(self, path, value):
        self.write(path, value)
        path.chmod(0o600)
        return path

    def fixture(self, *, pending=None):
        execution = {'run_id': RESIDUAL_RUN, 'manifest_sha256': 'a'*64,
                     'context_sha256': 'b'*64, 'review_sha256': 'c'*64}
        self.qualification = {'historical_run_status': 'failed', 'historical_execution_sealed': False,
            'source_binding_grade': 'current_bounded_reconstruction', 'provider_invoked': False,
            'applied_write_count': 5, 'unchanged_write_count': 0}
        self.settled = {'version': 1, 'kind': 'reviewed_residual_settlement', **execution, **self.qualification,
            'authorization_sha256': 'd'*64, 'generation_sha256s': ['e'*64], 'checkpoint_sha256': 'f'*64,
            'evidence_heads': {f'R{i}': '1'*64 for i in range(1,6)},
            'operations': [{'label': f'R{i}', 'operation_id': f'01234567-89ab-4cde-8f01-23456789abc{i}',
                            'receipt_sha256': '2'*64} for i in range(1,6)],
            'preserved_memory_ids': [MEMORY], 'new_memory_ids': [NEW_MEMORY], 'successful_coverage': False}
        self.reference = {'version': 1, 'id': RID, 'legacy_run_id': base.RUN, **execution,
            'settlement_sha256': '0'*64, 'interval': {'start_offset': 100, 'end_offset': 200,
                'excerpt_sha256': '3'*64, 'interval_sha256': '4'*64},
            'preserved_memory_ids': [MEMORY], 'new_memory_ids': [NEW_MEMORY]}
        self.root = self.learner_fixture(session={'offset': 200, 'status': 'legacy_reconciled_with_residuals',
            'last_run': base.RUN, 'last_residual_reconciliation': self.reference}, pending=pending)
        self.private(self.root/'runs'/base.RUN/'run.json', {'session_id': base.SID, 'status': 'failed',
            'reason': 'unverified_completion', 'turn_completed': True, 'write_calls': 1, 'end_offset': 200})
        self.directory = self.root/'runs'/RESIDUAL_RUN
        self.settled_path = self.directory/'residual-settlement.json'
        self.pin = {'ticket_id': RID, 'ticket_sha256': '5'*64}
        self.completion = {'version': 1, **self.pin, 'published_sha256': '6'*64, 'ack_intent_sha256': '7'*64,
            'outcome': {'result': 'legacy_reconciled_with_residuals', 'queue_action': 'keep', 'pause_reason': None},
            'disposition': 'original', 'pending': {'bytes': 'PRIVATE_PENDING_NEVER_DISPLAY'}}
        self.complete_path = self.private(self.root/'publications'/base.SID/'records'/RID/'completion.json', self.completion)
        self.pin_path = self.private(self.directory/'residual-publication-reference.json', self.pin)
        self.receipt = {'version': 1, 'kind': 'legacy_residual_interval_reconciliation',
            'status': 'reconciled_with_residuals', 'session_id': base.SID, 'request_id': base.REQUEST,
            'reference': self.reference, 'publication': self.pin,
            'completion_sha256': hashlib.sha256(self.complete_path.read_bytes()).hexdigest(), **self.qualification}
        self.receipt_path = self.directory/'residual-receipt.json'
        self.repin_settlement(self.settled)

    def repin_settlement(self, value):
        self.private(self.settled_path, value)
        self.reference['settlement_sha256'] = hashlib.sha256(self.settled_path.read_bytes()).hexdigest()
        self.private(self.receipt_path, self.receipt)
        self.update_state(last_residual_reconciliation=self.reference)

    def update_state(self, **values):
        path = self.root/'sessions'/(base.SID+'.json')
        value = json.loads(path.read_bytes());value.update(values);self.write(path, value)

    def health(self):
        return self.report()['learner']['health']

    def assert_pending(self):
        health = self.health()
        self.assertEqual(health['headline'], 'publication_recovery_pending')
        self.assertEqual(health['outcomes']['residual_reconciliation']['state'], 'recovery_pending')
        self.assertFalse(health['recovery']['automatic_replay_authorized'])

    def test_completed_review_retains_failed_provider_and_qualified_counts(self):
        self.fixture()
        health = self.health()
        self.assertEqual(health['headline'], 'idle')
        self.assertEqual(health['failure']['class'], 'none_observed')
        self.assertEqual(health['outcomes']['provider_completion']['run_status'], 'failed')
        residual = health['outcomes']['residual_reconciliation']
        self.assertEqual(residual['state'], 'recorded_completed')
        self.assertEqual(residual['applied_write_count'], 5)
        self.assertIs(residual['provider_invoked'], False)
        self.assertEqual(health['progress']['last_reconciled_interval']['evidence'], 'recorded_residual_reconciliation')
        self.assertEqual(health['progress']['last_completed_interval']['evidence'], 'not_available_in_window')
        self.assertEqual(health['outcomes']['independent_readback']['state'], 'not_performed')
        self.assertNotIn('PRIVATE_PENDING', json.dumps(self.report()))

    def test_missing_final_receipt_or_other_pin_requires_recovery(self):
        self.fixture()
        for path in (self.receipt_path, self.pin_path, self.settled_path, self.complete_path):
            with self.subTest(path=path.name):
                raw = path.read_bytes();path.unlink();self.assert_pending()
                path.write_bytes(raw);path.chmod(0o600)

    def test_missing_null_or_unsafe_reference_never_selects_arbitrary_paths(self):
        self.fixture()
        for reference in (None, {}, {**self.reference, 'run_id': '../PRIVATE'},
                          {**self.reference, 'id': RID.upper()}, {**self.reference, 'version': True}):
            with self.subTest(reference=reference):
                self.update_state(last_residual_reconciliation=reference)
                with patch.object(STATUS, 'read_bounded', wraps=STATUS.read_bounded) as reads:
                    self.assert_pending()
                self.assertFalse(any('residual-receipt' in str(c.args[0]) for c in reads.call_args_list))
        path = self.root/'sessions'/(base.SID+'.json')
        value = json.loads(path.read_bytes());del value['last_residual_reconciliation'];self.write(path, value)
        self.assert_pending()

    def test_receipt_qualifications_and_bindings_are_not_advisory(self):
        self.fixture()
        for key, value in [('version', True), ('provider_invoked', True), ('applied_write_count', True),
                           ('historical_run_status', 'succeeded'), ('unchanged_write_count', 1),
                           ('session_id', base.OTHER), ('completion_sha256', '0'*64), ('extra', 'PRIVATE_SECRET')]:
            with self.subTest(key=key):
                self.private(self.receipt_path, {**self.receipt, key: value});self.assert_pending()
                self.assertNotIn('PRIVATE_SECRET', json.dumps(self.report()))

    def test_rehashed_but_invalid_settlement_remains_held(self):
        self.fixture()
        for key, value in [('successful_coverage', True), ('provider_invoked', True), ('applied_write_count', 4),
                           ('context_sha256', '0'*64), ('new_memory_ids', []), ('operations', []),
                           ('generation_sha256s', []), ('evidence_heads', {}), ('extra', 'PRIVATE_SECRET')]:
            with self.subTest(key=key):
                self.repin_settlement({**self.settled, key: value});self.assert_pending()
                self.assertNotIn('PRIVATE_SECRET', json.dumps(self.report()))

    def test_receipts_are_bounded_private_and_no_review_or_source_is_loaded(self):
        self.fixture()
        with patch.object(STATUS, 'read_bounded', wraps=STATUS.read_bounded) as reads:
            self.assertEqual(self.health()['headline'], 'idle')
        forbidden = ('residual-context.json', 'residual-review.json', 'execution-manifest.json', '.sqlite')
        self.assertFalse(any(any(name in str(c.args[0]) for name in forbidden) for c in reads.call_args_list))
        for path, limit in ((self.receipt_path, STATUS.MAX_JSON_BYTES), (self.pin_path, STATUS.MAX_JSON_BYTES),
                            (self.settled_path, STATUS.MAX_SETTLEMENT_BYTES), (self.complete_path, STATUS.MAX_SETTLEMENT_BYTES)):
            with self.subTest(path=path.name):
                raw = path.read_bytes();path.chmod(0o644);self.assert_pending();path.chmod(0o600)
                path.write_bytes(b' '*(limit+1));self.assert_pending();path.write_bytes(raw)
                target = path.with_suffix('.saved');path.rename(target);path.symlink_to(target)
                self.assert_pending();path.unlink();target.rename(path)

    def test_newer_failure_or_current_hold_remains_visible(self):
        self.fixture()
        self.update_state(reconciliation_required={'run_id': base.RUN, 'reason': 'successful_or_unverified_write'})
        self.assertEqual(self.health()['headline'], 'reconciliation_required')
        path = self.root/'sessions'/(base.SID+'.json');value = json.loads(path.read_bytes())
        del value['reconciliation_required'];self.write(path, value)
        newer = '20261016T220000Z-'+'e'*32
        self.private(self.root/'runs'/newer/'run.json', {'session_id': base.SID, 'status': 'failed', 'reason': 'timeout'})
        self.update_state(last_run=newer)
        self.assertEqual(self.health()['headline'], 'failed')
        self.assertEqual(self.health()['failure']['class'], 'timeout')

    def test_paused_request_is_not_resumed_by_health_or_review(self):
        self.fixture(pending={'paused_request_id': base.REQUEST, 'pause_reason': 'batch_limit', 'size_bytes': 900})
        before = (self.root/'pending'/(base.SID+'.json')).read_bytes()
        health = self.health()
        self.assertEqual(health['headline'], 'batch_limit')
        self.assertEqual(health['outcomes']['queue']['state'], 'paused')
        self.assertEqual((self.root/'pending'/(base.SID+'.json')).read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
