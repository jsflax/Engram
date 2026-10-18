"""Exact current held-context seal for the reviewed fresh legacy residual profile.

Separate from ordinary admission and expired-only reconciliation. No provider,
mutation execution or cursor publication lives here. All caller paths are trusted;
retained reports select only fixed keys, never executable or filesystem paths.
"""
from __future__ import annotations
import copy
from dataclasses import dataclass
import datetime as dt
import os
import pwd
import re
from pathlib import Path
import sqlite3
import stat
import time
from . import admission as A, execution_context as C, execution_manifest as J
from . import legacy_reconciliation as L, publication_journal as PJ
from . import host_admission as H, transcript, writer_fence as F
from . import residual_driver as D
from . import publication_coordinator as Q

KIND = 'reviewed_legacy_residual_context'
MAX = 4 * 1024 * 1024
TOP = {'current-chat-independent-residual-review.json', 'current-chat-prior-success-readback.private.json',
       'current-chat-residual-review-adoption.json', 'current-chat-write-intents.private.json'}
NESTED = {'current-chat-fresh-hold-assessment.json','current-chat-bounded-diagnosis.json',
          'current-chat-coverage-excerpt.private.txt','current-chat-coverage-parser.private.json',
          'current-chat-readback.private.json','current-chat-write-intents.private.json',
          'current-chat-specific-duplicates.private.json'}
HISTORY = {'run','result','audit','provider','transport'}


def require(value, reason):
    if not value: raise ValueError('residual_context_' + reason)


def same(a,b): return J.encode(a) == J.encode(b)
def reviewed(plan): return type(plan) is dict and plan.get('kind') == L.REVIEWED_ACCOUNTING
def review_plan(plan): return L.accounting_review(plan) if reviewed(plan) else D._plan(plan)
def record(path, *, absent=False):
    raw,identity=J.durable._read(path,absent=absent)
    return raw, None if raw is None else J._json(raw),identity

def image(raw): return PJ._image(raw)
def unseal(value): return L._raw(value)
def report(images,name): return J._json(unseal(images[name]))


@dataclass(frozen=True)
class ResidualPaths:
    root: Path
    run_dir: Path
    config_path: Path
    plugin_root: Path
    candidate_store: Path

    def base(self): return C.ContextPaths(self.root,self.run_dir,self.config_path,self.plugin_root)
    def check(self):
        result=self.base().check()
        require(self.run_dir.parent == self.root/'runs', 'run_outside_root')
        require(re.fullmatch(r'[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}',self.run_dir.name),'invalid_run_id')
        require(self.candidate_store.is_absolute() and self.candidate_store.resolve(strict=True)==self.candidate_store,
                'untrusted_store')
        return {**result,'candidate_store':str(self.candidate_store)}


def review_reports(plan, images):
    if reviewed(plan):
        L.accounting_review(plan);require(images=={},'unexpected_review_reports');return
    """Authenticate the fixed adopted report graph, without following report paths."""
    D._plan(plan)
    require(set(plan['retained_inputs'])==TOP and set(images)==TOP|NESTED,'report_inventory')
    for name,digest in plan['retained_inputs'].items():
        J._digest(digest);require(J.sha256(unseal(images[name]))==digest,'report_changed')
    independent=report(images,'current-chat-independent-residual-review.json')
    require(set(independent['inputs'])==NESTED,'nested_inventory')
    for name,pin in independent['inputs'].items():
        require(type(pin['bytes']) is int and pin['bytes']==len(unseal(images[name]))
                and pin['sha256']==J.sha256(unseal(images[name])),'nested_report_changed')
    adoption=report(images,'current-chat-residual-review-adoption.json')
    require(adoption['schema_version']==1 and type(adoption['schema_version']) is int
            and adoption['kind']=='assistant_reviewed_residual_selection'
            and adoption['session_id']==plan['session_id'] and adoption['run_id']==plan['legacy_run_id']
            and adoption['proposal_sha256']==plan['approved_proposal_sha256']
            and J.sha256(unseal(images['current-chat-residual-review-adoption.json']))==plan['review_adoption_sha256'],
            'adoption_changed')
    require([{'id':v['id'],'arguments_sha256':v['arguments_sha256']} for v in adoption['selected_operations']]
            ==[{'id':v['id'],'arguments_sha256':v['arguments_canonical_sha256']} for v in plan['operations']],
            'adopted_payload_changed')
    require(len(adoption['message_dispositions'])==17,'adopted_messages_changed')
    for selected,reviewed_message in zip(adoption['message_dispositions'],plan['message_dispositions']):
        kind=reviewed_message['disposition']
        expected=('selected_residual' if kind=='reviewed_residual' else
                  'represented_by_preserved_update' if kind=='preserved_applied_update' else
                  'dated_plan_test_build_or_separate_reconciliation_progress')
        require(selected['index']==reviewed_message['index'] and type(selected['index']) is int
                and selected['disposition']==expected
                and selected['operation']==(reviewed_message['operations'][0] if kind=='reviewed_residual' else None)
                and selected['memory_ids']==(plan['preserve_without_replay']['memory_ids']
                    if kind=='preserved_applied_update' else []),'adopted_messages_changed')
    require(plan['preserve_without_replay']['tool']=='update'
            and len(plan['preserve_without_replay']['memory_ids'])==1,'preserved_update_changed')
    J._uuid(plan['preserve_without_replay']['memory_ids'][0])
    diagnosis=report(images,'current-chat-bounded-diagnosis.json')
    for item in (independent,diagnosis,report(images,'current-chat-write-intents.private.json')):
        require(item['session_id']==plan['session_id'] and item['run_id']==plan['legacy_run_id'],'selection_changed')
    require(diagnosis['source']['start']==plan['source']['start']
            and diagnosis['source']['end']==plan['source']['end']
            and diagnosis['source']['interval_sha256']==plan['source']['interval_sha256']
            and diagnosis['source']['identity']==plan['source']['identity']
            and diagnosis['source']['parser_sha256']==plan['source']['parser_sha256']
            and J.sha256(unseal(images['current-chat-coverage-excerpt.private.txt']))==plan['source']['excerpt_sha256'],
            'source_review_changed')
    return diagnosis


def capture_reports(plan,directory):
    if reviewed(plan):
        L.accounting_review(plan);return {}
    require(isinstance(directory,Path) and directory.is_absolute()
            and not J.durable._directory(directory).st_mode&0o077,'unsafe_import')
    images={name:image(J.durable._read(directory/name)[0]) for name in TOP|NESTED}
    review_reports(plan,images)
    return images


def readback(paths,expected):
    """One exact retained update row, indexed and read-only; no recall effects."""
    row=expected['updated_memory'];J._keys(row,set(L.ROW_FIELDS))
    memory=J._uuid(row['globalId'])
    before=paths.candidate_store.lstat()
    require(stat.S_ISREG(before.st_mode) and before.st_uid==os.getuid() and before.st_nlink==1,'unsafe_store')
    require(before.st_dev==expected['device'] and before.st_ino==expected['inode'],'store_changed')
    deadline=time.monotonic()+3
    db=sqlite3.connect(paths.candidate_store.as_uri()+'?mode=ro',uri=True,timeout=.2)
    try:
        db.execute('PRAGMA query_only=ON');db.set_progress_handler(lambda:int(time.monotonic()>=deadline),1000)
        db.execute('BEGIN')
        columns=['CASE WHEN length(CAST("content" AS BLOB)) <= 65536 THEN "content" ELSE NULL END'
                 if k=='content' else ('substr("'+k+'",1,4097)' if k in ('project','topic','source') else '"'+k+'"')
                 for k in L.ROW_FIELDS]
        values=db.execute('SELECT '+','.join(columns)+' FROM Memory WHERE globalId=? COLLATE NOCASE LIMIT 2',(memory,)).fetchall()
        require(len(values)==1 and time.monotonic()<deadline,'readback_missing')
        actual=dict(zip(L.ROW_FIELDS,values[0]));actual['globalId']=J._uuid(actual['globalId'])
        require(L._same_rows([actual],[{**row,'globalId':memory}]) and db.total_changes==0,'readback_changed')
        db.rollback()
    finally:db.close()
    after=paths.candidate_store.lstat()
    require((before.st_dev,before.st_ino,before.st_uid)==(after.st_dev,after.st_ino,after.st_uid),'store_changed')
    return True


def historical(paths,plan,images,history=None,*,verified=None):
    if reviewed(plan):
        L.accounting_review(plan);require(images=={},'unexpected_review_reports')
        actual={role:image(L._read_historical(paths.root,
            plan['previous_run_id'] if role=='previous_run' else plan['legacy_run_id'],
            'run' if role=='previous_run' else role)) for role in plan['history']}
        require(history is None or same(actual,history),'history_changed')
        key=(J.sha256(J.encode(plan)),J.sha256(J.encode(actual)))
        if verified is None or verified.get('key')!=key:
            L.accounting_history(plan,actual)
            if verified is not None:verified.clear();verified['key']=key
        return actual
    current={role:image(L._read_historical(paths.root,plan['legacy_run_id'],role)) for role in HISTORY}
    # Current historical bytes are always read. Only the already-proved
    # interpretation of identical sealed inputs can be reused by this context.
    key=(J.sha256(J.encode(plan)),
         tuple((name,J.sha256(unseal(images[name]))) for name in sorted(images)),
         None if history is None else tuple((name,J.sha256(unseal(history[name]))) for name in sorted(history)),
         tuple((name,J.sha256(unseal(current[name]))) for name in sorted(current)))
    if verified is not None and verified.get('key')==key:
        return current
    diagnosis=review_reports(plan,images)
    for role,value in current.items():
        require(J.sha256(unseal(value))==diagnosis['inputs'][role]['sha256'],'history_changed')
    if history is not None:require(same(history,current),'history_changed')
    validate_history(plan,images,current)
    if verified is not None:
        verified.clear();verified['key']=key
    return current


def validate_history(plan,images,history):
    # Closed serial historical account; no prose supplies mutation intent.
    _json,_raw,_lines,_require,_time,_same=J._json,unseal,L._lines,require,L._time,same
    codec,READ_TOOLS=J,L.READ_TOOLS
    review={"session_id":plan["session_id"],"source":{"end_offset":plan["source"]["end"]}}
    run = _json(_raw(history["run"]))
    _require(run.get("session_id") == review["session_id"] and run.get("status") == "failed"
             and run.get("reason") == "unverified_completion" and type(run.get("returncode")) is int
             and run["returncode"] == 0 and run.get("turn_completed") is True
             and (run.get("provider_error") is None or run.get("provider_error") is False)
             and (run.get("unexpected_tool") is None or run.get("unexpected_tool") is False)
             and run.get("end_offset") == review["source"]["end_offset"], "history_not_terminal")
    began, ended = _time(run["started_at"]), _time(run["ended_at"])
    _require(began <= ended and ended - began < dt.timedelta(hours=1), "invalid_run_window")
    provider = _lines(_raw(history["provider"]))
    audit = _lines(_raw(history["audit"]))
    _require(provider[-1].get("type") == "turn.completed", "provider_not_terminal")
    _require(audit[0].get("event") == "relay_started" and audit[-1].get("event") == "relay_finished"
             and audit[-1].get("child_reaped") is True and audit[-1].get("cleanup_overrun") is False
             and type(audit[-1].get("peak_inflight")) is int and audit[-1]["peak_inflight"] == 1,
             "relay_not_terminal")
    calls, results, active = [], [], None
    for event in audit[1:-1]:
        kind = event.get("event")
        if kind == "tool_call":
            _require(active is None and event.get("tool") in READ_TOOLS | {"remember", "update"}, "unaccounted_call")
            codec._integer(event.get("id"), 0, (1 << 31) - 1)
            active = event
            calls.append(event)
        elif kind == "tool_result":
            codec._integer(event.get("id"), 0, (1 << 31) - 1)
            _require(active is not None and event.get("id") == active.get("id")
                     and event.get("tool") == active.get("tool") and event.get("forwarded") is True,
                     "unmatched_result")
            results.append(event)
            active = None
        else:
            _require(kind in {"initialize_compat", "relay_interrupted"} and active is None,
                     "unknown_audit_event")
    _require(active is None and len({str(item.get("id")) for item in calls}) == len(calls), "unfinished_call")
    started, completed, pending = [], [], None
    _require(provider[0].get("type") == "thread.started" and provider[1].get("type") == "turn.started",
             "provider_start_missing")
    for event in provider[2:-1]:
        item = event.get("item", {})
        if item.get("type") != "mcp_tool_call":
            _require(event.get("type") == "item.completed" and type(item) is dict
                     and set(item) == {"id", "type", "text"}
                     and item["type"] in {"agent_message", "reasoning"}
                     and type(item["text"]) is str and pending is None,
                     "unexpected_provider_item")
            continue
        _require(item.get("server") == "memory" and item.get("tool") in READ_TOOLS | {"remember", "update"},
                 "unaccounted_provider_tool")
        if event.get("type") == "item.started":
            _require(pending is None, "provider_overlap")
            pending = item
            started.append(item)
        elif event.get("type") == "item.completed":
            _require(pending is not None and item.get("id") == pending.get("id")
                     and item.get("tool") == pending.get("tool")
                     and _same(item.get("arguments"), pending.get("arguments")), "provider_result_changed")
            completed.append(item)
            pending = None
        else:
            _require(False, "unknown_provider_event")
    _require(pending is None and len(started) == len(calls)
             and [item["tool"] for item in started] == [item["tool"] for item in calls],
             "call_correlation_changed")
    mutations=[(a,b,c) for a,b,c in zip(started,completed,results) if a['tool'] in ('remember','update')]
    retained=report(images,'current-chat-write-intents.private.json')['intents']
    require(len(mutations)==len(retained)==2 and [v[0]['tool'] for v in mutations]==['update','remember'],
            'historical_mutation_inventory')
    for (start,finish,result),expected in zip(mutations,retained):
        require(start['id']==expected['provider_item'] and result['id']==expected['audit_id']
                and same(start['arguments'],expected['provider_arguments'])
                and same(finish,expected['provider_completion']) and same(result,expected['audit_result'])
                and J.sha256(J.encode(expected['gateway_arguments']))==expected['gateway_arguments_sha256'],
                'historical_attempt_changed')
    update,failed=retained
    args=update['provider_arguments'];J._keys(args,{'id','append','source'})
    J._string(args['append'],65536)
    preserved=plan['preserve_without_replay']['memory_ids']
    require([J._uuid(args['id'])]==preserved and update['audit_result']['ok'] is True
            and [J._uuid(v) for v in update['audit_result']['memory_ids']]==preserved,'historical_update_changed')
    row=report(images,'current-chat-readback.private.json')['updated_memory']
    require(J._uuid(row['globalId'])==preserved[0] and row['deletedAt'] is None
            and type(row['content']) is str and row['content'].count(args['append'])==1
            and began.timestamp() <= row['modifiedAt'] <= ended.timestamp(),'historical_update_readback_changed')
    result=failed['audit_result']
    require(result['ok'] is False and result['memory_ids']==[] and type(result['write_outcome_version']) is int
            and result['write_outcome_version']==1 and result['write_outcome']=='not_stored_transaction_not_started',
            'historical_no_write_changed')
    receipt=failed['provider_completion']['result'].get('structured_content',{}).get('engram_write_receipt')
    require(same(receipt,{'schema_version':1,'tool':'remember','memory_ids':[],
            'reason':'database_busy','write_outcome':'not_stored_transaction_not_started'}),'historical_no_write_missing')
    require('expires_in_days' not in failed['provider_arguments']
            and same(failed['gateway_arguments'],plan['operations'][0]['arguments']),'residual_original_intent_changed')
    return True


def _mutation_policy(configuration):
    allowed=C.memory_config.allowed_tools(configuration['memory'],C.READ_TOOLS|C.WRITE_TOOLS)
    require('remember' in allowed,'remember_policy_disallows_residuals')
    return True


def _store_route(paths,route):
    environment=route['launch']['env']
    if 'CLAUDE_MEMORY_DB' in environment:
        value=environment['CLAUDE_MEMORY_DB']
        require(type(value) is str and bool(value) and Path(value).is_absolute(),'store_route_invalid')
        selected=Path(value)
    else:
        account_home=Path(pwd.getpwuid(os.getuid()).pw_dir)
        require(environment.get('HOME',str(account_home))==str(account_home)
                and environment.get('CFFIXED_USER_HOME',str(account_home))==str(account_home),
                'store_home_changed')
        selected=account_home/'.claude/memory.sqlite'
    require(selected.resolve(strict=True)==selected==paths.candidate_store,'store_route_changed')
    return True


def _runtime(*,accounting=False):
    paths=[Path(__file__),Path(D.__file__),Path(C.__file__),Path(J.__file__),Path(L.__file__),Path(F.__file__),
           Path(D.P.__file__),Path(D.G.__file__),Path(__file__).with_name('native_executor.py'),
           Path(__file__).with_name('residual_publication.py'),Path(Q.__file__)]
    if accounting:paths += [Path(__file__).with_name(name) for name in ('learner_plan.py','planned_execution.py')]
    return {p.name:{'path':str(p),'sha256':J.sha256(J.durable._read(p,private=False)[0])} for p in paths}


def _source(plan,request,state,images,maximum,scan,*,verified=None):
    if reviewed(plan):
        L.accounting_review(plan);source=plan['source']
        require(same(C._parser_state(state),plan['parser']['input'])
                and maximum==plan['parser']['max_chars'] and source['end']-source['start']<=scan<=C.MAX_SCAN,
                'parser_review_changed')
        require(C._interval(request['transcript_path'],source['identity'],source['start'],source['end'])
                ==source['interval_sha256'] and C._parser_runtime()['sha256']==source['parser_sha256'],'source_changed')
        key=J.sha256(J.encode({'plan':plan,'request':request,'state':state,'maximum':maximum,'scan':scan}))
        if verified is not None and verified.get('key')==key:return None
        excerpt=L.accounting_source(request,plan)
        parser={'version':1,'input':C._parser_state(state),'limits':{'max_chars':maximum,'max_scan_bytes':scan},
                'runtime':C._parser_runtime(),'interval_sha256':source['interval_sha256']}
        if verified is not None:verified.clear();verified['key']=key
        return excerpt,parser
    source=plan['source'];before=report(images,'current-chat-coverage-parser.private.json')['before']
    after=report(images,'current-chat-coverage-parser.private.json')['after']
    require(same(C._parser_state(state),C._parser_state(before))
            and state['offset']==source['start'] and request['identity']==source['identity']
            and C._parser_runtime()['sha256']==source['parser_sha256'],'parser_review_changed')
    require(type(maximum) is int and 1<=maximum<=48000 and type(scan) is int
            and source['end']-source['start']<=scan<=C.MAX_SCAN,'parser_limits')
    interval=C._interval(request['transcript_path'],source['identity'],source['start'],source['end'])
    require(interval==source['interval_sha256'],'source_changed')
    key=(J.sha256(J.encode(plan)),J.sha256(J.encode(request)),J.sha256(J.encode(state)),
         tuple((name,J.sha256(unseal(images[name]))) for name in sorted(images)),maximum,scan)
    if verified is not None and verified.get('key')==key:
        require(C._interval(request['transcript_path'],source['identity'],source['start'],source['end'])
                ==source['interval_sha256'] and C._parser_runtime()['sha256']==source['parser_sha256'],
                'source_changed')
        return None  # Validation-only callers; sealing still returns the projection.
    excerpt=transcript.read_excerpt(request['transcript_path'],source['start'],max_chars=maximum,
        max_scan_bytes=source['end']-source['start'],recent_messages=before['recent_messages'],
        current_turn_id=before['current_turn_id'],stable_identity=True)
    require(excerpt.blocked_reason is None and excerpt.next_offset==source['end']
            and excerpt.metadata.session_id==plan['session_id'] and excerpt.metadata.identity==source['identity']
            and same(C._next_parser(excerpt),C._parser_state(after))
            and J.sha256(excerpt.text.encode())==source['excerpt_sha256']
            and excerpt.text.encode()==unseal(images['current-chat-coverage-excerpt.private.txt']), 'excerpt_changed')
    # The adopted review hashes exact message bodies, excluding only the fixed
    # role label. Never trim whitespace or separator bytes from the body.
    chunks=excerpt.text.split('\n\n[ASSISTANT]\n')
    require(chunks[0].startswith('[ASSISTANT]\n'),'message_role_changed')
    chunks=[chunks[0]]+['[ASSISTANT]\n'+chunk for chunk in chunks[1:]]
    require(len(chunks)==excerpt.message_count==17 and all(J.sha256(chunk[len('[ASSISTANT]\n'):].encode())==entry['segment_sha256']
        for chunk,entry in zip(chunks,plan['message_dispositions'])),'message_mapping_changed')
    interval=C._interval(request['transcript_path'],source['identity'],source['start'],source['end'])
    require(interval==source['interval_sha256'],'source_changed')
    parser={'version':1,'input':C._parser_state(state),'limits':{'max_chars':maximum,'max_scan_bytes':scan},
            'runtime':C._parser_runtime(),'interval_sha256':interval}
    if verified is not None:
        verified.clear();verified['key']=key
    return excerpt,parser


def _pending_authority(paths,original_raw,*,accounting=False):
    original=J._json(original_raw);L._pending_pause(original,completed=accounting)
    raw,current,_=record(A.state_paths(paths.root,original['session_id'])['pending'])
    L._pending_pause(current,completed=accounting)
    require(same(A.check(paths.root,current),original['admission']),'pending_binding_changed')
    if current['request_id']==original['request_id']:
        require(raw==original_raw,'same_request_changed')
    return True


def _held(paths,request,state_raw,record_before,plan,*,processing,execution):
    binding=A.check(paths.root,request)
    require(binding['mode']==H.MODE_V2 and same(binding,request['admission']),'binding_changed')
    names=A.state_paths(paths.root,request['session_id'])
    current,state,_=record(names['sessions']);_,admitted,_=record(names['admissions'])
    original=J._json(state_raw)
    gate=state.get('reconciliation_required')
    expected_gate={'run_id':plan['legacy_run_id'],'reason':'successful_or_unverified_write',
                   'memory_ids':plan['preserve_without_replay']['memory_ids']}
    if reviewed(plan):
        require(type(gate) is dict and set(gate)==set(expected_gate),'held_state_changed')
        # The legacy runner sorted this inventory; reviewed attempt order is
        # independently bound by history. Preserve both original serializations.
        inventories=(gate['memory_ids'],expected_gate['memory_ids'])
        for ids in inventories:
            require(type(ids) is list and len(ids)<=32,'held_state_changed')
            normalized=[J._uuid(value) for value in ids]
            require(normalized==ids and len(set(normalized))==len(ids),'held_state_changed')
        gate_matches=(gate['run_id']==expected_gate['run_id']
                      and gate['reason']==expected_gate['reason']
                      and set(inventories[0])==set(inventories[1]))
    else:
        gate_matches=same(gate,expected_gate)
    require(current==state_raw and state['session_id']==plan['session_id']==request['session_id']
            and state['last_run']==plan['legacy_run_id'] and state['status']=='reconciliation_required'
            and gate_matches
            and state['identity']==request['identity']==binding['identity']
            and same(state['admission'],binding) and state['transcript_path']==request['transcript_path']
            and state['offset']>=binding['frontier_offset'],'held_state_changed')
    expected={**C._authority(record_before),'processing':processing,'processing_execution':execution}
    require(record_before['state_sha256']==J.durable.object_digest(original)
            and same(C._authority(admitted),expected) and same(admitted['binding'],binding),'held_admission_changed')
    require(same(A.check(paths.root,request),binding),'binding_changed')
    return True


class ResidualContext:
    def __init__(self,paths,manifest,digest,value,context_sha,*,runtime_admission=None):
        self.paths,self.manifest,self.manifest_sha256=paths,copy.deepcopy(manifest),digest
        self.runtime_admission=runtime_admission
        self.value,self.context_sha256=copy.deepcopy(value),context_sha
        self.plan=J._json(unseal(value['review']))
        self.review_sha256=value['review_sha256']
        self.run_id=paths.run_dir.name
        self._source_cache,self._projection_cache,self._history_cache={},{},{}

    @property
    def transport(self): return copy.deepcopy(J._json(J._unseal(self.manifest['inputs']['backend_route']))['transport'])

    def _pinned(self):
        self.paths.check()
        J._keys(self.value,{'version','kind','paths','manifest_sha256','review_sha256','review','reports','history','runtime'})
        require(type(self.value['version']) is int and self.value['version']==1 and self.value['kind']==KIND
                and self.value['paths']==self.paths.check(),'context_changed')
        require(same(self.plan,J._json(unseal(self.value['review']))),'review_plan_changed')
        if self.runtime_admission is None:
            require(same(self.value['runtime'],_runtime(accounting=reviewed(self.plan))),'context_changed')
        else:
            from .residual_runtime_compatibility import RuntimeAdmission
            require(type(self.runtime_admission) is RuntimeAdmission,'invalid_runtime_admission')
            require(self.runtime_admission.old_root == self.paths.plugin_root,'runtime_root_changed')
            self.runtime_admission.verify_runtime(self.value['runtime'],_runtime())
        raw,_=J.durable._read(self.paths.run_dir/'residual-context.json',maximum=MAX)
        require(J.sha256(raw)==self.context_sha256 and raw==J.encode(self.value)
                and J.read_manifest(self.paths.run_dir)[1]==self.manifest_sha256
                and self.value['manifest_sha256']==self.manifest_sha256
                and J.sha256(unseal(self.value['review']))==self.review_sha256,'context_pin_changed')
        decoded=C._decode_inputs(self.paths.base(),self.manifest)
        _store_route(self.paths,decoded['backend_route'])
        _mutation_policy(decoded['backend_config'])
        return decoded

    def validate_frozen_inputs(self,phase='frozen',*,decoded=None):
        decoded=self._pinned() if decoded is None else decoded
        _pending_authority(self.paths,J._unseal(self.manifest['inputs']['request']),accounting=reviewed(self.plan))
        C._source_backend_inputs(self.paths.base(),self.manifest,decoded,source_cache=self._source_cache,
                                 runtime_admission=self.runtime_admission)
        historical(self.paths,self.plan,self.value['reports'],self.value['history'],verified=self._history_cache)
        if reviewed(self.plan):
            require(L._rows(self.paths,self.plan['rows'],count=len(self.plan['rows']))==self.plan['store_identity'],
                    'store_changed')
        else:readback(self.paths,report(self.value['reports'],'current-chat-readback.private.json'))
        parser=decoded['parser_state']
        _source(self.plan,decoded['request'],decoded['cursor'],self.value['reports'],
                parser['limits']['max_chars'],parser['limits']['max_scan_bytes'],verified=self._projection_cache)
        return True

    def validate_inputs(self,manifest,plan,phase):
        require(same(manifest,self.manifest) and same(plan,self.plan),'execution_changed')
        decoded=self._pinned()
        self.validate_frozen_inputs(phase,decoded=decoded)
        pre=phase in {'prepare','before_intent','before_generation','after_generation'}
        execution=None if pre else {'run_id':self.run_id,'manifest_sha256':self.manifest_sha256}
        _held(self.paths,decoded['request'],J._unseal(manifest['inputs']['cursor']),decoded['admission'],self.plan,
              processing=None if pre else decoded['request']['request_id'],execution=execution)
        return True

    def validate_marker(self):
        decoded=self._pinned();self.validate_frozen_inputs('marker',decoded=decoded)
        names=A.state_paths(self.paths.root,self.plan['session_id'])
        _,admitted,_=record(names['admissions'])
        execution=None if admitted.get('processing') is None else {'run_id':self.run_id,'manifest_sha256':self.manifest_sha256}
        return _held(self.paths,decoded['request'],J._unseal(self.manifest['inputs']['cursor']),decoded['admission'],self.plan,
            processing=None if execution is None else decoded['request']['request_id'],execution=execution)


def seal_context(paths,*,reviewed_raw,reviewed_sha256,evidence_directory,host,scope,writer,max_chars,max_scan_bytes):
    require(type(paths) is ResidualPaths,'paths_required');paths.check()
    require(type(writer) is F.HeldFence and writer.mode=='shared'
            and writer._directory==paths.run_dir,'writer_required')
    writer.pass_fds();require(J.sha256(reviewed_raw)==reviewed_sha256,'review_changed')
    plan=review_plan(J._json(reviewed_raw));images=capture_reports(plan,evidence_directory)
    names=A.state_paths(paths.root,plan['session_id'])
    request_raw,request,_=record(names['pending']);state_raw,state,_=record(names['sessions'])
    admission_raw,admitted,_=record(names['admissions'])
    _pending_authority(paths,request_raw,accounting=reviewed(plan))
    require(admitted.get('processing') is None and 'processing_execution' not in admitted,'processing_changed')
    _held(paths,request,state_raw,admitted,plan,processing=None,execution=None)
    history=historical(paths,plan,images)
    def rows():
        if reviewed(plan):
            require(L._rows(paths,plan['rows'],count=len(plan['rows']))==plan['store_identity'],'store_changed')
        else:readback(paths,report(images,'current-chat-readback.private.json'))
    rows()
    excerpt,parser=_source(plan,request,state,images,max_chars,max_scan_bytes)
    config,route=C._backend(paths.base());_store_route(paths,route);_mutation_policy(config)
    inputs={'request':request_raw,'admission':admission_raw,'cursor':state_raw,'parser_state':J.encode(parser),
            'next_parser_state':J.encode(C._next_parser(excerpt)),'backend_route':J.encode(route),'backend_config':J.encode(config)}
    inputs={key:J.seal_json(raw) for key,raw in inputs.items()}
    source={'identity':request['identity'],'start_offset':state['offset'],'end_offset':excerpt.next_offset,
            'excerpt_sha256':J.sha256(excerpt.text.encode())}
    manifest={'version':1,'host':host,'session_id':plan['session_id'],'run_id':paths.run_dir.name,'inputs':inputs,
        'source':source,'expected_scope':scope,'backend':{'route_id':'stdio-'+J.sha256(J.encode(route['launch'])),
            'runtime_sha256':route['runtime']['sha256'],'route_sha256':inputs['backend_route']['sha256'],
            'config_sha256':inputs['backend_config']['sha256']},'fencing':writer.binding()}
    if reviewed(plan):
        manifest.update(plan_origin=L.REVIEWED_ACCOUNTING,review_sha256=reviewed_sha256,
                        plan_policy={'max_tool_calls':5,'max_writes':5})
    J._manifest(manifest)
    def verify(binding):
        writer.verify(binding);_held(paths,request,state_raw,admitted,plan,processing=None,execution=None)
        C._source_backend_inputs(paths.base(),manifest,C._decode_inputs(paths.base(),manifest))
        historical(paths,plan,images,history);rows()
        return True
    digest=J.publish_manifest(paths.run_dir,manifest,verify_fence=verify)
    value={'version':1,'kind':KIND,'paths':paths.check(),'manifest_sha256':digest,'review_sha256':reviewed_sha256,
           'review':image(reviewed_raw),'reports':images,'history':history,'runtime':_runtime(accounting=reviewed(plan))}
    raw=J.encode(value);require(len(raw)<=MAX,'context_limit')
    verify(writer.binding());J._publish(paths.run_dir/'residual-context.json',raw);verify(writer.binding())
    context=ResidualContext(paths,manifest,digest,value,J.sha256(raw));context.validate_marker()
    return context


def load_context(paths,*,manifest_sha256,context_sha256,runtime_profile=None):
    require(type(paths) is ResidualPaths,'paths_required');paths.check()
    manifest,digest=J.read_manifest(paths.run_dir);require(digest==manifest_sha256,'manifest_changed')
    raw,_=J.durable._read(paths.run_dir/'residual-context.json',maximum=MAX)
    require(J.sha256(raw)==context_sha256,'context_changed')
    admission=None
    if runtime_profile is not None:
        from .residual_runtime_compatibility import admit
        admission=admit(runtime_profile,paths.plugin_root)
    context=ResidualContext(paths,manifest,digest,J._json(raw),context_sha256,runtime_admission=admission)
    context._pinned()
    return context
