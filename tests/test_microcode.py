"""Independent compiler/ROM contract tests; no RTL simulator required."""

import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from tools.microcode.compile_microcode import (
    CompileError, ROOT, compile_sources, describe_pc, emit, encode, generate, resolve_symbol,
)

SOURCE = """microcode_format 1
instruction MOV_R16_IMM16:
    FETCH_IMM16 -> TMP0
writeback:
    TMP0 -> DST
    END
"""


class MicrocodeTests(unittest.TestCase):
    def compile(self, source=SOURCE, **options):
        return compile_sources({"data_move.mc": source}, **options)

    def reject(self, source, message, **options):
        with self.assertRaisesRegex(CompileError, message) as result:
            self.compile(source, **options)
        self.assertIn("data_move.mc:", str(result.exception))

    def test_minimal_instruction(self):
        program = self.compile()
        self.assertEqual([op.operation for op in program.operations], ["FETCH_IMM16", "MOVE", "END"])
        self.assertEqual(program.operations[1].operands, ("TMP0", "DST"))
        self.assertEqual((program.depth, program.address_width), (3, 2))

    def test_entry_and_local_label(self):
        program = self.compile()
        entry = resolve_symbol(program, "MOV_R16_IMM16")
        label = resolve_symbol(program, "MOV_R16_IMM16.writeback")
        self.assertEqual(program.operations[entry].operation, "FETCH_IMM16")
        self.assertEqual(program.operations[label].operation, "MOVE")
        self.assertLess(entry, label)
        self.assertIn("MC_ENTRY_MOV_R16_IMM16", generate(program)["spk286_microcode_pkg.sv"])

    def test_source_mapping(self):
        program = self.compile()
        mapping = json.loads(generate(program)["spk286_microcode_symbols.json"])
        move = mapping["operations"][resolve_symbol(program, "MOV_R16_IMM16.writeback")]
        self.assertEqual(move["location"], {"file": "data_move.mc", "line": 5, "entry": "MOV_R16_IMM16"})
        self.assertEqual(move["statement"], "TMP0 -> DST")
        self.assertEqual(move["operands"], ["TMP0", "DST"])

    def test_numeric_pc_diagnostic(self):
        program = self.compile()
        description = describe_pc(program, resolve_symbol(program, "MOV_R16_IMM16.writeback"))
        self.assertIn("data_move.mc:5: instruction MOV_R16_IMM16: TMP0 -> DST", description)

    def test_unmapped_pc_diagnostic(self):
        for address in (-1, 3, 4096):
            with self.assertRaisesRegex(CompileError, "unmapped micro-PC"):
                describe_pc(self.compile(), address)

    def test_deterministic_output_and_source_order(self):
        other = SOURCE.replace("MOV_R16_IMM16", "SECOND")
        first = compile_sources({"z.mc": other, "a.mc": SOURCE})
        second = compile_sources({"a.mc": SOURCE, "z.mc": other})
        self.assertEqual(generate(first), generate(second))
        self.assertLess(first.entries["MOV_R16_IMM16"], first.entries["SECOND"])

    def test_known_encoding_and_unique_addresses(self):
        program = self.compile()
        self.assertEqual([encode(op) for op in program.operations], [1, 2, 3])
        addresses = [op.address for op in program.operations]
        self.assertEqual(addresses, list(range(len(program.operations))))
        self.assertTrue(all(0 <= a < program.depth for a in program.entries.values()))
        rom = generate(program)["spk286_microcode_rom.sv"]
        for op in program.operations:
            self.assertIn(f"{program.address_width}'d{op.address}: word = spk286_microcode_pkg::MC_{op.operation};", rom)
        self.assertIn("default: valid = 1'b0", rom)

    def test_metadata(self):
        report = json.loads(generate(self.compile())["spk286_microcode_validation.json"])
        self.assertEqual(report["validation"], "PASS")
        self.assertEqual((report["used_words"], report["unused_words"]), (3, 0))
        self.assertIsNone(report["timing_metadata"])
        self.assertEqual(len(report["source_sha256"]["data_move.mc"]), 64)

    def test_generation_check_detects_stale_and_missing_without_writes(self):
        artifacts = generate(self.compile())
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stderr(io.StringIO()):
            root = Path(folder)
            self.assertFalse(emit(artifacts, root, check=True))
            self.assertEqual(list(root.iterdir()), [])
            self.assertTrue(emit(artifacts, root, check=False))
            self.assertTrue(emit(artifacts, root, check=True))
            for name in artifacts:
                with self.subTest(name=name):
                    path = root / name
                    path.write_bytes(b"stale")
                    self.assertFalse(emit(artifacts, root, check=True))
                    self.assertEqual(path.read_bytes(), b"stale")
                    self.assertTrue(emit(artifacts, root, check=False))
                    self.assertTrue(emit(artifacts, root, check=True))

    def test_check_preserves_modification_times(self):
        artifacts = generate(self.compile())
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            emit(artifacts, root, check=False)
            before = {p.name: p.stat().st_mtime_ns for p in root.iterdir()}
            emit(artifacts, root, check=False)
            self.assertEqual(before, {p.name: p.stat().st_mtime_ns for p in root.iterdir()})

    def test_invalid_operand(self):
        self.reject(SOURCE.replace("FETCH_IMM16 -> TMP0", "FETCH_IMM16 -> TMP9"), "line|invalid FETCH_IMM16 operand TMP9")

    def test_invalid_transfer(self):
        self.reject(SOURCE.replace("TMP0 -> DST", "TMP0 -> AX"), "invalid transfer operands")

    def test_unknown_operation(self):
        self.reject(SOURCE.replace("FETCH_IMM16 -> TMP0", "READ_RM16 TMP0"), "unknown or malformed micro-operation")

    def test_malformed_declaration(self):
        self.reject(SOURCE.replace("instruction MOV_R16_IMM16:", "instruction MOV_R16_IMM16"), "malformed instruction")

    def test_duplicate_entry(self):
        self.reject(SOURCE + SOURCE.split("\n", 1)[1], "duplicate instruction entry")

    def test_duplicate_label(self):
        self.reject(SOURCE.replace("writeback:", "writeback:\nwriteback:"), "duplicate label")

    def test_unresolved_debug_symbol(self):
        with self.assertRaisesRegex(CompileError, "unresolved symbol"):
            resolve_symbol(self.compile(), "MOV_R16_IMM16.missing")

    def test_label_must_name_operation(self):
        self.reject(SOURCE + "orphan:\n", "has no operation")

    def test_missing_end(self):
        self.reject(SOURCE.replace("    END\n", ""), "missing END")

    def test_unreachable_operation(self):
        self.reject(SOURCE + "    END\n", "unreachable statement after END")

    def test_temporary_read_before_definition(self):
        self.reject(SOURCE.replace("    FETCH_IMM16 -> TMP0\n", ""), "TMP0 read before")

    def test_format_version(self):
        for version in ("0", "24", "x", "1 extra"):
            with self.subTest(version=version):
                self.reject(SOURCE.replace("microcode_format 1", f"microcode_format {version}"), "expected microcode_format 1")

    def test_rom_overflow(self):
        self.reject(SOURCE, "ROM overflow", rom_depth=2)

    def test_address_overflow(self):
        self.reject(SOURCE, "address-width overflow", address_width=1)

    def test_configuration_ranges(self):
        for width in (0, -1, 13):
            self.reject(SOURCE, "address width must", address_width=width)
        self.reject(SOURCE, "ROM depth must be positive", rom_depth=0)

    def test_empty_and_outside_instruction(self):
        self.reject("", "source requires")
        self.reject("microcode_format 1\nEND", "outside an instruction")
        with self.assertRaisesRegex(CompileError, "no .mc sources"):
            compile_sources({})

    def test_absolute_path_rejected(self):
        with self.assertRaisesRegex(CompileError, "relative POSIX path"):
            compile_sources({"/host/data_move.mc": SOURCE})

    def test_comments_and_blank_lines(self):
        source = "# comment\n\n" + SOURCE.replace("END", "END # done")
        self.assertEqual([encode(op) for op in self.compile(source).operations], [1, 2, 3])

    def test_branches_and_timing_syntax_are_rejected(self):
        for statement in ("GOTO writeback", "IF_ZERO TMP0, writeback", "NOP", "TIMING 2"):
            self.reject(SOURCE.replace("TMP0 -> DST", statement), "unknown or malformed")

    def test_cli_diagnostics_have_location_without_traceback(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / "bad.mc").write_text(SOURCE.replace("TMP0 -> DST", "TMP9 -> DST"))
            result = subprocess.run([sys.executable, "-m", "tools.microcode.compile_microcode",
                                     "--source-dir", folder, "--output-dir", str(path / "out")],
                                    cwd=ROOT, capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 2)
            self.assertIn("bad.mc:5: instruction MOV_R16_IMM16:", result.stderr)
            self.assertNotIn("Traceback", result.stderr)
            self.assertFalse((path / "out").exists())

    def test_checked_in_source_and_artifacts(self):
        sources = {p.name: p.read_text(encoding="utf-8") for p in (ROOT / "microcode/source").glob("*.mc")}
        self.assertTrue(emit(generate(compile_sources(sources)), ROOT / "microcode/generated", check=True))


if __name__ == "__main__":
    unittest.main()
