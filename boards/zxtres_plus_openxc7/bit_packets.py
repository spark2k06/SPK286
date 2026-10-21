#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""List the configuration packets of a Xilinx 7-series .bit file: the words
before the sync word, then every register write and command, with frame
data (FDRI) summarized. Used to compare an openXC7 bitstream with a Vivado
one for the ZXTRES+.

  bit_packets.py FILE.bit
"""
from pathlib import Path
import struct
import sys

REGISTERS = {0: "CRC", 1: "FAR", 2: "FDRI", 3: "FDRO", 4: "CMD", 5: "CTL0", 6: "MASK",
             7: "STAT", 8: "LOUT", 9: "COR0", 10: "MFWR", 11: "CBC", 12: "IDCODE",
             13: "AXSS", 14: "COR1", 16: "WBSTAR", 17: "TIMER", 19: "RBCRC_SW",
             22: "BOOTSTS", 24: "CTL1", 31: "BSPI"}
COMMANDS = {0: "NULL", 1: "WCFG", 2: "MFW", 3: "LFRM", 4: "RCFG", 5: "START", 6: "RCAP",
            7: "RCRC", 8: "AGHIGH", 9: "SWITCH", 10: "GRESTORE", 11: "SHUTDOWN",
            12: "GCAPTURE", 13: "DESYNC", 15: "IPROG", 16: "CRCC", 17: "LTIMER"}


def configuration_data(data):
    """The bytes after the .bit header (field 'e'), or the whole file."""
    if data[:2] == b"\x00\x09":
        offset = 2 + 9 + 2 + 1
        while offset < len(data):
            key = data[offset - 1:offset]
            if key == b"e":
                length = struct.unpack(">I", data[offset:offset + 4])[0]
                return data[offset + 4:offset + 4 + length]
            length = struct.unpack(">H", data[offset:offset + 2])[0]
            offset += 2 + length + 1
    return data


def packets(data):
    words = struct.unpack(f">{len(data) // 4}I", data[:len(data) // 4 * 4])
    sync = words.index(0xAA995566)
    yield "pre-sync", " ".join(f"{w:08x}" for w in words[:sync] if w != 0xFFFFFFFF), \
        f"({sum(1 for w in words[:sync] if w == 0xFFFFFFFF)} dummy words)"
    i = sync + 1
    register = None
    while i < len(words):
        word = words[i]
        kind = word >> 29
        if kind == 1:
            op = (word >> 27) & 3
            register = (word >> 13) & 0x1F
            count = word & 0x7FF
            body = words[i + 1:i + 1 + count]
            i += 1 + count
        elif kind == 2:
            op = (word >> 27) & 3
            count = word & 0x7FFFFFF
            body = words[i + 1:i + 1 + count]
            i += 1 + count
        else:
            i += 1
            continue
        if op != 2 or count == 0:
            continue
        name = REGISTERS.get(register, f"R{register}")
        if name == "FDRI" or count > 4:
            yield name, f"{count} words", ""
        elif name == "CMD":
            yield name, " ".join(COMMANDS.get(w, f"{w:x}") for w in body), ""
        else:
            yield name, " ".join(f"{w:08x}" for w in body), ""


def main(path):
    for name, value, note in packets(configuration_data(Path(path).read_bytes())):
        print(f"{name:9s} {value} {note}".rstrip())


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
