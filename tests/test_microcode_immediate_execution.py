"""Literal format-23 delta and rejection tests independent of RTL decoding."""
import json
import unittest

from tools.microcode.compile_microcode import ROOT, CompileError, compile_sources, encode, generate
from tools.microcode.audit_microcode import canonical_source, read_generated_words


REPLACEMENTS = {
    'ALU_AX_IMM16': (0, 13, 181), 'ALU_AL_IMM8': (0, 53, 182),
    'ALU_RM16_IMM16': (1, 11, 183), 'ALU_RM16_IMM8S': (1, 12, 184),
    'ALU_RM8_IMM8': (1, 50, 185), 'MOV_R16_IMM16': (0, 1, 186),
    'MOV_R8_IMM8': (0, 29, 187), 'MOV_RM16_IMM16': (1, 1, 188),
    'MOV_RM8_IMM8': (1, 29, 189),
}


class ImmediateExecutionMicrocodeTests(unittest.TestCase):
    def test_nine_controls_preserve_all_layout_and_sequential_tails(self):
        old = json.loads((ROOT/'tests/fixtures/microcode_register_execution.json').read_text())
        active = json.loads((ROOT/'tests/fixtures/microcode_immediate_execution.json').read_text())
        expected = old['words'].copy()
        for name, (offset, before, after) in REPLACEMENTS.items():
            pc = old['entries'][name] + offset
            self.assertEqual(expected[pc], before)
            expected[pc] = after
        sources = {p.name: p.read_text() for p in (ROOT/'microcode/source').glob('*.mc')}
        program = compile_sources(sources)
        artifacts = generate(program)
        words = read_generated_words(artifacts['spk286_microcode_pkg.sv'], artifacts['spk286_microcode_rom.sv'])
        self.assertEqual(list(words), expected)
        self.assertEqual(active['words'], expected)
        self.assertEqual(program.entries, old['entries'])
        self.assertEqual(program.labels, old['labels'])
        self.assertEqual({str(k): v for k, v in program.branch_targets.items()}, old['branch_targets'])
        self.assertEqual((program.format_version, program.word_width), (23, 8))
        rebuilt = compile_sources({'canonical.mc': canonical_source(
            words, program.entries, program.labels, program.branch_targets)})
        self.assertEqual([encode(op) for op in rebuilt.operations], expected)

    def test_every_control_rejects_inconsistent_or_partial_protocol(self):
        sources = {p.name: p.read_text() for p in (ROOT/'microcode/source').glob('*.mc')}
        for name in REPLACEMENTS:
            body = next(text.split(f'instruction {name}:', 1)[1].split('\ninstruction ', 1)[0]
                        for text in sources.values() if f'instruction {name}:' in text)
            source = f'microcode_format 23\ninstruction {name}:' + body
            program = compile_sources({'valid.mc': source})
            self.assertGreater(len(program.operations), 2)
            control = next(line.strip() for line in body.splitlines() if line.strip().startswith('FETCH_') and ' -> ' not in line)
            mutations = [source.replace('format 23', 'format 22'),
                         source.replace('    END', ''), source.replace('    END', '    END\n    END'),
                         source.replace(f'    {control}', f'    {control}\n    {control}'),
                         source.replace(f'    {control}', f'    READ_FLAGS -> TMP0\n    {control}')]
            if 'ALU_' in control:
                mutations += [source.replace('    COMMIT_FLAGS\n', ''),
                              source.replace('TMP2 ->', 'TMP0 ->'),
                              source.replace('IF_WRITE', '')]
            if '_RM' in control:
                mutations += [source.replace('    DECODE_MODRM\n', ''),
                              source.replace(control, control.replace('_RM', '_DST'))]
            for index, mutation in enumerate(mutations):
                with self.subTest(entry=name, mutation=index), self.assertRaises(CompileError):
                    compile_sources({'invalid.mc': mutation})
