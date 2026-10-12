# SPDX-License-Identifier: MIT
import json
import unittest
from tools.microcode.compile_microcode import ROOT, CompileError, compile_sources, encode, generate
from tools.microcode.audit_microcode import canonical_source, read_generated_words

SOURCE = """microcode_format 27
instruction ESC_NO_COPROCESSOR:
    CHECK_NPX_ESC
    DECODE_MODRM
    CHECK_RM16
    END
"""


def expected_boundary_image(old):
    words = old['words'].copy()
    position = old['entries']['ESC_NO_COPROCESSOR']+2
    assert words[position-2:position+1] == [196,4,3]
    words.insert(position,19)
    def shifted(pc): return pc+int(pc >= position)
    return (words, {name:shifted(pc) for name,pc in old['entries'].items()},
            {name:shifted(pc) for name,pc in old['labels'].items()},
            {shifted(int(pc)):shifted(target) for pc,target in old['branch_targets'].items()})


class EscBoundaryMicrocodeTests(unittest.TestCase):
    def test_current_image_adds_only_an_existing_check_without_operand_access(self):
        old = json.loads((ROOT/'tests/fixtures/microcode_npx_access.json').read_text())
        words,entries,labels,branches = expected_boundary_image(old)
        program = compile_sources({p.name:p.read_text() for p in (ROOT/'microcode/source').glob('*.mc')})
        self.assertEqual([encode(op) for op in program.operations],words)
        self.assertEqual(program.entries,entries)
        self.assertEqual(program.labels,labels)
        self.assertEqual(program.branch_targets,branches)
        frozen = json.loads((ROOT/'tests/fixtures/microcode_esc_boundary.json').read_text())
        self.assertEqual(frozen['words'],words)
        self.assertEqual(frozen['entries'],entries)
        generated = generate(program)
        emitted = read_generated_words(generated['spk286_microcode_pkg.sv'],generated['spk286_microcode_rom.sv'])
        rebuilt = compile_sources({'canonical.mc':canonical_source(emitted,entries,labels,branches)})
        self.assertEqual([encode(op) for op in rebuilt.operations],words)
        self.assertEqual(rebuilt.format_version,27)

    def test_exact_sequence_and_legacy_h18(self):
        self.assertEqual([encode(op) for op in compile_sources({'test.mc':SOURCE}).operations],[196,4,19,3])
        old = SOURCE.replace('format 27','format 26').replace('    CHECK_RM16\n','')
        self.assertEqual([encode(op) for op in compile_sources({'old.mc':old}).operations],[196,4,3])

    def test_missing_early_duplicate_and_wrong_checks_are_rejected(self):
        for source in (SOURCE.replace('    CHECK_RM16\n',''),
                       SOURCE.replace('    DECODE_MODRM\n    CHECK_RM16','    CHECK_RM16\n    DECODE_MODRM'),
                       SOURCE.replace('    CHECK_RM16','    CHECK_RM16\n    CHECK_RM16'),
                       SOURCE.replace('CHECK_RM16','READ_RM16 -> TMP0'),
                       SOURCE.replace('CHECK_RM16','CHECK_RM32'),
                       SOURCE.replace('format 27','format 26')):
            with self.subTest(source=source),self.assertRaises(CompileError):
                compile_sources({'bad.mc':source})
