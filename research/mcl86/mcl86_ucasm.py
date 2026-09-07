"""Assemble the observed MCL86 programming stream into a 4096 x 32 ROM."""

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import sys

DEPTH = 4096


class FormatError(ValueError):
    """Invalid source or image, with source location."""


@dataclass(frozen=True)
class Image:
    words: tuple[int, ...]
    addresses: tuple[int, ...]
    controls: tuple[tuple[int, int], ...]
    delays: tuple[str, ...]


def assemble(source: str, name: str = "<source>") -> Image:
    words = [0] * DEPTH
    assigned = {}
    controls = []
    delays = []
    pending = None
    high = None
    exited = False
    for line, raw in enumerate(source.splitlines(), 1):
        text = re.split(r"//|#", raw, maxsplit=1)[0].strip()
        if not text or re.fullmatch(r"-+", text):
            continue

        def fail(message):
            raise FormatError(f"{name}:{line}: {message}")

        if exited:
            fail("directive after x")
        if text == "x" or re.fullmatch(r"d [0-9]+", text):
            if pending is not None:
                fail("incomplete word before control directive")
            if text == "x":
                exited = True
            else:
                # Delay units/radix are not specified by the public stream.
                delays.append(text[2:])
            continue
        match = re.fullmatch(r"p (00|01) 00000 (00001|00010) ([0-9A-Fa-f]{4})", text)
        if not match:
            fail("invalid directive; expected p 00/01 00000 00001/00010 HHHH, d digits, or x")
        command, target, value = match.groups()
        value = int(value, 16)
        if command == "00":
            if pending is not None:
                fail("incomplete word before new address")
            if target == "00001":
                if value >= DEPTH:
                    fail(f"ROM address 0x{value:04x} out of range")
                if value in assigned:
                    fail(f"duplicate ROM address 0x{value:03x}; first assigned at line {assigned[value]}")
            pending = (target, value, line)
            high = None
        else:
            if pending is None:
                fail("data half without an address")
            if pending[0] != target:
                fail("target changed within word")
            if high is None:
                high = value
            else:
                word = (high << 16) | value
                _, address, start = pending
                if target == "00001":
                    words[address] = word
                    assigned[address] = start
                else:
                    controls.append((address, word))
                pending = None
                high = None
    if pending is not None:
        raise FormatError(f"{name}:{pending[2]}: incomplete word at end of source")
    if not assigned:
        raise FormatError(f"{name}:1: no ROM words")
    return Image(tuple(words), tuple(sorted(assigned)), tuple(controls), tuple(delays))


def validate_words(words):
    if len(words) != DEPTH:
        raise FormatError(f"ROM size {len(words)}; expected {DEPTH} words")
    for address, word in enumerate(words):
        if type(word) is not int or not 0 <= word <= 0xffffffff:
            raise FormatError(f"ROM address 0x{address:03x}: invalid 32-bit word {word!r}")


def read_mem(source: str, name: str = "<ROM>") -> tuple[int, ...]:
    """Read the dense known-value readmemh subset used by both public images."""
    words = []
    for line, raw in enumerate(source.splitlines(), 1):
        for token in re.split(r"//|#", raw, maxsplit=1)[0].split():
            if not re.fullmatch(r"[0-9a-fA-F]{8}", token):
                raise FormatError(f"{name}:{line}: invalid 32-bit word {token!r}")
            words.append(int(token, 16))
    validate_words(words)
    return tuple(words)


def mem_bytes(words) -> bytes:
    validate_words(words)
    return "".join(f"{word:08x}\n" for word in words).encode("ascii")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = assemble(args.source.read_text(encoding="utf-8"), str(args.source))
    args.output.write_bytes(mem_bytes(result.words))
    print(f"MCL86 ASSEMBLY PASS: {len(result.addresses)} assigned, {DEPTH-len(result.addresses)} zero-filled")


if __name__ == "__main__":
    try:
        main()
    except (FormatError, OSError, UnicodeError) as error:
        print(f"MCL86 ERROR: {error}", file=sys.stderr)
        sys.exit(2)
