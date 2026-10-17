"""Fast adversarial settlement/reference contract checks; no store or provider."""
from pathlib import Path
import sys,unittest,uuid,copy,tempfile
from residual_test_support import runtime,TEMP_ROOT
P=runtime('residual_publication')

def identifier(index):return str(uuid.UUID(int=index,version=4))

class ResidualPublicationContractTests(unittest.TestCase):
    def summary(self):return {'memory_ids':[identifier(i) for i in range(1,6)],'preserved_legacy_memory_ids':[identifier(6)]}
    def test_exact_comparison_supports_lists_scalars_and_strict_json_types(self):
        for value in ([identifier(1)], [], None, False, 1, 'value', {'nested':[True,1]}):
            self.assertTrue(P.same(value,copy.deepcopy(value)))
        for a,b in ((True,1),(False,0),([True],[1]),(None,{}),([],{}),([1,2],[2,1])):
            self.assertFalse(P.same(a,b))
    def test_valid_completed_receipt_metadata_uses_only_bounded_fixed_files(self):
        parent=TEMP_ROOT;parent.mkdir(exist_ok=True,mode=0o700)
        with tempfile.TemporaryDirectory(prefix='passive-receipt-',dir=parent) as directory:
            root=Path(directory);sid='019b7a00-0000-7123-8000-000000000071'
            run_id='20261017T000000Z-'+('a'*32);old_run='20261016T000000Z-'+('b'*32)
            reference={'version':1,'id':identifier(7),'legacy_run_id':old_run,'run_id':run_id,
                'manifest_sha256':'1'*64,'context_sha256':'2'*64,'review_sha256':'3'*64,
                'settlement_sha256':'4'*64,'interval':{'start_offset':1,'end_offset':2,
                'interval_sha256':'5'*64,'excerpt_sha256':'6'*64},
                'preserved_memory_ids':[identifier(6)],'new_memory_ids':[identifier(i) for i in range(1,6)]}
            settled={'version':1,'kind':'reviewed_residual_settlement',
                **{key:reference[key] for key in ('run_id','manifest_sha256','context_sha256','review_sha256',
                                                'preserved_memory_ids','new_memory_ids')},
                'applied_write_count':5,'unchanged_write_count':0,'provider_invoked':False,
                'successful_coverage':False,'historical_execution_sealed':False,
                'historical_run_status':'failed','source_binding_grade':'current_bounded_reconstruction'}
            reference['settlement_sha256']=P.J.sha256(P.J.durable.encode(settled))
            publication={'ticket_id':reference['id'],'ticket_sha256':'7'*64}
            completion={'version':1,**publication,'published_sha256':'8'*64,'ack_intent_sha256':'9'*64,
                'outcome':{'result':P.RESULT,'queue_action':'keep','pause_reason':None},
                'disposition':'original','pending':{'retained':True}}
            receipt={'version':1,'kind':'legacy_residual_interval_reconciliation','status':'reconciled_with_residuals',
                'session_id':sid,'request_id':'synthetic-request','reference':reference,'publication':publication,
                'completion_sha256':P.J.sha256(P.J.durable.encode(completion)),
                'historical_run_status':'failed','historical_execution_sealed':False,
                'source_binding_grade':'current_bounded_reconstruction','provider_invoked':False,
                'applied_write_count':5,'unchanged_write_count':0}
            run=root/'runs'/run_id
            files={run/'residual-settlement.json':settled,run/'residual-publication-reference.json':publication,
                run/'residual-receipt.json':receipt,
                root/'publications'/sid/'records'/reference['id']/'completion.json':completion}
            for path,value in files.items():
                path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
                P.J.durable._new(path,P.J.durable.encode(value))
            self.assertEqual(P._receipt_metadata(root,sid,reference),receipt)
            self.assertEqual(set(root.rglob('*.json')),set(files))
    def test_exactly_five_distinct_new_ids_and_one_preserved_id(self):
        self.assertIs(P._qualified_memory_ids(self.summary()),True)
    def test_collapsed_and_duplicate_native_receipt_ids_cannot_qualify(self):
        for ids in ([identifier(i) for i in range(1,5)], [identifier(i) for i in (1,2,3,4,4)],
                    [identifier(i) for i in (1,2,3,4,6)]):
            with self.subTest(ids=len(ids)),self.assertRaises(ValueError):
                P._qualified_memory_ids({**self.summary(),'memory_ids':ids})
    def test_case_variant_of_preserved_id_is_still_overlap(self):
        selected=self.summary();selected['preserved_legacy_memory_ids']=[selected['memory_ids'][0].upper()]
        with self.assertRaises(ValueError):P._qualified_memory_ids(selected)
    def test_draft_to_final_view_only_fills_exact_plan_digest(self):
        draft={'prepared_sha256':None,'publication':{'version':1,'fixed':'exact bytes'}}
        expected={**draft,'prepared_sha256':P.J.sha256(P.J.durable.encode(draft['publication']))}
        self.assertEqual(P._publication_view(draft,'journal_prepare'),expected)
        self.assertEqual(P._publication_view(expected,'before_ticket'),expected)
        self.assertIsNone(draft['prepared_sha256'])
    def test_missing_or_wrong_final_plan_digest_is_refused(self):
        draft={'prepared_sha256':None,'publication':{'version':1}}
        for value,phase in ((draft,'before_ticket'),({**draft,'prepared_sha256':'0'*64},'journal_prepare'),
                            ({**draft,'prepared_sha256':'0'*64},'completion')):
            with self.subTest(phase=phase),self.assertRaises(ValueError):P._publication_view(value,phase)
    def test_null_or_missing_final_reference_remains_discoverable(self):
        # No filesystem access is needed for the typed reference boundary.
        for value in (None,{}, {'version':True}, {'version':1}):
            with self.subTest(value=value),self.assertRaises((ValueError,TypeError,KeyError)):
                P._state_reference(value)

if __name__=='__main__':unittest.main()
