"""Deterministic event vectors with independently modeled state and bus effects."""
import argparse
from pathlib import Path
from tools.event_reference import Machine, physical_accesses


def records():
    codes=[[op] for op in (0x9c,0x9d,0xcc,0xce,0xcf,0xf4,0xfa,0xfb)]
    codes += [[0xcd,v] for v in range(256)]
    for i,code in enumerate(codes):
        stacks=(0,1,2,3,4,5,6,7,0x200,0x201,0xfffb,0xfffc,0xfffd,0xfffe,0xffff) if len(code)==1 else (0x200,0x201)
        for sp in stacks:
            for flags in (2,0xcd7,0x7fd7):
                model=Machine(flags=flags,sp=sp)
                for vector in {3,4,13,code[1] if len(code)==2 else 0}:
                    address=vector*4
                    target=0x1800+vector*3
                    for a,v in ((address,target & 255),(address+1,target>>8),(address+2,0x30),(address+3,0x10)):
                        model.memory[a]=v
                for delta in range(-10,12):
                    offset=(sp+delta) % 65536
                    model.memory[0x80000+offset]=(offset*37+0x5b) % 256
                initial=model.memory.copy()
                model.step(code)
                addresses=sorted(set(initial)|set(model.memory))
                transfers=list(physical_accesses(model.accesses))
                yield [len(code),*code,*([0x90]*(8-len(code))),0x100,flags,sp,model.ss,
                       model.cs,model.ip,model.flags,model.sp,int(model.retired),
                       model.event if model.event is not None else 256,int(model.halted),int(model.shutdown),
                       (i+sp)%5,len(addresses),
                       *[x for a in addresses for x in (a,initial.get(a,0),model.memory[a])],
                       len(transfers),*[x for t in transfers for x in t]]
    # Frame writes precede IVT reads even when each possible frame byte aliases
    # the selected vector. No expected destination is copied into input RAM.
    for vector in (3,42,255):
        for delta in range(-3,9):
            sp=vector*4+delta
            model=Machine(ss=0,sp=sp,flags=0x402)
            for a in range(max(0,sp-10),sp+12):
                model.memory[a]=(a*37+0x5b) % 256
            for a,v in ((vector*4,0x34),(vector*4+1,0x12),(vector*4+2,0x78),(vector*4+3,0x56)):
                model.memory[a]=v
            initial=model.memory.copy()
            model.step([0xcd,vector])
            addresses=sorted(model.memory)
            transfers=list(physical_accesses(model.accesses))
            yield [2,0xcd,vector,*([0x90]*6),0x100,0x402,sp,0,
                   model.cs,model.ip,model.flags,model.sp,1,vector,0,0,delta%5,len(addresses),
                   *[x for a in addresses for x in (a,initial.get(a,0),model.memory[a])],
                   len(transfers),*[x for t in transfers for x in t]]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    rows=list(records())
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(f'{len(rows):x}\n'+''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in rows))
    print(f'EVENT_VECTORS: {len(rows)} independent architectural cases')


if __name__=='__main__':main()
