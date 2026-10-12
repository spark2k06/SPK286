# SPDX-License-Identifier: MIT
import unittest
from tools.stack_control_reference import condition, push, pop, relative, loop, evaluate


class StackControlReferenceTests(unittest.TestCase):
    def test_conditions_exhaustive_relations(self):
        for bits in range(32):
            flags = sum(((bits >> n) & 1) << bit for n,bit in enumerate((0,2,6,7,11)))
            for cc in range(0,16,2):
                self.assertNotEqual(condition(cc,flags),condition(cc+1,flags))
            # Signed relations checked by ordering abstract sign/overflow values.
            signed_less = ((flags >> 7) ^ (flags >> 11)) & 1
            self.assertEqual(condition(12,flags),bool(signed_less))
            self.assertEqual(condition(6,flags),bool(flags & 65))
            self.assertEqual(condition(14,flags),bool(flags & 64) or bool(signed_less))

    def test_stack_boundaries_and_order(self):
        for sp in range(65536):
            if sp == 1:
                with self.assertRaises(ValueError): push(sp,sp)
            else:
                offset,value = push(sp,sp)
                self.assertEqual(value,sp)
                self.assertEqual(pop(offset,value),sp)
            if sp == 65535:
                with self.assertRaises(ValueError): pop(sp,0)
            else:
                self.assertEqual(pop(sp,0xa55a,True),0xa55a)
                self.assertEqual(pop(sp,0,release=65535),(sp+1)%65536)

    def test_relative_wrap(self):
        self.assertEqual(relative(0xffff,1),0)
        self.assertEqual(relative(1,-2),0xffff)
        self.assertEqual(relative(0x8001,0x8000),1)

    def test_count_and_zero(self):
        for count in (0,1,2,65535):
            for z in (0,64):
                for op in range(0xe0,0xe4):
                    updated,taken=loop(op,count,z)
                    self.assertEqual(updated,count if op==0xe3 else (count-1)%65536)
                    if op==0xe3:self.assertEqual(taken,count==0)
                    elif count==1:self.assertFalse(taken)
                    elif op==0xe2:self.assertTrue(taken)
                    else:self.assertEqual(taken,bool(z)==(op==0xe1))

    def test_call_return_and_memory_pop_sp(self):
        r=[0,0,0,0,0x200,0,0,0]
        call=evaluate([0xe8,0xfd,0x00],r,2,0x100,{})
        self.assertEqual((call.ip,call.registers[4]),(0x200,0x1fe))
        ret=evaluate([0xc2,6,0],call.registers,2,call.ip,call.memory)
        self.assertEqual((ret.ip,ret.registers[4]),(0x103,0x206))
        loaded=evaluate([0x8f,0xc4],call.registers,2,0x100,call.memory)
        self.assertEqual(loaded.registers[4],0x103)
