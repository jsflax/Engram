#!/usr/bin/env python3
"""Pure launch-description checks; never invokes Xcode, a host, or a store."""
import copy
import importlib.util
import os
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('visualizer_preparation', Path(__file__).with_name('prepare_visualizer_tests.py'))
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)

class HostPreparationTests(unittest.TestCase):
    def setUp(self):
        self.host = {'BlueprintName': 'EngramUnitTests',
            'TestBundlePath': '__TESTHOST__/Contents/PlugIns/EngramUnitTests.xctest',
            'TestHostPath': '__TESTROOT__/Debug/Engram.app',
            'TestingEnvironmentVariables': {'DYLD_FRAMEWORK_PATH': '__TESTROOT__/Debug'},
            'EnvironmentVariables': {}, 'OnlyTestIdentifiers': ['oldSelection']}
        self.original = {'__xctestrun_metadata__': {'FormatVersion': 2},
            'TestConfigurations': [{'Name': 'Default', 'TestTargets': [self.host,
                {'BlueprintName': 'EngramUITests', 'TestHostPath': '/not-selected'}]}]}
        self.environment = {'ENGRAM_PERF_ISOLATED': '1', 'CLAUDE_MEMORY_DB': '/owned/app.sqlite',
                            'CFFIXED_USER_HOME': '/owned/home', 'TMPDIR': '/owned/tmp'}

    def test_isolation_replaces_selection_without_mutating_original_or_loader_environment(self):
        before = copy.deepcopy(self.original)
        value = M.isolate(self.original, self.environment)
        targets = value['TestConfigurations'][0]['TestTargets']
        self.assertEqual(len(targets), 1)
        self.assertEqual(targets[0]['EnvironmentVariables'], self.environment)
        self.assertEqual(targets[0]['OnlyTestIdentifiers'], list(M.CLASSES))
        self.assertFalse(targets[0]['ParallelizationEnabled'])
        self.assertEqual(targets[0]['TestingEnvironmentVariables'], self.host['TestingEnvironmentVariables'])
        self.assertEqual(self.original, before)

    def test_ambiguous_or_missing_unit_target_refuses_before_launch(self):
        for targets in ([], [self.host, copy.deepcopy(self.host)]):
            value = copy.deepcopy(self.original);value['TestConfigurations'][0]['TestTargets'] = targets
            with self.subTest(targets=len(targets)), self.assertRaisesRegex(ValueError, 'missing or ambiguous'):
                M.isolate(value, self.environment)

    def test_host_overrides_and_skips_refuse_instead_of_silently_running_elsewhere(self):
        for change in ({'EnvironmentVariables': {'HOME': '/other'}},
                       {'EnvironmentVariables': {'CLAUDE_MEMORY_DB': '/other'}},
                       {'EnvironmentVariables': {'ENGRAM_TEST_INSERT_DELAY': '1'}},
                       {'TestingEnvironmentVariables': {'CFFIXED_USER_HOME': '/other'}},
                       {'SkipTestIdentifiers': ['GalaxyDrainTests']},
                       {'CommandLineArguments': ['--other-store']},
                       {'TestHostPath': '/SomeOther.app'}, {'IsUITestBundle': True}):
            value = copy.deepcopy(self.original);value['TestConfigurations'][0]['TestTargets'][0].update(change)
            # The selected DB is deliberately replaced by our owned path.
            if change == {'EnvironmentVariables': {'CLAUDE_MEMORY_DB': '/other'}}:
                actual = M.isolate(value, self.environment)
                self.assertEqual(actual['TestConfigurations'][0]['TestTargets'][0]['EnvironmentVariables']['CLAUDE_MEMORY_DB'], '/owned/app.sqlite')
            else:
                with self.subTest(change=change), self.assertRaises(ValueError): M.isolate(value, self.environment)

    def test_unknown_format_and_multiple_configurations_refuse(self):
        for value in ({}, {**self.original, 'TestConfigurations': self.original['TestConfigurations'] * 2}):
            with self.assertRaises(ValueError): M.isolate(value, self.environment)

    def test_preparation_binds_actual_owned_files_and_rejects_escaping_host(self):
        fixture_root = Path(os.environ.get('ENGRAM_CI_TEST_ROOT', str(Path.home() / 'localdev/engram-ci-python-fixtures')))
        fixture_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='visualizer-host-', dir=fixture_root) as directory:
            root = Path(directory).resolve()
            for name in ('repo/EngramUnitTests', 'fixtures', 'test-home', 'tmp', 'evidence', 'derived/Build/Products'):
                (root / name).mkdir(parents=True, exist_ok=True)
            for name in M.CLASSES:
                (root / 'repo/EngramUnitTests' / (name + '.swift')).write_text('    func testFixture() {}\n')
            products = root / 'derived/Build/Products'
            app = products / 'Debug/Engram.app'
            native = app / 'Contents/MacOS/Engram'
            tests = app / 'Contents/PlugIns/EngramUnitTests.xctest/Contents/MacOS/EngramUnitTests'
            for path in (native, tests):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'not executable; source preparation fixture')
            original = products / 'Engram.xctestrun'
            original.write_bytes(plistlib.dumps(self.original))
            result = M.prepare(root)
            self.assertEqual(result['expected_tests'], 3)
            output = plistlib.loads(Path(result['prepared']).read_bytes())
            environment = output['TestConfigurations'][0]['TestTargets'][0]['EnvironmentVariables']
            self.assertEqual(environment['CLAUDE_MEMORY_DB'], str(root / 'fixtures/app-memory.sqlite'))
            self.assertEqual(environment['CFFIXED_USER_HOME'], str(root / 'test-home'))
            self.assertNotIn('HOME', environment)
            self.assertNotIn('CODEX_HOME', environment)
            self.assertFalse((root / 'fixtures/app-memory.sqlite').exists(), 'preparation must never launch a host')
            with self.assertRaisesRegex(ValueError, 'path outside'):
                M.owned(root, root.parent)

if __name__ == '__main__': unittest.main()
