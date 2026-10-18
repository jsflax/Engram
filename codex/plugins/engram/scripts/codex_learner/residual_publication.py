"""Qualified retrospective publication for a reviewed fresh residual execution.

No provider-success or successful-coverage evidence is created. Ordinary learner
settlement and expired-only reconciliation remain separate. Caller owns worker
coordination; every cursor/admission mutation additionally requires a live enqueue guard.
"""
from __future__ import annotations
import copy
import contextlib
import os
from pathlib import Path
import uuid
from . import publication_journal as PJ
from . import publication_coordinator as Q
from . import admission as A, execution_manifest as J, execution_context as C, writer_fence as F
from . import residual_context as R
from . import residual_driver as D
from . import native_executor as N
from . import learner_plan as LP, planned_execution as PE

KIND='legacy_residual'
RESULT='legacy_reconciled_with_residuals'
NAMESPACE=uuid.UUID('c41afc2a-7c64-44b7-9c69-6f2dfe8ca1a6')


def require(value,reason):
    if not value:raise ValueError('residual_publication_'+reason)
def same(a,b):return J.encode({'value':a})==J.encode({'value':b})
def boundary(label):pass

def _guard(check):require(callable(check) and check() is True,'caller_locks_changed')
def _read(path,*,maximum=J.MAX_INPUT):
    raw,_=J.durable._read(path,maximum=maximum)
    return J._json(raw),J.sha256(raw)
def _paths(root,sid,*,create=False):
    A._uuid(sid,7);names=A.state_paths(root,sid)
    if create:J.durable._mkdir(root/'publications')
    return Q.Paths(names['sessions'],names['admissions'],names['pending'],root/'publications'/sid)
def _active(root,sid):
    J.durable._directory(root)
    if not os.path.lexists(root/'publications'):return None
    return Q._active(_paths(root,sid),sid)
def _pin(context):
    return {'run_id':context.run_id,'manifest_sha256':context.manifest_sha256,'context_sha256':context.context_sha256,
            'review_sha256':context.review_sha256}
def _work(context):return context.paths.run_dir
def _ticket(context,purpose):
    return str(uuid.UUID(bytes=uuid.uuid5(NAMESPACE,context.context_sha256+purpose).bytes,version=4))

def _authorization(context):
    value,digest=_read(_work(context)/'residual-authorization.json')
    if R.reviewed(context.plan):
        plan,plan_sha=LP.read_plan(context.paths.run_dir)
        expected={'version':1,'kind':KIND,**_pin(context),'plan_origin':R.L.REVIEWED_ACCOUNTING,
            'plan_sha256':plan_sha,'operation_ids':[item['operation_id'] for item in plan['operations']],
            'max_generations':1}
    else:
        expected={'version':1,'kind':KIND,**_pin(context),
            'operation_ids':[J.operation_id(context.paths.run_dir,D.G.call_key(x)) for x in ('R1','R2','R3','R4','R5')],
            'max_generations':D.MAX_GENERATIONS}
    require(same(value,expected),'authorization_changed')
    return value,digest

def _evidence(context):
    return {'kind':KIND,**_pin(context),'authorization_sha256':_authorization(context)[1]}

def _marker(context):
    ref,_=_read(_work(context)/'processing-publication.json',maximum=65536)
    J._keys(ref,{'ticket_id','ticket_sha256'})
    completed=Q.read_completed(_paths(context.paths.root,context.plan['session_id']),
        session_id=context.plan['session_id'],**ref)
    expected=_evidence(context)
    require(same(completed['ticket']['input_evidence'],expected)
            and same(completed['ticket']['run_evidence'],expected)
            and completed['ticket']['outcome']=={'result':'processing','queue_action':'none','pause_reason':None}
            and PJ._raw(completed['publication']['records']['state']['old'],old=True)
                ==J._unseal(context.manifest['inputs']['cursor']),'marker_changed')
    return ref,completed


def _current_pair(context,view):
    selected=_paths(context.paths.root,context.plan['session_id']);plan=view['publication']
    path=selected.session_directory/'journals'/view['ticket_id']/'published.json'
    if not os.path.lexists(path):
        PJ._positions(plan,PJ.Paths(selected.state,selected.admission,path.parent));return True
    expected={'schema_version':1,'kind':PJ.KIND,'status':'published','transition_id':view['ticket_id'],
        'session_id':view['session_id'],'request_id':view['request_id'],'prepared_sha256':view['prepared_sha256'],
        'admission_sha256':plan['records']['admission']['new']['sha256'],
        'state_sha256':plan['records']['state']['new']['sha256']}
    require(J.durable._read(path)[0]==J.durable.encode(expected),'published_receipt_changed')
    require(J.durable._read(selected.state)[0]==PJ._raw(plan['records']['state']['new']),'published_state_changed')
    current=R.record(selected.admission)[1];next_record=J._json(PJ._raw(plan['records']['admission']['new']))
    require(same(C._authority(current),C._authority(next_record)),'published_admission_changed')
    return True


def begin(context,*,writer,verify_locks):
    """Freeze intents/authorization and a discoverable marker before dispatch."""
    _guard(verify_locks);context.validate_marker()
    sid=context.plan['session_id'];selected=_paths(context.paths.root,sid,create=True)
    require(_active(context.paths.root,sid) is None,'other_active_publication')
    if R.reviewed(context.plan):
        plan=LP.seal_plan(context.paths.run_dir,verify_fence=writer.verify,
            validate_inputs=lambda *_:context.validate_marker())
        plan_sha=LP.read_plan(context.paths.run_dir)[1]
        driver=None
        authorization={'version':1,'kind':KIND,**_pin(context),'plan_origin':R.L.REVIEWED_ACCOUNTING,
            'plan_sha256':plan_sha,'operation_ids':[item['operation_id'] for item in plan['operations']],
            'max_generations':1}
    else:
        driver=D.ResidualDriver.prepare(context.paths.run_dir,reviewed_raw=R.unseal(context.value['review']),
            reviewed_sha256=context.review_sha256,manifest_sha256=context.manifest_sha256,
            writer=writer,validate_inputs=context.validate_inputs)
        authorization={'version':1,'kind':KIND,**_pin(context),
            'operation_ids':[driver._intent(label)[0] for label in driver.operations],'max_generations':D.MAX_GENERATIONS}
    _guard(verify_locks);Q._immutable(_work(context)/'residual-authorization.json',authorization,'residual_authorization')
    evidence=_evidence(context);decoded=C._decode_inputs(context.paths.base(),context.manifest)
    request=decoded['request'];state_raw=J._unseal(context.manifest['inputs']['cursor'])
    admission_raw,record,_=R.record(selected.admission);pending_raw,_,_=R.record(selected.pending)
    require(pending_raw==J._unseal(context.manifest['inputs']['request']),'pending_changed_before_marker')
    next_record={**record,'processing':request['request_id'],'processing_execution':{
        'run_id':context.run_id,'manifest_sha256':context.manifest_sha256}}
    def validate(view,phase):
        _guard(verify_locks);context.validate_marker()
        require(same(view['input_evidence'],evidence) and same(view['run_evidence'],evidence),'marker_evidence_changed')
        Q._marker(view,view['publication']);return True
    summary=Q.start(selected,ticket_id=_ticket(context,'marker'),
        session_id=sid,request_id=request['request_id'],binding=request['admission'],
        expected_old_state_sha256=J.sha256(state_raw),expected_old_admission_sha256=J.sha256(admission_raw),
        expected_pending_sha256=J.sha256(pending_raw),new_state=decoded['cursor'],new_admission=next_record,
        input_evidence=evidence,run_evidence=evidence,outcome={'result':'processing','queue_action':'none','pause_reason':None},
        validate=validate)
    _guard(verify_locks)
    ref={key:summary[key] for key in ('ticket_id','ticket_sha256')}
    Q._immutable(_work(context)/'processing-publication.json',ref,'residual_marker_reference')
    Q.acknowledge(selected,session_id=sid,validate=validate)
    _guard(verify_locks);context.validate_inputs(context.manifest,context.plan,'before_dispatch')
    return driver


def _driver(context,verify_locks,view=None):
    if R.reviewed(context.plan):return None
    def validate(manifest,plan,phase):
        _guard(verify_locks)
        require(same(manifest,context.manifest) and same(plan,context.plan),'execution_changed')
        if view is None:return context.validate_inputs(manifest,plan,phase)
        context.validate_frozen_inputs(phase);_current_pair(context,view);return True
    return D.ResidualDriver(context.paths.run_dir,manifest_sha256=context.manifest_sha256,
        review_sha256=context.review_sha256,validate_inputs=validate)


def _qualified_memory_ids(summary):
    new=summary['memory_ids'];old=summary['preserved_legacy_memory_ids']
    require(type(new) is list and type(old) is list and len(new)==5 and len(old)==1,
            'residual_memory_ids_changed')
    normalized=[J._uuid(value) for value in new];preserved=[J._uuid(value) for value in old]
    require(len(set(normalized))==5 and not set(normalized)&set(preserved),'residual_memory_ids_changed')
    return True


def _settlement(context,driver,recoveries,verify_locks):
    if R.reviewed(context.plan):
        _guard(verify_locks)
        require(len(recoveries)==1 and type(recoveries[0]) is F.HeldFence
                and recoveries[0].mode=='exclusive','original_revoked_writer_required')
        recoveries[0].verify(context.manifest['fencing'])
        progress=PE.inspect_plan(context.paths.run_dir)
        require(progress['status']=='complete' and progress['unchanged_write_calls']==0,'reviewed_plan_incomplete')
        require(all(record['receipt']['outcome']=='applied' and len(record['receipt']['memoryIDs'])==1
                for record in progress['operations']),'reviewed_effect_changed')
        ids=progress['memory_ids'];preserved=context.plan['preserve_without_replay']['memory_ids']
        require(len(ids)==len(progress['operations']) and not set(ids)&set(preserved),'reviewed_effect_changed')
        settled={'version':1,'kind':'reviewed_residual_settlement',**_pin(context),
            'plan_origin':R.L.REVIEWED_ACCOUNTING,'plan_sha256':progress['plan_sha256'],'progress':progress,
            'preserved_memory_ids':preserved,'new_memory_ids':ids,'applied_write_count':len(ids),
            'unchanged_write_count':0,'provider_invoked':False,'successful_coverage':False,
            'historical_execution_sealed':False,'historical_run_status':'failed',
            'source_binding_grade':'current_bounded_reconstruction'}
        path=_work(context)/'residual-settlement.json'
        J._publish_atomic(path,J.encode(settled));_guard(verify_locks)
        return settled,J.sha256(J.encode(settled))
    _guard(verify_locks);driver._check('before_settlement',recoveries=recoveries)
    summary=driver.summary()
    _qualified_memory_ids(summary)
    require(summary['status']=='residuals_applied_reviewed_publication_pending'
            and summary.get('current_inputs_validated',True) is not False,'residuals_not_qualified')
    generations=driver._generations();index=len(generations)-1
    proof,proof_sha=D.read(context.paths.run_dir/f'residual-reconciliation-{index:03d}.json')
    driver._checkpoint(proof,generations)
    require(proof['heads']==driver._heads() and all(v['kind']=='committed' and v['receipt']['outcome']=='applied'
        and len(v['receipt']['memoryIDs'])==1 for v in proof['statuses'].values()),
        'final_status_not_qualified')
    value={'version':1,'kind':'reviewed_residual_settlement',**_pin(context),
        'authorization_sha256':_authorization(context)[1],'generation_sha256s':[v[1] for v in generations],
        'checkpoint_sha256':proof_sha,'evidence_heads':proof['heads'],
        'operations':[{'label':label,'operation_id':driver._intent(label)[0],
            'receipt_sha256':J.sha256(J.encode(proof['statuses'][label]['receipt']))} for label in driver.operations],
        'preserved_memory_ids':summary['preserved_legacy_memory_ids'],'new_memory_ids':summary['memory_ids'],
        'applied_write_count':5,'unchanged_write_count':0,'provider_invoked':False,
        'historical_run_status':'failed','historical_execution_sealed':False,
        'source_binding_grade':'current_bounded_reconstruction','successful_coverage':False}
    _guard(verify_locks);Q._immutable(_work(context)/'residual-settlement.json',value,'residual_settlement')
    driver._check('after_settlement',recoveries=recoveries)
    return value,J.sha256(J.durable.encode(value))


def _reference(context,settled,digest):
    source=context.manifest['source'];parser=J._json(J._unseal(context.manifest['inputs']['parser_state']))
    return {'version':2 if R.reviewed(context.plan) else 1,'id':_ticket(context,'final'),
        'legacy_run_id':context.plan['legacy_run_id'],**_pin(context),'settlement_sha256':digest,
        'interval':{'start_offset':source['start_offset'],'end_offset':source['end_offset'],
            'interval_sha256':parser['interval_sha256'],'excerpt_sha256':source['excerpt_sha256']},
        'preserved_memory_ids':settled['preserved_memory_ids'],'new_memory_ids':settled['new_memory_ids']}


def _proposal(context,settled,digest,record):
    state=J._json(J._unseal(context.manifest['inputs']['cursor']))
    state.update(J._json(J._unseal(context.manifest['inputs']['next_parser_state'])))
    state['status']=RESULT;state['last_residual_reconciliation']=_reference(context,settled,digest)
    del state['reconciliation_required']
    next_record={**record,'processing':None,'state_sha256':J.durable.object_digest(state)}
    next_record.pop('processing_execution',None)
    return state,next_record


def _publication_view(view,phase):
    """Bind the documented draft digest to its exact already-frozen plan."""
    value=copy.deepcopy(view)
    digest=J.sha256(J.durable.encode(value['publication']))
    if value['prepared_sha256'] is None:
        require(phase=='journal_prepare','publication_digest_missing')
        value['prepared_sha256']=digest
    require(value['prepared_sha256']==digest,'publication_digest_changed')
    return value


def _validator(context,settled,digest,recoveries,verify_locks):
    marker,completed_marker=_marker(context);evidence={**_evidence(context),'settlement_sha256':digest}
    cached_view=None;cached_driver=None
    def validate(view,phase):
        nonlocal cached_view,cached_driver
        view=_publication_view(view,phase)
        _guard(verify_locks);context.validate_frozen_inputs(phase);_current_pair(context,view)
        require(same(view['input_evidence'],evidence) and same(view['run_evidence'],{**evidence,'marker':marker})
                and view['outcome']=={'result':RESULT,'queue_action':'keep','pause_reason':None},'outcome_changed')
        if cached_view is None:
            cached_view=copy.deepcopy(view);cached_driver=_driver(context,verify_locks,cached_view)
        require(same(view,cached_view),'publication_view_changed')
        verified,actual=_settlement(context,cached_driver,recoveries,verify_locks)
        require(actual==digest and same(verified,settled),'settlement_changed')
        plan=view['publication'];old=J._json(PJ._raw(plan['records']['admission']['old'],old=True))
        require(PJ._raw(plan['records']['state']['old'],old=True)==J._unseal(context.manifest['inputs']['cursor']),
                'original_cursor_changed')
        original=J._json(J._unseal(context.manifest['inputs']['admission']))
        expected={**C._authority(original),'processing':view['request_id'],'processing_execution':{
            'run_id':context.run_id,'manifest_sha256':context.manifest_sha256}}
        require(same(C._authority(old),expected),'original_marker_changed')
        state,record=_proposal(context,settled,digest,old)
        require(PJ._raw(plan['records']['state']['new'])==J.durable.encode(state)
                and PJ._raw(plan['records']['admission']['new'])==J.durable.encode(record)
                and same(view['pending'],completed_marker['ticket']['pending']),'proposal_changed')
        selected=_paths(context.paths.root,context.plan['session_id'])
        raw,current,identity=R.record(selected.pending)
        require(same(A.check(context.paths.root,current),view['binding']),'pending_not_admitted')
        if current['request_id']==view['request_id']:
            require((raw,identity)==(PJ._raw(view['pending'],old=True),view['pending']['identity']),'same_request_changed')
        _guard(verify_locks);return True
    return validate


def finish(context,*,recoveries,verify_locks):
    """All generations revoked and every exact residual applied; keep queue."""
    _guard(verify_locks);sid=context.plan['session_id'];selected=_paths(context.paths.root,sid,create=True)
    active=_active(context.paths.root,sid)
    view=None if active is None else {**active[0],'publication':Q._plan(selected,active[0])}
    ref_path=_work(context)/'residual-publication-reference.json'
    if view is None and os.path.lexists(ref_path):
        ref,_=_read(ref_path,maximum=65536)
        done=Q.read_completed(selected,session_id=sid,**ref)
        view={**done['ticket'],'publication':done['publication']}
    if view is not None:
        require(view['outcome']['result']==RESULT and all(view['input_evidence'].get(k)==v
            for k,v in _evidence(context).items()),'other_active_publication')
    driver=_driver(context,verify_locks,view)
    # Final status is explicit and durable. During final pair recovery an
    # existing checkpoint is verified without adding or replacing evidence.
    if driver is not None:driver.reconcile(recoveries=recoveries,probe=N.status_probe(driver,context.transport))
    settled,digest=_settlement(context,driver,recoveries,verify_locks)
    marker,marker_complete=_marker(context);reference=_state_reference(_reference(context,settled,digest))
    request_id=marker_complete['ticket']['request_id'];evidence={**_evidence(context),'settlement_sha256':digest}
    validate=_validator(context,settled,digest,recoveries,verify_locks)
    ref_path=_work(context)/'residual-publication-reference.json'
    if active is None and not os.path.lexists(ref_path):
        context.validate_inputs(context.manifest,context.plan,'before_publication')
        state_raw,_,_=R.record(selected.state);admission_raw,record,_=R.record(selected.admission)
        pending_raw,_,_=R.record(selected.pending);new_state,new_record=_proposal(context,settled,digest,record)
        Q.start(selected,ticket_id=reference['id'],session_id=sid,request_id=request_id,
            binding=marker_complete['ticket']['binding'],expected_old_state_sha256=J.sha256(state_raw),
            expected_old_admission_sha256=J.sha256(admission_raw),expected_pending_sha256=J.sha256(pending_raw),
            new_state=new_state,new_admission=new_record,input_evidence=evidence,run_evidence={**evidence,'marker':marker},
            outcome={'result':RESULT,'queue_action':'keep','pause_reason':None},validate=validate,completed_marker=marker)
        active=_active(context.paths.root,sid)
    if active is not None:
        require(active[0]['ticket_id']==reference['id'],'other_active_publication')
        summary=Q.recover(selected,session_id=sid,validate=validate)
        _guard(verify_locks)
        Q._immutable(ref_path,{key:summary[key] for key in ('ticket_id','ticket_sha256')},'residual_publication_reference')
        Q.acknowledge(selected,session_id=sid,validate=validate)
    published,_=_read(ref_path,maximum=65536)
    completed=Q.read_completed(selected,session_id=sid,**published)
    validate({**completed['ticket'],'publication':completed['publication']},'completion')
    receipt={'version':1,'kind':'legacy_residual_interval_reconciliation','status':'reconciled_with_residuals',
        'session_id':sid,'request_id':request_id,'reference':reference,'publication':published,
        'completion_sha256':J.sha256(J.durable.encode(completed['completion'])),
        'historical_run_status':'failed','historical_execution_sealed':False,
        'source_binding_grade':'current_bounded_reconstruction','provider_invoked':False,
        'applied_write_count':settled['applied_write_count'],'unchanged_write_count':settled['unchanged_write_count']}
    _guard(verify_locks);Q._immutable(_work(context)/'residual-receipt.json',receipt,'residual_receipt')
    _guard(verify_locks);boundary('receipt_durable');return receipt


def _run_id(value):
    import re
    require(type(value) is str and re.fullmatch(r'[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}',value),'invalid_run_id')
    return value


def _pins(value,*,settlement=False):
    keys={'kind','run_id','manifest_sha256','context_sha256','review_sha256','authorization_sha256'}
    if settlement:keys.add('settlement_sha256')
    J._keys(value,keys);require(value['kind']==KIND,'invalid_evidence')
    _run_id(value['run_id'])
    for key in keys-{'kind','run_id'}:J._digest(value[key])
    return copy.deepcopy(value)


def _state_reference(value):
    J._keys(value,{'version','id','legacy_run_id','run_id','manifest_sha256','context_sha256',
        'review_sha256','settlement_sha256','interval','preserved_memory_ids','new_memory_ids'})
    require(type(value['version']) is int and value['version'] in (1,2),'invalid_reference')
    A._uuid(value['id'],4);_run_id(value['legacy_run_id']);_run_id(value['run_id'])
    for key in ('manifest_sha256','context_sha256','review_sha256','settlement_sha256'):J._digest(value[key])
    interval=value['interval'];J._keys(interval,{'start_offset','end_offset','interval_sha256','excerpt_sha256'})
    for key in ('start_offset','end_offset'):J._integer(interval[key],high=(1<<63)-1)
    require(interval['end_offset']>interval['start_offset'],'invalid_interval')
    for key in ('interval_sha256','excerpt_sha256'):J._digest(interval[key])
    for key,count in (('preserved_memory_ids',1),('new_memory_ids',5)):
        require(type(value[key]) is list and (len(value[key])==count if value['version']==1 else
            len(value[key])<= (32 if key=='preserved_memory_ids' else 5)),'invalid_memory_ids')
        ids=[J._uuid(item) for item in value[key]]
        require(len(set(ids))==len(ids),'invalid_memory_ids')
    require(not {J._uuid(x) for x in value['new_memory_ids']}
            &{J._uuid(x) for x in value['preserved_memory_ids']},'invalid_memory_ids')
    return value


def _ticket_metadata(root,sid,run,name):
    """Bounded fixed-path discovery; no plans, source, history, store or native IO."""
    selected=_paths(root,sid)
    reference,_=_read(root/'runs'/_run_id(run)/name,maximum=65536)
    J._keys(reference,{'ticket_id','ticket_sha256'})
    A._uuid(reference['ticket_id'],4);J._digest(reference['ticket_sha256'])
    raw,_=J.durable._read(Q._ticket_path(selected,reference['ticket_id']),maximum=Q.MAX_TICKET)
    require(J.sha256(raw)==reference['ticket_sha256'],'ticket_changed')
    ticket=J._json(raw);Q._ticket(ticket,selected,sid)
    return reference,ticket


def _receipt_metadata(root,sid,reference):
    """Passive completed metadata only; this does not authorize publication."""
    _state_reference(reference);run=root/'runs'/reference['run_id']
    receipt,_=_read(run/'residual-receipt.json',maximum=65536)
    J._keys(receipt,{'version','kind','status','session_id','request_id','reference','publication',
        'completion_sha256','historical_run_status','historical_execution_sealed','source_binding_grade',
        'provider_invoked','applied_write_count','unchanged_write_count'})
    require(type(receipt['version']) is int and receipt['version']==1
        and receipt['kind']=='legacy_residual_interval_reconciliation'
        and receipt['status']=='reconciled_with_residuals' and receipt['session_id']==sid
        and same(receipt['reference'],reference) and receipt['historical_run_status']=='failed'
        and receipt['historical_execution_sealed'] is False and receipt['provider_invoked'] is False
        and receipt['source_binding_grade']=='current_bounded_reconstruction'
        and type(receipt['applied_write_count']) is int and receipt['applied_write_count']==len(reference['new_memory_ids'])
        and type(receipt['unchanged_write_count']) is int and receipt['unchanged_write_count']==0,'receipt_changed')
    PJ._identifier(receipt['request_id']);J._digest(receipt['completion_sha256'])
    publication=receipt['publication'];J._keys(publication,{'ticket_id','ticket_sha256'})
    J._digest(publication['ticket_sha256'])
    require(publication['ticket_id']==reference['id'] and same(publication,
        _read(run/'residual-publication-reference.json',maximum=65536)[0]),'publication_reference_changed')
    raw,_=J.durable._read(root/'publications'/sid/'records'/reference['id']/'completion.json',maximum=262144)
    completion=J._json(raw)
    J._keys(completion,{'version','ticket_id','ticket_sha256','published_sha256','ack_intent_sha256',
                       'outcome','disposition','pending'})
    require(J.sha256(raw)==receipt['completion_sha256'] and type(completion['version']) is int
        and completion['version']==1 and all(completion[k]==v for k,v in publication.items())
        and same(completion['outcome'],{'result':RESULT,'queue_action':'keep','pause_reason':None})
        and completion['disposition'] in ('original','newer') and type(completion['pending']) is dict,
        'completion_changed')
    for key in ('published_sha256','ack_intent_sha256'):J._digest(completion[key])
    settled,digest=_read(run/'residual-settlement.json',maximum=262144)
    require(digest==reference['settlement_sha256'] and type(settled.get('version')) is int
        and settled['version']==1 and settled.get('kind')=='reviewed_residual_settlement'
        and all(settled.get(key)==reference[key] for key in ('run_id','manifest_sha256','context_sha256','review_sha256'))
        and same(settled.get('preserved_memory_ids'),reference['preserved_memory_ids'])
        and same(settled.get('new_memory_ids'),reference['new_memory_ids'])
        and type(settled.get('applied_write_count')) is int and settled['applied_write_count']==len(reference['new_memory_ids'])
        and type(settled.get('unchanged_write_count')) is int and settled['unchanged_write_count']==0
        and settled.get('provider_invoked') is False and settled.get('successful_coverage') is False
        and settled.get('historical_execution_sealed') is False and settled.get('historical_run_status')=='failed'
        and settled.get('source_binding_grade')=='current_bounded_reconstruction','settlement_metadata_changed')
    require((reference['version']==1 and 'plan_origin' not in settled) or
            (reference['version']==2 and settled.get('plan_origin')==R.L.REVIEWED_ACCOUNTING),'settlement_origin_changed')
    return receipt


def _processing_reference(root,session_id):
    names=A.state_paths(root,session_id)
    _,admitted,_=R.record(names['admissions'],absent=True)
    execution=None if admitted is None else admitted.get('processing_execution')
    if execution is None:return None
    J._keys(execution,{'run_id','manifest_sha256'});run=_run_id(execution['run_id']);J._digest(execution['manifest_sha256'])
    marker=root/'runs'/run/'processing-publication.json'
    if not os.path.lexists(marker):
        require(not any(os.path.lexists(root/'runs'/run/name) for name in
            ('residual-context.json','residual-authorization.json','residual-generation-000.json')),
            'processing_marker_reference_missing')
        return None
    _,ticket=_ticket_metadata(root,session_id,run,'processing-publication.json')
    if ticket['input_evidence'].get('kind')!=KIND:return None
    evidence=_pins(ticket['input_evidence'])
    require(ticket['outcome']['result']=='processing' and admitted['processing']==ticket['request_id']
        and evidence['run_id']==run and evidence['manifest_sha256']==execution['manifest_sha256'],
        'processing_reference_changed')
    return evidence


def recovery_reference(root,session_id):
    """Return checked run pins for a selected residual, or None for other work.

    This is discovery, never execution authority. Malformed selected references
    raise a fixed hold; they must not fall through to ordinary provider work.
    """
    A._uuid(session_id,7);require(isinstance(root,Path) and root.is_absolute(),'untrusted_root')
    active=_active(root,session_id)
    if active is not None:
        ticket=active[0];evidence=ticket['input_evidence']
        if evidence.get('kind')!=KIND:return None
        return _pins(evidence,settlement=ticket['outcome']['result']==RESULT)
    current=_processing_reference(root,session_id)
    if current is not None:return current
    names=A.state_paths(root,session_id)
    raw,state,_=R.record(names['sessions'],absent=True)
    if raw is None:return None
    if 'last_residual_reconciliation' in state or state.get('status')==RESULT:
        require(state.get('last_residual_reconciliation') is not None,'missing_reference')
        reference=_state_reference(state['last_residual_reconciliation'])
        _,ticket=_ticket_metadata(root,session_id,reference['run_id'],'residual-publication-reference.json')
        evidence=_pins(ticket['input_evidence'],settlement=True)
        require(ticket['ticket_id']==reference['id'] and ticket['outcome']['result']==RESULT
            and all(evidence[k]==reference[k] for k in ('run_id','manifest_sha256','context_sha256',
                'review_sha256','settlement_sha256')),'final_reference_changed')
        return evidence
    return None

def needs_recovery(root,session_id):
    """Bounded discovery; malformed evidence stays discoverable as an explicit hold."""
    try:
        ref=recovery_reference(root,session_id)
        if ref is None:return False
        if _active(root,session_id) is not None:return True
        _,state,_=R.record(A.state_paths(root,session_id)['sessions'])
        if state.get('last_residual_reconciliation') is None:return True
        if (state['last_residual_reconciliation'].get('run_id')!=ref['run_id']
            or state['last_residual_reconciliation'].get('context_sha256')!=ref['context_sha256']):return True
        _receipt_metadata(root,session_id,state['last_residual_reconciliation'])
        return False
    except (OSError,ValueError,TypeError,KeyError,AttributeError,OverflowError,RuntimeError,RecursionError,UnicodeError):
        return True


def _recover_marker(context,verify_locks):
    active=_active(context.paths.root,context.plan['session_id'])
    if active is None:return _marker(context)
    ticket=active[0]
    if ticket['outcome']['result']==RESULT:return _marker(context)
    require(ticket['outcome']['result']=='processing' and same(ticket['input_evidence'],_evidence(context))
        and same(ticket['run_evidence'],_evidence(context)),'marker_changed')
    def validate(view,phase):
        _guard(verify_locks);context.validate_marker()
        require(same(view['input_evidence'],_evidence(context)) and same(view['run_evidence'],_evidence(context)),
                'marker_changed')
        Q._marker(view,view['publication']);return True
    selected=_paths(context.paths.root,context.plan['session_id'])
    summary=Q.recover(selected,session_id=context.plan['session_id'],validate=validate)
    _guard(verify_locks)
    Q._immutable(_work(context)/'processing-publication.json',
        {k:summary[k] for k in ('ticket_id','ticket_sha256')},'residual_marker_reference')
    Q.acknowledge(selected,session_id=context.plan['session_id'],validate=validate)
    return _marker(context)


def _final_view(context):
    active=_active(context.paths.root,context.plan['session_id'])
    if active is not None:
        if active[0]['outcome']['result']!=RESULT:return None
        return {**active[0],'publication':Q._plan(_paths(context.paths.root,context.plan['session_id']),active[0])}
    ref_path=_work(context)/'residual-publication-reference.json'
    if not os.path.lexists(ref_path):return None
    ref,_=_read(ref_path,maximum=65536)
    done=Q.read_completed(_paths(context.paths.root,context.plan['session_id']),session_id=context.plan['session_id'],**ref)
    return {**done['ticket'],'publication':done['publication']}


def generation_directory(run_dir,index):
    """Only trusted derivation for real writer generations; never a JSON path."""
    require(isinstance(run_dir,Path) and run_dir.is_absolute() and type(index) is int
            and 0<=index<D.MAX_GENERATIONS,'invalid_generation')
    return run_dir if index==0 else run_dir/'residual-writers'/f'{index:03d}'


def recover_locked(paths,*,session_id,verify_locks,allow_continuation=False,runtime_profile=None):
    """Recover the selected held residual under caller worker -> enqueue locks.

    Default only revokes writers, queries exact status and completes qualified
    metadata. Explicit continuation may dispatch retained absent intents in a new
    generation. Every original generation remains revoked under real EX handles.
    No provider runs and no operation ID/payload/TTL is recreated.
    """
    require(type(paths) is R.ResidualPaths and type(allow_continuation) is bool,'invalid_arguments')
    _guard(verify_locks);paths.check();ref=recovery_reference(paths.root,session_id)
    if ref is None:return None
    require(paths.run_dir==paths.root/'runs'/ref['run_id'],'selected_run_changed')
    # Authenticated already-completed metadata is a no-op even after later cursor
    # progress. Full new publication always revalidates the original pinned pair.
    _,state,_=R.record(A.state_paths(paths.root,session_id)['sessions'])
    if (_active(paths.root,session_id) is None and type(state.get('last_residual_reconciliation')) is dict
        and state['last_residual_reconciliation'].get('run_id')==ref['run_id']
        and state['last_residual_reconciliation'].get('context_sha256')==ref['context_sha256']):
        if os.path.lexists(paths.run_dir/'residual-receipt.json'):
            receipt=_receipt_metadata(paths.root,session_id,state['last_residual_reconciliation'])
            done=Q.read_completed(_paths(paths.root,session_id),session_id=session_id,**receipt['publication'])
            require(same(done['ticket']['input_evidence'],ref)
                and done['ticket']['request_id']==receipt['request_id']
                and same(J._json(PJ._raw(done['publication']['records']['state']['new']))['last_residual_reconciliation'],
                    state['last_residual_reconciliation']),'completed_reference_changed')
            _guard(verify_locks);return None
    context=R.load_context(paths,manifest_sha256=ref['manifest_sha256'],context_sha256=ref['context_sha256'],
                           runtime_profile=runtime_profile)
    require(context.plan['session_id']==session_id and context.review_sha256==ref['review_sha256']
            and _authorization(context)[1]==ref['authorization_sha256'],'selected_context_changed')
    _recover_marker(context,verify_locks)
    if R.reviewed(context.plan):
        # This origin uses the ordinary whole-plan executor and its ORIGINAL
        # nonrevoked generation. A read-only recovery never calls operation_apply.
        # Explicit execute can replay exact native IDs; continue-absent retains
        # the older controller's distinct revoked-generation contract.
        require(not allow_continuation,'reviewed_plan_requires_execute')
        progress=PE.inspect_plan(paths.run_dir)
        if progress['status']!='complete':
            context.validate_inputs(context.manifest,context.plan,'reviewed_recovery')
            _,marker_complete=_marker(context)
            return {'status':'reviewed_plan_pending','run_id':context.run_id,
                    'request_id':marker_complete['ticket']['request_id'],'provider_invoked':False,
                    'successful_coverage':False,'cursor_changed':False,'memory_ids':progress['memory_ids']}
        view=_final_view(context)
        def validate_reviewed(binding,phase):
            _guard(verify_locks)
            if view is None:context.validate_inputs(context.manifest,context.plan,'reviewed_'+phase)
            else:context.validate_frozen_inputs(phase);_current_pair(context,view)
            return True
        with F.revoke(paths.run_dir,context.manifest['fencing'],validate=validate_reviewed) as recovery:
            return finish(context,recoveries=[recovery],verify_locks=verify_locks)
    view=_final_view(context);driver=_driver(context,verify_locks,view)
    def validate(binding,phase):
        _guard(verify_locks)
        if view is None:context.validate_inputs(context.manifest,context.plan,'recovery_'+phase)
        else:context.validate_frozen_inputs(phase);_current_pair(context,view)
        return True
    generations=driver._generations();require(bool(generations),'generation_missing')
    directories=paths.run_dir/'residual-writers'
    if os.path.lexists(directories):
        J.durable._directory(directories)
        require({p.name for p in directories.iterdir()}=={f'{n:03d}' for n in range(1,len(generations))},
                'unpublished_writer_generation')
    with contextlib.ExitStack() as stack:
        recoveries=[]
        for index,(gen,_) in enumerate(generations):
            _guard(verify_locks)
            held=F.revoke(generation_directory(paths.run_dir,index),gen['fencing'],validate=validate)
            stack.callback(held.close);recoveries.append(held)
        result=driver.reconcile(recoveries=recoveries,probe=N.status_probe(driver,context.transport))
        if result['status']!='residuals_applied_reviewed_publication_pending':
            require(allow_continuation and view is None,'residuals_require_reviewed_continuation')
            require(result['status']!='semantic_review_required','semantic_review_required')
            index=len(generations);directory=generation_directory(paths.run_dir,index)
            _guard(verify_locks);validate(None,'before_new_writer')
            J.durable._mkdir(directories)
            require(not os.path.lexists(directory),'unpublished_writer_generation')
            J.durable._mkdir(directory)
            binding=F.create(directory,generation_id=str(uuid.uuid4()),owner_id=str(uuid.uuid4()))
            writer=F.acquire_shared(directory,binding)
            try:
                driver.continue_generation(recoveries=recoveries,new_writer=writer)
                for label in driver._generations()[-1][0]['allowed']:
                    driver.dispatch(label,writer=writer,recoveries=recoveries,execute=N.executor(driver,context.transport))
            finally:writer.close()
            held=F.revoke(directory,binding,validate=validate);stack.callback(held.close);recoveries.append(held)
            driver.reconcile(recoveries=recoveries,probe=N.status_probe(driver,context.transport))
        return finish(context,recoveries=recoveries,verify_locks=verify_locks)
