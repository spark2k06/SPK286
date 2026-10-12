# SPDX-License-Identifier: MIT
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from tools.microcode.compile_microcode import CompileError, ROOT, compile_sources, emit, generate
from tools.microcode.audit_microcode import canonical_source, read_generated_words, validate_entries

SOURCE = "microcode_format 1\ninstruction MOV_R16_IMM16:\nFETCH_IMM16 -> TMP0\nwriteback:\nTMP0 -> DST\nEND\n"


class MicrocodeAuditTests(unittest.TestCase):
    def test_fixed_phase2_75_contract(self):
        contract = json.loads((ROOT / "tests/fixtures/microcode_phase2_75.json").read_text())
        # Preserve the historical contract independently of the active ISA source.
        source = {"data_move.mc": SOURCE}
        program = compile_sources(source)
        artifacts = generate(program)
        validate_entries(program, contract["entries"])
        self.assertEqual(program.entries, contract["entries"])
        self.assertEqual(program.labels, contract["labels"])
        self.assertEqual(program.address_width, contract["address_width"])
        self.assertEqual(list(read_generated_words(artifacts["spk286_microcode_pkg.sv"],
                                                  artifacts["spk286_microcode_rom.sv"])), contract["words"])

    def test_shifted_entry_rejected_with_source_location(self):
        # Previously accepted layout: regenerating alone cannot detect ABI drift.
        program = compile_sources({"a.mc": "microcode_format 1\ninstruction EARLIER:\nEND\n", "b.mc": SOURCE})
        with self.assertRaisesRegex(CompileError, r"b.mc:3: instruction MOV_R16_IMM16:.*moved: expected 0, got 1"):
            validate_entries(program, {"MOV_R16_IMM16": 0})

    def test_missing_required_entry(self):
        with self.assertRaisesRegex(CompileError, "missing required entry MOV_R16_IMM16"):
            validate_entries(compile_sources({"a.mc": SOURCE.replace("MOV_R16_IMM16", "RENAMED")}),
                             {"MOV_R16_IMM16": 0})

    def test_canonical_roundtrip_with_entries_labels_and_padding(self):
        source = SOURCE + "instruction SECOND:\nstart:\nFETCH_IMM16 -> TMP0\nTMP0 -> DST\nEND\n"
        original = compile_sources({"a.mc": source}, rom_depth=8)
        artifacts = generate(original)
        words = read_generated_words(artifacts["spk286_microcode_pkg.sv"], artifacts["spk286_microcode_rom.sv"])
        canonical = canonical_source(words, original.entries, original.labels)
        reconstructed = compile_sources({"canonical.mc": canonical}, rom_depth=8)
        rebuilt = generate(reconstructed)
        self.assertEqual(words, read_generated_words(rebuilt["spk286_microcode_pkg.sv"], rebuilt["spk286_microcode_rom.sv"]))
        self.assertEqual(original.entries, reconstructed.entries)
        self.assertEqual(original.labels, reconstructed.labels)
        self.assertEqual(canonical_source(words, reconstructed.entries, reconstructed.labels), canonical)

    def test_canonical_rejects_invalid_words(self):
        for words in ([], [0], [1, 0, 3], [1, 63, 3], [True, 2, 3]):
            with self.assertRaisesRegex(ValueError, "invalid"):
                canonical_source(words, {"MOV": 0})

    def test_canonical_rejects_invalid_entries(self):
        for entries in ({}, {"MOV": 1}, {"MOV": 0, "OTHER": 0}, {"MOV": 0, "OTHER": 2},
                        {"MOV": 3}, {"bad": 0}, {"MOV": -1}):
            with self.assertRaises(ValueError):
                canonical_source([1, 2, 3], entries)

    def test_canonical_rejects_invalid_labels(self):
        for labels in ({"OTHER.local": 0}, {"MOV.Bad": 0}, {"MOV.local": 3},
                       {"MOV.local": -1}, {"MOV.local": 1.5}):
            with self.assertRaisesRegex(ValueError, "invalid label"):
                canonical_source([1, 2, 3], {"MOV": 0}, labels)
        with self.assertRaisesRegex(ValueError, "outside its entry"):
            canonical_source([3, 3], {"FIRST": 0, "SECOND": 1}, {"FIRST.local": 1})

    def test_canonical_preserves_semantic_validation(self):
        for words, message in (([2, 3], "TMP0 read before"), ([1, 2], "missing END"),
                               ([3, 1, 3], "missing entry after END")):
            with self.assertRaisesRegex(ValueError, message):
                canonical_source(words, {"MOV": 0})

    def test_generated_rom_duplicate_range_encoding_failures(self):
        artifacts = generate(compile_sources({"a.mc": SOURCE}))
        package, rom = artifacts["spk286_microcode_pkg.sv"], artifacts["spk286_microcode_rom.sv"]
        for damaged, message in ((rom.replace("2'd1:", "2'd0:"), "duplicate ROM address"),
                                 (rom.replace("2'd2:", "2'd3:"), "out of range"),
                                 (rom.replace("MC_MOVE;", "MC_INVALID;"), "invalid ROM operation"),
                                 (rom.replace("2'd0:", "3'd0:"), "wrong width")):
            with self.assertRaisesRegex(ValueError, message):
                read_generated_words(package, damaged)
        with self.assertRaisesRegex(ValueError, "unexpected encoding"):
            read_generated_words(package.replace("MC_END = 2'd3", "MC_END = 2'd2"), rom)

    def test_source_coupling_includes_comments(self):
        first = generate(compile_sources({"a.mc": SOURCE}))
        second = generate(compile_sources({"a.mc": SOURCE+"# provenance change\n"}))
        self.assertEqual(first["spk286_microcode_rom.sv"], second["spk286_microcode_rom.sv"])
        self.assertNotEqual(first["spk286_microcode_validation.json"], second["spk286_microcode_validation.json"])
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stderr(io.StringIO()):
            emit(first, Path(folder), check=False)
            self.assertFalse(emit(second, Path(folder), check=True))

    def test_cross_process_generation_and_newline_normalization(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            sources = root / "source"
            sources.mkdir()
            hashes = []
            for seed, newline in (("1", "\n"), ("286", "\r\n")):
                (sources / "a.mc").write_bytes(SOURCE.replace("\n", newline).encode())
                output = root / seed
                result = subprocess.run([sys.executable, "-m", "tools.microcode.compile_microcode",
                                         "--source-dir", str(sources), "--output-dir", str(output)],
                                        cwd=ROOT, env={**os.environ, "PYTHONHASHSEED": seed}, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                hashes.append({p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in output.iterdir()})
            self.assertEqual(*hashes)

    def test_negative_cli_boundaries_preserve_outputs(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)/"out"
            output.mkdir()
            sentinel = output/"sentinel"
            sentinel.write_bytes(b"keep")
            for options, message in ((["--lookup", "MOV_R16_IMM16.missing"], "unresolved symbol"),
                                     (["--rom-depth", "2"], "ROM overflow"),
                                     (["--address-width", "1"], "address-width overflow")):
                result = subprocess.run([sys.executable, "-m", "tools.microcode.compile_microcode",
                                         "--output-dir", str(output), *options], cwd=ROOT, capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertIn(message, result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertEqual(list(output.iterdir()), [sentinel])
                self.assertEqual(sentinel.read_bytes(), b"keep")


if __name__ == "__main__":
    unittest.main()
