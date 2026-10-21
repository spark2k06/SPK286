#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Decode the configuration frames a 7-series bitstream writes, compressed
or not, and compare two bitstreams frame by frame.

  decode_frames.py PART_YAML A.bit B.bit

prjxray's bitread does not follow the multiple frame write (CMD MFW and
MFWR) of compressed bitstreams, so this models the configuration logic as
Vivado's bitstreams use it:

- FDRI data is cut into 101-word frames. Each frame is held in the frame
  buffer and written to the frame address only when the next frame
  arrives; the address then advances in configuration order (part.yaml,
  with two pad positions after each row). A CMD WCFG empties the buffer.
- After CMD MFW, every MFWR write copies the frame in the buffer to the
  current frame address.

The result is the contents of every frame address. Both files must give the
same contents for every address the part has; addresses neither writes
count as zero frames.
"""
from pathlib import Path
import struct
import sys

import compress_bitstream as cb

WORDS = 101


def decode(path, order):
    _, config = cb.split_bit(Path(path).read_bytes())
    words = struct.unpack(f">{len(config) // 4}I", config)
    position = {address: index for index, address in enumerate(order) if address is not None}
    frames = {}
    pos = 0
    held = None
    partial = []
    register = None
    i = words.index(cb.SYNC) + 1

    def frame_data(values):
        nonlocal pos, held, partial
        for value in values:
            partial.append(value)
            if len(partial) == WORDS:
                if held is not None:
                    if pos < len(order) and order[pos] is not None:
                        frames[order[pos]] = held
                    pos += 1
                held = tuple(partial)
                partial = []

    while i < len(words):
        word = words[i]
        kind = word >> 29
        if kind == 1:
            op, register, count = (word >> 27) & 3, (word >> 13) & 0x1F, word & 0x7FF
            body = words[i + 1:i + 1 + count]
            i += 1 + count
        elif kind == 2:
            op, count = (word >> 27) & 3, word & 0x7FFFFFF
            body = words[i + 1:i + 1 + count]
            i += 1 + count
        else:
            i += 1
            continue
        if op != 2 or not body:
            continue
        if register == cb.REG_FAR:
            # Both tools park FAR outside the array (03BE0000h) after START.
            pos = position.get(body[0], len(order))
        elif register == cb.REG_CMD:
            if body[0] in (cb.CMD_WCFG, cb.CMD_MFW):
                if body[0] == cb.CMD_WCFG:
                    held = None
                partial = []
        elif register == cb.REG_FDRI:
            frame_data(body)
        elif register == cb.REG_MFWR:
            if held is None:
                sys.exit(f"{path}: MFWR with an empty frame buffer")
            frames[order[pos]] = held
    return frames


def main(part_yaml, first, second):
    order = cb.frame_addresses(part_yaml)
    zero = (0,) * WORDS
    a = decode(first, order)
    b = decode(second, order)
    addresses = [x for x in order if x is not None]
    different = [x for x in addresses if a.get(x, zero) != b.get(x, zero)]
    nonzero = sum(1 for x in addresses if a.get(x, zero) != zero)
    print(f"{len(addresses)} frame addresses, {nonzero} non-zero in {Path(first).name}, "
          f"{len(a)} and {len(b)} written, {len(different)} different")
    for x in different[:10]:
        print(f"  {x:08x}")
    print("FRAMES IDENTICAL" if not different else "FRAMES DIFFER")
    return 1 if different else 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
