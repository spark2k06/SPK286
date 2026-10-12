# SPDX-License-Identifier: MIT
"""Generate directed CPU vectors from independent word ALU/EA arithmetic."""
import argparse
from pathlib import Path
from tools.alu_reference import evaluate, EDGES

FAMILIES = ('ADD', 'OR', 'ADC', 'SBB', 'AND', 'SUB', 'XOR', 'CMP')


def record(group, form, mode=3, reg=1, rm=0, disp=0, immediate=0, seed=0, alignment=0):
    registers = [0x800f, 0x7fff, 0xfffe, 0x2020, 0x4567, 0x3040, 0x0110, 0x0202]
    registers[reg] = EDGES[seed % len(EDGES)]
    registers[rm] = EDGES[(seed+5) % len(EDGES)] if mode == 3 else registers[rm]
    flags = (0x7fd7, 0x0002, 0x3013, 0x4506)[seed % 4]
    opcode = group*8 + (1 if form == 0 else 3 if form == 1 else 5)
    if form in (3, 4):
        opcode = 0x81 if form == 3 else 0x83
    code = [opcode]
    offset, segment = 0, 3
    memory = form != 2 and mode != 3
    if form != 2:
        encoded_reg = group if form in (3, 4) else reg
        code.append(mode*64 + encoded_reg*8 + rm)
        if mode == 1:
            code.append(disp & 255)
            disp = (disp & 255) - (256 if disp & 128 else 0)
        elif mode == 2 or mode == 0 and rm == 6:
            code += [disp & 255, (disp >> 8) & 255]
        else:
            disp = 0
        if memory:
            # Alter a participating base/index to exercise both physical alignments.
            index = (3, 3, 5, 5, 6, 7, 5, 3)[rm]
            bases = lambda: (registers[3]+registers[6], registers[3]+registers[7],
                            registers[5]+registers[6], registers[5]+registers[7],
                            registers[6], registers[7], registers[5], registers[3])
            if mode == 0 and rm == 6:
                disp = (disp & 0xfffe) | alignment
                code[-2:] = [disp & 255, disp >> 8]
                offset = disp
            else:
                if (bases()[rm]+disp) % 2 != alignment:
                    registers[index] = (registers[index]+1) % 65536
                offset = (bases()[rm]+disp) % 65536
            segment = 2 if rm in (2, 3) or rm == 6 and mode != 0 else 3
    if form in (2, 3):
        code += [immediate & 255, (immediate >> 8) & 255]
    elif form == 4:
        code.append(immediate & 255)
        immediate = (immediate & 255) | (0xff00 if immediate & 128 else 0)
    initial_memory = EDGES[(seed+3) % len(EDGES)]
    rm_value = initial_memory if memory else registers[rm]
    a, b = ((rm_value, registers[reg]) if form == 0 else
            (registers[reg], rm_value) if form == 1 else
            (registers[0], immediate) if form == 2 else (rm_value, immediate))
    result = evaluate(FAMILIES[group], a, b, flags & 1)
    expected = registers.copy()
    expected_memory = initial_memory
    blocked = memory and offset == 65535
    writing_memory = memory and form != 1 and group != 7
    if group != 7 and not blocked:
        if writing_memory:
            expected_memory = result.value
        else:
            destination = reg if form == 1 else 0 if form == 2 else rm
            expected[destination] = result.value
    length = len(code)
    code += [0xf4] * (8-len(code))
    return [length, *code, flags, *registers, result.commit(flags) if not blocked else flags,
            *expected, offset, segment, initial_memory, expected_memory,
            int(memory and not blocked), int(writing_memory and not blocked), seed % 4, int(blocked)]


def vectors():
    for group in range(8):
        for form in (0, 1):
            for reg in range(8):
                for rm in range(8):
                    yield record(group, form, reg=reg, rm=rm, seed=reg*8+rm)
        for form in (2, 3, 4):
            for i, immediate in enumerate((0, 1, 0x7f, 0x80, 0xff, 0x7fff, 0x8000, 0xffff)):
                for rm in range(8):
                    yield record(group, form, rm=rm, immediate=immediate, seed=i+rm)
        for form in (0, 1, 3, 4):
            for mode in range(3):
                for rm in range(8):
                    for d, disp in enumerate((0, 0x7f, 0xff80, 0x7fff, 0xffff)):
                        for alignment in (0, 1):
                            yield record(group, form, mode, reg=1, rm=rm, disp=disp,
                                         immediate=(0x80, 0x7fff, 0xffff, 1, 0)[d],
                                         seed=d+rm+group, alignment=alignment)


def write_vectors(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    records = list(vectors())
    with path.open('w', encoding='ascii', newline='\n') as output:
        output.write(f'{len(records):x}\n')
        for values in records:
            output.write(' '.join(f'{value:x}' for value in values)+'\n')
    return len(records)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(f'ALU_INSTRUCTION_VECTORS PASS: {write_vectors(args.output)} directed cases')
