# SPDX-License-Identifier: MIT
"""Independent closed-form 286 shift/rotate arithmetic; no RTL bit-step recurrence."""
import argparse
from pathlib import Path

KINDS = (0, 1, 2, 3, 4, 5, 7)
EDGES = (0, 1, 2, 0x7f, 0x80, 0xff, 0x100, 0x7fff, 0x8000, 0xfffe, 0xffff)


def evaluate(kind, width, operand, count, carry):
    limit = 2 ** width
    value = operand % limit
    n = count % 32
    if not n:
        return value, 0, 0, False
    if kind in (0, 1):
        rotation = n % width
        result = (((value * 2 ** rotation) + (value // 2 ** (width-rotation))) if kind == 0 else
                  ((value // 2 ** rotation) + (value * 2 ** (width-rotation)))) % limit
        next_carry = result % 2 if kind == 0 else result // (limit//2)
    elif kind in (2, 3):
        ring_width = width + 1
        rotation = n % ring_width
        ring = value * 2 + carry
        # Splitting at the rotation boundary avoids a stepwise copy of the RTL.
        if kind == 2:
            ring = (ring % (2 ** (ring_width-rotation))) * (2 ** rotation) + ring // (2 ** (ring_width-rotation))
        else:
            ring = ring // (2 ** rotation) + (ring % (2 ** rotation)) * (2 ** (ring_width-rotation))
        result, next_carry = divmod(ring, 2)
    elif kind == 4:
        result = value * (2 ** n) % limit
        next_carry = (value // (2 ** (width-n))) % 2 if n <= width else 0
    elif kind == 5:
        result = value // (2 ** n)
        next_carry = (value // (2 ** (n-1))) % 2 if n <= width else 0
    elif kind == 7:
        signed = value - limit if value >= limit//2 else value
        result = (signed // (2 ** n)) % limit
        next_carry = (signed // (2 ** (n-1))) % 2
    else:
        raise ValueError('undocumented shift extension is outside this model')
    if kind < 4:
        overflow = (result // (limit//2)) ^ (next_carry if kind in (0,2) else (result // (limit//4)) % 2)
        return result, next_carry + overflow*2048, 0x0801, True
    overflow = ((result // (limit//2)) ^ next_carry) if kind == 4 else (value // (limit//2)) if kind == 5 and n == 1 else 0
    flags = (next_carry + int((result % 256).bit_count() % 2 == 0)*4 +
             int(result == 0)*64 + int(result >= limit//2)*128 + overflow*2048)
    return result, flags, 0x08c5, True


def vectors():
    for kind in KINDS:
        for value in range(256):
            for count in range(32):
                for carry in (0, 1):
                    yield [kind, 8, value, count, carry, *evaluate(kind,8,value,count,carry)]
        for value in EDGES:
            for count in range(256):
                for width in (8, 16):
                    carry = (value+count) % 2
                    yield [kind,width,value,count,carry,*evaluate(kind,width,value,count,carry)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    args = parser.parse_args()
    rows = list(vectors())
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(f'{len(rows):x}\n'+''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in rows))
    print(f'SHIFT_VECTORS PASS: {len(rows)} independent byte/word/count/carry vectors')


if __name__ == '__main__':
    main()
