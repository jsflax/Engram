"""Pure SDK event/population cases, not compilation or catalog execution."""
from pathlib import Path
import copy
import json
import types
import unittest

HERE = Path(__file__).parent
source = HERE/'owned_catalog_sdk_results.py'
namespace = {'__name__':'catalog_data_only','__file__':str(source)}
exec(compile(source.read_bytes(),str(source),'exec'),namespace)
api = types.SimpleNamespace(**namespace)
PLAN = json.loads((HERE/'owned_catalog_sdk_plan.json').read_text())
GRAPH = Path('/Users/runner/localdev/finite-sdk-shape/graph')


def fixture():
    records = []
    def test(row, kind):
        ident = 'CurrentCatalogQualificationTests.'+row.get('suite', row['name'])
        if kind == 'function': ident += '/'+row['name']+('/arg' if row['parameterized'] else '/plain')
        payload = dict(kind=kind,id=ident,name=row['name']+('(_:)' if row.get('parameterized') else '()') if kind == 'function' else row['name'],
            sourceLocation=dict(filePath=str(GRAPH/row['source']),fileID='CurrentCatalogQualificationTests/'+Path(row['source']).name,line=row['line']))
        if kind == 'function': payload['isParameterized'] = row['parameterized']
        records.append(dict(kind='test',version='6.3.0',payload=payload));return ident
    suite_ids = [test(r,'suite')for r in PLAN['sdkSuites']]
    functions = [(r,test(r,'function'))for r in PLAN['sdkFunctions']]
    def event(kind, ident=None, messages=None):
        payload=dict(kind=kind,messages=messages or [])
        if ident is not None:payload['testID']=ident
        records.append(dict(kind='event',version='6.3.0',payload=payload))
    event('runStarted')
    for ident in suite_ids:event('testStarted',ident)
    for row,ident in functions:
        event('testStarted',ident)
        if row['parameterized']:
            for arg in PLAN['sdkParameterArguments']:
                text='Test case passing 1 argument action → CatalogCallbackBoundary.'+arg+' to '+row['name']+'(_:) started.'
                event('testCaseStarted',ident,[dict(symbol='default',text=text)])
                event('testCaseEnded',ident)
        event('testEnded',ident)
    for ident in suite_ids:event('testEnded',ident)
    event('runEnded',messages=[dict(symbol='pass',text='Actual shape fixture completed')])
    return records


def raw(records):
    return ('\n'.join(json.dumps(r)for r in records)+'\n').encode()


def result(records):
    return api.event_result(raw(records),PLAN['sdkFunctions'],PLAN['sdkSuites'],PLAN['sdkParameterArguments'],GRAPH)


def xml():
    rows = ''.join('<testcase classname="CurrentCatalogQualificationTests.'+r['suite']+'" name="'+r['name']+('(_:)' if r['parameterized'] else '()')+'"/>'for r in PLAN['sdkFunctions'])
    return ('<testsuites><testsuite>'+rows+'</testsuite></testsuites>').encode()


class SDKOutputCases(unittest.TestCase):
    def test_complete_real_protocol_shape_requires25_not17_case_invocations(self):
        observed=result(fixture())
        self.assertTrue(observed['allPassed']);self.assertEqual(observed['functionCount'],17)
        self.assertEqual(observed['observedInvocations'],25)
        self.assertTrue(api.xunit_result(xml(),PLAN['sdkFunctions'])['allPassed'])

    def test_actual_swift633_enum_shorthand_completes_all_nine_argument_invocations(self):
        # Exact messages retained from actual run38777830237, not a changed
        # product outcome. The original runtime still has its independent issue.
        actions = ['path','closed','optimize','add','preservingAdd','checkpoint','reclaim','close','generation']
        records=fixture();starts=[r for r in records if r['payload']['kind']=='testCaseStarted']
        self.assertEqual(len(starts),len(actions))
        for row,action in zip(starts,actions):
            row['payload']['messages']=[dict(symbol='default',text='Test case passing 1 argument action → .'+action+' to swiftCallbackRefusalsStayContainedAndPreserveOriginalOwner(_:) started.')]
        observed=result(records)
        self.assertTrue(observed['allPassed']);self.assertEqual(observed['observedInvocations'],25)
        self.assertEqual(next(r['arguments']for r in observed['rows']if r['expectedCases']==9),sorted(actions))

    def test_optional_dot_does_not_admit_unknown_empty_double_dot_or_duplicate_action(self):
        for spelling in ['.unknown','.', '..path', '.CatalogCallbackBoundary..path']:
            records=fixture();row=next(r for r in records if r['payload']['kind']=='testCaseStarted')
            row['payload']['messages'][0]['text']='Test case passing 1 argument action → '+spelling+' to swiftCallbackRefusalsStayContainedAndPreserveOriginalOwner(_:) started.'
            with self.assertRaisesRegex(RuntimeError,'sdk_unknown_or_duplicate_argument'):result(records)
        records=fixture();starts=[r for r in records if r['payload']['kind']=='testCaseStarted']
        for row in [starts[0],starts[-1]]:
            row['payload']['messages'][0]['text']='Test case passing 1 argument action → .path to swiftCallbackRefusalsStayContainedAndPreserveOriginalOwner(_:) started.'
        with self.assertRaisesRegex(RuntimeError,'sdk_unknown_or_duplicate_argument'):result(records)

    def test_actual_shorthand_with_failed_run_end_never_passes(self):
        records=fixture()
        for row in records:
            if row['payload']['kind']=='testCaseStarted':
                row['payload']['messages'][0]['text']=row['payload']['messages'][0]['text'].replace('CatalogCallbackBoundary.','.')
        records[-1]['payload']['messages']=[dict(symbol='fail',text='Test run with 15 tests in 3 suites failed after 4.838 seconds with 1 issue.')]
        with self.assertRaisesRegex(RuntimeError,'sdk_run_end_without_pass'):result(records)

    def test_xunit17_rows_cannot_substitute_for_one_missing_parameter_case(self):
        records=fixture();at=next(i for i,r in enumerate(records)if r['payload']['kind']=='testCaseStarted')
        del records[at:at+2]
        self.assertFalse(result(records)['allPassed'])
        self.assertTrue(api.xunit_result(xml(),PLAN['sdkFunctions'])['allPassed'])

    def test_missing_run_end_never_passes_despite_all_function_endings(self):
        self.assertFalse(result(fixture()[:-1])['allPassed'])

    def test_duplicate_parameter_does_not_replace_a_missing_enum_action(self):
        records=fixture();starts=[r for r in records if r['payload']['kind']=='testCaseStarted']
        starts[-1]['payload']['messages']=copy.deepcopy(starts[0]['payload']['messages'])
        with self.assertRaisesRegex(RuntimeError,'sdk_unknown_or_duplicate_argument'):result(records)

    def test_unjoined_parameter_frame_is_not_a_completed_function(self):
        records=fixture();at=next(i for i,r in enumerate(records)if r['payload']['kind']=='testCaseEnded');del records[at]
        with self.assertRaisesRegex(RuntimeError,'sdk_unexpected_or_overlapping_parameter_case'):result(records)

    def test_wrong_source_copy_or_line_refuses_provenance(self):
        for field,value in [('filePath','/Users/runner/localdev/old-source/Other.swift'),('line',1)]:
            records=fixture();row=next(r for r in records if r['kind']=='test'and r['payload']['kind']=='function')
            row['payload']['sourceLocation'][field]=value
            with self.assertRaisesRegex(RuntimeError,'sdk_test_source_provenance'):result(records)

    def test_split_attribute_location_cannot_be_replaced_by_following_function_line(self):
        # The actual prior Swift6.3 ABI selected @Test rather than the next
        # func line. New source has the same split declaration, shifted428/429.
        expected=next(r for r in PLAN['sdkFunctions']if r['parameterized'])
        self.assertEqual(expected['line'],428)
        records=fixture()
        row=next(r for r in records if r['kind']=='test'and r['payload'].get('isParameterized'))
        row['payload']['sourceLocation']['line']=429
        with self.assertRaisesRegex(RuntimeError,'sdk_test_source_provenance'):result(records)

    def test_issue_skip_or_cancellation_cannot_pass_even_with_final_pass_message(self):
        for kind in ['issueRecorded','testSkipped','testCancelled','testCaseCancelled']:
            records=fixture();ident=next(r['payload']['id']for r in records if r['kind']=='test'and r['payload']['kind']=='function')
            records.insert(-1,dict(kind='event',version='6.3.0',payload=dict(kind=kind,testID=ident,messages=[])))
            self.assertFalse(result(records)['allPassed'])

    def test_duplicate_function_record_refuses(self):
        records=fixture();at=next(i for i,r in enumerate(records)if r['kind']=='test'and r['payload']['kind']=='function')
        records.insert(at,copy.deepcopy(records[at]))
        with self.assertRaisesRegex(RuntimeError,'sdk_duplicate_or_late_test_record'):result(records)

    def test_old_or_unknown_abi_versions_refuse(self):
        for version in [0,'6.2.0','6.4.0']:
            records=fixture();records[0]['version']=version
            with self.assertRaisesRegex(RuntimeError,'sdk_stable_event_version'):result(records)

    def test_truncated_json_line_and_duplicate_keys_refuse(self):
        with self.assertRaisesRegex(RuntimeError,'sdk_event_stream_bound_or_incomplete_line'):
            api.event_result(raw(fixture())[:-1],PLAN['sdkFunctions'],PLAN['sdkSuites'],PLAN['sdkParameterArguments'],GRAPH)
        with self.assertRaisesRegex(RuntimeError,'sdk_duplicate_json_key'):
            api.event_result(b'{"version":"6.3.0","version":"6.3.0"}\n',PLAN['sdkFunctions'],PLAN['sdkSuites'],PLAN['sdkParameterArguments'],GRAPH)

    def test_empty_duplicate_failed_and_skipped_xunit_never_pass(self):
        self.assertFalse(api.xunit_result(b'<testsuites/>',PLAN['sdkFunctions'])['allPassed'])
        source=xml();first=source[source.index(b'<testcase'):source.index(b'/>')+2]
        self.assertFalse(api.xunit_result(source.replace(b'</testsuite>',first+b'</testsuite>'),PLAN['sdkFunctions'])['allPassed'])
        for marker in [b'<failure/>',b'<error/>',b'<skipped/>']:
            failed=source.replace(b'/>',b'>'+marker+b'</testcase>',1)
            self.assertFalse(api.xunit_result(failed,PLAN['sdkFunctions'])['allPassed'])

    def test_source_population_is_closed_and_no_function_or_argument_can_disappear(self):
        self.assertEqual(len(PLAN['sdkFunctions']),17);self.assertEqual(len(PLAN['sdkSuites']),3)
        self.assertEqual(sum(r['actualCases']for r in PLAN['sdkFunctions']),25)
        self.assertEqual(set(PLAN['sdkParameterArguments']),{'path','closed','optimize','add','preservingAdd','checkpoint','reclaim','close','generation'})
        self.assertTrue(PLAN['fullSDKRegressionGateStillRequired'])
        self.assertEqual(PLAN['jobs'],2);self.assertEqual(PLAN['workFloorBytes'],12*1024**3)


if __name__=='__main__':unittest.main()
