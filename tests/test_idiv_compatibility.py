"""Preserve documented division while bounding the physical overflow exception."""
import unittest
from tools.muldiv_reference import evaluate

class IdivCompatibilityTests(unittest.TestCase):
    def test_positive_overflow_zero_divisors_and_word_forms_stay_faults(self):
        for divisor in range(-128,128):
            if divisor:
                n=divisor*128
                self.assertEqual(evaluate(3,True,n%65536,divisor%256)[-2:],(0,1))
                for q in (-128,-127,0,127):
                    n=divisor*q;result=evaluate(3,True,n%65536,divisor%256)
                    self.assertEqual(result[0],q%256);self.assertEqual(result[-2:],(1,0))
        for n in range(0,65536,257):self.assertEqual(evaluate(3,True,n,0)[-2:],(0,1))
        for divisor in (1,7,127,0xff81,0xffff):
            signed_divisor=divisor if divisor<32768 else divisor-65536
            self.assertEqual(evaluate(3,False,(signed_divisor*-32769)%(1<<32),divisor)[-2:],(0,1))
