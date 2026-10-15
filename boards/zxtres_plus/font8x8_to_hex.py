#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Make font8x8.hex from font8x8_basic.h (github.com/dhepper/font8x8,
public domain).

  font8x8_to_hex.py font8x8_basic.h font8x8.hex

The text screen draws characters 20h-9Fh from a 1024-byte font, eight rows
per character, bit 7 the leftmost pixel. font8x8_basic covers 00h-7Fh with
bit 0 the leftmost pixel, so each row is bit-reversed; 80h-9Fh stay blank.
"""
from pathlib import Path
import re
import sys


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    source = Path(sys.argv[1]).read_text()
    rows = re.findall(r'\{((?:\s*0x[0-9A-Fa-f]{2}\s*,?){8})\}', source)
    if len(rows) != 128:
        sys.exit(f'{sys.argv[1]}: {len(rows)} characters, expected 128')
    glyphs = [[int(value, 16) for value in re.findall(r'0x[0-9A-Fa-f]{2}', row)] for row in rows]
    reverse = [int(f'{value:08b}'[::-1], 2) for value in range(256)]
    font = []
    for character in range(0x20, 0xA0):
        glyph = glyphs[character] if character < 0x80 else [0] * 8
        font.extend(reverse[value] for value in glyph)
    Path(sys.argv[2]).write_text(''.join(f'{value:02x}\n' for value in font))


if __name__ == '__main__':
    main()
