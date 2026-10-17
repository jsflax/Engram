"""One disposable hybrid fixture for integrated reviewed residual acceptance.

Uses the repository's V2 enrollment/SQLite scaffold. The pinned header-bearing
runtime is never executed; strict fixture receipts qualify orchestration only.
"""
from __future__ import annotations
import contextlib
import copy
import importlib
import json
import os
from pathlib import Path
import sqlite3
import sys
import uuid
from unittest import mock

from residual_test_support import D, PLUGIN_ROOT, runtime, synthetic_review
from legacy_fixture import LegacyFixture, load_runtime, SID, RUN_ID, PREVIOUS_RUN, SUCCESS_ID, write_json
RC = runtime('residual_context')
J, F, C = D.J, D.F, RC.C
MAX_CHARS, MAX_SCAN = 16000, 65536
STORE_ID = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
MAPPING = {1:'R2', 2:'R2', 12:'R3', 14:'R3', 15:'R4', 16:'R5', 17:'R1'}


class ResidualContextFixture:
    def __init__(self, *, fixture_parent=None):
        self.base_fixture = f = LegacyFixture(load_runtime(), fixture_parent=fixture_parent)
        for name in ('base','root','sessions','project','evidence','path','state_path','record_path',
                     'pending_path','enrollment_path','state','record','request','policy','enrollment',
                     'frontier','start','store','row_values'):
            setattr(self, name, getattr(f, name))
        self.historical_run_dir = f.run_dir
        self.handles, self.recoveries = [], []
        self.path.write_bytes(self.path.read_bytes()[:self.start])
        self.messages = [f'PRIVATE synthetic reviewed assistant finding {index:02d}.' for index in range(1,18)]
        for message in self.messages: f.append(message)
        self.excerpt = C.transcript.read_excerpt(self.path, self.start,
            max_chars=MAX_CHARS, max_scan_bytes=MAX_SCAN,
            recent_messages=self.state['recent_messages'], current_turn_id=self.state['current_turn_id'],
            stable_identity=True)
        self.end = self.excerpt.next_offset
        self.run_dir = self.root / 'runs' / ('20260103T084500Z-' + uuid.uuid4().hex)
        self.run_dir.mkdir(mode=0o700)
        (self.run_dir/'workspace').mkdir(mode=0o700)
        self.runtime = self.base/'native-fixture'
        self.runtime.write_bytes(b'\xcf\xfa\xed\xfe' + b'nonexecuted-header-fixture'*8)
        self.runtime.chmod(0o700)
        self.plugin = PLUGIN_ROOT
        self.config = self.base/'config.toml'
        self.config.write_text('[mcp_servers.memory]\ncommand = '+json.dumps(str(self.runtime))+
            '\nargs = []\ndefault_tools_approval_mode = "approve"\n[mcp_servers.memory.env]\nCLAUDE_MEMORY_DB = '+
            json.dumps(str(self.store))+'\n')
        self.config.chmod(0o600)
        write_json(self.root/'settings.json', {'max_chars':MAX_CHARS,'max_scan_bytes':MAX_SCAN})
        self.paths = RC.ResidualPaths(self.root,self.run_dir,self.config,self.plugin,self.store)
        self.binding = F.create(self.run_dir,generation_id=str(uuid.uuid4()),owner_id=str(uuid.uuid4()))
        self.writer = F.acquire_shared(self.run_dir,self.binding)
        self.handles.append(self.writer)
        self.scope = {'version':1,'storeID':STORE_ID,'principal':{'kind':'agent','groupIds':[],'scopes':[]}}
        self.plan = synthetic_review()
        self.plan.update(session_id=SID,legacy_run_id=RUN_ID,
            exact_rows_inspected=[SUCCESS_ID],prior_successful_runs=[PREVIOUS_RUN])
        self.plan['preserve_without_replay']={'tool':'update','memory_ids':[SUCCESS_ID],'messages_represented':[11,13]}
        self.plan['source']={'identity':self.enrollment['identity'],'start':self.start,'end':self.end,
            'interval_sha256':J.sha256(self.path.read_bytes()[self.start:self.end]),
            'excerpt_sha256':J.sha256(self.excerpt.text.encode()),
            'parser_sha256':C._parser_runtime()['sha256'],'visible_messages':17}
        self.plan['message_dispositions']=[]
        for index,message in enumerate(self.messages,1):
            item={'index':index,'segment_sha256':J.sha256(message.encode())}
            if index in MAPPING: item.update(disposition='reviewed_residual',operations=[MAPPING[index]])
            elif index in (11,13): item.update(disposition='preserved_applied_update',memory_ids=[SUCCESS_ID])
            else:item.update(disposition='dated_progress_no_new_durable_fact')
            self.plan['message_dispositions'].append(item)
        for op in self.plan['operations']:
            op['arguments']={'project':'Engram','topic':'learner-recovery',
                'content':'PRIVATE exact synthetic residual '+op['id']+'.','source':'codex-session:'+SID,
                'is_private':True,'force':False}
            op['arguments_canonical_sha256']=J.sha256(J.encode(op['arguments']))
        self.append_text='PRIVATE historical append retained exactly once.'
        self.row_values[0]['content']='PRIVATE original fixture fact.\n'+self.append_text
        self.row_values[0].update(project='Engram',topic='learner-recovery')
        with contextlib.closing(sqlite3.connect(self.store)) as db:
            db.execute('UPDATE Memory SET content=?,project=?,topic=? WHERE globalId=?',
                (self.row_values[0]['content'],'Engram','learner-recovery',SUCCESS_ID));db.commit()
        self.history,self.intents=self.make_history()
        for role,raw in self.history.items():
            target=self.historical_run_dir/self.base_fixture.L.ROLES[role]
            target.write_bytes(raw);target.chmod(0o644 if role=='result' else 0o600)
        self.make_reports()

    def make_history(self):
        provider=[{'type':'thread.started','thread_id':SID},{'type':'turn.started'}]
        audit=[{'event':'relay_started'},{'event':'initialize_compat'}]
        intents=[]
        tools=['recall','recall','recall','update','remember']
        for rpc,tool in enumerate(tools,2):
            args=({'query':'synthetic retained context'} if tool=='recall' else
                  {'id':SUCCESS_ID,'append':self.append_text,'source':'codex-session:'+SID} if tool=='update' else
                  copy.deepcopy(self.plan['operations'][0]['arguments']))
            item={'id':'item_'+str(rpc-1),'type':'mcp_tool_call','server':'memory','tool':tool,'arguments':args}
            result={'content':[{'type':'text','text':'Synthetic retained read.'}]}
            if tool=='update':result={'content':[{'type':'text','text':'Updated memory '+SUCCESS_ID}]}
            if tool=='remember':result={'structured_content':{'engram_write_receipt':{
                'schema_version':1,'tool':'remember','memory_ids':[],'reason':'database_busy',
                'write_outcome':'not_stored_transaction_not_started'}}}
            completed={**item,'result':result,'error':None,'status':'completed'}
            provider.extend([{'type':'item.started','item':item},{'type':'item.completed','item':completed}])
            observed={'event':'tool_result','id':rpc,'tool':tool,'ok':tool!='remember','memory_ids':[SUCCESS_ID] if tool=='update' else [],'forwarded':True}
            if tool=='remember': observed.update(write_outcome='not_stored_transaction_not_started',write_outcome_version=1)
            audit.extend([{'event':'tool_call','id':rpc,'tool':tool},observed])
            if tool in ('update','remember'):
                intents.append({'tool':tool,'provider_item':item['id'],'audit_id':rpc,
                    'provider_arguments':args,'gateway_arguments':args,
                    'gateway_arguments_sha256':J.sha256(J.encode(args)),
                    'audit_result':observed,'provider_completion':completed})
        provider.append({'type':'turn.completed'})
        audit.extend([{'event':'relay_interrupted'},{'event':'relay_finished','peak_inflight':1,'child_reaped':True,'cleanup_overrun':False}])
        run={'session_id':SID,'status':'failed','reason':'unverified_completion',
            'request_id':self.request['historical_request_id'],'started_at':'2026-01-03T08:32:00Z',
            'ended_at':'2026-01-03T08:33:21Z','end_offset':self.end,'returncode':0,
            'tool_calls':5,'write_calls':1,'tool_errors':1,'turn_completed':True,
            'provider_error':False,'unexpected_tool':False,'writes':[{'tool':'update','memory_ids':[SUCCESS_ID]}]}
        return {'run':J.encode(run),'result':J.encode({'outcome':'stored','summary':'PRIVATE retained synthetic result','memory_ids':[SUCCESS_ID]}),
            'audit':b'\n'.join(J.encode(x) for x in audit)+b'\n',
            'provider':b'\n'.join(J.encode(x) for x in provider)+b'\n',
            'transport':J.encode({'command':'never-execute-old-transport'})},intents

    def make_reports(self):
        reports={}
        def put(name,value,raw=False):
            data=value if raw else J.encode(value)
            (self.evidence/name).write_bytes(data);(self.evidence/name).chmod(0o600)
            reports[name]=data
            return J.sha256(data)
        source=self.plan['source']
        common={'schema_version':1,'session_id':SID,'run_id':RUN_ID}
        put('current-chat-write-intents.private.json',{**common,'intents':self.intents})
        put('current-chat-coverage-excerpt.private.txt',self.excerpt.text.encode(),raw=True)
        put('current-chat-coverage-parser.private.json',{'before':{**C._parser_state(self.state),'identity':self.enrollment['identity']},
            'after':{**C._next_parser(self.excerpt),'identity':self.enrollment['identity']}})
        info=self.store.stat()
        readback={'store':str(self.store),'device':info.st_dev,'inode':info.st_ino,'access':'read-only',
            'updated_memory':self.row_values[0],'append_occurrences':1,'queries':[]}
        put('current-chat-readback.private.json',readback)
        put('current-chat-specific-duplicates.private.json',{**common,'rows':[]})
        put('current-chat-fresh-hold-assessment.json',{**common,'read_only':True,'run':J._json(self.history['run']),
            'cursor':self.state,'audit':[J._json(x) for x in self.history['audit'].splitlines()]})
        put('current-chat-bounded-diagnosis.json',{**common,'read_only':True,'source':source,
            'inputs':{role:{'sha256':J.sha256(raw),'bytes':len(raw)} for role,raw in self.history.items()},
            'update_uuid':SUCCESS_ID,'append_observed_exactly_once':True,'new_mutations':0,'cursor_advanced':False})
        put('current-chat-prior-success-readback.private.json',{'schema_version':1,'session_id':SID,
            'access':'read-only','provider_or_native_invoked':False,'live_mutations':0,
            'store_identity':{'device':info.st_dev,'inode':info.st_ino,'uid':info.st_uid},'receipts':[],
            'rows':[{**self.row_values[0],'content_sha256':J.sha256(self.row_values[0]['content'].encode())}]})
        put('current-chat-independent-residual-review.json',{**common,'kind':'synthetic_independent_residual_review',
            'inputs':{name:{'sha256':J.sha256(reports[name]),'bytes':len(reports[name])} for name in RC.NESTED},
            'source':source,'messages':self.plan['message_dispositions']})
        self.plan['approved_proposal_sha256']=J.sha256(J.encode({k:v for k,v in self.plan.items() if k not in ('retained_inputs','review_adoption_sha256')}))
        dispositions=[]
        for item in self.plan['message_dispositions']:
            kind=item['disposition']
            dispositions.append({'index':item['index'],'disposition':
                'selected_residual' if kind=='reviewed_residual' else 'represented_by_preserved_update' if kind=='preserved_applied_update' else 'dated_plan_test_build_or_separate_reconciliation_progress',
                'operation':item['operations'][0] if kind=='reviewed_residual' else None,
                'memory_ids':[SUCCESS_ID] if kind=='preserved_applied_update' else []})
        adoption={**common,'kind':'assistant_reviewed_residual_selection',
            'proposal_sha256':self.plan['approved_proposal_sha256'],'selected_operations':[
                {'id':v['id'],'arguments_sha256':v['arguments_canonical_sha256']} for v in self.plan['operations']],
            'message_dispositions':dispositions,'new_mutations_performed':0,'cursor_changes':0}
        self.plan['review_adoption_sha256']=put('current-chat-residual-review-adoption.json',adoption)
        self.plan['retained_inputs']={name:J.sha256(reports[name]) for name in RC.TOP}
        self.reviewed_raw=J.encode(self.plan);self.reviewed_sha256=J.sha256(self.reviewed_raw)
        self.reports=reports

    def close(self):
        for held in reversed(self.handles):held.close()
        self.base_fixture.close()

    def current(self):return tuple(p.read_bytes() for p in (self.state_path,self.record_path,self.pending_path))
    def history_snapshot(self):return self.base_fixture.history_snapshot()
    def append(self,text):self.base_fixture.append(text)
    def newer_pending(self):return self.base_fixture.newer_pending()

    def seal(self,*,prepare_driver=True):
        self.context = RC.seal_context(self.paths,reviewed_raw=self.reviewed_raw,reviewed_sha256=self.reviewed_sha256,
            evidence_directory=self.evidence,host='synthetic-fixture',scope=self.scope,writer=self.writer,
            max_chars=MAX_CHARS,max_scan_bytes=MAX_SCAN)
        self.driver = (D.ResidualDriver.prepare(self.run_dir,reviewed_raw=self.reviewed_raw,
            reviewed_sha256=self.reviewed_sha256,manifest_sha256=self.context.manifest_sha256,
            writer=self.writer,validate_inputs=self.context.validate_inputs) if prepare_driver else None)
        return self.context

    @contextlib.contextmanager
    def locks(self):
        with J.durable.Locks(self.root) as held:
            def verify():
                held.verify()
                return True
            yield verify

    def revoke(self):
        self.writer.close()
        held=F.revoke(self.run_dir,self.binding,timeout_seconds=.5,validate=lambda *_:True)
        self.handles.append(held);self.recoveries.append(held)
        return held

    def begin(self,verify):
        RP = runtime('residual_publication')
        self.driver=RP.begin(self.context,writer=self.writer,verify_locks=verify)
        return self.driver

    def receipt_path(self,operation):return self.base/('synthetic-native-receipt-'+operation+'.json')

    def execute(self,raw,writer,check):
        """Trusted synthetic commit; never execute the pinned header fixture."""
        request=J._json(raw);operation=request['operationID']
        writer.verify(writer.binding());check('before_synthetic_commit')
        receipt_path=self.receipt_path(operation)
        if receipt_path.exists():
            raise AssertionError('Fixture forbids a second native apply for any operation')
        memory_id=str(uuid.uuid5(uuid.UUID(STORE_ID),operation))
        row=copy.deepcopy(self.row_values[0]);args=request['mutation']['request']
        row.update(globalId=memory_id,content=args['content'],source=args['source'],project=args['project'],
                   topic=args['topic'],expiresAt=None,deletedAt=None,createdAt=800000000.25,modifiedAt=800000000.25)
        with contextlib.closing(sqlite3.connect(self.store)) as db:
            columns=tuple(row)
            db.execute('INSERT INTO Memory ('+','.join(columns)+') VALUES ('+','.join('?' for _ in columns)+')',
                       tuple(row[name] for name in columns));db.commit()
        receipt={'version':1,'operationID':operation,'scope':self.scope,'payloadDigest':'d'*64,
                 'mutation':'remember','outcome':'applied','memoryIDs':[memory_id],'edgeIDs':[],
                 'committedAt':800000000.25}
        write_json(receipt_path,receipt)
        outer={'engram_operation':{'version':1,'kind':'committed','receipt':receipt}}
        return {'jsonrpc':'2.0','id':operation,'result':{'isError':False,'structuredContent':outer,
                'content':[{'type':'text','text':json.dumps(outer)}]}}

    def dispatch(self,label):
        return self.driver.dispatch(label,writer=self.writer,recoveries=self.recoveries,execute=self.execute)

    def status_probe(self,requests,recovery,check):
        recovery.verify(recovery.binding());check('before_synthetic_status')
        result=[]
        for request in requests:
            path=self.receipt_path(request['operationID'])
            result.append({'kind':'committed','receipt':J._json(path.read_bytes())} if path.exists() else
                          {'kind':'absent','operationID':request['operationID'],'scope':self.scope})
        check('after_synthetic_status')
        return result

    @contextlib.contextmanager
    def synthetic_probe(self):
        RP = runtime('residual_publication')
        with mock.patch.object(RP.N,'status_probe',return_value=self.status_probe):yield

    def finish(self,verify):
        RP = runtime('residual_publication')
        with self.synthetic_probe():
            return RP.finish(self.context,recoveries=self.recoveries,verify_locks=verify)

    def rows(self):
        with contextlib.closing(sqlite3.connect(self.store)) as db:
            db.row_factory=sqlite3.Row
            return [dict(row) for row in db.execute('SELECT * FROM Memory ORDER BY globalId')]

    def release_fences(self):
        for held in reversed(self.handles):held.close()
        self.recoveries=[]

    def child_spec(self):
        value={'paths':{name:str(getattr(self.paths,name)) for name in
                       ('root','run_dir','config_path','plugin_root','candidate_store')},
               'manifest_sha256':self.context.manifest_sha256,'context_sha256':self.context.context_sha256,
               'base':str(self.base),'scope':self.scope,'binding':self.binding,'row_values':self.row_values}
        path=self.base/'residual-child-spec.json';write_json(path,value);return path

    @classmethod
    def from_child_spec(cls,path):
        """Hydrate only retained fixture coordinates; no setup or external writes."""
        value=J._json(path.read_bytes());obj=cls.__new__(cls)
        obj.base=Path(value['base']);obj.scope=value['scope'];obj.binding=value['binding']
        obj.row_values=value['row_values'];obj.paths=RC.ResidualPaths(**{key:Path(val) for key,val in value['paths'].items()})
        obj.run_dir=obj.paths.run_dir;obj.root=obj.paths.root;obj.store=obj.paths.candidate_store
        obj.context=RC.load_context(obj.paths,manifest_sha256=value['manifest_sha256'],context_sha256=value['context_sha256'])
        obj.handles=[];obj.recoveries=[]
        return obj
