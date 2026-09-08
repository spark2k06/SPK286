"""Independent shift control encoding and explicit width/disposition protocols."""
import json
import unittest
from tools.microcode.compile_microcode import ROOT, CompileError, compile_sources, generate, emit
from tools.microcode.audit_microcode import canonical_source, read_generated_words


class ShiftMicrocodeTests(unittest.TestCase):
    def test_frozen_shift_contract_and_reconstruction(self):
        sources = json.loads((ROOT/'tests/fixtures/microcode_phase7_shift_sources.json').read_text())
        program = compile_sources(sources); artifacts = generate(program)
        fixture = json.loads((ROOT/'tests/fixtures/microcode_phase7_shift.json').read_text())
        words = read_generated_words(artifacts['spk286_microcode_pkg.sv'],artifacts['spk286_microcode_rom.sv'])
        self.assertEqual(list(words),fixture['words']);self.assertEqual(program.entries,fixture['entries']);self.assertEqual(program.labels,fixture['labels'])
        self.assertEqual((program.format_version,program.word_width,program.address_width),(8,6,8))
        rebuilt = compile_sources({'canonical.mc':canonical_source(words,program.entries,program.labels)})
        self.assertEqual([op.operation for op in rebuilt.operations],[op.operation for op in program.operations])
        self.assertEqual(artifacts,generate(compile_sources(dict(reversed(list(sources.items()))))))

    def test_width_source_and_commit_protocol_fail_closed(self):
        body = 'DECODE_MODRM\nFETCH_IMM8 -> TMP1\nREAD_RM16 -> TMP0\nSHIFT DECODED TMP0 TMP1 -> TMP2 FLAGS_DECODED\nTMP2 -> RM16 IF_WRITE\nCOMMIT_FLAGS\nEND\n'
        for bad in (body.replace('READ_RM16','READ_RM8'),body.replace('DECODE_MODRM\n',''),body.replace('FETCH_IMM8 -> TMP1\n',''),
                    body.replace('FETCH_IMM8 -> TMP1\nREAD_RM16 -> TMP0','READ_RM16 -> TMP0\nFETCH_IMM8 -> TMP1'),
                    body.replace('COMMIT_FLAGS\n',''),body.replace('TMP2 -> RM16 IF_WRITE\n',''),body.replace('TMP2 -> RM16 IF_WRITE','TMP2 -> RM16 IF_WRITE\nTMP2 -> RM16 IF_WRITE')):
            with self.subTest(body=bad),self.assertRaises(CompileError):compile_sources({'bad.mc':'microcode_format 8\ninstruction BAD:\n'+bad})
        for version in range(1,8):
            with self.subTest(version=version),self.assertRaises(CompileError):compile_sources({'old.mc':f'microcode_format {version}\ninstruction OLD:\n'+body})
