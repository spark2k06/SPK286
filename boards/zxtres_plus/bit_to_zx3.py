#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Convert a Vivado .bit file to a ZXTRES .ZX3 core file.

  bit_to_zx3.py INPUT.bit OUTPUT.ZX3

A .ZX3 core is the raw configuration data of the .bit file, without its
header, padded with zero bytes to a multiple of 16 KiB. This is the "full"
output of bit2bin_zx3 in github.com/zxtres/tools, which the ZXTRES BIOS and
the .zx3 command load.
"""
from pathlib import Path
import struct
import sys

BLOCK = 0x4000


def bitstream_data(raw):
    # Header: a length-prefixed field, the 16-bit key 0x0001, then fields
    # 'a' (design), 'b' (part), 'c' (date), 'd' (time), each with a 16-bit
    # length, and 'e' with a 32-bit length followed by the data.
    (length,) = struct.unpack_from('>H', raw, 0)
    position = 2 + length
    (key,) = struct.unpack_from('>H', raw, position)
    if key != 1:
        sys.exit('not a Xilinx .bit file')
    position += 2
    fields = {}
    while position < len(raw):
        key = raw[position:position + 1]
        position += 1
        if key == b'e':
            (length,) = struct.unpack_from('>I', raw, position)
            position += 4
            data = raw[position:position + length]
            if len(data) != length:
                sys.exit(f'truncated bitstream: {len(data)} of {length} bytes')
            return fields, data
        (length,) = struct.unpack_from('>H', raw, position)
        position += 2
        fields[key.decode()] = raw[position:position + length].rstrip(b'\0').decode()
        position += length
    sys.exit('no bitstream data field in the .bit file')


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    fields, data = bitstream_data(Path(sys.argv[1]).read_bytes())
    padded = data + bytes(-len(data) % BLOCK)
    Path(sys.argv[2]).write_bytes(padded)
    print(f"design {fields.get('a', '?')}, part {fields.get('b', '?')}, "
          f"{len(data)} bytes -> {len(padded)} bytes ({len(padded) // BLOCK} x 16 KiB)")


if __name__ == '__main__':
    main()
