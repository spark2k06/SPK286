import json
import unittest

from tools.microcode.compile_microcode import ROOT, CompileError, compile_sources, encode, generate
from tools.microcode.audit_microcode import canonical_source, read_generated_words


class SystemAccessMicrocodeTests(unittest.TestCase):
    def test_frozen_h01_rom_adds_only_the_eight_documented_checks(self):
        old = json.loads((ROOT / 'tests/fixtures/microcode_immediate_execution.json').read_text())
        additions = {
            'SYSTEM_STORE_LDTR': (0, 193), 'SYSTEM_STORE_TR': (0, 193),
            'SYSTEM_LOAD_LDTR': (0, 194), 'SYSTEM_LOAD_TR': (0, 194),
            'SYSTEM_VERIFY_READ': (0, 193), 'SYSTEM_VERIFY_WRITE': (0, 193),
            'SYSTEM_LOAD_ACCESS': (1, 193), 'SYSTEM_LOAD_LIMIT': (1, 193),
        }
        expected_words, expected_entries = [], {}
        entries = sorted(old['entries'].items(), key=lambda item: item[1])
        for index, (name, address) in enumerate(entries):
            expected_entries[name] = len(expected_words)
            end = entries[index + 1][1] if index + 1 < len(entries) else len(old['words'])
            body = old['words'][address:end].copy()
            if name in additions:
                offset, code = additions[name]
                body.insert(offset, code)
            expected_words.extend(body)
        frozen = json.loads((ROOT / 'tests/fixtures/microcode_system_access.json').read_text())
        program = compile_sources({'format24.mc': canonical_source(frozen['words'], frozen['entries'],
                    frozen['labels'], {int(k): v for k, v in frozen['branch_targets'].items()})})
        self.assertEqual([encode(op) for op in program.operations], expected_words)
        self.assertEqual(program.entries, expected_entries)
        self.assertEqual(frozen['words'], expected_words)
        self.assertEqual(frozen['entries'], expected_entries)
        generated = generate(program)
        words = read_generated_words(generated['spk286_microcode_pkg.sv'], generated['spk286_microcode_rom.sv'])
        rebuilt = compile_sources({'canonical.mc': canonical_source(words, program.entries, program.labels, program.branch_targets)})
        self.assertEqual([encode(op) for op in rebuilt.operations], expected_words)

    def test_protected_store_checks_mode_before_access(self):
        program = compile_sources({"test.mc": """microcode_format 24
instruction SYSTEM_STORE_LDTR:
    CHECK_PROTECTED_MODE
    SYSTEM_STORE_LDTR
    END
"""})
        self.assertEqual([encode(op) for op in program.operations], [193, 142, 3])

    def test_privileged_load_checks_before_read_and_commit(self):
        for instruction, operation in (("SYSTEM_LOAD_LDTR", 144), ("SYSTEM_LOAD_TR", 145)):
            with self.subTest(instruction=instruction):
                source = f"microcode_format 24\ninstruction {instruction}:\nCHECK_SYSTEM_PRIVILEGE\nREAD_RM16 -> TMP0\n{instruction}\nEND\n"
                program = compile_sources({"test.mc": source})
                self.assertEqual([encode(op) for op in program.operations], [194, 6, operation, 3])

    def test_missing_late_or_wrong_check_is_rejected(self):
        bodies = (
            "READ_RM16 -> TMP0\nSYSTEM_LOAD_TR\nEND",
            "READ_RM16 -> TMP0\nCHECK_SYSTEM_PRIVILEGE\nSYSTEM_LOAD_TR\nEND",
            "CHECK_PROTECTED_MODE\nREAD_RM16 -> TMP0\nSYSTEM_LOAD_TR\nEND",
        )
        for body in bodies:
            with self.subTest(body=body), self.assertRaises(CompileError):
                compile_sources({"test.mc": "microcode_format 24\ninstruction SYSTEM_LOAD_TR:\n" + body + "\n"})

    def test_inspection_decodes_then_checks_before_operand_read(self):
        source = "microcode_format 24\ninstruction SYSTEM_LOAD_ACCESS:\nDECODE_MODRM\nCHECK_PROTECTED_MODE\nREAD_RM16 -> TMP0\nSYSTEM_LOAD_ACCESS\nEND\n"
        program = compile_sources({"test.mc": source})
        self.assertEqual([encode(op) for op in program.operations], [4, 193, 6, 148, 3])
        with self.assertRaises(CompileError):
            compile_sources({"bad.mc": source.replace("CHECK_PROTECTED_MODE\n", "")})

    def test_new_controls_round_trip_without_changing_old_format(self):
        source = "microcode_format 24\ninstruction SYSTEM_LOAD_TR:\nCHECK_SYSTEM_PRIVILEGE\nREAD_RM16 -> TMP0\nSYSTEM_LOAD_TR\nEND\n"
        program = compile_sources({"test.mc": source})
        generated = generate(program)
        words = read_generated_words(generated["spk286_microcode_pkg.sv"], generated["spk286_microcode_rom.sv"])
        rebuilt = compile_sources({"canonical.mc": canonical_source(words, program.entries)})
        self.assertEqual([encode(op) for op in rebuilt.operations], list(words))
        legacy = source.replace("format 24", "format 17").replace("CHECK_SYSTEM_PRIVILEGE\n", "")
        self.assertEqual([encode(op) for op in compile_sources({"legacy.mc": legacy}).operations], [6, 145, 3])
