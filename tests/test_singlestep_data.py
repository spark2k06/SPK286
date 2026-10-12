# SPDX-License-Identifier: MIT
"""Exact data-transfer encodings, memory preservation and gate failure propagation."""
import unittest
from tests.test_singlestep_byte_prefix import vector
from tools.singlestep import SingleStepCase
from tools.run_singlestep import prepare_case, scope_exclusion, SingleStepRunnerError


class DataAdmissionTests(unittest.TestCase):
    def test_all_data_forms_preserve_source_bytes_and_ram(self):
        forms = [(f'{op:02X}', [op, 0xf4]) for op in (*range(0x90, 0x98), 0xd7)]
        forms += [(f'{op:02X}', [op, 0xff, 0xff, 0xf4]) for op in range(0xa0, 0xa4)]
        forms += [(f'{op:02X}', [op, 0x46, 0x80, 0xf4]) for op in (0x86, 0x87, 0x8d)]
        for name, code in forms:
            for prefix in ([], [0xf2, 0x36], [0xf0, 0x3e]):
                with self.subTest(opcode=name, prefix=prefix):
                    case = SingleStepCase.from_mapping(vector(prefix+code, name))
                    self.assertIsNone(scope_exclusion(case, name, True, True))
                    prepared = prepare_case(case, name, True, True)
                    self.assertEqual(prepared.source.instruction_bytes, tuple(prefix+code))
                    self.assertEqual(prepared.initial_ram, prepared.expected_ram)
                    self.assertEqual(len(prepared.initial_ram), len(prefix+code))

    def test_malformed_direct_and_modrm_lengths_fail(self):
        for name, code in [('90', [0x90, 0x90, 0xf4]), ('D7', [0xd7, 1, 0xf4]),
                           ('A0', [0xa0, 1, 0xf4]), ('A3', [0xa3, 1, 2, 3, 0xf4]),
                           ('87', [0x87, 6, 1, 0xf4]), ('8D', [0x8d, 0xc0, 1, 0xf4])]:
            with self.subTest(opcode=name), self.assertRaises(SingleStepRunnerError):
                prepare_case(SingleStepCase.from_mapping(vector(code, name)), name, True, True)
