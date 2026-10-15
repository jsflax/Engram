"""Finite Swift Testing ABI6.3 parser; pure data, never product execution."""
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET


def require(value, reason):
    if not value:
        raise RuntimeError(reason)


def unique(items):
    result = {}
    for key, value in items:
        require(key not in result, 'sdk_duplicate_json_key')
        result[key] = value
    return result


def base_name(value):
    require(type(value) is str and re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*\([^\n]*\)', value),
            'sdk_function_name_shape')
    return value.split('(', 1)[0]


def event_result(raw, functions, suites, arguments, graph):
    """Require all real function endings and every named parameter invocation.

    Actual Swift6.3 emits testCase events only for parameterized functions;
    xUnit counts declarations, not argument invocations. No successful command
    exit, printed total or XML declaration count substitutes for this stream.
    """
    require(type(raw) is bytes and 0 < len(raw) <= 16*1024**2 and raw.endswith(b'\n'), 'sdk_event_stream_bound_or_incomplete_line')
    wanted = {r['name']: r for r in functions}
    wanted_suites = {r['name']: r for r in suites}
    require(len(wanted) == len(functions) > 0 and len(wanted_suites) == len(suites) > 0,
            'sdk_expected_population_unique')
    require(sum(r['actualCases'] for r in functions) == len(functions)-1+len(arguments)
            and len(set(arguments)) == len(arguments) > 0
            and sum(r['parameterized'] for r in functions) == 1, 'sdk_expected_case_population')
    ids, function_ids, suite_ids = {}, {}, {}
    run_started = run_ended = False
    started, ended, open_cases, case_ended, arg_values = set(), set(), {}, {}, {}
    forbidden, unknown = [], []
    records = raw.splitlines()
    require(len(records) <= 100000 and all(0 < len(r) <= 1024**2 for r in records), 'sdk_event_record_bound')
    for index, line in enumerate(records):
        record = json.loads(line, object_pairs_hook=unique)
        require(type(record) is dict and record.get('version') == '6.3.0', 'sdk_stable_event_version')
        require(not run_ended, 'sdk_event_after_run_end')
        kind, payload = record.get('kind'), record.get('payload')
        require(type(payload) is dict, 'sdk_event_payload_shape')
        if kind == 'test':
            require(not run_started and type(payload.get('id')) is str and payload['id'] not in ids,
                    'sdk_duplicate_or_late_test_record')
            test_kind = payload.get('kind')
            require(test_kind in ('function', 'suite'), 'sdk_test_record_kind')
            name = base_name(payload.get('name')) if test_kind == 'function' else payload.get('name')
            expected = wanted.get(name) if test_kind == 'function' else wanted_suites.get(name)
            require(expected is not None, 'sdk_unexpected_test_declaration')
            location = payload.get('sourceLocation', {})
            require(location.get('filePath') == str(Path(graph)/expected['source'])
                    and location.get('fileID') == 'CurrentCatalogQualificationTests/'+Path(expected['source']).name
                    and location.get('line') == expected['line'], 'sdk_test_source_provenance')
            if test_kind == 'function':
                require(payload.get('isParameterized') is expected['parameterized'] and name not in function_ids,
                        'sdk_parameterization_or_duplicate_function')
                function_ids[name] = payload['id']
            else:
                require(name not in suite_ids, 'sdk_duplicate_suite'); suite_ids[name] = payload['id']
            ids[payload['id']] = dict(kind=test_kind, name=name, expected=expected)
            continue
        require(kind == 'event', 'sdk_unknown_record_kind')
        stage, ident = payload.get('kind'), payload.get('testID')
        if stage == 'runStarted':
            require(not run_started and ident is None and set(function_ids) == set(wanted)
                    and set(suite_ids) == set(wanted_suites), 'sdk_incomplete_inventory_or_duplicate_run')
            run_started = True; continue
        require(run_started, 'sdk_event_before_run_start')
        if stage == 'runEnded':
            require(ident is None and any(m.get('symbol') == 'pass' for m in payload.get('messages', [])), 'sdk_run_end_without_pass')
            run_ended = True; continue
        require(ident in ids, 'sdk_event_unknown_test_id')
        item = ids[ident]
        if stage == 'testStarted':
            require(ident not in started and ident not in ended, 'sdk_duplicate_test_start'); started.add(ident)
        elif stage == 'testEnded':
            require(ident in started and ident not in ended and ident not in open_cases, 'sdk_unmatched_test_end'); ended.add(ident)
        elif stage == 'testCaseStarted':
            require(item['kind'] == 'function' and item['expected']['parameterized']
                    and ident in started and ident not in ended and ident not in open_cases, 'sdk_unexpected_or_overlapping_parameter_case')
            messages = [m['text'] for m in payload.get('messages', []) if m.get('symbol') == 'default']
            require(len(messages) == 1 and messages[0].count('action → ') == 1, 'sdk_argument_observation_missing')
            text = messages[0].split('action → ', 1)[1]
            suffix = ' to '+item['name']+'(_:) started.'
            require(text.endswith(suffix), 'sdk_argument_observation_shape')
            value = text[:-len(suffix)]
            match = re.fullmatch(r'\.?(?:[A-Za-z_][A-Za-z_0-9]*\.)*([A-Za-z_][A-Za-z_0-9]*)', value)
            require(match and match[1] in arguments and match[1] not in arg_values.get(ident, set()), 'sdk_unknown_or_duplicate_argument')
            open_cases[ident] = match[1]; arg_values.setdefault(ident, set()).add(match[1])
        elif stage == 'testCaseEnded':
            require(ident in open_cases and ident not in ended, 'sdk_unmatched_parameter_case_end')
            open_cases.pop(ident); case_ended[ident] = case_ended.get(ident, 0)+1
        elif stage in ('issueRecorded', 'testSkipped', 'testCancelled', 'testCaseCancelled'):
            forbidden.append(dict(record=index, kind=stage, testID=ident, payload=payload))
        else:
            unknown.append(dict(record=index, kind=stage, testID=ident))
    rows = []
    for name, expected in wanted.items():
        ident = function_ids.get(name)
        observed = case_ended.get(ident, 0) if expected['parameterized'] else int(ident in ended)
        parameter_set = sorted(arg_values.get(ident, set()))
        rows.append(dict(name=name, id=ident, expectedCases=expected['actualCases'], observedCases=observed,
                         functionStarted=ident in started, functionEnded=ident in ended,
                         arguments=parameter_set,
                         exactArguments=(set(parameter_set) == set(arguments)) if expected['parameterized'] else True))
    all_passed = bool(run_started and run_ended and not forbidden and not unknown and not open_cases
        and started == ended == set(ids) and len(function_ids) == len(wanted)
        and len(suite_ids) == len(wanted_suites)
        and all(r['functionStarted'] and r['functionEnded'] and r['observedCases'] == r['expectedCases']
                and r['exactArguments'] for r in rows))
    return dict(exactFunctions=len(function_ids) == len(wanted), functionCount=len(function_ids),
        suiteCount=len(suite_ids), expectedInvocations=sum(r['actualCases'] for r in functions),
        observedInvocations=sum(r['observedCases'] for r in rows), runStarted=run_started, runEnded=run_ended,
        forbiddenEvents=forbidden, unknownEvents=unknown, rows=rows, allPassed=all_passed)


def xunit_result(raw, functions):
    require(type(raw) is bytes and 0 < len(raw) <= 16*1024**2
            and b'<!DOCTYPE' not in raw and b'<!ENTITY' not in raw, 'sdk_xml_bound_or_entity')
    root = ET.fromstring(raw)
    rows = []
    expected = {r['name']: r for r in functions}
    for case in root.iter('testcase'):
        name = base_name(case.get('name'))
        require(name in expected and case.get('classname') == 'CurrentCatalogQualificationTests.'+expected[name]['suite'],
                'sdk_xml_unexpected_function_or_suite')
        rows.append(dict(name=name, failures=len(case.findall('failure')), errors=len(case.findall('error')),
                         skipped=len(case.findall('skipped')), time=case.get('time')))
    names = [r['name'] for r in rows]
    exact = len(names) == len(set(names)) == len(expected) and set(names) == set(expected)
    return dict(exactFunctions=exact, functionCount=len(rows), rows=rows,
        allPassed=exact and all(not(r['failures'] or r['errors'] or r['skipped']) for r in rows))
