#!/usr/bin/env python3
"""Release qualification using a fresh native database and synthetic review.

No installed runtime, prior fixture database, provider, or live learner state is
selected. The explicit binary must include its normal bundled model resources.
The required new work directory retains private evidence even on failure.
"""
from __future__ import annotations

import argparse
import contextlib
import dataclasses
import hashlib
import importlib
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import sys
import time
import traceback
from types import SimpleNamespace
import uuid

sys.dont_write_bytecode = True
FACTS = (
    'The synthetic orchard tracks pear harvest weights in kilograms and stores weather observations separately.',
    'The synthetic observatory schedules a mirror inspection every third Tuesday at local noon.',
    'The synthetic library shelves botanical field guides beside its large paper atlases.',
    'The synthetic ferry terminal uses a blue triangular sign for bicycle boarding.',
    'The synthetic laboratory records refrigerator calibration readings in a dedicated weekly notebook.',
)


class GateFailure(RuntimeError):
    pass


def require(condition, label):
    if not condition:
        raise GateFailure('native_residual_gate_' + label)


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1048576), b''):
            digest.update(chunk)
    return digest.hexdigest()


def create_work_dir(path):
    path = Path(path)
    require(path.is_absolute(), 'work_dir_not_absolute')
    parent = path.parent
    require(parent.resolve(strict=True) == parent, 'work_parent_not_canonical')
    info = parent.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
            and not info.st_mode & 0o022, 'work_parent_not_owned')
    require(not os.path.lexists(path), 'work_dir_not_fresh')
    path.mkdir(mode=0o700)
    require(path.resolve(strict=True) == path and path.stat().st_mode & 0o777 == 0o700,
            'work_dir_not_private')
    return path


def save(path, value):
    raw = (json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n').encode()
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        with os.fdopen(fd, 'wb', closefd=False) as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(fd)
    finally:
        os.close(fd)


def rows(store, sql, args=()):
    with contextlib.closing(sqlite3.connect(store.as_uri() + '?mode=ro', uri=True)) as db:
        db.execute('PRAGMA query_only=ON')
        deadline = time.monotonic() + 3
        db.set_progress_handler(lambda: time.monotonic() >= deadline, 1000)
        return db.execute(sql, args).fetchall()


def seed_preserved_row(store, expected, receipt):
    """Disposable setup only, after native cleanup and exclusive fence drain.

    Preserve the complete native-generated embedding/default columns. Replace
    only the synthetic historical fields, and delete only the known bootstrap
    operation receipt. A second row or receipt refuses before any SQL mutation.
    """
    columns = tuple(expected)
    require(columns and all(re.fullmatch(r'[A-Za-z][A-Za-z0-9]*', c) for c in columns),
            'invalid_fixture_columns')
    require(receipt.get('outcome') == 'applied' and len(receipt.get('memoryIDs', [])) == 1
            and receipt.get('edgeIDs') == [], 'bootstrap_not_applied')
    memory = receipt['memoryIDs'][0]
    operation = receipt['operationID']
    with contextlib.closing(sqlite3.connect(store)) as db:
        db.create_function('sync_disabled', 0, lambda: 1)
        db.execute('BEGIN IMMEDIATE')
        try:
            require(db.execute('SELECT COUNT(*) FROM Memory').fetchone() == (1,), 'bootstrap_row_count')
            require(db.execute('SELECT COUNT(*) FROM Edge').fetchone() == (0,), 'bootstrap_edge_count')
            require(db.execute('SELECT COUNT(*) FROM EngramOperationReceiptV1').fetchone() == (1,),
                    'bootstrap_receipt_count')
            saved = db.execute('SELECT receiptJSON FROM EngramOperationReceiptV1 '
                'WHERE operationID=? COLLATE NOCASE LIMIT 2', (operation,)).fetchall()
            require(len(saved) == 1 and json.loads(saved[0][0]) == receipt, 'bootstrap_receipt_changed')
            updated = db.execute('UPDATE Memory SET ' + ','.join('"' + c + '"=?' for c in columns) +
                ' WHERE globalId=? COLLATE NOCASE', tuple(expected[c] for c in columns) + (memory,))
            require(updated.rowcount == 1, 'bootstrap_memory_changed')
            deleted = db.execute('DELETE FROM EngramOperationReceiptV1 WHERE operationID=? COLLATE NOCASE',
                (operation,))
            require(deleted.rowcount == 1, 'bootstrap_receipt_changed')
            db.commit()
        except BaseException:
            db.rollback()
            raise


def load_runtime(repo):
    repo = repo.resolve(strict=True)
    tests = repo / 'Tests/codex_plugin'
    package = repo / 'codex/plugins/engram/scripts'
    require((tests / 'residual_context_fixture.py').is_file(), 'missing_assembled_fixture')
    sys.path[:0] = [str(package), str(tests)]
    names = ('residual_context', 'residual_publication', 'residual_driver', 'native_executor',
             'operation_probe', 'execution_manifest', 'execution_context', 'writer_fence')
    modules = {name: importlib.import_module('codex_learner.' + name) for name in names}
    for name, module in modules.items():
        require(Path(module.__file__).resolve() == package / 'codex_learner' / (name + '.py'),
                'runtime_not_from_assembled_package')
    fixture = importlib.import_module('residual_context_fixture')
    require(Path(fixture.__file__).resolve() == tests / 'residual_context_fixture.py',
            'fixture_not_from_assembled_package')
    return modules, fixture


def bootstrap(fixture, modules, transport, directory, limits):
    """Bounded normal MCP creates the schema and exactly one native fixture row."""
    F, J, N, probe = (modules[name] for name in
        ('writer_fence', 'execution_manifest', 'native_executor', 'operation_probe'))
    directory.mkdir(mode=0o700)
    binding = F.create(directory, generation_id=str(uuid.uuid4()), owner_id=str(uuid.uuid4()))
    writer = F.acquire_shared(directory, binding)
    try:
        scope = probe.probe_scope(transport, writer_fence=writer, expected_binding=binding, limits=limits)
        require(rows(fixture.store, 'SELECT COUNT(*) FROM Memory') == [(0,)], 'fresh_store_not_empty')
        manifest = {'expected_scope': scope, 'host': 'native-release-fixture',
            'session_id': fixture.plan['session_id'], 'run_id': 'fixture-bootstrap',
            'source': {'start_offset': 0, 'end_offset': 1, 'excerpt_sha256': J.sha256(b'fixture')},
            'inputs': {'backend_route': J.seal_json(J.encode({'transport': transport}))}}
        request = {'version': 1, 'operationID': str(uuid.uuid4()), 'expectedScope': scope,
            'provenance': {'host': manifest['host'], 'sessionID': manifest['session_id'],
                'runID': manifest['run_id'], 'source': {'startOffset': 0, 'endOffset': 1,
                'excerptDigest': manifest['source']['excerpt_sha256']}},
            'mutation': {'kind': 'remember', 'request': {
                'content': fixture.row_values[0]['content'], 'project': 'Engram',
                'topic': 'learner-recovery', 'isPrivate': True,
                'source': 'codex-session:' + fixture.plan['session_id']}}}
        raw = J.encode(request)
        J.durable._new(directory / 'bootstrap-request.json', raw)
        def check(_phase):
            return writer.verify(binding)
        message = N.executor(SimpleNamespace(manifest=manifest), transport, limits=limits)(raw, writer, check)
        payload = modules['residual_driver'].G.envelope(message['result'])
        require(payload.get('kind') == 'committed', 'bootstrap_uncommitted')
        receipt = payload['receipt']
        J._receipt(receipt, request)
        save(directory / 'bootstrap-response.json', message)
    finally:
        writer.close()
    # Returning native executor/probe means their direct child has been reaped.
    # EX acquisition additionally proves the inherited SH generation drained.
    with F.revoke(directory, binding, timeout_seconds=1, validate=lambda *_: True):
        seed_preserved_row(fixture.store, fixture.row_values[0], receipt)
    require(rows(fixture.store, 'SELECT COUNT(*) FROM EngramOperationReceiptV1') == [(0,)],
            'bootstrap_receipt_not_removed')
    return scope, receipt


def run(args):
    work = create_work_dir(args.work_dir)
    report = {'version': 1, 'success': False, 'phase': 'configuration', 'provider_invoked': False,
        'installed_runtime_selected': False, 'live_store_access': False, 'work_dir': str(work)}
    target = work / 'result.json'
    f = None
    started = time.monotonic()
    def stage(name):
        report['phase'] = name
        save(target, report)
        print('Native residual gate:', name, flush=True)
    try:
        native = args.native.resolve(strict=True)
        info = native.stat()
        require(stat.S_ISREG(info.st_mode) and os.access(native, os.X_OK), 'native_not_executable')
        report['native_path'], report['native_sha256'] = str(native), sha(native)
        modules, fixture_module = load_runtime(args.repo)
        J, C, N, P, probe = (modules[name] for name in
            ('execution_manifest', 'execution_context', 'native_executor', 'residual_publication', 'operation_probe'))
        report['runtime_sha256s'] = {name: sha(Path(module.__file__)) for name, module in modules.items()}
        report['production_limits'] = dataclasses.asdict(probe.ProbeLimits())
        setup_limits = probe.ProbeLimits(deadline_seconds=30)
        report['setup_limits'] = dataclasses.asdict(setup_limits)
        f = fixture_module.ResidualContextFixture(fixture_parent=work)
        f.base_fixture.temp._finalizer.detach()  # Explicit evidence retention, even on success.
        report['fixture'] = str(f.base)
        require(f.base.is_relative_to(work), 'fixture_outside_work_dir')
        # The scaffold's tiny SQLite file is disposable; never import another DB.
        for suffix in ('', '-wal', '-shm'):
            candidate = Path(str(f.store) + suffix)
            require(candidate.parent.is_relative_to(work) and not candidate.is_symlink(), 'unsafe_fixture_store')
            candidate.unlink(missing_ok=True)
        home, temporary = f.base / 'native-home', work / 'tmp'
        home.mkdir(mode=0o700); (home / '.claude').mkdir(mode=0o700); temporary.mkdir(mode=0o700)
        env = {'CLAUDE_MEMORY_DB': str(f.store), 'CFFIXED_USER_HOME': str(home),
               'TMPDIR': str(temporary), 'ENGRAM_LATTICE_LOG_LEVEL': 'off'}
        f.config.write_text('[mcp_servers.memory]\ncommand = ' + json.dumps(str(native)) +
            '\nargs = []\ndefault_tools_approval_mode = "approve"\ncwd = ' + json.dumps(str(f.base)) +
            '\n[mcp_servers.memory.env]\n' + ''.join(k + ' = ' + json.dumps(v) + '\n' for k, v in env.items()))
        f.runtime = native
        _, route = C._backend(f.paths.base())
        stage('fresh_native_bootstrap')
        _, receipt = bootstrap(f, modules, route['transport'], work / 'bootstrap', setup_limits)
        report['bootstrap'] = {'memory_id': receipt['memoryIDs'][0], 'operation_id': receipt['operationID'],
            'direct_child_reaped_and_generation_drained': True, 'fixture_receipt_removed': True}
        for op, fact in zip(f.plan['operations'], FACTS):
            op['arguments']['content'] = fact
            op['arguments_canonical_sha256'] = J.sha256(J.encode(op['arguments']))
        f.history, f.intents = f.make_history()
        for role, raw in f.history.items():
            path = f.historical_run_dir / f.base_fixture.L.ROLES[role]
            path.write_bytes(raw); path.chmod(0o644 if role == 'result' else 0o600)
        f.make_reports()
        before_state, _, before_pending = f.current()
        before_history = f.history_snapshot()
        old_id = fixture_module.SUCCESS_ID
        columns = ','.join('"' + c + '"' for c in f.base_fixture.L.ROW_FIELDS)
        select_old = 'SELECT ' + columns + ' FROM Memory WHERE globalId=? COLLATE NOCASE LIMIT 2'
        preserved = rows(f.store, select_old, (old_id,))
        require(len(preserved) == 1, 'preserved_row_missing')
        stage('production_scope_and_context')
        f.scope = probe.probe_scope(route['transport'], writer_fence=f.writer, expected_binding=f.binding)
        f.seal(prepare_driver=False)
        report.update(run_id=f.context.run_id, manifest_sha256=f.context.manifest_sha256,
                      context_sha256=f.context.context_sha256, review_sha256=f.context.review_sha256)
        with f.locks() as verify:
            f.begin(verify)
            execute = N.executor(f.driver, f.context.transport)  # Production limits, never widened.
            for label in f.driver.operations:
                stage('dispatch_' + label)
                outcome = f.driver.dispatch(label, writer=f.writer, recoveries=[], execute=execute)
                report['dispatch_summary'] = outcome
                save(target, report)
                require(label in outcome['applied'] and not outcome['unchanged'], 'native_dispatch_unsettled')
                require(f.state_path.read_bytes() == before_state, 'cursor_advanced_before_settlement')
            stage('exclusive_status_and_publication')
            f.revoke()
            receipt = P.finish(f.context, recoveries=f.recoveries, verify_locks=verify)
            report['receipt'] = receipt
            save(target, report)
            require(P.recover_locked(f.paths, session_id=fixture_module.SID, verify_locks=verify) is None,
                    'completed_recovery_not_noop')
        stage('independent_readback')
        state = J._json(f.state_path.read_bytes())
        require(state['offset'] == f.end and state['status'] == P.RESULT, 'final_cursor_changed')
        require(state['last_run'] == f.state['last_run'], 'historical_failure_changed')
        for key in ('last_success', 'last_success_run_id', 'last_success_at'):
            require(state.get(key) == f.state.get(key), 'historical_success_changed')
        require('reconciliation_required' not in state and not (f.run_dir / 'successful-coverage.json').exists(),
                'incorrect_coverage_claim')
        require(f.history_snapshot() == before_history and f.pending_path.read_bytes() == before_pending,
                'history_or_pending_changed')
        require(rows(f.store, select_old, (old_id,)) == preserved, 'preserved_row_changed')
        require(rows(f.store, 'SELECT COUNT(*) FROM Memory') == [(6,)] and
                rows(f.store, 'SELECT COUNT(*) FROM EngramOperationReceiptV1') == [(5,)], 'final_native_counts')
        actual = rows(f.store, 'SELECT globalId,content,source,isPrivate FROM Memory '
                     'WHERE globalId<>? COLLATE NOCASE', (old_id,))
        require({str(uuid.UUID(row[0])) for row in actual} == set(receipt['reference']['new_memory_ids'])
                and {row[1] for row in actual} == set(FACTS)
                and {row[2] for row in actual} == {'codex-session:' + fixture_module.SID}
                and all(row[3] == 1 for row in actual), 'native_content_or_privacy_changed')
        require(sha(native) == report['native_sha256'] and all(
            sha(Path(modules[name].__file__)) == digest for name, digest in report['runtime_sha256s'].items()),
            'runtime_changed')
        report.update(success=True, phase='complete', memory_count=6, operation_receipt_count=5,
            old_row_unchanged=True, old_history_unchanged=True, pending_unchanged=True,
            independent_readback=True, provider_success_claimed=False)
        print('PASS: fresh native residual execution and exact retrospective publication.', flush=True)
        return 0
    except BaseException as error:
        reason = str(error)
        save(work / 'failure-details.json', {'type': type(error).__name__,
            'message': reason, 'traceback': traceback.format_exc()})
        report['failure'] = {'type': type(error).__name__, 'label': reason if re.fullmatch(
            r'[A-Za-z][A-Za-z0-9_]{0,160}', reason) else 'see_private_artifacts'}
        print('FAIL:', report['phase'], report['failure']['label'], flush=True)
        return 1
    finally:
        if f is not None:
            for held in reversed(f.handles):
                held.close()
        report['elapsed_seconds'] = round(time.monotonic() - started, 3)
        save(target, report)


def parser():
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument('--native', required=True, type=Path)
    value.add_argument('--work-dir', required=True, type=Path)
    value.add_argument('--repo', required=True, type=Path, help='Checkout with assembled plugin and synthetic test fixtures')
    return value


if __name__ == '__main__':
    try:
        sys.exit(run(parser().parse_args()))
    except (OSError, GateFailure) as error:
        print('FAIL: work directory was not created:', type(error).__name__, file=sys.stderr)
        sys.exit(1)
