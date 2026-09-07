import os
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import contextlib
import io
import json

from research.mcl86.fetch_references import ROOT, verified_references
from research.mcl86.mcl86_ucasm import FormatError, assemble, mem_bytes, read_mem
from research.mcl86.mcl86_ucdis import disassemble
from research.mcl86.mcl86_uccheck import check, differences


def transaction(address="0000", high="1234", low="5678", target="00001"):
    return (f"p 00 00000 {target} {address}\n"
            f"p 01 00000 {target} {high}\n"
            f"p 01 00000 {target} {low}\n")


class Mcl86Tests(unittest.TestCase):
    def reject(self, source, message):
        with self.assertRaisesRegex(FormatError, message) as error:
            assemble(source, "bad.txt")
        self.assertRegex(str(error.exception), r"bad.txt:[0-9]+:")

    def test_half_order_and_hex_address(self):
        result = assemble(transaction("000A"))
        self.assertEqual(result.words[10], 0x12345678)
        self.assertEqual(result.addresses, (10,))

    def test_holes_and_last_address(self):
        result = assemble(transaction("0FFF", "FFFF", "FFFF"))
        self.assertEqual(result.words, (0,)*4095+(0xffffffff,))

    def test_unordered_addresses(self):
        a, b = transaction("000A"), transaction("0000", "ABCD", "0123")
        self.assertEqual(assemble(a+b).words, assemble(b+a).words)

    def test_control_address_space_is_separate(self):
        source = transaction("0001", "0000", "000F", "00010")
        source += transaction("0001") + transaction("0001", "0000", "0000", "00010")
        result = assemble(source)
        self.assertEqual(result.words[1], 0x12345678)
        self.assertEqual(result.controls, ((1, 15), (1, 0)))

    def test_comments_separators_and_transport_directives(self):
        source = "// header\n# note\n----\nd 20\n" + transaction().replace("1234", "1234 // high")
        result = assemble(source+"d 1000\nx\n# end\n")
        self.assertEqual(result.delays, ("20", "1000"))
        self.assertEqual(result.words[0], 0x12345678)

    def test_duplicate_even_identical_word_rejected(self):
        self.reject(transaction()+transaction(), "duplicate ROM address.*first assigned at line 1")

    def test_address_overflow(self):
        self.reject(transaction("1000"), "out of range")

    def test_incomplete_words(self):
        for source in ("p 00 00000 00001 0000\n", "p 00 00000 00001 0000\np 01 00000 00001 1234\n"):
            self.reject(source, "incomplete word")
            self.reject(source+transaction("0001"), "incomplete word")
            self.reject(source+"d 20\n", "incomplete word")
            self.reject(source+"x\n", "incomplete word")

    def test_orphan_or_extra_half(self):
        self.reject("p 01 00000 00001 0000", "without an address")
        self.reject(transaction()+"p 01 00000 00001 0000", "without an address")

    def test_target_mismatch(self):
        self.reject(transaction().replace("p 01 00000 00001", "p 01 00000 00010", 1), "target changed")

    def test_invalid_directives_are_never_ignored(self):
        for directive in ("z", "p 02 00000 00001 0000", "p 00 00001 00001 0000",
                          "p 00 00000 00011 0000", "d -1", "d 20 extra", "x extra"):
            self.reject(transaction()+directive, "invalid directive")

    def test_invalid_halves(self):
        for word in ("12345", "-001", "XX00", "0x01", "123", "1234 extra"):
            self.reject(transaction(high=word), "invalid directive")

    def test_after_exit_and_empty(self):
        self.reject(transaction()+"x\nd 20", "after x")
        self.reject("# empty\nx", "no ROM words")

    def test_mem_size(self):
        for count in (0, 4095, 4097):
            with self.assertRaisesRegex(FormatError, "ROM size"):
                read_mem("00000000\n"*count)

    def test_mem_word_width_and_unknown_bits(self):
        for token in ("0", "100000000", "xxxx0000", "zzzzzzzz", "-0000001", "@0000000", "00000000;"):
            with self.assertRaisesRegex(FormatError, "reference.mem:1: invalid 32-bit word"):
                read_mem(token+"\n"+"00000000\n"*4095, "reference.mem")

    def test_dense_mem_whitespace_comments_and_canonical_bytes(self):
        words = read_mem("// header\n"+"ABCDEF01 "*4096+"# end")
        self.assertEqual(mem_bytes(words), b"abcdef01\n"*4096)

    def test_output_rejects_invalid_word_values(self):
        for value in (-1, 1 << 32, True, "0"):
            with self.assertRaisesRegex(FormatError, "invalid 32-bit word"):
                mem_bytes([value]+[0]*4095)

    def test_roundtrip_arbitrary_bits_and_edges(self):
        generator = random.Random(286)
        words = tuple([0, 0xffffffff, 0x80000000, 1]+[generator.getrandbits(32) for _ in range(4092)])
        text = disassemble(words)
        self.assertEqual(assemble(text).words, words)
        self.assertEqual(disassemble(assemble(text).words), text)
        self.assertEqual(read_mem(mem_bytes(words).decode()), words)

    def test_difference_addresses_and_size(self):
        self.assertEqual(differences([1, 2], [1, 3]),
                         [{"address": "001", "generated": "00000002", "reference": "00000003"}])
        with self.assertRaisesRegex(ValueError, "different sizes"):
            differences([1], [])

    def test_cli_roundtrip_and_hash_seed_reproducibility(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / "source.txt"
            source.write_text(transaction("0123"))
            outputs = []
            for seed in ("1", "286"):
                output = root / f"{seed}.mem"
                result = subprocess.run([sys.executable, "-m", "research.mcl86.mcl86_ucasm", str(source), str(output)],
                                        cwd=ROOT, env={**os.environ, "PYTHONHASHSEED": seed}, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                outputs.append(output.read_bytes())
            self.assertEqual(*outputs)
            canonical = root / "canonical.txt"
            subprocess.run([sys.executable, "-m", "research.mcl86.mcl86_ucdis", str(output), str(canonical)],
                           cwd=ROOT, check=True, capture_output=True)
            self.assertEqual(mem_bytes(assemble(canonical.read_text()).words), outputs[0])

    def test_cli_error_has_location_and_no_output(self):
        with tempfile.TemporaryDirectory() as folder:
            source, output = Path(folder)/"bad.txt", Path(folder)/"out.mem"
            source.write_text(transaction()+transaction())
            result = subprocess.run([sys.executable, "-m", "research.mcl86.mcl86_ucasm", str(source), str(output)],
                                    cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("bad.txt:4: duplicate", result.stderr)
            self.assertNotIn("Traceback", result.stderr)
            self.assertFalse(output.exists())

    def test_reference_hash_and_missing_file_fail_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with self.assertRaisesRegex(ValueError, "missing.*make mcl86-fetch"):
                verified_references(root)
            # The manifest's first filename is tested without changing the cache.
            manifest = json.loads((ROOT / "research/mcl86/sources.json").read_text())
            (root / manifest["files"][0]["name"]).write_bytes(b"corrupted reference")
            with self.assertRaisesRegex(ValueError, "reference hash mismatch"):
                verified_references(root)

    def test_checker_reports_real_comparison_and_roundtrip(self):
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stdout(io.StringIO()):
            root = Path(folder)
            words = assemble(transaction()).words
            (root / "Microcode_MCL86.txt").write_text(transaction())
            (root / "MCL86_Microcode_Xilinx_Version_4.coe").write_bytes(mem_bytes(words))
            changed = list(words)
            changed[7] = 1
            (root / "mcl86_ucode.mem").write_bytes(mem_bytes(changed))
            # Synthetic checker inputs have no relationship to the pinned oracle.
            with patch("research.mcl86.mcl86_uccheck.verified_references", return_value={"files": []}):
                report = check(root, root / "out")
            self.assertEqual(report["original_differences"], [])
            self.assertEqual(report["rewrite_differences"], differences(words, changed))
            self.assertEqual(report["roundtrip"], {"reference": "PASS", "rewrite": "PASS"})
            self.assertEqual((root / "out/reference_mcl86_ucode.mem").read_bytes(),
                             (root / "out/reference_reconstructed.mem").read_bytes())

    def test_checker_fails_original_mismatch_without_hiding_report(self):
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stdout(io.StringIO()):
            root = Path(folder)
            (root / "Microcode_MCL86.txt").write_text(transaction())
            for name in ("MCL86_Microcode_Xilinx_Version_4.coe", "mcl86_ucode.mem"):
                (root / name).write_bytes(mem_bytes([0]*4096))
            with patch("research.mcl86.mcl86_uccheck.verified_references", return_value={"files": []}):
                with self.assertRaisesRegex(ValueError, "original reference mismatch"):
                    check(root, root / "out")
            report = json.loads((root / "out/comparison.json").read_text())
            self.assertEqual(report["original_differences"][0]["address"], "000")


if __name__ == "__main__":
    unittest.main()
