import os
from pathlib import Path
import signal
import sys
import unittest
from unittest import mock
from test_residual_driver import Fixture,D,F,J,N,MEMORY

class CrashTests(unittest.TestCase):
    def kill_at(self, fixture, label, action):
        pid=os.fork()
        if pid==0:
            def stop(current):
                if current==label:os.kill(os.getpid(),signal.SIGKILL)
            D.boundary=stop
            try:action()
            except BaseException:os._exit(91)
            os._exit(92)
        waited,status=os.waitpid(pid,0)
        self.assertEqual(waited,pid)
        self.assertTrue(os.WIFSIGNALED(status),f'child did not hit {label}: {status}')
        self.assertEqual(os.WTERMSIG(status),signal.SIGKILL)

    def test_dispatch_death_boundaries_never_invent_commit(self):
        for boundary in ('dispatch_before_create','dispatch_created','dispatch_file_fsynced','dispatch_directory_fsynced','before_execute'):
            with self.subTest(boundary=boundary):
                f=Fixture()
                try:
                    self.kill_at(f,boundary,f.execute)
                    self.assertFalse((f.root/'calls.jsonl').exists())
                    self.assertEqual(f.driver.summary()['memory_ids'],[])
                    f.revoke()
                    if boundary=='dispatch_created':
                        with self.assertRaises(ValueError):f.reconcile()
                        self.assertFalse(f.driver.summary()['execution_evidence_valid'])
                    else:
                        f.reconcile();f.continue_();self.assertEqual(f.execute()['applied'],['R1'])
                finally:f.close()

    def test_actual_native_commit_then_controller_death_recovers_receipt(self):
        for boundary in ('after_execute','after_receipt'):
            with self.subTest(boundary=boundary):
                f=Fixture()
                try:
                    self.kill_at(f,boundary,f.execute)
                    f.revoke();result=f.reconcile()
                    self.assertEqual(result['memory_ids'],[MEMORY]);self.assertEqual(result['committed'],['R1'])
                    f.continue_()
                    with self.assertRaisesRegex(ValueError,'dispatch_not_authorized'):f.execute()
                    calls=(f.root/'calls.jsonl').read_text()
                    self.assertEqual(calls.count('"tool": "operation_apply"'),1)
                finally:f.close()

    def test_continuation_publication_death_has_no_invisible_replay(self):
        for boundary in ('generation_before_create','generation_created','generation_file_fsynced','generation_directory_fsynced'):
            with self.subTest(boundary=boundary):
                f=Fixture()
                try:
                    f.revoke();f.reconcile();writer=f.new_writer()
                    self.kill_at(f,boundary,lambda:f.driver.continue_generation(recoveries=f.recoveries,new_writer=writer))
                    self.assertFalse((f.root/'calls.jsonl').read_text().find('operation_apply')>=0)
                    if boundary=='generation_created':
                        with self.assertRaises(ValueError):f.driver.dispatch('R1',writer=writer,recoveries=f.recoveries,execute=lambda *_:None)
                    elif boundary=='generation_before_create':
                        self.assertEqual(f.driver.continue_generation(recoveries=f.recoveries,new_writer=writer),1)
                    else:
                        # Durable generation is recovered by reading its original
                        # binding; there is no new manifest or operation identity.
                        f.writer=writer
                        self.assertEqual(f.execute()['applied'],['R1'])
                finally:f.close()

    def test_prepublication_exact_true_continuation_validation(self):
        for bad in (False,None,1):
            f=Fixture()
            try:
                f.revoke();f.reconcile();writer=f.new_writer()
                f.driver.validate_inputs=lambda _m,_p,phase:bad if phase=='before_continuation_publish' else True
                with self.assertRaisesRegex(ValueError,'input_validation_refused'):f.driver.continue_generation(recoveries=f.recoveries,new_writer=writer)
                self.assertFalse(f.driver._generation_path(1).exists())
            finally:f.close()

if __name__=='__main__':unittest.main()
