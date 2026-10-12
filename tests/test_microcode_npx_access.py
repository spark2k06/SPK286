# SPDX-License-Identifier: MIT
import json
import unittest

from tools.microcode.compile_microcode import ROOT, CompileError, compile_sources, encode, generate
from tools.microcode.audit_microcode import canonical_source, read_generated_words


ESC = """microcode_format 26
instruction ESC_NO_COPROCESSOR:
    CHECK_NPX_ESC
    DECODE_MODRM
    END
"""
WAIT = """microcode_format 26
instruction WAIT_NO_COPROCESSOR:
    CHECK_NPX_WAIT
    END
"""


def expected_npx_image(old):
    # Independent literal transformation of the frozen ROM preceding the no-NPX checks, including
    # every unrelated entry and branch. No expectations come from new sources.
    words, entries, positions = [], {}, []
    ordered = sorted(old['entries'].items(), key=lambda item: item[1])
    for index, (name, address) in enumerate(ordered):
        entries[name] = len(words)
        end = ordered[index+1][1] if index+1 < len(ordered) else len(old['words'])
        body = old['words'][address:end].copy()
        if name == 'ESC_NO_COPROCESSOR':
            assert body == [4, 3]
            body.insert(0, 196)
            positions.append((address, 1))
            words.extend(body)
            entries['WAIT_NO_COPROCESSOR'] = len(words)
            words.extend([197, 3])
            positions.append((end, 2))
        else:
            words.extend(body)
    def shifted(pc):
        return pc + sum(size for position, size in positions if position <= pc)
    labels = {name: shifted(pc) for name, pc in old['labels'].items()}
    branches = {shifted(int(pc)): shifted(target) for pc, target in old['branch_targets'].items()}
    return words, entries, labels, branches


class NpxAccessMicrocodeTests(unittest.TestCase):
    def test_frozen_npx_image_changes_only_esc_check_and_adds_wait(self):
        old = json.loads((ROOT / 'tests/fixtures/microcode_iopl_access.json').read_text())
        words, entries, labels, branches = expected_npx_image(old)
        frozen = json.loads((ROOT / 'tests/fixtures/microcode_npx_access.json').read_text())
        program = compile_sources({'format26.mc': canonical_source(frozen['words'], frozen['entries'],
                    frozen['labels'], {int(k): v for k, v in frozen['branch_targets'].items()})})
        self.assertEqual([encode(op) for op in program.operations], words)
        self.assertEqual(program.entries, entries)
        self.assertEqual(program.labels, labels)
        self.assertEqual(program.branch_targets, branches)
        self.assertEqual(frozen['words'], words)
        self.assertEqual(frozen['entries'], entries)
        generated = generate(program)
        emitted = read_generated_words(generated['spk286_microcode_pkg.sv'], generated['spk286_microcode_rom.sv'])
        rebuilt = compile_sources({'canonical.mc': canonical_source(emitted, entries, labels, branches)})
        self.assertEqual([encode(op) for op in rebuilt.operations], words)

    def test_exact_sequences_and_legacy_esc(self):
        self.assertEqual([encode(op) for op in compile_sources({'esc.mc': ESC}).operations], [196, 4, 3])
        self.assertEqual([encode(op) for op in compile_sources({'wait.mc': WAIT}).operations], [197, 3])
        legacy = ESC.replace('format 26', 'format 17').replace('    CHECK_NPX_ESC\n', '')
        self.assertEqual([encode(op) for op in compile_sources({'legacy.mc': legacy}).operations], [4, 3])

    def test_missing_late_duplicate_wrong_check_and_wrong_entry_rejected(self):
        bad_sources = [
            ESC.replace('    CHECK_NPX_ESC\n', ''),
            ESC.replace('    CHECK_NPX_ESC\n', '    CHECK_NPX_ESC\n    CHECK_NPX_ESC\n'),
            ESC.replace('    CHECK_NPX_ESC\n    DECODE_MODRM', '    DECODE_MODRM\n    CHECK_NPX_ESC'),
            ESC.replace('CHECK_NPX_ESC', 'CHECK_NPX_WAIT'),
            WAIT.replace('CHECK_NPX_WAIT', 'CHECK_NPX_ESC'),
            WAIT.replace('    CHECK_NPX_WAIT\n', ''),
            WAIT.replace('WAIT_NO_COPROCESSOR', 'OTHER'),
            ESC.replace('format 26', 'format 25'),
            WAIT.replace('format 26', 'format 25'),
            ESC.replace('    DECODE_MODRM', 'skip:\n    DECODE_MODRM'),
        ]
        for source in bad_sources:
            with self.subTest(source=source), self.assertRaises(CompileError):
                compile_sources({'bad.mc': source})

    def test_operand_and_port_side_effects_are_rejected(self):
        for source in (ESC, WAIT):
            for operation in ('READ_RM16 -> TMP0', 'WRITE_RM16 TMP0',
                              'FETCH_PORT DECODED -> TMP1', 'IO_READ16 TMP1 -> TMP0',
                              'IO_WRITE16 TMP1 TMP0', 'TMP0 -> DST', 'COMMIT_FLAGS'):
                with self.subTest(operation=operation), self.assertRaises(CompileError):
                    compile_sources({'bad.mc': source.replace('    END', f'    {operation}\n    END')})
