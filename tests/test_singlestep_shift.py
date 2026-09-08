"""All shift forms retain exact prefixes/bytes and reject malformed encodings."""
import unittest
from tests.test_singlestep_byte_prefix import vector
from tools.singlestep import SingleStepCase
from tools.run_singlestep import prepare_case, scope_exclusion, SingleStepRunnerError


class ShiftAdmissionTests(unittest.TestCase):
    def test_all_42_forms_preserve_instruction_and_memory(self):
        for op in (0xc0, 0xc1, 0xd0, 0xd1, 0xd2, 0xd3):
            for group in (0, 1, 2, 3, 4, 5, 7):
                for prefix in ([], [0xf2, 0x36], [0xf0, 0x3e]):
                    name = f'{op:02X}.{group}'
                    code = prefix+[op, 0x46+group*8, 0x80]+([0xff] if op < 0xd0 else [])+[0xf4]
                    with self.subTest(opcode=name, prefix=prefix):
                        case = SingleStepCase.from_mapping(vector(code, name))
                        self.assertIsNone(scope_exclusion(case, name, True, True))
                        prepared = prepare_case(case, name, True, True)
                        self.assertEqual(prepared.source.instruction_bytes, tuple(code))
                        self.assertEqual(prepared.initial_ram, prepared.expected_ram)
                        self.assertEqual(len(prepared.initial_ram), len(code))

    def test_bad_count_displacement_and_group_are_errors(self):
        for name, code in [('C0.0', [0xc0, 0xc0, 0xf4]), ('C1.7', [0xc1, 0xff, 1, 2, 0xf4]),
                           ('D2.4', [0xd2, 0xe6, 0x10, 0xf4]), ('D3.3', [0xd3, 0xde, 1, 0xf4]),
                           ('C0.4', [0xc0, 0xf0, 1, 0xf4])]:
            with self.subTest(opcode=name), self.assertRaises(SingleStepRunnerError):
                prepare_case(SingleStepCase.from_mapping(vector(code, name)), name, True, True)
