"""Complete read-only proposals, sealed before the first native mutation.

The provider never chooses operation IDs or reports stored memory IDs. A plan
contains every exact native request up front, including original provenance,
scope and deterministic UUIDs. Existing UUID targets only: linking to a newly
remembered item requires a later recall, not an ambiguous post-commit rewrite.
This module does not launch anything, dispatch a mutation or publish a cursor.
"""
from __future__ import annotations

import copy
import os
from pathlib import Path

from . import execution_manifest as J, memory_config, migration as durable
from . import operation_gateway as G

MODE = "read_only_plan"
PLAN_NAME = "learner-plan.json"
MAX_WRITES = 5
READ_TOOLS = frozenset({"recall", "graph", "list_topics", "stats", "timeline"})
WRITE_TOOLS = frozenset({"remember", "update", "connect"})
INPUTS = ("provider-dispatch.json", "provider-observation.json", "mcp-audit.jsonl", "proposal.json")


def _tool_schemas(privacy_policy=None):
    from .memory_proxy import learner_tool_descriptor
    return {tool: learner_tool_descriptor({'name': tool}, 'learner', privacy_policy=privacy_policy)['inputSchema']
            for tool in WRITE_TOOLS}


_ARGUMENT_SCHEMAS = _tool_schemas()


def _schema(privacy_policy=None):
    schemas = _ARGUMENT_SCHEMAS if privacy_policy is None else _tool_schemas(privacy_policy)
    choices = []
    for tool in sorted(WRITE_TOOLS):
        arguments = copy.deepcopy(schemas[tool])
        if 'source' in arguments['properties']:
            arguments['properties']['source'].pop('const', None)
        # Strict Structured Outputs requires every property in required. Null
        # represents only an existing optional argument; normalization below
        # removes those known optional nulls before the native policy validator.
        for name, schema in arguments['properties'].items():
            schema.pop('default', None)
            if name not in arguments['required']:
                arguments['properties'][name] = {'anyOf': [schema, {'type': 'null'}]}
        arguments['required'] = list(arguments['properties'])
        choices.append({"type": "object", "additionalProperties": False,
            "required": ["key", "tool", "arguments"], "properties": {
                "key": {"type": "string", "pattern": "^op_[1-5]$"},
                "tool": {"type": "string", "const": tool}, "arguments": arguments}})
    return {"type": "object", "additionalProperties": False,
        "required": ["schema_version", "outcome", "summary", "operations"], "properties": {
            "schema_version": {"type": "integer", "const": 1},
            "outcome": {"type": "string", "enum": ["proposed", "no_new_memories", "failed"]},
            "summary": {"type": "string", "maxLength": 4096},
            "operations": {"type": "array", "maxItems": MAX_WRITES, "items": {"anyOf": choices}}}}


PROPOSAL_SCHEMA = _schema()


def provider_contract(manifest):
    """Use the original sealed policy even before an interrupted plan exists."""
    policy = manifest_policy(manifest)['privacy_policy']
    return (_schema(policy), 'learner_prompt_project.md' if policy else 'learner_prompt.md')


def _require(ok, reason):
    if not ok:
        raise ValueError("learner_plan_" + reason)


def validate_proposal(value, *, provenance, allowed_tools, max_tool_calls, max_writes, read_calls,
                      privacy_policy=None):
    """Return normalized learner arguments after validating the entire cohort."""
    value = J._json(J.encode(value), J.MAX_INPUT)
    _require(privacy_policy in (None, J.PROJECT_SYNC_PRIVACY), 'invalid_privacy_policy')
    schemas = _ARGUMENT_SCHEMAS if privacy_policy is None else _tool_schemas(privacy_policy)
    J._keys(value, {"schema_version", "outcome", "summary", "operations"})
    J._version(value['schema_version'])
    J._string(value['summary'], 4096, nonempty=False)
    J._string(provenance, 4096)
    J._integer(max_tool_calls, 1, 64)
    J._integer(max_writes, 0, MAX_WRITES)
    J._integer(read_calls, 0, max_tool_calls)
    _require(value['outcome'] in {'proposed', 'no_new_memories', 'failed'}, 'invalid_outcome')
    operations = value['operations']
    _require(type(operations) is list and len(operations) <= max_writes
             and read_calls + len(operations) <= max_tool_calls, 'budget_exceeded')
    _require((value['outcome'] == 'proposed') == bool(operations), 'outcome_operations_mismatch')
    for index, item in enumerate(operations, 1):
        J._keys(item, {'key', 'tool', 'arguments'})
        _require(item['key'] == f'op_{index}' and item['tool'] in WRITE_TOOLS
                 and item['tool'] in allowed_tools and type(item['arguments']) is dict, 'invalid_operation')
        args, tool = item['arguments'], item['tool']
        argument_schema = schemas[tool]
        optional = set(argument_schema['properties']) - set(argument_schema['required'])
        args = {key: value for key, value in args.items() if key not in optional or value is not None}
        item['arguments'] = args
        if tool == 'remember':
            private = args.get('is_private') if privacy_policy else args.get('is_private', True)
            _require((type(private) is bool if privacy_policy else private is True)
                     and args.get('force', False) is False,
                     'invalid_remember_policy')
            _require(args.get('source', provenance) == provenance, 'invalid_provenance')
            args.update(is_private=private, force=False, source=provenance)
        elif tool == 'update' and 'source' in args:
            _require(args['source'] == provenance, 'invalid_provenance')
        # The typed native validator rejects objects in UUID fields, arbitrary
        # edits, policy overrides and malformed values before ANY operation runs.
        G.mutation(tool, args, privacy_policy=privacy_policy)
    return value


def manifest_policy(manifest):
    reviewed = manifest.get('plan_origin') == 'reviewed_legacy_accounting'
    _require(reviewed or manifest.get('provider_mode') == MODE, 'wrong_provider_mode')
    policy = manifest.get('plan_policy')
    J._keys(policy, {'max_tool_calls', 'max_writes'}, set() if reviewed else {'privacy'})
    if 'privacy' in policy:
        _require(policy['privacy'] == J.PROJECT_SYNC_PRIVACY, 'invalid_privacy_policy')
    J._integer(policy['max_tool_calls'], 1, 64)
    J._integer(policy['max_writes'], 0, MAX_WRITES)
    configuration = J._json(J._unseal(manifest['inputs']['backend_config']))
    allowed = memory_config.allowed_tools(configuration['memory'], READ_TOOLS | WRITE_TOOLS)
    _require(reviewed or 'recall' in allowed, 'recall_not_permitted')
    return dict(max_tool_calls=policy['max_tool_calls'], max_writes=policy['max_writes'],
                privacy_policy=policy.get('privacy'),
                provenance='codex-session:' + manifest['session_id'], allowed_tools=allowed)


def _inputs(run_dir):
    raws, binding = {}, {}
    manifest, _ = J.read_manifest(run_dir)
    names = ('residual-context.json',) if manifest.get('plan_origin') == 'reviewed_legacy_accounting' else INPUTS
    for name in names:
        raw, identity = durable._read(run_dir / name, maximum=J.MAX_RECORD if name=='residual-context.json' else J.MAX_INPUT)
        raws[name] = raw
        binding[name] = {'sha256': J.sha256(raw), 'identity': identity}
    return raws, binding


def _reviewed_proposal(manifest, digest, raw):
    from . import legacy_reconciliation as L
    context = J._json(raw['residual-context.json'], J.MAX_RECORD)
    review_raw = L._raw(context['review'])
    review = L.accounting_review(J._json(review_raw, J.MAX_INPUT))
    _require(context['manifest_sha256'] == digest and context['review_sha256'] == manifest['review_sha256']
             == J.sha256(review_raw) and review['session_id'] == manifest['session_id'], 'review_origin_changed')
    source = manifest['source']; historical = review['source']
    _require(source == {'identity': historical['identity'], 'start_offset': historical['start'],
             'end_offset': historical['end'], 'excerpt_sha256': historical['excerpt_sha256']}, 'review_source_changed')
    L.accounting_history(review, context['history'])
    proposal = {'schema_version': 1, 'outcome': 'proposed' if review['operations'] else 'no_new_memories',
        'summary': 'Explicit retrospective full review; historical successes are preserved without replay.',
        'operations': [{'key': op['id'], 'tool': op['tool'], 'arguments': op['arguments']} for op in review['operations']]}
    return proposal, {'origin': L.REVIEWED_ACCOUNTING, 'review_sha256': manifest['review_sha256'],
                     'historical_execution_sealed': False, 'tool_calls': 0}


def _candidate(run_dir):
    from . import settlement as S, memory_proxy
    manifest, digest = J.read_manifest(run_dir)
    policy = manifest_policy(manifest)
    raw, binding = _inputs(run_dir)
    if manifest.get('plan_origin') == 'reviewed_legacy_accounting':
        proposal, audit = _reviewed_proposal(manifest, digest, raw)
    else:
        _require(raw['provider-dispatch.json'] == J.encode({'version': 1, 'manifest_sha256': digest}),
                 'provider_dispatch_changed')
        observation = J._json(raw['provider-observation.json'])
        J._keys(observation, {'version', 'manifest_sha256', 'observation'})
        J._version(observation['version'])
        _require(observation['manifest_sha256'] == digest and S._provider_clean(S._observation(observation['observation'])),
                 'provider_not_complete')
        audit = memory_proxy.audit_planning_bytes(raw['mcp-audit.jsonl'], allow_clean_interrupt=True)
        _require(audit['tool_errors'] == 0 and audit['successful_recalls'] > 0, 'read_audit_failed')
        proposal = J._json(raw['proposal.json'])
    proposal = validate_proposal(proposal, **policy, read_calls=audit['tool_calls'])
    _require(proposal['outcome'] != 'failed', 'proposal_failed')
    source = manifest['source']
    requests = []
    for item in proposal['operations']:
        call = 'plan-' + item['key']
        operation = J.operation_id(run_dir, call)
        request = {'version': 1, 'operationID': operation, 'expectedScope': manifest['expected_scope'],
            'provenance': {'host': manifest['host'], 'sessionID': manifest['session_id'],
                'runID': manifest['run_id'], 'source': {'startOffset': source['start_offset'],
                'endOffset': source['end_offset'], 'excerptDigest': source['excerpt_sha256']}},
            'mutation': G.mutation(item['tool'], item['arguments'], privacy_policy=policy['privacy_policy'])}
        native = J.encode(request)
        J._request(native, manifest, operation)
        requests.append({'key': item['key'], 'call_id': call, 'operation_id': operation, 'request': J.seal_json(native)})
    value = {'version': 1, 'kind': 'complete_learner_plan', 'manifest_sha256': digest,
             'inputs': binding, 'proposal': proposal, 'audit': audit, 'operations': requests}
    _require(_inputs(run_dir)[1] == binding, 'planning_evidence_changed')
    return value


def operation_inventory(run_dir, plan=None):
    """Reject unplanned intents or evidence, including a partial foreign file."""
    expected = {} if plan is None else {item['operation_id']: item for item in plan['operations']}
    present = set()
    with os.scandir(run_dir) as entries:
        for index, entry in enumerate(entries):
            _require(index < 4096, 'run_directory_limit')
            if entry.name.startswith('operation-'):
                operation = entry.name[10:-5] if entry.name.endswith('.json') else ''
                _require(operation in expected and entry.name == 'operation-' + operation + '.json', 'unplanned_intent')
                native, _ = J.read_intent(run_dir, operation)
                _require(native == J._unseal(expected[operation]['request']), 'intent_changed')
                present.add(operation)
            elif entry.name.startswith('evidence-'):
                operation = entry.name[9:]
                _require(operation in expected, 'unplanned_evidence')
                J.read_evidence(run_dir, operation)
    return present


def read_plan(run_dir):
    run_dir = J._private(Path(run_dir))
    raw, _ = durable._read(run_dir / PLAN_NAME, maximum=J.MAX_RECORD)
    value = J._json(raw)
    _require(raw == J.encode(_candidate(run_dir)), 'sealed_plan_changed')
    operation_inventory(run_dir, value)
    return value, J.sha256(raw)


def durable_plan(run_dir):
    """Re-establish durability after rename-before-directory-fsync crashes."""
    plan, digest = read_plan(run_dir)
    raws, inputs = _inputs(run_dir)
    _require(inputs == plan['inputs'], 'planning_evidence_changed')
    for name, raw in raws.items():
        J._sync_existing(run_dir / name, raw)
    J._sync_existing(run_dir / PLAN_NAME, J.encode(plan))
    _require(read_plan(run_dir) == (plan, digest), 'sealed_plan_changed')
    return plan, digest


def seal_plan(run_dir, *, verify_fence, validate_inputs):
    """Accept a complete proposal, never an incomplete/mutating provider turn."""
    run_dir = J._private(Path(run_dir))
    manifest, _ = J.read_manifest(run_dir)
    J._check_fence(manifest, verify_fence)
    _require(callable(validate_inputs) and validate_inputs(copy.deepcopy(manifest), 'before_plan_seal') is True,
             'input_validation_refused')
    if os.path.lexists(run_dir / PLAN_NAME):
        plan, _ = durable_plan(run_dir)
        _require(validate_inputs(copy.deepcopy(manifest), 'after_plan_publication') is True, 'input_validation_refused')
        J._check_fence(manifest, verify_fence)
        return plan
    operation_inventory(run_dir)
    _require(not os.path.lexists(run_dir / 'plan-attempts'), 'unplanned_attempts')
    value = _candidate(run_dir)
    raws, inputs = _inputs(run_dir)
    _require(inputs == value['inputs'], 'planning_evidence_changed')
    for name, raw in raws.items():
        J._sync_existing(run_dir / name, raw)
    _require(validate_inputs(copy.deepcopy(manifest), 'before_plan_publication') is True, 'input_validation_refused')
    J._check_fence(manifest, verify_fence)
    _require(value == _candidate(run_dir), 'planning_evidence_changed')
    J._publish_atomic(run_dir / PLAN_NAME, J.encode(value))
    J._check_fence(manifest, verify_fence)
    _require(validate_inputs(copy.deepcopy(manifest), 'after_plan_publication') is True, 'input_validation_refused')
    return read_plan(run_dir)[0]
