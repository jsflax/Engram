#!/usr/bin/env python3
"""Bind an owned Xcode test host before launch; audit focused XCTest results."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess

CLASSES = ('GalaxyLoadChangesTests', 'GalaxyDrainTests', 'VisualizerHostIsolationTests')

def require(ok, message):
    if not ok:
        raise ValueError(message)

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def owned(root, path):
    path = path.resolve(strict=True)
    require(path == root or root in path.parents, 'path outside validation root')
    return path

def inventory(repo):
    result = []
    for name in CLASSES:
        source = repo / 'EngramUnitTests' / (name + '.swift')
        methods = re.findall(r'^\s+func (test\w+)\(', source.read_text(), re.M)
        require(methods and len(methods) == len(set(methods)), 'invalid test source inventory')
        result.extend(name + '/' + method for method in methods)
    return sorted(result)

def isolate(value, environment):
    """Only documented xctestrun v2 host-environment/selection fields change."""
    result = copy.deepcopy(value)
    require(result.get('__xctestrun_metadata__', {}).get('FormatVersion') == 2, 'unknown xctestrun format')
    configurations = result.get('TestConfigurations')
    require(isinstance(configurations, list) and len(configurations) == 1, 'unexpected test configurations')
    configuration = configurations[0]
    require(configuration.get('IsEnabled', True) is True, 'test configuration disabled')
    targets = [target for target in configuration['TestTargets'] if target.get('BlueprintName') == 'EngramUnitTests']
    require(len(targets) == 1, 'unit target missing or ambiguous')
    target = targets[0]
    require(not target.get('IsUITestBundle', False), 'unexpected UI test host')
    require(target.get('TestBundlePath', '').endswith('/EngramUnitTests.xctest'), 'unexpected unit bundle')
    require(target.get('TestHostPath', '').endswith(('/Engram.app', '/Engram.app/Contents/MacOS/Engram')),
            'unexpected application host')
    require(not target.get('SkipTestIdentifiers'), 'focused tests must not be skipped')
    require(not target.get('CommandLineArguments'), 'unexpected host arguments')
    require(not target.get('UITargetAppPath'), 'unexpected UI target')
    existing = target.get('EnvironmentVariables', {})
    require(isinstance(existing, dict), 'unexpected host environment')
    # Do not inherit alternate database/account/instrumentation selectors.
    controlled = {k for k in existing if k.startswith(('ENGRAM_', 'CLAUDE_', 'GOOGLE_', 'TEST_AUTH_'))}
    require(controlled <= environment.keys(), 'unreviewed app environment selector')
    require('HOME' not in existing and 'CODEX_HOME' not in existing, 'home override in generated host')
    testing = target.get('TestingEnvironmentVariables')
    require(isinstance(testing, dict), 'missing generated test launch environment')
    require(not (set(testing) & (set(environment) | {'HOME', 'CODEX_HOME'})), 'conflicting test launch environment')
    target['EnvironmentVariables'] = {**existing, **environment}
    target['OnlyTestIdentifiers'] = list(CLASSES)
    target['ParallelizationEnabled'] = False
    configuration['TestTargets'] = targets
    return result

def prepare(root):
    repo = owned(root, root / 'repo')
    products = owned(root, root / 'derived/Build/Products')
    paths = list(products.glob('*.xctestrun'))
    require(len(paths) == 1, 'expected one original generated xctestrun')
    original = paths[0]
    value = plistlib.loads(original.read_bytes())
    fixtures = owned(root, root / 'fixtures')
    environment = {
        'ENGRAM_PERF_ISOLATED': '1',
        'ENGRAM_VISUALIZER_TEST_ROOT': str(fixtures),
        'CLAUDE_MEMORY_DB': str(fixtures / 'app-memory.sqlite'),
        'CFFIXED_USER_HOME': str(owned(root, root / 'test-home')),
        'TMPDIR': str(owned(root, root / 'tmp')),
        'ENGRAM_TEST_ROOT': str(fixtures),
        'ENGRAM_ADOPTION_TEST_ROOT': str(fixtures),
    }
    require(not (fixtures / 'app-memory.sqlite').exists(), 'app fixture is not fresh')
    prepared = isolate(value, environment)
    target_spec = prepared['TestConfigurations'][0]['TestTargets'][0]
    host = owned(root, Path(target_spec['TestHostPath'].replace('__TESTROOT__', str(products))))
    require('Engram.app' in host.parts, 'host path escaped app product')
    app = host if host.name == 'Engram.app' else host.parents[2]
    require(app.name == 'Engram.app', 'unexpected host executable layout')
    host_binary = owned(root, app / 'Contents/MacOS/Engram')
    bundle = owned(root, Path(target_spec['TestBundlePath'].replace('__TESTROOT__', str(products))
                             .replace('__TESTHOST__', str(app))))
    test_binary = owned(root, bundle / 'Contents/MacOS/EngramUnitTests')
    # __TESTROOT__ expands relative to the xctestrun, so retain Products location.
    target = products / 'VisualizerValidation.xctestrun'
    target.write_bytes(plistlib.dumps(prepared))
    target.chmod(0o600)
    evidence = root / 'evidence'
    (evidence / 'original.xctestrun').write_bytes(original.read_bytes())
    (evidence / 'isolated.xctestrun').write_bytes(target.read_bytes())
    expected = inventory(repo)
    (evidence / 'test-host.json').write_text(json.dumps({
        'original_sha256': digest(original), 'isolated_sha256': digest(target),
        'xctestrun': str(target), 'environment': environment, 'expected_tests': expected,
        'binaries_sha256': {str(path): digest(path) for path in (host_binary, test_binary)},
        'test_count': len(expected), 'HOME_CODEX_HOME_overridden': False,
    }, indent=2) + '\n')
    return {'prepared': str(target), 'expected_tests': len(expected)}

def dependency_checkouts(repo, pins, dependencies):
    """Xcode adds the local package itself to SwiftPM's managed dependencies."""
    expected = {pin['identity'] for pin in pins}
    require(len(pins) == len(expected) == 46, 'dependency pins changed')
    checkouts = {}
    seen = set()
    local = None
    for entry in dependencies:
        reference = entry['packageRef']
        identity = reference['identity']
        require(identity not in seen, 'duplicate dependency identity')
        seen.add(identity)
        if identity in expected:
            require(reference['kind'] == 'remoteSourceControl', 'pinned dependency is not remote')
            checkouts[identity] = entry['subpath']
        else:
            # The only additional package is this exact, already hash-checked repo.
            require(local is None and reference['kind'] in ('root', 'fileSystem')
                    and reference['name'] in ('Engram', repo.name)
                    and identity in ('engram', repo.name.lower())
                    and reference['location'] == str(repo)
                    and entry['state'] == {'name': 'fileSystem', 'path': str(repo)}
                    and entry.get('basedOn') is None, 'unexpected local dependency')
            local = reference
    require(set(checkouts) == expected, 'dependency set changed')
    return checkouts, local

def verify_inputs(root):
    repo = root / 'repo'
    identity = json.loads((root / 'evidence/source-identity.json').read_text())
    require(subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()
            == identity['source_sha'], 'source commit changed')
    mirror_path = '.swiftpm/configuration/mirrors.json'
    for path, expected in identity['files_sha256'].items():
        if path != mirror_path:
            require(digest(repo / path) == expected, 'source changed: ' + path)
    original_mirrors = json.loads((root / 'private/mirrors.json').read_text())['object']
    actual_mirrors = json.loads((repo / mirror_path).read_text())['object']
    extra = {'original': 'https://github.com/sparkle-project/Sparkle/releases/download/2.8.1/Sparkle-for-Swift-Package-Manager.zip',
             'mirror': 'http://127.0.0.1:8765/Sparkle-for-Swift-Package-Manager.zip'}
    require(len(actual_mirrors) == len(original_mirrors) + 1
            and all(row in actual_mirrors for row in original_mirrors + [extra]), 'dependency mirror changed')
    original_lock = (root / 'private/Package.resolved').read_bytes()
    for path in ('Package.resolved', 'Engram.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'):
        require((repo / path).read_bytes() == original_lock, 'dependency lock changed')
    pins = json.loads(original_lock)['pins']
    suffix = 'final' if (root / 'evidence/inputs-initial.json').exists() else 'initial'
    state_bytes = (root / 'scratch/workspace-state.json').read_bytes()
    with (root / 'evidence' / ('workspace-state-' + suffix + '.json')).open('xb') as output:
        output.write(state_bytes)
    state = json.loads(state_bytes)['object']['dependencies']
    checkouts, local = dependency_checkouts(repo, pins, state)
    heads = {}
    for pin in pins:
        checkout = owned(root, root / 'scratch/checkouts' / checkouts[pin['identity']])
        head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=checkout, text=True).strip()
        require(head == pin['state']['revision'], 'dependency revision changed: ' + pin['identity'])
        heads[pin['identity']] = head
    result = {'source_sha': identity['source_sha'], 'source_files': len(identity['files_sha256']),
              'lock_sha256': hashlib.sha256(original_lock).hexdigest(), 'pins': pins,
              'actual_checkout_heads': heads, 'sdk_mirrors_preserved': True,
              'local_package_reference': local, 'workspace_state_sha256': hashlib.sha256(state_bytes).hexdigest()}
    destination = root / 'evidence' / ('inputs-' + suffix + '.json')
    require(not destination.exists(), 'input verification receipt already exists')
    destination.write_text(json.dumps(result, indent=2) + '\n')
    return {'input_receipt': str(destination), 'source_files': result['source_files'], 'pins': len(pins)}

def audit(root):
    evidence = root / 'evidence'
    binding = json.loads((evidence / 'test-host.json').read_text())
    require(digest(Path(binding['xctestrun'])) == binding['isolated_sha256'], 'test host binding changed')
    require(all(digest(owned(root, Path(path))) == expected
                for path, expected in binding['binaries_sha256'].items()), 'compiled product changed')
    expected = inventory(root / 'repo')
    require(expected == binding['expected_tests'], 'test inventory changed')
    log = (evidence / 'tests/output.log').read_text()
    passed = re.findall(r"Test Case '-\[(?:\w+\.)?(\w+) (test\w+)\]' passed", log)
    actual = sorted(name + '/' + method for name, method in passed if name in CLASSES)
    require(actual == expected, 'missing, duplicate or unexpected focused XCTest pass')
    require(not re.search(r"Test Case .*\b(?:failed|skipped)\b", log), 'failed or skipped test')
    result = json.loads((evidence / 'tests/receipt.json').read_text())
    require(result.get('exit_code') == 0 and result.get('reason') == 'exit'
            and result.get('child_exit_code') == 0 and not result.get('log_truncated')
            and result.get('reader_complete') is True and not result.get('reader_error')
            and not result.get('errors') and not result.get('signals_received')
            and not result.get('cleanup', {}).get('remaining')
            and not result.get('cleanup', {}).get('errors'), 'test command did not finish cleanly')
    # Exact product paths only; never print unrelated processes or signal them.
    listing = subprocess.check_output(['/bin/ps', '-axo', 'pid=,comm='], text=True, timeout=5)
    live = [line for line in listing.splitlines() if str(root / 'derived') in line]
    require(not live, 'owned app/test process remains after xcodebuild')
    for name in ('Package.resolved', 'Engram.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'):
        require((root / 'repo' / name).read_bytes() == (root / 'private/Package.resolved').read_bytes(), 'dependency lock changed')
    outcome = {'status': 'passed', 'test_count': len(actual), 'tests': actual,
               'test_log_sha256': digest(evidence / 'tests/output.log'),
               'result_sha256': digest(evidence / 'tests/receipt.json'),
               'owned_product_processes_remaining': 0}
    (evidence / 'FOCUSED-RESULT.json').write_text(json.dumps(outcome, indent=2) + '\n')
    return outcome

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=('prepare', 'audit', 'verify-inputs'))
    parser.add_argument('--root', required=True, type=Path)
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    require(root.parent == Path.home() / 'localdev', 'validation root must be a direct localdev child')
    print(json.dumps({'prepare': prepare, 'audit': audit, 'verify-inputs': verify_inputs}[args.phase](root), sort_keys=True))
