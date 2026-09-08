"""Hand-derived boundary examples constrain the independent closed-form oracle."""
import unittest
from tools.shift_reference import evaluate


class ShiftReferenceTests(unittest.TestCase):
    def test_wraps_through_carry_and_masks_count(self):
        self.assertEqual(evaluate(2, 8, 0x80, 1, 1), (1, 0x801, 0x801, True))
        self.assertEqual(evaluate(3, 8, 1, 1, 1), (0x80, 0x801, 0x801, True))
        self.assertEqual(evaluate(2, 8, 0x80, 9, 1), (0x80, 1, 0x801, True))
        self.assertEqual(evaluate(7, 16, 0x8000, 31, 0), (0xffff, 0x85, 0x8c5, True))
        self.assertEqual(evaluate(4, 8, 0x66, 5, 0), (0xc0, 0x884, 0x8c5, True))
        for kind in (0, 1, 2, 3, 4, 5, 7):
            for width in (8, 16):
                self.assertEqual(evaluate(kind, width, 0x1234, 32, 1), (0x1234 % 2**width, 0, 0, False))
                self.assertEqual(evaluate(kind, width, 0x1234, 255, 1), evaluate(kind, width, 0x1234, 31, 1))
