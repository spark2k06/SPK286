# SPDX-License-Identifier: MIT
"""Independent schedule contract for the eight register-direct early exits."""
import json
import unittest

from tools.microcode.compile_microcode import ROOT, CompileError, compile_sources, encode, generate
from tools.microcode.audit_microcode import canonical_source, read_generated_words


# Literal mapping, independent of the compiler's opcode allocation.
REPLACEMENTS = {
    'ALU_RM16_R16': (173, 4), 'ALU_R16_RM16': (174, 4),
    'ALU_RM8_R8': (175, 4), 'ALU_R8_RM8': (176, 4),
    'MOV_RM16_R16': (177, 4), 'MOV_R16_RM16': (178, 4),
    'MOV_RM8_R8': (179, 4), 'MOV_R8_RM8': (180, 4),
    'NOT_RM16': (190, 4), 'NOT_RM8': (191, 4),
    'NEG_RM16': (190, 4), 'NEG_RM8': (191, 4),
    'INC_DEC_RM16': (190, 4), 'INC_DEC_RM8': (191, 4),
    'INC_DEC_R16': (192, 13),
}
SOURCE = '''microcode_format 22
instruction ADD_OR_MEMORY:
    DECODE_ALU_RM16_REG16
    READ_RM16 -> TMP0
    READ_REG16 -> TMP1
    ALU DECODED TMP0, TMP1 -> TMP2 FLAGS_DECODED
    TMP2 -> RM16 IF_WRITE
    COMMIT_FLAGS
    END
'''


class RegisterExecutionMicrocodeTests(unittest.TestCase):
    def test_register_decode_controls_change(self):
        baseline = json.loads((ROOT / 'tests/fixtures/microcode_phase9_salc.json').read_text())
        active = json.loads((ROOT / 'tests/fixtures/microcode_register_execution.json').read_text())
        expected = baseline['words'].copy()
        for entry, (code, old_code) in REPLACEMENTS.items():
            address = baseline['entries'][entry]
            self.assertEqual(expected[address], old_code)
            expected[address] = code
        sources = {'format22.mc': canonical_source(active['words'], active['entries'],
                                                  active['labels'], {int(k): v for k, v in active['branch_targets'].items()})}
        program = compile_sources(sources)
        artifacts = generate(program)
        words = read_generated_words(artifacts['spk286_microcode_pkg.sv'],
                                     artifacts['spk286_microcode_rom.sv'])
        self.assertEqual(list(words), expected)
        self.assertEqual(active['words'], expected)
        self.assertEqual(program.entries, baseline['entries'])
        self.assertEqual(program.labels, baseline['labels'])
        self.assertEqual({str(k): v for k, v in program.branch_targets.items()}, baseline['branch_targets'])
        self.assertEqual((program.format_version, program.word_width), (22, 8))
        rebuilt = compile_sources({'canonical.mc': canonical_source(
            words, program.entries, program.labels, program.branch_targets)})
        self.assertEqual([encode(op) for op in rebuilt.operations], expected)

    def test_register_and_memory_paths_must_agree(self):
        mutations = (
            ('format 22', 'format 21'),
            ('DECODE_ALU_RM16_REG16', 'DECODE_ALU_REG16_RM16'),
            ('READ_RM16 -> TMP0', 'READ_RM16 -> TMP1'),
            ('READ_REG16 -> TMP1', 'READ_REG16 -> TMP0'),
            ('TMP2 -> RM16 IF_WRITE', 'TMP2 -> REG16 IF_WRITE'),
            ('    COMMIT_FLAGS\n', ''),
            ('    END\n', ''),
            ('    END', '    END\n    END'),
            ('    DECODE_ALU_RM16_REG16', '    READ_FLAGS -> TMP0\n    DECODE_ALU_RM16_REG16'),
        )
        for old, new in mutations:
            with self.subTest(old=old, new=new), self.assertRaises(CompileError):
                compile_sources({'bad.mc': SOURCE.replace(old, new)})

    def test_literal_encoding_and_memory_fallback(self):
        self.assertEqual([encode(op) for op in compile_sources({'a.mc': SOURCE}).operations],
                         [173, 6, 9, 14, 16, 18, 3])
