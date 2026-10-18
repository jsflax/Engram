"""Retrospective accounting through real manifests/fences/coordinator, synthetic data only."""
import contextlib
import copy
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import types
import unittest
import uuid
from unittest import mock

from residual_context_fixture import ResidualContextFixture, RC as R, C, J, SID, SUCCESS_ID, write_json
from residual_test_support import runtime
from legacy_fixture import DUPLICATE_ID, RUN_ID, PREVIOUS_RUN

L, P, E, Q = runtime('legacy_reconciliation'), runtime('learner_plan'), runtime('planned_execution'), runtime('residual_publication')
F = R.F
import learner_residual as CLI


class AccountingFixture(ResidualContextFixture):
    def __init__(self, *, residuals=1, successes=1, missing_tail=False, project='A different project', parent=False):
        super().__init__()
        self.path.write_bytes(self.path.read_bytes()[:self.start])
        self.messages = [f'PRIVATE preserved statement {i}.' for i in range(successes)] + [
            f'PRIVATE permanent reviewed requirement {i}.' for i in range(residuals)] + ['PRIVATE dated progress only.']
        for body in self.messages: self.append(body)
        self.excerpt = C.transcript.read_excerpt(self.path, self.start, max_chars=16000, max_scan_bytes=65536,
            recent_messages=self.state['recent_messages'], current_turn_id=self.state['current_turn_id'], stable_identity=True)
        self.end = self.excerpt.next_offset
        self.rows = []
        preserve = []
        for i in range(successes):
            mid = SUCCESS_ID if i == 0 else str(uuid.uuid5(uuid.UUID(SUCCESS_ID), str(i)))
            row = self.base_fixture.memory(mid, self.messages[i])
            row.update(project=project, topic='reviewed', source='codex-session:' + SID,
                       expiresAt=64092211200.0, createdAt=1767429140.0, modifiedAt=1767429140.0)
            self.rows.append(row); preserve.append(mid)
        if parent:
            row = self.base_fixture.memory(DUPLICATE_ID, 'PRIVATE permanent parent requirement.')
            row.update(project=project, topic='parent', expiresAt=64092211200.0)
            self.rows.append(row)
        with contextlib.closing(sqlite3.connect(self.store)) as db:
            db.execute('DELETE FROM Memory')
            for row in self.rows:
                keys=tuple(row)
                db.execute('INSERT INTO Memory ('+','.join(keys)+') VALUES ('+','.join('?' for _ in keys)+')',tuple(row[k] for k in keys))
            db.commit()
        self.state['reconciliation_required']['memory_ids']=preserve
        self.record['state_sha256']=J.durable.object_digest(self.state)
        write_json(self.state_path,self.state);write_json(self.record_path,self.record)
        operations=[]
        for index in range(residuals):
            args={'content':self.messages[successes+index],'project':project,'topic':'reviewed',
                  'source':'codex-session:'+SID,'is_private':True,'force':False}
            if parent:args['parent_id']=DUPLICATE_ID
            operations.append({'id':f'op_{index+1}','tool':'remember','arguments':args,
                'arguments_canonical_sha256':J.sha256(J.encode(args)),'messages':[successes+index+1],
                'attempt_ids':[f'item_{successes+index+1}'],
                'duplicate_review':{'decision':'distinct_reviewed_fact','compared_memory_ids':[row['globalId'] for row in self.rows],
                                    'rationale':'Compared exact retained rows; this requirement is distinct.'}})
        provider=[{'type':'thread.started','thread_id':SID},{'type':'turn.started'}]
        audit=[{'event':'relay_started'}];attempts=[]
        for index in range(successes+residuals):
            successful=index<successes
            args=({'content':self.messages[index],'project':project,'topic':'reviewed','source':'codex-session:'+SID,
                   'is_private':True,'force':False} if successful else operations[index-successes]['arguments'])
            mid=preserve[index] if successful else None
            result=({'content':[{'type':'text','text':f'Stored memory (id: {mid}, project: {project}, topic: reviewed, private: true): '+args['content']}],
                     'structured_content':None} if successful else {'content':[{'type':'text','text':L.expired_update.BEGIN_BUSY_TEXT}],
                     'structured_content':{'engram_write_receipt':{'schema_version':1,'tool':'remember','memory_ids':[],
                        'reason':'database_busy','write_outcome':L.expired_update.NO_WRITE}}})
            item={'id':f'item_{index+1}','type':'mcp_tool_call','server':'memory','tool':'remember','arguments':args}
            provider.extend([{'type':'item.started','item':item},{'type':'item.completed','item':{
                **item,'status':'completed' if successful else 'failed','error':None,'result':result}}])
            event={'event':'tool_result','id':index+1,'tool':'remember','ok':successful,'memory_ids':[mid] if successful else [],'forwarded':True}
            if not successful:event.update(write_outcome_version=1,write_outcome=L.expired_update.NO_WRITE)
            audit.extend([{'event':'tool_call','id':index+1,'tool':'remember'},event])
            attempts.append({'item_id':item['id'],'audit_id':index+1,'tool':'remember','arguments':copy.deepcopy(args),
                'native_result_sha256':J.sha256(J.encode(result)),
                'disposition':'preserved_success' if successful else 'affirmative_no_write',
                'memory_ids':[mid] if successful else [],'operations':[] if successful else [operations[index-successes]['id']],
                'rationale':'Exact native acknowledgement or affirmative pre-transaction refusal.'})
        provider.append({'type':'turn.completed'})
        if not missing_tail:audit.append({'event':'relay_finished','child_reaped':True,'cleanup_overrun':False,'peak_inflight':1})
        run=J._json(self.history['run']);run.update(end_offset=self.end,tool_calls=len(attempts),write_calls=successes,
            writes=[{'tool':'remember','memory_ids':[v]} for v in preserve])
        self.history.update(run=J.encode(run),provider=b'\n'.join(J.encode(v) for v in provider)+b'\n',
                            audit=b'\n'.join(J.encode(v) for v in audit)+b'\n',transport=J.encode({
                'transport':{'command':'/nonexecuted/historical/native','args':[]},
                'audit_path':str(self.historical_run_dir/'mcp-audit.jsonl'),'provenance':'codex-session:'+SID,
                'allowed_tools':['remember','update'],'max_tool_calls':20,'max_writes':10}))
        for role,raw in self.history.items():
            path=self.historical_run_dir/L.ROLES[role];path.write_bytes(raw);path.chmod(0o644 if role=='result' else 0o600)
        previous=L._read_historical(self.root,PREVIOUS_RUN,'run')
        all_history={**self.history,'previous_run':previous}
        dispositions=[];position=self.start
        for index,body in enumerate(self.messages,1):
            with self.path.open('rb') as stream:
                stream.seek(position);raw=stream.readline()
            op=operations[index-successes-1]['id'] if successes<index<=successes+residuals else None
            dispositions.append({'index':index,'role':'assistant','sha256':J.sha256(('[ASSISTANT]\n'+body).encode()),
                'record':{'start_offset':position,'end_offset':position+len(raw),'sha256':J.sha256(raw)},
                'body':{'sha256':J.sha256(body.encode()),'chars':len(body)},
                'disposition':'preserved' if index<=successes else 'residual' if op else 'dated_progress',
                'memory_ids':[preserve[index-1]] if index<=successes else [],'operations':[op] if op else [],
                'attempt_ids':[f'item_{index}'] if index<=successes+residuals else [],
                'rationale':'Full bounded source reviewed; no additional durable fact remains unclassified.'})
            position+=len(raw)
        info=self.store.stat()
        self.plan={'schema_version':1,'kind':L.REVIEWED_ACCOUNTING,'status':'reviewed_candidate_not_live_dispatch_authority',
            'session_id':SID,'legacy_run_id':RUN_ID,'previous_run_id':PREVIOUS_RUN,
            'historical_request_id':self.request['historical_request_id'],
            'source':{'identity':self.request['identity'],'start':self.start,'end':self.end,
                'interval_sha256':J.sha256(self.path.read_bytes()[self.start:self.end]),
                'excerpt_sha256':J.sha256(self.excerpt.text.encode()),'parser_sha256':C._parser_runtime()['sha256']},
            'parser':{'input':C._parser_state(self.state),'next':C._next_parser(self.excerpt),'max_chars':16000,
                'record_count':len(self.messages),'diagnostics':self.excerpt.diagnostics},
            'history':{key:J.sha256(raw) for key,raw in all_history.items()},
            'rows':[{**{k:v for k,v in row.items() if k in L.ROW_FIELDS and k!='content'},
                    'content_sha256':J.sha256(row['content'].encode())} for row in self.rows],
            'row_content':{row['globalId']:row['content'] for row in self.rows},
            'store_identity':{'device':info.st_dev,'inode':info.st_ino,'uid':info.st_uid},
            'preserve_without_replay':{'memory_ids':preserve},'message_dispositions':dispositions,
            'attempts':attempts,'operations':operations,'qualifications':{'origin':'explicit_retrospective_full_review',
                'historical_run_status':'failed','historical_execution_sealed':False,
                'source_binding_grade':'current_bounded_reconstruction','current_cross_provider_capability':'unverified'}}
        self.refresh();self.calls=[];self.effects={};self.lose=set()

    def refresh(self):
        self.reviewed_raw=J.encode(self.plan);self.reviewed_sha256=J.sha256(self.reviewed_raw)

    def change_history(self,role,value):
        raw=(b'\n'.join(J.encode(v) for v in value)+b'\n' if role in ('provider','audit') else J.encode(value))
        self.history[role]=raw
        (self.historical_run_dir/L.ROLES[role]).write_bytes(raw)
        self.plan['history'][role]=J.sha256(raw)
        self.refresh()

    def retained(self):
        return {**self.history,'previous_run':L._read_historical(self.root,PREVIOUS_RUN,'run')}

    def append_ack(self,*,repeated=False):
        mid=self.plan['preserve_without_replay']['memory_ids'][0]
        append=self.messages[0];body='PRIVATE earlier fact.\n'+append
        if repeated:body+='\n'+append
        self.plan['row_content'][mid]=body
        self.plan['rows'][0]['content_sha256']=J.sha256(body.encode())
        with contextlib.closing(sqlite3.connect(self.store)) as db:
            db.execute('UPDATE Memory SET content=? WHERE globalId=?',(body,mid));db.commit()
        args={'id':mid,'append':append,'source':'codex-session:'+SID}
        provider=[J._json(line) for line in self.history['provider'].splitlines()]
        result={'content':[{'type':'text','text':f'Updated memory (id: {mid}, project: synthetic): '+append}],
                'structured_content':None}
        for event in provider[2:4]:event['item'].update(tool='update',arguments=args)
        provider[3]['item']['result']=result
        self.plan['attempts'][0].update(tool='update',arguments=args,native_result_sha256=J.sha256(J.encode(result)))
        audit=[J._json(line) for line in self.history['audit'].splitlines()]
        for event in audit[1:3]:event['tool']='update'
        run=J._json(self.history['run']);run['writes'][0]['tool']='update'
        self.change_history('provider',provider);self.change_history('audit',audit);self.change_history('run',run)

    def seal(self):
        self.context=R.seal_context(self.paths,reviewed_raw=self.reviewed_raw,reviewed_sha256=self.reviewed_sha256,
            evidence_directory=self.evidence,host='synthetic-fixture',scope=self.scope,writer=self.writer,
            max_chars=16000,max_scan_bytes=65536)
        return self.context

    def execute(self,raw,writer,check):
        writer.pass_fds();check('before_native_forward')
        request=J._json(raw);key=request['operationID'];self.calls.append((key,raw))
        if key not in self.effects:
            self.effects[key]=(raw,{'version':1,'operationID':key,'scope':self.scope,'payloadDigest':'d'*64,
                'mutation':'remember','outcome':'applied','memoryIDs':[str(uuid.uuid5(uuid.UUID(SUCCESS_ID),key))],
                'edgeIDs':[],'committedAt':800000000.25})
        assert self.effects[key][0]==raw
        if key in self.lose:self.lose.remove(key);raise TimeoutError('lost exact native response')
        value={'engram_operation':{'version':1,'kind':'committed','receipt':self.effects[key][1]}}
        return {'result':{'isError':False,'structuredContent':value,'content':[{'type':'text','text':J.encode(value).decode()}]}}

    def cli_args(self):
        return types.SimpleNamespace(root=self.root,session_id=SID,run_id=self.run_dir.name,
            manifest_sha256=self.context.manifest_sha256,context_sha256=self.context.context_sha256,
            review_sha256=self.reviewed_sha256,config=self.config,package_root=self.plugin,
            candidate_store=self.store,runtime_compatibility=None)


class ReviewedAccountingTests(unittest.TestCase):
    def fixture(self,**kwargs):
        f=AccountingFixture(**kwargs);self.addCleanup(f.close);return f

    def prepend_source_record(self, f, raw):
        original = f.path.read_bytes()
        f.path.write_bytes(original[:f.start] + raw + original[f.start:f.end])
        f.end += len(raw)
        f.excerpt = L.transcript.read_excerpt(f.path, f.start,
            max_chars=f.plan['parser']['max_chars'], max_scan_bytes=C.MAX_SCAN,
            recent_messages=f.state['recent_messages'], current_turn_id=f.state['current_turn_id'],
            stable_identity=True)
        f.plan['source'].update(end=f.end,
            interval_sha256=J.sha256(f.path.read_bytes()[f.start:f.end]),
            excerpt_sha256=J.sha256(f.excerpt.text.encode()))
        f.plan['parser'].update(next=C._next_parser(f.excerpt),
            record_count=len(f.messages)+1, diagnostics=f.excerpt.diagnostics)
        for message in f.plan['message_dispositions']:
            message['record']['start_offset'] += len(raw)
            message['record']['end_offset'] += len(raw)
        f.refresh()

    def test_source_coverage_accepts_large_excluded_record_without_expanding_report_limits(self):
        f=self.fixture()
        expected=f.excerpt.text; before=f.current(); history=f.history_snapshot()
        raw=json.dumps({'type':'compacted','payload':{'summary':'x'*(4*1024*1024)}}).encode()+b'\n'
        self.assertGreater(len(raw),L.MAX)
        self.assertLess(len(raw),C.MAX_SCAN)
        self.prepend_source_record(f,raw)
        with self.no_external(),mock.patch.object(sqlite3,'connect',side_effect=AssertionError('no database read')):
            excerpt,parser=R._source(f.plan,f.request,f.state,{},16000,C.MAX_SCAN)
            with self.assertRaisesRegex(ValueError,'execution_manifest_invalid_record_size'):
                L._json(raw)
            with self.assertRaisesRegex(ValueError,'execution_manifest_invalid_record_size'):
                J.seal_json(raw)
        self.assertEqual(excerpt.text,expected)
        self.assertEqual(excerpt.next_offset,f.end)
        self.assertEqual(excerpt.message_count,len(f.messages))
        self.assertEqual(excerpt.diagnostics['excluded_records'],1)
        self.assertEqual(C._next_parser(excerpt),f.plan['parser']['next'])
        self.assertEqual(parser['interval_sha256'],f.plan['source']['interval_sha256'])
        self.assertEqual(f.current(),before);self.assertEqual(f.history_snapshot(),history)
        self.assertEqual(f.calls,[])
        self.assertFalse((f.run_dir/'execution-manifest.json').exists())

    def test_excluded_source_records_keep_json_structure_and_complexity_guards(self):
        deep='0'
        for _ in range(34):deep='{"child":'+deep+'}'
        cases={
            'malformed':b'{"type":"compacted",\n',
            'non_object':b'[]\n',
            'depth':('{"type":"compacted","payload":'+deep+'}\n').encode(),
            'nodes':json.dumps({'type':'compacted','payload':[0]*100001}).encode()+b'\n',
            'nonfinite':b'{"type":"compacted","payload":NaN}\n',
        }
        for name,raw in cases.items():
            with self.subTest(case=name):
                f=self.fixture();before=f.current();history=f.history_snapshot()
                self.prepend_source_record(f,raw)
                with self.no_external(),mock.patch.object(sqlite3,'connect',side_effect=AssertionError('no database read')), \
                     self.assertRaises(ValueError):
                    R._source(f.plan,f.request,f.state,{},16000,C.MAX_SCAN)
                self.assertEqual(f.current(),before);self.assertEqual(f.history_snapshot(),history)
                self.assertEqual(f.calls,[])
                self.assertFalse((f.run_dir/'execution-manifest.json').exists())

    def test_source_interval_over_eight_mib_refuses_before_parsing(self):
        f=self.fixture();before=f.current();history=f.history_snapshot()
        raw=json.dumps({'type':'compacted','payload':'x'*(8*1024*1024)}).encode()+b'\n'
        original=f.path.read_bytes()
        f.path.write_bytes(original[:f.start]+raw+original[f.start:f.end])
        f.plan['source']['end'] += len(raw)
        f.plan['parser']['next']['offset'] += len(raw)
        f.plan['source']['interval_sha256']=J.sha256(f.path.read_bytes()[f.start:])
        f.refresh()
        scan=8*1024*1024
        self.assertGreater(f.plan['source']['end']-f.start,scan)
        with self.no_external(),mock.patch.object(sqlite3,'connect',side_effect=AssertionError('no database read')), \
             mock.patch.object(L.transcript,'read_excerpt',side_effect=AssertionError('oversized interval parsed')), \
             self.assertRaisesRegex(ValueError,'residual_context_parser_review_changed'):
            R._source(f.plan,f.request,f.state,{},16000,scan)
        # The existing absolute ceiling remains distinct from this run's budget.
        f.plan['source']['end']=f.start+C.MAX_SCAN+1
        with mock.patch.object(L.transcript,'read_excerpt',side_effect=AssertionError('oversized interval parsed')), \
             self.assertRaisesRegex(ValueError,'legacy_reconciliation_invalid_interval'):
            R._source(f.plan,f.request,f.state,{},16000,C.MAX_SCAN)
        self.assertEqual(f.current(),before);self.assertEqual(f.history_snapshot(),history)
        self.assertEqual(f.calls,[])
        self.assertFalse((f.run_dir/'execution-manifest.json').exists())

    def ci_interleaved_history(self, f, prose_kind='agent_message'):
        """Synthetic bytes with the retained CI's exact nine-call event order."""
        original=[J._json(v) for v in f.history['provider'].splitlines()]
        mutations=[copy.deepcopy(v['item']) for v in original if v['type']=='item.completed']
        first,second=mutations
        args={'id':f.plan['preserve_without_replay']['memory_ids'][0],
              'content':f.messages[0],'source':'codex-session:'+SID}
        first.update(id='item_7',tool='update',arguments=args)
        first['result']={'content':[{'type':'text','text':
            'Updated memory (id: '+args['id']+', project: synthetic): '+args['content']}],
            'structured_content':None}
        second['id']='item_10'
        for attempt,item,audit_id in zip(f.plan['attempts'],(first,second),(7,10)):
            attempt.update(item_id=item['id'],audit_id=audit_id,tool=item['tool'],
                arguments=copy.deepcopy(item['arguments']),native_result_sha256=J.sha256(J.encode(item['result'])))
        f.plan['message_dispositions'][0]['attempt_ids']=['item_7']
        f.plan['message_dispositions'][1]['attempt_ids']=['item_10']
        def prose(index,kind='agent_message'):
            return {'type':'item.completed','item':{'id':f'item_{index}','type':kind,
                'text':'Synthetic non-authoritative progress prose.'}}
        provider=[{'type':'thread.started','thread_id':SID},{'type':'turn.started'},prose(0)]
        audit=[{'event':'relay_started'}]
        for index in (1,2,3,4,6,7,8,9,10):
            if index==6:provider.append(prose(5))
            finish=copy.deepcopy(first if index==7 else second if index==10 else {
                'id':f'item_{index}','type':'mcp_tool_call','server':'memory','tool':'recall',
                'arguments':{'query':'synthetic'},'status':'completed','error':None,
                'result':{'content':[],'structured_content':None}})
            start={key:value for key,value in finish.items() if key not in ('result','error','status')}
            provider.append({'type':'item.started','item':{**start,'status':'in_progress','result':None}})
            if index==10:provider.append(prose(11,prose_kind))
            provider.append({'type':'item.completed','item':finish})
            audit.extend([{'event':'tool_call','id':index+1 if index<6 else index,'tool':finish['tool']},
                {'event':'tool_result','id':index+1 if index<6 else index,'tool':finish['tool'],'ok':True,
                 'memory_ids':[f.plan['preserve_without_replay']['memory_ids'][0 if index==7 else 1]]
                     if index in (7,10) else [],'forwarded':True}])
        # Recall item_6 uses audit id 6, so all original ids are 2 through 10.
        provider.extend([prose(12),{'type':'turn.completed'}])
        audit.append({'event':'relay_interrupted','signal':15})
        run=J._json(f.history['run']);run.update(tool_calls=9,write_calls=2,
            writes=[{'tool':item['tool'],'memory_ids':attempt['memory_ids']}
                    for item,attempt in zip((first,second),f.plan['attempts'])])
        transport=J._json(f.history['transport']);transport['allowed_tools']=['recall','remember','update']
        for role,value in (('run',run),('provider',provider),('audit',audit),('transport',transport)):
            f.change_history(role,value)
        return provider

    def test_completed_prose_between_ci_tool_start_and_ack_preserves_accounting(self):
        for kind in ('agent_message','reasoning'):
            with self.subTest(kind=kind):
                f=self.fixture(residuals=0,successes=2,missing_tail=True)
                self.ci_interleaved_history(f,kind)
                before=f.current();history=f.history_snapshot()
                with self.no_external():
                    result=L.accounting_history(f.plan,{k:L._sealed(v) for k,v in f.retained().items()})
                self.assertEqual(result,{'attempts':2,'relay_terminal_retained':False,'historical_execution_sealed':False})
                self.assertEqual(f.current(),before);self.assertEqual(f.history_snapshot(),history)
                self.assertEqual(f.plan['operations'],[]);self.assertEqual(f.calls,[])

    def test_pending_prose_does_not_relax_tool_pairing_or_unknown_frames(self):
        f=self.fixture(residuals=0,successes=2,missing_tail=True)
        baseline=self.ci_interleaved_history(f)
        for change in ('overlap','ack_id','ack_arguments','ack_result','unknown_item','unfinished_prose','extra_prose_field'):
            with self.subTest(change=change):
                provider=copy.deepcopy(baseline)
                message=next(i for i,event in enumerate(provider) if event.get('item',{}).get('id')=='item_11')
                ack=provider[message+1]['item']
                if change=='overlap':
                    provider[message]=copy.deepcopy(provider[message-1]);provider[message]['item']['id']='overlapping_call'
                elif change=='ack_id':ack['id']='different_call'
                elif change=='ack_arguments':ack['arguments']['content']='Changed after dispatch.'
                elif change=='ack_result':ack['result']['content'][0]['text']='Contradictory result.'
                elif change=='unknown_item':provider[message]['item']['type']='command_execution'
                elif change=='unfinished_prose':provider[message]['type']='item.started'
                else:provider[message]['item']['unexpected']='not allowed'
                f.change_history('provider',provider)
                with self.no_external(),self.assertRaises(ValueError):
                    L.accounting_history(f.plan,{k:L._sealed(v) for k,v in f.retained().items()})
                self.assertEqual(f.plan['operations'],[]);self.assertEqual(f.calls,[])

    @contextlib.contextmanager
    def no_external(self):
        with contextlib.ExitStack() as stack:
            for module,name in ((subprocess,'Popen'),(subprocess,'run'),(socket,'socket'),(os,'system')):
                stack.enter_context(mock.patch.object(module,name,side_effect=AssertionError('native/provider/network forbidden')))
            yield

    def complete(self,f):
        f.writer.close()
        with self.no_external(),CLI.Coordination(f.root).worker() as locks, \
             mock.patch.object(E,'native_executor',return_value=f.execute):
            return CLI._execute(f.cli_args(),locks)

    def test_varied_complete_reviews_account_successes_without_replay(self):
        for residuals,successes in ((0,2),(1,1),(3,2)):
            with self.subTest(residuals=residuals,successes=successes):
                f=self.fixture(residuals=residuals,successes=successes,missing_tail=True,project=f'Project {residuals}')
                before=f.current();history=f.history_snapshot();f.seal()
                self.assertEqual(f.current(),before)
                result=self.complete(f)
                self.assertEqual(result['applied_write_count'],residuals)
                self.assertEqual(len(f.effects),residuals)
                self.assertEqual(f.history_snapshot(),history)
                state=J._json(f.state_path.read_bytes())
                self.assertEqual(state['offset'],f.end);self.assertNotIn('reconciliation_required',state)
                self.assertEqual(state['last_residual_reconciliation']['preserved_memory_ids'],f.plan['preserve_without_replay']['memory_ids'])
                self.assertEqual(f.pending_path.read_bytes(),before[2])
                for name in ('provider-dispatch.json','provider-observation.json','successful-coverage.json'):
                    self.assertFalse((f.run_dir/name).exists())

    def test_unknown_or_incomplete_attempt_and_message_coverage_refuses(self):
        for change in ('unknown','missing_attempt','missing_message','orphan_call','parent_shared','temporary','forged_result'):
            f=self.fixture(parent=True)
            with self.subTest(change=change):
                if change=='unknown':f.plan['attempts'][-1]['disposition']='unknown'
                elif change=='missing_attempt':f.plan['attempts'].pop()
                elif change=='missing_message':f.plan['message_dispositions'].pop()
                elif change=='parent_shared':f.plan['rows'][-1]['isPrivate']=0
                elif change=='temporary':f.plan['operations'][0]['arguments']['expires_in_days']=7
                else:
                    path=f.historical_run_dir/'mcp-audit.jsonl';rows=[J._json(v) for v in path.read_bytes().splitlines()]
                    if change=='orphan_call':rows.insert(-1,{'event':'tool_call','id':99,'tool':'remember'})
                    else:rows[-2].pop('write_outcome')
                    raw=b'\n'.join(J.encode(v) for v in rows)+b'\n';path.write_bytes(raw);f.plan['history']['audit']=J.sha256(raw)
                f.refresh();before=f.current()
                with self.no_external(),self.assertRaises(ValueError):f.seal()
                self.assertEqual(f.current(),before);self.assertEqual(f.calls,[])

    def test_reversed_preserved_inventory_prepares_and_publishes_without_replay(self):
        for residuals in (0,1):
            with self.subTest(residuals=residuals):
                f=self.fixture(residuals=residuals,successes=2,missing_tail=True)
                f.plan['preserve_without_replay']['memory_ids']=list(reversed(
                    f.plan['preserve_without_replay']['memory_ids']));f.refresh()
                before=f.current();history=f.history_snapshot();review=f.reviewed_raw
                self.assertNotEqual(J._json(before[0])['reconciliation_required']['memory_ids'],
                                    f.plan['preserve_without_replay']['memory_ids'])
                review_path=f.base/'reversed-review.json';review_path.write_bytes(review);review_path.chmod(0o600)
                f.writer.close()
                args=types.SimpleNamespace(root=f.root,session_id=SID,
                    run_id='20260103T084600Z-'+uuid.uuid4().hex,config=f.config,package_root=f.plugin,
                    candidate_store=f.store,review=review_path,review_sha256=f.reviewed_sha256,
                    evidence_directory=f.evidence,runtime_compatibility=None)
                with self.no_external(),CLI.Coordination(f.root).worker() as locks, \
                     mock.patch.object(CLI.operation_probe,'probe_scope',return_value=f.scope) as scope:
                    prepared=CLI._prepare(args,locks)
                self.assertEqual(scope.call_count,1)
                self.assertEqual(prepared['status'],'prepared')
                self.assertEqual(prepared['memory_mutations_requested'],0)
                self.assertEqual(f.current(),before);self.assertEqual(review_path.read_bytes(),review)
                args.manifest_sha256=prepared['manifest_sha256'];args.context_sha256=prepared['context_sha256']
                f.run_dir=f.root/'runs'/args.run_id;f.paths=CLI._paths(args,args.run_id);f.context=CLI._load(args)
                self.assertEqual(f.context.manifest['inputs']['cursor']['sha256'],J.sha256(before[0]))
                result=self.complete(f)
                self.assertEqual(result['applied_write_count'],residuals)
                self.assertEqual(len(f.calls),residuals);self.assertEqual(len(f.effects),residuals)
                self.assertEqual(f.history_snapshot(),history);self.assertEqual(review_path.read_bytes(),review)
                self.assertEqual(f.pending_path.read_bytes(),before[2])
                state=J._json(f.state_path.read_bytes())
                self.assertEqual(state['offset'],f.end);self.assertNotIn('reconciliation_required',state)
                self.assertEqual(state['last_residual_reconciliation']['preserved_memory_ids'],
                                 f.plan['preserve_without_replay']['memory_ids'])
                for name in ('provider-dispatch.json','provider-observation.json','successful-coverage.json'):
                    self.assertFalse((f.run_dir/name).exists())

    def test_preserved_inventory_set_matching_rejects_invalid_or_changed_gate(self):
        f=self.fixture(residuals=0,successes=2)
        original=copy.deepcopy(f.state);record=copy.deepcopy(f.record)
        for change in ('missing','extra','duplicate','uppercase','malformed','not_list','run','reason','extra_key'):
            with self.subTest(change=change):
                state=copy.deepcopy(original);gate=state['reconciliation_required'];ids=gate['memory_ids']
                if change=='missing':ids.pop()
                elif change=='extra':ids.append(str(uuid.uuid4()))
                elif change=='duplicate':ids.append(ids[0])
                elif change=='uppercase':
                    upper=ids[1].upper();self.assertNotEqual(upper,ids[1]);ids[1]=upper
                elif change=='malformed':ids[0]='not-a-uuid'
                elif change=='not_list':gate['memory_ids']={str(i):v for i,v in enumerate(ids)}
                elif change=='run':gate['run_id']=PREVIOUS_RUN
                elif change=='reason':gate['reason']='different_reason'
                else:gate['unreviewed']=True
                write_json(f.state_path,state)
                write_json(f.record_path,{**record,'state_sha256':J.durable.object_digest(state)})
                before=f.current()
                with self.no_external(),self.assertRaises(ValueError):f.seal()
                self.assertEqual(f.current(),before);self.assertEqual(f.calls,[])
                self.assertFalse((f.run_dir/'execution-manifest.json').exists())

    def test_lost_response_resumes_same_plan_once_and_keeps_hold_until_complete(self):
        f=self.fixture(residuals=2,parent=True);f.seal()
        with f.locks() as verify:Q.begin(f.context,writer=f.writer,verify_locks=verify)
        plan,_=P.read_plan(f.run_dir);lost=plan['operations'][0]['operation_id'];f.lose.add(lost)
        with self.no_external():
            result=E.execute_plan(f.run_dir,writer=f.writer,
                validate_inputs=lambda m,p:f.context.validate_inputs(m,f.plan,p),execute=f.execute)
        self.assertEqual(result['status'],'pending');self.assertEqual(len(f.effects),1)
        self.assertEqual(J._json(f.state_path.read_bytes())['offset'],f.start)
        f.writer.close()
        with f.locks() as verify,self.no_external():
            result=Q.recover_locked(f.paths,session_id=SID,verify_locks=verify)
        self.assertEqual(result['status'],'reviewed_plan_pending');self.assertEqual(len(f.calls),1)
        result=self.complete(f)
        self.assertEqual(result['applied_write_count'],2);self.assertEqual(len(f.effects),2)
        self.assertEqual(f.calls[0],f.calls[1])

    def test_changed_authority_source_parent_or_preserved_row_blocks_forward(self):
        for target in ('source','policy','parent','preserved'):
            f=self.fixture(parent=True);f.seal();before=f.current()
            if target=='source':f.path.write_bytes(f.path.read_bytes().replace(b'permanent reviewed',b'changedxx reviewed'))
            elif target=='policy':write_json(f.root/'admission.json',{**f.policy,'enabled':False})
            else:
                with contextlib.closing(sqlite3.connect(f.store)) as db:
                    db.execute('UPDATE Memory SET isPrivate=0 WHERE globalId=?',(DUPLICATE_ID if target=='parent' else SUCCESS_ID,));db.commit()
            with self.subTest(target=target),self.no_external(),self.assertRaises(ValueError):self.complete(f)
            self.assertEqual(f.current(),before);self.assertEqual(f.calls,[])

    def test_known_commit_is_retained_before_postcheck_failure(self):
        f=self.fixture();f.seal()
        with f.locks() as verify:Q.begin(f.context,writer=f.writer,verify_locks=verify)
        def validate(m,phase):
            if phase=='after_plan_response':raise ValueError('changed after native commit')
            return f.context.validate_inputs(m,f.plan,phase)
        with self.no_external(),self.assertRaises(ValueError):
            E.execute_plan(f.run_dir,writer=f.writer,validate_inputs=validate,execute=f.execute)
        self.assertEqual(E.inspect_plan(f.run_dir)['applied_write_calls'],1)
        self.assertEqual(J._json(f.state_path.read_bytes())['offset'],f.start)

    def test_publication_crash_and_newer_pending_recover_without_replay(self):
        f=self.fixture();f.seal()
        with f.locks() as verify:Q.begin(f.context,writer=f.writer,verify_locks=verify)
        E.execute_plan(f.run_dir,writer=f.writer,validate_inputs=lambda m,p:f.context.validate_inputs(m,f.plan,p),execute=f.execute)
        f.writer.close();newer,_=f.newer_pending()
        original=Q.PJ._boundary
        observed=[]
        def crash(label):
            if label=='admission_replaced':observed.append(label);raise RuntimeError('fixture crash')
            original(label)
        with f.locks() as verify,self.no_external(),mock.patch.object(Q.PJ,'_boundary',side_effect=crash),self.assertRaises(RuntimeError):
            Q.recover_locked(f.paths,session_id=SID,verify_locks=verify)
        self.assertEqual(observed,['admission_replaced'])
        with f.locks() as verify,self.no_external():
            Q.recover_locked(f.paths,session_id=SID,verify_locks=verify)
        self.assertEqual(f.pending_path.read_bytes(),newer);self.assertEqual(len(f.calls),1)
        self.assertEqual(J._json(f.state_path.read_bytes())['offset'],f.end)

    def test_append_parent_and_reconciliation_pause_use_existing_publication(self):
        f=self.fixture(parent=True,missing_tail=True);f.append_ack()
        pending=J._json(f.pending_path.read_bytes())
        pending.update(paused_request_id=pending['request_id'],pause_reason='reconciliation_required')
        write_json(f.pending_path,pending)
        before=f.pending_path.read_bytes();old=f.history_snapshot();f.seal()
        result=self.complete(f)
        self.assertEqual(result['applied_write_count'],1)
        self.assertEqual(len(f.effects),1)
        exact=J._json(f.calls[0][1]);self.assertEqual(exact['mutation']['request']['parentId'],DUPLICATE_ID)
        self.assertEqual(f.pending_path.read_bytes(),before);self.assertEqual(f.history_snapshot(),old)
        self.assertEqual(J._json(f.state_path.read_bytes())['offset'],f.end)

    def test_expired_no_write_and_covered_duplicate_never_become_executable(self):
        for disposition in ('expired','covered'):
            with self.subTest(disposition=disposition):
                f=self.fixture();attempt=f.plan['attempts'][-1];message=f.plan['message_dispositions'][1]
                f.plan['operations']=[];attempt['operations']=[];message['operations']=[];message['disposition']=disposition
                if disposition=='expired':
                    attempt['disposition']='expired_no_write';attempt['arguments']['expires_in_days']=1
                    provider=[J._json(v) for v in f.history['provider'].splitlines()]
                    for event in provider[4:6]:event['item']['arguments']=copy.deepcopy(attempt['arguments'])
                    f.change_history('provider',provider)
                else:message['memory_ids']=[SUCCESS_ID]
                f.refresh();f.seal();result=self.complete(f)
                self.assertEqual(result['applied_write_count'],0);self.assertEqual(f.calls,[])
                self.assertEqual(J._json(f.state_path.read_bytes())['offset'],f.end)

    def test_historical_projection_and_gateway_contradictions_refuse(self):
        for change in ('status','text','boolean_version','provenance','budget','inventory','repeated_append','missing_attempt_link','duplicate_payload'):
            with self.subTest(change=change):
                f=self.fixture()
                if change in ('status','text','boolean_version'):
                    provider=[J._json(v) for v in f.history['provider'].splitlines()]
                    finish=provider[-2]['item']
                    if change=='status':finish['status']='completed'
                    else:
                        if change=='text':finish['result']['content'][0]['text']='Contradictory acknowledgement.'
                        else:finish['result']['structured_content']['engram_write_receipt']['schema_version']=True
                        f.plan['attempts'][-1]['native_result_sha256']=J.sha256(J.encode(finish['result']))
                    f.change_history('provider',provider)
                elif change in ('provenance','budget'):
                    value=J._json(f.history['transport'])
                    if change=='provenance':value['provenance']='unbound'
                    else:value['max_writes']=0
                    f.change_history('transport',value)
                elif change=='inventory':
                    value=J._json(f.history['run']);value['write_calls']=0;f.change_history('run',value)
                elif change=='repeated_append':f.append_ack(repeated=True)
                elif change=='missing_attempt_link':f.plan['message_dispositions'][1]['attempt_ids']=[]
                else:
                    args=f.plan['operations'][0]['arguments'];args['content']=f.plan['row_content'][SUCCESS_ID]
                    f.plan['operations'][0]['arguments_canonical_sha256']=J.sha256(J.encode(args))
                    f.plan['attempts'][-1]['arguments']=copy.deepcopy(args)
                f.refresh()
                with self.no_external(),self.assertRaises(ValueError):L.accounting_history(f.plan,f.retained())
                self.assertEqual(f.calls,[])

    def test_semantic_cache_is_bound_to_the_exact_sealed_review(self):
        f=self.fixture();f.seal();cache={}
        with mock.patch.object(L,'accounting_history',wraps=L.accounting_history) as checked:
            for _ in range(2):R.historical(f.paths,f.plan,{},f.context.value['history'],verified=cache)
            self.assertEqual(checked.call_count,1)
            changed=copy.deepcopy(f.plan);changed['attempts'][-1]['native_result_sha256']='0'*64
            with self.assertRaises(ValueError):R.historical(f.paths,changed,{},f.context.value['history'],verified=cache)
            self.assertEqual(checked.call_count,2)
        f.context.plan['message_dispositions'][0]['rationale']='Substituted after sealing.'
        with self.no_external(),self.assertRaisesRegex(ValueError,'review_plan_changed'):f.context.validate_marker()
        self.assertEqual(f.calls,[])

    def test_worker_pending_review_defers_without_dispatch_or_cursor_change(self):
        f=self.fixture();f.seal()
        with f.locks() as verify:Q.begin(f.context,writer=f.writer,verify_locks=verify)
        f.writer.close();before=f.current()
        RP=runtime('runner_publication')
        with f.locks() as verify,self.no_external():
            service=RP.Publications(f.root,f.config,f.plugin,
                residual_paths=lambda run:f.paths,residual_verify_locks=verify)
            result=service.recover(SID,{})
        self.assertIsInstance(result,RP.Continuation)
        self.assertEqual(result.request_id,f.request['request_id'])
        self.assertEqual(f.current(),before);self.assertEqual(f.calls,[])
        self.assertEqual(self.complete(f)['applied_write_count'],1)


if __name__=='__main__':unittest.main()
