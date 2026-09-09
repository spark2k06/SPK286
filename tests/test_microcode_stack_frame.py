"""Independent stack/frame primitives and bounded symbolic branch contracts."""
import json
import unittest
from tools.microcode.compile_microcode import ROOT,CompileError,compile_sources,generate,emit
from tools.microcode.audit_microcode import canonical_source,read_generated_words,read_generated_branches


class StackFrameMicrocodeTests(unittest.TestCase):
    def test_active_image_and_independent_branch_reconstruction(self):
        sources=json.loads((ROOT/'tests/fixtures/microcode_phase7_stack_frame_sources.json').read_text())
        program=compile_sources(sources);artifacts=generate(program)
        contract=json.loads((ROOT/'tests/fixtures/microcode_phase7_stack_frame.json').read_text())
        words=read_generated_words(artifacts['spk286_microcode_pkg.sv'],artifacts['spk286_microcode_rom.sv'])
        branches=read_generated_branches(artifacts['spk286_microcode_pkg.sv'])
        self.assertEqual((program.format_version,program.word_width,program.address_width,len(words)),(13,7,9,433))
        self.assertEqual(list(words),contract['words']);self.assertEqual(program.entries,contract['entries']);self.assertEqual(program.labels,contract['labels'])
        self.assertEqual(branches,{404:414,406:412,411:407})
        self.assertEqual(branches,program.branch_targets)
        rebuilt=compile_sources({'canonical.mc':canonical_source(words,program.entries,program.labels,branches)})
        self.assertEqual([op.operation for op in rebuilt.operations],[op.operation for op in program.operations])
        self.assertEqual(rebuilt.branch_targets,branches)
        for invalid in ({},{404:407,406:412,411:407},{404:414,406:356,411:407}):
            with self.subTest(invalid=invalid),self.assertRaises((ValueError,CompileError)):
                canonical_source(words,program.entries,program.labels,invalid)

    def test_precheck_source_commit_and_loop_protocols(self):
        source=(ROOT/'microcode/source/zzzzzzzzz_stack_frame.mc').read_text()
        compile_sources({'valid.mc':source})
        lines=source.splitlines()
        for i,line in enumerate(lines):
            if not line.startswith('    '):continue
            with self.subTest(removed=line,index=i),self.assertRaises(CompileError):
                compile_sources({'invalid.mc':'\n'.join(lines[:i]+lines[i+1:])})
        for old,new in [('BRANCH_ZERO finish','BRANCH_ZERO copy_parent'),
                        ('BRANCH_NONZERO copy_parent','BRANCH_NONZERO finish'),
                        ('BRANCH_ZERO push_frame','BRANCH_ZERO absent'),
                        ('microcode_format 13','microcode_format 12'),
                        ('CHECK_PUSH8','CHECK_POP8'),('TMP0 -> BP','TMP0 -> AX')]:
            with self.subTest(old=old,new=new),self.assertRaises(CompileError):
                compile_sources({'invalid.mc':source.replace(old,new)})
