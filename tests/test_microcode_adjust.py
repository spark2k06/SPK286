# SPDX-License-Identifier: MIT
"""Independent adjust image and mandatory fault-check/FLAGS ordering."""
import json
import unittest
from tools.microcode.compile_microcode import ROOT,CompileError,compile_sources,generate,emit
from tools.microcode.audit_microcode import canonical_source,read_generated_words


class AdjustMicrocodeTests(unittest.TestCase):
    def test_frozen_adjust_image_and_canonical_reconstruction(self):
        sources=json.loads((ROOT/'tests/fixtures/microcode_phase7_adjust_sources.json').read_text())
        program=compile_sources(sources);artifacts=generate(program)
        contract=json.loads((ROOT/'tests/fixtures/microcode_phase7_adjust.json').read_text())
        words=read_generated_words(artifacts['spk286_microcode_pkg.sv'],artifacts['spk286_microcode_rom.sv'])
        self.assertEqual((program.format_version,program.word_width,program.address_width,len(words)),(11,7,9,342))
        self.assertEqual((contract['format_version'],contract['encoding_version']),(11,11))
        self.assertEqual(list(words),contract['words']);self.assertEqual(program.entries,contract['entries']);self.assertEqual(program.labels,contract['labels'])
        rebuilt=compile_sources({'canonical.mc':canonical_source(words,program.entries,program.labels)})
        self.assertEqual([op.operation for op in rebuilt.operations],[op.operation for op in program.operations])

    def test_adjust_protocol_requires_flags_then_fault_check(self):
        for first in (['READ_DST16 -> TMP0','CONST_ZERO -> TMP1'],['FETCH_IMM8 -> TMP1','READ_DST16 -> TMP0']):
            body=first+['ADJUST DECODED TMP0 TMP1 -> TMP2 FLAGS_DECODED','TMP2 -> DST IF_WRITE','COMMIT_FLAGS','CHECK_ARITHMETIC','END']
            good='microcode_format 11\ninstruction ADJUST:\n'+'\n'.join(body)
            compile_sources({'good.mc':good})
            for i in range(len(body)):
                missing=body[:i]+body[i+1:]
                with self.subTest(missing=i),self.assertRaises(CompileError):compile_sources({'bad.mc':'microcode_format 11\ninstruction ADJUST:\n'+'\n'.join(missing)})
            for old,new in (('COMMIT_FLAGS\nCHECK_ARITHMETIC','CHECK_ARITHMETIC\nCOMMIT_FLAGS'),('format 11','format 10'),('TMP2 -> DST','TMP2 -> RM16'),('CHECK_ARITHMETIC','CHECK_ARITHMETIC\nCHECK_ARITHMETIC')):
                with self.subTest(old=old),self.assertRaises(CompileError):compile_sources({'bad.mc':good.replace(old,new)})
