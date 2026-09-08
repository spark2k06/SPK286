"""Independent scalar wire contract, frozen prior formats and protocol negatives."""
import json
import unittest
from tools.microcode.compile_microcode import ROOT, CompileError, compile_sources, generate, emit
from tools.microcode.audit_microcode import canonical_source, read_generated_words


class ScalarMicrocodeTests(unittest.TestCase):
    def test_frozen_scalar_contract_and_reconstruction(self):
        sources = json.loads((ROOT/'tests/fixtures/microcode_phase7_scalar_sources.json').read_text())
        program = compile_sources(sources)
        expected = json.loads((ROOT/'tests/fixtures/microcode_phase7_scalar.json').read_text())
        generated = generate(program)
        words = read_generated_words(generated['spk286_microcode_pkg.sv'], generated['spk286_microcode_rom.sv'])
        self.assertEqual(list(words), expected['words'])
        self.assertEqual(program.entries, expected['entries'])
        self.assertEqual(program.labels, expected['labels'])
        self.assertEqual((program.format_version, program.word_width, program.address_width), (7, 6, 8))
        rebuilt = compile_sources({'canonical.mc': canonical_source(words, program.entries, program.labels)})
        self.assertEqual([op.operation for op in rebuilt.operations], [op.operation for op in program.operations])
        self.assertEqual(generated, generate(compile_sources(dict(reversed(list(sources.items()))))))

    def test_load_flags_byte_roundtrip_requires_scalar_format(self):
        source = canonical_source((30, 54, 3), {'LOAD': 0})
        self.assertTrue(source.startswith('microcode_format 7\n'))
        self.assertEqual(compile_sources({'lahf.mc': source}).format_version, 7)

    def test_rejects_undefined_source_missing_flags_and_double_commit(self):
        for body in ('SIGN_EXTEND8 TMP0\nTMP0 -> DST\nEND',
                     'READ_DST16 -> TMP0\nSIGN_FILL16 TMP0\nEND',
                     'FLAGS DECODED\nFLAGS DECODED\nEND',
                     'READ_FLAGS -> TMP0\nTMP0 -> DST\nEND',
                     'CONST_ONE -> TMP0\nEND',
                     'READ_DST16 -> TMP0\nCONST_ONE -> TMP1\nALU DECODED TMP0, TMP1 -> TMP2 FLAGS_DECODED\nCOMMIT_FLAGS\nEND',
                     'READ_DST16 -> TMP0\nCONST_ONE -> TMP1\nALU DECODED TMP0, TMP1 -> TMP2 FLAGS_DECODED\nTMP2 -> DST IF_WRITE\nEND'):
            with self.subTest(body=body), self.assertRaises(CompileError):
                compile_sources({'bad.mc': 'microcode_format 7\ninstruction BAD:\n'+body+'\n'})
        for version in range(1, 7):
            with self.subTest(version=version), self.assertRaises(CompileError):
                compile_sources({'old.mc': f'microcode_format {version}\ninstruction OLD:\nFLAGS DECODED\nEND\n'})
