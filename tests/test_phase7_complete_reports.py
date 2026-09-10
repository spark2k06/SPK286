import hashlib,json,unittest
from tools.phase7_complete_reports import validate_report,summarize
from pathlib import Path
import tempfile

class CompleteReportTests(unittest.TestCase):
    def fixture(self):
        form={'opcode':'F6.7','case_count':2,'git_blob':'a'*40}
        identities=[dict(index=i,hash=str(i+1)*40,category='new_form') for i in range(2)]
        raw=json.dumps(identities).encode()
        report=dict(opcode='F6.7',discovered=2,revoked=0,prefix_skipped=0,exception_skipped=0,selection_skipped=0,selected=2,executed=2,passed=2,failed=0,source_git_blob='a'*40,identity_sha256=hashlib.sha256(raw).hexdigest())
        return form,report,identities,raw
    def test_execution_and_source_failures_cannot_pass(self):
        form,report,ids,raw=self.fixture();self.assertEqual(validate_report(report,form,raw,{},set())[0],2)
        for key,value in [('failed',1),('passed',1),('selected',1),('prefix_skipped',1),('revoked',1),('executed',True),('source_git_blob','b'*40)]:
            with self.subTest(key=key),self.assertRaises(ValueError):validate_report(dict(report,**{key:value}),form,raw,{},set())
    def test_duplicate_or_forged_identities_cannot_pass(self):
        form,report,ids,raw=self.fixture()
        for altered in ([ids[0],ids[0]],[dict(ids[0],index=2),ids[1]],[dict(ids[0],category='legacy'),ids[1]]):
            data=json.dumps(altered).encode();changed=dict(report,identity_sha256=hashlib.sha256(data).hexdigest())
            with self.assertRaises(ValueError):validate_report(changed,form,data,{},set())
        with self.assertRaises(ValueError):validate_report(report,form,raw,{},set([ids[0]['hash']]))
    def test_empty_cohort_is_a_failure(self):
        with tempfile.TemporaryDirectory() as d,self.assertRaisesRegex(ValueError,'missing/extra'):
            summarize(Path(d),Path(d))

    def test_e7_evaluable_population_cannot_be_reduced(self):
        from tools.phase7_capture_admission import CAPTURE
        form={'opcode':'E7','case_count':5000,'git_blob':'a'*40}
        ids=[dict(index=i,hash=f'{i+1:040x}',category='new_form') for i in range(5000) if i!=1100]
        raw=json.dumps(ids).encode()
        report=dict(opcode='E7',discovered=5000,revoked=0,prefix_skipped=0,exception_skipped=0,
                    selection_skipped=0,selected=4999,executed=4999,passed=4999,failed=0,
                    source_git_blob='a'*40,identity_sha256=hashlib.sha256(raw).hexdigest(),not_evaluable=[CAPTURE])
        self.assertEqual(validate_report(report,form,raw,{},set())[0],4999)
        for altered in (ids[:-1],ids[:-1]+[dict(ids[-1],index=1100)]):
            changed_raw=json.dumps(altered).encode()
            changed=dict(report,identity_sha256=hashlib.sha256(changed_raw).hexdigest())
            with self.assertRaisesRegex(ValueError,'incomplete'):
                validate_report(changed,form,changed_raw,{},set())
        for field,value in [('not_evaluable',[]),('not_evaluable',[CAPTURE,CAPTURE]),('failed',1),('passed',4998)]:
            with self.assertRaises(ValueError):validate_report(dict(report,**{field:value}),form,raw,{},set())
