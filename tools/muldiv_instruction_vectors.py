"""Full-CPU arithmetic vectors with independent integer results and operand addressing."""
import argparse
from pathlib import Path
from tools.test_instruction_vectors import record as operand_record, read, put, EDGES
from tools.muldiv_reference import evaluate, signed


def record(kind,width,mode,rm,seed,immediate=None,destination=0,boundary=False,byte_value=None):
    row=operand_record(width,0,mode,destination if immediate is not None else kind+4,rm,seed,boundary)
    prefix=int(row[2]==0x3e);code=row[2:2+row[1]]
    code[prefix]=(0x69 if immediate==16 else 0x6b) if immediate is not None else 0xf6+int(width==16)
    initial=row[11:19]
    initial[0]=(EDGES[seed%10] if kind<2 else (seed*59+7)%512)
    initial[2]=(0 if kind>=2 else EDGES[(seed+5)%10])
    if kind==3 and seed%2:initial[0]=(-initial[0])%65536;initial[2]=0xffff
    if byte_value is not None:
        assert width==8 and mode==3
        initial[0]=byte_value+(255-byte_value)*256
        put(initial,rm,byte_value*37%256,8)
    source=read(initial,rm,width) if mode==3 else row[30]%(1<<width)
    dividend=initial[0]+initial[2]*65536
    if immediate is not None:
        literal=EDGES[(seed+3)%10]
        code.append(literal%256)
        if immediate==16:code.append(literal//256)
        dividend=literal if immediate==16 else signed(literal,8)%65536
    if seed%4==3:code.insert(0,0xf3)
    assert len(code)<=8
    row[1]=len(code);row[2:10]=code+[0xf4]*(8-len(code));row[11:19]=initial
    low,high,flags,mask,write,fault=evaluate(kind,width==8,dividend,source)
    expected=list(initial)
    if not row[35]:
        row[35]=2 if fault else 0
        row[19]=(row[10]&~mask)|flags
        if write:
            if immediate is not None:expected[destination]=low
            else:
                expected[0]=low
                if width==16:expected[2]=high
    row[20:28]=expected
    return row


def vectors():
    for kind in range(4):
        for width in (8,16):
            for mode in range(4):
                for rm in range(8):
                    for seed in range(32):yield record(kind,width,mode,rm,seed)
            for seed in range(10):yield record(kind,width,0,6,seed,boundary=True)
    for immediate in (8,16):
        for mode in range(4):
            for destination in range(8):
                for rm in range(8):
                    for seed in range(10):yield record(1,16,mode,rm,seed,immediate,destination)
        for seed in range(10):yield record(1,16,0,6,seed,immediate,3,True)
    for kind in (0,1,3):
        for rm in range(8):
            for value in range(256):yield record(kind,8,3,rm,value%10,byte_value=value)


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    rows=list(vectors());args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(f'{len(rows):x}\n'+''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in rows))
    print(f'MULDIV_INSTRUCTION_VECTORS PASS: {len(rows)} independent CPU cases; {sum(row[35]==2 for row in rows)} arithmetic faults; {sum(row[35]==1 for row in rows)} operand faults')


if __name__=='__main__':main()
