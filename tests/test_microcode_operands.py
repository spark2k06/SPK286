# SPDX-License-Identifier: MIT
"""Format-2 operand ordering, versioning and independent phase contract."""
import json
import unittest
from tools.microcode.compile_microcode import CompileError, ROOT, compile_sources, generate, encode
from tools.microcode.audit_microcode import canonical_source, read_generated_words, validate_entries

READ = "microcode_format 2\ninstruction MOV_R16_RM16:\nDECODE_MODRM\nREAD_RM16 -> TMP0\nTMP0 -> REG16\nEND\n"
WRITE = READ.replace("MOV_R16_RM16", "MOV_RM16_R16").replace("READ_RM16", "READ_REG16").replace("-> REG16", "-> RM16")

class OperandMicrocodeTests(unittest.TestCase):
    def test_both_logical_directions(self):
        for source, words in ((READ, [4, 6, 7, 3]), (WRITE, [4, 5, 8, 3])):
            p = compile_sources({"a.mc": source})
            self.assertEqual([encode(op) for op in p.operations], words)
            self.assertEqual((p.format_version, p.word_width), (2, 4))
            canonical = canonical_source(words, p.entries)
            self.assertEqual([encode(op) for op in compile_sources({"b.mc": canonical}).operations], words)

    def test_operand_context_and_temporary_lifetime(self):
        for source, reason in (
            (READ.replace("DECODE_MODRM\n", ""), "before DECODE_MODRM"),
            (READ.replace("READ_RM16 -> TMP0\n", ""), "TMP0 read before"),
            (READ.replace("READ_RM16 -> TMP0", "READ_RM16 -> TMP1"), "invalid READ_RM16 operand"),
            (WRITE.replace("TMP0 -> RM16", "TMP1 -> RM16"), "invalid WRITE_RM16 operand"),
            (READ.replace("DECODE_MODRM", "DECODE_MODRM\nDECODE_MODRM"), "more than once"),
            (READ.replace("microcode_format 2", "microcode_format 1"), "require microcode_format 2"),
        ):
            with self.subTest(reason=reason), self.assertRaisesRegex(CompileError, reason):
                compile_sources({"bad.mc": source})

    def test_current_contract_and_rom_roundtrip(self):
        contract = json.loads((ROOT / "tests/fixtures/microcode_phase3.json").read_text())
        p = compile_sources({"data_move.mc": (ROOT / "tests/fixtures/microcode_phase3.mc").read_text()})
        a = generate(p)
        validate_entries(p, contract["entries"])
        words = read_generated_words(a["spk286_microcode_pkg.sv"], a["spk286_microcode_rom.sv"])
        self.assertEqual(list(words), contract["words"])
        self.assertEqual(p.entries, contract["entries"])
        self.assertEqual(p.labels, contract["labels"])
        self.assertEqual(p.address_width, contract["address_width"])
        metadata = json.loads(a["spk286_microcode_validation.json"])
        for field in ("format_version", "encoding_version", "word_width"):
            self.assertEqual(metadata[field],contract[field])
        p2 = compile_sources({"canonical.mc": canonical_source(words, p.entries, p.labels)})
        self.assertEqual([encode(op) for op in p2.operations], list(words))
        self.assertEqual(p2.entries, p.entries)
        self.assertEqual(p2.labels, p.labels)

    def test_corrupt_operand_encoding_is_rejected(self):
        a = generate(compile_sources({"a.mc": READ}))
        with self.assertRaisesRegex(ValueError, "unexpected encoding"):
            read_generated_words(a["spk286_microcode_pkg.sv"].replace("MC_READ_RM16 = 4'd6", "MC_READ_RM16 = 4'd5"),
                                 a["spk286_microcode_rom.sv"])
