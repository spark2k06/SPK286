# SPDX-License-Identifier: MIT
"""Stack-frame lengths and unchanged invalid-BOUND generator tails."""
import unittest
from tests.test_singlestep_byte_prefix import vector
from tools.singlestep import SingleStepCase
from tools.run_singlestep import prepare_case,scope_exclusion,SingleStepRunnerError


class StackFrameAdmissionTests(unittest.TestCase):
    def test_frame_lengths_and_original_bound_tail_bytes(self):
        encodings=[([op],f'{op:02X}',None) for op in (0x60,0x61,0xc9)]
        encodings += [([0xc8,1,0x80,n],'C8',None) for n in (0,1,31,32,255)]
        encodings += [([0x62,6,0,0x10],'62',5)]
        encodings += [([0x62,0xc0+i,*range(n)],'62',6) for i in range(64) for n in range(7)]
        for encoding,name,fault in encodings:
            for prefix in ([],[0x26],[0xf3,0x3e]):
                code=prefix+encoding+[0xf4];case=SingleStepCase.from_mapping(vector(code,name,fault))
                self.assertIsNone(scope_exclusion(case,name,True,True))
                prepared=prepare_case(case,name,True,True)
                self.assertEqual(prepared.source.instruction_bytes,tuple(code))
                self.assertEqual(prepared.initial_ram,prepared.expected_ram)
                self.assertEqual(len(prepared.initial_ram),len(code))

    def test_bad_lengths_or_missing_bound_fault_are_rejected(self):
        cases=[('C8',[0xc8,0,0,0xf4],None),('C8',[0xc8,0,0,0,0,0xf4],None),
               ('60',[0x60,0,0xf4],None),('62',[0x62,0xc0,0xf4],None),
               ('62',[0x62,0xc0,0,0xf4],13),('62',[0x62,6,0,0x10,0,0xf4],None)]
        for name,code,fault in cases:
            with self.subTest(code=code,fault=fault),self.assertRaises(SingleStepRunnerError):
                prepare_case(SingleStepCase.from_mapping(vector(code,name,fault)),name,True,True)
