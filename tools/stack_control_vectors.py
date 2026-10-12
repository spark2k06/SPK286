# SPDX-License-Identifier: MIT
"""Directed instruction and ordered physical-bus vectors from an independent model."""
import argparse
from pathlib import Path
from tools.stack_control_reference import evaluate


def records():
    def case(code,sp=0x200,cx=2,flags=0x7fd7,ip=0x100,wait=0,regs=None):
        r=list(regs) if regs else [0xa55a,cx,0x1357,0x2000,sp,0x3000,0x110,0x222]
        memory={}
        # Seed complete stack and operand regions with address-dependent words.
        for base in (0x40000,0x80000):
            for offset in (0,1,2,0x100,0x200,0x202,0x2110,0x2222,0x3110,0x3222,0x110,0x222,0x3000,0x2000,0xfffe,0xffff,
                           r[4],(r[4]-2)%65536):
                for delta in (-1,0,1,2):
                    a=base+offset+delta
                    memory[a]=(a*73+0x59)%256
        outcome=evaluate(code,r,flags,ip,memory)
        for _,a,_ in outcome.transactions:
            for n in (-1,0,1,2):memory.setdefault(a+n,0)
        outcome=evaluate(code,r,flags,ip,memory)
        touched=set(memory)|set(outcome.memory)
        buses=[]
        for write,address,value in outcome.transactions:
            if address%2:
                buses.extend([(write,address,(value%256)*256,0),(write,address+1,value//256,1)])
            else:buses.append((write,address,value,0))
        return ([len(code),*code,*([0xf4]*(8-len(code))),ip,flags,*r,outcome.ip,*outcome.registers,
                 int(outcome.blocked),int(outcome.redirected),wait,len(touched)] +
                [v for a in sorted(touched) for v in (a,memory.get(a,0),outcome.memory.get(a,memory.get(a,0)))] +
                [len(buses)]+[int(v) for bus in buses for v in bus])
    for op in range(0x50,0x60):
        for sp in (0,1,2,3,0x200,0x201,0xfffe,0xffff):
            for wait in (0,1,4):yield case([op],sp=sp,wait=wait)
    for op in (0x68,0x6a):
        for value in (0,1,0x7f,0x80,0xff,0x7fff,0x8000,0xffff):
            for sp in (0,1,2,3,0xfffe,0xffff):
                yield case([op,value%256]+([value//256] if op==0x68 else []),sp=sp,wait=value%5)
    for op,group in ((0x8f,0),(0xff,2),(0xff,4),(0xff,6)):
        for mode in range(4):
            for rm in range(8):
                for disp in (0,1,0x7f,0x80,0xff,0xffff):
                    code=[op,mode*64+group*8+rm]
                    if mode==1:code+=[disp%256]
                    elif mode==2 or mode==0 and rm==6:code += [disp%256,disp//256]
                    for sp in (0x200,0x201):yield case(code,sp=sp,wait=disp%5)
        for offset in (0xfffe,0xffff):
            yield case([op,group*8+6,offset%256,offset//256])
        # Stack/source/destination overlap in SS:BP; capture source before PUSH.
        for sp in (0,1,2,0x200,0xffff):
            r=[0xa55a,2,0x1357,0x2000,sp,sp,0x110,0x222]
            yield case([op,0x46+group*8,0],regs=r,wait=3)
    for op in (0xe8,0xe9,0xeb):
        for displacement in (0,1,0x7f,0x80,0xff,0x7fff,0x8000,0xffff):
            for ip in (0,1,0x100,0xfffd):
                for sp in (0,1,2,3,0xffff):
                    yield case([op,displacement%256]+([displacement//256] if op!=0xeb else []),ip=ip,sp=sp,wait=displacement%5)
    for op in (0xc2,0xc3):
        for release in (0,1,2,0x7fff,0xffff):
            for sp in (0,1,2,3,0xfffe,0xffff):
                yield case([op]+([release%256,release//256] if op==0xc2 else []),sp=sp,wait=release%5)
    for bits in range(32):
        flags=0x7502|sum(((bits>>n)&1)<<bit for n,bit in enumerate((0,2,6,7,11)))
        for op in range(0x70,0x80):
            for displacement in (0,1,0x7f,0x80,0xfe,0xff):
                for ip in (1,0xfffe):yield case([op,displacement],flags=flags,ip=ip,wait=bits%5)
    for op in range(0xe0,0xe4):
        for count in (0,1,2,0x7fff,0xffff):
            for flags in (2,0x7fd7):
                for displacement in (0,1,0x7f,0x80,0xff):
                    for ip in (1,0xfffe):yield case([op,displacement],cx=count,flags=flags,ip=ip,wait=count%5)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    vectors=list(records())
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(f'{len(vectors):x}\n'+''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in vectors))
    print(f'STACK_CONTROL_VECTORS: {len(vectors)} independently modeled CPU cases')


if __name__=='__main__':main()
