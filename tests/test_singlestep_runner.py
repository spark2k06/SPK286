# SPDX-License-Identifier: MIT
from __future__ import annotations

import unittest

from tools.run_singlestep import SingleStepRunnerError, prepare_case
from tools.singlestep import SingleStepCase


REGS = {
    "ax": 0x1111, "bx": 0x2222, "cx": 0x3333, "dx": 0x4444,
    "cs": 0x1000, "ss": 0x2000, "ds": 0x3000, "es": 0x4000,
    "sp": 0x5555, "bp": 0x6666, "si": 0x7777, "di": 0x8888,
    "ip": 0x1200, "flags": 0x0042,
}


class SingleStepPreparationTests(unittest.TestCase):
    def test_sparse_final_and_halt_ip_are_expanded(self) -> None:
        case = SingleStepCase.from_mapping({
            "idx": 1847,
            "name": "mov ax,1234h",
            "bytes": [0xB8, 0x34, 0x12, 0xF4],
            "initial": {"regs": REGS, "ram": [[0x11200, 0xB8], [0x11201, 0x34],
                                                [0x11202, 0x12], [0x11203, 0xF4]], "queue": []},
            "final": {"regs": {"ax": 0x1234, "ip": 0x1204}, "ram": [], "queue": []},
            "hash": "ab" * 20,
        })
        prepared = prepare_case(case, "B8")
        self.assertEqual(prepared.expected_regs[0], 0x1234)
        self.assertEqual(prepared.expected_regs[12], 0x1203)
        self.assertEqual(prepared.expected_regs[1], REGS["bx"])
        self.assertEqual(dict(prepared.expected_ram), dict(prepared.initial_ram))
        self.assertEqual(prepared.expected_masks[13], 0xFFFF)

    def test_reg_masks_are_preserved_for_undefined_bits(self) -> None:
        case = SingleStepCase.from_mapping({
            "bytes": [0xBF, 0x78, 0x56, 0xF4],
            "initial": {"regs": REGS, "ram": [[0x11200, 0xBF], [0x11201, 0x78],
                                                [0x11202, 0x56], [0x11203, 0xF4]]},
            "final": {
                "regs": {"di": 0x5678, "ip": 0x1204},
                "reg_masks": {"flags": 0x7FFF},
            },
        })
        prepared = prepare_case(case, "BF")
        self.assertEqual(prepared.expected_masks[13], 0x7FFF)
        self.assertEqual(prepared.expected_regs[11], 0x5678)

    def test_halt_ip_mismatch_is_rejected(self) -> None:
        case = SingleStepCase.from_mapping({
            "bytes": [0xB8, 0, 0, 0xF4],
            "initial": {"regs": REGS, "ram": []},
            "final": {"regs": {"ip": 0x1205}},
        })
        with self.assertRaises(SingleStepRunnerError):
            prepare_case(case, "B8")


if __name__ == "__main__":
    unittest.main()
