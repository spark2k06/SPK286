# SPDX-License-Identifier: MIT
"""SALC's literal control sequence, strict lifecycle and append-only extension."""
import unittest
from tools.microcode.compile_microcode import ROOT, CompileError, compile_sources, generate, encode, emit
from tools.microcode.audit_microcode import canonical_source, read_generated_words

NAME = 'zzzzzzzzzzzzzzzzzzzzz_salc.mc'


class SalcMicrocodeTests(unittest.TestCase):
    def test_encoding_and_flags_preservation_protocol(self):
        source = (ROOT / 'microcode/source' / NAME).read_text()
        program = compile_sources({NAME: source})
        self.assertEqual([encode(op) for op in program.operations], [30, 172, 54, 3])
        self.assertEqual(program.entries, {'LOAD_CARRY_BYTE': 0})
        for line in ('    READ_FLAGS -> TMP0\n', '    CARRY_FILL8 TMP0\n',
                     '    TMP0 -> DST8\n', '    END\n'):
            with self.subTest(line=line), self.assertRaises(CompileError):
                compile_sources({NAME: source.replace(line, '')})
        for changed in (source.replace('21', '20'),
                        source.replace('    END', '    COMMIT_FLAGS\n    END'),
                        source.replace('TMP0 -> DST8', 'TMP0 -> DST')):
            with self.assertRaises(CompileError):
                compile_sources({NAME: changed})

    def test_existing_entries_unchanged_and_complete_roundtrip(self):
        sources = {p.name: p.read_text() for p in (ROOT / 'microcode/source').glob('*.mc')}
        previous = compile_sources({n: s for n, s in sources.items() if n != NAME})
        current = compile_sources(sources)
        self.assertEqual([encode(op) for op in current.operations[:-4]],
                         [encode(op) for op in previous.operations])
        self.assertEqual({n: a for n, a in current.entries.items() if n != 'LOAD_CARRY_BYTE'},
                         previous.entries)
        self.assertEqual(current.entries['LOAD_CARRY_BYTE'], len(previous.operations))
        self.assertEqual(current.labels, previous.labels)
        self.assertEqual(current.branch_targets, previous.branch_targets)
        artifacts = generate(current)
        words = read_generated_words(artifacts['spk286_microcode_pkg.sv'],
                                     artifacts['spk286_microcode_rom.sv'])
        self.assertEqual(list(words[-4:]), [30, 172, 54, 3])
        rebuilt = compile_sources({'canonical.mc': canonical_source(
            words, current.entries, current.labels, current.branch_targets)})
        self.assertEqual([encode(op) for op in rebuilt.operations], list(words))
        self.assertTrue(emit(artifacts, ROOT / 'microcode/generated', check=True))
