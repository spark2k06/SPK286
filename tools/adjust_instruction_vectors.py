"""Full-CPU adjust expectations; independent arithmetic model with varied prefixes."""
import argparse
from pathlib import Path
from tools.adjust_reference import evaluate

OPCODES=(0x27,0x2f,0x37,0x3f,0xd4,0xd5)
EDGES=(0,1,0x009a,0x00ff,0x0100,0x7fff,0xff00,0xffff)


def record(kind,operand,radix,seed):
    opcode=OPCODES[kind]
    flags=(0x7fc6,0x3703,0x4712,0x0fd7)[seed%4]
    initial=[operand,0x5678,0x9abc,0xdef0,0x6800,0x7000,0x1122,0x3344]
    expected=list(initial)
    result,candidate,mask,write,fault=evaluate(kind,operand,radix,flags%2,(flags>>4)%2)
    assert not fault
    expected[0]=result
    code=[opcode]+([radix] if kind>=4 else [])
    if seed%4==1:code=[0x26]+code
    if seed%4==2:code=[0xf2,0x3e]+code
    if seed%4==3:code=[0xf3,0x36]+code
    return [0,len(code),*code,*([0xf4]*(8-len(code))),flags,*initial,
            (flags&~mask)|candidate,*expected,0,3,0xa55a,0xa55a,0,0,seed%4,0]


def vectors():
    for kind in range(4):
        for low in range(256):
            for seed in range(4):yield record(kind,((low*17+seed)%256)*256+low,0,seed)
    for kind in (4,5):
        for radix in range(1 if kind==4 else 0,256):
            for i,operand in enumerate(EDGES):yield record(kind,operand,radix,radix+i)


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();rows=list(vectors());args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(f'{len(rows):x}\n'+''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in rows))
    print(f'ADJUST_INSTRUCTION_VECTORS PASS: {len(rows)} normal CPU cases; fault coverage is separate')


if __name__=='__main__':main()
