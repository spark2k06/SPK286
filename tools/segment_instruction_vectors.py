# SPDX-License-Identifier: MIT
"""Independent selector, stack, EA and hidden-cache expectations for segments."""
import argparse
from pathlib import Path
from tools.test_instruction_vectors import record as operand_record, EDGES
from tools.data_instruction_vectors import pack

SEGMENTS=(0x2000,0x1000,0x8000,0x4000)


def mov_record(opcode,mode,reg,rm,seed,boundary=False):
    row=operand_record(16,0,mode,reg,rm,seed,boundary)
    prefix=int(row[2]==0x3e);row[2+prefix]=opcode
    if seed>=3:
        override={3:0,4:1,5:2}[seed]
        code=[(0x26,0x2e,0x36,0x3e)[override],*row[2:2+row[1]]]
        row[1]=len(code);row[2:10]=code+[0]*(8-len(code));row[29]=override
    initial=list(row[11:19]);expected=list(initial);segments=list(SEGMENTS)
    invalid=reg>3 or opcode==0x8e and reg==1
    blocked=invalid or mode!=3 and row[28]==0xffff
    row[35]=2 if invalid else int(blocked)
    row[19]=row[10];row[32:34]=[0,0]
    if not blocked:
        if opcode==0x8e:
            segments[reg]=initial[rm] if mode==3 else row[30]
            row[32]=int(mode!=3)
        elif mode==3:expected[rm]=SEGMENTS[reg]
        else:row[31]=SEGMENTS[reg];row[33]=1
    row[20:28]=expected
    return [*row,*SEGMENTS,*segments]


def stack_record(opcode,sp,seed,prefix):
    initial=[0xa501,0x1234,0xabcd,0x2468,sp,0x369c,0x110,0x220]
    expected=list(initial);segments=list(SEGMENTS);segment=(opcode>>3)&3
    pop=bool(opcode&1);offset=sp if pop else (sp-2)%65536
    blocked=offset==0xffff;before=EDGES[seed];after=before
    if not blocked:
        expected[4]=(sp+(2 if pop else -2))%65536
        if pop:segments[segment]=before
        else:after=SEGMENTS[segment]
    row=pack(16,prefix+[opcode],initial,expected,offset,2,before,after,
             int(pop and not blocked),int(not pop and not blocked),seed,int(blocked))
    return [*row,*SEGMENTS,*segments]


def vectors():
    for opcode in (0x8c,0x8e):
        for mode in range(4):
            for reg in range(8):
                for rm in range(8):
                    for seed in range(6):yield mov_record(opcode,mode,reg,rm,seed)
        for reg in range(8):
            for seed in (0,2,5):yield mov_record(opcode,0,reg,6,seed,True)
    for opcode in (0x06,0x07,0x0e,0x16,0x17,0x1e,0x1f):
        for sp in (0,1,2,3,0x1000,0x1001,0xfffe,0xffff):
            for seed in range(10):
                for prefix in ([],[0x3e],[0xf3,0x26]):yield stack_record(opcode,sp,seed,prefix)


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();rows=list(vectors());args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(f'{len(rows):x}\n'+''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in rows))
    print(f'SEGMENT_VECTORS PASS: {len(rows)} independent selector/cache/stack/EA cases')


if __name__=='__main__':main()
