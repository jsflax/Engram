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


def run_block(workflow, name):
    text = (ROOT / '.github/workflows' / workflow).read_text()
    marker = '      - name: ' + name + '\n'
    section = text.split(marker, 1)[1].split('\n      - ', 1)[0]
    match = re.search(r'^        run: (.*)$', section, re.M)
    if not match:
        raise AssertionError('step has no run command: ' + name)
    value = match[1]
    if value not in ('|', '>'):
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
                self.assertNotRegex(section, re.compile(r'^        if:', re.M))
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

    def test_native_mcp_gate_includes_persistence_and_existing_cases(self):
        body = run_block('release.yml', 'Verify real MCP lifecycle and database lock regressions')
        match = re.search(r'for regression in ([^;]+); do', body)
        self.assertIsNotNone(match)
        cases = match[1].split()
        self.assertEqual(set(cases), {'smoke', 'startup', 'warm-startup', 'recall', 'idle', 'persistence'})
        self.assertEqual(len(cases), 6)

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
