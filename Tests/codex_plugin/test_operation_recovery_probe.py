"""Real synthetic stdio children and durable fences; no installed native store."""
import copy
import importlib
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import time
import unittest
from unittest import mock

from suite_support import PLUGIN_ROOT
sys.path.insert(0, str(PLUGIN_ROOT / "scripts"))
S = importlib.import_module("codex_learner.settlement")
J, F, G, P = S.journal, S.writer_fence, S.gateway, S.operation_probe
STORE = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
MEMORY = "11111111-2222-4333-8444-555555555555"
SID = "01900000-0000-7000-8000-000000000001"

SERVER = r'''
import fcntl, json, os, signal, sys, time
from pathlib import Path
config = json.loads(Path(sys.argv[1]).read_text())
root = Path(sys.argv[1]).parent
assert 'ENGRAM_WRITER_FENCE_FD' not in os.environ
assert 'ENGRAM_WRITER_FENCE_BINDING_B64' not in os.environ
identity = os.stat(root / 'writer.lock')
for candidate in range(3, 256):
    try: item = os.fstat(candidate)
    except OSError: continue
    assert (item.st_dev, item.st_ino) != (identity.st_dev, identity.st_ino)
fd = os.open(root / 'writer.lock', os.O_RDONLY)
try:
    fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
except BlockingIOError: pass
else: raise AssertionError('parent does not hold exclusive fence')
os.close(fd)
def read():
    raw = sys.stdin.readline()
    if not raw: sys.exit(0)
    value = json.loads(raw)
    with (root / 'calls.jsonl').open('a') as out: out.write(json.dumps(value) + '\n')
    return value
def emit(request, result):
    print(json.dumps({'jsonrpc':'2.0', 'id':request['id'], 'result':result}), flush=True)
def envelope(payload):
    outer = {'engram_operation':payload}
    return {'isError':payload['kind']=='error','structuredContent':outer,
            'content':[{'type':'text','text':json.dumps(outer)}]}
request = read()
assert request['method'] == 'initialize'
emit(request, {'protocolVersion':request['params']['protocolVersion'],'capabilities':{'tools':{}},
               'serverInfo':{'name':'recovery-fixture','version':'1'}})
assert read()['method'] == 'notifications/initialized'
request = read()
assert request['params'] == {'name':'operation_scope','arguments':{}}
emit(request, envelope({'version':1,'kind':'scope','capability':'localMutationOperationsV1','scope':config['scope']}))
for operation in config['operations']:
    request = read()
    assert request['method'] == 'tools/call'
    assert request['params'] == {'name':'operation_status','arguments':{
        'operationID':operation,'scope':config['requested_scope']}}
    mode = config.get('mode', 'valid')
    if mode == 'delay': time.sleep(60)
    if mode == 'death': os.kill(os.getpid(), signal.SIGKILL)
    if mode == 'malformed':
        print('private invalid output', flush=True); time.sleep(60)
    if mode == 'wrong_id': request['id'] += 1
    result = envelope({'version':1, **config['responses'][operation]})
    if mode == 'conflicting_text': result['content'][0]['text'] = '{}'
    if mode == 'duplicate':
        raw = json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}).encode() + b'\n'
        os.write(1, raw + raw)
    else: emit(request, result)
if config.get('mode') == 'ignore_term':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(60)
'''


class RecoveryProbeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="operation-recovery-")
        self.addCleanup(temporary.cleanup)
        self.run = Path(temporary.name).resolve()
        self.binding = F.create(self.run, generation_id=STORE, owner_id=MEMORY)
        self.writer = F.acquire_shared(self.run, self.binding)
        self.addCleanup(self.writer.close)
        self.recovery = None
        self.script, self.config = self.run / "server.py", self.run / "server.json"
        self.script.write_text(SERVER)
        self.transport = {"command": sys.executable, "args": ["-B", str(self.script), str(self.config)],
                          "cwd": str(self.run), "env": {}}
        values = {name: {"fixture":name} for name in J.INPUT_NAMES}
        values["backend_route"] = {"transport":self.transport}
        values["request"] = {"session_id":SID,"request_id":"fixture-request", "admission":{"session_id":SID}}
        values["parser_state"] = {"version":1,"input":{"offset":10},"limits":{"max_chars":24000},
                                  "runtime":{"sha256":"b"*64},"interval_sha256":"c"*64}
        values["next_parser_state"] = {"offset":20}
        inputs = {name:J.seal_json(J.encode(value)) for name,value in values.items()}
        self.scope = {"version":1,"storeID":STORE,"principal":{"kind":"agent","groupIds":[],"scopes":[]}}
        self.manifest = {"version":1,"host":"fixture","session_id":SID,"run_id":"fixture-run",
            "inputs":inputs,"expected_scope":self.scope,"source":{
                "identity":{"scheme":"macos_volume_uuid_inode_v1","volume_uuid":STORE,"inode":123},
                "start_offset":10,"end_offset":20,"excerpt_sha256":"a"*64},
            "backend":{"route_id":"fixture","runtime_sha256":"b"*64,
                       "route_sha256":inputs["backend_route"]["sha256"],"config_sha256":inputs["backend_config"]["sha256"]},
            "fencing":self.binding}
        self.digest = J.publish_manifest(self.run,self.manifest,verify_fence=self.writer.verify)
        self.gateway = G.OperationGateway(self.run,manifest_sha256=self.digest,writer_fence=self.writer,
                                          validate_inputs=lambda *_:True)
        self.requests, self.responses = [], {}
        self.prepare()
        self.limits = P.ProbeLimits(deadline_seconds=2,terminate_timeout_seconds=0.05)
        self.children = []
        cleanup = P.bridge._cleanup
        def observed_cleanup(child,timeout):
            self.children.append(child)
            result = cleanup(child,timeout)
            self.assertTrue(result['child_reaped'])
            return result
        patch = mock.patch.object(P.bridge,'_cleanup',side_effect=observed_cleanup)
        patch.start(); self.addCleanup(patch.stop)

    def prepare(self):
        operation,_ = self.gateway.prepare(len(self.requests)+1,'remember',{
            'content':'private fixture','source':'fixture','is_private':True})
        self.requests.append(J.read_intent(self.run,operation)[1])
        self.responses[operation] = {'kind':'committed','receipt':{
            'version':1,'operationID':operation,'scope':self.scope,'payloadDigest':'d'*64,
            'mutation':'remember','outcome':'applied','memoryIDs':[MEMORY],'edgeIDs':[], 'committedAt':800000000.25}}
        return operation

    def revoke(self):
        if self.recovery is None:
            self.writer.close()
            self.recovery = F.revoke(self.run,self.binding,validate=lambda *_:True)
            self.addCleanup(self.recovery.close)
        return self.recovery

    def configure(self,**extra):
        self.config.write_text(json.dumps({'scope':self.scope,'requested_scope':self.scope,
            'operations':[r['operationID'] for r in self.requests], 'responses':self.responses, **extra}))

    def probe(self,**extra):
        self.configure(**extra)
        return P.probe_statuses(self.transport,recovery_fence=self.revoke(),expected_binding=self.binding,
            expected_scope=self.scope,requests=self.requests,validate_inputs=lambda *_:True,limits=self.limits)

    def reconcile(self,validate=None,**extra):
        self.configure(**extra)
        return S.reconcile_statuses(self.run,manifest_sha256=self.digest,recovery_fence=self.revoke(),
            transport=self.transport,validate_inputs=validate or (lambda *_:True),limits=self.limits)

    def kinds(self,operation=None):
        operation = operation or self.requests[0]['operationID']
        return [event['evidence']['kind'] for event in J.read_evidence(self.run,operation)]

    def test_only_scope_status_without_inherited_descriptor_and_parent_ex_retained(self):
        self.prepare()
        second = self.requests[1]['operationID']
        self.responses[second] = {'kind':'absent','operationID':second,'scope':self.scope}
        result = self.probe()
        self.assertEqual([r['kind'] for r in result],['committed','absent'])
        calls = [json.loads(line) for line in (self.run/'calls.jsonl').read_text().splitlines()]
        self.assertEqual([v['params']['name'] for v in calls if v['method']=='tools/call'],
                         ['operation_scope','operation_status','operation_status'])
        self.assertTrue(self.recovery.verify(self.binding))
        self.assertTrue(all(c.poll() is not None for c in self.children))
        self.assertEqual(self.kinds(),['dispatch'])

    def test_scope_id_mutation_and_receipt_shape_must_match(self):
        operation = self.requests[0]['operationID']
        valid = copy.deepcopy(self.responses[operation])
        for change in ('scope','operationID','mutation','payloadDigest','outcome','memoryIDs','extra'):
            with self.subTest(change=change):
                value = copy.deepcopy(valid)
                value['receipt'][change] = {'scope':{**self.scope,'storeID':MEMORY},'operationID':MEMORY,
                    'mutation':'update','payloadDigest':'bad','outcome':'maybe','memoryIDs':[False],'extra':True}[change]
                self.responses[operation] = value
                with self.assertRaises(P.ProbeError): self.probe()
        self.responses[operation] = valid
        with self.assertRaisesRegex(P.ProbeError,'scope_changed'):
            self.probe(scope={**self.scope,'storeID':MEMORY})

    def test_absence_binding_error_protocol_and_actual_child_death_never_append(self):
        operation = self.requests[0]['operationID']
        valid = copy.deepcopy(self.responses[operation])
        for response in ({'kind':'absent','operationID':MEMORY,'scope':self.scope},
                         {'kind':'absent','operationID':operation,'scope':{**self.scope,'storeID':MEMORY}},
                         {'kind':'error','code':'storage_unavailable'}):
            self.responses[operation] = response
            with self.assertRaises(P.ProbeError): self.reconcile()
            self.assertEqual(self.kinds(),['dispatch'])
        self.responses[operation] = valid
        for mode in ('malformed','wrong_id','conflicting_text','duplicate','death'):
            with self.subTest(mode=mode), self.assertRaises(P.ProbeError) as raised:
                self.reconcile(mode=mode)
            self.assertNotIn('private',str(raised.exception))
            self.assertEqual(self.kinds(),['dispatch'])

    def test_deadline_refuses_all_observations(self):
        self.limits = P.ProbeLimits(deadline_seconds=0.2,terminate_timeout_seconds=0.05)
        start = time.monotonic()
        with self.assertRaisesRegex(P.ProbeError,'deadline'): self.reconcile(mode='delay')
        self.assertLess(time.monotonic()-start,2)
        self.assertEqual(self.kinds(),['dispatch'])

    def test_cleanup_failure_refuses_all_observations(self):
        # Keep normal probe time for this independent failure injection. The
        # deadline test's 0.2s limit can mask cleanup on a loaded host.
        cleanup = P.bridge._cleanup
        def failed(child,timeout):
            result = cleanup(child,timeout)
            return {**result,'cleanup_failed':True}
        with mock.patch.object(P.bridge,'_cleanup',side_effect=failed):
            with self.assertRaisesRegex(P.ProbeError,'cleanup_failed'): self.reconcile()
        self.assertEqual(self.kinds(),['dispatch'])

    def test_validator_exact_true_at_launch_response_cleanup_and_append(self):
        for target in ('before_probe_launch','after_probe_status','after_probe_cleanup','before_status_evidence'):
            for refused in (False,None,1):
                with self.subTest(target=target,refused=refused):
                    with self.assertRaises((ValueError,P.ProbeError)):
                        self.reconcile(validate=lambda _m,p: refused if p==target else True)
                    self.assertEqual(self.kinds(),['dispatch'])

    def test_closed_or_shared_fence_and_reserved_environment_prevent_launch(self):
        self.configure()
        with self.assertRaisesRegex(P.ProbeError,'writer_unfenced'):
            P.probe_statuses(self.transport,recovery_fence=self.writer,expected_binding=self.binding,
                expected_scope=self.scope,requests=self.requests,validate_inputs=lambda *_:True)
        self.revoke().close()
        with self.assertRaises(ValueError): self.reconcile()
        self.assertEqual(self.children,[])

    def test_ambient_fence_environment_is_removed_and_transport_override_refused(self):
        with mock.patch.dict(os.environ, {'ENGRAM_WRITER_FENCE_FD':'77',
                                         'ENGRAM_WRITER_FENCE_BINDING_B64':'untrusted'}):
            self.assertEqual(self.probe()[0]['kind'],'committed')
        self.transport['env']['ENGRAM_WRITER_FENCE_FD'] = '77'
        with self.assertRaises(P.ProbeError): self.probe()
        self.assertEqual(len(self.children),1)

    def test_fence_closed_after_scope_prevents_status_and_no_evidence_is_appended(self):
        def closed(_manifest,phase):
            if phase == 'after_probe_scope': self.recovery.close()
            return True
        with self.assertRaises((ValueError,P.ProbeError)): self.reconcile(validate=closed)
        self.assertEqual(self.kinds(),['dispatch'])
        calls = [json.loads(line) for line in (self.run/'calls.jsonl').read_text().splitlines()]
        self.assertEqual([v['params']['name'] for v in calls if v['method']=='tools/call'], ['operation_scope'])

    def test_committed_recovery_is_durable_but_missing_provider_outcome_cannot_create_coverage(self):
        counts = self.reconcile()
        self.assertEqual(counts,{'requested':1,'committed':1,'absent':0,'already_committed':0})
        self.assertEqual(self.kinds(),['dispatch','committed'])
        self.assertEqual(self.reconcile(),{'requested':0,'committed':0,'absent':0,'already_committed':1})
        self.assertEqual(len(self.children),1)
        result = S.settle(self.run,manifest_sha256=self.digest,recovery_fence=self.recovery,validate_inputs=lambda *_:True)
        self.assertEqual(result['status'],'reconciliation_required')
        self.assertEqual(result['applied_write_calls'],1)
        self.assertFalse((self.run/'successful-coverage.json').exists())
        with self.assertRaisesRegex(ValueError,'already_settled'): self.reconcile()

    def test_absent_and_unchanged_never_grant_replay_or_success(self):
        operation = self.requests[0]['operationID']
        self.responses[operation] = {'kind':'absent','operationID':operation,'scope':self.scope}
        self.assertEqual(self.reconcile()['absent'],1)
        self.assertEqual(self.kinds(),['dispatch','absent'])
        with self.assertRaisesRegex(ValueError,'redispatch'):
            J.record_dispatch(self.run,operation,verify_fence=self.recovery.verify)
        self.responses[operation] = {'kind':'committed','receipt':{'version':1,'operationID':operation,
            'scope':self.scope,'payloadDigest':'d'*64,'mutation':'remember','outcome':'unchanged',
            'memoryIDs':[MEMORY],'edgeIDs':[],'committedAt':800000000.25}}
        self.assertEqual(self.reconcile()['committed'],1)
        result = S.settle(self.run,manifest_sha256=self.digest,recovery_fence=self.recovery,validate_inputs=lambda *_:True)
        self.assertEqual(result['status'],'reconciliation_required')
        self.assertEqual(result['applied_write_calls'],0)
        self.assertEqual(result['unchanged_write_calls'],1)

    def test_sealed_route_and_manifest_integrity_are_checked_before_launch(self):
        self.transport['env']['OVERRIDE'] = 'unsealed'
        with self.assertRaisesRegex(ValueError,'backend_route_changed'): self.reconcile()
        self.assertEqual(self.children,[])

    def test_evidence_mutation_during_probe_and_append_refuses_success(self):
        operation = self.requests[0]['operationID']
        path = self.run / ('operation-'+operation+'.json')
        original = path.read_bytes()
        def changed(_manifest,phase):
            if phase == 'after_probe_status': path.write_bytes(original+b' ')
            return True
        with self.assertRaises((ValueError,P.ProbeError)): self.reconcile(validate=changed)
        self.assertEqual(len(list((self.run/('evidence-'+operation)).iterdir())),1)

    def test_request_limit_duplicates_and_unknown_response_fields_refuse(self):
        self.configure()
        for requests in ([], self.requests*2, self.requests*33):
            with self.assertRaises(P.ProbeError):
                P.probe_statuses(self.transport,recovery_fence=self.revoke(),expected_binding=self.binding,
                    expected_scope=self.scope,requests=requests,validate_inputs=lambda *_:True)
        operation = self.requests[0]['operationID']
        self.responses[operation]['unknown'] = True
        with self.assertRaises(P.ProbeError): self.reconcile()


if __name__ == '__main__': unittest.main()
