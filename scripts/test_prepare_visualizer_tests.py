#!/usr/bin/env python3
"""Pure launch-description checks; never invokes Xcode, a host, or a store."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
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
            self.assertEqual(result['expected_tests'], 6)
            output = plistlib.loads(Path(result['prepared']).read_bytes())
            environment = output['TestConfigurations'][0]['TestTargets'][0]['EnvironmentVariables']
            self.assertEqual(environment['CLAUDE_MEMORY_DB'], str(root / 'fixtures/app-memory.sqlite'))
            self.assertEqual(environment['CFFIXED_USER_HOME'], str(root / 'test-home'))
            self.assertNotIn('HOME', environment)
            self.assertNotIn('CODEX_HOME', environment)
            self.assertFalse((root / 'fixtures/app-memory.sqlite').exists(), 'preparation must never launch a host')
            with self.assertRaisesRegex(ValueError, 'path outside'):
                M.owned(root, root.parent)

    def test_frame_lookup_controls_are_mirrored_and_selected_in_exact_app_census(self):
        repo = Path(__file__).parents[1]
        package = (repo / 'Tests/EngramRealityKitTests/FrameLookupInvalidationTests.swift').read_text()
        mirrored = package.replace('import Testing', 'import XCTest')
        mirrored = re.sub(r'^@Suite\([^\n]*\)\n', '', mirrored, flags=re.M)
        mirrored = re.sub(r'^    @Test\([^\n]*\)\n', '', mirrored, flags=re.M)
        mirrored = mirrored.replace('struct FrameLookupInvalidationTests {',
                                    'final class FrameLookupInvalidationTests: XCTestCase {')
        mirrored = re.sub(r'^    func ([a-z])(\w*)\(',
                          lambda match: '    func test' + match[1].upper() + match[2] + '(',
                          mirrored, flags=re.M)
        mirrored = mirrored.replace('    func testTick(dt: Float) {}', '    func tick(dt: Float) {}')
        mirrored = mirrored.replace('#expect(', 'XCTAssertTrue(')
        self.assertEqual((repo / 'EngramUnitTests/FrameLookupInvalidationTests.swift').read_text(), mirrored)
        expected = ['FrameLookupInvalidationTests/' + name for name in (
            'testLightColorsRemainLive', 'testLightNodeInvalidation', 'testSelectedEdgeDeletion',
            'testSelectedEdgeReorderAndReplacement', 'testStableFlowAndSelectionChange',
            'testFlowProviderCountAndCap', 'testLabelMembershipSeparatesDomainsAndExtendsAppendPrefix',
            'testLabelMembershipRejectsInvalidContinuity', 'testLabelNumericRescanFollowsMotion',
            'testLabelNumericRescanPreservesMissingPositionSemantics',
            'testLabelNumericSlotsFollowReorderAndTopicChanges')]
        inventory = M.inventory(repo)
        self.assertEqual(len(inventory), 75)
        self.assertEqual([name for name in inventory if name.startswith('FrameLookupInvalidationTests/')],
                         sorted(expected))
        self.assertEqual(M.CLASSES.count('FrameLookupInvalidationTests'), 1)
        domain_controls = ['SceneMetadataDomainTests/' + name for name in (
            'testRevisionDomainsPreserveLateEndpointsAndSkipUnchangedPrefixes',
            'testRevisionFallbacksMatchConservativeEndpointResults',
            'testDuplicateAppendPreservesExistingEndpointPolicy',
            'testRoutingDomainsExtendOnlyCertifiedNodeSuffixes',
            'testRoutingDomainsRebuildForEditsRemovalAndReplacement',
            'testMetadataDomainsMatchConservativeVisibilityAcrossMutations',
            'testMetadataReusePreservesMotionAndLivePriorityOverrides')]
        self.assertEqual([name for name in inventory if name.startswith('SceneMetadataDomainTests/')],
                         sorted(domain_controls))
        self.assertEqual(M.CLASSES.count('SceneMetadataDomainTests'), 1)

class DependencyPreparationTests(unittest.TestCase):
    def setUp(self):
        self.repo = Path('/owned/repo')
        self.pins = json.loads((Path(__file__).parents[1] / 'Package.resolved').read_text())['pins']
        self.remote = [{'packageRef': {'identity': pin['identity'], 'kind': 'remoteSourceControl'},
                        'subpath': pin['identity']} for pin in self.pins]
        self.local = {'packageRef': {'identity': 'repo', 'kind': 'fileSystem',
                                     'name': 'repo', 'location': str(self.repo)},
                      'state': {'name': 'fileSystem', 'path': str(self.repo)},
                      'basedOn': None, 'subpath': 'repo'}

    def test_exact_local_self_preserves_all_remote_checkouts(self):
        before, local = M.dependency_checkouts(self.repo, self.pins, self.remote)
        self.assertIsNone(local)
        after, local = M.dependency_checkouts(self.repo, self.pins, self.remote + [self.local])
        self.assertEqual(before, after)
        self.assertEqual(len(after), 46)
        self.assertEqual(local, self.local['packageRef'])

    def test_unknown_or_wrong_path_local_package_refuses(self):
        for part, key, value in [('packageRef', 'identity', 'unexpected'),
                                 ('packageRef', 'kind', 'remoteSourceControl'),
                                 ('packageRef', 'name', 'AnotherPackage'),
                                 ('packageRef', 'location', '/owned/other'),
                                 ('state', 'path', '/owned/other'),
                                 ('state', 'name', 'edited')]:
            local = copy.deepcopy(self.local); local[part][key] = value
            with self.subTest(part=part, key=key), self.assertRaisesRegex(ValueError, 'unexpected local'):
                M.dependency_checkouts(self.repo, self.pins, self.remote + [local])

    def test_local_self_cannot_hide_missing_duplicate_or_replaced_remote(self):
        for state in (self.remote[:-1] + [self.local], self.remote + [self.remote[0]],
                      self.remote + [self.local, self.local]):
            with self.subTest(count=len(state)), self.assertRaises(ValueError):
                M.dependency_checkouts(self.repo, self.pins, state)
        state = copy.deepcopy(self.remote); state[0]['packageRef']['kind'] = 'fileSystem'
        with self.assertRaisesRegex(ValueError, 'pinned dependency is not remote'):
            M.dependency_checkouts(self.repo, self.pins, state + [self.local])

if __name__ == '__main__': unittest.main()
