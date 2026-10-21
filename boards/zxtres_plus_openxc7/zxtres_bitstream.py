#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Give a prjxray bitstream the ZXTRES+ flash read settings Vivado writes.

  zxtres_bitstream.py INPUT.bit OUTPUT.bit

The ZXTRES+ cores are built with SPI_BUSWIDTH 4 and SPI_32BIT_ADDR YES:
right after the sync word and its NOOP, Vivado writes BSPI = 0000026Ch
(quad output read, opcode 6Ch, with 4-byte addresses) and the BSPI_READ
command, then a NOOP, so the rest of the core is read from the flash in
that mode. xc7frames2bit has no such options. This inserts the same five
words at the same place, before the first RCRC, so they stay outside the
CRC, and pads the dummy words before the sync word to Vivado's 74. The
frame data and every later packet are unchanged.
"""
from pathlib import Path
import struct
import sys

SYNC = 0xAA995566
NOOP = 0x20000000
DUMMY = 0xFFFFFFFF
BUS_WIDTH = (0x000000BB, 0x11220044)
FLASH_READ = (0x3003E001, 0x0000026C,      # type 1 write BSPI
              0x30008001, 0x00000012,      # type 1 write CMD: BSPI_READ
              NOOP)
VIVADO_DUMMIES = 74


def split_bit(data):
    """Return (header up to the 'e' length field, configuration bytes)."""
    if data[:2] != b"\x00\x09":
        sys.exit("not a .bit file")
    offset = 2 + 9 + 2 + 1
    while offset < len(data):
        key = data[offset - 1:offset]
        if key == b"e":
            length = struct.unpack(">I", data[offset:offset + 4])[0]
            return data[:offset], data[offset + 4:offset + 4 + length]
        length = struct.unpack(">H", data[offset:offset + 2])[0]
        offset += 2 + length + 1
    sys.exit("no configuration data field")


def patch(words):
    sync = words.index(SYNC)
    pre = words[:sync]
    if any(w not in (DUMMY,) + BUS_WIDTH for w in pre) or tuple(pre[-4:-2]) != BUS_WIDTH:
        sys.exit("unexpected words before the sync word")
    if words[sync + 1] != NOOP:
        sys.exit("no NOOP after the sync word")
    if 0x3003E001 in words[sync:sync + 64]:
        sys.exit("the bitstream already writes BSPI")
    dummies = sum(1 for w in pre if w == DUMMY)
    padded = [DUMMY] * max(0, VIVADO_DUMMIES - dummies) + list(pre)
    return padded + [SYNC, NOOP] + list(FLASH_READ) + list(words[sync + 2:])


def main(source, target):
    header, config = split_bit(Path(source).read_bytes())
    if len(config) % 4:
        sys.exit("configuration data is not a whole number of words")
    words = patch(list(struct.unpack(f">{len(config) // 4}I", config)))
    body = struct.pack(f">{len(words)}I", *words)
    Path(target).write_bytes(header + struct.pack(">I", len(body)) + body)
    print(f"{target}: {len(body)} configuration bytes, flash read set to quad, 4-byte addresses")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
