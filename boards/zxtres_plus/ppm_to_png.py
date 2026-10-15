#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Convert the binary PPM frames of the demo simulation to PNG.

  ppm_to_png.py INPUT.ppm OUTPUT.png
"""
from pathlib import Path
import struct
import sys
import zlib


def read_ppm(path):
    data = Path(path).read_bytes()
    fields, position = [], 0
    while len(fields) < 4:
        while data[position:position + 1].isspace():
            position += 1
        start = position
        while not data[position:position + 1].isspace():
            position += 1
        fields.append(data[start:position])
    position += 1
    if fields[0] != b'P6':
        sys.exit(f'{path}: not a binary PPM')
    width, height, maximum = (int(field) for field in fields[1:])
    pixels = data[position:position + width * height * 3]
    if len(pixels) != width * height * 3:
        sys.exit(f'{path}: truncated, {len(pixels)} of {width * height * 3} bytes')
    scale = bytes(round(value * 255 / maximum) if value <= maximum else 255 for value in range(256))
    return width, height, pixels.translate(scale)


def write_png(path, width, height, pixels):
    def chunk(kind, payload):
        return (struct.pack('>I', len(payload)) + kind + payload +
                struct.pack('>I', zlib.crc32(kind + payload) & 0xFFFFFFFF))
    stride = width * 3
    raw = b''.join(b'\x00' + pixels[row * stride:(row + 1) * stride] for row in range(height))
    Path(path).write_bytes(b'\x89PNG\r\n\x1a\n' +
                           chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) +
                           chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    write_png(sys.argv[2], *read_ppm(sys.argv[1]))


if __name__ == '__main__':
    main()
