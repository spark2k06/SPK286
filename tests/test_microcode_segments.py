"""Independent segment control ABI and source-before-cache commit protocols."""
import json
import unittest
from tools.microcode.compile_microcode import ROOT,CompileError,compile_sources,generate,emit
from tools.microcode.audit_microcode import canonical_source,read_generated_words


class SegmentMicrocodeTests(unittest.TestCase):
    def test_active_segment_image_and_canonical_reconstruction(self):
        sources=json.loads((ROOT/'tests/fixtures/microcode_phase7_segment_sources.json').read_text())
        program=compile_sources(sources);artifacts=generate(program)
        contract=json.loads((ROOT/'tests/fixtures/microcode_phase7_segments.json').read_text())
        words=read_generated_words(artifacts['spk286_microcode_pkg.sv'],artifacts['spk286_microcode_rom.sv'])
        self.assertEqual((program.format_version,program.word_width,program.address_width,len(words)),(12,7,9,356))
        self.assertEqual((contract['format_version'],contract['encoding_version']),(12,12))
        self.assertEqual(list(words),contract['words']);self.assertEqual(program.entries,contract['entries']);self.assertEqual(program.labels,contract['labels'])
        rebuilt=compile_sources({'canonical.mc':canonical_source(words,program.entries,program.labels)})
        self.assertEqual([op.operation for op in rebuilt.operations],[op.operation for op in program.operations])

    def test_segment_source_stack_and_cache_write_protocols(self):
        bodies=(['DECODE_MODRM','READ_SEG16 -> TMP0','TMP0 -> RM16','END'],
                ['DECODE_MODRM','READ_RM16 -> TMP0','TMP0 -> SEG16','END'],
                ['READ_SEG16 -> TMP0','PUSH16 DECODED TMP0','END'],
                ['POP16 -> TMP0','TMP0 -> SEG16','END'])
        for body in bodies:
            good='microcode_format 12\ninstruction SEGMENT:\n'+'\n'.join(body)
            compile_sources({'good.mc':good})
            for i in range(len(body)):
                with self.subTest(body=body,missing=i),self.assertRaises(CompileError):
                    compile_sources({'bad.mc':'microcode_format 12\ninstruction SEGMENT:\n'+'\n'.join(body[:i]+body[i+1:])})
            for changed in (good.replace('format 12','format 11'),good.replace('END','COMMIT_FLAGS\nEND'),
                            good.replace('TMP0 -> SEG16','TMP1 -> SEG16') if 'TMP0 -> SEG16' in good else good.replace('READ_SEG16 -> TMP0','READ_SEG16 -> TMP1')):
                with self.subTest(changed=changed),self.assertRaises(CompileError):compile_sources({'bad.mc':changed})
