"""Independent negative acceptance for the isolated residual controller."""
import copy
import json
from pathlib import Path
import unittest
from unittest import mock

from test_residual_driver import Fixture
from residual_test_support import D
J = D.J


def write(path, value):
    path.write_bytes(J.encode(value))
    path.chmod(0o600)


class ResidualIndependentTests(unittest.TestCase):
    def fixture(self):
        fixture = Fixture()
        self.addCleanup(fixture.close)
        return fixture

    def snapshot(self, fixture):
        return {str(p.relative_to(fixture.run)): (p.read_bytes(), p.stat().st_mode)
                for p in fixture.run.rglob('*') if p.is_file()}

    def no_dispatch(self, fixture):
        executed = mock.Mock(side_effect=AssertionError('refused input must never execute'))
        before = self.snapshot(fixture)
        with self.assertRaises((ValueError, OSError, KeyError, TypeError)):
            fixture.driver.dispatch('R1', writer=fixture.writer,
                                    recoveries=fixture.recoveries, execute=executed)
        executed.assert_not_called()
        self.assertEqual(self.snapshot(fixture), before)

    def test_completed_checkpoint_replay_and_new_controller_are_exact_noops(self):
        f = self.fixture()
        f.revoke()
        expected = f.reconcile()
        before = self.snapshot(f)
        forbidden = mock.Mock(side_effect=AssertionError('completed checkpoint must not probe again'))
        self.assertEqual(f.driver.reconcile(recoveries=f.recoveries, probe=forbidden), expected)
        f.driver = D.ResidualDriver(f.run, manifest_sha256=f.manifest_sha,
            review_sha256=f.review_sha, validate_inputs=f.validator)
        self.assertEqual(f.driver.reconcile(recoveries=f.recoveries, probe=forbidden), expected)
        forbidden.assert_not_called()
        self.assertEqual(self.snapshot(f), before)
        self.assertEqual(f.continue_(), 1)

    def test_missing_partial_or_unexpected_generation_never_executes(self):
        for change in ('missing', 'partial', 'gap', 'extra-name'):
            with self.subTest(change=change):
                f = self.fixture()
                path = f.run / 'residual-generation-000.json'
                if change == 'missing': path.unlink()
                elif change == 'partial': path.write_bytes(b'{')
                elif change == 'gap': path.rename(f.run / 'residual-generation-001.json')
                else: write(f.run / 'residual-generation-extra.json', {})
                self.no_dispatch(f)

    def test_generation_cannot_change_request_inventory_or_authority(self):
        for change in ('allowed-order', 'allowed-subset', 'index', 'prior', 'request', 'review'):
            with self.subTest(change=change):
                f = self.fixture()
                path = f.run / 'residual-generation-000.json'
                gen = json.loads(path.read_bytes())
                if change == 'allowed-order': gen['allowed'].reverse()
                elif change == 'allowed-subset': gen['allowed'] = ['R1']
                elif change == 'index': gen['index'] = 1
                elif change == 'prior': gen['previous_sha256'] = '1' * 64
                elif change == 'request': gen['requests']['R1'] = '2' * 64
                else: gen['review_sha256'] = '3' * 64
                write(path, gen)
                self.no_dispatch(f)

    def test_partial_checkpoint_refuses_without_probe_or_status_append(self):
        f = self.fixture()
        f.revoke()
        path = f.run / 'residual-reconciliation-000.json'
        path.write_bytes(b'{'); path.chmod(0o600)
        before = self.snapshot(f)
        probe = mock.Mock(side_effect=AssertionError('partial checkpoint must stay held'))
        with self.assertRaises(ValueError):
            f.driver.reconcile(recoveries=f.recoveries, probe=probe)
        probe.assert_not_called()
        self.assertEqual(self.snapshot(f), before)

    def test_checkpoint_tamper_cannot_grant_continuation(self):
        for change in ('head', 'status-inventory', 'generations', 'review', 'extra-status'):
            with self.subTest(change=change):
                f = self.fixture(); f.revoke(); f.reconcile()
                path = f.run / 'residual-reconciliation-000.json'
                proof = json.loads(path.read_bytes())
                if change == 'head': proof['heads']['R1'] = '4' * 64
                elif change == 'status-inventory': proof['statuses'].pop('R1')
                elif change == 'generations': proof['generation_sha256s'] = []
                elif change == 'review': proof['review_sha256'] = '5' * 64
                else: proof['statuses']['R6'] = copy.deepcopy(proof['statuses']['R1'])
                write(path, proof)
                before = self.snapshot(f)
                with self.assertRaises((ValueError, OSError)):
                    f.continue_()
                self.assertEqual(self.snapshot(f), before)
                self.assertFalse((f.run / 'residual-generation-001.json').exists())

    def test_later_evidence_holds_checkpoint_replay_and_continuation(self):
        f = self.fixture(); f.revoke(); f.reconcile()
        operation, _, _ = f.driver._intent('R1')
        J.record_response(f.run, operation, {'kind':'absent','operationID':operation,'scope':f.scope},
                          verify_fence=f.recoveries[0].verify)
        before = self.snapshot(f)
        forbidden = mock.Mock(side_effect=AssertionError('changed checkpoint heads must stay held'))
        with self.assertRaisesRegex(ValueError, 'status_changed_since_checkpoint'):
            f.driver.reconcile(recoveries=f.recoveries, probe=forbidden)
        with self.assertRaisesRegex(ValueError, 'status_changed_since_checkpoint'):
            f.continue_()
        forbidden.assert_not_called()
        self.assertEqual(self.snapshot(f), before)

    def test_missing_prior_checkpoint_blocks_existing_continuation_dispatch(self):
        f = self.fixture(); f.revoke(); f.reconcile(); f.continue_()
        (f.run / 'residual-reconciliation-000.json').unlink()
        self.no_dispatch(f)

    def test_extra_intent_and_tampered_dispatch_record_never_execute(self):
        for change in ('extra-intent', 'dispatch-operation', 'dispatch-generation'):
            with self.subTest(change=change):
                f = self.fixture()
                if change == 'extra-intent': write(f.run / 'operation-unreviewed.json', {})
                else:
                    gen, digest = f.driver._generations()[0]
                    record = f.driver._dispatch_record(0, 'R1', digest)
                    if change == 'dispatch-operation': record['operation_id'] = f.driver._intent('R2')[0]
                    else: record['generation_sha256'] = '6' * 64
                    write(f.run / 'residual-dispatch-000-R1.json', record)
                self.no_dispatch(f)

    def test_continuation_cannot_regrant_applied_operation(self):
        f = self.fixture(); f.execute('R1'); f.revoke(); f.reconcile(); f.continue_()
        path = f.run / 'residual-generation-001.json'
        gen = json.loads(path.read_bytes()); gen['allowed'] = list(f.driver.operations)
        write(path, gen)
        self.no_dispatch(f)
        self.assertEqual(f.driver.summary()['applied'], ['R1'])
        self.assertFalse(f.driver.summary()['cursor_authority'])


if __name__ == '__main__': unittest.main()
