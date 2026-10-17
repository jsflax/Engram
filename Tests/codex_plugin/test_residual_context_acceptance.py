"""Independent held context and publication acceptance; synthetic stores only."""
import contextlib
import copy
import dataclasses
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import unittest
import uuid
from unittest import mock
from residual_context_fixture import ResidualContextFixture, RC, C, J, SID, SUCCESS_ID, PREVIOUS_RUN, write_json
from residual_test_support import runtime
RP = runtime('residual_publication')

HARNESS_POPEN=subprocess.Popen


class ResidualContextAcceptanceTests(unittest.TestCase):
    def fixture(self, *, sealed=True,prepared=True):
        f=ResidualContextFixture();self.addCleanup(f.close)
        if sealed:f.seal(prepare_driver=prepared)
        return f

    @contextlib.contextmanager
    def no_processes(self):
        with contextlib.ExitStack() as guards:
            for module,name in ((subprocess,'Popen'),(subprocess,'run'),(subprocess,'call'),(os,'system'),(socket,'socket')):
                guards.enter_context(mock.patch.object(module,name,side_effect=AssertionError('provider/native/network forbidden')))
            yield

    def change_intent_payload(self,path):
        document=J._json(path.read_bytes());request=J._json(J._unseal(document['request']))
        request['mutation']['request']['content']+=' Unreviewed payload alteration.'
        raw=J.encode(request)
        document['request']=J.seal_json(raw);document['local_json_sha256']=J.sha256(raw)
        path.write_bytes(J.encode(document))

    def test_seal_and_reload_preserve_held_cursor_history_store_and_pending(self):
        f=self.fixture(sealed=False)
        before,history,store=f.current(),f.history_snapshot(),f.store.read_bytes()
        with self.no_processes():
            c=f.seal()
            self.assertIs(c.validate_marker(),True)
            loaded=RC.load_context(f.paths,manifest_sha256=c.manifest_sha256,context_sha256=c.context_sha256)
            self.assertIs(loaded.validate_marker(),True)
        self.assertEqual(f.current(),before)
        self.assertEqual(f.history_snapshot(),history)
        self.assertEqual(f.store.read_bytes(),store)
        self.assertEqual(len(f.driver.operations),5)
        self.assertEqual(f.driver.summary()['committed'],[])
        for name in ('provider-observation.json','provider-dispatch.json','successful-coverage.json'):
            self.assertFalse((f.run_dir/name).exists())

    def test_source_mutation_truncation_and_replacement_refuse_without_cursor_change(self):
        for change in ('content','truncate','replace'):
            with self.subTest(change=change):
                f=self.fixture();before=f.current();raw=f.path.read_bytes()
                if change=='content':f.path.write_bytes(raw[:f.start]+raw[f.start:].replace(b'PRIVATE',b'CHANGED',1))
                elif change=='truncate':f.path.write_bytes(raw[:-1])
                else:
                    replacement=f.base/'replacement.jsonl';replacement.write_bytes(raw);replacement.chmod(0o600)
                    os.replace(replacement,f.path)
                with self.no_processes(),self.assertRaises(ValueError):f.context.validate_marker()
                self.assertEqual(f.current(),before)

    def test_selected_old_update_semantics_must_remain_exact(self):
        f=self.fixture();before=f.current()
        for column,value in (('content','changed'),('project','changed'),('source','changed'),
                             ('modifiedAt',1.0),('expiresAt',None),('deletedAt',1.0)):
            with self.subTest(column=column):
                original=f.row_values[0][column]
                with contextlib.closing(sqlite3.connect(f.store)) as db:
                    db.execute('UPDATE Memory SET '+column+'=? WHERE globalId=?',(value,SUCCESS_ID));db.commit()
                changed=f.store.read_bytes()
                with self.no_processes(),self.assertRaises(ValueError):f.context.validate_marker()
                self.assertEqual(f.current(),before);self.assertEqual(f.store.read_bytes(),changed)
                with contextlib.closing(sqlite3.connect(f.store)) as db:
                    db.execute('UPDATE Memory SET '+column+'=? WHERE globalId=?',(original,SUCCESS_ID));db.commit()

    def test_gate_policy_processing_and_parser_change_refuse(self):
        f=self.fixture()
        changes=[(f.state_path,{**f.state,'offset':f.start+1}),
            (f.state_path,{**f.state,'reconciliation_required':{**f.state['reconciliation_required'],'reason':'changed'}}),
            (f.record_path,{**f.record,'processing':'other-request'}),
            (f.root/'admission.json',{**f.policy,'enabled':False})]
        for path,value in changes:
            with self.subTest(path=path.name,keys=sorted(value)):
                raw=path.read_bytes();write_json(path,value);before=f.current()
                with self.no_processes(),self.assertRaises(ValueError):f.context.validate_marker()
                self.assertEqual(f.current(),before);path.write_bytes(raw)

    def test_runtime_route_config_and_history_change_refuse(self):
        for target in ('runtime','config','provider.jsonl','run.json'):
            with self.subTest(target=target):
                f=self.fixture();before=f.current()
                path=getattr(f,target) if target in ('runtime','config') else f.historical_run_dir/target
                if target=='config':
                    # The sealed backend pins resolved configuration, so change
                    # the effective store route rather than TOML whitespace.
                    path.write_text(path.read_text().replace(str(f.store),str(f.store)+'.changed'))
                else:path.write_bytes(path.read_bytes()+b' ')
                with self.no_processes(),self.assertRaises(ValueError):f.context.validate_marker()
                self.assertEqual(f.current(),before)

    def test_wrong_selected_store_route_refuses_before_sealing(self):
        f=self.fixture(sealed=False);before=f.current();history=f.history_snapshot();store=f.store.read_bytes()
        other=f.base/'different.sqlite';shutil.copyfile(f.store,other);other.chmod(0o600)
        f.config.write_text(f.config.read_text().replace(str(f.store),str(other)))
        with self.no_processes(),self.assertRaisesRegex(ValueError,'store_route_changed'):f.seal()
        self.assertEqual(f.current(),before);self.assertEqual(f.history_snapshot(),history)
        self.assertEqual(f.store.read_bytes(),store)
        self.assertFalse((f.run_dir/'execution-manifest.json').exists())
        self.assertFalse((f.run_dir/'residual-context.json').exists())

    def test_exact_message_body_hash_does_not_accept_role_prefix_or_extra_whitespace(self):
        for changed_body in ('role_prefix','newline'):
            with self.subTest(changed_body=changed_body):
                f=self.fixture(sealed=False);before=f.current();store=f.store.read_bytes()
                text=('[ASSISTANT]\n'+f.messages[0]) if changed_body=='role_prefix' else f.messages[0]+'\n'
                f.plan['message_dispositions'][0]['segment_sha256']=J.sha256(text.encode())
                f.make_reports()
                with self.no_processes(),self.assertRaisesRegex(ValueError,'message_mapping_changed'):f.seal()
                self.assertEqual(f.current(),before);self.assertEqual(f.store.read_bytes(),store)
                self.assertFalse((f.run_dir/'execution-manifest.json').exists())

    def test_wrong_initial_writer_directory_or_run_id_refuses_before_sealing(self):
        for invalid in ('writer_directory','run_id'):
            with self.subTest(invalid=invalid):
                f=self.fixture(sealed=False);before=f.current();f.writer.close()
                directory=(f.base/'wrong-writer') if invalid=='writer_directory' else f.root/'runs'/'invalid-run'
                directory.mkdir(mode=0o700)
                binding=RC.F.create(directory,generation_id=str(uuid.uuid4()),owner_id=str(uuid.uuid4()))
                f.writer=RC.F.acquire_shared(directory,binding);f.handles.append(f.writer)
                if invalid=='run_id':f.paths=dataclasses.replace(f.paths,run_dir=directory)
                with self.no_processes(),self.assertRaises(ValueError):f.seal()
                self.assertEqual(f.current(),before)
                self.assertFalse((directory/'execution-manifest.json').exists())
                self.assertFalse((f.run_dir/'execution-manifest.json').exists())

    def test_sealed_reports_survive_import_directory_removal_and_later_source_append(self):
        f=self.fixture();before=f.current();history=f.history_snapshot()
        shutil.rmtree(f.evidence)
        f.append('PRIVATE later source message beyond the reviewed interval.')
        with self.no_processes():self.assertIs(f.context.validate_marker(),True)
        self.assertEqual(f.current(),before);self.assertEqual(f.history_snapshot(),history)
        self.assertGreater(f.path.stat().st_size,f.end)
        self.assertFalse(f.evidence.exists())

    def test_tampered_context_plan_or_intent_refuses_direct_authority_reads(self):
        f=self.fixture()
        paths=[(f.run_dir/'residual-context.json',f.context.validate_marker),
               (f.run_dir/'residual-review.json',lambda:type(f.driver)(f.run_dir,
                    manifest_sha256=f.context.manifest_sha256,review_sha256=f.context.review_sha256,
                    validate_inputs=f.context.validate_inputs)),
               (f.run_dir/('operation-'+f.driver._intent('R1')[0]+'.json'),lambda:f.driver._intent('R1'))]
        for path,check in paths:
            with self.subTest(path=path.name):
                raw=path.read_bytes()
                if path.name.startswith('operation-'):self.change_intent_payload(path)
                else:path.write_bytes(raw+b' ')
                before=f.current()
                with self.no_processes(),self.assertRaises(ValueError):check()
                self.assertEqual(f.current(),before);path.write_bytes(raw)

    def test_five_applied_residuals_publish_qualified_cursor_and_preserve_originals(self):
        for newer in (False,True):
            with self.subTest(newer_pending=newer):
                f=self.fixture(prepared=False);history=f.history_snapshot();old_rows=f.rows();old_state=f.state_path.read_bytes()
                with self.no_processes(),f.locks() as verify:
                    f.begin(verify)
                    self.assertEqual(f.state_path.read_bytes(),old_state)
                    self.assertEqual(J._json(f.record_path.read_bytes())['processing'],f.request['request_id'])
                    if newer:f.newer_pending()
                    pending=f.pending_path.read_bytes()
                    for label in f.driver.operations:
                        result=f.dispatch(label)
                        self.assertEqual(result['applied'],list(f.driver.operations)[:int(label[1:])])
                        self.assertEqual(f.state_path.read_bytes(),old_state)
                    f.revoke();receipt=f.finish(verify)
                    first=f.current()
                    self.assertIsNone(RP.recover_locked(f.paths,session_id=SID,verify_locks=verify))
                    self.assertEqual(f.current(),first)
                state=J._json(f.state_path.read_bytes());record=J._json(f.record_path.read_bytes())
                self.assertEqual(state['offset'],f.end)
                self.assertEqual(C._parser_state(state),C._next_parser(f.excerpt))
                self.assertEqual(state['status'],'legacy_reconciled_with_residuals')
                self.assertNotIn('reconciliation_required',state)
                self.assertEqual(state['last_run'],f.state['last_run'])
                for key in ('last_success','successful_runs','last_successful_run'):
                    self.assertEqual(state.get(key),f.state.get(key))
                self.assertEqual(f.pending_path.read_bytes(),pending)
                self.assertIsNone(record['processing']);self.assertNotIn('processing_execution',record)
                self.assertEqual(f.history_snapshot(),history)
                rows=f.rows();self.assertEqual(len(rows),len(old_rows)+5)
                self.assertEqual([r for r in rows if r['globalId'] in {v['globalId'] for v in old_rows}],old_rows)
                new_ids=set(receipt['reference']['new_memory_ids'])
                self.assertEqual(new_ids,{r['globalId'] for r in rows}-{r['globalId'] for r in old_rows})
                self.assertEqual(receipt['reference']['preserved_memory_ids'],[SUCCESS_ID])
                self.assertEqual(receipt['applied_write_count'],5)
                self.assertIs(receipt['provider_invoked'],False)
                self.assertEqual(receipt['historical_run_status'],'failed')
                self.assertIs(receipt['historical_execution_sealed'],False)
                self.assertEqual(receipt['source_binding_grade'],'current_bounded_reconstruction')
                for name in ('provider-observation.json','provider-dispatch.json','successful-coverage.json'):
                    self.assertFalse((f.run_dir/name).exists())

    def test_marker_is_required_before_dispatch_and_bad_guard_prevents_marker(self):
        f=self.fixture();before=f.current();execute=mock.Mock(side_effect=AssertionError('must not execute'))
        with self.no_processes(),self.assertRaises(ValueError):
            f.driver.dispatch('R1',writer=f.writer,recoveries=[],execute=execute)
        execute.assert_not_called();self.assertEqual(f.current(),before)
        for guard in (lambda:False,lambda:None,lambda:1,None):
            with self.subTest(guard=guard),self.no_processes(),self.assertRaisesRegex(ValueError,'caller_locks_changed'):
                RP.begin(f.context,writer=f.writer,verify_locks=guard)
            self.assertEqual(f.current(),before)

    def test_manual_pause_refuses_before_seal_or_dispatch_and_preserves_pending(self):
        for stage in ('before_seal','same_request','newer_request'):
            with self.subTest(stage=stage):
                f=self.fixture(sealed=False)
                if stage!='before_seal':
                    f.seal(prepare_driver=False)
                    with f.locks() as verify:f.begin(verify)
                if stage=='newer_request':f.newer_pending()
                pending=J._json(f.pending_path.read_bytes())
                pending.update(paused_request_id=pending['request_id'],pause_reason='manual_review_required')
                write_json(f.pending_path,pending);before=f.current();rows=f.rows()
                with self.no_processes(),self.assertRaises(ValueError):
                    f.seal() if stage=='before_seal' else f.dispatch('R1')
                self.assertEqual(f.current(),before);self.assertEqual(f.rows(),rows)
                self.assertFalse(list(f.base.glob('synthetic-native-receipt-*')))

    def test_marked_intent_tamper_refuses_before_synthetic_native_commit(self):
        f=self.fixture(prepared=False)
        with self.no_processes(),f.locks() as verify:
            f.begin(verify);before=f.current();rows=f.rows()
            path=f.run_dir/('operation-'+f.driver._intent('R1')[0]+'.json')
            self.change_intent_payload(path)
            with self.assertRaises(ValueError):f.dispatch('R1')
            self.assertEqual(f.current(),before);self.assertEqual(f.rows(),rows)

    def test_finish_refuses_missing_applied_receipts_without_advancing_cursor(self):
        f=self.fixture(prepared=False)
        with self.no_processes(),f.locks() as verify:
            f.begin(verify);f.dispatch('R1');f.revoke();before=f.current()
            with self.assertRaisesRegex(ValueError,'residual_memory_ids_changed|residuals_not_qualified'):f.finish(verify)
            self.assertEqual(f.current(),before)
            self.assertEqual(f.driver.summary()['applied'],['R1'])
            self.assertFalse((f.run_dir/'residual-receipt.json').exists())

    def test_recovery_publishes_all_applied_then_passive_completed_receipt_is_noop(self):
        f=self.fixture(prepared=False);history=f.history_snapshot()
        with self.no_processes(),f.locks() as verify:
            f.begin(verify)
            for label in f.driver.operations:f.dispatch(label)
        f.release_fences();before=f.current();rows=f.rows()
        self.assertTrue(RP.needs_recovery(f.root,SID))
        with self.no_processes(),f.locks() as verify,f.synthetic_probe():
            receipt=RP.recover_locked(f.paths,session_id=SID,verify_locks=verify)
            completed=f.current()
            self.assertIsNotNone(receipt);self.assertEqual(J._json(completed[0])['offset'],f.end)
            self.assertEqual(completed[2],before[2])
            with mock.patch.object(RP.R,'load_context',side_effect=AssertionError('completed recovery must be passive')):
                self.assertIsNone(RP.recover_locked(f.paths,session_id=SID,verify_locks=verify))
            self.assertEqual(f.current(),completed)
        self.assertFalse(RP.needs_recovery(f.root,SID))
        self.assertEqual(f.rows(),rows);self.assertEqual(f.history_snapshot(),history)

    def test_missing_or_malformed_processing_reference_remains_discoverable(self):
        for mutation in ('missing','malformed'):
            with self.subTest(mutation=mutation):
                f=self.fixture(prepared=False)
                with f.locks() as verify:f.begin(verify)
                path=f.run_dir/'processing-publication.json'
                if mutation=='missing':path.unlink()
                else:path.write_bytes(b'{')
                before=f.current();f.release_fences()
                self.assertTrue(RP.needs_recovery(f.root,SID))
                with self.no_processes(),f.locks() as verify,f.synthetic_probe(),self.assertRaises((OSError,ValueError)):
                    RP.recover_locked(f.paths,session_id=SID,verify_locks=verify)
                self.assertEqual(f.current(),before)

    def test_current_processing_marker_takes_precedence_over_an_older_retained_reference(self):
        f=self.fixture(sealed=False)
        prior={'version':1,'id':str(uuid.uuid4()),'legacy_run_id':PREVIOUS_RUN,'run_id':PREVIOUS_RUN,
            **{key:'c'*64 for key in ('manifest_sha256','context_sha256','review_sha256','settlement_sha256')},
            'interval':{'start_offset':f.start,'end_offset':f.end,'interval_sha256':'d'*64,'excerpt_sha256':'e'*64},
            'preserved_memory_ids':[SUCCESS_ID],'new_memory_ids':[str(uuid.uuid4()) for _ in range(5)]}
        RP._state_reference(prior)
        f.state['last_residual_reconciliation']=prior
        f.record['state_sha256']=J.durable.object_digest(f.state)
        write_json(f.state_path,f.state);write_json(f.record_path,f.record);f.make_reports();f.seal(prepare_driver=False)
        with self.no_processes(),f.locks() as verify:f.begin(verify)
        selected=RP.recovery_reference(f.root,SID)
        self.assertEqual(selected['run_id'],f.run_dir.name)
        self.assertEqual(selected['context_sha256'],f.context.context_sha256)
        self.assertTrue(RP.needs_recovery(f.root,SID))

    def test_recovery_context_or_guard_change_keeps_applied_ids_and_cursor_held(self):
        for change in ('source','old_row','guard'):
            with self.subTest(change=change):
                f=self.fixture(prepared=False)
                with self.no_processes(),f.locks() as verify:
                    f.begin(verify)
                    f.dispatch('R1')
                f.release_fences();before=f.current();ids=f.driver.summary()['memory_ids']
                if change=='source':
                    raw=f.path.read_bytes();f.path.write_bytes(raw[:f.start]+raw[f.start:].replace(b'PRIVATE',b'CHANGED',1))
                elif change=='old_row':
                    with contextlib.closing(sqlite3.connect(f.store)) as db:
                        db.execute('UPDATE Memory SET source=? WHERE globalId=?',('changed',SUCCESS_ID));db.commit()
                with self.no_processes(),f.locks() as verify,f.synthetic_probe(),self.assertRaises(ValueError):
                    RP.recover_locked(f.paths,session_id=SID,verify_locks=(lambda:False) if change=='guard' else verify)
                self.assertEqual(f.current(),before);self.assertEqual(f.driver.summary()['memory_ids'],ids)
                self.assertFalse((f.run_dir/'residual-receipt.json').exists())

    def test_commit_receipt_survives_immediate_old_row_change_without_publication(self):
        f=self.fixture(prepared=False)
        with self.no_processes(),f.locks() as verify:
            f.begin(verify);before=f.current()
            def execute(raw,writer,check):
                message=f.execute(raw,writer,check)
                with contextlib.closing(sqlite3.connect(f.store)) as db:
                    db.execute('UPDATE Memory SET source=? WHERE globalId=?',('changed-after-commit',SUCCESS_ID));db.commit()
                return message
            result=f.driver.dispatch('R1',writer=f.writer,recoveries=[],execute=execute)
            self.assertEqual(result['applied'],['R1']);self.assertEqual(len(result['memory_ids']),1)
            self.assertEqual(result['status'],'reconciliation_required')
            self.assertIs(result['current_inputs_validated'],False)
            self.assertEqual(f.current(),before)
            self.assertEqual(J.read_evidence(f.run_dir,f.driver._intent('R1')[0])[-1]['evidence']['kind'],'committed')
            with self.assertRaises(ValueError):f.dispatch('R2')


class ResidualPublicationCrashTests(unittest.TestCase):
    fixture=ResidualContextAcceptanceTests.fixture
    no_processes=ResidualContextAcceptanceTests.no_processes

    def kill_at(self,f,action,boundary):
        spec=f.child_spec();f.release_fences()
        child=HARNESS_POPEN([sys.executable,'-B',str(Path(__file__).with_name('residual_context_crash_child.py')),
                            str(spec),action,boundary],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:out,err=child.communicate(timeout=900)
        except subprocess.TimeoutExpired:
            child.kill();child.communicate(timeout=5);self.fail('crash fixture timed out')
        self.assertEqual(child.returncode,-signal.SIGKILL,(boundary,out.decode(),err.decode()))

    def test_final_publication_sigkill_prefixes_recover_exactly_once(self):
        # The unchanged coordinator already has a full prefix matrix. These
        # exercise the new partial pair and retired/missing-receipt adapter paths.
        boundaries=('state_replaced','active_unlinked')
        for boundary in boundaries:
            with self.subTest(boundary=boundary):
                f=self.fixture(prepared=False);history=f.history_snapshot()
                with self.no_processes(),f.locks() as verify:
                    f.begin(verify)
                    for label in f.driver.operations:f.dispatch(label)
                    f.newer_pending()
                rows=f.rows();pending=f.pending_path.read_bytes()
                self.kill_at(f,'recover',boundary)
                with self.no_processes(),f.locks() as verify,f.synthetic_probe():
                    RP.recover_locked(f.paths,session_id=SID,verify_locks=verify)
                    settled=f.current()
                    self.assertIsNone(RP.recover_locked(f.paths,session_id=SID,verify_locks=verify))
                    self.assertEqual(f.current(),settled)
                self.assertEqual(J._json(settled[0])['offset'],f.end)
                self.assertEqual(f.pending_path.read_bytes(),pending)
                self.assertEqual(f.rows(),rows);self.assertEqual(f.history_snapshot(),history)
                self.assertFalse(RP.needs_recovery(f.root,SID))

    def test_marker_sigkill_recovery_keeps_cursor_and_does_not_dispatch(self):
        for boundary in ('active_unlinked',):
            with self.subTest(boundary=boundary):
                f=self.fixture(prepared=False);before=f.current();rows=f.rows();history=f.history_snapshot()
                self.kill_at(f,'begin',boundary)
                self.assertTrue(RP.needs_recovery(f.root,SID))
                with self.no_processes(),f.locks() as verify,f.synthetic_probe(),self.assertRaisesRegex(ValueError,'reviewed_continuation'):
                    RP.recover_locked(f.paths,session_id=SID,verify_locks=verify)
                self.assertEqual(f.state_path.read_bytes(),before[0])
                self.assertEqual(f.pending_path.read_bytes(),before[2])
                self.assertEqual(f.rows(),rows);self.assertEqual(f.history_snapshot(),history)
                driver=RP._driver(f.context,lambda:True)
                self.assertEqual(driver.summary()['memory_ids'],[])


if __name__=='__main__':unittest.main()
