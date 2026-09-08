import json
import unittest
from tools.microcode.compile_microcode import ROOT, CompileError, compile_sources, generate, encode
from tools.microcode.audit_microcode import canonical_source, read_generated_words

SOURCE = '''microcode_format 3
instruction WORD_ALU:
DECODE_MODRM
READ_RM16 -> TMP0
FETCH_IMM16 -> TMP1
ALU DECODED TMP0, TMP1 -> TMP2 FLAGS_DECODED
TMP2 -> RM16 IF_WRITE
COMMIT_FLAGS
END
'''


class AluMicrocodeTests(unittest.TestCase):
    def test_datapath_whitespace_is_not_semantic(self):
        spaced = SOURCE.replace('ALU DECODED TMP0, TMP1 -> TMP2 FLAGS_DECODED',
                                'ALU\tDECODED  TMP0 ,TMP1->TMP2\tFLAGS_DECODED').replace(
                                'TMP2 -> RM16 IF_WRITE', 'TMP2->RM16\tIF_WRITE')
        original = compile_sources({'a.mc': SOURCE})
        rebuilt = compile_sources({'a.mc': spaced})
        self.assertEqual([encode(op) for op in original.operations], [encode(op) for op in rebuilt.operations])

    def test_frozen_phase4_contract(self):
        frozen = json.loads((ROOT/'tests/fixtures/microcode_phase6_sources.json').read_text())
        p = compile_sources({k:v for k,v in frozen.items() if k in ('data_move.mc','word_alu.mc')})
        contract = json.loads((ROOT/'tests/fixtures/microcode_phase4.json').read_text())
        generated = generate(p)
        words = read_generated_words(generated['spk286_microcode_pkg.sv'], generated['spk286_microcode_rom.sv'])
        self.assertEqual(list(words), contract['words'])
        self.assertEqual(p.entries, contract['entries'])
        self.assertEqual(p.labels, contract['labels'])
        self.assertEqual((p.format_version, p.word_width, p.address_width), (3, 5, 6))
        rebuilt = compile_sources({'roundtrip.mc': canonical_source(words, p.entries, p.labels)})
        self.assertEqual([encode(op) for op in rebuilt.operations], list(words))
        self.assertEqual(rebuilt.labels, p.labels)

    def test_lifetime_and_explicit_flags(self):
        for old, new, error in (
            ('READ_RM16 -> TMP0\n', '', 'undefined ALU temporary'),
            ('FETCH_IMM16 -> TMP1\n', '', 'undefined ALU temporary'),
            ('DECODE_MODRM\n', '', 'before DECODE_MODRM'),
            ('DECODED TMP0', 'MUL TMP0', 'invalid ALU'),
            ('FLAGS_DECODED', 'FLAGS_ALL', 'invalid ALU'),
            ('TMP2 -> RM16 IF_WRITE\n', '', 'result disposition'),
            ('COMMIT_FLAGS\n', '', 'missing COMMIT_FLAGS'),
            ('TMP2 -> RM16 IF_WRITE', 'TMP2 -> AX IF_WRITE', 'malformed'),
            ('COMMIT_FLAGS', 'COMMIT_FLAGS\nCOMMIT_FLAGS', 'after FLAGS commit'),
            ('END', 'END\nREAD_DST16 -> TMP0', 'after END'),
            ('FETCH_IMM16 -> TMP1', 'FETCH_IMM8S -> TMP0', 'invalid FETCH_IMM8S'),
            ('TMP2 -> RM16 IF_WRITE', 'TMP2 -> RM16 IF_WRITE\nTMP2 -> RM16 IF_WRITE', 'already consumed'),
        ):
            with self.subTest(error=error), self.assertRaisesRegex(CompileError, error):
                compile_sources({'negative.mc': SOURCE.replace(old, new)})

    def test_extension_requires_format_three(self):
        for version in (1, 2):
            with self.assertRaises(CompileError):
                compile_sources({'old.mc': SOURCE.replace('format 3', f'format {version}')})

    def test_encoding_and_source_locations(self):
        p = compile_sources({'alu.mc': SOURCE})
        self.assertEqual([encode(op) for op in p.operations], [4,6,11,14,16,18,3])
        self.assertEqual(p.operations[3].location.line, 6)
        self.assertEqual(p.operations[3].operands[-1], 'FLAGS_DECODED')
