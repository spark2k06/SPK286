# SPDX-License-Identifier: MIT
"""New forms retain strict lengths, masks, group admission and HLT boundary."""
from copy import deepcopy
import unittest
from tools.run_singlestep import ALU_OPCODES, prepare_case, scope_exclusion, SingleStepRunnerError
from tools.singlestep import SingleStepCase
from test_singlestep_runner import REGS


def mapping(opcode, modrm=0xc0):
    byte = int(opcode.split('.')[0], 16)
    group = int(opcode[-1]) if '.' in opcode else None
    accumulator = byte < 64 and byte % 8 == 5
    data = [byte]
    if not accumulator:
        if group is not None:
            modrm = (modrm & 0xc7) | group*8
        data.append(modrm)
        mode, rm = modrm >> 6, modrm & 7
        data += [0x80] * (1 if mode == 1 else 2 if mode == 2 or mode == 0 and rm == 6 else 0)
    data += [0xff, 0x7f] if accumulator or byte == 0x81 else [0x80] if byte == 0x83 else []
    data.append(0xf4)
    return {'idx': 0, 'name': 'ALU admission', 'bytes': data,
            'initial': {'regs': dict(REGS), 'ram': [[0x11200+i, b] for i,b in enumerate(data)]},
            'final': {'regs': {'ip': 0x1200+len(data)}, 'reg_masks': {'flags': 0xf7ee}}}


class AluAdmissionTests(unittest.TestCase):
    def test_all_forms_and_modrm_lengths(self):
        for opcode in ALU_OPCODES:
            for modrm in range(256):
                value = mapping(opcode, modrm)
                case = SingleStepCase.from_mapping(value)
                self.assertIsNone(scope_exclusion(case, opcode))
                prepared = prepare_case(case, opcode)
                self.assertEqual(prepared.expected_masks[-1], 0xf7ee)
                self.assertEqual(prepared.expected_regs[12], 0x1200+len(value['bytes'])-1)
                for extra in (-1, 1):
                    damaged = deepcopy(value)
                    damaged['bytes'] = value['bytes'][:-2]+[0xf4] if extra == -1 else value['bytes'][:-1]+[0,0xf4]
                    with self.assertRaises(SingleStepRunnerError):
                        prepare_case(SingleStepCase.from_mapping(damaged), opcode)

    def test_group_mismatch_and_unsupported_width_are_errors(self):
        for opcode in ('81.0', '83.7'):
            value = mapping(opcode); value['bytes'][1] ^= 8
            for fn in (scope_exclusion, prepare_case):
                with self.assertRaisesRegex(SingleStepRunnerError, 'group extension'):
                    fn(SingleStepCase.from_mapping(value), opcode)
            value = mapping(opcode); value['bytes'][0] = 0x80
            with self.assertRaises(SingleStepRunnerError):
                scope_exclusion(SingleStepCase.from_mapping(value), opcode)

    def test_prefix_and_exception_exclusions(self):
        for opcode in ALU_OPCODES:
            value = mapping(opcode)
            value['exception'] = {'number': 13, 'flag_address': 0x20000}
            self.assertEqual(scope_exclusion(SingleStepCase.from_mapping(value), opcode), 'exception_delivery')
            value['bytes'].insert(0, 0xf0)
            self.assertEqual(scope_exclusion(SingleStepCase.from_mapping(value), opcode), 'unsupported_prefix')
