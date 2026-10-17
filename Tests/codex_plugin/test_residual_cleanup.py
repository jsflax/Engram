"""A valid reply without successful cleanup is still a lost acknowledgement."""
import unittest
from unittest import mock
from test_residual_driver import Fixture,D,J,MEMORY

class CleanupBoundaryTests(unittest.TestCase):
    def test_native_commit_then_reported_cleanup_failure_recovers_only_by_status(self):
        f=Fixture();self.addCleanup(f.close)
        cleanup=D.P.bridge._cleanup
        observed=[]
        def fail_after_actual_reap(child,timeout):
            result=cleanup(child,timeout)
            observed.append(result['child_reaped'])
            return {**result,'cleanup_failed':True}
        with mock.patch.object(D.P.bridge,'_cleanup',side_effect=fail_after_actual_reap):
            result=f.execute()
        self.assertEqual(observed,[True])
        self.assertEqual(result['memory_ids'],[])
        self.assertEqual(result['committed'],[])
        self.assertEqual(result['status'],'reconciliation_required')
        operation=f.driver._intent('R1')[0]
        self.assertTrue((f.root/('receipt-'+operation+'.json')).exists())
        f.revoke();result=f.reconcile()
        self.assertEqual(result['memory_ids'],[MEMORY])
        self.assertEqual(result['committed'],['R1'])
        self.assertEqual(J.read_evidence(f.run,operation)[-1]['evidence']['kind'],'committed')
        f.continue_()
        with self.assertRaisesRegex(ValueError,'dispatch_not_authorized'):f.execute()

if __name__=='__main__':unittest.main()
