"""Independent address/byte-alias/exchange expectations for data transfers."""
import argparse
from pathlib import Path
from tools.test_instruction_vectors import record as operand_record, read, put, EDGES


def modrm_record(opcode, mode, reg, rm, seed, boundary=False):
    width = 8 if opcode == 0x86 else 16
    row = operand_record(width, 0, mode, reg, rm, seed, boundary)
    prefix = int(row[2] == 0x3e)
    row[2+prefix] = opcode
    initial = list(row[11:19]); expected = list(initial)
    row[19] = row[10]  # All data operations preserve every FLAGS bit.
    if opcode == 0x8d:
        row[32:34] = [0, 0]
        row[35] = 2 if mode == 3 else 0
        if mode != 3: expected[reg] = row[28]
    elif not row[35]:
        source = read(initial, reg, width)
        other = read(initial, rm, width) if mode == 3 else row[30] % 2**width
        put(expected, reg, other, width)
        if mode == 3: put(expected, rm, source, width)
        else:
            row[31] = source | (row[30] & 0xff00 if width == 8 else 0)
            row[33] = 1
    row[20:28] = expected
    return row


def pack(width, code, initial, expected, offset, segment, initial_memory, expected_memory, reads, writes, seed, blocked=0):
    flags = (0x7cd7, 0x0002, 0x3413, 0x4446)[seed % 4]
    return [int(width == 8), len(code), *code, *([0xf4]*(8-len(code))), flags, *initial,
            flags, *expected, offset, segment, initial_memory, expected_memory, reads, writes, seed % 4, blocked]


def direct_record(opcode, offset, seed, prefix):
    width = 8 if opcode % 2 == 0 else 16
    initial = [EDGES[seed % 10], 0x1234, 0xabcd, 0x2468, 0x6800, 0x369c, 0x110, 0x220]
    expected = list(initial); memory = 0xa580 | ((seed*17+3) % 128)
    blocked = int(width == 16 and offset == 65535)
    store = opcode >= 0xa2
    changed = memory
    if not blocked:
        if store: changed = initial[0] if width == 16 else (memory & 0xff00) | (initial[0] % 256)
        else: put(expected, 0, memory, width)
    code = prefix+[opcode, offset % 256, offset // 256]
    return pack(width, code, initial, expected, offset, 2 if 0x36 in prefix else 3,
                memory, changed, int(not store and not blocked), int(store and not blocked), seed, blocked)


def xlat_record(base, index, seed, prefix):
    initial = [0xa500 | index, 0x1234, 0xabcd, base, 0x6800, 0x369c, 0x110, 0x220]
    expected = list(initial); value = (base + index*13 + 7) % 256
    expected[0] = 0xa500 | value
    return pack(8, prefix+[0xd7], initial, expected, (base+index) % 65536,
                2 if 0x36 in prefix else 3, 0xa500 | value, 0xa500 | value, 1, 0, seed)


def vectors():
    for opcode in (0x86, 0x87, 0x8d):
        for mode in range(4):
            for reg in range(8):
                for rm in range(8):
                    for seed in range(6):
                        yield modrm_record(opcode, mode, reg, rm, seed)
        for reg in range(8):
            for seed in (0, 2, 5):
                yield modrm_record(opcode, 0, reg, 6, seed, True)
    for target in range(8):
        for seed in range(10):
            initial = [((seed+r+1)*0x1237) % 65536 for r in range(8)]
            initial[0] = EDGES[seed]
            expected = list(initial); expected[0], expected[target] = initial[target], initial[0]
            yield pack(16, [0x90+target], initial, expected, 0x4320, 3, 0xa55a, 0xa55a, 0, 0, seed)
    for opcode in range(0xa0, 0xa4):
        for offset in (0, 1, 0x100, 0x101, 0x7fff, 0xfffe, 0xffff):
            for prefix in ([], [0x36], [0xf3, 0x3e]):
                for seed in range(10):
                    yield direct_record(opcode, offset, seed, prefix)
    for base in (0, 1, 0x100, 0xff00, 0xff80, 0xffff):
        for index in (0, 1, 0x7f, 0x80, 0xff):
            for prefix in ([], [0x36], [0xf2, 0x3e]):
                yield xlat_record(base, index, base+index, prefix)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(); rows = list(vectors())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(f'{len(rows):x}\n'+''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in rows))
    print(f'DATA_INSTRUCTION_VECTORS PASS: {len(rows)} independent cases')


if __name__ == '__main__':
    main()
