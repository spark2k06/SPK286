"""Shift CPU vectors reuse independent EA construction and closed-form arithmetic."""
import argparse
from pathlib import Path
from tools.test_instruction_vectors import record as operand_record, read, put
from tools.shift_reference import evaluate, KINDS

COUNTS = (0, 1, 2, 7, 8, 9, 15, 16, 17, 31, 32, 33, 255)


def record(opcode, kind, mode, rm, count, seed, boundary=False):
    width = 16 if opcode % 2 else 8
    v = operand_record(width, 1, mode, 0, rm, seed, boundary)
    code = list(v[2:2+v[1]])
    prefix = 1 if code[0] == 0x3e else 0
    code[prefix] = opcode
    code[prefix+1] = mode*64 + kind*8 + rm
    code = code[:-(width//8)]
    if opcode in (0xc0, 0xc1):
        code.append(count)
    initial = list(v[11:19])
    if opcode in (0xd2, 0xd3):
        initial[1] = (initial[1] & 0xff00) | count
    else:
        count = count if opcode in (0xc0,0xc1) else 1
    expected = list(initial)
    memory = mode != 3
    value = v[30] % (2**width) if memory else read(initial,rm,width)
    result, candidate, mask, write = evaluate(kind,width,value,count,v[10]%2)
    blocked = bool(v[35])
    expected_memory = v[30]
    flags = v[10] if blocked else ((v[10] & ~mask) | (candidate & mask))
    if write and not blocked:
        if memory:
            expected_memory = result | (v[30] & 0xff00 if width == 8 else 0)
        else:
            put(expected,rm,result,width)
    return [int(width==8),len(code),*code,*([0xf4]*(8-len(code))),v[10],*initial,
            flags,*expected,v[28],v[29],v[30],expected_memory,int(memory and not blocked),
            int(memory and not blocked and write),seed%4,int(blocked)]


def vectors():
    for opcode in (0xc0,0xc1,0xd0,0xd1,0xd2,0xd3):
        for kind in KINDS:
            for mode in range(4):
                for rm in range(8):
                    for i,count in enumerate(COUNTS if opcode not in (0xd0,0xd1) else (1,)):
                        yield record(opcode,kind,mode,rm,count,i+rm)
            for count in (0,1,32,255) if opcode not in (0xd0,0xd1) else (1,):
                yield record(opcode,kind,0,6,count,count%4,boundary=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();rows=list(vectors())
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(f'{len(rows):x}\n'+''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in rows))
    print(f'SHIFT_INSTRUCTION_VECTORS PASS: {len(rows)} independent CPU cases')


if __name__=='__main__':
    main()
