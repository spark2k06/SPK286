"""Lossless canonical raw-word disassembly; no inferred MCL86 mnemonics."""

import argparse
from pathlib import Path
import sys

from research.mcl86.mcl86_ucasm import FormatError, read_mem, validate_words


def disassemble(words) -> str:
    validate_words(words)
    return "".join(f"p 00 00000 00001 {address:04X}\n"
                   f"p 01 00000 00001 {word >> 16:04X}\n"
                   f"p 01 00000 00001 {word & 0xffff:04X}\n"
                   for address, word in enumerate(words))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    words = read_mem(args.source.read_text(encoding="utf-8"), str(args.source))
    args.output.write_bytes(disassemble(words).encode("ascii"))
    print("MCL86 DISASSEMBLY PASS: 4096 words")


if __name__ == "__main__":
    try:
        main()
    except (FormatError, OSError, UnicodeError) as error:
        print(f"MCL86 ERROR: {error}", file=sys.stderr)
        sys.exit(2)
