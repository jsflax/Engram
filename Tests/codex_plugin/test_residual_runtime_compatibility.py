"""Closed predecessor admission against synthetic sealed private fixtures.

No native executable, live store or provider is used. Only the predecessor file
contents/hashes are substituted; the closed inventory, safe reads, successor
pins, parser equivalence, current authority and existing driver stay real.
"""
import contextlib
import copy
import dataclasses
import io
import json
from pathlib import Path
import shutil
import socket
import subprocess
import unittest
from unittest import mock
from residual_context_fixture import ResidualContextFixture, RC, C, J, SID, write_json
from residual_test_support import runtime
import learner_residual as CLI
K = runtime('residual_runtime_compatibility')


class ResidualRuntimeCompatibilityTests(unittest.TestCase):
    def fixture(self, *, begun=False, profile=K.PROFILE):
        f = ResidualContextFixture(); self.addCleanup(f.close)
        old = f.base / 'old-plugin'; directory = old / 'scripts/codex_learner'
        directory.mkdir(parents=True, mode=0o700)
        hashes = {}
        for name in K.OLD_HASHES:
            raw = ('# synthetic predecessor ' + name + '\n').encode()
            path = directory / name; path.write_bytes(raw); path.chmod(0o600)
            hashes[name] = J.sha256(raw)
        parser = directory / 'transcript.py'
        parser.write_bytes(Path(C.transcript.__file__).read_bytes()); parser.chmod(0o600)
        patch = mock.patch.object(K, 'OLD_HASHES' if profile==K.PROFILE else 'RELEASED_HASHES', hashes)
        patch.start(); self.addCleanup(patch.stop)
        f.plugin = old; f.paths = dataclasses.replace(f.paths, plugin_root=old)
        sealed_runtime = {n:{'path':str(directory/n), 'sha256':h} for n,h in hashes.items()}
        old_parser = {'path':str(parser), 'sha256':K.PARSER_SHA256}
        with mock.patch.object(RC, '_runtime', return_value=sealed_runtime), \
             mock.patch.object(C, '_parser_runtime', return_value=old_parser):
            f.seal(prepare_driver=False)
        f.context = self.load(f,profile=profile)
        if begun:
            with f.locks() as verify: f.begin(verify)
        return f

    def load(self, f, *, profile=K.PROFILE):
        return RC.load_context(f.paths, manifest_sha256=f.context.manifest_sha256,
            context_sha256=f.context.context_sha256, runtime_profile=profile)

    @contextlib.contextmanager
    def no_processes(self):
        with contextlib.ExitStack() as stack:
            for module,name in ((subprocess,'Popen'),(subprocess,'run'),(socket,'socket')):
                stack.enter_context(mock.patch.object(module,name,side_effect=AssertionError('native/provider/network forbidden')))
            yield

    def arguments(self,f,command):
        return [command,'--root',str(f.root),'--config',str(f.config),'--package-root',str(f.plugin),
            '--candidate-store',str(f.store),'--session-id',SID,'--run-id',f.run_dir.name,
            '--manifest-sha256',f.context.manifest_sha256,'--context-sha256',f.context.context_sha256,
            '--runtime-compatibility',K.PROFILE]

    def invoke(self,args):
        output=io.StringIO()
        with self.no_processes(),contextlib.redirect_stdout(output):code=CLI.main(args)
        self.assertNotIn('PRIVATE',output.getvalue())
        return code,json.loads(output.getvalue())

    def test_explicit_load_preserves_old_seals_and_default_stays_strict(self):
        f=self.fixture();before={n:(f.run_dir/n).read_bytes() for n in ('execution-manifest.json','residual-context.json')}
        state=f.current();history=f.history_snapshot();rows=f.rows()
        with self.no_processes():
            with self.assertRaises(ValueError):self.load(f,profile=None)
            self.assertIs(self.load(f).validate_marker(),True)
            f.append('PRIVATE appended beyond original interval')
            self.assertIs(self.load(f).validate_marker(),True)
        self.assertEqual(before,{n:(f.run_dir/n).read_bytes() for n in before})
        self.assertEqual(f.current(),state);self.assertEqual(f.history_snapshot(),history);self.assertEqual(f.rows(),rows)

    def test_admitted_context_reuses_semantics_but_revalidates_all_pin_bytes(self):
        f=self.fixture();context=self.load(f)
        with self.no_processes(), mock.patch.object(RC,'validate_history',wraps=RC.validate_history) as history, \
             mock.patch.object(C.transcript,'read_excerpt',wraps=C.transcript.read_excerpt) as parse, \
             mock.patch.object(K,'_hash',wraps=K._hash) as hashes:
            for _ in range(3):self.assertIs(context.validate_marker(),True)
            self.assertEqual(history.call_count,1)
            self.assertEqual(parse.call_count,2)
            old=f.plugin/'scripts/codex_learner/operation_probe.py'
            current=Path(C.__file__).with_name('operation_probe.py')
            self.assertEqual(sum(call.args==(old,) for call in hashes.call_args_list),3)
            self.assertEqual(sum(call.args==(current,) for call in hashes.call_args_list),3)
            path=f.historical_run_dir/'provider.jsonl';path.write_bytes(path.read_bytes()+b' ')
            with self.assertRaises(ValueError):context.validate_marker()

    def test_every_old_runtime_file_is_freshly_checked(self):
        f=self.fixture();context=self.load(f);context.validate_marker()
        for name in K.OLD_HASHES:
            with self.subTest(name=name):
                path=f.plugin/'scripts/codex_learner'/name;raw=path.read_bytes();path.write_bytes(raw+b'# changed\n')
                with self.no_processes(),self.assertRaises(ValueError):context.validate_marker()
                path.write_bytes(raw)
        context.validate_marker()

    def test_current_bundle_changed_bytes_missing_file_and_mixed_paths_refuse(self):
        f=self.fixture();old=f.context.value['runtime'];current=RC._runtime()
        copyroot=f.base/'new-plugin';directory=copyroot/'scripts/codex_learner';directory.mkdir(parents=True)
        for name in K.CURRENT_HASHES:
            shutil.copyfile(Path(current[name]['path']),directory/name)
        shutil.copyfile(Path(C.transcript.__file__),directory/'transcript.py')
        running={n:{'path':str(directory/n),'sha256':h} for n,h in K.CURRENT_HASHES.items()}
        with mock.patch.object(K,'__file__',str(directory/'residual_runtime_compatibility.py')):
            admitted=K.RuntimeAdmission(f.plugin,copyroot)
            self.assertIs(admitted.verify_runtime(old,running),True)
            name='operation_probe.py';path=directory/name;raw=path.read_bytes();path.write_bytes(raw+b'\n')
            with self.assertRaises(ValueError):admitted.verify_runtime(old,running)
            path.unlink()
            with self.assertRaises((ValueError,OSError)):admitted.verify_runtime(old,running)
            path.write_bytes(raw)
            mixed=copy.deepcopy(running);mixed[name]['path']=current[name]['path']
            with self.assertRaises(ValueError):admitted.verify_runtime(old,mixed)

    def test_parser_relocation_requires_both_exact_files_and_paths(self):
        f=self.fixture();context=self.load(f);context.validate_marker()
        path=f.plugin/'scripts/codex_learner/transcript.py';raw=path.read_bytes();path.write_bytes(raw+b'\n')
        with self.assertRaises(ValueError):context.validate_marker()
        path.write_bytes(raw)
        admission=context.runtime_admission
        sealed=J._json(J._unseal(context.manifest['inputs']['parser_state']))['runtime']
        current=C._parser_runtime();self.assertIs(admission.verify_parser(sealed,current),True)
        with self.assertRaises(ValueError):admission.verify_parser({**sealed,'path':current['path']},current)
        with self.assertRaises(ValueError):admission.verify_parser(sealed,{**current,'sha256':'0'*64})
        with mock.patch.object(K,'_hash',side_effect=lambda p: '0'*64 if p==Path(current['path']) else J.sha256(p.read_bytes())):
            with self.assertRaises(ValueError):admission.verify_parser(sealed,current)

    def test_native_policy_route_source_and_retained_row_remain_current(self):
        import sqlite3
        for target in ('native','policy','config','source','row'):
            with self.subTest(target=target):
                f=self.fixture();context=self.load(f);context.validate_marker();before=f.current()
                if target=='native':f.runtime.write_bytes(f.runtime.read_bytes()+b'changed')
                elif target=='policy':write_json(f.root/'admission.json',{**f.policy,'enabled':False})
                elif target=='config':f.config.write_text(f.config.read_text().replace(str(f.store),str(f.store)+'.changed'))
                elif target=='source':f.path.write_bytes(f.path.read_bytes().replace(b'PRIVATE',b'CHANGED',1))
                else:
                    with contextlib.closing(sqlite3.connect(f.store)) as db:
                        db.execute('UPDATE Memory SET content=? WHERE globalId=?',('changed',f.row_values[0]['globalId']));db.commit()
                current=f.current()
                with self.no_processes(),self.assertRaises((ValueError,OSError)):context.validate_marker()
                self.assertEqual(f.current(),current)

    def test_profile_is_closed_and_not_available_for_prepare_or_execute(self):
        f=self.fixture()
        for bad in ('unknown',{},True):
            with self.assertRaises(ValueError):self.load(f,profile=bad)
        for command in ('prepare','execute'):
            code,result=self.invoke(self.arguments(f,command))
            self.assertEqual((code,result['reason']),(2,'residual_cli_runtime_compatibility_recovery_only'))
        self.assertFalse((f.run_dir/'residual-generation-000.json').exists())

    def test_recovery_and_absence_only_continuation_keep_original_intent_ids(self):
        f=self.fixture(begun=True);seals={n:(f.run_dir/n).read_bytes() for n in ('execution-manifest.json','residual-context.json')}
        exact={label:f.driver._intent(label)[1] for label in f.driver.operations}
        attempts=[]
        def interrupted(raw,writer,check):attempts.append(raw);raise ValueError('synthetic lost reply before mutation')
        f.driver.dispatch('R1',writer=f.writer,recoveries=[],execute=interrupted);f.writer.close()
        with f.synthetic_probe(),mock.patch.object(CLI.N,'executor',side_effect=AssertionError('read-only recover must not mutate')):
            code,result=self.invoke(self.arguments(f,'recover'));self.assertEqual(code,2)
        self.assertEqual(attempts,[exact['R1']]);self.assertFalse(f.receipt_path(J._json(exact['R1'])['operationID']).exists())
        resumed=[]
        def execute(raw,writer,check):resumed.append(raw);self.assertIn(raw,exact.values());return f.execute(raw,writer,check)
        with f.synthetic_probe(),mock.patch.object(CLI.N,'executor',return_value=execute):
            code,result=self.invoke(self.arguments(f,'continue-absent'))
        self.assertEqual((code,result['status']),(0,'reconciled_with_residuals'),result)
        self.assertEqual(resumed,list(exact.values()))
        self.assertEqual(seals,{n:(f.run_dir/n).read_bytes() for n in seals})
        self.assertEqual(J._json(resumed[0])['operationID'],J._json(attempts[0])['operationID'])

    def test_unknown_status_never_grants_continuation(self):
        f=self.fixture(begun=True);f.writer.close();before=f.current()
        def unknown(*args,**kwargs):raise ValueError('operation_probe_deadline')
        with mock.patch.object(CLI.N,'status_probe',return_value=unknown), \
             mock.patch.object(CLI.N,'executor',side_effect=AssertionError('unknown cannot write')):
            code,result=self.invoke(self.arguments(f,'continue-absent'))
        self.assertEqual(code,2);self.assertEqual(f.current(),before)
        self.assertFalse((f.run_dir/'residual-writers/001').exists())

    def test_closed_0152_predecessor_keeps_existing_seals_and_checks_all_bytes(self):
        f=self.fixture(profile=K.RELEASED_PROFILE)
        before={name:(f.run_dir/name).read_bytes() for name in ('execution-manifest.json','residual-context.json')}
        original=f.current()
        with self.no_processes():
            with self.assertRaises(ValueError):self.load(f,profile=None)
            context=self.load(f,profile=K.RELEASED_PROFILE)
            self.assertTrue(context.validate_marker())
            for name in K.RELEASED_HASHES:
                path=f.plugin/'scripts/codex_learner'/name;raw=path.read_bytes();path.write_bytes(raw+b'# changed\n')
                with self.assertRaises(ValueError):context.validate_marker()
                path.write_bytes(raw)
            self.assertTrue(context.validate_marker())
        self.assertEqual(original,f.current())
        self.assertEqual(before,{name:(f.run_dir/name).read_bytes() for name in before})
