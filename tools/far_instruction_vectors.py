"""Independent far-pointer, return-link and modular stack transaction vectors."""
import argparse
from pathlib import Path
from tools.stack_frame_vectors import Case,SEGMENTS,SS_BASE,SP_EDGES
from tools.test_instruction_vectors import record as operand_record


class FarCase(Case):
    def __init__(self,code,sp,seed):
        super().__init__(code,sp,0x369c,seed)
        self.segments=list(SEGMENTS)
        self.next_ip=0x100+len(code)

    def initialize_word(self,address,value):
        self.ensure(address)
        for i in (0,1):self.before[address+i]=self.memory[address+i]=(value>>(8*i))&255

    def row(self):
        row=super().row()
        # Code/FLAGS/initial+expected GPR fields precede expected IP and caches.
        return row[:26]+[self.next_ip,*self.segments]+row[26:]


def pointer(opcode,mode,reg,rm,seed,boundary=None,sp=0x6800,overlap=False):
    row=operand_record(16,0,mode,reg,rm,seed)
    code=row[2:2+row[1]];prefix=int(code[0]==0x3e)
    code[prefix]=opcode
    if opcode==0xff:code[prefix+1]=mode*64+reg*8+rm
    if boundary is not None:
        assert mode==0 and rm==6
        code[prefix+2:prefix+4]=[boundary&255,boundary>>8]
        row[28]=boundary
    if overlap:
        assert mode==0 and rm==6
        code=[0x36,0xff,reg*8+6,row[28]&255,row[28]>>8]
        row[29]=2
    c=FarCase(code,sp,seed);c.initial=row[11:19];c.initial[4]=sp;c.expected=c.initial.copy()
    target=(0,1,0x7fff,0x8000,0xfffe,0xffff,0x1234,0x1235,0x5a5a,0xa5a5)[seed%10]
    selector=(0,1,0xffff,0x2345,0x8001,0x7fff)[seed%6]
    offset=row[28];base=SEGMENTS[row[29]]<<4
    if mode==3:c.fault=6;return c
    c.initialize_word(base+offset,target)
    c.initialize_word(base+((offset+2)&65535),selector)
    if any(((offset+2*i)&65535)==65535 for i in range(2)):
        c.fault=13;return c
    low=c.transfer(base+offset);high=c.transfer(base+((offset+2)&65535))
    if opcode in (0xc4,0xc5):
        c.segments[0 if opcode==0xc4 else 3]=high;c.expected[reg]=low
    else:
        if reg==3:
            if any(((sp-2*(i+1))&65535)==65535 for i in range(2)):
                c.fault=13;return c
            c.push(SEGMENTS[1]);c.push(c.next_ip)
        c.segments[1]=high;c.next_ip=low
    return c


def immediate(opcode,sp,seed):
    target=(0,1,0x7fff,0x8000,0xfffe,0xffff)[seed%6]
    selector=(0,1,0xffff,0x2345,0x8001,0x7fff)[seed%6]
    prefix=() if seed%3==0 else (0x3e,) if seed%3==1 else (0xf3,0x26)
    c=FarCase([*prefix,opcode,target&255,target>>8,selector&255,selector>>8],sp,seed)
    if opcode==0x9a:
        if any(((sp-2*(i+1))&65535)==65535 for i in range(2)):
            c.fault=13;return c
        c.push(SEGMENTS[1]);c.push(c.next_ip)
    c.segments[1]=selector;c.next_ip=target
    return c


def return_case(opcode,sp,seed):
    allocation=(0,1,2,0x7fff,0x8000,0xffff)[seed%6]
    prefix=() if seed%3==0 else (0xf3,) if seed%3==1 else (0x26,0x36)
    c=FarCase([*prefix,opcode,*([allocation&255,allocation>>8] if opcode==0xca else [])],sp,seed)
    target=(0,1,0x7fff,0x8000,0xfffe,0xffff)[seed%6]
    selector=(0,1,0xffff,0x2345,0x8001,0x7fff)[seed%6]
    c.initialize_word(SS_BASE+sp,target)
    c.initialize_word(SS_BASE+((sp+2)&65535),selector)
    if any(((sp+2*i)&65535)==65535 for i in range(2)):
        c.fault=13;return c
    c.next_ip=c.pop();c.segments[1]=c.pop()
    if opcode==0xca:c.expected[4]=(c.expected[4]+allocation)&65535
    return c


def vectors():
    for opcode in (0xc4,0xc5):
        for mode in range(4):
            for reg in range(8):
                for rm in range(8):
                    for seed in range(10):yield pointer(opcode,mode,reg,rm,seed)
    for group in (3,5):
        for mode in range(4):
            for rm in range(8):
                for seed in range(10):yield pointer(0xff,mode,group,rm,seed)
    for opcode in (0x9a,0xea):
        for sp in SP_EDGES:
            for seed in range(6):yield immediate(opcode,sp,seed)
    for opcode in (0xca,0xcb):
        for sp in SP_EDGES:
            for seed in range(6):yield return_case(opcode,sp,seed)
    for opcode,reg in ((0xc4,3),(0xc5,3),(0xff,3),(0xff,5)):
        for offset in (0xfffc,0xfffd,0xfffe,0xffff):
            for seed in range(6):yield pointer(opcode,0,reg,6,seed,boundary=offset)
    for offset in (0x67fa,0x67fc,0x67fe,0x6800):
        for seed in range(10):yield pointer(0xff,0,3,6,seed,boundary=offset,overlap=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    cases=list(vectors());rows=[c.row() for c in cases];args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(f'{len(rows):x}\n'+''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in rows))
    print(f'FAR_INSTRUCTION_VECTORS PASS: {len(rows)} independent pointer/stack/cache/target cases')


if __name__=='__main__':main()
