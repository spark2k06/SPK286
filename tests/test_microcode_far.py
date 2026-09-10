"""Independent far pointer control and ordered stack/cache disposition contract."""
import json
import unittest
from tools.microcode.compile_microcode import ROOT,CompileError,compile_sources,generate,emit
from tools.microcode.audit_microcode import canonical_source,read_generated_words,read_generated_branches

class FarMicrocodeTests(unittest.TestCase):
    def test_literal_encoding_and_canonical_source(self):
        sources=json.loads((ROOT/'tests/fixtures/microcode_phase7_far_sources.json').read_text())
        program=compile_sources(sources);artifacts=generate(program)
        contract=json.loads((ROOT/'tests/fixtures/microcode_phase7_far.json').read_text())
        words=read_generated_words(artifacts['spk286_microcode_pkg.sv'],artifacts['spk286_microcode_rom.sv'])
        branches=read_generated_branches(artifacts['spk286_microcode_pkg.sv'])
        self.assertEqual((program.format_version,program.word_width,program.address_width,len(words)),(14,7,9,492))
        self.assertEqual(list(words),contract['words']);self.assertEqual(program.entries,contract['entries']);self.assertEqual(program.labels,contract['labels'])
        self.assertEqual(branches,{404:414,406:412,411:407})
        rebuilt=compile_sources({'canonical.mc':canonical_source(words,program.entries,program.labels,branches)})
        self.assertEqual([op.operation for op in rebuilt.operations],[op.operation for op in program.operations])

    def test_missing_acquisition_commit_and_fault_steps_are_rejected(self):
        source=(ROOT/'microcode/source/zzzzzzzzzz_far_pointer.mc').read_text();compile_sources({'valid.mc':source})
        lines=source.splitlines()
        for index,line in enumerate(lines):
            if not line.startswith('    '):continue
            with self.subTest(index=index,line=line),self.assertRaises(CompileError):
                compile_sources({'missing.mc':'\n'.join(lines[:index]+lines[index+1:])})
        for changed in (source.replace('microcode_format 14','microcode_format 13'),source.replace('READ_SEG16 -> TMP0','READ_FLAGS -> TMP0'),source.replace('CHECK_POP2','CHECK_PUSH2')):
            with self.assertRaises(CompileError):compile_sources({'changed.mc':changed})
