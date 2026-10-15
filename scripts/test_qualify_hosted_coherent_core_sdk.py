"""Pure parser/population cases; never a compiler, process owner or product."""
import json
from pathlib import Path
import types
import unittest

HERE = Path(__file__).parent
source = HERE/'qualify_hosted_coherent_core_sdk.py'
namespace = {'__name__':'coherent_data_only','__file__':str(source)}
exec(compile(source.read_bytes(),str(source),'exec'),namespace)
api = types.SimpleNamespace(**namespace)


class NativeOutputCases(unittest.TestCase):
    def test_real_listing_prefix_and_comment(self):
        self.assertEqual(api.inventory(b'Running main() from gtest_main.cc\nA.\n  One\n  Two # typed note\n'), ['A.One','A.Two'])

    def test_duplicate_listing_refuses(self):
        with self.assertRaisesRegex(RuntimeError,'inventory_duplicate_or_bound'):
            api.inventory(b'A.\n  One\n  One\n')

    def test_case_without_suite_refuses(self):
        with self.assertRaisesRegex(RuntimeError,'inventory_suite_missing'):
            api.inventory(b'  One\n')

    def test_oversized_listing_refuses_before_parse(self):
        with self.assertRaisesRegex(RuntimeError,'inventory_bound'):
            api.inventory(b'x'*(16*1024**2+1))

    def test_exact_pass_and_missing_case_differ(self):
        raw=b'<testsuites><testsuite><testcase classname="A" name="One" status="run" result="completed"/></testsuite></testsuites>'
        self.assertTrue(api.native_result(raw,['A.One'])['allPassed'])
        self.assertFalse(api.native_result(raw,['A.One','A.Two'])['allPassed'])

    def test_duplicates_cannot_replace_a_missing_name(self):
        raw=b'<testsuites><testcase classname="A" name="One" status="run" result="completed"/><testcase classname="A" name="One" status="run" result="completed"/></testsuites>'
        self.assertFalse(api.native_result(raw,['A.One','A.Two'])['exactNames'])

    def test_failure_skip_error_and_notrun_never_pass(self):
        for body in [b'<failure/>',b'<skipped/>',b'<error/>']:
            raw=b'<testsuites><testcase classname="A" name="One" status="run" result="completed">'+body+b'</testcase></testsuites>'
            self.assertFalse(api.native_result(raw,['A.One'])['allPassed'])
        raw=b'<testsuites><testcase classname="A" name="One" status="notrun" result="suppressed"/></testsuites>'
        self.assertFalse(api.native_result(raw,['A.One'])['allPassed'])

    def test_entity_declaration_refuses(self):
        with self.assertRaisesRegex(RuntimeError,'xml_bound_or_entity'):
            api.native_result(b'<!DOCTYPE test><testsuites/>',[])

    def test_selected_population_preserves_all_six_known_failures(self):
        plan=json.loads((HERE/'coherent_core_sdk_plan.json').read_text())
        names=plan['nativeNames']
        self.assertEqual(len(names),661)
        self.assertEqual(len(set(names)),661)
        self.assertEqual(len(plan['new21Names']),21)
        self.assertEqual(len(plan['knownFirst640FailedNames']),6)
        self.assertTrue(set(plan['knownFirst640FailedNames'])<=set(names))
        self.assertNotIn(plan['genuineChildRole']['dispatcher'],names)
        self.assertIn(plan['genuineChildRole']['mandatoryParent'],names)


if __name__ == '__main__':
    unittest.main()
