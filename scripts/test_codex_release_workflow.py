"""Exercise release command blocks with fake tools; never resolve or build Swift."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def step_section(workflow, name):
    text = (ROOT / '.github/workflows' / workflow).read_text()
    marker = '      - name: ' + name + '\n'
    return text.split(marker, 1)[1].split('\n      - ', 1)[0]


def run_block(workflow, name):
    section = step_section(workflow, name)
    match = re.search(r'^        run: (.*)$', section, re.M)
    if not match:
        raise AssertionError('step has no run command: ' + name)
    value = match[1]
    if value not in ('|', '>'):
        # Decode the YAML single-quoted scalar used by native build commands;
        # its outer quotes are not part of the script GitHub executes.
        if value.startswith("'") and value.endswith("'"):
            value = value[1:-1].replace("''", "'")
        return value + '\n'
    body = []
    for line in section[match.end():].splitlines()[1:]:
        if line and not line.startswith('          '):
            break
        body.append(line[10:] if line else '')
    return ('\n' if value == '|' else ' ').join(body) + '\n'


class ReleaseWorkflowTests(unittest.TestCase):
    def test_xcode_and_package_sdk_mirrors_match_owned_fork(self):
        expected = {
            'https://github.com/modelcontextprotocol/swift-sdk':
                'https://github.com/jsflax/swift-sdk.git',
            'https://github.com/modelcontextprotocol/swift-sdk.git':
                'https://github.com/jsflax/swift-sdk.git',
        }
        for relative in (
            '.swiftpm/configuration/mirrors.json',
            'Engram.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration/mirrors.json',
        ):
            with self.subTest(config=relative):
                config = json.loads((ROOT / relative).read_text())
                sdk = [entry for entry in config['object']
                       if entry['original'] in expected]
                self.assertEqual(len(sdk), len(expected))
                self.assertEqual({entry['original']: entry['mirror'] for entry in sdk}, expected)

        # The release must use the same DNS-free server qualified by the native
        # and app workflows, while retaining its artifact/readiness contract.
        name = 'Mirror Sparkle artifact from localhost'
        section = step_section('release.yml', name)
        block = run_block('release.yml', name)
        self.assertEqual(re.findall(r'^        timeout-minutes: (.*)$', section, re.M), ['5'])
        self.assertIn('(cd /tmp/sparkle-mirror-root && nohup python3 '
                      '"$GITHUB_WORKSPACE/scripts/artifact_mirror_server.py" '
                      '--directory /tmp/sparkle-mirror-root > /tmp/mirror.log 2>&1 &)', block)
        self.assertEqual(block.count('nohup python3'), 1)
        self.assertNotIn('-m http.server', block)
        self.assertIn('curl -sSfL -o /tmp/sparkle-mirror-root/Sparkle-for-Swift-Package-Manager.zip --create-dirs', block)
        self.assertIn('sleep 2\n', block)
        self.assertIn('curl -sSf -o /dev/null http://127.0.0.1:8765/Sparkle-for-Swift-Package-Manager.zip && echo "mirror serving OK"', block)
        self.assertIn('--mirror http://127.0.0.1:8765/Sparkle-for-Swift-Package-Manager.zip', block)

    def test_release_and_linux_commands_enforce_locks_and_xcode_version(self):
        with tempfile.TemporaryDirectory(prefix='engram-workflow-') as temporary:
            root = Path(temporary)
            (root / 'scripts').mkdir()
            # This test checks workflow command contracts. Supervision has its
            # own tests; a real process inventory can stall on a busy host.
            (root / 'scripts/run_native_tests.py').write_text('''import argparse, os, subprocess
from pathlib import Path
parser = argparse.ArgumentParser()
parser.add_argument('--diagnostics-dir', required=True)
parser.add_argument('--timeout-seconds', type=int, required=True)
parser.add_argument('--silence-seconds', type=int, required=True)
parser.add_argument('command', nargs=argparse.REMAINDER)
args = parser.parse_args()
assert args.diagnostics_dir == 'build/native-test-diagnostics', args
assert args.timeout_seconds == 1800, args
assert args.silence_seconds == 300, args
assert args.command and args.command[0] == '--', args
assert os.environ['ENGRAM_ADOPTION_TEST_ROOT'] == str(
    Path(os.environ['HOME']) / 'localdev/engram-native-tests-987654321-2')
assert os.environ['ENGRAM_TEST_ROOT'] == os.environ['ENGRAM_ADOPTION_TEST_ROOT']
assert os.environ['TMPDIR'] == str(Path(os.environ['ENGRAM_ADOPTION_TEST_ROOT']) / 'tmp')
raise SystemExit(subprocess.run(args.command[1:], check=False).returncode)
''')
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            log = root / 'calls.jsonl'
            fake = '#!' + sys.executable + '\n' + '''import json,os,sys
from pathlib import Path
kind=Path(sys.argv[0]).name
args=sys.argv[1:]
if kind=='mkdir':
    # Intercept the workflow's fixture allocation: never write to the real home.
    fixture = Path(os.environ['HOME'])/'localdev/engram-native-tests-987654321-2'
    assert args == ['-m','700','-p',str(fixture),str(fixture/'tmp')],args
elif kind=='swift':
    assert '--force-resolved-versions' in args,args
else:
    assert '-disableAutomaticPackageResolution' in args,args
    assert '-onlyUsePackageVersionsFromResolvedFile' in args,args
    assert '-clonedSourcePackagesDirPath' in args,args
    assert 'MARKETING_VERSION=0.14.8' in args,args
    assert 'CURRENT_PROJECT_VERSION=15' in args,args
with open(os.environ['CALL_LOG'],'a') as output:
    output.write(json.dumps([kind,*args])+'\\n')
'''
            for name in ('swift', 'xcodebuild', 'mkdir'):
                command = bin_dir / name
                command.write_text(fake)
                command.chmod(0o755)
            (root / 'appcast.xml').write_text('<sparkle:version>14</sparkle:version>\n')
            env = dict(os.environ, PATH=f'{bin_dir}:/usr/bin:/bin', CALL_LOG=str(log),
                       RELEASE_TAG='v0.14.8', APPLE_TEAM_ID='ABCDEFGHIJ', RUNNER_TEMP=str(root),
                       GITHUB_RUN_ID='987654321', GITHUB_RUN_ATTEMPT='2')
            steps = {
                'release.yml': ['Resolve dependencies', 'Build tests', 'Run tests',
                                'Run statement-budget regressions (serial)',
                                'Build CLI release binaries', 'Archive app with xcodebuild'],
                'linux-core.yml': ['Build EngramMemoryCore (Linux)', 'Compile its tests (Linux)'],
            }
            for workflow, names in steps.items():
                for name in names:
                    with self.subTest(workflow=workflow, step=name):
                        result = subprocess.run(['/bin/bash', '-e', '-c', run_block(workflow, name)],
                                                cwd=root, env=env, capture_output=True, text=True, timeout=20)
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual(sum(call[0] == 'swift' for call in calls), 8)
            self.assertEqual(sum(call[0] == 'xcodebuild' for call in calls), 1)
            self.assertEqual(sum(call[0] == 'mkdir' for call in calls), 1)
            tests = [call for call in calls if call[:2] == ['swift', 'test']]
            self.assertEqual(len(tests), 3)
            self.assertTrue(any('recall_statementBudget' in call for call in tests))
            self.assertTrue(any('clusters_statementBudget' in call for call in tests))
            self.assertEqual(tests[0], [
                'swift', 'test', '--force-resolved-versions', '--skip-build', '--filter',
                'EngramTests|EngramMemoryCoreTests|EngramRealityKitTests|PositionVersionTests|LockedSnapshotTests',
                '--skip', 'PerfTests', '--skip', 'keyBERTKeywordExtraction',
                '--skip', 'recall_semanticRelevanceOrdering',
                '--skip', 'recall_connectedMemory_showsEdgeRelation',
                '--skip', 'recall_graphTraversal_relatesToDoesNotLeakViaUnrelatedStructuralEdge',
                '--skip', 'recall_statementBudget', '--skip', 'clusters_statementBudget',
                '--skip', 'busyBeginDoesNotInvokeBodyOrPublishReceipt',
            ])

    def test_begin_timing_skip_has_mandatory_isolated_gate_and_propagates_failure(self):
        selected = 'busyBeginDoesNotInvokeBodyOrPublishReceipt'
        name = 'Run ledger BEGIN timing regression (serial)'
        source = (ROOT / 'Tests/EngramTests/MemoryOperationLedgerTests.swift').read_text()
        self.assertIn('@Test func ' + selected + '()', source)
        self.assertIn('#expect(elapsed < 2.0)', source)
        for workflow, parallel_name in (('release.yml', 'Run tests'),
                                         ('native-validation.yml', 'Run full native release filter')):
            with self.subTest(workflow=workflow):
                text = (ROOT / '.github/workflows' / workflow).read_text()
                self.assertEqual(text.count('      - name: ' + name + '\n'), 1)
                section = text.split('      - name: ' + name + '\n', 1)[1].split('\n      - ', 1)[0]
                self.assertNotIn('continue-on-error', section)
                conditions = re.findall(r'^        if: (.*)$', section, re.M)
                self.assertEqual(conditions, [] if workflow == 'release.yml' else [
                    "${{ !cancelled() && steps.native_build.outcome == 'success' }}"])
                self.assertNotIn('|| true', section)
                self.assertLess(text.index('      - name: ' + parallel_name + '\n'),
                                text.index('      - name: ' + name + '\n'))
                parallel = run_block(workflow, parallel_name)
                self.assertRegex(parallel, r'--skip ["\']?' + selected + r'["\']?(?:\s|$)')
                block = run_block(workflow, name)
                with tempfile.TemporaryDirectory(prefix='engram ledger workflow ') as temporary:
                    root = Path(temporary).resolve()
                    validation = root / 'validation'
                    (validation / 'repo').mkdir(parents=True)
                    bin_dir = root / 'bin'; bin_dir.mkdir()
                    log, continued = root / 'calls.jsonl', root / 'continued'
                    fake = '#!' + sys.executable + '\n' + """import json,os,sys
from pathlib import Path
kind=Path(sys.argv[0]).name
with open(os.environ['CALL_LOG'],'a') as stream:
    stream.write(json.dumps({'tool':kind,'args':sys.argv[1:],'cwd':str(Path.cwd()),
        'fixture':os.environ['ENGRAM_ADOPTION_TEST_ROOT'],'tmp':os.environ['TMPDIR']})+'\\n')
raise SystemExit(int(os.environ['FAKE_GATE_EXIT']) if kind=='python3' else 0)
"""
                    for tool in ('python3', 'mkdir'):
                        command = bin_dir / tool
                        command.write_text(fake); command.chmod(0o755)
                    fixture = validation / 'fixtures'
                    env = dict(os.environ, PATH=f'{bin_dir}:/usr/bin:/bin', CALL_LOG=str(log),
                        VALIDATION_ROOT=str(validation), GITHUB_RUN_ID='987654321', GITHUB_RUN_ATTEMPT='2',
                        ENGRAM_ADOPTION_TEST_ROOT=str(fixture), ENGRAM_TEST_ROOT=str(fixture),
                        TMPDIR=str(validation / 'tmp'))
                    release = workflow == 'release.yml'
                    expected_fixture = (Path(env['HOME']) / 'localdev/engram-native-ledger-begin-987654321-2'
                                        if release else fixture)
                    expected_cwd = root if release else validation / 'repo'
                    command = ['swift' if release else str(validation / 'bin/swift-validation'),
                               'test', '--force-resolved-versions']
                    if not release:
                        command += ['--disable-index-store']
                    command += ['--skip-build', '--filter', selected]
                    expected_args = ['-B', 'scripts/run_native_tests.py', '--diagnostics-dir',
                        str(expected_fixture / 'diagnostics') if release else str(validation / 'evidence/ledger-begin-timing'),
                        '--timeout-seconds', '120', '--silence-seconds', '60', '--', *command]
                    for code in (0, 29):
                        log.unlink(missing_ok=True); continued.unlink(missing_ok=True)
                        # The path may contain spaces; pass it as a separate shell argument.
                        result = subprocess.run(['/bin/bash', '-e', '-c', block + "printf continued > \"$1\"\n", 'gate', str(continued)],
                            cwd=root, env=dict(env, FAKE_GATE_EXIT=str(code)),
                            capture_output=True, text=True, timeout=10)
                        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
                        self.assertEqual(continued.exists(), code == 0)
                        calls = [json.loads(line) for line in log.read_text().splitlines()]
                        self.assertEqual([call['tool'] for call in calls], ['mkdir', 'python3'] if release else ['python3'])
                        call = calls[-1]
                        self.assertEqual(call['args'], expected_args)
                        self.assertEqual(call['cwd'], str(expected_cwd))
                        self.assertEqual(call['fixture'], str(expected_fixture))
                        self.assertEqual(call['tmp'], str(expected_fixture / 'tmp') if release else str(validation / 'tmp'))

    def test_force_preparation_requires_exact_runtime_passes_and_propagates_failure(self):
        names = ['testPreparationCentroidsUseFirstEncodePositionsAndCadence',
                 'testPreparationRegroupAndCapacityGrowth', 'testPreparationAsyncDirtyDispatch']
        selected = '|'.join(names)
        name = 'Run force preparation regressions (serial)'
        source = (ROOT / 'Tests/EngramVisualizerTests/ForceEngineTests.swift').read_text()
        for method in names:
            self.assertRegex(source, r'@Test\s+@MainActor\s+func ' + method + r'\(\)')
            self.assertIsNotNone(re.search(selected, 'EngramVisualizerTests.ForceEngineTests/' + method + '()'))
        self.assertIsNone(re.search(selected, 'EngramVisualizerTests.ForceEngineTests/testHistoricalGPUCase()'))
        for workflow in ('native-validation.yml', 'release.yml'):
            with self.subTest(workflow=workflow), tempfile.TemporaryDirectory(prefix='engram force gate ') as temporary:
                root = Path(temporary).resolve()
                validation = root / 'validation'
                (validation / 'repo').mkdir(parents=True)
                bin_dir = root / 'bin'; bin_dir.mkdir()
                log = root / 'call.json'
                fake = bin_dir / 'python3'
                fake.write_text('#!' + sys.executable + '\nimport json,os,sys\nfrom pathlib import Path\n'
                    'Path(os.environ["CALL_LOG"]).write_text(json.dumps(sys.argv[1:]))\n'
                    'raise SystemExit(int(os.environ["FAKE_GATE_EXIT"]))\n')
                fake.chmod(0o700)
                env = dict(os.environ, PATH=f'{bin_dir}:/usr/bin:/bin', CALL_LOG=str(log),
                           VALIDATION_ROOT=str(validation), GITHUB_RUN_ID='987654321', GITHUB_RUN_ATTEMPT='2')
                release = workflow == 'release.yml'
                diagnostics = (Path(env['HOME']) / 'localdev/engram-force-preparation-987654321-2/diagnostics'
                               if release else validation / 'evidence/force-preparation')
                command = ['swift' if release else str(validation / 'bin/swift-validation'),
                           'test', '--force-resolved-versions']
                if not release:
                    command += ['--disable-index-store']
                command += ['--skip-build', '--no-parallel', '--filter', selected]
                expected = ['-B', 'scripts/run_native_tests.py', '--diagnostics-dir', str(diagnostics),
                            '--timeout-seconds', '120', '--silence-seconds', '60']
                for method in names:
                    expected += ['--require-swift-test', method]
                expected += ['--', *command]
                section = step_section(workflow, name)
                self.assertIn('timeout-minutes: 4', section)
                self.assertNotIn('continue-on-error', section)
                self.assertNotIn('|| true', section)
                for code in (0, 29):
                    # Intercept mkdir so release-path checks never write under the real HOME.
                    result = subprocess.run(['/bin/bash', '-e', '-c', 'mkdir() { :; };\n' + run_block(workflow, name)],
                        cwd=root, env=dict(env, FAKE_GATE_EXIT=str(code)), capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, code, result.stdout + result.stderr)
                    self.assertEqual(json.loads(log.read_text()), expected)
        upload = step_section('release.yml', 'Upload force preparation diagnostics')
        self.assertIn('if: ${{ always() }}', upload)
        self.assertIn('~/localdev/engram-force-preparation-${{ github.run_id }}-${{ github.run_attempt }}/diagnostics/', upload)
        self.assertIn('${{ env.VALIDATION_ROOT }}/evidence/', step_section('native-validation.yml', 'Upload explicit validation evidence'))

    def test_native_validation_uses_only_explicit_independent_prerequisites(self):
        workflow = 'native-validation.yml'
        text = (ROOT / '.github/workflows' / workflow).read_text()
        ids = {
            'Check out exact source under localdev': 'checkout_source',
            'Resolve pinned dependencies (private read-only clone credential)': 'dependencies',
            'Build native tests': 'native_build',
            'Build release Engram native product': 'release_build',
        }
        self.assertEqual(re.findall(r'^        id: (.*)$', text, re.M), list(ids.values()))
        for name, step_id in ids.items():
            self.assertEqual(re.findall(r'^        id: (.*)$', step_section(workflow, name), re.M), [step_id])
        prerequisites = {
            'Run full native release filter': 'native_build',
            'Run force preparation regressions (serial)': 'native_build',
            'Run ledger BEGIN timing regression (serial)': 'native_build',
            'Collect ledger BEGIN contention diagnostics (serial)': 'native_build',
            'Run both statement budgets in separate serial processes': 'native_build',
            'Validate Python MCP harness fixtures': 'checkout_source',
            'Build release Engram native product': 'dependencies',
            'Verify actual native MCP lifecycle and contention cases': 'release_build',
        }
        evidence_steps = {'Record source and dependency integrity', 'Stop owned artifact mirror',
                          'Upload explicit validation evidence'}
        for name in re.findall(r'^      - name: (.*)$', text, re.M):
            conditions = re.findall(r'^        if: (.*)$', step_section(workflow, name), re.M)
            expected = []
            if name in prerequisites:
                expected = ["${{ !cancelled() && steps." + prerequisites[name] + ".outcome == 'success' }}"]
            elif name in evidence_steps:
                expected = ["${{ always() && env.VALIDATION_ROOT != '' }}"]
            self.assertEqual(conditions, expected, name)
        self.assertNotIn('continue-on-error', text)
        # Mirror diagnostics must not replace the original failing curl status.
        # No validation command may otherwise suppress its failure.
        optional_diagnostic = ('python3 -B scripts/artifact_mirror_diagnostics.py failure '
                              '--root "$VALIDATION_ROOT" --curl-status "$mirror_status" || true')
        self.assertEqual(text.count(optional_diagnostic), 1)
        self.assertNotIn('|| true', text.replace(optional_diagnostic, ''))
        diagnostic = 'Collect ledger BEGIN contention diagnostics (serial)'
        self.assertLess(text.index('      - name: Run ledger BEGIN timing regression (serial)\n'),
                        text.index('      - name: ' + diagnostic + '\n'))
        self.assertLess(text.index('      - name: ' + diagnostic + '\n'),
                        text.index('      - name: Run both statement budgets in separate serial processes\n'))
        self.assertIn('--skip beginContentionTimingDiagnostics',
                      run_block(workflow, 'Run full native release filter'))
        self.assertIn('timeout-minutes: 3', step_section(workflow, diagnostic))

    def test_native_validation_shell_commands_collect_independent_failures(self):
        workflow = 'native-validation.yml'
        full_filter = 'EngramTests|EngramMemoryCoreTests|EngramRealityKitTests|PositionVersionTests|LockedSnapshotTests'
        with tempfile.TemporaryDirectory(prefix='engram independent workflow ') as temporary:
            root = Path(temporary).resolve()
            validation = root / 'validation'
            (validation / 'repo').mkdir(parents=True)
            bin_dir = root / 'bin'; bin_dir.mkdir()
            (validation / 'bin').mkdir()
            (validation / 'scratch/release').mkdir(parents=True)
            native = validation / 'scratch/release/Engram'
            native.write_text('#!/bin/sh\nexit 99\n'); native.chmod(0o700)
            migration = validation / 'scratch/release/EngramDaemon'
            migration.write_text('#!/bin/sh\nexit 99\n'); migration.chmod(0o700)
            log = root / 'calls.jsonl'
            fake = '#!' + sys.executable + '\n' + """import json,os,sys
from pathlib import Path
args=sys.argv[1:]
with open(os.environ['CALL_LOG'],'a') as stream:
    stream.write(json.dumps({'tool':Path(sys.argv[0]).name,'args':args,'cwd':str(Path.cwd())})+'\\n')
key = (args[args.index('--filter')+1] if '--filter' in args else
       args[args.index('--case')+1] if '--case' in args else
       args[args.index('--product')+1] if Path(sys.argv[0]).name=='swift-validation' else 'fixtures')
raise SystemExit(29 if key in json.loads(os.environ['FAIL_KEYS']) else 0)
"""
            for command in (bin_dir / 'python3', validation / 'bin/swift-validation'):
                command.write_text(fake); command.chmod(0o700)
            env = dict(os.environ, PATH=f'{bin_dir}:/usr/bin:/bin', CALL_LOG=str(log),
                       VALIDATION_ROOT=str(validation))
            swift_test = [str(validation / 'bin/swift-validation'), 'test',
                          '--force-resolved-versions', '--disable-index-store', '--skip-build']
            def supervised(directory, timeout, silence, command):
                return ['-B', 'scripts/run_native_tests.py', '--diagnostics-dir',
                        str(validation / 'evidence' / directory), '--timeout-seconds', str(timeout),
                        '--silence-seconds', str(silence), '--', *command]
            cases = ['smoke', 'startup', 'warm-startup', 'warm-multistore-startup',
                     'recall', 'idle', 'persistence']
            budgets = ['recall_statementBudget', 'clusters_statementBudget']
            checks = [
                ('Run full native release filter', [full_filter], [supervised('native-tests', 1800, 300,
                    swift_test + ['--filter', full_filter] + [argument for name in (
                        'PerfTests', 'keyBERTKeywordExtraction', 'recall_semanticRelevanceOrdering',
                        'recall_connectedMemory_showsEdgeRelation',
                        'recall_graphTraversal_relatesToDoesNotLeakViaUnrelatedStructuralEdge',
                        *budgets, 'busyBeginDoesNotInvokeBodyOrPublishReceipt',
                        'beginContentionTimingDiagnostics') for argument in ('--skip', name)])], False),
                ('Collect ledger BEGIN contention diagnostics (serial)', ['beginContentionTimingDiagnostics'],
                    [supervised('ledger-begin-diagnostics', 120, 60,
                                swift_test + ['--filter', 'beginContentionTimingDiagnostics'])], False),
                ('Run both statement budgets in separate serial processes', budgets,
                    [supervised(budget, 300, 180, swift_test + ['--filter', budget]) for budget in budgets], True),
                ('Validate Python MCP harness fixtures', ['fixtures'],
                    [supervised('mcp-harness-fixtures', 180, 60,
                                ['python3', '-B', '-m', 'unittest', 'discover', '-s', 'scripts', '-p', 'test_mcp_locks.py'])], False),
                ('Build release Engram native product', ['Engram', 'EngramDaemon'],
                    [['build', '--force-resolved-versions', '--disable-index-store', '-c', 'release', '--product', product]
                     for product in ('Engram', 'EngramDaemon')], False),
                ('Verify actual native MCP lifecycle and contention cases', cases,
                    [supervised('mcp-' + case, 180, 90,
                                ['python3', '-B', 'scripts/verify-mcp-locks.py', '--binary', str(native),
                                 '--migration-binary', str(migration), '--case', case])
                     for case in cases], True),
            ]
            for name, keys, expected_args, aggregated in checks:
                # First and second budget failures each preserve the other run;
                # every MCP position is also exercised without running Swift.
                scenarios = [[], *[[key] for key in keys]] + ([keys] if aggregated else [])
                for failures in scenarios:
                    with self.subTest(step=name, failures=failures):
                        log.unlink(missing_ok=True)
                        continued = root / 'continued'; continued.unlink(missing_ok=True)
                        result = subprocess.run(['/bin/bash', '-e', '-c', run_block(workflow, name)
                            + 'printf continued > "$1"\n', 'gate', str(continued)], cwd=validation / 'repo',
                            env=dict(env, FAIL_KEYS=json.dumps(failures)), capture_output=True, text=True, timeout=20)
                        self.assertEqual(result.returncode, (1 if aggregated else 29) if failures else 0,
                                         result.stdout + result.stderr)
                        self.assertEqual(continued.exists(), not failures and not aggregated)
                        calls = [json.loads(line) for line in log.read_text().splitlines()]
                        building = name == 'Build release Engram native product'
                        reached = (expected_args[:keys.index(failures[0]) + 1]
                                   if building and failures else expected_args)
                        self.assertEqual(calls, [{'tool': 'swift-validation' if building else 'python3',
                            'args': arguments, 'cwd': str(validation / 'repo')} for arguments in reached])
            # The migration prerequisite must fail before any supervised MCP
            # case, rather than being mistaken for the injected tool failure.
            migration.unlink()
            log.unlink(missing_ok=True)
            result = subprocess.run(['/bin/bash', '-e', '-c', run_block(workflow,
                'Verify actual native MCP lifecycle and contention cases')], cwd=validation / 'repo',
                env=dict(env, FAIL_KEYS='[]'), capture_output=True, text=True, timeout=20)
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(log.exists())

    def test_begin_diagnostics_requires_explicit_native_opt_in(self):
        flag = 'ENGRAM_BEGIN_DIAGNOSTICS'
        workflow = 'native-validation.yml'
        name = 'Collect ledger BEGIN contention diagnostics (serial)'
        block = run_block(workflow, name)
        source = (ROOT / 'Tests/EngramTests/BeginContentionDiagnosticsTests.swift').read_text()
        self.assertRegex(source, r'@Test\(\.enabled\(if:\s*ProcessInfo\.processInfo\.environment\["'
                         + flag + r'"\]\s*==\s*"1"\)\)\s*func beginContentionTimingDiagnostics\(')
        self.assertIn(flag + '=1 python3 -B scripts/run_native_tests.py', block)
        text = (ROOT / '.github/workflows' / workflow).read_text()
        self.assertEqual(text.count(flag), 1)
        self.assertNotIn(flag, (ROOT / '.github/workflows/release.yml').read_text())
        with tempfile.TemporaryDirectory(prefix='engram diagnostic opt in ') as temporary:
            root = Path(temporary).resolve()
            validation = root / 'validation'
            scripts = validation / 'repo/scripts'; scripts.mkdir(parents=True)
            bin_dir = root / 'bin'; bin_dir.mkdir()
            (validation / 'bin').mkdir()
            (bin_dir / 'python3').symlink_to(sys.executable)
            log = root / 'calls.jsonl'
            (scripts / 'run_native_tests.py').write_text("""import argparse,json,os,subprocess
parser=argparse.ArgumentParser()
parser.add_argument('--diagnostics-dir',required=True)
parser.add_argument('--timeout-seconds',type=int,required=True)
parser.add_argument('--silence-seconds',type=int,required=True)
parser.add_argument('command',nargs=argparse.REMAINDER)
args=parser.parse_args()
assert args.timeout_seconds==120 and args.silence_seconds==60,args
assert args.command[0]=='--',args
with open(os.environ['CALL_LOG'],'a') as stream:
    stream.write(json.dumps({'phase':'supervisor','opt_in':os.environ.get('ENGRAM_BEGIN_DIAGNOSTICS')})+'\\n')
raise SystemExit(subprocess.run(args.command[1:],check=False).returncode)
""")
            native = validation / 'bin/swift-validation'
            native.write_text('#!' + sys.executable + '\n' + """import json,os,sys
assert sys.argv[1:]==['test','--force-resolved-versions','--disable-index-store','--skip-build',
                      '--filter','beginContentionTimingDiagnostics'],sys.argv
with open(os.environ['CALL_LOG'],'a') as stream:
    stream.write(json.dumps({'phase':'child','opt_in':os.environ.get('ENGRAM_BEGIN_DIAGNOSTICS')})+'\\n')
raise SystemExit(int(os.environ['FAKE_GATE_EXIT']))
""")
            native.chmod(0o700)
            env = dict(os.environ, PATH=f'{bin_dir}:/usr/bin:/bin', VALIDATION_ROOT=str(validation),
                       CALL_LOG=str(log), ENGRAM_BEGIN_DIAGNOSTICS='0')
            for exit_code in (0, 29):
                with self.subTest(exit_code=exit_code):
                    log.unlink(missing_ok=True)
                    continued = root / 'continued'; continued.unlink(missing_ok=True)
                    result = subprocess.run(['/bin/bash', '-e', '-c', block + 'printf continued > "$1"\n',
                                             'gate', str(continued)], cwd=validation / 'repo',
                        env=dict(env, FAKE_GATE_EXIT=str(exit_code)), capture_output=True, text=True, timeout=20)
                    self.assertEqual(result.returncode, exit_code, result.stdout + result.stderr)
                    self.assertEqual(continued.exists(), exit_code == 0)
                    self.assertEqual([json.loads(line) for line in log.read_text().splitlines()], [
                        {'phase': 'supervisor', 'opt_in': '1'}, {'phase': 'child', 'opt_in': '1'}])

    def test_native_mcp_gate_includes_persistence_and_existing_cases(self):
        name = 'Verify real MCP lifecycle and database lock regressions'
        body = run_block('release.yml', name)
        match = re.search(r'for regression in ([^;]+); do', body)
        self.assertIsNotNone(match)
        cases = match[1].split()
        expected = ['smoke', 'startup', 'warm-startup', 'warm-multistore-startup',
                    'recall', 'idle', 'persistence']
        self.assertEqual(cases, expected)
        validation = run_block('native-validation.yml', 'Verify actual native MCP lifecycle and contention cases')
        self.assertEqual(re.search(r'for regression in ([^;]+); do', validation)[1].split(), expected)
        section = (ROOT / '.github/workflows/release.yml').read_text().split(
            '      - name: ' + name + '\n', 1)[1].split('\n      - ', 1)[0]
        self.assertIn('timeout-minutes: 10', section)
        self.assertNotIn('continue-on-error', section)
        self.assertNotRegex(section, re.compile(r'^        if:', re.M))
        with tempfile.TemporaryDirectory(prefix='engram mcp workflow ') as temporary:
            root = Path(temporary).resolve()
            bin_dir = root / 'bin'; bin_dir.mkdir()
            log, continued = root / 'calls.jsonl', root / 'continued'
            fake = '#!' + sys.executable + '\n' + """import json,os,sys
from pathlib import Path
with open(os.environ['CALL_LOG'],'a') as stream:
    stream.write(json.dumps({'args':sys.argv[1:],'cwd':str(Path.cwd()),
        'home':os.environ['HOME'],'foundation_home':os.environ['CFFIXED_USER_HOME'],
        'tmp':os.environ['TMPDIR']})+'\\n')
case=sys.argv[sys.argv.index('--case')+1]
raise SystemExit(37 if case==os.environ['FAILING_CASE'] else 0)
"""
            command = bin_dir / 'python3'
            command.write_text(fake); command.chmod(0o755)
            env = dict(os.environ, PATH=f'{bin_dir}:/usr/bin:/bin', CALL_LOG=str(log))
            for failing in ('', 'warm-multistore-startup'):
                with self.subTest(failing=failing):
                    log.unlink(missing_ok=True); continued.unlink(missing_ok=True)
                    result = subprocess.run(['/bin/bash', '-e', '-c', body + 'printf continued > continued\n'],
                        cwd=root, env=dict(env, FAILING_CASE=failing), capture_output=True, text=True, timeout=20)
                    self.assertEqual(result.returncode, 37 if failing else 0, result.stdout + result.stderr)
                    self.assertEqual(continued.exists(), not failing)
                    observed = [json.loads(line) for line in log.read_text().splitlines()]
                    selected = expected[:4] if failing else expected
                    self.assertEqual(observed, [{
                        'args': ['-B', 'scripts/verify-mcp-locks.py', '--binary', '.build/release/Engram',
                                 '--migration-binary', '.build/release/EngramDaemon', '--case', case],
                        'cwd': str(root), 'home': env['HOME'],
                        'foundation_home': str(root / 'build/mcp-test-home'),
                        'tmp': str(root / 'build/mcp-test-tmp'),
                    } for case in selected])

    def test_native_residual_gate_uses_release_binary_private_workdir_and_propagates_failure(self):
        name = 'Verify actual native residual recovery and readback'
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        self.assertLess(workflow.index('      - name: Build CLI release binaries\n'),
                        workflow.index('      - name: ' + name + '\n'))
        self.assertLess(workflow.index('      - name: ' + name + '\n'),
                        workflow.index('      - name: Import signing certificate\n'))
        step = workflow.split('      - name: ' + name + '\n', 1)[1].split('\n      - ', 1)[0]
        self.assertNotIn('continue-on-error', step)
        upload = workflow.split('      - name: Upload native residual recovery evidence\n', 1)[1].split('\n      - ', 1)[0]
        self.assertIn("always() && steps.native_residual.outcome != 'skipped'", upload)
        self.assertIn('path: ~/localdev/engram-residual-native-${{ github.run_id }}-${{ github.run_attempt }}/', upload)
        with tempfile.TemporaryDirectory(prefix='engram residual workflow ') as temporary:
            root = Path(temporary).resolve()
            bin_dir = root / 'bin'; bin_dir.mkdir()
            log, continued = root / 'calls.jsonl', root / 'continued'
            fake = '#!' + sys.executable + '\n' + '''import json,os,sys
from pathlib import Path
kind=Path(sys.argv[0]).name
with open(os.environ['CALL_LOG'],'a') as stream:
    stream.write(json.dumps({'tool':kind,'args':sys.argv[1:],'cwd':str(Path.cwd())})+'\\n')
# mkdir is intercepted too: this test never writes to the actual user home.
raise SystemExit(int(os.environ['FAKE_GATE_EXIT']) if kind=='python3' else 0)
'''
            for tool in ('python3', 'mkdir'):
                command = bin_dir / tool
                command.write_text(fake); command.chmod(0o755)
            env = dict(os.environ, PATH=f'{bin_dir}:/usr/bin:/bin', CALL_LOG=str(log),
                       GITHUB_RUN_ID='987654321', GITHUB_RUN_ATTEMPT='2')
            expected_work = str(Path(env['HOME']) / 'localdev/engram-residual-native-987654321-2')
            block = run_block('release.yml', name) + "printf 'continued' > continued\n"
            for exit_code in (0, 23):
                with self.subTest(exit_code=exit_code):
                    log.unlink(missing_ok=True); continued.unlink(missing_ok=True)
                    result = subprocess.run(['/bin/bash', '-e', '-c', block], cwd=root,
                        env=dict(env, FAKE_GATE_EXIT=str(exit_code)), capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, exit_code, result.stdout + result.stderr)
                    self.assertEqual(continued.exists(), exit_code == 0)
                    calls = [json.loads(line) for line in log.read_text().splitlines()]
                    self.assertEqual(calls, [
                        {'tool':'mkdir','args':['-p',str(Path(env['HOME'])/'localdev')],'cwd':str(root)},
                        {'tool':'python3','args':['-B','scripts/native_residual_smoke.py',
                            '--native',str(root/'.build/release/Engram'),'--repo',str(root),
                            '--work-dir',expected_work],'cwd':str(root)},
                    ])


    def test_slack_dispatch_announces_publication_and_checks_acknowledgment(self):
        workflow = (ROOT / '.github/workflows/release.yml').read_text()
        step = workflow.split('      - name: Notify Slack\n', 1)[1].split('\n      - ', 1)[0]
        self.assertIn("steps.publish.outcome == 'success'", step)
        self.assertNotIn("github.event_name", step)
        self.assertIn("SWIFTLM SLACK; do", workflow)
        with tempfile.TemporaryDirectory(prefix='engram-slack-') as temporary:
            root = Path(temporary)
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            fake = '#!' + sys.executable + '\n' + """import json,os,sys
from pathlib import Path
args=sys.argv[1:]
assert '--fail' in args and '--max-time' in args,args
assert '--retry' not in args,args
payload=json.loads(args[args.index('-d')+1])
Path(os.environ['CALL_LOG']).write_text(json.dumps(payload))
print(os.environ['FAKE_ACK'])
sys.exit(int(os.environ.get('FAKE_EXIT','0')))
"""
            command = bin_dir / 'curl'
            command.write_text(fake)
            command.chmod(0o755)
            log = root / 'payload.json'
            (root / 'CHANGELOG.md').write_text('## [0.14.9]\n### Fixed\n- A "quoted" fix\n## [0.14.8]\n- Old\n')
            block = run_block('release.yml', 'Notify Slack').replace('${{ github.repository }}', 'owner/Engram')
            env = dict(os.environ, PATH=f'{bin_dir}:/usr/bin:/bin', CALL_LOG=str(log),
                       RELEASE_TAG='v0.14.9', SLACK_WEBHOOK_URL='https://example.invalid/webhook')
            for ack, exit_code, expected in [('ok', '0', 0), ('invalid_payload', '0', 1), ('ok', '22', 22)]:
                with self.subTest(ack=ack, exit_code=exit_code):
                    result = subprocess.run(['/bin/bash', '-e', '-c', block], cwd=root,
                                            env=dict(env, FAKE_ACK=ack, FAKE_EXIT=exit_code),
                                            capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
            payload = json.loads(log.read_text())
            self.assertIn('v0.14.9', payload['blocks'][0]['text']['text'])
            self.assertEqual(payload['blocks'][1]['accessory']['url'],
                             'https://github.com/owner/Engram/releases/tag/v0.14.9')
            self.assertIn('A "quoted" fix', payload['blocks'][1]['text']['text'])
            self.assertNotIn('Old', payload['blocks'][1]['text']['text'])


if __name__ == '__main__':
    unittest.main()
