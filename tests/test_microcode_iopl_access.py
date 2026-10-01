import json
import unittest

from tools.microcode.compile_microcode import ROOT, CompileError, compile_sources, encode, generate
from tools.microcode.audit_microcode import canonical_source, read_generated_words


SOURCE = """microcode_format 25
instruction IN_AX_PORT:
    FETCH_PORT DECODED -> TMP1
    CHECK_IO_PRIVILEGE
    IO_READ16 TMP1 -> TMP0
    TMP0 -> DST
    END
"""


class IoplAccessMicrocodeTests(unittest.TestCase):
    def test_current_image_adds_only_eight_pre_side_effect_checks(self):
        old = json.loads((ROOT / 'tests/fixtures/microcode_system_access.json').read_text())
        additions = {'IN_AL_PORT': 1, 'IN_AX_PORT': 1, 'OUT_PORT_AL': 1, 'OUT_PORT_AX': 1,
                     'STRING_INPUT_BYTE': 2, 'STRING_INPUT_WORD': 2,
                     'STRING_OUTPUT_BYTE': 2, 'STRING_OUTPUT_WORD': 2}
        expected, entries, positions = [], {}, []
        ordered = sorted(old['entries'].items(), key=lambda item: item[1])
        for i, (name, address) in enumerate(ordered):
            entries[name] = len(expected)
            end = ordered[i+1][1] if i+1<len(ordered) else len(old['words'])
            body = old['words'][address:end].copy()
            if name in additions:
                offset = additions[name]
                self.assertEqual(body[offset-1], 135)  # Captured port, no transaction.
                body.insert(offset, 195)
                positions.append(address+offset)
            expected.extend(body)
        def shifted(pc):
            return pc + sum(position <= pc for position in positions)
        labels = {name: shifted(pc) for name, pc in old['labels'].items()}
        branches = {shifted(int(pc)): shifted(target) for pc, target in old['branch_targets'].items()}
        program = compile_sources({p.name: p.read_text() for p in (ROOT / 'microcode/source').glob('*.mc')})
        self.assertEqual([encode(op) for op in program.operations], expected)
        self.assertEqual(program.entries, entries)
        self.assertEqual(program.labels, labels)
        self.assertEqual(program.branch_targets, branches)
        fixture = json.loads((ROOT / 'tests/fixtures/microcode_iopl_access.json').read_text())
        self.assertEqual(fixture['words'], expected)
        self.assertEqual(fixture['entries'], entries)
        generated = generate(program)
        words = read_generated_words(generated['spk286_microcode_pkg.sv'], generated['spk286_microcode_rom.sv'])
        rebuilt = compile_sources({'canonical.mc': canonical_source(words, entries, labels, branches)})
        self.assertEqual([encode(op) for op in rebuilt.operations], expected)

    def test_scalar_literal_and_legacy_format_remain_independent(self):
        self.assertEqual([encode(op) for op in compile_sources({'test.mc': SOURCE}).operations], [135, 195, 132, 2, 3])
        legacy = SOURCE.replace('format 25', 'format 17').replace('    CHECK_IO_PRIVILEGE\n', '')
        self.assertEqual([encode(op) for op in compile_sources({'legacy.mc': legacy}).operations], [135, 132, 2, 3])

    def test_missing_late_or_duplicate_check_is_rejected(self):
        for source in (SOURCE.replace('    CHECK_IO_PRIVILEGE\n', ''),
                       SOURCE.replace('    CHECK_IO_PRIVILEGE\n', '    CHECK_IO_PRIVILEGE\n    CHECK_IO_PRIVILEGE\n'),
                       SOURCE.replace('    CHECK_IO_PRIVILEGE\n', '').replace('    TMP0 -> DST', '    CHECK_IO_PRIVILEGE\n    TMP0 -> DST'),
                       SOURCE.replace('    FETCH_PORT DECODED -> TMP1\n', '').rstrip() + '\n    FETCH_PORT DECODED -> TMP1\n',
                       SOURCE.replace('format 25', 'format 24')):
            with self.subTest(source=source), self.assertRaises(CompileError):
                compile_sources({'bad.mc': source})

    def test_string_check_precedes_count_memory_and_port_but_keeps_empty_branch(self):
        source = """microcode_format 25
instruction STRING_OUTPUT_WORD:
    BRANCH_REPEAT_EMPTY done
    FETCH_PORT DECODED -> TMP1
    CHECK_IO_PRIVILEGE
loop:
    STEP_STRING_SOURCE
    REPEAT_COUNT
    READ_STRING_TMP0
    IO_WRITE16 TMP1 TMP0
    BRANCH_REPEAT_CONTINUE loop
done:
    END
"""
        program = compile_sources({'test.mc': source})
        self.assertEqual([encode(op) for op in program.operations], [121, 135, 195, 122, 124, 125, 134, 128, 3])
        self.assertEqual(program.branch_targets, {0: 8, 7: 3})
        with self.assertRaises(CompileError):
            compile_sources({'bad.mc': source.replace('    CHECK_IO_PRIVILEGE\nloop:', 'loop:\n    CHECK_IO_PRIVILEGE')})
