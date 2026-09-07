"""Audit encoding 1 using emitted RTL and canonical DSL reconstruction.

This is an offline checker for the existing generated case-ROM template, not a
general Verilog parser or a new production ROM format. Entry/label sidecars are
necessary because raw control words do not encode symbolic names or boundaries.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

from tools.microcode.compile_microcode import (
    CompileError, Location, ROOT, compile_sources, emit, encode, generate,
)

# Independent decoding of the documented encoding-1 wire representation.
STATEMENTS = {1: "FETCH_IMM16 -> TMP0", 2: "TMP0 -> DST", 3: "END"}


def validate_entries(program, expected):
    for name, address in expected.items():
        if name not in program.entries:
            raise CompileError(Location("<entry-contract>", 1), f"missing required entry {name}")
        actual = program.entries[name]
        if actual != address:
            raise CompileError(program.operations[actual].location,
                               f"entry {name} moved: expected {address}, got {actual}")


def read_generated_words(package: str, rom: str) -> tuple[int, ...]:
    def dimension(name):
        matches = re.findall(rf"localparam integer {name} = ([0-9]+);", package)
        if len(matches) != 1:
            raise ValueError(f"expected one generated {name} declaration")
        return int(matches[0])

    depth = dimension("MC_DEPTH")
    width = dimension("MC_ADDR_WIDTH")
    if dimension("MC_WORD_WIDTH") != 2 or not 1 <= width <= 12 or not 1 <= depth <= 1 << width:
        raise ValueError("invalid encoding-1 ROM dimensions")
    constants = re.findall(r"MC_([A-Z0-9_]+) = 2'd([0-9]+);", package)
    values = {}
    for name, value in constants:
        if name in values:
            raise ValueError(f"duplicate ROM constant {name}")
        values[name] = int(value)
    if {name: values.get(name) for name in ("INVALID", "FETCH_IMM16", "MOVE", "END")} != {
            "INVALID": 0, "FETCH_IMM16": 1, "MOVE": 2, "END": 3}:
        raise ValueError("unexpected encoding-1 operation constants")
    words = [0] * depth
    seen = set()
    for bits, address, operation in re.findall(
            r"([0-9]+)'d([0-9]+): word = spk286_microcode_pkg::MC_([A-Z0-9_]+);", rom):
        address = int(address)
        if int(bits) != width or address >= depth:
            raise ValueError(f"ROM address {address} out of range or wrong width")
        if address in seen:
            raise ValueError(f"duplicate ROM address {address}")
        if operation not in ("FETCH_IMM16", "MOVE", "END"):
            raise ValueError(f"invalid ROM operation {operation} at {address}")
        seen.add(address)
        words[address] = values[operation]
    if not seen or sorted(seen) != list(range(len(seen))):
        raise ValueError("generated operations must have contiguous unique addresses")
    return tuple(words)


def canonical_source(words, entries, labels=None):
    labels = {} if labels is None else labels
    if not words or any(type(w) is not int or w not in (0, 1, 2, 3) for w in words):
        raise ValueError("invalid encoding-1 ROM words")
    used = len(words)
    while used and words[used - 1] == 0:
        used -= 1
    if not used or 0 in words[:used]:
        raise ValueError("invalid word within used ROM")
    by_address = {}
    for name, address in entries.items():
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", name):
            raise ValueError(f"invalid entry name {name}")
        if type(address) is not int or not 0 <= address < used or address in by_address:
            raise ValueError(f"invalid or duplicate entry address {address}")
        if address and words[address - 1] != 3:
            raise ValueError(f"entry {name} is not at an END boundary")
        by_address[address] = name
    if 0 not in by_address:
        raise ValueError("missing entry at address 0")
    label_addresses = {}
    for symbol, address in sorted(labels.items()):
        match = re.fullmatch(r"([A-Z][A-Z0-9_]*)\.([a-z][a-z0-9_]*)", symbol)
        if not match or match[1] not in entries or type(address) is not int or not 0 <= address < used:
            raise ValueError(f"invalid label {symbol}")
        owner = by_address[max(a for a in by_address if a <= address)]
        if owner != match[1]:
            raise ValueError(f"label {symbol} outside its entry")
        label_addresses.setdefault(address, []).append(match[2])
    lines = ["microcode_format 1"]
    for address, word in enumerate(words[:used]):
        if address in by_address:
            lines.append(f"instruction {by_address[address]}:")
        elif address and words[address - 1] == 3:
            raise ValueError(f"missing entry after END at {address-1}")
        lines.extend(f"{label}:" for label in label_addresses.get(address, []))
        lines.append(f"    {STATEMENTS[word]}")
    source = "\n".join(lines) + "\n"
    # Reuse semantic validation, including TMP0 lifetime and the terminal END.
    compile_sources({"canonical.mc": source}, rom_depth=len(words))
    return source


def audit(output_dir, contract_path):
    sources = {p.relative_to(ROOT / "microcode/source").as_posix(): p.read_text(encoding="utf-8")
               for p in (ROOT / "microcode/source").rglob("*.mc")}
    program = compile_sources(sources)
    contract = json.loads(contract_path.read_text(encoding="utf-8"))
    validate_entries(program, contract["entries"])
    generated_dir = ROOT / "microcode/generated"
    if not emit(generate(program), generated_dir, check=True):
        raise ValueError("stale generated microcode")
    artifacts = {p.name: p.read_bytes() for p in generated_dir.iterdir() if p.is_file()}
    words = read_generated_words(artifacts["spk286_microcode_pkg.sv"].decode(),
                                 artifacts["spk286_microcode_rom.sv"].decode())
    symbols = json.loads(artifacts["spk286_microcode_symbols.json"])
    if (list(words) != contract["words"] or symbols["entries"] != contract["entries"]
            or symbols["labels"] != contract["labels"]
            or program.address_width != contract["address_width"]):
        raise ValueError("Phase 2.75 ROM/symbol contract changed")
    canonical = canonical_source(words, symbols["entries"], symbols["labels"])
    reconstructed = compile_sources({"canonical.mc": canonical},
                                    address_width=program.address_width, rom_depth=program.depth)
    roundtrip_words = read_generated_words(generate(reconstructed)["spk286_microcode_pkg.sv"],
                                          generate(reconstructed)["spk286_microcode_rom.sv"])
    if words != roundtrip_words or list(words) != [encode(op) for op in program.operations]:
        raise ValueError("source/RTL/round-trip word mismatch")
    if program.entries != reconstructed.entries or program.labels != reconstructed.labels:
        raise ValueError("round-trip symbol mismatch")
    report = {"schema_version": 1, "validation": "PASS", "roundtrip": "PASS",
              "baseline": contract["baseline"], "entries": program.entries,
              "words": words, "source_sha256": program.source_hashes,
              "artifact_sha256": {name: hashlib.sha256(data).hexdigest()
                                  for name, data in sorted(artifacts.items())}}
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "canonical.mc").write_bytes(canonical.encode())
    (output_dir / "audit.json").write_bytes((json.dumps(report, sort_keys=True, indent=2)+"\n").encode())
    print("MICROCODE AUDIT PASS: Phase 2.75 entries, emitted ROM, source coupling and round-trip")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/microcode-audit")
    parser.add_argument("--contract", type=Path,
                        default=ROOT / "tests/fixtures/microcode_phase2_75.json")
    args = parser.parse_args()
    audit(args.output, args.contract)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, UnicodeError) as error:
        print(f"MICROCODE AUDIT ERROR: {error}", file=sys.stderr)
        sys.exit(2)
