"""String admission preserves prefixes, sparse effects and exact fault identity."""
import unittest
from tests.test_singlestep_byte_prefix import vector
from tools.singlestep import SingleStepCase
from tools.run_singlestep import STRING_OPCODES,prepare_case,scope_exclusion,SingleStepRunnerError

class StringAdmissionTests(unittest.TestCase):
    def test_all_forms_prefixes_and_faults_preserve_original_values(self):
        for op in STRING_OPCODES:
            for prefix in ([],[0xf2],[0xf3,0x36],[0xf0,0x2e,0xf2,0x3e]):
                for fault in (None,13):
                    raw=vector(prefix+[int(op,16),0xf4],op,fault)
                    raw['final']['regs'].update(cx=0xffff,si=1,di=0xfffd)
                    c=SingleStepCase.from_mapping(raw);v=prepare_case(c,op,True,True)
                    self.assertIsNone(scope_exclusion(c,op,True,True));self.assertEqual(v.source.instruction_bytes,tuple(raw['bytes']))
                    self.assertEqual(v.initial_ram,v.expected_ram);self.assertEqual(v.expected_regs[2],0xffff);self.assertEqual(v.expected_regs[10:12],(1,0xfffd))

    def test_wrong_length_file_or_fault_identity_is_rejected(self):
        for op in STRING_OPCODES:
            for code,fault in (([int(op,16),0,0xf4],None),([0xf3,int(op,16)^1,0xf4],None),([int(op,16),0xf4],6),([int(op,16),0xf4],0)):
                with self.subTest(op=op,code=code,fault=fault),self.assertRaises(SingleStepRunnerError):
                    prepare_case(SingleStepCase.from_mapping(vector(code,op,fault)),op,True,True)
