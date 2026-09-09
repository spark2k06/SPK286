"""Only the pre-existing pinned upstream ENTER revocation is excluded."""
import hashlib
import json
import unittest
from tools.phase7_stack_frame_reports import validate_capture, UPSTREAM_REVOKED


class StackFrameReportTests(unittest.TestCase):
    def fixture(self):
        form={'case_count':5000,'git_blob':'pinned-source'}
        records=[dict(index=i,hash=f'{i:040x}',category='new_form') for i in range(5000) if i not in UPSTREAM_REVOKED['C8']]
        report=dict(opcode='C8',discovered=5000,revoked=1,prefix_skipped=0,exception_skipped=0,selection_skipped=0,selected=4999,executed=4999,passed=4999,failed=0,source_git_blob='pinned-source')
        return form,records,report

    def check_records(self,form,records,report):
        raw=json.dumps(records).encode();report['identity_sha256']=hashlib.sha256(raw).hexdigest()
        return validate_capture(report,'C8',form,raw,set())

    def test_exact_unrevoked_inventory_includes_last_source_index(self):
        self.assertEqual(self.check_records(*self.fixture()),4999)

    def test_no_extra_skip_failure_or_changed_source_can_pass(self):
        for field,value in [('revoked',2),('exception_skipped',1),('selected',4998),('passed',4998),('failed',1),('source_git_blob','different')]:
            form,records,report=self.fixture();report[field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):self.check_records(form,records,report)

    def test_replacing_an_unrevoked_record_with_revoked_or_duplicate_is_rejected(self):
        for field,value in [('index',904),('index',0),('hash',UPSTREAM_REVOKED['C8'][904]),('hash',f'{0:040x}')]:
            form,records,report=self.fixture();records[-1][field]=value
            with self.subTest(field=field,value=value),self.assertRaises(ValueError):self.check_records(form,records,report)
