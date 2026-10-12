# SPDX-License-Identifier: MIT
"""The state adapter validates initialization/fetch, never instruction execution."""

import unittest

from tools.singlestep import SingleStepCase, load_source
from tools.state_vectors import prepare_initial, expected_snapshot, serialize_initial


class StateVectorTests(unittest.TestCase):
    def test_phase0_fixture_uses_normal_cs_reload(self):
        case = load_source("tests/fixtures/singlestep_sample.json")[0]
        state = prepare_initial(case)
        snapshot = expected_snapshot(state)
        self.assertEqual(snapshot["fetch_address"], 0x0FFFF0)
        self.assertEqual(snapshot["bases"], [0, 0x0F0000, 0, 0])
        self.assertEqual(snapshot["fetch_data"], 0xF490)
        self.assertEqual(snapshot["regs"]["ip"], 0xFFF0)
        self.assertEqual(snapshot["instructions_executed"], 0)
        self.assertIn("REG cs 61440\n", serialize_initial(state))

    def test_high_memory_odd_fetch(self):
        case = SingleStepCase.from_mapping({
            "initial": {"regs": {"cs": 0xFFFF, "ip": 0x11}, "ram": [[0x100001, 0xA5]]}
        })
        snapshot = expected_snapshot(prepare_initial(case))
        self.assertEqual(snapshot["fetch_address"], 0x100001)
        self.assertEqual(snapshot["fetch_count"], 1)
        self.assertEqual(snapshot["fetch_data"], 0xA5)

    def test_rejects_unsupported_or_invalid_state(self):
        bad_initials = [
            {"regs": {"eax": 0}},
            {"regs": {"ax": 65536}},
            {"regs": {"flags": 0}},
            {"regs": {}, "queue": [1]},
            {"regs": {}, "ram": [[0x1000000, 1]]},
            {"regs": {}, "ram": [[0, 256]]},
        ]
        for initial in bad_initials:
            with self.subTest(initial=initial), self.assertRaises(ValueError):
                prepare_initial(SingleStepCase.from_mapping({"initial": initial}))

    def test_requires_declared_first_fetch_bytes(self):
        with self.assertRaises(ValueError):
            prepare_initial(SingleStepCase.from_mapping({"initial": {"regs": {}}}))


if __name__ == "__main__":
    unittest.main()
