"""Proxy budget, privacy and verified receipt regressions with no transport child."""
import importlib
import copy
import json
from pathlib import Path
import tempfile
import unittest

from suite_support import PLUGIN_ROOT, REPOSITORY_ROOT, TEMP_ROOT

import test_frontier as F

PROXY = None
ID = '11111111-2222-4333-8444-555555555555'
OTHER = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'


def setUpModule():
    global PROXY
    F.setUpModule()
    PROXY = importlib.import_module(F.PACKAGE + '.memory_proxy')


def tearDownModule():
    F.tearDownModule()


class MemoryAudit:
    def __init__(self): self.rows = []
    def write(self, row): self.rows.append(row)


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.audit = MemoryAudit()
        self.policy = PROXY.Policy(self.audit, 'codex-session:SOURCE', 3, 1)

    def call(self, number, name, arguments=None):
        return self.policy.client_message({'jsonrpc': '2.0', 'id': number, 'method': 'tools/call',
                                           'params': {'name': name, 'arguments': arguments or {}}})

    def reply(self, number, text, error=False):
        return self.policy.server_message({'jsonrpc': '2.0', 'id': number,
                                           'result': {'isError': error, 'content': [{'type': 'text', 'text': text}]}})

    def audit_result(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'audit.jsonl'
            path.write_text(''.join(json.dumps(r) + '\n' for r in self.audit.rows))
            return F.RUNNER.audit_tools(path)

    def test_remember_enforces_private_provenance_and_exact_primary_uuid(self):
        forwarded, denied = self.call(1, 'remember', {'content': 'Synthetic', 'is_private': False, 'source': 'forged'})
        self.assertIsNone(denied)
        self.assertTrue(forwarded['params']['arguments']['is_private'])
        self.assertEqual(forwarded['params']['arguments']['source'], 'codex-session:SOURCE')
        self.reply(1, f'Stored memory (id: {ID})\nAutomatically related to {OTHER}')
        result = self.audit_result()
        self.assertEqual(result['tool_errors'], 0)
        self.assertEqual(result['writes'][0]['memory_ids'], [ID])
        self.assertNotIn('Synthetic', json.dumps(self.audit.rows))

    def test_claimed_uuid_without_engram_receipt_is_denied(self):
        self.call(1, 'remember', {'content': 'Synthetic'})
        output, _ = self.reply(1, f'I probably saved {ID}')
        self.assertTrue(output['result']['isError'])
        self.assertGreater(self.audit_result()['tool_errors'], 0)
        self.assertEqual(self.audit_result()['writes'], [])

    def conflict(self):
        return (PROXY.NEAR_DUPLICATE_PREFIX
                + f'\n  [id:{OTHER}] (distance: 0.123, term overlap: 90%) PRIVATE_EXISTING'
                + PROXY.NEAR_DUPLICATE_SUFFIX)

    def test_near_duplicate_is_not_a_write_or_tool_error(self):
        self.call(1, 'remember', {'content': 'Synthetic'})
        output, _ = self.reply(1, self.conflict())
        self.assertIs(output['result']['isError'], False)
        self.assertIn(OTHER, output['result']['content'][0]['text'])
        self.assertNotIn(OTHER, json.dumps(self.audit.rows))
        self.assertNotIn('PRIVATE_EXISTING', json.dumps(self.audit.rows))
        self.assertEqual(self.audit_result(), {'tool_calls': 1, 'write_calls': 0,
                                             'writes': [], 'tool_errors': 0})

    def test_conflict_then_update_counts_only_the_verified_update(self):
        self.policy = PROXY.Policy(self.audit, 'codex-session:SOURCE', 3, 2)
        self.call(1, 'remember', {'content': 'Synthetic'})
        self.reply(1, self.conflict())
        self.call(2, 'update', {'id': OTHER, 'append': 'New finding'})
        self.reply(2, f'Updated memory (id: {OTHER})')
        self.assertEqual(self.audit_result(), {'tool_calls': 2, 'write_calls': 1,
            'writes': [{'tool': 'update', 'memory_ids': [OTHER]}], 'tool_errors': 0})

    def test_conflict_attempt_still_consumes_write_budget(self):
        self.call(1, 'remember', {'content': 'Synthetic'})
        self.reply(1, self.conflict())
        forwarded, denied = self.call(2, 'remember', {'content': 'Another'})
        self.assertIsNone(forwarded)
        self.assertTrue(denied['result']['isError'])
        self.assertEqual(self.policy.write_calls, 2)
        self.assertEqual(self.audit_result()['write_calls'], 0)
        self.assertGreater(self.audit_result()['tool_errors'], 0)

    def test_malformed_no_write_receipts_fail_both_completion_and_reconciliation(self):
        self.call(1, 'remember', {'content': 'Synthetic'})
        self.reply(1, self.conflict())
        valid = self.audit.rows[-1]
        changes = [{'write_outcome': 'unknown'}, {'memory_ids': [OTHER]},
                   {'memory_ids': None}, {'forwarded': 1}, {'forwarded': False},
                   {'ok': 1}, {'ok': False}, {'tool': 'update'}, {'extra': True}]
        for change in changes:
            with self.subTest(change=change):
                self.audit.rows[-1] = dict(valid, **change)
                self.assertGreater(self.audit_result()['tool_errors'], 0)
                with tempfile.TemporaryDirectory() as temp:
                    path = Path(temp)
                    rows = [{'event': 'relay_started'}, *self.audit.rows]
                    (path / 'mcp-audit.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in rows))
                    self.assertIsNotNone(F.RUNNER.failure_reconciliation(path, True))

    def begin_busy(self, tool='remember'):
        text = ('Memory was not updated: the database was busy before the write transaction started. Retry on a later turn.'
                if tool == 'update' else
                'Memory was not stored: the database was busy before the write transaction started. Retry on a later turn.')
        return {'isError': True, 'content': [{'type': 'text', 'text': text}],
                'structuredContent': {'engram_write_receipt': {
                    'schema_version': 1, 'tool': tool,
                    'write_outcome': 'not_stored_transaction_not_started',
                    'reason': 'database_busy', 'memory_ids': []}}}

    def busy_reply(self, number, result=None, **envelope):
        return self.policy.server_message({'jsonrpc': '2.0', 'id': number,
            'result': self.begin_busy() if result is None else result, **envelope})

    def test_begin_busy_is_failed_but_replay_has_no_unverified_write(self):
        self.call(1, 'remember', {'content': 'Synthetic'})
        output, _ = self.busy_reply(1)
        self.assertIs(output['result']['isError'], True)
        self.assertEqual(self.audit.rows[-1], {
            'event': 'tool_result', 'id': 1, 'tool': 'remember', 'ok': False,
            'forwarded': True, 'memory_ids': [],
            'write_outcome': 'not_stored_transaction_not_started', 'write_outcome_version': 1})
        self.assertEqual(self.audit_result(), {'tool_calls': 1, 'write_calls': 0,
                                             'writes': [], 'tool_errors': 1})
        self.assertIsNone(self.reconciliation([*self.timeout_prefix(), *self.audit.rows]))
        # Failure still consumes the finite attempt budget.
        _, denied = self.call(2, 'remember', {'content': 'Retry'})
        self.assertTrue(denied['result']['isError'])

    def test_update_begin_busy_is_failed_without_a_reconciliation_gate(self):
        self.call(1, 'update', {'id': ID, 'importance': 3})
        output, _ = self.busy_reply(1, self.begin_busy('update'))
        self.assertIs(output['result']['isError'], True)
        self.assertEqual(self.audit.rows[-1], {
            'event': 'tool_result', 'id': 1, 'tool': 'update', 'ok': False,
            'forwarded': True, 'memory_ids': [],
            'write_outcome': 'not_stored_transaction_not_started', 'write_outcome_version': 1})
        self.assertEqual(self.audit_result(), {'tool_calls': 1, 'write_calls': 0,
                                             'writes': [], 'tool_errors': 1})
        self.assertIsNone(self.reconciliation([*self.timeout_prefix(), *self.audit.rows]))
        _, denied = self.call(2, 'update', {'id': ID, 'importance': 4})
        self.assertTrue(denied['result']['isError'])

    def test_begin_busy_contract_rejects_text_spoofs_and_contradictions(self):
        base = self.begin_busy()
        candidates = []
        for key in base:
            value = copy.deepcopy(base); del value[key]; candidates.append(value)
        for replacement in [False, 1, None]:
            candidates.append(dict(base, isError=replacement))
        candidates.extend([dict(base, extra=True), dict(base, content=[]),
                           dict(base, content=[{'type': 'text', 'text': 'Quoted: ' + PROXY.BEGIN_BUSY_TEXT}]),
                           dict(base, content=[{'type': 'text', 'text': PROXY.BEGIN_BUSY_TEXT, 'extra': True}]),
                           dict(base, structuredContent={'other': base['structuredContent']})])
        mutations = [('schema_version', True), ('schema_version', 1.0), ('schema_version', 2),
                     ('tool', 'update'), ('write_outcome', 'unknown'), ('reason', 'other'),
                     ('memory_ids', [ID]), ('memory_ids', None), ('extra', True)]
        for key, value in mutations:
            changed = copy.deepcopy(base)
            changed['structuredContent']['engram_write_receipt'][key] = value
            candidates.append(changed)
        for key in base['structuredContent']['engram_write_receipt']:
            changed = copy.deepcopy(base); del changed['structuredContent']['engram_write_receipt'][key]
            candidates.append(changed)
        for candidate in candidates:
            with self.subTest(candidate=candidate):
                self.audit = MemoryAudit()
                self.policy = PROXY.Policy(self.audit, 'codex-session:SOURCE', 3, 1)
                self.call(1, 'remember', {'content': 'Synthetic'})
                self.busy_reply(1, candidate)
                self.assertNotIn('write_outcome', self.audit.rows[-1])
                self.assertIsNotNone(self.reconciliation([*self.timeout_prefix(), *self.audit.rows]))
        self.assertFalse(PROXY.verified_begin_busy_response('update', base))
        self.audit = MemoryAudit(); self.policy = PROXY.Policy(self.audit, 'codex-session:SOURCE', 3, 1)
        self.call(1, 'remember', {'content': 'Synthetic'})
        self.busy_reply(1, error={'code': -1, 'message': 'Contradictory error'})
        self.assertNotIn('write_outcome', self.audit.rows[-1])
        self.assertIsNotNone(self.reconciliation([*self.timeout_prefix(), *self.audit.rows]))

    def test_begin_busy_receipt_mutations_remain_uncertain(self):
        self.call(1, 'remember', {'content': 'Synthetic'}); self.busy_reply(1)
        valid = self.audit.rows[-1]
        mutations = [{'write_outcome_version': True}, {'write_outcome_version': 1.0},
                     {'write_outcome_version': 2}, {'write_outcome': 'unknown'},
                     {'ok': True}, {'ok': 0}, {'forwarded': False}, {'forwarded': 1},
                     {'memory_ids': [ID]}, {'memory_ids': None}, {'tool': 'connect'}, {'extra': True}]
        candidates = [dict(valid, **change) for change in mutations]
        candidates.extend({k: v for k, v in valid.items() if k != removed} for removed in valid)
        for candidate in candidates:
            with self.subTest(candidate=candidate):
                self.assertFalse(PROXY.verified_no_write_receipt(candidate))
                self.assertIsNotNone(self.reconciliation([*self.timeout_prefix(), self.audit.rows[0], candidate]))

    def test_begin_busy_audit_tool_must_match_the_forwarded_call(self):
        for tool, other in (('remember', 'update'), ('update', 'remember')):
            with self.subTest(tool=tool):
                self.audit = MemoryAudit(); self.policy = PROXY.Policy(self.audit, 'codex-session:SOURCE', 3, 1)
                self.call(1, tool, {'content': 'Synthetic'} if tool == 'remember' else {'id': ID, 'importance': 3})
                self.busy_reply(1, self.begin_busy(tool))
                self.audit.rows[-1]['tool'] = other
                self.assertIsNotNone(self.reconciliation([*self.timeout_prefix(), *self.audit.rows]))

    def test_update_uncertain_body_or_commit_failure_still_requires_reconciliation(self):
        self.call(1, 'update', {'id': ID, 'importance': 3})
        self.reply(1, 'Storage failed after transaction entry; write outcome uncertain.', error=True)
        self.assertNotIn('write_outcome', self.audit.rows[-1])
        self.assertEqual(self.reconciliation([*self.timeout_prefix(), *self.audit.rows]),
                         {'reason': 'successful_or_unverified_write', 'memory_ids': []})

    def test_safe_begin_failure_cannot_erase_prior_success_or_uncertainty(self):
        for tool in ('remember', 'update'):
            for prior in (None, {'ok': False, 'memory_ids': []}, {'ok': True, 'memory_ids': [ID]}):
                with self.subTest(tool=tool, prior=prior):
                    self.audit = MemoryAudit(); self.policy = PROXY.Policy(self.audit, 'codex-session:SOURCE', 3, 2)
                    self.call(2, tool, {'content': 'Synthetic'} if tool == 'remember' else {'id': ID, 'importance': 3})
                    self.busy_reply(2, self.begin_busy(tool))
                    rows = [*self.timeout_prefix(), {'event': 'tool_call', 'id': 1, 'tool': 'remember'}]
                    if prior is not None:
                        rows.append({'event': 'tool_result', 'id': 1, 'tool': 'remember',
                                     'forwarded': True, **prior})
                    rows.extend(self.audit.rows)
                    gate = self.reconciliation(rows)
                    self.assertEqual(gate['reason'], 'successful_or_unverified_write')
                    self.assertEqual(gate['memory_ids'], [ID] if prior and prior['ok'] else [])

    def test_post_timeout_cleanup_cannot_claim_native_begin_receipt(self):
        for tool in ('remember', 'update'):
            with self.subTest(tool=tool):
                self.audit = MemoryAudit(); self.policy = PROXY.Policy(self.audit, 'codex-session:SOURCE', 3, 1)
                self.call(1, tool, {'content': 'Synthetic'} if tool == 'remember' else {'id': ID, 'importance': 3})
                self.busy_reply(1, self.begin_busy(tool))
                rows = [*self.timeout_prefix(), self.audit.rows[0], {'event': 'request_timeout'}, self.audit.rows[1]]
                self.assertEqual(self.reconciliation(rows)['reason'], 'write_status_unknown')

    def test_update_receipt_requires_requested_exact_uuid(self):
        self.call(1, 'update', {'id': ID, 'content': 'Synthetic'})
        self.reply(1, f'Updated memory (id: {OTHER})')
        self.assertGreater(self.audit_result()['tool_errors'], 0)

    def reconciliation(self, rows, *, complete=True):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            raw = ''.join(json.dumps(row) + '\n' for row in rows)
            (path / 'mcp-audit.jsonl').write_text(raw if complete else raw.rstrip('\n'))
            return F.RUNNER.failure_reconciliation(path, True)

    def timeout_prefix(self):
        return [{'event': 'relay_started'},
                {'event': 'initialize_compat', 'omitted_capability': 'codex/auth-change'}]

    def test_initialize_timeout_has_no_forwarded_write_but_is_not_success(self):
        rows = [*self.timeout_prefix(), {'event': 'request_timeout'}]
        self.assertIsNone(self.reconciliation(rows))
        self.audit.rows = rows
        self.assertGreater(self.audit_result()['tool_errors'], 0)

    def test_timeout_retains_unknown_and_acknowledged_earlier_writes(self):
        call = {'event': 'tool_call', 'id': 1, 'tool': 'remember'}
        for result in (None,
                       {'event': 'tool_result', 'id': 1, 'tool': 'remember',
                        'ok': False, 'forwarded': True, 'memory_ids': []},
                       {'event': 'tool_result', 'id': 1, 'tool': 'remember',
                        'ok': True, 'forwarded': True, 'memory_ids': [ID]}):
            with self.subTest(result=result):
                rows = [*self.timeout_prefix(), call]
                if result is not None:
                    rows.append(result)
                rows.append({'event': 'request_timeout'})
                gate = self.reconciliation(rows)
                self.assertEqual(gate['reason'], 'successful_or_unverified_write')
                self.assertEqual(gate['memory_ids'], [ID] if result and result['ok'] else [])

    def test_timeout_cleanup_can_record_failed_pending_call_but_not_erase_risk(self):
        rows = [*self.timeout_prefix(), {'event': 'tool_call', 'id': 1, 'tool': 'remember'},
                {'event': 'request_timeout'},
                {'event': 'relay_finished', 'child_reaped': True, 'cleanup_overrun': False},
                {'event': 'tool_result', 'id': 1, 'tool': 'remember',
                 'ok': False, 'forwarded': True, 'memory_ids': []}]
        self.assertIsNotNone(self.reconciliation(rows))
        for forwarded in (False, None, 0, 1):
            with self.subTest(forwarded=forwarded):
                rows[-1]['forwarded'] = forwarded
                self.assertEqual(self.reconciliation(rows)['reason'], 'write_status_unknown')

    def test_timeout_after_local_denial_does_not_create_write_uncertainty(self):
        rows = [*self.timeout_prefix(), {'event': 'tool_call', 'id': 1, 'tool': 'remember'},
                {'event': 'tool_result', 'id': 1, 'tool': 'remember',
                 'ok': False, 'forwarded': False, 'memory_ids': []},
                {'event': 'request_timeout'}]
        self.assertIsNone(self.reconciliation(rows))

    def test_malformed_or_nonterminal_timeout_remains_unknown(self):
        timeout = {'event': 'request_timeout'}
        cases = [[timeout],
                 [*self.timeout_prefix(), dict(timeout, no_writes=True)],
                 [*self.timeout_prefix(), timeout, timeout],
                 [*self.timeout_prefix(), timeout, {'event': 'relay_started'}],
                 [*self.timeout_prefix(), timeout,
                  {'event': 'tool_call', 'id': 1, 'tool': 'remember'}],
                 [*self.timeout_prefix(), timeout, {'event': 'initialize_compat'}],
                 [*self.timeout_prefix(), {'event': 'unknown_timeout'}]]
        for rows in cases:
            with self.subTest(rows=rows):
                self.assertEqual(self.reconciliation(rows)['reason'], 'write_status_unknown')
        self.assertEqual(self.reconciliation([*self.timeout_prefix(), timeout], complete=False)['reason'],
                         'write_status_unknown')

    def test_duplicate_audit_fields_cannot_hide_a_write_as_a_timeout(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            (path / 'mcp-audit.jsonl').write_text(
                '{"event":"relay_started"}\n'
                '{"event":"tool_call","event":"request_timeout"}\n')
            self.assertEqual(F.RUNNER.failure_reconciliation(path, True)['reason'],
                             'write_status_unknown')

    def test_failed_and_denied_calls_consume_total_budget(self):
        self.call(1, 'recall'); self.reply(1, 'failed', error=True)
        self.call(2, 'shell')
        self.call(3, 'recall'); self.reply(3, '[]')
        forwarded, denied = self.call(4, 'remember', {'content': 'Synthetic'})
        self.assertIsNone(forwarded)
        self.assertTrue(denied['result']['isError'])
        self.assertEqual(self.policy.total_calls, 4)

    def test_write_limit_and_conflict_override_are_enforced(self):
        self.call(1, 'remember', {'content': 'Synthetic', 'force': True})
        forwarded, denied = self.call(2, 'remember', {'content': 'Synthetic'})
        self.assertIsNone(forwarded)
        self.assertTrue(denied['result']['isError'])
        self.assertEqual(self.policy.write_calls, 2)

    def test_privacy_and_project_changes_in_update_are_denied(self):
        for field in ('is_private', 'project', 'restore'):
            policy = PROXY.Policy(MemoryAudit(), 'codex-session:SOURCE', 3, 1)
            forwarded, denied = policy.client_message({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
                'params': {'name': 'update', 'arguments': {'id': ID, field: False}}})
            self.assertIsNone(forwarded)
            self.assertTrue(denied['result']['isError'])

    def test_missing_or_duplicate_result_cannot_count_as_success(self):
        self.call(1, 'recall')
        self.assertGreater(self.audit_result()['tool_errors'], 0)
        self.reply(1, '[]')
        self.audit.rows.append(dict(self.audit.rows[-1]))
        self.assertGreater(self.audit_result()['tool_errors'], 0)

    def test_only_exact_successful_connection_endpoints_are_accepted(self):
        self.call(1, 'connect', {'from': ID, 'to': OTHER, 'relation': 'relates_to'})
        self.reply(1, f'Connected (edge id: {ID}) [id:{ID}] --[relates_to]--> [id:{OTHER}]')
        result = self.audit_result()
        self.assertEqual(result['tool_errors'], 0)
        self.assertEqual(result['writes'][0]['memory_ids'], [ID, OTHER])


if __name__ == '__main__':
    unittest.main()
