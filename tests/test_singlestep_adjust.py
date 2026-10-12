# SPDX-License-Identifier: MIT
"""Exact radix encodings, explicit fault admission and failing gate propagation."""
import unittest
from tests.test_singlestep_byte_prefix import vector
from tools.singlestep import SingleStepCase
from tools.run_singlestep import prepare_case, scope_exclusion, SingleStepRunnerError


class AdjustAdmissionTests(unittest.TestCase):
    def test_adjust_bytes_and_every_radix_are_preserved(self):
        for op in (0x27,0x2f,0x37,0x3f,0xd4,0xd5):
            name=f'{op:02X}'
            for radix in range(256) if op>=0xd4 else (0,):
                for prefix in ([],[0x26],[0xf2,0x36],[0xf3,0x3e]):
                    code=prefix+[op]+([radix] if op>=0xd4 else [])+[0xf4]
                    case=SingleStepCase.from_mapping(vector(code,name))
                    self.assertIsNone(scope_exclusion(case,name,True,True))
                    prepared=prepare_case(case,name,True,True)
                    self.assertEqual(prepared.source.instruction_bytes,tuple(code))
                    self.assertEqual(prepared.initial_ram,prepared.expected_ram)
                    self.assertEqual(len(prepared.initial_ram),len(code))

    def test_adjust_lengths_and_fault_ownership_fail_closed(self):
        for name,code,fault in [('D4',[0xd4,0xf4],None),('D5',[0xd5,0,1,0xf4],None),
                              ('27',[0x27,1,0xf4],None),('37',[0x3f,0xf4],None),
                              ('D5',[0xd5,0,0xf4],0),('27',[0x27,0xf4],0)]:
            with self.subTest(code=code,fault=fault),self.assertRaises(SingleStepRunnerError):
                prepare_case(SingleStepCase.from_mapping(vector(code,name,fault)),name,True,True)
        code=[0xf3,0x36,0xd4,0,0xf4]
        prepared=prepare_case(SingleStepCase.from_mapping(vector(code,'D4',0)),'D4',True,True)
        self.assertEqual((prepared.expected_event,prepared.expected_retired),(0,0))
        self.assertEqual(prepared.source.instruction_bytes,tuple(code))
