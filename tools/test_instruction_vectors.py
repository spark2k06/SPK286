# SPDX-License-Identifier: MIT
"""Independent TEST expectations: integer AND, flag parity and no destination write."""
import argparse
from pathlib import Path

EDGES = (0, 1, 15, 16, 127, 128, 255, 0x7fff, 0x8000, 0xffff)


def read(registers, index, width):
    return registers[index] if width == 16 else (registers[index % 4] // (256 if index >= 4 else 1)) % 256


def put(registers, index, value, width):
    if width == 16:
        registers[index] = value % 65536
    else:
        scale = 256 if index >= 4 else 1
        registers[index % 4] += (value % 256 - read(registers, index, width)) * scale


def record(width, form, mode, reg, rm, seed, boundary=False):
    registers = [0x807f, 0x1234, 0xabcd, 0x2468, 0x6800, 0x369c, 0x110, 0x220]
    mask = 2 ** width - 1
    source = EDGES[seed % len(EDGES)] & mask
    memory_value = EDGES[(seed + 3) % len(EDGES)] & mask
    if form == 0:
        put(registers, reg, source, width)
    if mode == 3 and form != 2:
        put(registers, rm, memory_value, width)
    if form == 2:
        put(registers, 0, memory_value, width)
    flags = (0x7cd7, 0x0002, 0x3413, 0x4446)[seed % 4]
    displacement = (0, 127, 128, 255, 0x8000, 0xffff)[seed % 6]
    code = [((0x84, 0xf6, 0xa8)[form]) + (width == 16)]
    segment = 3
    offset = 0
    memory = mode != 3 and form != 2
    if form != 2:
        code.append(mode * 64 + (reg if form == 0 else 0) * 8 + rm)
        if mode == 1:
            code.append(displacement % 256)
            displacement = displacement % 256 - (256 if displacement % 256 >= 128 else 0)
        elif mode == 2 or mode == 0 and rm == 6:
            if boundary:
                displacement = 0xffff
            code += [displacement % 256, displacement // 256]
        else:
            displacement = 0
        if memory:
            base = (registers[3]+registers[6], registers[3]+registers[7],
                    registers[5]+registers[6], registers[5]+registers[7],
                    registers[6], registers[7], registers[5], registers[3])[rm]
            offset = (displacement + (0 if mode == 0 and rm == 6 else base)) % 65536
            segment = 2 if rm in (2, 3) or rm == 6 and mode != 0 else 3
    if form != 0:
        code.append(source % 256)
        if width == 16:
            code.append(source // 256)
    if seed % 4 == 2:
        code.insert(0, 0x3e)
        segment = 3
    a = memory_value if memory else read(registers, 0 if form == 2 else rm, width)
    b = read(registers, reg, width) if form == 0 else source
    result = a & b
    blocked = memory and width == 16 and offset == 0xffff
    expected_flags = flags if blocked else ((flags & ~0x08c5) |
                     (int(result >= 2 ** (width-1)) * 128) |
                     (int(result == 0) * 64) | (int((result % 256).bit_count() % 2 == 0) * 4))
    # The byte harness also compares the adjacent high byte; preserve its sentinel.
    initial_memory = memory_value | (0xa500 if width == 8 else 0)
    return [int(width == 8), len(code), *code, *([0] * (8-len(code))), flags,
            *registers, expected_flags, *registers, offset, segment,
            initial_memory, initial_memory, int(memory and not blocked), 0, seed % 4, int(blocked)]


def vectors():
    for width in (8, 16):
        for mode in range(4):
            for reg in range(8):
                for rm in range(8):
                    for seed in (0, 2, 5):
                        yield record(width, 0, mode, reg, rm, seed)
        for mode in range(4):
            for rm in range(8):
                for seed in range(10):
                    yield record(width, 1, mode, 0, rm, seed)
        for seed in range(10):
            yield record(width, 2, 3, 0, 0, seed)
        for form in (0, 1):
            for seed in range(10):
                yield record(width, form, 0, 1, 6, seed, boundary=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    rows = list(vectors())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(f'{len(rows):x}\n' + ''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in rows))
    print(f'TEST_VECTORS PASS: {len(rows)} independent cases')


if __name__ == '__main__':
    main()
