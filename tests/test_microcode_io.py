"""Independent encoding and complete source/iteration/commit contracts."""
import json
import unittest
from tools.microcode.compile_microcode import ROOT,CompileError,compile_sources,generate,emit
from tools.microcode.audit_microcode import canonical_source,read_generated_words,read_generated_branches

class IoMicrocodeTests(unittest.TestCase):
    def test_literal_image_and_generated_roundtrip(self):
        sources={p.name:p.read_text() for p in (ROOT/'microcode/source').glob('*.mc')}
        program=compile_sources(sources);artifacts=generate(program)
        fixture=json.loads((ROOT/'tests/fixtures/microcode_phase8.json').read_text())
        words=read_generated_words(artifacts['spk286_microcode_pkg.sv'],artifacts['spk286_microcode_rom.sv']);branches=read_generated_branches(artifacts['spk286_microcode_pkg.sv'])
        self.assertEqual((program.format_version,program.word_width,program.address_width,len(words)),(20,8,10,682))
        self.assertEqual(list(words),fixture['words']);self.assertEqual(program.entries,fixture['entries']);self.assertEqual(program.labels,fixture['labels'])
        self.assertEqual(branches,{412: 422, 414: 420, 419: 415, 549: 556, 555: 550, 557: 567, 566: 558, 568: 574, 573: 570, 575: 581, 580: 576, 582: 591, 590: 583, 608: 615, 614: 610, 616: 623, 622: 618, 624: 631, 630: 626, 632: 639, 638: 634})
        rebuilt=compile_sources({'canonical.mc':canonical_source(words,program.entries,program.labels,branches)})
        self.assertEqual([op.operation for op in rebuilt.operations],[op.operation for op in program.operations])
        self.assertTrue(emit(artifacts,ROOT/'microcode/generated',check=True))

    def test_missing_access_effects_or_changed_iteration_targets_are_rejected(self):
        source=(ROOT/'microcode/source/zzzzzzzzzzzzz_io.mc').read_text();compile_sources({'valid.mc':source});lines=source.splitlines()
        for index,line in enumerate(lines):
            if not line.startswith('    '):continue
            with self.subTest(index=index,line=line),self.assertRaises(CompileError):
                compile_sources({'missing.mc':'\n'.join(lines[:index]+lines[index+1:])})
        for changed in (source.replace('microcode_format 17','microcode_format 16'),source.replace('BRANCH_REPEAT_EMPTY done','BRANCH_REPEAT_EMPTY loop'),source.replace('BRANCH_REPEAT_CONTINUE loop','BRANCH_REPEAT_CONTINUE done'),source.replace('STEP_STRING_SOURCE','STEP_STRING_DEST')):
            with self.assertRaises(CompileError):compile_sources({'changed.mc':changed})
