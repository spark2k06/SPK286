# SPDX-License-Identifier: MIT
"""No-NPX physical admission preserves capture identities and comparison state."""
import unittest
from tests.test_singlestep_byte_prefix import vector
from tools.singlestep import SingleStepCase
from tools.run_singlestep import NPX_OPCODES, SUPPORTED_OPCODES, prepare_case, scope_exclusion, SingleStepRunnerError


class NpxAdmissionTests(unittest.TestCase):
    def test_wait_and_esc_lengths_and_original_bytes(self):
        for opcode, code in [('9B',[0x9B,0xF4]), ('D8',[0xD8,0xC0,0xF4]),
                             ('D8',[0xD8,0x06,0xFF,0xFF,0xF4]), ('D8',[0xD8,0x46,0x7F,0xF4])]:
            for prefix in ([], [0x2E], [0xF3,0x36]):
                with self.subTest(opcode=opcode, prefix=prefix):
                    case = SingleStepCase.from_mapping(vector(prefix+code, opcode))
                    prepared = prepare_case(case, opcode, True, True)
                    self.assertEqual(prepared.source.instruction_bytes, tuple(prefix+code))
                    self.assertEqual(prepared.initial_ram, prepared.expected_ram)
                    self.assertEqual(prepared.expected_retired, 1)
                    self.assertEqual(prepared.expected_event, 256)

    def test_bad_lengths_fail_closed(self):
        for opcode, code in [('9B',[0x9B,0x90,0xF4]), ('D8',[0xD8,0xF4]),
                             ('D8',[0xD8,0x06,0xFF,0xF4]), ('D8',[0xD8,0xC0,0,0xF4])]:
            with self.subTest(opcode=opcode), self.assertRaises(SingleStepRunnerError):
                prepare_case(SingleStepCase.from_mapping(vector(code, opcode)), opcode, True, True)

    def test_npx_is_explicitly_admitted_and_prefix_policy_is_counted(self):
        self.assertTrue(set(NPX_OPCODES) <= set(SUPPORTED_OPCODES))
        case = SingleStepCase.from_mapping(vector([0x2E,0x9B,0xF4], '9B'))
        self.assertEqual(scope_exclusion(case,'9B'), 'unsupported_prefix')
        self.assertIsNone(scope_exclusion(case,'9B',True,True))
