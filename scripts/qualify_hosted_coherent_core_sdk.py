#!/usr/bin/env python3
"""Fresh coherent source qualification; never an app/profile/lifecycle issuer."""
import sys
if not (sys.flags.isolated and sys.flags.no_site and sys.flags.dont_write_bytecode
        and sys.implementation.name == 'cpython' and sys.version_info >= (3, 11)):
    raise RuntimeError('isolated_no_site_no_bytecode_cpython_required')
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import pwd
import re
import shutil
import signal
import stat
import threading
import time
import types
import xml.etree.ElementTree as ET

PLAN_SHA = '2b27346be71a9108f7737dc0cc86f049faf62e1a1376af975130665da50346f6'
HELPER_SHA = 'a3f2349c052f03881a2690077eca84ce85a6bae414f08b3315d87b33b8ea7728'
COMMAND_SHA = 'aab985543261f94b181a367bce56275c3203048bc2d2030b6e2708ecfca95f1b'
GATE_SHA = 'b69a4a80b6b2c18653b52f26915ec9e21a0c8c90d41402915d5ec06559a8d8b8'
_HELD = None


def require(value, code):
    if not value:
        raise RuntimeError(code)


def bootstrap(path, limit, expected):
    require(path.is_absolute() and path.resolve(strict=True) == path, 'canonical_source_required')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    identity = lambda s: (s.st_dev, s.st_ino, s.st_uid, s.st_gid, s.st_mode,
                          s.st_nlink, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    try:
        first = os.fstat(fd)
        require(stat.S_ISREG(first.st_mode) and first.st_nlink == 1 and 0 < first.st_size <= limit
                and identity(first) == identity(path.lstat()), 'source_type_size_identity')
        raw = bytearray()
        while len(raw) < first.st_size:
            part = os.read(fd, min(65536, first.st_size-len(raw)))
            require(part, 'source_short_read'); raw.extend(part)
        require(not os.read(fd, 1) and identity(first) == identity(os.fstat(fd))
                == identity(path.lstat()), 'source_changed')
    except BaseException as first_failure:
        try:
            os.close(fd)
        except BaseException as close_failure:
            raise first_failure from close_failure
        raise
    else:
        os.close(fd)
    require(hashlib.sha256(raw).hexdigest() == expected, 'source_pin_changed')
    return bytes(raw)


def load(path, raw, name):
    namespace = {'__name__': name, '__file__': str(path)}
    exec(compile(raw, str(path), 'exec'), namespace)
    return types.SimpleNamespace(**namespace)


def inventory(raw):
    require(len(raw) <= 16*1024**2, 'inventory_bound')
    result, suite = [], None
    for line in raw.decode('utf-8').splitlines():
        if not line or line.startswith(('Running main()', 'Note:')):
            continue
        text = line.split('#', 1)[0].rstrip()
        if text and not line.startswith(' ') and text.endswith('.'):
            suite = text[:-1]
        elif line.startswith('  ') and text.strip():
            require(suite is not None, 'inventory_suite_missing')
            result.append(suite+'.'+text.strip())
    require(result and len(result) == len(set(result)) <= 20000, 'inventory_duplicate_or_bound')
    return result


def native_result(raw, expected):
    require(len(raw) <= 16*1024**2 and b'<!DOCTYPE' not in raw and b'<!ENTITY' not in raw, 'xml_bound_or_entity')
    root = ET.fromstring(raw)
    rows = []
    for case in root.iter('testcase'):
        name = case.get('classname', '')+'.'+case.get('name', '')
        rows.append(dict(name=name, time=case.get('time'), failures=len(case.findall('failure')),
                         errors=len(case.findall('error')), skipped=len(case.findall('skipped')),
                         status=case.get('status'), result=case.get('result')))
    names = [r['name'] for r in rows]
    exact = len(names) == len(set(names)) == len(expected) and set(names) == set(expected)
    return dict(exactNames=exact, tests=len(rows), rows=rows,
        allPassed=exact and all(not(r['failures'] or r['errors'] or r['skipped'])
            and r['status'] == 'run' and r['result'] == 'completed' for r in rows))


class FloorStop:
    """Keep the established command owner; add the original work-floor veto."""
    def __init__(self, original, root, end, floor):
        self.actual = original.StopFlag()
        self.root, self.end, self.floor = root, end, floor
        self.last = -1.0
        self.first = None
        self.minimum = None

    @property
    def requested(self):
        now = time.monotonic()
        if self.first is None and now-self.last >= 1:
            self.last = now
            try:
                free = shutil.disk_usage(self.root).free
                self.minimum = free if self.minimum is None else min(self.minimum, free)
                if free < self.floor:
                    self.first = 'original_12gib_work_floor'
            except BaseException:
                self.first = 'work_floor_observation_unknown'
        if self.first is None and now >= self.end:
            self.first = 'original_overall_deadline'
        return self.actual.requested or self.first is not None

    def install(self):
        self.actual.install()

    def restore(self):
        self.actual.restore()


class Qualification:
    def __init__(self, args, helper, original, plan, seals, began):
        self.args, self.h, self.original, self.plan, self.seals = args, helper, original, plan, seals
        self.process, self.thread, self.uid = os.getpid(), threading.get_ident(), os.geteuid()
        self.root, self.graph = args.root, args.root/'graph'
        self.end = began+plan['originalOverallBudgetSeconds']
        self.stop = FloorStop(original, args.root.parent, self.end, plan['workFloorBytes'])
        self.commands = self.negative = None
        self.reserved = self.evidence_created = False
        self.root_identity = None
        self.exported_bytes = self.exported_files = 0
        self.prepared = None
        self.result = dict(format='lattice-coherent-core-sdk-qualification/1', kind=args.kind,
            inputGraphSHA256=plan['graphSealSHA256'], requiredSHA256=plan['requiredSHA256'],
            originalBudgetSeconds=plan['originalOverallBudgetSeconds'], workFloorBytes=plan['workFloorBytes'],
            harnessCommit=args.harness_commit, primaryFailure=None, primaryException=None, cleanupFailures=[],
            buildSucceeded=False, focusedTestsPassed=False, importerBuildOnly=False,
            allProjectObjectsModulesAndArchivesFresh=True, oldObjectsReused=False,
            legacySemanticProfileRequiredForCompilation=False, legacySemanticProfileQualified=False,
            actualManagedLifecycleQualified=False, ownerRetirementQualified=False, runtimePerformanceQualified=False,
            releaseQualified=False)

    def budget(self, reserve=0):
        require(os.getpid() == self.process and threading.get_ident() == self.thread
                and os.geteuid() == self.uid, 'compiler_creator_changed')
        require(not self.stop.requested and time.monotonic()+reserve < self.end, 'compiler_canceled_floor_or_late')
        if self.reserved:
            require(self.h.namespace_identity(self.root) == self.root_identity, 'compiler_root_changed')

    def remember(self, failure):
        if self.result['primaryFailure'] is None:
            self.result['primaryFailure'] = str(failure)[:256]
            self.result['primaryException'] = self.original.exception_fact(failure)

    def run(self, label, argv, seconds):
        self.budget(31)
        return self.commands.run(label, [str(x) for x in argv], cwd=self.root, env=self.env,
            seconds=min(seconds, self.end-time.monotonic()-30), stderr_separate=True)

    def reserve(self):
        self.budget(120)
        self.stop.install()
        self.root.mkdir(mode=0o700); self.reserved = True
        self.root_identity = self.h.namespace_identity(self.root)
        self.args.evidence.mkdir(mode=0o700); self.evidence_created = True
        self.evidence_identity = self.h.namespace_identity(self.args.evidence)
        for leaf in ['private','receipts','negative-private','negative-receipts','tmp','modules',
                     'security','swift-sdks','build','sdk-scratch']:
            (self.root/leaf).mkdir(mode=0o700)
        account = pwd.getpwuid(self.uid)
        self.env = dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME=account.pw_dir,
            USER=account.pw_name, LOGNAME=account.pw_name, TMPDIR=str(self.root/'tmp'),
            DEVELOPER_DIR=str(self.args.developer_dir), SDKROOT=str(self.args.sdk_root),
            MACOSX_DEPLOYMENT_TARGET='14.0', CLANG_MODULE_CACHE_PATH=str(self.root/'modules'),
            SWIFT_MODULECACHE_PATH=str(self.root/'modules'), SWIFTPM_MODULECACHE_OVERRIDE=str(self.root/'modules'),
            GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_TERMINAL_PROMPT='0',
            PYTHONDONTWRITEBYTECODE='1', CCACHE_DISABLE='1',
            LATTICE_TEST_LOG_PATH=str(self.root/'tmp/lattice_debug.log'))
        self.commands = self.original.CommandOwner(self.stop, self.root/'receipts', self.root/'private')
        self.negative = self.original.CommandOwner(self.stop, self.root/'negative-receipts', self.root/'negative-private')
        self.result['positivePreflight'] = self.original.qualify_owner(self.commands, cwd=self.root, env=self.env)
        self.result['negativePreflight'] = self.original.qualify_nonzero_owner(self.negative, cwd=self.root, env=self.env)

    def prepare(self):
        self.budget(120)
        self.h.private_copy(self.args.graph, self.graph, self.seals['graph'], 'owner-sealed-source-graph-v1')
        self.h.private_copy(self.args.cache, self.root/'cache', self.seals['cache'], 'owner-sealed-dependency-cache-v1')
        self.h.private_copy(self.args.config, self.root/'config', self.seals['config'], self.seals['config']['format'])
        self.result['cacheRefsRestoration'] = self.h.restore_seed_refs_directories(self.root/'cache', self.seals['cache'])
        self.result['swiftVersion'] = self.run('actual-swift-version', ['/usr/bin/swift','--version'], 30)
        row = self.run('actual-sdk-path', ['/usr/bin/xcrun','--sdk','macosx','--show-sdk-path'], 30)
        sdk = self.original.bounded_regular(Path(row['stdout']), 4096).decode().strip()
        require(len(sdk.splitlines()) == 1 and Path(sdk).resolve(strict=True) == self.args.sdk_root, 'actual_sdk_differs')
        if self.args.kind == 'sdk-importer':
            rewrites = []
            for row in self.plan['manifestBindings']:
                path = self.graph/row['path']; before = self.h.bounded_source_bytes(path, 1024**2)
                after = before
                for old, new in row['replacements']:
                    require(after.count(old.encode()) == 1, 'exact_manifest_preimage')
                    after = after.replace(old.encode(), new.encode(), 1)
                require(hashlib.sha256(after).hexdigest() == row['boundBody']['sha256'], 'exact_manifest_postimage')
                path.unlink(); self.h.exclusive_bytes(path, after)
                rewrites.append(dict(path=row['path'], beforeSHA256=hashlib.sha256(before).hexdigest(), afterSHA256=hashlib.sha256(after).hexdigest()))
            lock = self.h.bounded_source_bytes(self.args.owner_lock, 1024**2)
            require(hashlib.sha256(lock).hexdigest() == self.plan['ownerLockSHA256'], 'strict39_lock_changed')
            lock_path = self.graph/'OwnerImages/Package.resolved'
            require(not os.path.lexists(lock_path), 'owner_lock_not_fresh')
            self.h.exclusive_bytes(lock_path, lock)
            self.result['manifestRewrites'] = rewrites
            self.env['LATTICE_RECLAMATION_COMPOSED_ENGRAM_SOURCE'] = str(self.graph/'Engram')
        self.prepared = self.h.census(self.graph, 'coherent-qualification-private-source/1')
        self.h.save(self.root/'PREPARED-SOURCE.json', self.prepared)
        self.budget(120)

    def core(self):
        flags = '-fmodules-cache-path='+str(self.root/'modules')
        argv = [self.args.cmake,'-S',self.graph/'Core','-B',self.root/'build','-DCMAKE_BUILD_TYPE=Debug',
            '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON','-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0',
            '-DCMAKE_OSX_SYSROOT='+str(self.args.sdk_root),'-DCMAKE_CXX_FLAGS='+flags,'-DCMAKE_C_FLAGS='+flags,
            '-DCMAKE_CXX_COMPILER_LAUNCHER=','-DCMAKE_C_COMPILER_LAUNCHER=',
            '-DLATTICE_SYNC_COMMIT_PROBE=OFF','-DLATTICE_MANAGED_TARGET_RECLAMATION_FIXTURE=OFF',
            '-DLATTICE_MANAGED_TARGET_RECLAMATION_OWNER_FIXTURE=OFF',
            '-DLATTICE_MANAGED_TARGET_RECLAMATION_HISTORY_FIXTURE=OFF']
        self.run('core-configure', argv, 180)
        self.run('core-build', [self.args.cmake,'--build',self.root/'build','--target',
            'LatticeCoreTests','LatticeSwiftCppBridge','LatticeInstallationLauncher','--parallel','2'], 5400)
        self.result['buildSucceeded'] = True
        exe = self.root/'build/LatticeCoreTests'
        self.result['nativeExecutable'] = self.original.file_fact(exe, 512*1024**2)
        listing = self.run('native-inventory', [exe,'--gtest_list_tests'], 30)
        names = inventory(self.h.bounded_source_bytes(Path(listing['stdout']), 16*1024**2))
        expected = self.plan['nativeNames']
        require(set(expected) <= set(names), 'planned_native_case_missing')
        self.result['actualDiscoveredTests'] = len(names)
        xml = self.root/'focus.xml'
        failure = None
        try:
            self.run('native-focus', [exe,'--gtest_filter='+':'.join(expected),'--gtest_repeat=1',
                '--gtest_color=no','--gtest_output=xml:'+str(xml)], 1800)
        except BaseException as actual_failure:
            failure = actual_failure
            self.remember(actual_failure)
        # Preserve exact names and first failure even when native exit is nonzero.
        if xml.exists():
            facts = native_result(self.h.bounded_source_bytes(xml, 16*1024**2), expected)
            self.h.save(self.root/'NATIVE-RESULT.json', facts)
            self.result['native'] = facts
            self.result['focusedTestsPassed'] = facts['allPassed'] and failure is None
            parent = self.plan['genuineChildRole']['mandatoryParent']
            parent_rows = [r for r in facts['rows'] if r['name'] == parent]
            parent_pass = len(parent_rows) == 1 and all(not parent_rows[0][x] for x in ['failures','errors','skipped'])
            helper_pairs = {}
            for index, path in enumerate((self.root/'tmp').iterdir()):
                require(index < 100000, 'native_tmp_inventory_bound')
                match = re.fullmatch(r'(continuous_[0-9]+\.sqlite)-(seed|reopen)-terminal\.log', path.name)
                if match:
                    require(len(helper_pairs) < 32 or match[1] in helper_pairs, 'native_helper_pair_bound')
                    body = self.h.bounded_source_bytes(path, 1024**2)
                    helper_pairs.setdefault(match[1], {})[match[2]] = dict(
                        path=str(path), bytes=len(body), sha256=hashlib.sha256(body).hexdigest(),
                        actualHelperRan=b'[ RUN      ] RecoveryProducerContinuity.ProcessHelper' in body,
                        actualHelperPassed=b'[       OK ] RecoveryProducerContinuity.ProcessHelper' in body)
            genuine = parent_pass and len(helper_pairs) == 1 and all(
                set(pair) == {'seed','reopen'} and pair['seed']['actualHelperRan']
                and pair['reopen']['actualHelperPassed'] for pair in helper_pairs.values())
            self.result['genuineProcessHelper'] = dict(parent=parent, parentPassed=parent_pass,
                actualPairs=helper_pairs, complete=genuine, runnerInjectedChildRole=False,
                childWaitAndExitAssertionsRemainOriginalSource=True)
            self.result['focusedTestsPassed'] = self.result['focusedTestsPassed'] and genuine
        require(self.result['focusedTestsPassed'], 'native_first_population_not_all_passed')

    def sdk(self):
        argv = ['/usr/bin/swift','build','--package-path',self.graph/'OwnerImages',
            '--scratch-path',self.root/'sdk-scratch','--cache-path',self.root/'cache',
            '--config-path',self.root/'config','--security-path',self.root/'security',
            '--swift-sdks-path',self.root/'swift-sdks','--manifest-cache','local','--configuration','debug',
            '--disable-automatic-resolution','--skip-update','--disable-netrc','--disable-keychain',
            '--disable-experimental-prebuilts','--disable-index-store','--jobs','2',
            '-Xswiftc','-module-cache-path','-Xswiftc',self.root/'modules',
            '-Xcc','-fmodules-cache-path='+str(self.root/'modules'),
            '-Xcxx','-fmodules-cache-path='+str(self.root/'modules')]
        macros = ['LATTICE_MANAGED_TARGET_RECLAMATION_OWNER_FIXTURE',
            'LATTICE_MANAGED_TARGET_RECLAMATION_HISTORY_FIXTURE',
            'LATTICE_MANAGED_TARGET_RECLAMATION_HISTORY_EXTRA_ALIAS']
        for macro in macros:
            argv += ['-Xswiftc','-D'+macro,'-Xcxx','-D'+macro,'-Xcc','-D'+macro]
        self.result['buildMacros'] = macros
        self.run('sdk-owner-images-build', argv, 5400)
        lock = self.h.bounded_source_bytes(self.graph/'OwnerImages/Package.resolved', 1024**2)
        require(hashlib.sha256(lock).hexdigest() == self.plan['ownerLockSHA256'], 'strict39_lock_changed')
        pins = {r['identity']:r for r in json.loads(lock, object_pairs_hook=self.h.unique)['pins']}
        require(len(pins) == 39, 'strict39_pin_population')
        state_raw = self.h.bounded_source_bytes(self.root/'sdk-scratch/workspace-state.json', 16*1024**2)
        state = json.loads(state_raw, object_pairs_hook=self.h.unique)
        local, remote = set(), set()
        wanted = {str(self.graph/x) for x in ['Core','SDK','Engram']}
        for dep in state['object']['dependencies']:
            ref = dep['packageRef']
            if ref.get('kind') == 'fileSystem':
                require(ref['location'] in wanted and dep['state'].get('name') == 'fileSystem'
                    and dep['state'].get('path') == ref['location'], 'wrong_local_package')
                local.add(ref['location'])
            else:
                ident = ref['identity']
                require(ref.get('kind') == 'remoteSourceControl' and ident in pins and ident not in remote
                    and dep['state'].get('name') == 'sourceControlCheckout'
                    and dep['state']['checkoutState']['revision'] == pins[ident]['state']['revision'], 'actual_remote_revision')
                remote.add(ident)
        require(local == wanted and remote == set(pins), 'all_actual_local_and_remote_packages_required')
        self.h.exclusive_bytes(self.root/'ACTUAL-WORKSPACE-STATE.json', state_raw)
        row = self.run('sdk-bin-path', argv+['--show-bin-path'], 30)
        raw = self.original.bounded_regular(Path(row['stdout']), 4096).decode().strip()
        require(len(raw.splitlines()) == 1, 'bin_path_shape')
        directory = Path(raw).resolve(strict=True)
        require(directory.is_relative_to(self.root/'sdk-scratch'), 'bin_path_escape')
        images = []
        for name in ['memory-sync','lattice-reclamation-paired-image']:
            image = directory/name
            require(image.resolve(strict=True) == image and image.lstat().st_mode & 0o111, 'linked_image_required')
            images.append(dict(name=name, **self.original.file_fact(image, 512*1024**2)))
        self.result.update(buildSucceeded=True, importerBuildOnly=True, actualLinkedImages=images,
            actualLocalPackages=sorted(local), actualRemotePins=len(remote), focusedTestsPassed=False)

    def export(self, path, relative, limit):
        require(self.h.namespace_identity(self.args.evidence) == self.evidence_identity, 'evidence_namespace_changed')
        raw = self.h.bounded_source_bytes(path, limit)
        require(self.exported_files < 1024 and self.exported_bytes+len(raw) <= 512*1024**2, 'evidence_bound')
        self.exported_files += 1; self.exported_bytes += len(raw)
        target = self.args.evidence/relative
        target.parent.mkdir(parents=True, exist_ok=True)
        self.h.exclusive_bytes(target, raw)

    def finish(self):
        if self.reserved:
            try:
                if self.prepared is not None:
                    require(self.h.census(self.graph, 'coherent-qualification-private-source/1') == self.prepared,
                            'compiler_changed_private_source')
                self.h.verified_tree(self.args.graph, self.seals['graph'], 'owner-sealed-source-graph-v1')
                self.h.verified_tree(self.args.cache, self.seals['cache'], 'owner-sealed-dependency-cache-v1')
                self.h.verified_tree(self.args.config, self.seals['config'], self.seals['config']['format'])
                self.h.json_input(self.args.required_sources,self.args.required_sources_sha256)
                require(hashlib.sha256(self.h.bounded_source_bytes(self.args.owner_lock,1024**2)).hexdigest()
                    == self.plan['ownerLockSHA256'], 'input_owner39_lock_changed')
            except BaseException as failure:
                self.remember(failure); self.result['cleanupFailures'].append('source_or_dependency_input_changed')
        try:
            self.stop.restore()
        except BaseException as failure:
            self.remember(failure); self.result['cleanupFailures'].append('signal_restore_unproved')
        self.result['commands'] = [] if self.commands is None else [x.row for x in self.commands.owners]
        self.result['minimumObservedFreeBytes'] = self.stop.minimum
        self.result['firstSupervisorRefusal'] = self.stop.first
        if self.reserved:
            # A failed/oversize evidence copy must not hide the first build/test
            # outcomes or prevent attempts to retain other bounded raw files.
            candidates = []
            if self.evidence_created:
                for directory in ['receipts','negative-receipts','private','negative-private']:
                    if (self.root/directory).is_dir():
                        candidates.extend((path, directory+'/'+path.name, 256*1024**2)
                            for path in sorted((self.root/directory).iterdir()))
                for name in ['PREPARED-SOURCE.json','focus.xml','NATIVE-RESULT.json','ACTUAL-WORKSPACE-STATE.json']:
                    if (self.root/name).exists(): candidates.append((self.root/name,name,16*1024**2))
                for path in sorted((self.root/'tmp').glob('continuous_*.sqlite-*-terminal.log')):
                    candidates.append((path,'helper-logs/'+path.name,1024**2))
                if self.args.kind == 'native-core' and (self.root/'build/compile_commands.json').exists():
                    candidates.append((self.root/'build/compile_commands.json','compile_commands.json',32*1024**2))
                if len(candidates) > 1023:
                    failure = RuntimeError('evidence_file_population_bound')
                    self.remember(failure); self.result['cleanupFailures'].append(str(failure))
                for path, name, limit in candidates[:1023]:
                    try:
                        require(time.monotonic() < self.end, 'evidence_original_deadline')
                        # Keep16MiB of the fixed aggregate for the first receipt.
                        require(self.exported_bytes+path.lstat().st_size <= 496*1024**2, 'raw_evidence_reserve_bound')
                        self.export(path,name,limit)
                    except BaseException as failure:
                        self.remember(failure)
                        self.result['cleanupFailures'].append('bounded_evidence_copy_failed:'+name)
            passed = bool(self.result['primaryFailure'] is None and not self.result['cleanupFailures']
                and self.result['buildSucceeded'] and (self.args.kind == 'sdk-importer' or self.result['focusedTestsPassed'])
                and not self.stop.requested and time.monotonic() < self.end)
            self.result['limitedQualificationPassed'] = passed
            try:
                require(self.h.namespace_identity(self.root) == self.root_identity, 'compiler_root_changed')
                self.h.save(self.root/'QUALIFICATION.json', self.result)
                if self.evidence_created:
                    self.export(self.root/'QUALIFICATION.json', 'QUALIFICATION.json', 16*1024**2)
                # Never rewrite a first receipt after late export/return.
                require(time.monotonic() < self.end, 'first_receipt_or_export_returned_late')
            except BaseException:
                return False
            return passed and time.monotonic() < self.end
        return False


def main():
    global _HELD
    began = time.monotonic()
    p = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    p.add_argument('--ephemeral-ci-vm', action='store_true', required=True)
    p.add_argument('--kind', choices=['native-core','sdk-importer'], required=True)
    for name in ['graph','graph-pins','required-sources','cache','cache-pins','config','config-pins',
                 'owner-lock','root','evidence','cmake','developer-dir','sdk-root']:
        p.add_argument('--'+name, type=Path, required=True)
    for name in ['graph-pins-sha256','required-sources-sha256','cache-pins-sha256','config-pins-sha256','harness-commit']:
        p.add_argument('--'+name, required=True)
    args = p.parse_args()
    plan_path = Path(__file__).absolute().with_name('coherent_core_sdk_plan.json')
    plan = json.loads(bootstrap(plan_path, 1024**2, PLAN_SHA))
    require(_HELD is None and sys.platform == 'darwin' and platform.machine() == 'arm64'
        and os.getuid() == os.geteuid() > 0 and signal.getsignal(signal.SIGCHLD) == signal.SIG_DFL
        and int(platform.mac_ver()[0].split('.')[0]) >= 26
        and os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('RUNNER_ENVIRONMENT') == 'github-hosted'
        and os.environ.get('GITHUB_EVENT_NAME') == 'workflow_dispatch' and os.environ.get('GITHUB_RUN_ATTEMPT') == '1'
        and os.environ.get('GITHUB_REPOSITORY') == 'jsflax/Engram'
        and re.fullmatch(r'[0-9a-f]{40}',args.harness_commit)
        and os.environ.get('GITHUB_SHA') == os.environ.get('ENGRAM_WORKFLOW_SHA') == args.harness_commit,
        'actual_first_hosted_caller_required')
    require(args.graph_pins_sha256 == plan['graphSealSHA256']
        and args.required_sources_sha256 == plan['requiredSHA256'], 'selected_coherent_graph_required')
    for name in ['graph','graph_pins','required_sources','cache','cache_pins','config','config_pins','owner_lock',
                 'root','evidence','cmake','developer_dir','sdk_root']:
        setattr(args,name,getattr(args,name).absolute())
    base = Path(pwd.getpwuid(os.geteuid()).pw_dir)/'localdev'
    require(base.resolve(strict=True) == base and args.root.parent == base
        and re.fullmatch(r'lqc[0-9a-f]{8}',args.root.name) and not os.path.lexists(args.root)
        and args.evidence.name == 'evidence' and args.evidence.parent.is_relative_to(base)
        and args.evidence.parent.resolve(strict=True) == args.evidence.parent
        and not os.path.lexists(args.evidence), 'fresh_localdev_namespaces_required')
    for name in ['cmake','developer_dir','sdk_root']:
        require(getattr(args,name).resolve(strict=True) == getattr(args,name), 'actual_toolchain_required')
    helper_path = args.graph/'FixtureScripts/build_hosted_provider.py'
    helper = load(helper_path, bootstrap(helper_path, 1024**2, HELPER_SHA), 'coherent_data_helpers')
    seals = dict(graph=helper.json_input(args.graph_pins,args.graph_pins_sha256),
        cache=helper.json_input(args.cache_pins,args.cache_pins_sha256),
        config=helper.json_input(args.config_pins,args.config_pins_sha256))
    helper.json_input(args.required_sources,args.required_sources_sha256)
    helper.verified_tree(args.graph,seals['graph'],'owner-sealed-source-graph-v1')
    require(hashlib.sha256(helper.bounded_source_bytes(args.owner_lock,1024**2)).hexdigest() == plan['ownerLockSHA256']
        and hashlib.sha256(helper.bounded_source_bytes(args.config/'mirrors.json',1024**2)).hexdigest() == plan['mirrorSHA256'],
        'actual_owner39_lock_and_mirrors_required')
    scripts=args.graph/'Core/Tools/LatticeManagedTargetReclamationFixture/HostedCustody/scripts'
    command_path=scripts/'managed_startup_command_owner.py'
    command_raw=bootstrap(command_path,1024**2,COMMAND_SHA)
    bootstrap(scripts/'managed_startup_exec_gate.py',65536,GATE_SHA)
    original=load(command_path,command_raw,'coherent_original_command_owner')
    held=Qualification(args,helper,original,plan,seals,began)
    _HELD=held
    try:
        held.reserve();held.prepare()
        held.core() if args.kind == 'native-core' else held.sdk()
    except BaseException as failure:
        held.remember(failure)
    finally:
        passed=held.finish()
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
