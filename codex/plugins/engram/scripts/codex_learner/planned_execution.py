"""Resume one complete learner plan using the original idempotency keys.

The worker holds its session lock and drains previous holders before supplying
the ORIGINAL nonrevoked shared fence. No provider, fresh generation or new UUID
is used on resume. A repeated exact operation_apply is also a status/replay:
the native transaction returns its original committed receipt without applying
the mutation again. Missing replies never mean absence or completed coverage.

Each invocation forwards at most the plan's five operations, stopping on the
first uncertainty. It never sleeps or writes a cursor. Only the publication
owner may revoke after complete execution (or a zero-write planning failure).
"""
from __future__ import annotations

import copy
import os
from pathlib import Path
from types import SimpleNamespace

from . import execution_manifest as J, learner_plan as P, migration as durable
from . import operation_gateway as G, writer_fence as F
from . import native_executor as N, operation_probe

MAX_ATTEMPTS = 1024
# A mutation also performs embedding/vector/transaction work after scope. Keep
# read-only probes and reviewed-residual executor defaults at their own 10s.
MUTATION_DEADLINE_SECONDS = 30.0


class PlanRefused(ValueError):
    """Invalid authority/evidence; preserve processing and require inspection."""


def _require(ok, reason):
    if not ok:
        raise PlanRefused('planned_execution_' + reason)


def read_attempts(run_dir, plan, digest):
    directory = run_dir / 'plan-attempts'
    if not os.path.lexists(directory):
        return []
    J._private(directory)
    paths = J._event_paths(directory, planning=True)
    _require(len(paths) <= MAX_ATTEMPTS, 'attempt_limit')
    requests = {item['operation_id']: J._unseal(item['request']) for item in plan['operations']}
    manifest, _ = J.read_manifest(run_dir)
    result, previous = [], None
    for index, path in enumerate(paths):
        _require(path.name == f'{index:06d}.json', 'attempt_sequence_changed')
        raw, _ = durable._read(path, maximum=J.MAX_INPUT)
        item = J._json(raw)
        J._keys(item, {'version', 'sequence', 'previous_sha256', 'kind', 'manifest_sha256',
                      'plan_sha256', 'operation_id', 'request_sha256', 'fencing'})
        J._version(item['version'])
        J._integer(item['sequence'], index, index)
        _require(item['kind'] == 'planned_dispatch' and item['previous_sha256'] == previous
                 and item['manifest_sha256'] == plan['manifest_sha256'] and item['plan_sha256'] == digest
                 and item['operation_id'] in requests
                 and item['request_sha256'] == J.sha256(requests[item['operation_id']])
                 and J.encode(item['fencing']) == J.encode(manifest['fencing']), 'attempt_binding_changed')
        previous = J.sha256(raw)
        result.append(item)
    return result


def inspect_plan(run_dir):
    """Read exact durable progress; no backend, dispatch or authority claim."""
    run_dir = Path(run_dir)
    plan, digest = P.read_plan(run_dir)
    attempts = read_attempts(run_dir, plan, digest)
    attempted = {item['operation_id'] for item in attempts}
    present = P.operation_inventory(run_dir, plan)
    records, memory_ids = [], set()
    for item in plan['operations']:
        operation = item['operation_id']
        events = J.read_evidence(run_dir, operation) if operation in present else []
        kinds = [event['evidence']['kind'] for event in events]
        receipts = [event['evidence']['receipt'] for event in events if event['evidence']['kind'] == 'committed']
        _require(not events or kinds[0] == 'dispatch', 'response_without_dispatch')
        _require(not receipts or operation in attempted, 'receipt_without_attempt')
        _require(operation not in attempted or 'dispatch' in kinds, 'attempt_without_dispatch')
        receipt = receipts[-1] if receipts else None
        _require(receipt is None or receipt['outcome'] != 'applied' or bool(receipt['memoryIDs']),
                 'applied_without_memory_ids')
        # A valid committed receipt is final. A later contradictory native result
        # is rejected by the journal; transient observations cannot erase it.
        if receipt is not None and receipt['outcome'] == 'applied':
            memory_ids.update(J._uuid(value) for value in receipt['memoryIDs'])
        records.append({'operation_id': operation, 'mutation': J._json(J._unseal(item['request']))['mutation']['kind'],
                        'dispatched': bool(events), 'settled': receipt is not None, 'receipt': receipt})
    complete = all(record['settled'] for record in records)
    return {'status': 'complete' if complete else 'pending', 'reason': 'verified_plan_completion' if complete else 'plan_pending',
            'plan_sha256': digest, 'operations': records, 'attempts': len(attempts),
            'applied_write_calls': sum(record['receipt'] is not None and record['receipt']['outcome'] == 'applied' for record in records),
            'unchanged_write_calls': sum(record['receipt'] is not None and record['receipt']['outcome'] == 'unchanged' for record in records),
            'memory_ids': sorted(memory_ids)}


def native_executor(run_dir, transport, *, limits=None, diagnostic=None):
    """Use the existing bounded exact-route native transport/cleanup contract."""
    from . import native_executor as N
    manifest, _ = J.read_manifest(run_dir)
    P.manifest_policy(manifest)
    limits = limits or operation_probe.ProbeLimits(deadline_seconds=MUTATION_DEADLINE_SECONDS)
    return N.executor(SimpleNamespace(manifest=manifest), transport, limits=limits, diagnostic=diagnostic)


def _durable_progress(run_dir):
    """A complete post-crash receipt is synced before it can grant completion."""
    before = inspect_plan(run_dir)
    for record in before['operations']:
        path = run_dir / ('operation-' + record['operation_id'] + '.json')
        if not os.path.lexists(path):
            continue
        J._sync_existing(path, durable._read(path, maximum=J.MAX_RECORD)[0])
        directory = run_dir / ('evidence-' + record['operation_id'])
        if os.path.lexists(directory):
            for path in J._event_paths(directory, planning=True):
                J._sync_existing(path, durable._read(path, maximum=J.MAX_RECORD)[0])
    directory = run_dir / 'plan-attempts'
    if os.path.lexists(directory):
        for path in J._event_paths(directory, planning=True):
            J._sync_existing(path, durable._read(path, maximum=J.MAX_RECORD)[0])
    _require(inspect_plan(run_dir) == before, 'progress_changed')


def execute_plan(run_dir, *, writer, validate_inputs, execute, diagnostic=None):
    run_dir = J._private(Path(run_dir))
    manifest, manifest_sha = J.read_manifest(run_dir)
    _require(type(writer) is F.HeldFence and writer.mode == 'shared', 'shared_original_fence_required')
    _require(callable(validate_inputs) and callable(execute), 'callbacks_required')
    plan, digest = P.read_plan(run_dir)

    def verify(binding):
        return writer.verify(binding)

    def check(phase):
        _require(J.read_manifest(run_dir)[1] == manifest_sha and P.read_plan(run_dir)[1] == digest,
                 'plan_changed')
        _require(writer.verify(manifest['fencing']) is True, 'writer_unfenced')
        writer.pass_fds()
        _require(validate_inputs(copy.deepcopy(manifest), phase) is True, 'input_validation_refused')
        _require(writer.verify(manifest['fencing']) is True, 'writer_unfenced')
        return True

    check('before_plan_execution')
    P.durable_plan(run_dir)
    _durable_progress(run_dir)
    check('before_plan_execution')
    for item in plan['operations']:
        progress = inspect_plan(run_dir)
        record = next(record for record in progress['operations'] if record['operation_id'] == item['operation_id'])
        if record['settled']:
            continue
        operation, native = item['operation_id'], J._unseal(item['request'])
        check('before_plan_intent')
        _require(J.publish_intent(run_dir, item['call_id'], native, verify_fence=verify, atomic=True) == native,
                 'intent_changed')
        check('before_plan_dispatch')
        if not J.read_evidence(run_dir, operation):
            _require(J.record_dispatch(run_dir, operation, verify_fence=verify, atomic=True) == native, 'intent_changed')
        # Legacy journal permits a single original dispatch. This separate chain
        # records each exact-byte idempotent attempt, including lost replies.
        attempts = read_attempts(run_dir, plan, digest)
        _require(len(attempts) < MAX_ATTEMPTS, 'attempt_limit')
        directory = run_dir / 'plan-attempts'
        durable._mkdir(directory)
        previous = None if not attempts else J.sha256(durable._read(directory / f'{len(attempts)-1:06d}.json')[0])
        attempt = {'version': 1, 'sequence': len(attempts), 'previous_sha256': previous,
            'kind': 'planned_dispatch', 'manifest_sha256': manifest_sha, 'plan_sha256': digest,
            'operation_id': operation, 'request_sha256': J.sha256(native), 'fencing': manifest['fencing']}
        J._publish_atomic(directory / f'{len(attempts):06d}.json', J.encode(attempt))
        check('before_plan_forward')
        reason = None
        response_reason = 'transport_error'
        detail = {}
        try:
            message = execute(native, writer, check)
        except (PlanRefused, operation_probe.ProbeError) as error:
            N.observe(diagnostic, {'kind': 'native_plan_failure', 'operation_id': operation,
                'reason': 'native_execution_refused', **N.failure_fields(error)})
            raise
        except (OSError, ValueError, TimeoutError) as error:
            reason = 'native_reply_unavailable'
            detail = N.failure_fields(error)
        else:
            try:
                _require(type(message) is dict and 'error' not in message, 'invalid_native_reply')
                value = G.envelope(message.get('result'))
                if value['kind'] == 'error':
                    reason = 'native_operation_unavailable'
                    response_reason = 'backend_error'
                    detail = {'native_error_code': value['code']}  # G.envelope checked the closed allowlist.
                else:
                    J._keys(value, {'version', 'kind', 'receipt'})
                    _require(value['kind'] == 'committed', 'invalid_native_reply')
                    J._receipt(value['receipt'], J._json(native))
                    _require(value['receipt']['outcome'] != 'applied' or bool(value['receipt']['memoryIDs']),
                             'applied_without_memory_ids')
            except (ValueError, TypeError, KeyError) as error:
                reason = 'native_reply_invalid'
                response_reason = 'invalid_response'
                detail = N.failure_fields(error)
        if reason is not None:
            # Do not infer absence, success or fresh authority from uncertainty.
            N.observe(diagnostic, {'kind': 'native_plan_failure', 'operation_id': operation,
                'reason': reason, 'response_reason': response_reason, **detail})
            J.record_response(run_dir, operation, {'kind': 'unavailable', 'reason': response_reason}, verify_fence=verify, atomic=True)
            check('after_plan_response')
            return dict(inspect_plan(run_dir), reason=reason)
        # Retain known commits before rechecking mutable source/admission. A
        # revocation during the call must not hide an effect that already landed.
        J.record_response(run_dir, operation, {'kind': 'committed', 'receipt': value['receipt']}, verify_fence=verify, atomic=True)
        check('after_plan_response')
    check('after_plan_execution')
    return inspect_plan(run_dir)
