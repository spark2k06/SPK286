# SPDX-License-Identifier: MIT
import unittest
from tools.alu_reference import evaluate, EDGES, OPERATIONS


class AluReferenceTests(unittest.TestCase):
    def test_hand_derived_arithmetic(self):
        for op, a, b, c, value, flags in (
            ('ADD', 0xffff, 1, 0, 0, 0x55),
            ('ADD', 0x7fff, 1, 0, 0x8000, 0x894),
            ('ADD', 0x8000, 0x8000, 0, 0, 0x845),
            ('ADC', 0xffff, 0, 1, 0, 0x55),
            ('ADC', 0x7fff, 0x7fff, 1, 0xffff, 0x894),
            ('SUB', 0, 1, 0, 0xffff, 0x95),
            ('SUB', 0x8000, 1, 0, 0x7fff, 0x814),
            ('SUB', 0x7fff, 0xffff, 0, 0x8000, 0x885),
            ('SBB', 0, 0xffff, 1, 0, 0x55),
            ('SBB', 0x8000, 0x7fff, 1, 0, 0x854),
            ('SUB', 0x100, 1, 0, 0xff, 0x14),
        ):
            with self.subTest(op=op, a=a, b=b, c=c):
                result = evaluate(op, a, b, c)
                self.assertEqual((result.value, result.flags), (value, flags))

    def test_all_low_byte_parities(self):
        for low in range(256):
            expected = low.bit_count() % 2 == 0
            for high in (0, 1, 0x80, 0xff):
                self.assertEqual(bool(evaluate('OR', high*256+low, 0).flags & 4), expected)

    def test_properties(self):
        for a in EDGES:
            for b in EDGES:
                self.assertEqual(evaluate('ADC', a, b), evaluate('ADD', a, b))
                self.assertEqual(evaluate('SBB', a, b), evaluate('SUB', a, b))
                self.assertEqual(evaluate('CMP', a, b), evaluate('SUB', a, b))
                for op in ('ADD', 'AND', 'OR', 'XOR'):
                    self.assertEqual(evaluate(op, a, b), evaluate(op, b, a))
            self.assertEqual(evaluate('SUB', a, a).flags, 0x44)
            self.assertEqual(evaluate('XOR', a, a).value, 0)

    def test_masks_and_preservation(self):
        for op in OPERATIONS:
            result = evaluate(op, 0x800f, 0x7fff, 1)
            logical = op in ('AND', 'OR', 'XOR')
            self.assertEqual(result.update_mask, 0x8c5 if logical else 0x8d5)
            self.assertEqual(result.undefined_mask, 16 if logical else 0)
            for previous in (0x2, 0x7fd7, 0x4002, 0x3013):
                self.assertEqual(result.commit(previous) & ~result.update_mask,
                                 previous & ~result.update_mask)
            if logical:
                self.assertEqual(result.flags & 0x801, 0)

    def test_invalid_inputs(self):
        for args in (('MUL', 0, 0), ('ADD', -1, 0), ('ADD', 0, 65536), ('ADC', 0, 0, 2)):
            with self.assertRaises(ValueError):
                evaluate(*args)
