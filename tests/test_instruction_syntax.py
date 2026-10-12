# SPDX-License-Identifier: MIT
"""Byte acquisition metadata is derived from functional microcode, not opcodes."""
import json
import unittest

from tools.microcode.compile_microcode import ROOT, compile_sources, generate, instruction_syntax


class InstructionSyntaxTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.program = compile_sources({p.name: p.read_text() for p in
                                      (ROOT / 'microcode/source').glob('*.mc')})
        cls.syntax = instruction_syntax(cls.program)

    def test_every_entry_has_source_bound_metadata(self):
        self.assertEqual(set(self.syntax), set(self.program.entries))
        generated = json.loads(generate(self.program)['spk286_microcode_validation.json'])
        self.assertEqual(generated['instruction_syntax'], self.syntax)
        for name, shape in self.syntax.items():
            self.assertLessEqual(shape['trailing_bytes'], 4)
            for pc in shape['acquisition_micro_pc']:
                op = self.program.operations[pc]
                self.assertEqual(op.location.entry, name)
                self.assertTrue(op.operation.startswith(('FETCH_', 'DECODE_')))

    def test_minimal_immediate_is_not_an_opcode_table(self):
        program = compile_sources({'renamed.mc': '''microcode_format 1
instruction RENAMED:
    FETCH_IMM16 -> TMP0
    TMP0 -> DST
    END
'''})
        self.assertEqual(instruction_syntax(program)['RENAMED']['trailing_bytes'], 2)

    def test_literal_form_requirements(self):
        expected = {
            'MOV_R16_IMM16': (False, 2), 'MOV_R8_IMM8': (False, 1),
            'ALU_AX_IMM16': (False, 2), 'ALU_AL_IMM8': (False, 1),
            'ALU_RM16_IMM16': (True, 2), 'ALU_RM16_IMM8S': (True, 1),
            'ALU_RM8_IMM8': (True, 1), 'MOV_RM16_IMM16': (True, 2),
            'MOV_RM8_IMM8': (True, 1), 'ALU_R16_RM16': (True, 0),
            'ALU_RM16_R16': (True, 0), 'INC_DEC_R16': (False, 0),
            'INC_DEC_RM16': (True, 0), 'CALL_FAR_IMM': (False, 4),
            'JMP_FAR_IMM': (False, 4), 'ENTER_FRAME': (False, 3),
            'LOAD_DIRECT16': (False, 2), 'ESC_NO_COPROCESSOR': (True, 0),
            'LOADALL': (False, 0), 'SYSTEM_LOAD_ACCESS': (True, 0),
            'GROUP3_DISPATCH': (True, 0), 'GROUP5_DISPATCH': (True, 0),
            'SYSTEM_GROUP_0F00': (True, 0), 'SYSTEM_GROUP_0F01': (True, 0),
        }
        for name, shape in expected.items():
            with self.subTest(name=name):
                self.assertEqual((self.syntax[name]['modrm'],
                                  self.syntax[name]['trailing_bytes']), shape)
        for name in ('GROUP3_DISPATCH', 'GROUP5_DISPATCH',
                     'SYSTEM_GROUP_0F00', 'SYSTEM_GROUP_0F01'):
            self.assertTrue(self.syntax[name]['dispatch'])
        for name in ('IN_AL_PORT', 'IN_AX_PORT', 'OUT_PORT_AL', 'OUT_PORT_AX',
                     'STRING_INPUT_BYTE', 'STRING_OUTPUT_WORD'):
            self.assertTrue(self.syntax[name]['conditional_port'])
            self.assertEqual(self.syntax[name]['trailing_bytes'], 0)

    def test_regeneration_is_deterministic(self):
        source = {p.name: p.read_text() for p in (ROOT / 'microcode/source').glob('*.mc')}
        self.assertEqual(generate(self.program), generate(compile_sources(dict(reversed(list(source.items()))))))


if __name__ == '__main__':
    unittest.main()
