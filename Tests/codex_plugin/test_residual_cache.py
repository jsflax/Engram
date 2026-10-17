"""Parsed authority memoization never memoizes current bytes or live fences."""
import json
import unittest
from test_residual_driver import Fixture,J,D

class AuthorityCacheTests(unittest.TestCase):
    def fixture(self):
        f=Fixture();self.addCleanup(f.close);f.driver._generations();return f
    def test_warm_then_same_size_request_change_refuses(self):
        f=self.fixture();operation=f.driver._intent('R1')[0]
        p=f.run/('operation-'+operation+'.json');raw=p.read_bytes()
        # Change one retained base64 byte without changing file size.
        value=J._json(raw);encoded=value['request']['bytes_base64']
        value['request']['bytes_base64']=('A' if encoded[0]!='A' else 'B')+encoded[1:]
        changed=J.encode(value);self.assertEqual(len(raw),len(changed));p.write_bytes(changed)
        with self.assertRaises(ValueError):f.execute()
        self.assertFalse((f.root/'calls.jsonl').exists())
    def test_warm_then_remove_add_and_change_evidence_refuse(self):
        f=self.fixture();f.execute();f.driver._generations()
        operation=f.driver._intent('R1')[0];directory=f.run/('evidence-'+operation)
        record=directory/'000000.json';raw=record.read_bytes();record.unlink()
        with self.assertRaises(ValueError):f.execute('R2')
        record.write_bytes(raw);record.chmod(0o600);f.driver._generations()
        extra=f.run/'evidence-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';extra.mkdir(mode=0o700)
        with self.assertRaisesRegex(ValueError,'unexpected_evidence'):f.execute('R2')
        extra.rmdir();f.driver._generations()
        tail=directory/'000002.json';tail.write_bytes(b'{}');tail.chmod(0o600)
        with self.assertRaises(ValueError):f.execute('R2')
    def test_cache_hit_rechecks_current_validator_and_actual_held_fence(self):
        f=self.fixture();f.driver._generations()
        f.driver.validate_inputs=lambda *_:False
        with self.assertRaisesRegex(ValueError,'input_validation_refused'):f.execute()
        f.driver.validate_inputs=lambda *_:True;f.writer.close()
        with self.assertRaisesRegex(ValueError,'closed'):f.execute()

if __name__=='__main__':unittest.main()
