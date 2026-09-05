from __future__ import annotations

import json
from pathlib import Path
import struct
import tempfile
import unittest

from tools.singlestep import (
    SingleStepFormatError,
    is_revoked,
    load_json,
    load_moo,
    load_revocation_list,
)


ROOT = Path(__file__).resolve().parents[1]


def chunk(name: str, payload: bytes) -> bytes:
    return name.encode("ascii") + struct.pack("<I", len(payload)) + payload


def regs(values: list[int], mask: int) -> bytes:
    return struct.pack("<H", mask) + b"".join(struct.pack("<H", value) for value in values)


class SingleStepReaderTests(unittest.TestCase):
    def test_checked_in_json_fixture(self) -> None:
        cases = load_json(ROOT / "tests" / "fixtures" / "singlestep_sample.json")
        self.assertEqual(len(cases), 1)
        self.assertEqual(cases[0].index, 0)
        self.assertEqual(cases[0].instruction_bytes, (0x90, 0xF4))
        self.assertEqual(cases[0].initial["regs"]["cs"], 0xF000)
        self.assertEqual(cases[0].cycles[0][5], "CODE")

    def test_moo_reader_normalizes_common_chunks(self) -> None:
        initial_regs = regs([0x0001, 0xF000, 0xFFF0], (1 << 0) | (1 << 4) | (1 << 12))
        final_regs = regs([0xFFF2], 1 << 12)
        initial = chunk(
            "INIT",
            chunk("REGS", initial_regs) + chunk("RAM ", struct.pack("<IIB", 1, 0xFFFFF0, 0x90)),
        )
        final = chunk("FINA", chunk("REGS", final_regs))
        test = chunk(
            "TEST",
            struct.pack("<I", 7)
            + chunk("NAME", struct.pack("<I", 5) + b"smoke")
            + chunk("BYTS", struct.pack("<I", 2) + bytes([0x90, 0xF4]))
            + initial
            + final
            + chunk("HASH", bytes.fromhex("11" * 20)),
        )
        moo_header = chunk("MOO ", bytes([1, 1, 0, 0]) + struct.pack("<I", 1) + b"C286")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "sample.moo"
            path.write_bytes(moo_header + test)
            parsed = load_moo(path)
        self.assertEqual(parsed.header["cpu_id"], "C286")
        self.assertEqual(parsed.header["test_count"], 1)
        self.assertEqual(len(parsed.tests), 1)
        self.assertEqual(parsed.tests[0].index, 7)
        self.assertEqual(parsed.tests[0].name, "smoke")
        self.assertEqual(parsed.tests[0].test_hash, "11" * 20)
        self.assertEqual(parsed.tests[0].initial["ram"], [[0xFFFFF0, 0x90]])

    def test_revocation_hashes_are_preserved(self) -> None:
        cases = load_json(ROOT / "tests" / "fixtures" / "singlestep_sample.json")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "revocation_list.txt"
            path.write_text("# comment\n" + "0" * 40 + "\n", encoding="ascii")
            revoked = load_revocation_list(path)
        self.assertTrue(is_revoked(cases[0], revoked))

    def test_malformed_moo_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.moo"
            path.write_bytes(b"MOO ")
            with self.assertRaises(SingleStepFormatError):
                load_moo(path)


if __name__ == "__main__":
    unittest.main()
