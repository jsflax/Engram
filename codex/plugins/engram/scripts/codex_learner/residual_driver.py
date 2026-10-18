"""Reviewed-residual controller; no independent cursor authority.

Caller holds worker coordination, supplies a current held-state/history/source/
route validator returning exactly True, and selects a trusted native-only executor.
No provider, legacy memory tool, implicit retry, TTL, queue or cursor mutation.
The existing execution manifest retains every native intent and receipt. These
small generation records grant one reviewed continuation, not a second memory
ledger. New generations require every old shared writer to drain and be durably
revoked. Their native request bytes/operation IDs remain those of the first seal.

Executor(raw, shared_fence, check) must inherit that real SH descriptor, validate
before launch/forward, and drain/reap its owned native child before returning a
strict operation_apply response. The caller explicitly selects the trusted native executor.
The accompanying subprocess fixture qualifies orchestration, not native atomicity.
"""
from __future__ import annotations
import copy
import os
from pathlib import Path
from . import execution_manifest as J, operation_gateway as G
from . import writer_fence as F, operation_probe as P

MAX_GENERATIONS = 32


def require(value, reason):
    if not value:
        raise ValueError('residual_' + reason)


def boundary(label):
    """Process-death fixture seam only."""


def read(path):
    raw = J.durable._read(path, maximum=J.MAX_RECORD)[0]
    return J._json(raw), J.sha256(raw)


def once(path, value, label):
    raw = J.encode(value)
    J._private(path.parent)
    boundary(label + '_before_create')
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        boundary(label + '_created')
        view = memoryview(raw)
        while view:
            written = os.write(fd, view)
            require(written > 0, 'short_write')
            view = view[written:]
        os.fsync(fd)
        boundary(label + '_file_fsynced')
    finally:
        os.close(fd)
    J.durable._fsync(path.parent)
    boundary(label + '_directory_fsynced')
    require(J.durable._read(path, maximum=J.MAX_RECORD)[0] == raw, 'publication_changed')
    return J.sha256(raw)


def _response(value, request):
    J._response(value,request,None)
    if value.get('kind')=='committed':
        receipt=value['receipt']
        # Applied remembers can create automatic edges alongside the new memory.
        # The shared receipt validator above checks every effect ID and its bounds.
        require(len(receipt['memoryIDs'])==1 if receipt['outcome']=='applied'
                else bool(receipt['memoryIDs']) and receipt['edgeIDs']==[],
                'invalid_remember_effect_ids')
    return value


def _plan(value):
    require(type(value) is dict and value.get('kind') == 'reviewed_fresh_residual_plan'
            and value.get('status') == 'reviewed_candidate_not_live_dispatch_authority', 'unreviewed_plan')
    require(value.get('schema_version') == 1 and type(value['schema_version']) is int, 'plan_version')
    J._uuid(value['session_id']); J._identifier(value['legacy_run_id'])
    ops = value.get('operations')
    require(type(ops) is list and len(ops) == 5, 'operation_inventory')
    require([op.get('id') for op in ops] == ['R1','R2','R3','R4','R5'], 'operation_inventory')
    mapping = {1:'R2',2:'R2',12:'R3',14:'R3',15:'R4',16:'R5',17:'R1'}
    messages = value.get('message_dispositions')
    require(type(messages) is list and len(messages) == 17, 'message_inventory')
    for i, item in enumerate(messages, 1):
        require(type(item.get('index')) is int and item['index'] == i, 'message_inventory')
        J._digest(item['segment_sha256'])
        if i in mapping:
            require(item.get('disposition') == 'reviewed_residual'
                    and item.get('operations') == [mapping[i]], 'message_disposition')
        elif i in (11,13):
            require(item.get('disposition') == 'preserved_applied_update'
                    and item.get('memory_ids') == value['preserve_without_replay']['memory_ids'], 'message_disposition')
        else:
            require(item.get('disposition') == 'dated_progress_no_new_durable_fact', 'message_disposition')
    for op in ops:
        args = op['arguments']
        require(op['tool'] == 'remember' and op['review_status'] == 'reviewed_exact_payload'
                and set(args) == {'project','topic','content','source','is_private','force'}
                and args['project'] == 'Engram' and args['topic'] == 'learner-recovery'
                and args['source'] == 'codex-session:' + value['session_id']
                and args['is_private'] is True and args['force'] is False, 'unsupported_residual_policy')
        require(J.sha256(J.encode(args)) == op['arguments_canonical_sha256'], 'review_payload_changed')
        require(op['messages'] == [i for i, label in mapping.items() if label == op['id']], 'message_disposition')
        G.mutation('remember', args)
    return value


class ResidualDriver:
    def __init__(self, run_dir, *, manifest_sha256, review_sha256, validate_inputs):
        self.run = J._private(Path(run_dir))
        self.manifest, digest = J.read_manifest(self.run)
        require(digest == manifest_sha256, 'manifest_changed')
        self.digest, self.review_sha = digest, review_sha256
        self.plan, actual = read(self.run / 'residual-review.json')
        require(actual == review_sha256, 'review_changed')
        _plan(self.plan)
        require(callable(validate_inputs), 'validator_required')
        self.validate_inputs = validate_inputs
        source, old = self.manifest['source'], self.plan['source']
        require(self.manifest['session_id'] == self.plan['session_id']
                and J.encode(source['identity']) == J.encode(old['identity'])
                and source['start_offset'] == old['start'] and source['end_offset'] == old['end']
                and source['excerpt_sha256'] == old['excerpt_sha256'], 'source_binding_changed')
        self.operations = {v['id']: v for v in self.plan['operations']}
        self._expected_cache = {label:self._build_expected(label) for label in self.operations}
        self._authority_cache = None

    @classmethod
    def prepare(cls, run_dir, *, reviewed_raw, reviewed_sha256, manifest_sha256,
                writer, validate_inputs):
        require(J.sha256(reviewed_raw) == reviewed_sha256, 'review_changed')
        plan = _plan(J._json(reviewed_raw))
        manifest, actual = J.read_manifest(run_dir)
        require(actual == manifest_sha256 and type(writer) is F.HeldFence
                and writer.mode == 'shared', 'writer_required')
        writer.verify(manifest['fencing']); writer.pass_fds()
        require(validate_inputs(copy.deepcopy(manifest), copy.deepcopy(plan), 'prepare') is True,
                'input_validation_refused')
        J._publish(Path(run_dir) / 'residual-review.json', reviewed_raw)
        driver = cls(run_dir, manifest_sha256=manifest_sha256, review_sha256=reviewed_sha256,
                     validate_inputs=validate_inputs)
        for label in driver.operations:
            driver._check('before_intent', writer=writer, recoveries=[])
            call, raw = driver._expected(label)
            J.publish_intent(run_dir, call, raw, verify_fence=writer.verify)
        driver._inventory()
        driver._check('before_generation', writer=writer, recoveries=[])
        once(driver._generation_path(0), driver._generation(0, writer.binding(), None, None, list(driver.operations)), 'generation')
        driver._check('after_generation', writer=writer, recoveries=[])
        return driver

    def _expected(self, label):
        return self._expected_cache[label]

    def _build_expected(self, label):
        call = G.call_key(label)
        source = self.manifest['source']
        request = {'version':1,'operationID':J.operation_id(self.run, call),
            'expectedScope':self.manifest['expected_scope'], 'provenance':{
                'host':self.manifest['host'],'sessionID':self.manifest['session_id'],
                'runID':self.manifest['run_id'],'source':{'startOffset':source['start_offset'],
                    'endOffset':source['end_offset'],'excerptDigest':source['excerpt_sha256']}},
            'mutation':G.mutation('remember', self.operations[label]['arguments'])}
        raw = J.encode(request)
        J._request(raw, self.manifest, request['operationID'])
        return call, raw

    def _intent(self, label):
        call, expected = self._expected(label)
        operation = J._json(expected)['operationID']
        raw, request = J.read_intent(self.run, operation)
        require(raw == expected, 'intent_changed')
        return operation, raw, request

    def _inventory(self):
        expected = {'operation-' + self._intent(label)[0] + '.json' for label in self.operations}
        entries = list(self.run.iterdir())
        require(len(entries) <= 4096, 'directory_limit')
        require({p.name for p in entries if p.name.startswith('operation-')} == expected, 'unexpected_intent')
        evidence={'evidence-'+self._intent(label)[0] for label in self.operations}
        require({p.name for p in entries if p.name.startswith('evidence-')} <= evidence,'unexpected_evidence')

    def _generation_path(self, index):
        return self.run / f'residual-generation-{index:03d}.json'

    def _generation(self, index, binding, previous, checkpoint, allowed):
        return {'version':1,'kind':'reviewed_residual_generation','manifest_sha256':self.digest,
                'review_sha256':self.review_sha,'index':index,'previous_sha256':previous,
                'reconciliation_sha256':checkpoint,'fencing':binding,'allowed':allowed,
                'requests':{label:J.sha256(self._expected(label)[1]) for label in self.operations}}

    def _authority_snapshot(self):
        # Cache parsing only, never disk state. Every use re-reads bounded owned
        # regular files and compares exact bytes, identity and filename inventory.
        # New evidence, replacement, truncation or removal invalidates the cache.
        result={};total=0
        entries=list(self.run.iterdir())
        require(len(entries)<=4096,'directory_limit')
        def retain(path):
            nonlocal total
            raw,identity=J.durable._read(path,maximum=J.MAX_RECORD)
            total+=len(raw)
            require(total<=32*1024*1024 and len(result)<4096,'evidence_limit')
            result[str(path.relative_to(self.run))]={'sha256':J.sha256(raw),'identity':identity}
        for path in entries:
            name=path.name
            if name in ('execution-manifest.json','residual-review.json') or name.startswith(
                    ('operation-','residual-generation-','residual-dispatch-','residual-reconciliation-')):
                retain(path)
            elif name.startswith('evidence-'):
                directory=J.durable._directory(path)
                J._private(path)
                result[name]={'directory_identity':J.durable._identity(directory)}
                children=list(path.iterdir())
                require(len(children)<=J.MAX_EVENTS,'evidence_limit')
                for child in children:retain(child)
        return result

    def _generations(self):
        snapshot=self._authority_snapshot()
        if self._authority_cache is not None and snapshot==self._authority_cache[0]:
            return copy.deepcopy(self._authority_cache[1])
        result=self._read_generations()
        require(snapshot==self._authority_snapshot(),'evidence_changed_during_validation')
        self._authority_cache=(snapshot,copy.deepcopy(result))
        return result

    def _read_generations(self):
        self._inventory()
        for label in self.operations:J.read_evidence(self.run,self._intent(label)[0])
        paths = sorted(p for p in self.run.iterdir() if p.name.startswith('residual-generation-'))
        require(0 < len(paths) <= MAX_GENERATIONS, 'generation_inventory')
        result, previous = [], None
        for index, path in enumerate(paths):
            require(path == self._generation_path(index), 'generation_sequence')
            gen, digest = read(path)
            F.validate_binding(gen['fencing'])
            allowed = gen['allowed']
            require(type(allowed) is list and allowed
                    and allowed == [x for x in self.operations if x in allowed], 'allowed_inventory')
            if index == 0:
                require(J.encode(gen['fencing']) == J.encode(self.manifest['fencing'])
                        and allowed == list(self.operations), 'initial_generation_changed')
                checkpoint = None
            else:
                proof, checkpoint = read(self.run / f'residual-reconciliation-{index-1:03d}.json')
                self._checkpoint(proof, result)
                require(allowed == [k for k,v in proof['statuses'].items() if v['kind'] == 'absent'], 'continuation_authority_changed')
                require(not any(v.get('receipt',{}).get('outcome') == 'unchanged' for v in proof['statuses'].values()), 'semantic_review_required')
                require(all(J.encode(gen['fencing']) != J.encode(old[0]['fencing'])
                            and gen['fencing']['epoch_id'] != old[0]['fencing']['epoch_id']
                            and gen['fencing']['lock_identity']['inode'] != old[0]['fencing']['lock_identity']['inode']
                            for old in result), 'generation_reused')
            require(J.encode(gen) == J.encode(self._generation(index,gen['fencing'],previous,checkpoint,allowed)), 'generation_changed')
            result.append((gen,digest)); previous=digest
        checkpoints=[p for p in self.run.iterdir() if p.name.startswith('residual-reconciliation-')]
        expected={f'residual-reconciliation-{i:03d}.json':i for i in range(len(result))}
        for path in checkpoints:
            require(path.name in expected,'checkpoint_inventory')
            self._checkpoint(read(path)[0],result[:expected[path.name]+1])
        # A dispatch record is immutable and consumed even when process death
        # precedes forwarding. It can only be retried through a later generation.
        dispatches = [p for p in self.run.iterdir() if p.name.startswith('residual-dispatch-')]
        require(len(dispatches) <= MAX_GENERATIONS * 5, 'dispatch_limit')
        for path in dispatches:
            item,_ = read(path)
            index,label=item['generation'],item['label']
            require(type(index) is int and 0 <= index < len(result) and label in self.operations,
                    'dispatch_binding_changed')
            require(path == self._dispatch_path(index,label) and label in result[index][0]['allowed']
                    and J.encode(item) == J.encode(self._dispatch_record(index,label,result[index][1])), 'dispatch_binding_changed')
        return result

    def _held(self, *, writer=None, recoveries):
        current, digest = J.read_manifest(self.run)
        require(digest == self.digest and read(self.run/'residual-review.json')[1] == self.review_sha, 'input_pin_changed')
        generations = self._generations() if self._generation_path(0).exists() else []
        expected = len(generations) if writer is None else max(0,len(generations)-1)
        require(type(recoveries) is list and len(recoveries) == expected, 'all_prior_generations_required')
        for held,(gen,_) in zip(recoveries,generations):
            require(type(held) is F.HeldFence and held.mode == 'exclusive', 'revoked_exclusive_required')
            held.verify(gen['fencing'])
        if writer is not None:
            require(type(writer) is F.HeldFence and writer.mode == 'shared', 'shared_writer_required')
            writer.verify(generations[-1][0]['fencing'] if generations else current['fencing'])
            writer.pass_fds()
        return current

    def _check(self, phase, *, writer=None, recoveries):
        current=self._held(writer=writer,recoveries=recoveries)
        require(self.validate_inputs(copy.deepcopy(current), copy.deepcopy(self.plan),phase) is True, 'input_validation_refused')
        return True

    def _journal_verifier(self, writer, recoveries, *, retain_response=False):
        held = recoveries[0] if recoveries else writer
        def verify(binding):
            if retain_response:
                self._held(writer=writer,recoveries=recoveries)
            else:
                self._check('journal_evidence',writer=writer,recoveries=recoveries)
            return held.verify(binding)
        return verify

    def _dispatch_path(self, index, label):
        return self.run / f'residual-dispatch-{index:03d}-{label}.json'

    def _dispatch_record(self,index,label,generation_sha):
        operation,raw,_=self._intent(label)
        return {'version':1,'generation':index,'generation_sha256':generation_sha,'label':label,
                'operation_id':operation,'request_sha256':J.sha256(raw),'manifest_sha256':self.digest,
                'review_sha256':self.review_sha}

    def dispatch(self,label,*,writer,recoveries,execute):
        """One operation only; callback is trusted process code, never plan data."""
        self._check('before_dispatch',writer=writer,recoveries=recoveries); self._inventory()
        generations=self._generations(); index=len(generations)-1; gen,digest=generations[-1]
        require(label in gen['allowed'] and callable(execute), 'dispatch_not_authorized')
        before=self.summary()
        require(not before['invalid_operations'] and not before['unchanged'], 'semantic_or_evidence_hold')
        require(not any(os.path.lexists(self._dispatch_path(index,other))
                        and other in before['unsettled'] for other in self.operations),
                'current_generation_unsettled')
        operation,raw,request=self._intent(label)
        require(label not in before['committed'], 'already_committed')
        once(self._dispatch_path(index,label),self._dispatch_record(index,label,digest),'dispatch')
        verify=self._journal_verifier(writer,recoveries)
        if index == 0:
            require(J.record_dispatch(self.run,operation,verify_fence=verify) == raw, 'request_changed')
        self._check('before_forward',writer=writer,recoveries=recoveries)
        boundary('before_execute')
        try:
            message=execute(raw,writer,lambda phase:self._check(phase,writer=writer,recoveries=recoveries))
            boundary('after_execute')
            self._held(writer=writer,recoveries=recoveries)
            require(type(message) is dict and set(message)=={'jsonrpc','id','result'}
                    and message['jsonrpc']=='2.0' and message['id']==operation, 'invalid_rpc_response')
            value=G.envelope(message['result'])
            require(set(value)=={'version','kind','receipt'} and value['kind']=='committed','invalid_apply_response')
            response=_response({'kind':'committed','receipt':value['receipt']},request)
            J.record_response(self.run,operation,response,verify_fence=
                self._journal_verifier(writer,recoveries,retain_response=True))
        except (OSError,ValueError,RuntimeError,KeyError,TypeError):
            # Known earlier applied IDs remain independently readable even if
            # this response/evidence is malformed or the validator now refuses.
            try: J.record_response(self.run,operation,{'kind':'unavailable','reason':'transport_error'},verify_fence=verify)
            except (OSError,ValueError,RuntimeError,KeyError,TypeError): pass
            return self.summary()
        boundary('after_receipt')
        try:
            # Retaining a returned commit does not renew dispatch authority.
            # Context can change after the native transaction; preserve the
            # receipt/IDs, then hold further work until current validation passes.
            self._check('after_response',writer=writer,recoveries=recoveries)
            self._check('after_receipt',writer=writer,recoveries=recoveries)
        except (OSError,ValueError,RuntimeError,KeyError,TypeError):
            result=self.summary();result['status']='reconciliation_required'
            result['current_inputs_validated']=False
            return result
        return self.summary()

    def _heads(self):
        result={}
        for label in self.operations:
            operation,_,_=self._intent(label); events=J.read_evidence(self.run,operation)
            require(bool(events), 'missing_status')
            result[label]=J.sha256(J.durable._read(self.run/f'evidence-{operation}'/f'{len(events)-1:06d}.json',maximum=J.MAX_RECORD)[0])
        return result

    def _checkpoint(self, proof, generations):
        require(set(proof)=={'version','generation_sha256s','manifest_sha256','review_sha256','statuses','heads'}
                and type(proof['version']) is int and proof['version']==1
                and proof['generation_sha256s']==[v[1] for v in generations]
                and proof['manifest_sha256']==self.digest and proof['review_sha256']==self.review_sha
                and set(proof['statuses'])==set(self.operations) and set(proof['heads'])==set(self.operations), 'checkpoint_changed')
        for label in self.operations:
            operation,_,request=self._intent(label)
            status=proof['statuses'][label]
            require(status.get('kind') in ('committed','absent'),'uncertain_status')
            _response(status,request)
            events=J.read_evidence(self.run,operation)
            matching=[e for e in events if J.sha256(J.encode(e))==proof['heads'][label]]
            require(len(matching)==1 and J.encode(matching[0]['evidence'])==J.encode(status),'checkpoint_evidence_changed')

    def reconcile(self,*,recoveries,probe):
        """Probe must be trusted read-only status code. No native writer FD here."""
        self._check('before_status',recoveries=recoveries); self._inventory()
        generations=self._generations(); index=len(generations)-1
        require(callable(probe),'probe_required')
        checkpoint_path=self.run/f'residual-reconciliation-{index:03d}.json'
        if os.path.lexists(checkpoint_path):
            proof,_=read(checkpoint_path)
            self._checkpoint(proof,generations)
            require(proof['heads']==self._heads(),'status_changed_since_checkpoint')
            self._check('after_existing_status_checkpoint',recoveries=recoveries)
            return self.summary()
        requests=[self._intent(k)[2] for k in self.operations]
        responses=probe(copy.deepcopy(requests),recoveries[0],lambda phase:self._check(phase,recoveries=recoveries))
        # A successfully returned status is an observation of the original
        # native operation. Retain strict receipts under the original immutable
        # intent and real revoked fences even if current authority has changed.
        # This does not authorize a checkpoint, continuation or publication.
        self._held(recoveries=recoveries)
        require(type(responses) is list and len(responses)==len(requests),'status_inventory')
        statuses={}
        for label,response in zip(self.operations,responses):
            operation,_,request=self._intent(label)
            require(response.get('kind') in ('committed','absent'),'uncertain_status')
            _response(response,request)
            self._held(recoveries=recoveries)
            J.record_response(self.run,operation,response,verify_fence=
                self._journal_verifier(None,recoveries,retain_response=True))
            statuses[label]=copy.deepcopy(response)
        try:
            self._check('after_status',recoveries=recoveries)
        except (OSError,ValueError,RuntimeError,KeyError,TypeError):
            result=self.summary();result['status']='reconciliation_required'
            result['current_inputs_validated']=False
            return result
        proof={'version':1,'generation_sha256s':[v[1] for v in generations],
               'manifest_sha256':self.digest,'review_sha256':self.review_sha,'statuses':statuses,'heads':self._heads()}
        self._check('before_status_checkpoint',recoveries=recoveries)
        # A complete identical proof is safely recoverable; a changed/partial
        # checkpoint requires review. No second status round overwrites history.
        J._publish(self.run/f'residual-reconciliation-{index:03d}.json',J.encode(proof))
        self._checkpoint(proof,generations)
        self._check('after_status_checkpoint',recoveries=recoveries)
        return self.summary()

    def continue_generation(self,*,recoveries,new_writer):
        self._check('before_continuation',recoveries=recoveries); self._inventory()
        generations=self._generations(); index=len(generations)
        require(index<MAX_GENERATIONS and type(new_writer) is F.HeldFence
                and new_writer.mode=='shared','new_shared_writer_required')
        binding=new_writer.binding();new_writer.pass_fds()
        proof,digest=read(self.run/f'residual-reconciliation-{index-1:03d}.json')
        self._checkpoint(proof,generations)
        require(proof['heads']==self._heads(),'status_changed_since_checkpoint')
        require(not any(v.get('receipt',{}).get('outcome')=='unchanged' for v in proof['statuses'].values()),'semantic_review_required')
        allowed=[k for k in self.operations if proof['statuses'][k]['kind']=='absent']
        require(bool(allowed),'nothing_to_continue')
        for gen,_ in generations:
            require(binding['epoch_id']!=gen['fencing']['epoch_id']
                    and binding['lock_identity']['inode']!=gen['fencing']['lock_identity']['inode'],'generation_reused')
        self._check('before_continuation_publish',recoveries=recoveries)
        new_writer.verify(binding)
        once(self._generation_path(index),self._generation(index,binding,generations[-1][1],digest,allowed),'generation')
        self._check('after_continuation',writer=new_writer,recoveries=recoveries)
        return index

    def summary(self):
        """Content-free, no publication/provider success or coverage authority."""
        result={'status':'reconciliation_required','committed':[],'applied':[],'unchanged':[],
                'memory_ids':[],'invalid_operations':[],'unsettled':[],
                'historical_provider_success':False,'successful_coverage':False,'cursor_authority':False,
                'execution_evidence_valid':True,
                'preserved_legacy_memory_ids':copy.deepcopy(self.plan['preserve_without_replay']['memory_ids'])}
        try:
            self._inventory();self._generations()
            require(J.read_manifest(self.run)[1]==self.digest
                    and read(self.run/'residual-review.json')[1]==self.review_sha,'input_pin_changed')
        except (OSError,ValueError,RuntimeError,KeyError,TypeError):result['execution_evidence_valid']=False
        for label in self.operations:
            try:
                operation,_,_=self._intent(label); events=J.read_evidence(self.run,operation)
                receipts=[e['evidence']['receipt'] for e in events if e['evidence']['kind']=='committed']
                if receipts:
                    receipt=receipts[-1];_response({'kind':'committed','receipt':receipt},self._intent(label)[2])
                    result['committed'].append(label)
                    result[receipt['outcome']].append(label)
                    if receipt['outcome']=='applied': result['memory_ids'].extend(J._uuid(v) for v in receipt['memoryIDs'])
                if not events or events[-1]['evidence']['kind']!='committed': result['unsettled'].append(label)
            except (OSError,ValueError,RuntimeError,KeyError,TypeError): result['invalid_operations'].append(label)
        result['memory_ids']=sorted(set(result['memory_ids']))
        if result['execution_evidence_valid'] and len(result['applied'])==len(self.operations) and not result['unsettled'] and not result['invalid_operations']:
            result['status']='residuals_applied_reviewed_publication_pending'
        elif result['unchanged']: result['status']='semantic_review_required'
        return result
