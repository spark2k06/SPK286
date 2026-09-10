"""Independent encoding and complete source/iteration/commit contracts."""
import json
import unittest
from tools.microcode.compile_microcode import ROOT,CompileError,compile_sources,generate,emit
from tools.microcode.audit_microcode import canonical_source,read_generated_words,read_generated_branches

class StringMicrocodeTests(unittest.TestCase):
    def test_literal_image_and_generated_roundtrip(self):
        sources=json.loads((ROOT/'tests/fixtures/microcode_phase7_string_sources.json').read_text())
        program=compile_sources(sources);artifacts=generate(program)
        fixture=json.loads((ROOT/'tests/fixtures/microcode_phase7_strings.json').read_text())
        words=read_generated_words(artifacts['spk286_microcode_pkg.sv'],artifacts['spk286_microcode_rom.sv']);branches=read_generated_branches(artifacts['spk286_microcode_pkg.sv'])
        self.assertEqual((program.format_version,program.word_width,program.address_width,len(words)),(16,8,10,564))
        self.assertEqual(list(words),fixture['words']);self.assertEqual(program.entries,fixture['entries']);self.assertEqual(program.labels,fixture['labels'])
        self.assertEqual(branches,{404:414,406:412,411:407,521:528,527:522,529:539,538:530,540:546,545:542,547:553,552:548,554:563,562:555})
        rebuilt=compile_sources({'canonical.mc':canonical_source(words,program.entries,program.labels,branches)})
        self.assertEqual([op.operation for op in rebuilt.operations],[op.operation for op in program.operations])

    def test_missing_access_effects_or_changed_iteration_targets_are_rejected(self):
        source=(ROOT/'microcode/source/zzzzzzzzzzzz_strings.mc').read_text();compile_sources({'valid.mc':source});lines=source.splitlines()
        for index,line in enumerate(lines):
            if not line.startswith('    '):continue
            with self.subTest(index=index,line=line),self.assertRaises(CompileError):
                compile_sources({'missing.mc':'\n'.join(lines[:index]+lines[index+1:])})
        for changed in (source.replace('microcode_format 16','microcode_format 15'),source.replace('BRANCH_REPEAT_EMPTY done','BRANCH_REPEAT_EMPTY loop'),source.replace('BRANCH_REPEAT_CONTINUE loop','BRANCH_REPEAT_CONTINUE done'),source.replace('STEP_STRING_SOURCE','STEP_STRING_DEST')):
            with self.assertRaises(CompileError):compile_sources({'changed.mc':changed})
