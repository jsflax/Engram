"""Isolated candidate tests; every file/process is disposable under localdev."""
import copy
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

from residual_test_support import D, N, TEMP_ROOT, synthetic_review
J,F=D.J,D.F
STORE='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
MEMORY='11111111-2222-4333-8444-555555555555'

SERVER=r'''
import base64,fcntl,json,os,signal,sys
from pathlib import Path
root=Path(sys.argv[1]); scope=json.loads((root/'scope.json').read_text())
fd=os.environ.get('ENGRAM_WRITER_FENCE_FD')
if fd:
    fd=int(fd);binding=json.loads(base64.b64decode(os.environ['ENGRAM_WRITER_FENCE_BINDING_B64']))
    assert os.fstat(fd).st_ino==binding['lock_identity']['inode']
    assert os.fstat(fd).st_nlink==1
else:
    assert 'ENGRAM_WRITER_FENCE_BINDING_B64' not in os.environ
for line in sys.stdin:
    request=json.loads(line)
    if 'id' not in request: continue
    if request['method']=='initialize':
        result={'protocolVersion':request['params']['protocolVersion'],'capabilities':{'tools':{}},'serverInfo':{'name':'synthetic-residual','version':'1'}}
    else:
        name=request['params']['name'];args=request['params']['arguments']
        with (root/'calls.jsonl').open('a') as out: out.write(json.dumps({'tool':name,'arguments':args})+'\n')
        if name=='operation_scope': payload={'version':1,'kind':'scope','scope':scope,'capability':'localMutationOperationsV1'}
        elif name=='operation_status':
            assert fd is None
            p=root/('receipt-'+args['operationID']+'.json')
            payload={'version':1,'kind':'committed','receipt':json.loads(p.read_text())} if p.exists() else {'version':1,'kind':'absent','operationID':args['operationID'],'scope':scope}
        elif name=='operation_apply':
            assert fd is not None
            p=root/('receipt-'+args['operationID']+'.json')
            if p.exists(): receipt=json.loads(p.read_text())
            else:
                mode=(root/'mode').read_text() if (root/'mode').exists() else 'applied'
                if mode=='die_before': os.kill(os.getpid(),signal.SIGKILL)
                receipt={'version':1,'operationID':args['operationID'],'scope':scope,'payloadDigest':'d'*64,'mutation':'remember','outcome':'unchanged' if mode=='unchanged' else 'applied','memoryIDs':['11111111-2222-4333-8444-555555555555'],'edgeIDs':[],'committedAt':800000000.25}
                p.write_text(json.dumps(receipt))
                if mode=='die_after': os.kill(os.getpid(),signal.SIGKILL)
            payload={'version':1,'kind':'committed','receipt':receipt}
        else: raise AssertionError('unexpected tool')
        outer={'engram_operation':payload}
        result={'isError':False,'structuredContent':outer,'content':[{'type':'text','text':json.dumps(outer)}]}
    print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}),flush=True)
'''

class Fixture:
    def __init__(self):
        if TEMP_ROOT.is_symlink():raise RuntimeError('Residual fixture directory must not be a symlink')
        TEMP_ROOT.mkdir(mode=0o700,exist_ok=True)
        self.tmp=tempfile.TemporaryDirectory(prefix='residual-fixture-',dir=TEMP_ROOT)
        self.root=Path(self.tmp.name);self.run=self.root/'run';self.run.mkdir(mode=0o700)
        self.handles=[];self.bindings=[];self.dirs=[]
        self.writer=self.new_writer()
        self.plan=synthetic_review()
        self.scope={'version':1,'storeID':STORE,'principal':{'kind':'agent','groupIds':[],'scopes':[]}}
        (self.root/'scope.json').write_text(json.dumps(self.scope));(self.root/'server.py').write_text(SERVER)
        self.transport={'command':sys.executable,'args':['-B',str(self.root/'server.py'),str(self.root)],'cwd':str(self.root),'env':{}}
        inputs={name:J.seal_json(J.encode({'fixture':name})) for name in J.INPUT_NAMES}
        inputs['backend_route']=J.seal_json(J.encode({'transport':self.transport}))
        source=self.plan['source']
        self.manifest={'version':1,'host':'synthetic','session_id':self.plan['session_id'],'run_id':'residual-fixture',
            'inputs':inputs,'source':{'identity':source['identity'],'start_offset':source['start'],'end_offset':source['end'],'excerpt_sha256':source['excerpt_sha256']},'expected_scope':self.scope,
            'backend':{'route_id':'fixture','runtime_sha256':'b'*64,'route_sha256':inputs['backend_route']['sha256'],'config_sha256':inputs['backend_config']['sha256']},'fencing':self.bindings[0]}
        self.manifest_sha=J.publish_manifest(self.run,self.manifest,verify_fence=self.writer.verify)
        self.raw=J.encode(self.plan);self.review_sha=J.sha256(self.raw)
        self.validator=lambda *_:True
        self.driver=D.ResidualDriver.prepare(self.run,reviewed_raw=self.raw,reviewed_sha256=self.review_sha,
            manifest_sha256=self.manifest_sha,writer=self.writer,validate_inputs=self.validator)
        self.recoveries=[]
        self.limits=D.P.ProbeLimits(deadline_seconds=5,terminate_timeout_seconds=.1)
    def new_writer(self):
        import uuid
        directory=self.root/('fence-'+str(len(self.bindings)));directory.mkdir(mode=0o700)
        binding=F.create(directory,generation_id=str(uuid.uuid4()),owner_id=str(uuid.uuid4()))
        held=F.acquire_shared(directory,binding)
        self.dirs.append(directory);self.bindings.append(binding);self.handles.append(held)
        return held
    def revoke(self):
        self.writer.close(); index=len(self.recoveries)
        held=F.revoke(self.dirs[index],self.bindings[index],timeout_seconds=.1,validate=lambda *_:True)
        self.handles.append(held);self.recoveries.append(held);return held
    def execute(self,label='R1'):
        return self.driver.dispatch(label,writer=self.writer,recoveries=self.recoveries,
            execute=N.executor(self.driver,self.transport,limits=self.limits))
    def reconcile(self):
        return self.driver.reconcile(recoveries=self.recoveries,
            probe=N.status_probe(self.driver,self.transport,limits=self.limits))
    def continue_(self):
        self.writer=self.new_writer()
        return self.driver.continue_generation(recoveries=self.recoveries,new_writer=self.writer)
    def close(self):
        for h in reversed(self.handles):h.close()
        self.tmp.cleanup()

class ResidualTests(unittest.TestCase):
    def setUp(self):self.f=Fixture();self.addCleanup(self.f.close)
    def test_exact_all_seventeen_dispositions_and_five_original_requests(self):
        f=self.f;self.assertEqual(len(f.plan['message_dispositions']),17)
        for op in f.plan['operations']:
            _,raw,request=f.driver._intent(op['id'])
            self.assertEqual(request['mutation'],D.G.mutation('remember',op['arguments']))
            self.assertNotIn('expiresInDays',request['mutation']['request'])
        self.assertEqual(f.driver.summary()['memory_ids'],[])
        self.assertFalse((f.run/'successful-coverage.json').exists())
    def test_real_native_only_executor_and_all_applied_remain_publication_pending(self):
        f=self.f
        for label in f.driver.operations: result=f.execute(label)
        self.assertEqual(result['status'],'residuals_applied_reviewed_publication_pending')
        self.assertFalse(result['historical_provider_success']);self.assertFalse(result['cursor_authority'])
        calls=[json.loads(x)['tool'] for x in (f.root/'calls.jsonl').read_text().splitlines()]
        self.assertEqual(set(calls),{'operation_scope','operation_apply'})
        self.assertFalse((f.run/'provider-observation.json').exists())
    def test_lost_ack_commit_status_is_retained_never_replayed(self):
        f=self.f;(f.root/'mode').write_text('die_after')
        result=f.execute();self.assertEqual(result['memory_ids'],[])
        f.revoke();result=f.reconcile();self.assertEqual(result['memory_ids'],[MEMORY])
        old=f.driver._intent('R1')[1];f.continue_()
        with self.assertRaisesRegex(ValueError,'dispatch_not_authorized'):f.execute('R1')
        self.assertEqual(old,f.driver._intent('R1')[1])
        self.assertEqual(f.driver.summary()['committed'],['R1'])
    def test_absent_allows_explicit_new_generation_same_identity_bytes(self):
        f=self.f;(f.root/'mode').write_text('die_before');f.execute()
        operation,raw,_=f.driver._intent('R1')
        with self.assertRaisesRegex(ValueError,'current_generation_unsettled'):f.execute()
        with self.assertRaisesRegex(ValueError,'current_generation_unsettled'):f.execute('R2')
        f.revoke();f.reconcile();self.assertEqual(f.continue_(),1)
        (f.root/'mode').unlink();self.assertEqual(f.execute()['applied'],['R1'])
        self.assertEqual(f.driver._intent('R1')[:2],(operation,raw))
        events=J.read_evidence(f.run,operation)
        self.assertEqual(sum(e['evidence']['kind']=='dispatch' for e in events),1)
        self.assertTrue((f.run/'residual-dispatch-001-R1.json').exists())
    def test_absence_alone_and_shared_handle_never_authorize_continuation(self):
        f=self.f
        with self.assertRaisesRegex(ValueError,'all_prior_generations'): f.driver.continue_generation(recoveries=[],new_writer=f.new_writer())
        with self.assertRaisesRegex(ValueError,'revoked_exclusive'): f.driver.reconcile(recoveries=[f.writer],probe=lambda *_:[])
        f.revoke()
        with self.assertRaisesRegex(ValueError,"missing_file"):f.continue_()
    def test_unchanged_is_semantic_hold_not_coverage(self):
        f=self.f;(f.root/'mode').write_text('unchanged')
        result=f.execute();self.assertEqual(result['status'],'semantic_review_required');self.assertEqual(result['memory_ids'],[])
        with self.assertRaisesRegex(ValueError,'semantic_or_evidence_hold'):f.execute('R2')
        f.revoke();f.reconcile()
        with self.assertRaisesRegex(ValueError,'semantic_review_required'):f.continue_()
    def test_known_applied_ids_survive_later_invalid_operation_and_unavailable(self):
        f=self.f;f.execute()
        op=f.driver._intent('R1')[0]
        J.record_response(f.run,op,{'kind':'unavailable','reason':'backend_error'},verify_fence=f.writer.verify)
        path=f.run/('operation-'+f.driver._intent('R2')[0]+'.json');path.write_bytes(b'{')
        result=f.driver.summary()
        self.assertEqual(result['memory_ids'],[MEMORY]);self.assertEqual(result['invalid_operations'],['R2'])
        self.assertEqual(result['status'],'reconciliation_required')
    def test_later_malformed_status_preserves_earlier_validated_commits(self):
        f=self.f;f.execute();f.revoke()
        requests=[f.driver._intent(x)[2] for x in f.driver.operations]
        def probe(*_):
            receipt=J.read_evidence(f.run,requests[0]['operationID'])[-1]['evidence']
            return [receipt,{'kind':'committed','receipt':{}},*[{'kind':'absent','operationID':r['operationID'],'scope':f.scope} for r in requests[2:]]]
        with self.assertRaises(ValueError):f.driver.reconcile(recoveries=f.recoveries,probe=probe)
        self.assertEqual(f.driver.summary()['memory_ids'],[MEMORY])
        self.assertFalse((f.run/'residual-reconciliation-000.json').exists())
    def test_exact_true_validators_before_forward_and_after_response(self):
        for phase in ('before_dispatch','before_forward','after_response'):
            for bad in (False,None,1):
                with self.subTest(phase=phase,bad=bad):
                    f=Fixture()
                    try:
                        f.driver.validate_inputs=lambda _m,_p,p:bad if p==phase else True
                        executed=[]
                        def execute(*_):executed.append(True);return {}
                        if phase=='after_response':result=f.driver.dispatch('R1',writer=f.writer,recoveries=[],execute=execute);self.assertEqual(result['committed'],[])
                        else:
                            with self.assertRaises(ValueError):f.driver.dispatch('R1',writer=f.writer,recoveries=[],execute=execute)
                            self.assertEqual(executed,[])
                    finally:f.close()
    def test_missing_old_generation_after_second_continuation_refuses(self):
        f=self.f;f.revoke();f.reconcile();f.continue_();f.revoke();f.reconcile();f.continue_()
        with self.assertRaisesRegex(ValueError,'all_prior_generations'):f.driver.dispatch('R1',writer=f.writer,recoveries=f.recoveries[:1],execute=lambda *_:None)
    def test_manifest_review_intent_and_transport_mutations_refuse(self):
        f=self.f
        with self.assertRaisesRegex(ValueError,'transport_changed'):N.executor(f.driver,{**f.transport,'env':{'X':'Y'}})
        path=f.run/'residual-review.json';raw=path.read_bytes();path.write_bytes(raw+b' ')
        with self.assertRaisesRegex(ValueError,'input_pin_changed'):f.execute()
    def test_extra_operation_or_malformed_generation_refuses(self):
        f=self.f;(f.run/'operation-extra.json').write_bytes(b'{}')
        # The owned-file check may refuse the untrusted addition before inventory validation.
        with self.assertRaises(ValueError):f.execute()
    def test_policy_expiry_privacy_and_force_refuse_before_new_intents(self):
        f=self.f
        for key,value in [('expires_in_days',1),('force',True),('is_private',False)]:
            plan=copy.deepcopy(f.plan);plan['operations'][0]['arguments'][key]=value
            plan['operations'][0]['arguments_canonical_sha256']=J.sha256(J.encode(plan['operations'][0]['arguments']))
            with self.assertRaisesRegex(ValueError,'unsupported_residual_policy'):D._plan(plan)
    def test_postcommit_context_change_retains_actual_native_receipt_and_ids(self):
        f=self.f
        f.driver.validate_inputs=lambda _m,_p,phase:False if phase=='after_response' else True
        result=f.execute()
        self.assertEqual(result['memory_ids'],[MEMORY])
        self.assertEqual(result['committed'],['R1'])
        self.assertEqual(result['status'],'reconciliation_required')
        self.assertIs(result['current_inputs_validated'],False)
        events=J.read_evidence(f.run,f.driver._intent('R1')[0])
        self.assertEqual(events[-1]['evidence']['kind'],'committed')

    def test_applied_remember_without_one_memory_id_cannot_qualify(self):
        f=self.f;request=f.driver._intent('R1')[2]
        valid={'version':1,'operationID':request['operationID'],'scope':f.scope,'payloadDigest':'d'*64,
               'mutation':'remember','outcome':'applied','memoryIDs':[MEMORY],'edgeIDs':[],'committedAt':1}
        for ids,edges in (([],[]),([MEMORY],[STORE]),([MEMORY,STORE],[])):
            receipt={**valid,'memoryIDs':ids,'edgeIDs':edges}
            with self.assertRaisesRegex(ValueError,'invalid_remember_effect_ids'):
                D._response({'kind':'committed','receipt':receipt},request)

    def test_real_inherited_child_fence_prevents_premature_revocation(self):
        f=self.f;fd,=f.writer.pass_fds()
        child=subprocess.Popen([sys.executable,'-B','-c','import os,sys,time;os.fstat(int(sys.argv[1]));print("ready",flush=True);time.sleep(30)',str(fd)],pass_fds=(fd,),stdout=subprocess.PIPE)
        try:
            self.assertEqual(child.stdout.readline(),b'ready\n');f.writer.close()
            with self.assertRaisesRegex(ValueError,'busy'):F.revoke(f.dirs[0],f.bindings[0],timeout_seconds=.05,validate=lambda *_:True)
            child.kill();child.wait(timeout=5)
            f.revoke();self.assertTrue(f.recoveries[0].verify(f.bindings[0]))
        finally:
            if child.poll() is None:child.kill();child.wait(timeout=5)
            child.stdout.close()

if __name__=='__main__':unittest.main()
