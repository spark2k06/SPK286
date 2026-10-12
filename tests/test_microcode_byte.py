# SPDX-License-Identifier: MIT
"""Independent encoding-6 controls, frozen-source stability and rejection cases."""
import json
import unittest
from tools.microcode.compile_microcode import ROOT, CompileError, compile_sources, generate, emit
from tools.microcode.audit_microcode import read_generated_words, canonical_source

class ByteMicrocodeTests(unittest.TestCase):
    def test_frozen_byte_contract(self):
        sources=json.loads((ROOT/'tests/fixtures/microcode_phase7_byte_sources.json').read_text())
        p=compile_sources(sources)
        expected=json.loads((ROOT/'tests/fixtures/microcode_phase7_byte.json').read_text())
        generated=generate(p)
        words=read_generated_words(generated['spk286_microcode_pkg.sv'],generated['spk286_microcode_rom.sv'])
        self.assertEqual(list(words),expected['words'])
        self.assertEqual(p.entries,expected['entries'])
        self.assertEqual(p.labels,expected['labels'])
        self.assertEqual((p.format_version,p.word_width,p.address_width),(6,6,8))
        old=json.loads((ROOT/'tests/fixtures/microcode_phase6.json').read_text())
        # Immediate forms acquire every instruction byte before data access;
        # all other inherited operations retain the frozen encoding.
        revised=list(old['words'])
        revised[31:38]=[4,11,6,14,16,18,3]
        revised[38:45]=[4,12,6,14,16,18,3]
        self.assertEqual(list(words[:128]),revised)
        self.assertTrue(all(p.entries[k]==v for k,v in old['entries'].items()))
        rebuilt=compile_sources({'canonical.mc':canonical_source(words,p.entries,p.labels)})
        self.assertEqual(read_generated_words(generate(rebuilt)['spk286_microcode_pkg.sv'],generate(rebuilt)['spk286_microcode_rom.sv']),words)
        self.assertEqual(generate(p),generate(compile_sources(dict(reversed(list(sources.items()))))))

    def test_malformed_width_lifetime_context_and_disposition_rejected(self):
        bodies=(
            'TMP0 -> DST8\nEND',
            'READ_RM8 -> TMP0\nTMP0 -> DST8\nEND',
            'FETCH_IMM16 -> TMP0\nTMP0 -> DST8\nEND',
            'FETCH_IMM8 -> TMP0\nTMP0 -> DST8',
            'FETCH_IMM8 -> TMP0\nTMP0 -> DST8\nEND\nEND',
            'READ_DST8 -> TMP0\nALU DECODED TMP0, TMP1 -> TMP2 FLAGS_DECODED\nEND',
            'READ_DST8 -> TMP0\nFETCH_IMM8 -> TMP1\nALU DECODED TMP0, TMP1 -> TMP2 FLAGS_DECODED\nCOMMIT_FLAGS\nEND',
            'READ_DST8 -> TMP0\nFETCH_IMM8 -> TMP1\nALU DECODED TMP0, TMP1 -> TMP2 FLAGS_DECODED\nTMP2 -> DST8 IF_WRITE\nEND',
            'FETCH_IMM8 -> TMP0\nTMP0 -> DST8\nHALT\nEND',
        )
        for body in bodies:
            with self.subTest(body=body),self.assertRaises(CompileError) as caught:
                compile_sources({'bad.mc':'microcode_format 6\ninstruction BAD:\n'+body+'\n'})
            self.assertIn('bad.mc:',str(caught.exception))
        for version in range(1,6):
            with self.subTest(version=version),self.assertRaises(CompileError):
                compile_sources({'bad.mc':f'microcode_format {version}\ninstruction OLD:\nREAD_DST8 -> TMP0\nTMP0 -> DST8\nEND\n'})

    def test_new_address_bit_required(self):
        sources=json.loads((ROOT/'tests/fixtures/microcode_phase7_byte_sources.json').read_text())
        with self.assertRaisesRegex(CompileError,'overflow'):
            compile_sources(sources,address_width=7)
