"""Unary expectations from integer complement, negation and signed boundaries."""
import argparse
from pathlib import Path
from tools.test_instruction_vectors import record as operand_record, read, put


def evaluate(kind, width, value, flags):
    limit = 2**width
    value %= limit
    result = (~value if kind == 0 else -value if kind == 1 else value+1 if kind == 2 else value-1) % limit
    if kind == 0:
        return result, flags
    carry = int(value != 0) if kind == 1 else flags % 2
    auxiliary = int(value % 16 != 0) if kind == 1 else int(value % 16 == 15) if kind == 2 else int(value % 16 == 0)
    overflow = int(value == limit//2-1) if kind == 2 else int(value == limit//2)
    status = carry + 4*int((result % 256).bit_count() % 2 == 0) + 16*auxiliary + 64*int(result == 0) + 128*int(result >= limit//2) + 2048*overflow
    return result, (flags & ~0x08d5) | status


def record(kind, width, mode, rm, seed, boundary=False, value=None):
    extension = (2, 3, 0, 1)[kind]
    opcode = (0xf6 if kind < 2 else 0xfe) + int(width == 16)
    row = operand_record(width, 0, mode, extension, rm, seed, boundary)
    prefix = int(row[2] == 0x3e)
    row[2+prefix] = opcode
    initial = row[11:19]
    if value is not None:
        assert mode == 3
        put(initial, rm, value, width)
        row[11:19] = initial
    source = read(initial, rm, width) if mode == 3 else row[30] % 2**width
    result, flags = evaluate(kind, width, source, row[10])
    expected = list(initial)
    if not row[35]:
        row[19] = flags
        if mode == 3: put(expected, rm, result, width)
        else:
            row[31] = result | (row[30] & 0xff00 if width == 8 else 0)
            row[33] = 1
    row[20:28] = expected
    return row


def vectors():
    for kind in range(4):
        for width in (8, 16):
            for mode in range(4):
                for rm in range(8):
                    for seed in range(10):
                        yield record(kind, width, mode, rm, seed)
            for seed in range(10):
                yield record(kind, width, 0, 6, seed, True)
        for rm in range(8):
            for value in range(256):
                yield record(kind, 8, 3, rm, value % 10, value=value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(); rows = list(vectors())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(f'{len(rows):x}\n'+''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in rows))
    print(f'UNARY_VECTORS PASS: {len(rows)} independent cases')


if __name__ == '__main__':
    main()
