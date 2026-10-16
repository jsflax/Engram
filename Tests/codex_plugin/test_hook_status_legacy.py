"""Bounded passive legacy reconciliation projection; fixtures remain in localdev."""
import copy
import hashlib
import json
import unittest
from unittest.mock import patch

import test_hook_status as base

STATUS = base.STATUS
RID = '01234567-89ab-4cde-8f01-23456789abcd'
MEMORY = '01234567-89ab-4cde-8f01-23456789abce'


class LegacyHealthTests(unittest.TestCase):
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
        self.reference = {'version': 1, 'id': RID, 'legacy_run_id': base.RUN,
            'evidence_sha256': 'b' * 64,
            'interval': {'start_offset': 100, 'end_offset': 200,
                         'excerpt_sha256': 'c' * 64, 'interval_sha256': 'd' * 64},
            'memory_ids': [MEMORY]}
        self.root = self.learner_fixture(session={'offset': 200,
            'status': 'legacy_reconciled_no_new_mutation', 'last_run': base.RUN,
            'last_reconciliation': copy.deepcopy(self.reference)}, pending=pending)
        self.private(self.root / 'runs' / base.RUN / 'run.json',
            {'session_id': base.SID, 'status': 'failed', 'reason': 'unverified_completion',
             'turn_completed': True, 'write_calls': 1, 'end_offset': 200})
        self.private(self.root / 'runs' / base.RUN / 'result.json',
                     {'outcome': 'no_new_memories', 'memory_ids': []})
        self.pin = {'ticket_id': RID, 'ticket_sha256': 'e' * 64}
        self.completion = {'version': 1, **self.pin, 'published_sha256': 'f' * 64,
            'ack_intent_sha256': 'a' * 64,
            'outcome': {'result': 'legacy_reconciled_no_new_mutation', 'queue_action': 'keep', 'pause_reason': None},
            'disposition': 'original', 'pending': {'bytes': 'PRIVATE_PENDING_NEVER_DISPLAY'}}
        self.directory = self.root / 'reconciliations' / RID
        self.complete_path = self.private(self.root / 'publications' / base.SID / 'records' / RID / 'completion.json', self.completion)
        self.pin_path = self.private(self.directory / 'publication-reference.json', self.pin)
        self.receipt = {'version': 1, 'kind': 'legacy_interval_reconciliation',
            'status': 'reconciled_no_new_mutation', 'session_id': base.SID,
            'reference': copy.deepcopy(self.reference), 'plan_sha256': 'a' * 64,
            'publication': copy.deepcopy(self.pin),
            'completion_sha256': hashlib.sha256(self.complete_path.read_bytes()).hexdigest(),
            'historical_run_status': 'failed', 'historical_execution_sealed': False,
            'source_binding_grade': 'current_bounded_reconstruction', 'native_mutations_performed': 0}
        self.receipt_path = self.private(self.directory / 'receipt.json', self.receipt)
        return self.root

    def health(self):
        return self.report()['learner']['health']

    def update_state(self, **values):
        path = self.root / 'sessions' / (base.SID + '.json')
        state = json.loads(path.read_text())
        state.update(values)
        self.write(path, state)

    def assert_pending(self):
        result = self.health()
        self.assertEqual(result['headline'], 'publication_recovery_pending')
        self.assertEqual(result['failure']['class'], 'publication_requires_recovery')
        self.assertEqual(result['outcomes']['legacy_reconciliation']['state'], 'recovery_pending')
        self.assertFalse(result['recovery']['automatic_replay_authorized'])

    def test_recorded_reconciliation_resolves_exact_old_failure_without_claiming_success(self):
        self.fixture()
        result = self.health()
        self.assertEqual(result['headline'], 'idle')
        self.assertEqual(result['failure']['class'], 'none_observed')
        self.assertEqual(result['outcomes']['provider_completion']['run_status'], 'failed')
        self.assertEqual(result['outcomes']['provider_completion']['state'], 'completed_in_run_receipt')
        self.assertEqual(result['progress']['last_completed_interval']['evidence'], 'not_available_in_window')
        self.assertEqual(result['progress']['last_reconciled_interval'], {
            'evidence': 'recorded_legacy_reconciliation', 'legacy_run_id': base.RUN,
            'start_offset': 100, 'end_offset': 200})
        self.assertEqual(result['outcomes']['legacy_reconciliation']['historical_execution_sealed'], False)
        self.assertEqual(result['outcomes']['independent_readback']['state'], 'not_performed')
        self.assertNotIn('PRIVATE_PENDING', json.dumps(self.report()))

    def test_matching_pending_pause_remains_paused(self):
        self.fixture(pending={'paused_request_id': base.REQUEST, 'pause_reason': 'batch_limit', 'size_bytes': 900})
        result = self.health()
        self.assertEqual(result['headline'], 'batch_limit')
        self.assertEqual(result['outcomes']['queue']['state'], 'paused')
        self.assertEqual(result['failure']['class'], 'none_observed')

    def test_missing_receipt_after_active_retirement_still_requires_recovery(self):
        self.fixture()
        self.assertFalse((self.root / 'publications' / base.SID / 'active.json').exists())
        self.receipt_path.unlink()
        self.assert_pending()

    def test_missing_pin_or_completion_requires_recovery(self):
        self.fixture()
        for path in (self.pin_path, self.complete_path):
            with self.subTest(path=path.name):
                raw = path.read_bytes()
                path.unlink()
                self.assert_pending()
                path.write_bytes(raw)
                path.chmod(0o600)

    def test_receipt_schema_binding_and_qualifiers_are_exact(self):
        self.fixture()
        mutations = [
            ('version', True), ('session_id', base.OTHER), ('plan_sha256', 'x'),
            ('historical_run_status', 'succeeded'), ('historical_execution_sealed', True),
            ('source_binding_grade', 'historically_sealed'), ('native_mutations_performed', False),
            ('native_mutations_performed', 1), ('completion_sha256', '0' * 64),
            ('publication', {**self.pin, 'ticket_id': base.OTHER}),
            ('reference', {**self.reference, 'evidence_sha256': '0' * 64}),
            ('private_extra', 'PRIVATE_SECRET')]
        for key, value in mutations:
            with self.subTest(key=key, value=value):
                self.private(self.receipt_path, {**self.receipt, key: value})
                self.assert_pending()
                self.assertNotIn('PRIVATE_SECRET', json.dumps(self.report()))
        self.private(self.receipt_path, self.receipt)

    def test_completion_pin_hash_and_outcome_are_required(self):
        self.fixture()
        for key, value in [('ticket_sha256', '0' * 64), ('version', True),
                           ('outcome', {'result': 'succeeded', 'queue_action': 'delete', 'pause_reason': None}),
                           ('disposition', 'invented'), ('pending', None), ('extra', 'SECRET')]:
            with self.subTest(key=key):
                self.private(self.complete_path, {**self.completion, key: value})
                self.private(self.receipt_path, {**self.receipt, 'completion_sha256': hashlib.sha256(self.complete_path.read_bytes()).hexdigest()})
                self.assert_pending()
        self.private(self.complete_path, self.completion)
        self.private(self.receipt_path, self.receipt)
        self.private(self.pin_path, {**self.pin, 'ticket_sha256': '0' * 64})
        self.assert_pending()

    def test_private_bounded_owned_files_only(self):
        self.fixture()
        for path, limit in ((self.receipt_path, STATUS.MAX_JSON_BYTES), (self.pin_path, STATUS.MAX_JSON_BYTES),
                            (self.complete_path, STATUS.MAX_SETTLEMENT_BYTES)):
            raw = path.read_bytes()
            with self.subTest(path=path.name, issue='permissions'):
                path.chmod(0o644)
                self.assert_pending()
                path.chmod(0o600)
            with self.subTest(path=path.name, issue='oversize'):
                path.write_bytes(b' ' * (limit + 1))
                self.assert_pending()
                path.write_bytes(raw)
            with self.subTest(path=path.name, issue='symlink'):
                target = path.with_suffix('.saved')
                path.rename(target)
                path.symlink_to(target)
                self.assert_pending()
                path.unlink()
                target.rename(path)

    def test_duplicate_json_keys_refused(self):
        self.fixture()
        raw = self.receipt_path.read_bytes()
        self.receipt_path.write_bytes(b'{"version":1,' + raw[1:])
        self.assert_pending()

    def test_malformed_reference_cannot_select_other_paths(self):
        self.fixture()
        for changed in ({'id': '../../private'}, {'id': RID.upper()}, {'version': True},
                        {'memory_ids': [MEMORY, MEMORY.upper()]},
                        {'interval': {**self.reference['interval'], 'start_offset': True}}):
            with self.subTest(changed=changed):
                self.update_state(last_reconciliation={**self.reference, **changed})
                with patch.object(STATUS, 'read_bounded', wraps=STATUS.read_bounded) as reads:
                    self.assert_pending()
                self.assertFalse(any('reconciliations' in str(call.args[0]) for call in reads.call_args_list))

    def test_new_status_without_reference_is_not_idle(self):
        self.fixture()
        path = self.root / 'sessions' / (base.SID + '.json')
        state = json.loads(path.read_text())
        del state['last_reconciliation']
        self.write(path, state)
        self.assert_pending()

    def test_newer_failed_run_cannot_be_resolved_by_historical_receipt(self):
        self.fixture()
        new_run = '20260918T120000Z-' + 'c' * 32
        self.private(self.root / 'runs' / new_run / 'run.json', {'session_id': base.SID, 'status': 'failed', 'reason': 'timeout'})
        self.update_state(last_run=new_run)
        self.assertEqual(self.health()['failure']['class'], 'timeout')
        self.assertEqual(self.health()['headline'], 'failed')

    def test_current_state_failure_or_lower_cursor_is_not_resolved(self):
        self.fixture()
        self.update_state(status='failed')
        self.assertEqual(self.health()['headline'], 'failed')
        self.update_state(status='legacy_reconciled_no_new_mutation', offset=199)
        self.assertEqual(self.health()['headline'], 'failed')

    def test_current_gate_processing_or_active_publication_still_wins(self):
        self.fixture()
        self.update_state(reconciliation_required={'run_id': base.RUN, 'reason': 'successful_or_unverified_write', 'memory_ids': [MEMORY]})
        self.assertEqual(self.health()['headline'], 'reconciliation_required')
        path = self.root / 'sessions' / (base.SID + '.json')
        state = json.loads(path.read_text())
        del state['reconciliation_required']
        self.write(path, state)
        self.write(self.root / 'admissions' / (base.SID + '.json'), {'binding': {'session_id': base.SID}, 'processing': base.REQUEST})
        self.assertEqual(self.health()['headline'], 'processing_unverified')
        self.private(self.root / 'publications' / base.SID / 'active.json', self.pin)
        self.assertEqual(self.health()['headline'], 'publication_recovery_pending')

    def test_later_parser_only_progress_preserves_historical_resolution(self):
        self.fixture()
        self.update_state(status='no_visible_content', offset=300)
        self.assertEqual(self.health()['headline'], 'idle')
        self.assertEqual(self.health()['outcomes']['provider_completion']['run_status'], 'failed')

    def test_projection_does_not_open_plan_audit_or_database(self):
        self.fixture()
        with patch.object(STATUS, 'open_regular', wraps=STATUS.open_regular) as opens:
            self.assertEqual(self.health()['headline'], 'idle')
        paths = [str(call.args[0]) for call in opens.call_args_list]
        self.assertFalse(any(name in path for path in paths for name in ('plan.json', 'mcp-audit', 'provider.jsonl', '.sqlite', 'manifest.json')))
        self.assertLessEqual(len(paths), 20)


if __name__ == '__main__':
    unittest.main()
