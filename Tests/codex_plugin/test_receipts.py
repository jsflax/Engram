"""Proxy budget, privacy and verified receipt regressions with no transport child."""
import importlib
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

    def test_update_receipt_requires_requested_exact_uuid(self):
        self.call(1, 'update', {'id': ID, 'content': 'Synthetic'})
        self.reply(1, f'Updated memory (id: {OTHER})')
        self.assertGreater(self.audit_result()['tool_errors'], 0)

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
