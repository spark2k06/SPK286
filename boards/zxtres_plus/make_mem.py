#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Memory images for the ZXTRES+ demo, one 16-bit hex word per line.

  make_mem.py rom  DEMO_BIN OUT   64 KiB ROM image, little-endian words
  make_mem.py text OUT            initial text screen
  make_mem.py font FONT_HEX OUT   8x8 font, one byte per line

The initial screen says the CPU has not drawn anything yet, so a board that
shows only this message has video but no running CPU.
"""
from pathlib import Path
import sys


def rom(source, target):
    data = Path(source).read_bytes()
    if len(data) != 0x10000:
        sys.exit(f'{source}: {len(data)} bytes, expected 65536')
    words = [data[i] | (data[i + 1] << 8) for i in range(0, len(data), 2)]
    Path(target).write_text(''.join(f'{word:04x}\n' for word in words))


def text(target):
    words = [0x0720] * 2048
    lines = [
        (10, 'SPK286 ZXTRES+ demo'),
        (12, 'The CPU has not written to the screen yet.'),
        (13, 'If this stays, video works but the CPU is not running:'),
        (14, 'see the status line at the bottom.'),
    ]
    for row, message in lines:
        column = (80 - len(message)) // 2
        for offset, character in enumerate(message):
            words[row * 80 + column + offset] = 0x4F00 | ord(character)
    Path(target).write_text(''.join(f'{word:04x}\n' for word in words))


def font(source, target):
    values = [int(line, 16) for line in Path(source).read_text().split()]
    if len(values) != 1024:
        sys.exit(f'{source}: {len(values)} entries, expected 1024')
    Path(target).write_text(''.join(f'{value:02x}\n' for value in values))


def main():
    kind = sys.argv[1] if len(sys.argv) > 1 else ''
    if kind == 'rom' and len(sys.argv) == 4:
        rom(sys.argv[2], sys.argv[3])
    elif kind == 'text' and len(sys.argv) == 3:
        text(sys.argv[2])
    elif kind == 'font' and len(sys.argv) == 4:
        font(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
