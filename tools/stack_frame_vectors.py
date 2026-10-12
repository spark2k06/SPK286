# SPDX-License-Identifier: MIT
"""Independent word-address enumeration and stack/frame architectural vectors."""
import argparse
from pathlib import Path
from tools.test_instruction_vectors import record as operand_record


SS_BASE = 0x80000
SEGMENTS = (0x2000, 0x1000, 0x8000, 0x4000)
SP_EDGES = tuple(range(18)) + tuple(range(0xfff0, 0x10000)) + (0x1234, 0x1235)
PREFIXES = ((), (0x3e,), (0xf3, 0x26))


def signed(value):
    return value if value < 0x8000 else value - 0x10000


class WordFault(Exception):
    pass


class Case:
    def __init__(self, code, sp, bp, seed, prefix=()):
        self.code = [*prefix, *code]
        self.initial = [(0x1357 * (i + 1) + seed * 0x2469) & 0xffff for i in range(8)]
        self.initial[4:6] = sp, bp
        self.expected = self.initial.copy()
        self.flags = 2 | ((seed * 0x495) & 0xcd5)
        self.seed = seed
        self.before = {}
        self.memory = {}
        self.transactions = []
        self.fault = 0

    def ensure(self, address):
        for a in range(address - 1, address + 3):
            if a not in self.before:
                value = (a * 29 + (a >> 8) + self.seed * 53) & 255
                self.before[a] = self.memory[a] = value

    def transfer(self, address, value=None):
        self.ensure(address)
        write = value is not None
        if write:
            self.memory[address] = value & 255
            self.memory[address + 1] = value >> 8
        else:
            value = self.memory[address] | self.memory[address + 1] << 8
        if address & 1:
            self.transactions.extend(((int(write), address, 0, (value & 255) << 8),
                                      (int(write), address + 1, 1, value >> 8)))
        else:
            self.transactions.append((int(write), address, 0, value))
        return value

    def push(self, value):
        offset = (self.expected[4] - 2) & 0xffff
        if offset == 0xffff:
            raise WordFault
        self.expected[4] = offset
        self.transfer(SS_BASE + self.expected[4], value)

    def pop(self):
        value = self.transfer(SS_BASE + self.expected[4])
        self.expected[4] = (self.expected[4] + 2) & 0xffff
        return value

    def row(self):
        result = [len(self.code), *self.code, *([0] * (8 - len(self.code))),
                  self.flags, *self.initial, *self.expected, self.fault, self.seed % 3,
                  len(self.before)]
        for a, v in sorted(self.before.items()):
            result.extend((a, v))
        result.append(len(self.memory))
        for a, v in sorted(self.memory.items()):
            result.extend((a, v))
        result.append(len(self.transactions))
        for transaction in self.transactions:
            result.extend(transaction)
        return result


def frame_case(opcode, sp, bp, seed, prefix=(), allocation=0, nesting=0):
    code = [opcode, allocation & 255, allocation >> 8, nesting] if opcode == 0xc8 else [opcode]
    case = Case(code, sp, bp, seed, prefix)
    level = nesting % 32
    if opcode == 0x60:
        offsets = [(sp - 2 * i) & 0xffff for i in range(1, 9)]
    elif opcode == 0x61:
        offsets = [(sp + 2 * i) & 0xffff for i in range(8)]
    elif opcode == 0xc9:
        offsets = [bp]
    else:
        offsets = [(sp - 2 * i) & 0xffff for i in range(1, (level + 1 if level else 1) + 1)]
        offsets += [(bp - 2 * i) & 0xffff for i in range(1, level)]
    for offset in offsets:
        case.ensure(SS_BASE + offset)
    if opcode != 0xc8 and 0xffff in offsets:
        case.fault = 13
    elif opcode == 0x60:
        for value in case.initial:
            case.push(value)
    elif opcode == 0x61:
        for index in (7, 6, 5, 4, 3, 2, 1, 0):
            value = case.pop()
            if index != 4:
                case.expected[index] = value
    elif opcode == 0xc9:
        case.expected[4] = bp
        case.expected[5] = case.pop()
    else:
        try:
            case.push(bp)
            frame = case.expected[4]
            if level:
                for i in range(1, level):
                    offset = (bp - 2 * i) & 0xffff
                    if offset == 0xffff:
                        raise WordFault
                    case.push(case.transfer(SS_BASE + offset))
                case.push(frame)
            case.expected[5] = frame
            case.expected[4] = (case.expected[4] - allocation) & 0xffff
        except WordFault:
            case.fault = 13
            case.expected = case.initial.copy()
    return case


def bound_case(mode, reg, rm, seed, boundary=None):
    row = operand_record(16, 0, mode, reg, rm, seed % 6)
    code = row[2:2 + row[1]]
    index = int(code[0] == 0x3e)
    code[index] = 0x62
    initial = list(row[11:19])
    offset, segment = row[28:30]
    if boundary is not None:
        code = [0x62, (reg << 3) | 6, boundary & 255, boundary >> 8]
        offset, segment, mode = boundary, 3, 0
    prefix = (0x26, 0x2e, 0x36, 0x3e)[seed % 4]
    code = [prefix, *code]
    if index == 0 or boundary is not None:
        segment = seed % 4
    case = Case(code, initial[4], initial[5], seed)
    case.initial = initial
    case.expected = initial.copy()
    value = signed(initial[reg])
    variants = ((-32768, 32767), (value, value), (value + 1, 32767),
                (-32768, value - 1), (32767, -32768), (-1, 0), (0, 0), (-32768, -32768))
    lower, upper = (v & 0xffff for v in variants[seed % len(variants)])
    address = SEGMENTS[segment] * 16 + offset
    upper_address = SEGMENTS[segment] * 16 + ((offset + 2) & 0xffff)
    for a, value in ((address, lower), (upper_address, upper)):
        case.ensure(a)
        case.before[a] = case.memory[a] = value & 255
        case.before[a + 1] = case.memory[a + 1] = value >> 8
    if mode == 3:
        case.fault = 6
    elif 0xffff in (offset, (offset + 2) & 0xffff):
        case.fault = 13
    else:
        case.transfer(address)
        case.transfer(upper_address)
        if not signed(lower) <= signed(initial[reg]) <= signed(upper):
            case.fault = 5
    return case


def vectors():
    for opcode in (0x60, 0x61):
        for sp in SP_EDGES:
            for seed in range(4):
                for prefix in PREFIXES:
                    yield frame_case(opcode, sp, 0x2000 + seed, seed, prefix)
    for bp in SP_EDGES:
        for sp in (0, 1, 0x4321, 0xffff):
            for prefix in PREFIXES:
                yield frame_case(0xc9, sp, bp, bp % 7, prefix)
    for nesting in range(256):
        for sp, bp in ((0x2000, 0x4000), (0x2001, 0x4001), (0xfffe, 0), (0xffff, 0xffff)):
            for allocation in (0, 1, 0xffff):
                for prefix in ((), (0x3e,)):
                    yield frame_case(0xc8, sp, bp, nesting, prefix, allocation, nesting)
    for nesting in range(32):
        for sp, bp in ((1, 0x2000), (15, 0x2001), (31, 0x2000), (63, 0x2000),
                       (0x2000, 1), (0x2001, 15), (0x2000, 31), (0x2000, 63)):
            yield frame_case(0xc8, sp, bp, nesting, (0xf3, 0x26), 0x8000, nesting)
    for mode in range(4):
        for reg in range(8):
            for rm in range(8):
                for seed in range(8):
                    yield bound_case(mode, reg, rm, seed)
    for offset in range(0xfff8, 0x10000):
        for reg in range(8):
            for seed in range(8):
                yield bound_case(0, reg, 6, seed, offset)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    cases = list(vectors())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(f'{len(cases):x}\n' + ''.join(' '.join(f'{v:x}' for v in c.row()) + '\n' for c in cases))
    print(f'STACK_FRAME_VECTORS PASS: {len(cases)} independent frame/address/BOUND cases')


if __name__ == '__main__':
    main()
