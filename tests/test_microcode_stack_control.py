import json
import unittest
from tools.microcode.compile_microcode import ROOT, CompileError, compile_sources, generate
from tools.microcode.audit_microcode import read_generated_words, canonical_source


class StackControlMicrocodeTests(unittest.TestCase):
    def test_independent_contract_and_roundtrip(self):
        p=compile_sources({f.name:f.read_text() for f in (ROOT/'microcode/source').glob('*.mc')})
        c=json.loads((ROOT/'tests/fixtures/microcode_phase5.json').read_text())
        g=generate(p)
        w=read_generated_words(g['spk286_microcode_pkg.sv'],g['spk286_microcode_rom.sv'])
        self.assertEqual(list(w),c['words'])
        self.assertEqual(p.entries,c['entries'])
        self.assertEqual((p.format_version,p.address_width,p.word_width),(4,7,5))
        rebuilt=compile_sources({'canonical.mc':canonical_source(w,p.entries,p.labels)})
        self.assertEqual(rebuilt.entries,p.entries)
        self.assertEqual(generate(p),generate(compile_sources(dict(reversed(list({f.name:f.read_text() for f in (ROOT/'microcode/source').glob('*.mc')}.items()))))))

    def test_invalid_lifetimes_and_order(self):
        for body,message in (
            ('PUSH16 DECODED TMP0','defined source'),
            ('TARGET_REL16 TMP1','undefined target'),
            ('REDIRECT DECODED','requires target'),
            ('CHECK_RM16','requires context'),
            ('ADJUST_SP16 TMP1','requires stack'),
            ('DECODE_MODRM\nPOP16 -> TMP0\nTMP0 -> RM16','requires precheck'),
            ('POP16 -> TMP0\nTARGET_ABS16 TMP0','missing REDIRECT'),
            ('COUNT DECODED\nCOUNT DECODED','more than once'),
            ('POP16 -> TMP0\nPOP16 -> TMP0','unique stack'),
            ('POP16 -> TMP0\nTARGET_ABS16 TMP0\nTARGET_ABS16 TMP0','overwritten'),
            ('POP16 -> TMP0\nTARGET_ABS16 TMP0\nREDIRECT DECODED\nCOUNT DECODED','after REDIRECT'),
        ):
            with self.subTest(body=body),self.assertRaisesRegex(CompileError,message):
                compile_sources({'negative.mc':'microcode_format 4\ninstruction NEGATIVE:\n'+body+'\nEND\n'})

    def test_version_boundary_and_whitespace(self):
        for version in (1,2,3):
            with self.assertRaises(CompileError):
                compile_sources({'v.mc':f'microcode_format {version}\ninstruction V:\nPOP16 -> TMP0\nEND\n'})
        p=compile_sources({'v.mc':'microcode_format 4\ninstruction V:\nFETCH_IMM8S->TMP0\nPUSH16  DECODED\tTMP0\nEND\n'})
        self.assertEqual(len(p.operations),3)
