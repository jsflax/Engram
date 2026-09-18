"""Exercise release command blocks with fake tools; never resolve or build Swift."""
import json
import os
from pathlib import Path
import re
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
            bin_dir = root / 'bin'
            bin_dir.mkdir()
            log = root / 'calls.jsonl'
            fake = '#!' + sys.executable + '\n' + '''import json,os,sys
from pathlib import Path
kind=Path(sys.argv[0]).name
args=sys.argv[1:]
if kind=='swift':
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
            for name in ('swift', 'xcodebuild'):
                command = bin_dir / name
                command.write_text(fake)
                command.chmod(0o755)
            (root / 'appcast.xml').write_text('<sparkle:version>14</sparkle:version>\n')
            env = dict(os.environ, PATH=f'{bin_dir}:/usr/bin:/bin', CALL_LOG=str(log),
                       RELEASE_TAG='v0.14.8', APPLE_TEAM_ID='ABCDEFGHIJ', RUNNER_TEMP=str(root))
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
            tests = [call for call in calls if call[:2] == ['swift', 'test']]
            self.assertEqual(len(tests), 3)
            self.assertTrue(any('recall_statementBudget' in call for call in tests))
            self.assertTrue(any('clusters_statementBudget' in call for call in tests))

    def test_native_mcp_gate_includes_persistence_and_existing_cases(self):
        body = run_block('release.yml', 'Verify real MCP lifecycle and database lock regressions')
        match = re.search(r'for regression in ([^;]+); do', body)
        self.assertIsNotNone(match)
        cases = match[1].split()
        self.assertEqual(set(cases), {'smoke', 'startup', 'recall', 'idle', 'persistence'})
        self.assertEqual(len(cases), 5)


if __name__ == '__main__':
    unittest.main()
