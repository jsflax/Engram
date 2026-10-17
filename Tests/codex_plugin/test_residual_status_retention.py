"""Returned read-only observations are retained without renewing authority."""
import copy
import unittest
from test_residual_driver import Fixture, J, MEMORY


class StatusRetentionTests(unittest.TestCase):
    def fixture(self):
        f = Fixture()
        self.addCleanup(f.close)
        f.revoke()
        return f

    def responses(self, f, requests):
        receipt = {'version': 1, 'operationID': requests[0]['operationID'], 'scope': f.scope,
                   'payloadDigest': 'd' * 64, 'mutation': 'remember', 'outcome': 'applied',
                   'memoryIDs': [MEMORY], 'edgeIDs': [], 'committedAt': 800000000.25}
        return [{'kind': 'committed', 'receipt': receipt}] + [
            {'kind': 'absent', 'operationID': item['operationID'], 'scope': f.scope} for item in requests[1:]]

    def test_returned_commit_survives_current_authority_change_without_checkpoint(self):
        f = self.fixture()
        def probe(requests, recovery, check):
            check('before_fixture_status')
            result = self.responses(f, requests)
            f.driver.validate_inputs = lambda *_: False
            return result
        result = f.driver.reconcile(recoveries=f.recoveries, probe=probe)
        self.assertEqual(result['memory_ids'], [MEMORY])
        self.assertEqual(result['applied'], ['R1'])
        self.assertEqual(result['status'], 'reconciliation_required')
        self.assertIs(result['current_inputs_validated'], False)
        operation = f.driver._intent('R1')[0]
        self.assertEqual(J.read_evidence(f.run, operation)[-1]['evidence']['kind'], 'committed')
        self.assertFalse((f.run / 'residual-reconciliation-000.json').exists())
        writer = f.new_writer()
        with self.assertRaises(ValueError):
            f.driver.continue_generation(recoveries=f.recoveries, new_writer=writer)
        self.assertFalse((f.run / 'residual-generation-001.json').exists())

    def test_later_malformed_status_keeps_prior_valid_receipt(self):
        f = self.fixture()
        def probe(requests, recovery, check):
            result = self.responses(f, requests)
            result[1] = copy.deepcopy(result[0])
            return result
        with self.assertRaises(ValueError):
            f.driver.reconcile(recoveries=f.recoveries, probe=probe)
        self.assertEqual(f.driver.summary()['memory_ids'], [MEMORY])
        self.assertFalse((f.run / 'residual-reconciliation-000.json').exists())

    def test_adapter_failure_is_still_uncertain_and_invents_no_receipt(self):
        f = self.fixture()
        def probe(*_):
            raise ValueError('synthetic cleanup failure before successful return')
        with self.assertRaises(ValueError):
            f.driver.reconcile(recoveries=f.recoveries, probe=probe)
        self.assertEqual(f.driver.summary()['memory_ids'], [])
        self.assertFalse((f.run / 'residual-reconciliation-000.json').exists())


if __name__ == '__main__':
    unittest.main()
