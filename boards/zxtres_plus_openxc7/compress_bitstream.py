#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Compress a prjxray 7-series bitstream the way Vivado's
BITSTREAM.GENERAL.COMPRESS does.

  compress_bitstream.py PART_YAML [FRAMES] INPUT.bit OUTPUT.bit

xc7frames2bit writes every configuration frame in one FDRI block. Here
frames with the same contents (within a block type) are written once and
copied to their other addresses with the multiple frame write (CMD MFW and
MFWR, with eight NOOPs after each in block RAM content), and the remaining
frames are written in runs within a column, each run followed by one pad
frame that pushes its last frame out of the frame buffer, as in Vivado's
compressed bitstreams. CTL1 bit 12 is set around the frame writes
as Vivado does there. The packets before and after the frames are kept.

PART_YAML (prjxray-db part.yaml) gives the frame addresses: block type,
half, row, column and minor in configuration order, with two pad frames at
the end of each row, which is how xc7frames2bit lays out its FDRI block.
When FRAMES (the fasm2frames output) is given, every frame it lists must be
found at its address, word for word except the ECC word, before anything is
written.
"""
from pathlib import Path
import re
import struct
import sys

WORDS = 101
NOOP = 0x20000000
SYNC = 0xAA995566
REG_FAR, REG_FDRI, REG_CMD, REG_MASK, REG_CTL1, REG_MFWR = 1, 2, 4, 6, 24, 10
CMD_WCFG, CMD_MFW = 1, 2
BUSES = {"CLB_IO_CLK": 0, "BLOCK_RAM": 1}
ECC_WORD = 50


def type1_write(register, words):
    return [0x30000000 | (register << 13) | len(words)] + list(words)


def frame_addresses(part_yaml):
    """[(address or None for a pad frame)] in xc7frames2bit order."""
    text = Path(part_yaml).read_text()
    columns = {}
    half = row = bus = column = None
    for line in text.splitlines():
        indent = len(line) - len(line.lstrip())
        stripped = line.strip()
        if indent == 2 and stripped.rstrip(":").split(":")[0] in ("top", "bottom"):
            half = 0 if stripped.startswith("top") else 1
        elif indent == 6 and re.match(r"\d+:", stripped):
            row = int(stripped.split(":")[0])
        elif indent == 10 and stripped.split(":")[0] in BUSES:
            bus = BUSES[stripped.split(":")[0]]
        elif indent == 10:
            bus = None
        elif indent == 14 and re.match(r"\d+:", stripped):
            column = int(stripped.split(":")[0])
        elif stripped.startswith("frame_count:") and bus is not None:
            columns[(bus, half, row, column)] = int(stripped.split(":")[1])
    order = []
    for bus in sorted(BUSES.values()):
        for half in (0, 1):
            rows = sorted({r for (b, h, r, _) in columns if b == bus and h == half})
            for row in rows:
                for column in sorted(c for (b, h, r, c) in columns
                                     if b == bus and h == half and r == row):
                    for minor in range(columns[(bus, half, row, column)]):
                        order.append((bus << 23) | (half << 22) | (row << 17) | (column << 7) | minor)
                order += [None, None]
    return order


def split_bit(data):
    if data[:2] != b"\x00\x09":
        sys.exit("not a .bit file")
    offset = 2 + 9 + 2 + 1
    while offset < len(data):
        if data[offset - 1:offset] == b"e":
            length = struct.unpack(">I", data[offset:offset + 4])[0]
            return data[:offset], data[offset + 4:offset + 4 + length]
        length = struct.unpack(">H", data[offset:offset + 2])[0]
        offset += 2 + length + 1
    sys.exit("no configuration data field")


def find_frame_block(words):
    """Index of the FAR write that starts the frames, and the FDRI data span."""
    i = words.index(SYNC) + 1
    far_index = None
    while i < len(words):
        word = words[i]
        if word >> 29 == 1 and (word >> 27) & 3 == 2:
            register, count = (word >> 13) & 0x1F, word & 0x7FF
            if register == REG_FAR and words[i + 1] == 0:
                far_index = i
            if register == REG_FDRI and count == 0 and words[i + 1] >> 29 == 2:
                length = words[i + 1] & 0x7FFFFFF
                return far_index, i, i + 2, i + 2 + length
            i += 1 + count
        else:
            i += 1
    sys.exit("no FDRI block")


def compress(words, order, frames_file=None):
    far_index, fdri_index, start, end = find_frame_block(words)
    data = words[start:end]
    if len(data) != len(order) * WORDS:
        sys.exit(f"FDRI holds {len(data) // WORDS} frames, the part has {len(order)} with padding")
    frames = {}
    for position, address in enumerate(order):
        frame = tuple(data[position * WORDS:(position + 1) * WORDS])
        if address is None:
            if any(frame):
                sys.exit(f"pad frame {position} is not empty")
        else:
            frames[address] = frame
    if frames_file:
        checked = 0
        for line in Path(frames_file).read_text().split("\n"):
            if not line.strip():
                continue
            address, values = line.split(" ", 1)
            expected = [int(v, 16) for v in values.split(",")]
            actual = frames[int(address, 16)]
            if any(a != e for index, (a, e) in enumerate(zip(actual, expected)) if index != ECC_WORD):
                sys.exit(f"frame {address} differs from {frames_file}")
            checked += 1
        print(f"{checked} frames of {frames_file} found at their addresses")

    # Frames with the same contents, within one block type, become one MFW
    # group each; the others are written in runs of consecutive minors
    # within a column. As in Vivado's bitstreams, block RAM content frames
    # (block type 1) get eight NOOPs after every MFWR.
    groups = {}
    for address in sorted(frames):
        groups.setdefault((address >> 23, frames[address]), []).append(address)
    body = []
    single = sorted(a for members in groups.values() if len(members) == 1 for a in members)
    for (block_type, content), members in sorted(groups.items(), key=lambda item: item[1][0]):
        if len(members) < 2:
            continue
        settle = [NOOP] * 8 if block_type == 1 else []
        body += type1_write(REG_FAR, [members[0]]) + type1_write(REG_CMD, [CMD_WCFG]) + [NOOP]
        body += type1_write(REG_FDRI, content)
        body += type1_write(REG_CMD, [CMD_MFW]) + [NOOP] * 12 + type1_write(REG_MFWR, [0] * 8) + settle
        for address in members[1:]:
            body += type1_write(REG_FAR, [address]) + type1_write(REG_MFWR, [0] * 4) + settle
    run = []
    for address in single + [None]:
        if run and (address is None or address != run[-1] + 1 or address >> 7 != run[0] >> 7):
            payload = [w for a in run for w in frames[a]] + [0] * WORDS
            body += type1_write(REG_CMD, [CMD_WCFG]) + [NOOP] + type1_write(REG_FAR, [run[0]]) + [NOOP]
            body += [0x30004000, 0x50000000 | len(payload)] + payload
            run = []
        if address is not None:
            run.append(address)

    head = words[:far_index]
    # Vivado's compressed bitstreams set CTL1 bit 12 with its mask before
    # the frames and clear it after LFRM.
    try:
        ctl1 = max(i for i in range(len(head) - 1) if head[i] == 0x30030001)
        if head[ctl1 - 2:ctl1 - 1] == [0x3000C001] and head[ctl1 - 1] == 0 and head[ctl1 + 1] == 0:
            head[ctl1 - 1] = 0x00001000
            head[ctl1 + 1] = 0x00001000
            set_ctl1 = True
        else:
            set_ctl1 = False
    except ValueError:
        set_ctl1 = False
    tail = list(words[end:])
    if set_ctl1:
        lfrm = next(i for i in range(len(tail) - 1) if tail[i] == 0x30008001 and tail[i + 1] == 3)
        tail[lfrm + 2:lfrm + 2] = type1_write(REG_MASK, [0x1000]) + type1_write(REG_CTL1, [0])
    return head + body + tail, len(frames), sum(1 for m in groups.values() if len(m) > 1)


def main(part_yaml, *rest):
    frames_file, source, target = (rest if len(rest) == 3 else (None,) + tuple(rest))
    header, config = split_bit(Path(source).read_bytes())
    words = list(struct.unpack(f">{len(config) // 4}I", config))
    out, count, groups = compress(words, frame_addresses(part_yaml), frames_file)
    body = struct.pack(f">{len(out)}I", *out)
    Path(target).write_bytes(header + struct.pack(">I", len(body)) + body)
    print(f"{target}: {count} frames, {groups} repeated contents, "
          f"{len(config)} -> {len(body)} configuration bytes")


if __name__ == "__main__":
    if len(sys.argv) not in (4, 5):
        sys.exit(__doc__)
    main(*sys.argv[1:])
