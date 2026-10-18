"""Durable zero-intent classification and actual worker/publication regressions."""
import contextlib
import copy
import importlib
import json
import os
from pathlib import Path
import stat
import unittest
from unittest import mock

import test_runner_publication as fixtures
from suite_support import PLUGIN_ROOT

R, C, J, F = fixtures.R, fixtures.C, fixtures.J, fixtures.F
S, Q, P = R.settlement, R.coordinator, R.publication
SID, write_json = fixtures.SID, fixtures.write_json
runner = importlib.import_module('codex_learner.runner')


class ZeroIntentRetryTests(unittest.TestCase):
    def setUp(self):
        self.f = fixtures.RunnerPublicationTests(methodName='runTest')
        self.f.setUp(); self.addCleanup(self.f.doCleanups)
        self.root, self.service = self.f.f.root, self.f.service
        self.f.f.request['size_bytes'] = self.f.f.path.stat().st_size
        write_json(self.f.pending, self.f.f.request)
        for name in S.PINNED_DURABLE_0151:
            path = self.f.f.plugin / 'scripts/codex_learner' / name
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            path.write_bytes((PLUGIN_ROOT / 'scripts/codex_learner' / name).read_bytes())
            path.chmod(0o600)
        self.config = {**runner.DEFAULTS, **self.f.config, 'min_chars': 0, 'max_runs_per_worker': 2}
        self.observation = {'started': True, 'terminated': True, 'returncode': 1,
            'turn_completed': False, 'provider_error': True, 'unexpected_tool': False,
            'tool_errors': 0, 'reason': None}

    def startup(self, *, old=False):
        self.execution = self.f.begin(); self.addCleanup(self.execution.close)
        self.run = self.execution.paths.run_dir
        write_json(self.run / 'transport.json', self.f.proxy_config(self.execution))
        S.record_provider_dispatch(self.run, self.execution.context.manifest_sha256,
            lambda manifest, phase: self.execution.context.validate_inputs(manifest, 'before_forward'))
        S.persist_observation(self.run, self.observation)
        if old:
            compute = S._compute
            def old_compute(*args, **kwargs):
                return compute(*args, **{**kwargs, 'zero_intent': False})
            with mock.patch.object(S, '_compute', side_effect=old_compute):
                self.assertEqual(self.f.finish(self.execution), 'reconciliation_required')
            self.original = (self.run / 'settlement.json').read_bytes()
        return self.execution

    def prepare(self):
        return self.service.prepare_zero_intent_retry(SID, self.config)

    def finish(self, ready):
        try:
            with self.f.locks():
                return self.service.finish_zero_intent_retry(ready)
        finally:
            ready.close()

    def assert_failed(self):
        state = json.loads(self.f.f.state_path.read_bytes())
        self.assertEqual(state['status'], 'failed')
        self.assertNotIn('reconciliation_required', state)
        self.assertEqual(C._parser_state(state), C._parser_state(self.f.f.state))
        self.assertEqual((self.run / 'settlement.json').read_bytes(), self.original)
        self.assertFalse((self.run / 'successful-coverage.json').exists())
        self.assertEqual(list(self.run.glob('operation-*')), [])
        self.assertEqual(self.f.status_probe_mock.call_count, 0)
        return state

    def test_normal_settlement_classifies_bound_zero_intent_as_failed(self):
        execution = self.startup()
        self.assertEqual(self.f.finish(execution), 'failed')
        value = json.loads((self.run / 'settlement.json').read_bytes())
        self.assertEqual(value['reason'], 'verified_zero_intent_failure')
        self.assertEqual(value['attempted_write_calls'], 0)
        self.assertEqual(value['memory_ids'], [])
        self.assertIn('gateway_contract', value['zero_intent_proof'])
        self.assertFalse((self.run / 'successful-coverage.json').exists())

    def test_old_hold_uses_derived_receipt_and_ignores_new_ambient_path(self):
        self.startup(old=True)
        before = json.loads(self.f.f.state_path.read_bytes())
        with mock.patch.dict(os.environ, {'PATH': '/different/ephemeral/codex/path'}):
            ready = self.prepare(); self.assertIsNotNone(ready)
            self.assertEqual(self.finish(ready), 'failed')
        state = self.assert_failed()
        self.assertEqual(state['retry_after'], before['retry_after'])
        receipt = json.loads((self.run / S.ZERO_RETRY).read_bytes())
        self.assertEqual(receipt['original_settlement']['sha256'], J.sha256(self.original))
        self.assertEqual(receipt['status'], 'failed')
        self.assertEqual(json.loads(self.f.pending.read_bytes())['pause_reason'], 'failed')

    def test_unbound_or_unknown_gateway_and_nonempty_evidence_refuse(self):
        for bad in ('no_execution', 'wrong_manifest', 'wrong_route', 'unknown_gateway',
                    'partial_intent', 'orphan', 'noncanonical_operation', 'partial_retry', 'replaced_known_gateway'):
            with self.subTest(bad=bad):
                self.setUp(); self.startup(old=True); before=self.f.current()
                if bad in ('no_execution', 'wrong_manifest', 'wrong_route'):
                    config=json.loads((self.run/'transport.json').read_bytes())
                    if bad=='no_execution': del config['execution']
                    elif bad=='wrong_manifest': config['execution']['manifest_sha256']='0'*64
                    else: config['transport']['command']='/unbound'
                    write_json(self.run/'transport.json',config)
                elif bad=='unknown_gateway':
                    (self.f.f.plugin/'scripts/codex_learner/memory_proxy.py').write_bytes(b'raw fallback')
                elif bad=='replaced_known_gateway':
                    path=self.f.f.plugin/'scripts/codex_learner/memory_proxy.py';raw=path.read_bytes();path.unlink();path.write_bytes(raw);path.chmod(0o600)
                elif bad=='partial_intent':
                    write_json(self.run/'operation-11111111-2222-4333-8444-555555555555.json',{})
                elif bad=='orphan': (self.run/'evidence-11111111-2222-4333-8444-555555555555').mkdir(mode=0o700)
                elif bad=='noncanonical_operation': write_json(self.run/'operation-unknown.tmp',{})
                else: (self.run/S.ZERO_RETRY).write_bytes(b'{')
                with self.assertRaises((ValueError, OSError, TypeError)): self.prepare()
                self.assertEqual(self.f.current(),before)
                self.assertEqual((self.run/'settlement.json').read_bytes(),self.original)

    def test_changed_owner_source_policy_and_settlement_refuse(self):
        for bad in ('not_terminated','unexpected_tool','source','policy','settlement','owner_replaced'):
            with self.subTest(bad=bad):
                self.setUp(); self.startup(old=True); before=self.f.current()
                if bad in ('not_terminated','unexpected_tool'):
                    value=json.loads((self.run/'provider-observation.json').read_bytes())
                    if bad=='not_terminated': value['observation'].update(terminated=False,returncode=None)
                    else: value['observation']['unexpected_tool']=True
                    write_json(self.run/'provider-observation.json',value)
                elif bad=='source':
                    with self.f.f.path.open('r+b') as f: f.seek(self.f.f.frontier); f.write(b'X')
                elif bad=='policy':
                    value=json.loads((self.root/'admission.json').read_bytes());value['enabled']=False
                    write_json(self.root/'admission.json',value)
                elif bad=='settlement': (self.run/'settlement.json').write_bytes(self.original+b' ')
                else:
                    path=self.run/'provider-observation.json';raw=path.read_bytes();path.unlink();write_json(path,J._json(raw))
                with self.assertRaises((ValueError,OSError,TypeError)): self.prepare()
                self.assertEqual(self.f.current(),before)

    def test_newer_pending_and_last_event_survive_preparation_interleaving(self):
        self.startup(old=True); ready=self.prepare(); self.addCleanup(ready.close)
        receipt=(self.run/S.ZERO_RETRY).read_bytes()
        value=json.loads(self.f.f.record_path.read_bytes());value['last_event']='b'*64
        runner.atomic_json(self.f.f.record_path,value)
        newer={**self.f.f.request,'request_id':'newer-request','turn_id':'later-turn'}
        write_json(self.f.pending,newer); pending=self.f.pending.read_bytes()
        # A pre-index crash/re-entry keeps the same receipt despite last_event.
        ready.close();ready=self.prepare()
        self.assertEqual((self.run/S.ZERO_RETRY).read_bytes(),receipt)
        self.assertEqual(self.finish(ready),'failed');self.assert_failed()
        self.assertEqual(self.f.pending.read_bytes(),pending)
        self.assertEqual(json.loads(self.f.f.record_path.read_bytes())['last_event'],'b'*64)

    def test_crash_after_first_pair_replacement_recovers_exact_transition(self):
        self.startup(old=True);ready=self.prepare()
        class Crash(BaseException): pass
        def stop(label):
            if label=='admission_replaced': raise Crash()
        with self.assertRaises(Crash), mock.patch.object(P,'_boundary',side_effect=stop):
            self.finish(ready)
        self.assertTrue((self.service.paths(SID).session_directory/'active.json').exists())
        ready=self.prepare();self.assertIsNotNone(ready)
        self.assertEqual(self.finish(ready),'failed');self.assert_failed()
        self.assertFalse((self.service.paths(SID).session_directory/'active.json').exists())
        self.assertIsNone(self.prepare())

    def test_explicit_resume_releases_eligible_hold_but_preserves_backoff(self):
        self.startup(old=True)
        with mock.patch.object(runner,'publications',return_value=self.service), mock.patch.object(runner,'event_log'):
            self.assertFalse(runner.resume_pending(self.root,SID,spawn=False))
            state=self.assert_failed();self.assertEqual(json.loads(self.f.pending.read_bytes())['pause_reason'],'failed')
            with mock.patch.object(runner.time,'time',return_value=state['retry_after']+1), \
                 mock.patch.object(runner,'publications',side_effect=AssertionError('ordinary resume needs no proof preparation')):
                self.assertTrue(runner.resume_pending(self.root,SID,spawn=False))
        self.assertNotIn('pause_reason',json.loads(self.f.pending.read_bytes()))

    def test_natural_hook_worker_reaches_new_read_only_plan_without_old_replay(self):
        self.startup(old=True)
        state=json.loads(self.f.f.state_path.read_bytes());calls=[]
        payload={'session_id':SID,'transcript_path':str(self.f.f.path),'cwd':str(self.f.f.project),
                 'hook_event_name':'Stop','turn_id':'new-hook'}
        def provider(root,run,request,excerpt,config):
            manifest,_=J.read_manifest(run)
            self.assertEqual(manifest['provider_mode'],'read_only_plan')
            self.assertNotEqual(run,self.run);calls.append(run)
            return {'status':'failed','reason':'fixture_provider_no_plan'}
        with mock.patch.object(runner,'publications',return_value=self.service), \
             mock.patch.object(runner,'event_log'),mock.patch.object(runner,'spawn_worker') as spawn, \
             mock.patch.object(runner,'settings',return_value=self.config), \
             mock.patch.object(runner,'provider_slot',return_value=contextlib.nullcontext()), \
             mock.patch.object(runner,'run_planner',side_effect=provider), \
             mock.patch.object(runner.time,'time',return_value=state['retry_after']+1):
            self.assertFalse(runner.enqueue(self.root,payload))
            spawn.assert_called_once()
            self.assertEqual(runner.worker(self.root),0)
        self.assertEqual(len(calls),1)
        self.assertEqual((self.run/'settlement.json').read_bytes(),self.original)
        self.assertEqual(list(self.run.glob('operation-*')),[])
        self.assertEqual(C._parser_state(json.loads(self.f.f.state_path.read_bytes())),C._parser_state(self.f.f.state))
        self.assertEqual(self.f.status_probe_mock.call_count,0)

    def test_explicit_resume_preserves_and_wakes_newer_unpaused_request(self):
        self.startup(old=True)
        newer={**self.f.f.request,'request_id':'newer-request','turn_id':'later-turn'}
        write_json(self.f.pending,newer); before=self.f.pending.read_bytes()
        with mock.patch.object(runner,'publications',return_value=self.service), \
             mock.patch.object(runner,'event_log'),mock.patch.object(runner,'spawn_worker') as spawn:
            self.assertTrue(runner.resume_pending(self.root,SID))
            spawn.assert_called_once()
        self.assert_failed();self.assertEqual(self.f.pending.read_bytes(),before)

    def test_durable_transport_replaced_after_dispatch_cannot_create_proof(self):
        self.startup(old=True);before=self.f.current()
        path=self.run/'transport.json';raw=path.read_bytes()
        path.unlink();path.write_bytes(raw);path.chmod(0o600)
        with self.assertRaisesRegex(ValueError,'configuration_installed_after_dispatch'):
            self.prepare()
        self.assertEqual(self.f.current(),before)
        self.assertEqual((self.run/'settlement.json').read_bytes(),self.original)

    def test_crash_after_published_receipt_recovers_queue_without_republishing_pair(self):
        self.startup(old=True);ready=self.prepare()
        class Crash(BaseException): pass
        def stop(label):
            if label=='publication_complete': raise Crash()
        with self.assertRaises(Crash),mock.patch.object(P,'_boundary',side_effect=stop):
            self.finish(ready)
        pair=(self.f.f.state_path.read_bytes(),self.f.f.record_path.read_bytes())
        ready=self.prepare();self.assertEqual(self.finish(ready),'failed')
        self.assertEqual((self.f.f.state_path.read_bytes(),self.f.f.record_path.read_bytes()),pair)
        self.assert_failed();self.assertEqual(json.loads(self.f.pending.read_bytes())['pause_reason'],'failed')

    def test_current_runtime_pins_and_zero_failure_reader_remain_strict(self):
        pins=importlib.import_module('codex_learner.residual_runtime_compatibility')
        self.assertEqual(set(pins.CURRENT_HASHES),set(pins.OLD_HASHES));self.assertEqual(len(pins.CURRENT_HASHES),11)
        for name,digest in pins.CURRENT_HASHES.items():
            self.assertEqual(J.sha256((PLUGIN_ROOT/'scripts/codex_learner'/name).read_bytes()),digest)
        execution=self.startup();self.assertEqual(self.f.finish(execution),'failed')
        from importlib import util
        path=PLUGIN_ROOT/'skills/hook-status/scripts/hook_status.py'
        spec=util.spec_from_file_location('zero_retry_hook_status',path)
        status=util.module_from_spec(spec);spec.loader.exec_module(status)
        raw=(self.run/'settlement.json').read_bytes()
        view=status.linked_settlement(self.root,self.run.name,SID,J.sha256(raw))
        self.assertEqual(view['binding'],'session_hash_match')
        self.assertEqual(view['metadata']['reason'],'verified_zero_intent_failure')
        for field,value in [('status','succeeded'),('attempted_write_calls',1),('applied_write_calls',1)]:
            altered=json.loads(raw);altered[field]=value;write_json(self.run/'settlement.json',altered)
            view=status.linked_settlement(self.root,self.run.name,SID,J.sha256((self.run/'settlement.json').read_bytes()))
            self.assertEqual(view['read']['read_status'],'invalid_json')

    def install_inventory(self, root):
        files=[]
        for name in S.PINNED_DURABLE_0151:
            relative='scripts/codex_learner/'+name;path=root/relative
            raw,identity=S.durable._read(path,private=False)
            permissions=stat.S_IMODE(identity.pop('mode'))
            files.append({'path':relative,'sha256':J.sha256(raw),'bytes':len(raw),
                          'identity':{**identity,'mode':oct(permissions),'type':stat.S_IFREG}})
        return {'root':str(root),'files':files,'directories':[],
                'total_bytes':sum(row['bytes'] for row in files)}

    def restored_install(self, *, old=True):
        # The fixture is a known contract with real pre-dispatch and restored
        # inode/ctime records. Production keeps the fixed release hashes.
        plugin=self.f.f.plugin
        known={name:J.sha256((plugin/'scripts/codex_learner'/name).read_bytes())
               for name in S.PINNED_DURABLE_0151}
        self.enterContext(mock.patch.object(S,'PINNED_DURABLE_0151',known))
        before=self.install_inventory(plugin)
        self.startup(old=old)
        directory=self.root/'install-evidence';directory.mkdir(mode=0o700)
        saved=directory/'backup';saved.mkdir(mode=0o700)
        for name in known:
            source=plugin/'scripts/codex_learner'/name
            target=saved/'scripts/codex_learner'/name
            target.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
            target.write_bytes(source.read_bytes());target.chmod(0o600)
        before_path=directory/'before.json';write_json(before_path,{'inventory':before})
        backup={'status':'verified','source_stable_before_after':True,
                'backup_new_inodes_not_source_identity':True,
                'before_manifest_sha256':J.sha256(before_path.read_bytes()),
                'source_after':self.install_inventory(plugin),'backup_inventory':self.install_inventory(saved)}
        for name in known:
            path=plugin/'scripts/codex_learner'/name;raw=path.read_bytes()
            path.unlink();path.write_bytes(raw);path.chmod(0o600)
        restored={'disposition':'restored_only_absent_old_cache',
                  'original_contents_preserved':True,'uninterrupted_availability_claim':False,
                  'inventory':self.install_inventory(plugin)}
        self.install_records={'before':{'inventory':before},'backup':backup,'restored':restored}
        self.install_directory=directory
        self.write_install_authority()

    def write_install_authority(self):
        value={'version':1,'kind':'reviewed_gateway_install_continuity','approved':True,
               'plugin_root':str(self.f.f.plugin)}
        for role,record in self.install_records.items():
            path=self.install_directory/(role+'.json');write_json(path,record)
            value[role]={'path':str(path),'sha256':J.sha256(path.read_bytes())}
        # The backup schema binds the actual before bytes.
        self.install_records['backup']['before_manifest_sha256']=value['before']['sha256']
        path=self.install_directory/'backup.json';write_json(path,self.install_records['backup'])
        value['backup']['sha256']=J.sha256(path.read_bytes())
        write_json(self.root/S.INSTALL_AUTHORITY,value)

    def test_reviewed_install_continuity_preserves_old_receipt_cursor_backoff_and_retry(self):
        self.restored_install();before=json.loads(self.f.f.state_path.read_bytes())
        with mock.patch.dict(os.environ,{'PATH':'/new/ambient/path'}):
            ready=self.prepare();self.assertEqual(self.finish(ready),'failed')
        state=self.assert_failed();self.assertEqual(state['retry_after'],before['retry_after'])
        proof=json.loads((self.run/S.ZERO_RETRY).read_bytes())['proof']['install_continuity']
        self.assertEqual(proof['authority']['sha256'],J.sha256((self.root/S.INSTALL_AUTHORITY).read_bytes()))
        with mock.patch.object(runner.time,'time',return_value=state['retry_after']+1), \
             mock.patch.object(runner,'publications',side_effect=AssertionError('ordinary retry only')):
            self.assertTrue(runner.resume_pending(self.root,SID,spawn=False))

    def test_reviewed_install_authority_absent_false_changed_or_unsafe_refuses(self):
        for bad in ('absent','false','wrong_root','unknown_map','symlink','evidence_hash','evidence_replaced'):
            with self.subTest(bad=bad):
                self.setUp();self.restored_install();before=self.f.current()
                authority=self.root/S.INSTALL_AUTHORITY;value=json.loads(authority.read_bytes())
                if bad=='absent': authority.unlink()
                elif bad=='symlink':
                    raw=authority.read_bytes();authority.unlink();target=self.root/'other.json'
                    target.write_bytes(raw);target.chmod(0o600);authority.symlink_to(target)
                elif bad=='evidence_hash': (self.install_directory/'backup.json').write_bytes(b'{}')
                elif bad=='evidence_replaced':
                    # Changed after preparation is rejected even when the bytes match.
                    ready=self.prepare();self.addCleanup(ready.close)
                    path=self.install_directory/'backup.json';raw=path.read_bytes();path.unlink()
                    path.write_bytes(raw);path.chmod(0o600)
                    with self.assertRaises((ValueError,OSError)):self.finish(ready)
                    self.assertEqual(self.f.current(),before);continue
                else:
                    if bad=='false': value['approved']=False
                    elif bad=='wrong_root': value['plugin_root']=str(self.root)
                    else: value['hashes']={'runner.py':'0'*64}
                    write_json(authority,value)
                with self.assertRaises((ValueError,OSError)):self.prepare()
                self.assertEqual(self.f.current(),before)

    def test_reviewed_install_rejects_incomplete_altered_or_late_history(self):
        for bad in ('missing_file','wrong_hash','duplicate','late_original','wrong_original_identity',
                    'wrong_restored_identity','not_absent_restore','unstable_source','changed_backup','bool_identity'):
            with self.subTest(bad=bad):
                self.setUp();self.restored_install();before=self.f.current();records=self.install_records
                if bad=='missing_file':records['backup']['backup_inventory']['files'].pop()
                elif bad=='wrong_hash':records['before']['inventory']['files'][0]['sha256']='0'*64
                elif bad=='duplicate':records['before']['inventory']['files'].append(records['before']['inventory']['files'][0])
                elif bad=='late_original':
                    for inventory in (records['before']['inventory'],records['backup']['source_after']):
                        inventory['files'][0]['identity']['ctime_ns']=2**63
                elif bad=='wrong_original_identity':records['backup']['source_after']['files'][0]['identity']['inode']+=1
                elif bad=='wrong_restored_identity':records['restored']['inventory']['files'][0]['identity']['inode']+=1
                elif bad=='not_absent_restore':records['restored']['disposition']='partial_merge'
                elif bad=='unstable_source':records['backup']['source_stable_before_after']=False
                elif bad=='bool_identity':records['before']['inventory']['files'][0]['identity']['uid']=True
                else: records['backup']['backup_inventory']['files'][0]['sha256']='1'*64
                self.write_install_authority()
                with self.assertRaises((ValueError,OSError)):self.prepare()
                self.assertEqual(self.f.current(),before)

    def test_reviewed_install_does_not_admit_unknown_contract_or_mutation_evidence(self):
        for bad in ('unknown_source','current_replacement','intent','orphan','transport','live_owner','unexpected_tool'):
            with self.subTest(bad=bad):
                self.setUp();self.restored_install();before=self.f.current()
                if bad in ('unknown_source','current_replacement'):
                    path=self.f.f.plugin/'scripts/codex_learner/runner.py';raw=path.read_bytes()
                    path.unlink();path.write_bytes(raw if bad=='current_replacement' else b'unknown');path.chmod(0o600)
                elif bad=='intent':write_json(self.run/'operation-11111111-2222-4333-8444-555555555555.json',{})
                elif bad=='orphan':(self.run/'evidence-11111111-2222-4333-8444-555555555555').mkdir(mode=0o700)
                elif bad=='transport':
                    path=self.run/'transport.json';raw=path.read_bytes();path.unlink();path.write_bytes(raw);path.chmod(0o600)
                else:
                    value=json.loads((self.run/'provider-observation.json').read_bytes())
                    if bad=='live_owner':value['observation'].update(terminated=False,returncode=None)
                    else:value['observation']['unexpected_tool']=True
                    write_json(self.run/'provider-observation.json',value)
                with self.assertRaises((ValueError,OSError)):self.prepare()
                self.assertEqual(self.f.current(),before)

    def test_reviewed_install_authority_is_rechecked_across_metadata_crash(self):
        self.restored_install();ready=self.prepare()
        newer={**self.f.f.request,'request_id':'newer-request','turn_id':'later-turn'}
        write_json(self.f.pending,newer);pending=self.f.pending.read_bytes()
        class Crash(BaseException):pass
        def stop(label):
            if label=='admission_replaced':raise Crash()
        with self.assertRaises(Crash),mock.patch.object(P,'_boundary',side_effect=stop):self.finish(ready)
        pair=(self.f.f.state_path.read_bytes(),self.f.f.record_path.read_bytes())
        authority=self.root/S.INSTALL_AUTHORITY;raw=authority.read_bytes();value=json.loads(raw)
        value['approved']=False;write_json(authority,value)
        with self.assertRaises(ValueError):self.prepare()
        self.assertEqual((self.f.f.state_path.read_bytes(),self.f.f.record_path.read_bytes()),pair)
        self.assertEqual(self.f.pending.read_bytes(),pending)
        self.assertEqual((self.run/'settlement.json').read_bytes(),self.original)

    def test_reviewed_install_unchanged_authority_recovers_crash_and_newer_pending(self):
        self.restored_install();ready=self.prepare()
        newer={**self.f.f.request,'request_id':'newer-request','turn_id':'later-turn'}
        write_json(self.f.pending,newer);pending=self.f.pending.read_bytes()
        class Crash(BaseException):pass
        def stop(label):
            if label=='publication_complete':raise Crash()
        with self.assertRaises(Crash),mock.patch.object(P,'_boundary',side_effect=stop):self.finish(ready)
        ready=self.prepare();self.assertEqual(self.finish(ready),'failed');self.assert_failed()
        self.assertEqual(self.f.pending.read_bytes(),pending)

    def test_reviewed_install_is_not_automatic_normal_settlement_authority(self):
        self.restored_install(old=False)
        self.assertEqual(self.f.finish(self.execution),'reconciliation_required')
        value=json.loads((self.run/'settlement.json').read_bytes())
        self.assertNotIn('zero_intent_proof',value)
