# SPDX-License-Identifier: MIT
"""Independent ordered memory/port oracle with retained irreversible effects."""
import argparse
from pathlib import Path
from tools.string_instruction_vectors import StringCase
from tools.stack_frame_vectors import SEGMENTS, WordFault


def port_byte(address):
    return (address * 73 + 0x35) & 255


class StringIoCase(StringCase):
    def __init__(self, opcode, repeat, override, df, offset, cx, port, seed):
        super().__init__(opcode, repeat, override, df, offset, offset, cx, seed)
        self.initial[2] = port
        self.expected = self.initial.copy()
        self.port = port

    def port_transfer(self, value=None):
        write = value is not None
        if not write:
            value = sum(port_byte(self.port+b) << (8*b) for b in range(self.width))
        # Bit 1 distinguishes I/O from memory in the independent bus trace.
        kind = 2 + int(write)
        if self.width == 2 and self.port & 1:
            self.transactions.extend(((kind, self.port, 0, (value & 255) << 8),
                                      (kind, self.port+1, 1, (value >> 8) & 255)))
        else:
            self.transactions.append((kind, self.port,
                                      int(self.width == 1 and not self.port & 1),
                                      (value & ((1 << (8*self.width))-1)) << (8 if self.port & 1 else 0)))
        return value

    def calculate(self):
        source = 3 if self.override is None else self.override
        count = self.initial[1] if self.repeat else 1
        for _ in range(count):
            self.decrement()
            try:
                if self.opcode in (0x6c, 0x6d):
                    value = self.port_transfer()
                    try:
                        self.access(7, 0, value)
                    except WordFault:
                        self.decrement()
                        raise
                else:
                    value = self.access(6, source)
                    self.port_transfer(value)
            except WordFault:
                self.fault = 13
                break
        return self


def records():
    seed = 0
    for opcode in (0x6c, 0x6d, 0x6e, 0x6f):
        for repeat in (0, 1, 2):
            for override in (None, 0, 1, 2, 3):
                for df in (0, 1):
                    for offset in (0, 1, 0xfffc, 0xfffd, 0xfffe, 0xffff):
                        for cx in (0, 1, 2, 7):
                            for port in (0, 1, 0xfffe, 0xffff):
                                case = StringIoCase(opcode, repeat, override, df, offset, cx, port, seed)
                                source = 3 if override is None else override
                                count = cx if repeat else 1
                                delta = -case.width if df else case.width
                                for step in range(count):
                                    addr = (SEGMENTS[source] << 4) + ((offset+step*delta) & 65535)
                                    case.initialize(addr, (0x793d + seed*17 + step*0x927) & 65535)
                                    case.ensure((SEGMENTS[0] << 4) + ((offset+step*delta) & 65535))
                                yield case.calculate().row()
                                seed += 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    rows = list(records())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(f'{len(rows):x}\n' + ''.join(' '.join(f'{v:x}' for v in row)+'\n' for row in rows))
    print(f'STRING_IO_VECTORS PASS: {len(rows)} independent ordered memory/port cases')


if __name__ == '__main__':
    main()
