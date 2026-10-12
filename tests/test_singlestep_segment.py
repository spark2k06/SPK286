# SPDX-License-Identifier: MIT
"""Segment encoding, original-memory admission and failing gate propagation."""
import unittest
from tests.test_singlestep_byte_prefix import vector
from tools.singlestep import SingleStepCase
from tools.run_singlestep import prepare_case,scope_exclusion,SingleStepRunnerError


class SegmentAdmissionTests(unittest.TestCase):
    def test_all_segment_forms_preserve_original_bytes_and_memory(self):
        encodings=[[v] for v in (6,7,14,22,23,30,31)]
        encodings += [[op,mode*64+reg*8+6]+([0x80] if mode==1 else [1,0x10] if mode in (0,2) else [])
                      for op in (0x8c,0x8e) for mode in range(4) for reg in range(8)]
        for encoding in encodings:
            op=encoding[0];name=f'{op:02X}'
            invalid=op in (0x8c,0x8e) and (encoding[1]>>3&7)>3 or op==0x8e and (encoding[1]>>3&7)==1
            for prefix in ([],[0x26],[0xf3,0x36],[0x2e,0x3e]):
                code=prefix+encoding+[0xf4];case=SingleStepCase.from_mapping(vector(code,name,6 if invalid else None))
                self.assertIsNone(scope_exclusion(case,name,True,True));prepared=prepare_case(case,name,True,True)
                self.assertEqual(prepared.source.instruction_bytes,tuple(code))
                self.assertEqual(prepared.initial_ram,prepared.expected_ram)
                self.assertEqual(len(prepared.initial_ram),len(code))

    def test_missing_or_extra_segment_operand_bytes_are_rejected(self):
        for name,code in [('06',[6,0,0xf4]),('17',[0x17,0,0xf4]),('8C',[0x8c,6,1,0xf4]),
                          ('8E',[0x8e,0xd8,0,0xf4]),('8E',[0x8c,0xd8,0xf4])]:
            with self.subTest(code=code),self.assertRaises(SingleStepRunnerError):
                prepare_case(SingleStepCase.from_mapping(vector(code,name)),name,True,True)
