# SPDX-License-Identifier: MIT
import unittest
from tools.event_reference import Machine, WordLimit, Interruptibility, UnresolvedEvidence, physical_accesses


class EventReferenceTests(unittest.TestCase):
    def machine(self, **kwargs):
        m=Machine(**kwargs)
        m.memory={12:0x34,13:0x12,14:0x56,15:0x78,52:0x22,53:0x11,54:0x44,55:0x33}
        return m

    def test_known_int_frame_and_reserved_flags(self):
        m=self.machine(flags=0x7fd7,sp=0x201)
        m.step([0xcc])
        self.assertEqual((m.cs,m.ip,m.flags,m.sp,m.event,m.retired),(0x7856,0x1234,0x7cd7,0x1fb,3,True))
        self.assertEqual(m.accesses,[(True,0x801ff,0x7fd7),(True,0x801fd,0x1000),(True,0x801fb,0x101),
                                    (False,12,0x1234),(False,14,0x7856)])
        self.assertEqual(len(list(physical_accesses(m.accesses))),8)

    def test_frame_wrap_even_and_shutdown_partial_odd(self):
        m=self.machine(sp=0)
        m.step([0xcc])
        self.assertEqual((m.sp,m.shutdown,m.event),(0xfffa,False,3))
        for sp,writes in ((1,0),(3,1),(5,2)):
            m=self.machine(sp=sp)
            m.step([0xcc])
            self.assertTrue(m.shutdown)
            self.assertFalse(m.retired)
            self.assertEqual(len(m.accesses),writes)
            self.assertIsNone(m.event)

    def test_iret_stages_context_and_keeps_completed_sp_effect(self):
        m=self.machine(sp=0xfffd,flags=0x402)
        m.memory.update({0x8fffd:0xef,0x8fffe:0xbe})
        m.step([0xcf])
        self.assertEqual((m.event,m.retired,m.sp),(13,False,0xfff9))
        self.assertEqual(m.accesses[0],(False,0x8fffd,0xbeef))
        self.assertEqual(m.accesses[2],(True,0x8fffb,0x1000))
        self.assertEqual(m.accesses[3],(True,0x8fff9,0x100))

    def test_iret_normalizes_application_flags(self):
        m=self.machine(sp=0xfffe,flags=0x5002)
        for a,v in ((0x8fffe,0x34),(0x8ffff,0x12),(0x80000,0x78),(0x80001,0x56),(0x80002,0xff),(0x80003,0xff)):
            m.memory[a]=v
        m.step([0xcf])
        self.assertEqual((m.cs,m.ip,m.sp,m.flags),(0x5678,0x1234,4,0x5fd7))

    def test_into_untaken_and_cli_sti_preserve_flags(self):
        m=self.machine(flags=0x4d7)
        m.step([0xce])
        self.assertEqual((m.event,m.ip,len(m.accesses)),(None,0x101,0))
        m.step([0xfb]); self.assertEqual(m.flags,0x6d7)
        m.step([0xfa]); self.assertEqual(m.flags,0x4d7)

    def test_all_source_eligibility_combinations(self):
        for bits in range(64):
            step,nmi,blocked,intr,enabled,shadow = [bool(bits & (1 << n)) for n in range(6)]
            state=Interruptibility(pending_step=step,pending_nmi=nmi,nmi_in_service=blocked,
                                   intr=intr,following_sti=int(shadow))
            candidates=[]
            if step: candidates.append((2,1))
            if nmi and not blocked: candidates.append((3,2))
            if intr and enabled and not shadow: candidates.append((4,None))
            self.assertEqual(state.choose(0x200 if enabled else 0),candidates[0] if candidates else None)
            self.assertEqual(state.choose(0x200,fault=13),(1,13))
            self.assertEqual(state.choose(0x200,software=3),(5,3))

    def test_edge_retention_and_successful_return(self):
        state=Interruptibility()
        state.pins(False,True);state.accept(3)
        state.pins(False,True)
        self.assertFalse(state.pending_nmi)
        state.pins(False,False);state.pins(False,True)
        self.assertTrue(state.pending_nmi)
        self.assertIsNone(state.choose(2))
        state.begin(2);state.finish(0xcf)
        self.assertEqual(state.choose(2),(3,2))

    def test_failed_iret_is_not_fabricated_hardware_evidence(self):
        state=Interruptibility(nmi_in_service=True)
        with self.assertRaisesRegex(UnresolvedEvidence,'failed IRET'):
            state.finish(0xcf,fault=True)

    def test_flags_sampling_and_completed_instruction_shadow(self):
        state=Interruptibility(intr=True)
        state.begin(2);state.finish(0xfb)
        self.assertIsNone(state.choose(0x202))
        state.begin(0x202);state.finish(0xb8)
        self.assertEqual(state.choose(0x202),(4,None))
        state.begin(0x102);state.finish(0x9d)
        self.assertEqual(state.choose(2),(2,1))
        state.accept(2);state.begin(2);state.finish(0x9d)
        self.assertIsNone(state.choose(0x102))
        state.begin(0x102);state.finish(0xcc,software=True)
        self.assertIsNone(state.choose(2))

    def test_stack_vector_alias_observes_written_words(self):
        m=self.machine(ss=0,sp=18,flags=0x402)
        m.step([0xcc])
        self.assertEqual((m.ip,m.cs),(0x101,0x1000))
        self.assertEqual(m.accesses[-2:],[(False,12,0x101),(False,14,0x1000)])
