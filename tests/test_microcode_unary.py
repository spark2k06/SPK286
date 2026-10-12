# SPDX-License-Identifier: MIT
"""Independent unary/dispatch ABI and fail-closed compiler protocols."""
import json
import unittest
from tools.microcode.compile_microcode import ROOT, CompileError, compile_sources, generate, emit
from tools.microcode.audit_microcode import canonical_source, read_generated_words


class UnaryMicrocodeTests(unittest.TestCase):
    def test_frozen_unary_contract_and_reconstruction(self):
        sources = json.loads((ROOT/'tests/fixtures/microcode_phase7_unary_sources.json').read_text())
        program = compile_sources(sources); artifacts = generate(program)
        fixture = json.loads((ROOT/'tests/fixtures/microcode_phase7_unary.json').read_text())
        words = read_generated_words(artifacts['spk286_microcode_pkg.sv'], artifacts['spk286_microcode_rom.sv'])
        self.assertEqual(list(words), fixture['words']); self.assertEqual(program.entries, fixture['entries']); self.assertEqual(program.labels, fixture['labels'])
        self.assertEqual((program.format_version, program.word_width, program.address_width), (10, 7, 9))
        self.assertEqual((fixture['format_version'], fixture['encoding_version'], fixture['word_width']), (10, 10, 7))
        rebuilt = compile_sources({'canonical.mc':canonical_source(words, program.entries, program.labels)})
        self.assertEqual([op.operation for op in rebuilt.operations], [op.operation for op in program.operations])
        self.assertEqual(artifacts, generate(compile_sources(dict(reversed(list(sources.items()))))))

    def test_terminal_dispatch_requires_context_and_has_no_fallthrough(self):
        good = 'microcode_format 10\ninstruction GROUP:\nDECODE_MODRM\nDISPATCH DECODED\n'
        program = compile_sources({'dispatch.mc':good})
        self.assertEqual([op.operation for op in program.operations], ['DECODE_MODRM','DISPATCH_DECODED'])
        for text in (good.replace('DECODE_MODRM\n',''), good+'END\n',good+'DISPATCH DECODED\n',good.replace('format 10','format 9')):
            with self.subTest(text=text), self.assertRaises(CompileError): compile_sources({'bad.mc':text})

    def test_unary_protocols_require_source_width_and_ordered_commits(self):
        for width in (8,16):
            for const in ('ZERO','ONES','ONE'):
                body = ['DECODE_MODRM',f'READ_RM{width} -> TMP0',f'CONST_{const} -> TMP1','ALU DECODED TMP0, TMP1 -> TMP2 FLAGS_DECODED',f'TMP2 -> RM{width} IF_WRITE','COMMIT_FLAGS','END']
                good = 'microcode_format 10\ninstruction UNARY:\n'+'\n'.join(body)
                compile_sources({'good.mc':good})
                for i in range(len(body)):
                    lines = list(body); lines.pop(i)
                    with self.subTest(width=width,const=const,missing=i), self.assertRaises(CompileError):
                        compile_sources({'bad.mc':'microcode_format 10\ninstruction UNARY:\n'+'\n'.join(lines)})
                for old,new in (('TMP0, TMP1','TMP1, TMP0'),(f'TMP2 -> RM{width}', f'TMP2 -> RM{24-width}'),('COMMIT_FLAGS\nEND','COMMIT_FLAGS\nCOMMIT_FLAGS\nEND')):
                    with self.subTest(old=old), self.assertRaises(CompileError): compile_sources({'bad.mc':good.replace(old,new)})

    def test_canonical_incdec_with_old_controls_infers_format10(self):
        for words in ([4,47,61,14,56,18,3],[4,6,61,14,16,18,3]):
            source = canonical_source(words,{'INCDEC':0})
            self.assertTrue(source.startswith('microcode_format 10\n'))
            with self.assertRaises(CompileError): compile_sources({'old.mc':source.replace('format 10','format 9')})
