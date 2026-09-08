"""Scalar admission is strict about instruction bytes, widths and group extensions."""
import unittest
from tests.test_singlestep_byte_prefix import vector
from tools.singlestep import SingleStepCase
from tools.run_singlestep import prepare_case, scope_exclusion, SingleStepRunnerError


class ScalarAdmissionTests(unittest.TestCase):
    def test_scalar_forms_keep_all_bytes_and_memory(self):
        forms = [('84',[0x84,0xc4,0xf4]), ('85',[0x85,0x06,0xfe,0xff,0xf4]),
                 ('A8',[0xa8,0x80,0xf4]), ('A9',[0xa9,0x80,0x7f,0xf4]),
                 ('F6.0',[0xf6,0xc4,0xff,0xf4]), ('F7.0',[0xf7,0x46,0x80,0xff,0x7f,0xf4])]
        forms += [(f'{op:02X}',[op,0xf4]) for op in (*range(0x40,0x50),0x98,0x99,0x9e,0x9f,0xf5,0xf8,0xf9,0xfc,0xfd)]
        for opcode, code in forms:
            for prefix in ([],[0xf2,0x36],[0xf3,0x3e]):
                with self.subTest(opcode=opcode,prefix=prefix):
                    case = SingleStepCase.from_mapping(vector(prefix+code,opcode))
                    self.assertIsNone(scope_exclusion(case,opcode,True,True))
                    result = prepare_case(case,opcode,True,True)
                    self.assertEqual(result.source.instruction_bytes,tuple(prefix+code))
                    self.assertEqual(result.initial_ram,result.expected_ram)
                    self.assertEqual(len(result.initial_ram),len(prefix+code))

    def test_scalar_length_and_group_mismatches_are_errors(self):
        forms = [('40',[0x40,0x90,0xf4]), ('A8',[0xa8,1,2,0xf4]),
                 ('A9',[0xa9,1,0xf4]), ('84',[0x84,0x06,0xff,0xf4]),
                 ('F6.0',[0xf6,0xd0,1,0xf4]), ('F7.0',[0xf7,0xc0,1,0xf4])]
        for opcode, code in forms:
            with self.subTest(opcode=opcode), self.assertRaises(SingleStepRunnerError):
                prepare_case(SingleStepCase.from_mapping(vector(code,opcode)),opcode,True,True)
