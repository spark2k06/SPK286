"""Independent architectural real-mode event model, with ordered word effects.

No generated microcode, RTL constants, corpus expected values or CPU helpers are
used. Intel 210498/210760 and the B-2 corrections ground the policies below;
unresolved distinctions are identified separately and block release.
Bus clocks are intentionally absent. Physical word splitting is a separate
serialization of architectural accesses for directed verification.
"""
from dataclasses import dataclass, field


class UnresolvedEvidence(Exception):
    """A physical discriminator is needed; model agreement is not evidence."""


@dataclass
class Interruptibility:
    """Instruction-boundary rules, independent of micro-operations and clocks.

    The old-IF STI qualifier and fault/TF suppression are documented candidate
    interpretations. Failed IRET deliberately has no asserted hardware oracle.
    See docs/PHASE6_ARCHITECTURAL_REVIEW.md for the evidence limitations.
    """
    intr: bool = False
    nmi_level: bool = False
    pending_nmi: bool = False
    nmi_in_service: bool = False
    pending_step: bool = False
    following_sti: int = 0
    sampled_tf: bool = False
    old_if: bool = False
    coincident_edge: bool = False

    def pins(self, intr, nmi):
        self.intr = bool(intr)
        self.coincident_edge = self.pending_nmi and bool(nmi) and not self.nmi_level
        self.pending_nmi |= bool(nmi) and not self.nmi_level
        self.nmi_level = bool(nmi)

    def begin(self, flags):
        self.coincident_edge = False
        self.sampled_tf = bool(flags & 0x100)
        self.old_if = bool(flags & 0x200)

    def finish(self, opcode, *, fault=False, software=False):
        if opcode == 0xcf:
            if fault and self.nmi_in_service:
                raise UnresolvedEvidence('286 NMI inhibition after failed IRET')
            if not fault:
                self.nmi_in_service = False
        self.pending_step = self.sampled_tf and not fault and not software
        self.following_sti = (1 if opcode == 0xfb and not self.old_if
                              else max(0, self.following_sti - 1))

    def choose(self, flags, *, fault=None, software=None, shutdown=False):
        # Priority is a table of eligible architectural sources. A next-opcode
        # fetch demand must be presented only after prior boundary sources.
        eligible = [(1, fault, fault is not None and not shutdown),
                    (5, software, software is not None and not shutdown),
                    (2, 1, self.pending_step and not shutdown),
                    (3, 2, self.pending_nmi and not self.nmi_in_service),
                    (4, None, self.intr and bool(flags & 0x200)
                     and not self.following_sti and not shutdown)]
        return next(((kind, vector) for kind, vector, yes in eligible if yes), None)

    def accept(self, kind):
        if kind == 3:
            self.pending_nmi = self.coincident_edge
            self.nmi_in_service = True
        self.pending_step = False
        self.following_sti = 0


class WordLimit(Exception):
    pass


@dataclass
class Machine:
    cs: int = 0x1000
    ip: int = 0x100
    flags: int = 2
    ss: int = 0x8000
    sp: int = 0x200
    memory: dict[int, int] = field(default_factory=dict)
    accesses: list[tuple[bool, int, int]] = field(default_factory=list)
    halted: bool = False
    shutdown: bool = False
    event: int | None = None
    retired: bool = False

    def word(self, address, value=None):
        address %= 1 << 24
        if value is None:
            value=self.memory[address]+256*self.memory[(address+1) % (1 << 24)]
            self.accesses.append((False,address,value))
            return value
        self.memory[address]=value % 256
        self.memory[(address+1) % (1 << 24)]=value // 256
        self.accesses.append((True,address,value))

    def push(self, value):
        offset=(self.sp-2) % 65536
        if offset == 65535:
            raise WordLimit
        self.word(self.ss*16+offset,value)
        self.sp=offset

    def pop(self):
        if self.sp == 65535:
            raise WordLimit
        value=self.word(self.ss*16+self.sp)
        self.sp=(self.sp+2) % 65536
        return value

    def deliver(self, vector, return_ip, software=False):
        try:
            self.push(self.flags)
            self.push(self.cs)
            self.push(return_ip)
        except WordLimit:
            self.shutdown=True
            return
        self.flags &= ~0x300
        target=self.word(vector*4)
        selector=self.word(vector*4+2)
        self.cs,self.ip=selector,target
        self.event=vector
        self.retired=software
        self.halted=False

    def step(self, code):
        start=self.ip
        self.ip=(self.ip+len(code)) % 65536
        op=code[0]
        try:
            if op==0x9c:
                self.push(self.flags)
            elif op==0x9d:
                self.flags=(self.flags & 0x7000) | (self.pop() & 0xfd5) | 2
            elif op==0xfa:
                self.flags &= ~0x200
            elif op==0xfb:
                self.flags |= 0x200
            elif op==0xf4:
                self.halted=True
            elif op==0xcf:
                target,selector,image=self.pop(),self.pop(),self.pop()
                self.cs,self.ip=selector,target
                self.flags=(self.flags & 0x7000) | (image & 0xfd5) | 2
            elif op in (0xcc,0xcd,0xce):
                if op!=0xce or self.flags & 0x800:
                    self.deliver(3 if op==0xcc else code[1] if op==0xcd else 4,self.ip,software=True)
                    return
            else:
                raise ValueError(f'unsupported independent model opcode {op:02x}')
        except WordLimit:
            self.deliver(13,start)
            return
        self.retired=True


def physical_accesses(accesses):
    for write,address,value in accesses:
        if address % 2:
            yield int(write),address,(value % 256)*256,0
            yield int(write),(address+1) % (1 << 24),value//256,1
        else:
            yield int(write),address,value,0
