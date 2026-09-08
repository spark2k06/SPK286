"""Audit encodings 1 through 11 using emitted RTL and canonical DSL reconstruction.

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
STATEMENTS = {1: "FETCH_IMM16 -> TMP0", 2: "TMP0 -> DST", 3: "END",
              4: "DECODE_MODRM", 5: "READ_REG16 -> TMP0", 6: "READ_RM16 -> TMP0",
              7: "TMP0 -> REG16", 8: "TMP0 -> RM16",
              9: "READ_REG16 -> TMP1", 10: "READ_RM16 -> TMP1",
              11: "FETCH_IMM16 -> TMP1", 12: "FETCH_IMM8S -> TMP1",
              13: "READ_DST16 -> TMP0", 14: "ALU DECODED TMP0, TMP1 -> TMP2 FLAGS_DECODED",
              15: "TMP2 -> REG16 IF_WRITE", 16: "TMP2 -> RM16 IF_WRITE",
              17: "TMP2 -> DST IF_WRITE", 18: "COMMIT_FLAGS", 19: "CHECK_RM16", 20: "FETCH_IMM8S -> TMP0",
              21: "PUSH16 DECODED TMP0", 22: "POP16 -> TMP0", 23: "READ_IP16 -> TMP0",
              24: "TARGET_REL16 TMP1", 25: "TARGET_ABS16 TMP0", 26: "REDIRECT DECODED",
              27: "ADJUST_SP16 TMP1", 28: "COUNT DECODED",
              29: 'FETCH_IMM8 -> TMP0', 30: 'READ_FLAGS -> TMP0', 31: 'RESTORE_FLAGS TMP0',
              32: 'SET_IF DECODED', 33: 'HALT', 34: 'REQUEST_EVENT DECODED', 35: 'EVENT_ACK',
              36: 'EVENT_FLAGS -> TMP0', 37: 'EVENT_CS -> TMP0', 38: 'EVENT_IP -> TMP0',
              39: 'CLEAR_IF_TF', 40: 'VECTOR_IP -> TMP0', 41: 'VECTOR_CS -> TMP1',
              42: 'CONTEXT_COMMIT TMP0 TMP1', 43: 'POP16 -> TMP1', 44: 'POP16 -> TMP2',
              45: 'IRET_COMMIT TMP0 TMP1 TMP2',
              46: 'READ_REG8 -> TMP0', 47: 'READ_RM8 -> TMP0', 48: 'TMP0 -> REG8', 49: 'TMP0 -> RM8',
              50: 'FETCH_IMM8 -> TMP1', 51: 'READ_REG8 -> TMP1', 52: 'READ_RM8 -> TMP1',
              53: 'READ_DST8 -> TMP0', 54: 'TMP0 -> DST8', 55: 'TMP2 -> REG8 IF_WRITE',
              56: 'TMP2 -> RM8 IF_WRITE', 57: 'TMP2 -> DST8 IF_WRITE',
              58: 'FLAGS DECODED', 59: 'SIGN_EXTEND8 TMP0', 60: 'SIGN_FILL16 TMP0', 61: 'CONST_ONE -> TMP1', 62: 'SHIFT DECODED TMP0 TMP1 -> TMP2 FLAGS_DECODED', 63: 'COUNT_LOW -> TMP1', 64: 'READ_EA -> TMP0', 65: 'TMP1 -> REG8', 66: 'TMP1 -> REG16', 67: 'READ_TARGET16 -> TMP1', 68: 'TMP1 -> SOURCE16', 69: 'SET_ADDRESS TMP1', 70: 'ADD_BASE TMP0 -> TMP1', 71: 'DISPATCH DECODED', 72: 'CONST_ZERO -> TMP1', 73: 'CONST_ONES -> TMP1', 74: 'ADJUST DECODED TMP0 TMP1 -> TMP2 FLAGS_DECODED', 75: 'CHECK_ARITHMETIC'}


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
    word_width = dimension("MC_WORD_WIDTH")
    if word_width not in (2, 4, 5, 6, 7) or not 1 <= width <= 12 or not 1 <= depth <= 1 << width:
        raise ValueError("invalid ROM dimensions")
    constants = re.findall(rf"MC_([A-Z0-9_]+) = {word_width}'d([0-9]+);", package)
    values = {}
    for name, value in constants:
        if name in values:
            raise ValueError(f"duplicate ROM constant {name}")
        values[name] = int(value)
    expected = {"INVALID": 0, "FETCH_IMM16": 1, "MOVE": 2, "END": 3}
    if word_width >= 4:
        expected.update(DECODE_MODRM=4, READ_REG16=5, READ_RM16=6, WRITE_REG16=7, WRITE_RM16=8)
    if word_width >= 5:
        expected.update(READ_REG16_TMP1=9, READ_RM16_TMP1=10, FETCH_IMM16_TMP1=11,
                        FETCH_IMM8S_TMP1=12, READ_DST16=13, ALU=14,
                        WRITE_RESULT_REG16=15, WRITE_RESULT_RM16=16,
                        WRITE_RESULT_DST=17, COMMIT_FLAGS=18)
    if dimension('MC_FORMAT_VERSION') >= 4:
        expected.update(CHECK_RM16=19, FETCH_IMM8S_TMP0=20, PUSH16=21, POP16=22,
                        READ_IP16=23, TARGET_REL16=24, TARGET_ABS16=25,
                        REDIRECT=26, ADJUST_SP16=27, COUNT=28)
    if dimension('MC_FORMAT_VERSION') >= 5:
        expected.update(FETCH_IMM8=29, READ_FLAGS=30, RESTORE_FLAGS=31, SET_IF=32,
                        HALT=33, REQUEST_EVENT=34, EVENT_ACK=35, EVENT_FLAGS=36,
                        EVENT_CS=37, EVENT_IP=38, CLEAR_IF_TF=39, VECTOR_IP=40,
                        VECTOR_CS=41, CONTEXT_COMMIT=42, POP16_TMP1=43,
                        POP16_TMP2=44, IRET_COMMIT=45)
    if dimension('MC_FORMAT_VERSION') >= 6:
        expected.update(READ_REG8=46, READ_RM8=47, WRITE_REG8=48, WRITE_RM8=49, FETCH_IMM8_TMP1=50,
                        READ_REG8_TMP1=51, READ_RM8_TMP1=52, READ_DST8=53, MOVE8=54,
                        WRITE_RESULT_REG8=55, WRITE_RESULT_RM8=56, WRITE_RESULT_DST8=57)
    if dimension('MC_FORMAT_VERSION') >= 7:
        expected.update(FLAGS_DECODED=58, SIGN_EXTEND8=59, SIGN_FILL16=60, CONST_ONE_TMP1=61)
    if dimension('MC_FORMAT_VERSION') >= 8:
        expected.update(SHIFT=62, COUNT_LOW_TMP1=63)
    if dimension('MC_FORMAT_VERSION') >= 9:
        expected.update(READ_EA=64, WRITE_REG8_TMP1=65, WRITE_REG16_TMP1=66, READ_TARGET16_TMP1=67, MOVE_SOURCE16_TMP1=68, SET_ADDRESS_TMP1=69, ADD_BASE_TMP0_TMP1=70)
    if dimension('MC_FORMAT_VERSION') >= 10:
        expected.update(DISPATCH_DECODED=71, CONST_ZERO_TMP1=72, CONST_ONES_TMP1=73)
    if dimension('MC_FORMAT_VERSION') >= 11:
        expected.update(ADJUST=74, CHECK_ARITHMETIC=75)
    if {name: values.get(name) for name in expected} != expected:
        raise ValueError("unexpected encoding operation constants")
    words = [0] * depth
    seen = set()
    for bits, address, operation in re.findall(
            r"([0-9]+)'d([0-9]+): word = spk286_microcode_pkg::MC_([A-Z0-9_]+);", rom):
        address = int(address)
        if int(bits) != width or address >= depth:
            raise ValueError(f"ROM address {address} out of range or wrong width")
        if address in seen:
            raise ValueError(f"duplicate ROM address {address}")
        if operation not in expected or operation == "INVALID":
            raise ValueError(f"invalid ROM operation {operation} at {address}")
        seen.add(address)
        words[address] = values[operation]
    if not seen or sorted(seen) != list(range(len(seen))):
        raise ValueError("generated operations must have contiguous unique addresses")
    return tuple(words)


def canonical_source(words, entries, labels=None):
    labels = {} if labels is None else labels
    if not words or any(type(w) is not int or w not in (0, *STATEMENTS) for w in words):
        raise ValueError("invalid ROM words")
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
        if address and words[address - 1] not in (3, 71):
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
    unary = any(tuple(words[i:i+7]) in ((4,47,61,14,56,18,3), (4,6,61,14,16,18,3)) for i in range(len(words)-6))
    version = 11 if any(w > 73 for w in words) else 10 if any(w > 70 for w in words) or unary else 9 if any(w > 63 for w in words) else 8 if any(w > 61 for w in words) else 7 if any(w > 57 for w in words) or any(tuple(words[i:i+2]) == (30, 54) for i in range(len(words)-1)) else 6 if any(w > 45 for w in words) else 5 if any(w > 28 for w in words) else (4 if any(w > 18 for w in words) else (3 if any(w > 8 for w in words) else (2 if any(w > 3 for w in words) else 1)))
    lines = [f"microcode_format {version}"]
    for address, word in enumerate(words[:used]):
        if address in by_address:
            lines.append(f"instruction {by_address[address]}:")
        elif address and words[address - 1] in (3, 71):
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
    metadata = json.loads(artifacts["spk286_microcode_validation.json"])
    for field in ("format_version", "encoding_version", "word_width"):
        if field in contract and metadata[field] != contract[field]:
            raise ValueError(f"phase {field} contract changed")
    if (list(words) != contract["words"] or symbols["entries"] != contract["entries"]
            or symbols["labels"] != contract["labels"]
            or program.address_width != contract["address_width"]):
        raise ValueError("phase ROM/symbol contract changed")
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
    print("MICROCODE AUDIT PASS: phase entries, emitted ROM, source coupling and round-trip")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/microcode-audit")
    parser.add_argument("--contract", type=Path,
                        default=ROOT / "tests/fixtures/microcode_phase7_adjust.json")
    args = parser.parse_args()
    audit(args.output, args.contract)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, UnicodeError) as error:
        print(f"MICROCODE AUDIT ERROR: {error}", file=sys.stderr)
        sys.exit(2)
