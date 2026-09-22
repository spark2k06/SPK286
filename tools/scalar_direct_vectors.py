"""Independent direct-scalar arithmetic and bit-transfer CPU expectations."""
import argparse
from pathlib import Path

OPCODES = tuple(range(0x40, 0x50)) + (0x98, 0x99, 0x9e, 0x9f, 0xd6, 0xf5, 0xf8, 0xf9, 0xfc, 0xfd)
VALUES = (0, 1, 0xf, 0x10, 0x7f, 0x80, 0xff, 0x100, 0x7fff, 0x8000, 0xfffe, 0xffff)


def record(opcode, value, seed):
    registers = [0x1234, 0x5678, 0x9abc, 0xdef0, 0x6800, 0x7000, 0x1122, 0x3344]
    registers[opcode % 8 if opcode < 0x50 else 0] = value
    flags = (0x7fd7, 0x0302, 0x3413, 0x4446)[seed % 4]
    expected = registers.copy()
    result_flags = flags
    if opcode < 0x50:
        direction = 1 if opcode < 0x48 else -1
        result = (value + direction) % 65536
        expected[opcode % 8] = result
        signed = value - 65536 if value >= 32768 else value
        nibble = value % 16 + direction
        result_flags = ((flags & ~0x08d4) | (int(not -32768 <= signed + direction <= 32767) * 2048) |
                        (int(result >= 32768) * 128) | (int(result == 0) * 64) |
                        (int(not 0 <= nibble <= 15) * 16) | (int((result % 256).bit_count() % 2 == 0) * 4))
    elif opcode == 0x98:
        expected[0] = value % 256 + (65280 if value % 256 >= 128 else 0)
    elif opcode == 0x99:
        expected[2] = 65535 if value >= 32768 else 0
    elif opcode == 0x9e:
        result_flags = (flags & ~0x00d5) | ((value // 256) & 0xd5)
    elif opcode == 0x9f:
        expected[0] = value % 256 + (flags % 256) * 256
    elif opcode == 0xd6:
        expected[0] = (value & 0xff00) | (255 if flags & 1 else 0)
    elif opcode == 0xf5:
        result_flags = flags - 1 if flags % 2 else flags + 1
    elif opcode == 0xf8:
        result_flags = flags - flags % 2
    elif opcode == 0xf9:
        result_flags = flags - flags % 2 + 1
    elif opcode == 0xfc:
        result_flags = flags & ~1024
    elif opcode == 0xfd:
        result_flags = flags | 1024
    code = [opcode]
    if seed % 4 == 2:
        code = [0xf2, 0x3e, opcode]
    if seed % 4 == 3:
        code = [0xf3, 0x36, opcode]
    return [1, len(code), *code, *([0xf4] * (8-len(code))), flags, *registers,
            result_flags, *expected, 0, 3, 0xa55a, 0xa55a, 0, 0, seed % 4, 0]


def vectors():
    for opcode in OPCODES:
        for value in VALUES:
            for seed in range(4):
                yield record(opcode, value, seed)
    # Every AL/AH bit combination with varied preserved high FLAGS and READY.
    for opcode in (0x98, 0x9e, 0x9f, 0xd6):
        for value in range(256):
            yield record(opcode, value + (255-value)*256, value % 4)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    rows = list(vectors())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(f'{len(rows):x}\n' + ''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in rows))
    print(f'SCALAR_DIRECT_VECTORS PASS: {len(rows)} independent cases')


if __name__ == '__main__':
    main()
