"""In-process plan/fence/ledger fixtures; no provider, native or store access."""
import copy
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'codex/plugins/engram/scripts'))
from codex_learner import learner_plan as P, planned_execution as E
from codex_learner import execution_manifest as J, settlement as S, writer_fence as F

SID = '01900000-0000-7000-8000-000000000001'
STORE = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
MEMORY = '11111111-2222-4333-8444-555555555555'
OTHER = '11111111-2222-4333-8444-555555555556'
EDGE = '11111111-2222-4333-8444-555555555557'


def planning_files(run, manifest_sha, operations, *, outcome=None):
    """Populate provider-owned terminal/read-only evidence for a real manifest."""
    observation = {'started': True, 'terminated': True, 'returncode': 0, 'turn_completed': True,
        'provider_error': False, 'unexpected_tool': False, 'tool_errors': 0, 'reason': None}
    S.record_provider_dispatch(run, manifest_sha, lambda *_: True)
    S.persist_observation(run, observation)
    rows = [{'event': 'relay_started'}, {'event': 'tool_call', 'id': 1, 'tool': 'recall'},
        {'event': 'tool_result', 'id': 1, 'tool': 'recall', 'ok': True, 'memory_ids': [], 'forwarded': True},
        {'event': 'relay_finished', 'child_reaped': True, 'cleanup_overrun': False}]
    S.durable._new(run / 'mcp-audit.jsonl', b''.join(J.encode(row) + b'\n' for row in rows))
    proposal = {'schema_version': 1, 'outcome': outcome or ('proposed' if operations else 'no_new_memories'),
        'summary': 'Fixture proposal', 'operations': operations}
    S.durable._new(run / 'proposal.json', J.encode(proposal))
    return proposal


def receipt_envelope(request, *, outcome='applied'):
    kind = request['mutation']['kind']
    receipt = {'version': 1, 'operationID': request['operationID'], 'scope': request['expectedScope'],
        'payloadDigest': J.sha256(J.encode(request)), 'mutation': kind, 'outcome': outcome,
        'memoryIDs': [MEMORY, OTHER] if kind == 'connect' else [MEMORY],
        'edgeIDs': [EDGE] if kind == 'connect' else [], 'committedAt': 800000000.25}
    value = {'engram_operation': {'version': 1, 'kind': 'committed', 'receipt': receipt}}
    return {'jsonrpc': '2.0', 'id': 3, 'result': {'isError': False, 'structuredContent': value,
        'content': [{'type': 'text', 'text': J.encode(value).decode()}]}}


class FakeLedger:
    """Exact-request idempotency simulator, with deliberate lost responses."""
    def __init__(self):
        self.requests, self.receipts, self.effects, self.calls = {}, {}, {}, []
        self.lose = set()
        self.before_effect_failures = 0

    def __call__(self, raw, writer, check):
        check('before_native_launch'); writer.pass_fds(); check('before_native_write')
        request = J._json(raw); operation = request['operationID']; self.calls.append((operation, raw))
        if self.before_effect_failures:
            self.before_effect_failures -= 1
            raise TimeoutError('fixture transport interrupted')
        if operation in self.requests:
            if self.requests[operation] != raw:
                raise AssertionError('request bytes changed during retry')
        else:
            self.requests[operation] = raw
            self.receipts[operation] = receipt_envelope(request)
            self.effects[operation] = self.effects.get(operation, 0) + 1
        if operation in self.lose:
            self.lose.remove(operation)
            raise TimeoutError('fixture lost response after commit')
        return copy.deepcopy(self.receipts[operation])


class LearnerPlanTests(unittest.TestCase):
    def setUp(self):
        base = Path(os.environ.get('ENGRAM_TEST_ROOT', ROOT / 'Tests/codex_plugin/.tmp')).resolve()
        base.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix='whole-plan-', dir=base)
        self.addCleanup(self.temporary.cleanup)
        self.run = Path(self.temporary.name)
        self.binding = F.create(self.run, generation_id=STORE, owner_id=MEMORY)
        self.writer = F.acquire_shared(self.run, self.binding)
        self.addCleanup(lambda: self.writer.close())
        self.scope = {'version': 1, 'storeID': STORE, 'principal': {'kind': 'agent', 'groupIds': [], 'scopes': []}}
        memory = {'enabled': True, 'disabled_tools': [],
            'default_tools_approval_mode': 'approve', 'tools': {}}
        values = {name: {'fixture': name} for name in J.INPUT_NAMES}
        values['backend_config'] = {'memory': memory, 'settings': None}
        values['request'] = {'session_id': SID, 'request_id': 'fixture', 'admission': {'session_id': SID}}
        values['parser_state'] = {'version': 1, 'input': {'offset': 10, 'recent_messages': [], 'current_turn_id': None},
            'limits': {'max_chars': 24000, 'max_scan_bytes': 8388608},
            'runtime': {'path': '/fixture/parser.py', 'sha256': 'b' * 64}, 'interval_sha256': 'c' * 64}
        values['next_parser_state'] = {'offset': 20, 'recent_messages': [], 'current_turn_id': None}
        inputs = {name: J.seal_json(J.encode(value)) for name, value in values.items()}
        self.manifest = {'version': 1, 'host': 'fixture', 'session_id': SID, 'run_id': 'fixture-plan',
            'provider_mode': P.MODE, 'plan_policy': {'max_tool_calls': 12, 'max_writes': 5},
            'inputs': inputs, 'expected_scope': self.scope, 'source': {
                'identity': {'scheme': 'macos_volume_uuid_inode_v1', 'volume_uuid': STORE, 'inode': 123},
                'start_offset': 10, 'end_offset': 20, 'excerpt_sha256': 'a' * 64},
            'backend': {'route_id': 'fixture', 'runtime_sha256': 'b' * 64,
                'route_sha256': inputs['backend_route']['sha256'], 'config_sha256': inputs['backend_config']['sha256']},
            'fencing': self.binding}
        self.digest = J.publish_manifest(self.run, self.manifest, verify_fence=self.writer.verify)
        self.ledger = FakeLedger()
        self.operations = [
            {'key': 'op_1', 'tool': 'remember', 'arguments': {'content': 'Fixture complete plan', 'expires_in_days': 7}},
            {'key': 'op_2', 'tool': 'update', 'arguments': {'id': MEMORY, 'append': 'Fixture appended text'}},
            {'key': 'op_3', 'tool': 'connect', 'arguments': {'from': MEMORY, 'to': OTHER, 'relation': 'relates_to'}}]

    def seal(self, operations=None):
        planning_files(self.run, self.digest, self.operations if operations is None else operations)
        return P.seal_plan(self.run, verify_fence=self.writer.verify, validate_inputs=lambda *_: True)

    def execute(self, execute=None, validate=None):
        return E.execute_plan(self.run, writer=self.writer, validate_inputs=validate or (lambda *_: True),
                              execute=execute or self.ledger)

    def settle(self):
        self.writer.close()
        with F.revoke(self.run, self.binding, validate=lambda *_: True) as recovery:
            return S.settle(self.run, manifest_sha256=self.digest, recovery_fence=recovery, validate_inputs=lambda *_: True)

    def test_entire_proposal_validates_before_any_intent_or_dispatch(self):
        proposal = {'schema_version': 1, 'outcome': 'proposed', 'summary': '', 'operations': self.operations}
        policy = dict(provenance='codex-session:' + SID, allowed_tools=P.WRITE_TOOLS,
                      max_tool_calls=12, max_writes=5, read_calls=1)
        valid = P.validate_proposal(proposal, **policy)
        self.assertTrue(valid['operations'][0]['arguments']['is_private'])
        self.assertEqual(valid['operations'][0]['arguments']['source'], policy['provenance'])
        for edit in ('symbolic_target', 'unknown_field', 'privacy', 'source', 'duplicate_key', 'budget'):
            with self.subTest(edit=edit):
                value = copy.deepcopy(proposal); options = dict(policy)
                if edit == 'symbolic_target': value['operations'][2]['arguments']['to'] = {'operation_key': 'op_1'}
                elif edit == 'unknown_field': value['operations'][2]['arguments']['query'] = 'anything'
                elif edit == 'privacy': value['operations'][0]['arguments']['is_private'] = False
                elif edit == 'source': value['operations'][0]['arguments']['source'] = 'forged'
                elif edit == 'duplicate_key': value['operations'][2]['key'] = 'op_1'
                else: options['max_tool_calls'] = 3
                with self.assertRaises(ValueError): P.validate_proposal(value, **options)
        self.assertEqual(list(self.run.glob('operation-*')), [])

    def test_seal_requires_clean_readonly_coverage_and_binds_exact_inputs(self):
        self.seal()
        self.assertEqual(E.inspect_plan(self.run)['status'], 'pending')
        self.assertEqual(list(self.run.glob('operation-*')), [])
        raw = (self.run / 'proposal.json').read_bytes()
        (self.run / 'proposal.json').write_bytes(raw + b' ')
        with self.assertRaisesRegex(ValueError, 'sealed_plan_changed'): P.read_plan(self.run)
        self.assertEqual(self.ledger.calls, [])

    def test_strict_output_schema_and_only_known_optional_nulls(self):
        def visit(value):
            if isinstance(value, dict):
                if value.get('type') == 'object':
                    self.assertEqual(set(value['properties']), set(value['required']))
                    self.assertIs(value['additionalProperties'], False)
                for item in value.values(): visit(item)
            elif isinstance(value, list):
                for item in value: visit(item)
        visit(P.PROPOSAL_SCHEMA)
        proposal = {'schema_version': 1, 'outcome': 'proposed', 'summary': '', 'operations': copy.deepcopy(self.operations)}
        for item in proposal['operations']:
            for key in P._ARGUMENT_SCHEMAS[item['tool']]['properties']:
                item['arguments'].setdefault(key, None)
        policy = dict(provenance='codex-session:' + SID, allowed_tools=P.WRITE_TOOLS,
                      max_tool_calls=12, max_writes=5, read_calls=1)
        normalized = P.validate_proposal(proposal, **policy)
        self.assertEqual(normalized['operations'][1]['arguments'], self.operations[1]['arguments'])
        self.assertTrue(normalized['operations'][0]['arguments']['is_private'])
        for change in ('required_null', 'unknown_null', 'public', 'force'):
            value = copy.deepcopy(proposal)
            if change == 'required_null': value['operations'][0]['arguments']['content'] = None
            elif change == 'unknown_null': value['operations'][0]['arguments']['unknown'] = None
            elif change == 'public': value['operations'][0]['arguments']['is_private'] = False
            else: value['operations'][0]['arguments']['force'] = True
            with self.subTest(change=change), self.assertRaises(ValueError): P.validate_proposal(value, **policy)

    def test_applied_without_memory_ids_never_grants_completion(self):
        plan = self.seal(self.operations[:1])
        request = J._json(J._unseal(plan['operations'][0]['request']))
        message = receipt_envelope(request)
        receipt = message['result']['structuredContent']['engram_operation']['receipt']
        receipt['memoryIDs'] = []
        message['result']['content'][0]['text'] = J.encode(message['result']['structuredContent']).decode()
        progress = self.execute(execute=lambda *_: message)
        self.assertEqual((progress['status'], progress['applied_write_calls'], progress['reason']),
                         ('pending', 0, 'native_reply_invalid'))
        # The common legacy shape validator alone accepts this shape. A corrupt
        # retained record must still fail the stronger whole-plan completion gate.
        J.record_response(self.run, request['operationID'], {'kind': 'committed', 'receipt': receipt},
                          verify_fence=self.writer.verify, atomic=True)
        with self.assertRaisesRegex(ValueError, 'applied_without_memory_ids'): E.inspect_plan(self.run)
        self.assertEqual(self.settle()['status'], 'reconciliation_required')

    def test_partial_and_lost_reply_resume_identical_ids_without_duplicate_effect(self):
        plan = self.seal()
        ids = [item['operation_id'] for item in plan['operations']]
        self.ledger.lose.add(ids[1])
        first = self.execute()
        self.assertEqual((first['status'], first['applied_write_calls']), ('pending', 1))
        self.assertFalse((self.run / 'settlement.json').exists())
        self.assertFalse((self.run / 'successful-coverage.json').exists())
        self.writer.close()
        self.writer = F.drain_and_acquire_shared(self.run, self.binding, validate=lambda *_: True)
        second = self.execute()
        self.assertEqual(second['status'], 'complete')
        self.assertEqual([op for op, _ in self.ledger.calls], [ids[0], ids[1], ids[1], ids[2]])
        self.assertEqual(self.ledger.effects, dict.fromkeys(ids, 1))
        self.assertEqual(self.ledger.calls[1][1], self.ledger.calls[2][1])
        final = self.settle()
        self.assertEqual((final['status'], final['applied_write_calls']), ('succeeded', 3))
        self.assertIsNotNone(final['coverage_reference'])

    def test_unknown_before_effect_keeps_plan_pending_and_uses_original_request(self):
        self.seal(self.operations[:1]); self.ledger.before_effect_failures = 1
        first = self.execute()
        self.assertEqual(first['status'], 'pending'); self.assertEqual(first['memory_ids'], [])
        self.assertEqual(S._compute(self.run, self.manifest, self.digest)['status'], 'pending')
        second = self.execute()
        self.assertEqual(second['status'], 'complete')
        self.assertEqual(self.ledger.calls[0], self.ledger.calls[1])
        self.assertEqual(sum(self.ledger.effects.values()), 1)

    def test_empty_completed_plan_has_coverage_without_mutations(self):
        self.seal([])
        self.assertEqual(self.execute()['status'], 'complete')
        self.assertEqual(self.ledger.calls, [])
        final = self.settle()
        self.assertEqual((final['status'], final['applied_write_calls'], final['unchanged_write_calls']), ('succeeded', 0, 0))

    def test_unsealed_provider_crash_is_failed_without_coverage(self):
        S.record_provider_dispatch(self.run, self.digest, lambda *_: True)
        final = self.settle()
        self.assertEqual((final['status'], final['reason']), ('failed', 'planning_not_complete'))
        self.assertIsNone(final['coverage_reference'])
        self.assertEqual(self.ledger.calls, [])

    def test_invalid_existing_plan_holds_instead_of_starting_new_plan(self):
        J._publish(self.run / P.PLAN_NAME, J.encode({'version': 1, 'corrupt': True}))
        final = self.settle()
        self.assertEqual(final['status'], 'reconciliation_required')
        self.assertIsNone(final['coverage_reference'])

    def test_known_receipt_retained_before_post_effect_authority_failure(self):
        self.seal()
        def validate(_manifest, phase): return phase != 'after_plan_response'
        with self.assertRaisesRegex(ValueError, 'input_validation_refused'): self.execute(validate=validate)
        progress = E.inspect_plan(self.run)
        self.assertEqual((progress['status'], progress['applied_write_calls']), ('pending', 1))
        self.assertEqual(len(self.ledger.calls), 1)

    def test_bad_native_response_is_unknown_never_absent_or_success(self):
        self.seal(self.operations[:1])
        def bad(raw, *_):
            message = receipt_envelope(J._json(raw))
            value = message['result']['structuredContent']['engram_operation']
            value['receipt']['operationID'] = OTHER
            message['result']['content'][0]['text'] = J.encode(message['result']['structuredContent']).decode()
            return message
        progress = self.execute(execute=bad)
        self.assertEqual((progress['status'], progress['applied_write_calls']), ('pending', 0))
        self.assertEqual(progress['reason'], 'native_reply_invalid')

    def test_applied_remember_auto_edges_settle_without_entering_memory_coverage(self):
        self.seal(self.operations[:1])
        def auto_connected(raw,*_):
            value=receipt_envelope(J._json(raw))
            value['result']['structuredContent']['engram_operation']['receipt']['edgeIDs']=[EDGE]
            value['result']['content'][0]['text']=J.encode(value['result']['structuredContent']).decode()
            return value
        progress=self.execute(execute=auto_connected)
        self.assertEqual((progress['status'],progress['memory_ids']),('complete',[MEMORY]))
        self.assertEqual(progress['operations'][0]['receipt']['edgeIDs'],[EDGE])
        final=self.settle()
        self.assertEqual((final['status'],final['applied_write_calls']),('succeeded',1))
        self.assertEqual(final['memory_ids'],[MEMORY])
        self.assertIsNotNone(final['coverage_reference'])

    def test_unchanged_commit_completes_without_claiming_new_memory(self):
        self.seal(self.operations[:1])
        progress = self.execute(execute=lambda raw, *_: receipt_envelope(J._json(raw), outcome='unchanged'))
        self.assertEqual((progress['status'], progress['unchanged_write_calls'], progress['memory_ids']), ('complete', 1, []))
        self.assertEqual(self.settle()['status'], 'succeeded')

    def test_atomic_publication_preserves_existing_and_ignores_unpublished_temp(self):
        target = self.run / 'fixture.json'; raw = J.encode({'complete': True})
        (self.run / '.plan-publish-abandoned').write_bytes(b'{partial')
        with mock.patch.object(J, '_boundary', side_effect=lambda phase: (_ for _ in ()).throw(SystemExit())
                               if phase == 'atomic_after_write' else None):
            with self.assertRaises(SystemExit): J._publish_atomic(target, raw)
        self.assertFalse(target.exists())
        J._publish_atomic(target, raw)
        identity = target.stat().st_ino
        J._publish_atomic(target, raw)
        self.assertEqual(target.stat().st_ino, identity)
        with self.assertRaisesRegex(ValueError, 'immutable_record_conflict'):
            J._publish_atomic(target, J.encode({'complete': False}))
        self.assertEqual(target.read_bytes(), raw)
        self.seal([])
        self.assertEqual(self.execute()['status'], 'complete')

    def test_atomic_plan_after_rename_reentry_retains_exact_whole_plan(self):
        planning_files(self.run, self.digest, self.operations)
        with mock.patch.object(J, '_boundary', side_effect=lambda phase: (_ for _ in ()).throw(SystemExit())
                               if phase == 'atomic_after_rename' else None):
            with self.assertRaises(SystemExit):
                P.seal_plan(self.run, verify_fence=self.writer.verify, validate_inputs=lambda *_: True)
        saved = (self.run / P.PLAN_NAME).read_bytes()
        self.assertEqual((self.run / P.PLAN_NAME).stat().st_nlink, 1)
        P.seal_plan(self.run, verify_fence=self.writer.verify, validate_inputs=lambda *_: True)
        self.assertEqual((self.run / P.PLAN_NAME).read_bytes(), saved)
        synced = set(); sync = J._sync_existing
        def observe(path, raw):
            result = sync(path, raw); synced.add(path.name); return result
        def execute(raw, writer, check):
            self.assertTrue(set(P.INPUTS) | {P.PLAN_NAME} <= synced)
            return self.ledger(raw, writer, check)
        with mock.patch.object(J, '_sync_existing', side_effect=observe):
            self.assertEqual(self.execute(execute=execute)['status'], 'complete')

    def test_lost_local_receipt_publication_recovers_exact_native_commit(self):
        self.seal(self.operations[:1])
        publish = J._publish_atomic
        def fail_response(path, raw):
            if path.parent.name.startswith('evidence-') and path.name == '000001.json':
                with mock.patch.object(J, '_boundary', side_effect=lambda phase: (_ for _ in ()).throw(SystemExit())
                                       if phase == 'atomic_after_file_fsync' else None):
                    return publish(path, raw)
            return publish(path, raw)
        with mock.patch.object(J, '_publish_atomic', side_effect=fail_response):
            with self.assertRaises(SystemExit): self.execute()
        self.assertEqual(sum(self.ledger.effects.values()), 1)
        self.assertEqual(E.inspect_plan(self.run)['status'], 'pending')
        self.assertEqual(self.execute()['status'], 'complete')
        self.assertEqual(sum(self.ledger.effects.values()), 1)
        self.assertEqual(self.ledger.calls[0], self.ledger.calls[1])

    def test_attempt_history_is_bounded_without_new_ids(self):
        self.seal(self.operations[:1]); self.ledger.before_effect_failures = 2
        with mock.patch.object(E, 'MAX_ATTEMPTS', 1):
            self.assertEqual(self.execute()['status'], 'pending')
            with self.assertRaisesRegex(ValueError, 'attempt_limit'): self.execute()
        self.assertEqual(len(self.ledger.calls), 1)


if __name__ == '__main__':
    unittest.main()
