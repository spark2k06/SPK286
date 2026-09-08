"""Independent mathematical word ALU oracle and deterministic RTL vectors.

Signed range checks and nibble arithmetic deliberately differ from the RTL's
extended binary datapath and sign-bit equations. Undefined flags are masked.
"""
import argparse
from dataclasses import dataclass
from pathlib import Path
import random

OPERATIONS = ('ADD', 'OR', 'ADC', 'SBB', 'AND', 'SUB', 'XOR')
EDGES = (0, 1, 15, 16, 255, 256, 0x7ffe, 0x7fff, 0x8000, 0x8001,
         0xfffe, 0xffff, 0x5555, 0xaaaa)
ARITH_MASK = 0x08d5
LOGIC_MASK = 0x08c5


@dataclass(frozen=True)
class Result:
    value: int
    flags: int
    update_mask: int
    undefined_mask: int

    def commit(self, previous):
        return (previous & ~self.update_mask) | (self.flags & self.update_mask)


def evaluate(operation, a, b, carry=0):
    if operation not in (*OPERATIONS, 'CMP'):
        raise ValueError('invalid ALU operation')
    if not (0 <= a <= 65535 and 0 <= b <= 65535 and carry in (0, 1)):
        raise ValueError('invalid word/carry operand')
    signed_a = a if a < 32768 else a - 65536
    signed_b = b if b < 32768 else b - 65536
    flags = 0
    if operation in ('AND', 'OR', 'XOR'):
        value = {'AND': a & b, 'OR': a | b, 'XOR': a ^ b}[operation]
        mask, undefined = LOGIC_MASK, 0x10
    else:
        c = carry if operation in ('ADC', 'SBB') else 0
        subtract = operation in ('SUB', 'SBB', 'CMP')
        total = a - b - c if subtract else a + b + c
        signed_total = signed_a - signed_b - c if subtract else signed_a + signed_b + c
        nibble = a % 16 - b % 16 - c if subtract else a % 16 + b % 16 + c
        flags |= int(total < 0 if subtract else total >= 65536)
        flags |= int(nibble < 0 if subtract else nibble >= 16) << 4
        flags |= int(not -32768 <= signed_total <= 32767) << 11
        value = total % 65536
        mask, undefined = ARITH_MASK, 0
    flags |= int(sum((value >> bit) & 1 for bit in range(8)) % 2 == 0) << 2
    flags |= int(value == 0) << 6
    flags |= int(value >= 32768) << 7
    return Result(value, flags, mask, undefined)


def vectors():
    for op in OPERATIONS:
        for a in EDGES:
            for b in EDGES:
                for carry in (0, 1):
                    yield op, a, b, carry
    # Every low byte with differing high bytes catches accidental word parity.
    for a in range(256):
        for high in (0, 1, 0x80, 0xff):
            yield 'OR', a | (high << 8), 0, 0
    # Exhaust nibble operands with carry and contrasting sign/high-bit patterns.
    for op in ('ADD', 'ADC', 'SUB', 'SBB'):
        for a in range(16):
            for b in range(16):
                for high_a, high_b in ((0, 0), (0x7ff0, 0x7ff0), (0x8000, 0xfff0)):
                    for carry in (0, 1):
                        yield op, a | high_a, b | high_b, carry
    rng = random.Random(286)
    for _ in range(20000):
        yield rng.choice(OPERATIONS), rng.randrange(65536), rng.randrange(65536), rng.randrange(2)


def write_vectors(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with path.open('w', encoding='ascii', newline='\n') as output:
        for op, a, b, carry in vectors():
            result = evaluate(op, a, b, carry)
            output.write(f'{OPERATIONS.index(op):x} {a:04x} {b:04x} {carry:x} '
                         f'{result.value:04x} {result.flags:04x} {result.update_mask:04x}\n')
            count += 1
    return count


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(f'ALU_VECTORS PASS: {write_vectors(args.output)} deterministic cases')
