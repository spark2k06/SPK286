"""Check public source reconstruction, reproducibility and both ROM round-trips."""

import argparse
import hashlib
import json
from pathlib import Path
import sys

from research.mcl86.fetch_references import ROOT, verified_references
from research.mcl86.mcl86_ucasm import assemble, read_mem, mem_bytes
from research.mcl86.mcl86_ucdis import disassemble


def differences(left, right):
    if len(left) != len(right):
        raise ValueError("cannot compare ROMs with different sizes")
    return [{"address": f"{i:03x}", "generated": f"{a:08x}", "reference": f"{b:08x}"}
            for i, (a, b) in enumerate(zip(left, right)) if a != b]


def check(directory: Path, output: Path):
    manifest = verified_references(directory)
    source = (directory / "Microcode_MCL86.txt").read_text(encoding="utf-8")
    assembled = assemble(source, "Microcode_MCL86.txt")
    generated = mem_bytes(assembled.words)
    if generated != mem_bytes(assemble(source).words):
        raise ValueError("assembly is not reproducible")
    original = read_mem((directory / "MCL86_Microcode_Xilinx_Version_4.coe").read_text())
    rewritten = read_mem((directory / "mcl86_ucode.mem").read_text())
    original_diff = differences(assembled.words, original)
    rewritten_diff = differences(assembled.words, rewritten)
    output.mkdir(parents=True, exist_ok=True)
    (output / "generated_mcl86_ucode.mem").write_bytes(generated)
    report = {"schema_version": 1, "assigned_words": len(assembled.addresses),
              "zero_filled_holes": 4096 - len(assembled.addresses),
              "control_transactions": assembled.controls, "delays_opaque": assembled.delays,
              "raw_sha256": {item["name"]: item["sha256"] for item in manifest["files"]},
              "generated_sha256": hashlib.sha256(generated).hexdigest(),
              "original_differences": original_diff, "rewrite_differences": rewritten_diff,
              "roundtrip": {}, "canonical_sha256": {}}
    for name, words in (("reference", original), ("rewrite", rewritten)):
        canonical = disassemble(words)
        reconstructed = mem_bytes(assemble(canonical).words)
        reference = mem_bytes(words)
        if reconstructed != reference:
            raise ValueError(f"{name} round-trip mismatch")
        (output / f"{name}_mcl86_ucode.mem").write_bytes(reference)
        (output / f"{name}_disassembled.txt").write_bytes(canonical.encode("ascii"))
        (output / f"{name}_reconstructed.mem").write_bytes(reconstructed)
        report["roundtrip"][name] = "PASS"
        report["canonical_sha256"][name] = hashlib.sha256(reference).hexdigest()
    (output / "comparison.json").write_bytes((json.dumps(report, sort_keys=True, indent=2)+"\n").encode())
    print(f"MCL86 COMPARE: original={len(original_diff)} differences; rewrite={len(rewritten_diff)} differences")
    print(f"MCL86 SHA256: generated={report['generated_sha256']}")
    if original_diff:
        raise ValueError(f"original reference mismatch: {original_diff[:8]}")
    print("MCL86 CHECK PASS: original 4096/4096 identical; both 4096-word round-trips identical")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=ROOT / ".cache/mcl86")
    parser.add_argument("--output", type=Path, default=ROOT / "build/mcl86")
    args = parser.parse_args()
    check(args.directory, args.output)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, UnicodeError) as error:
        print(f"MCL86 ERROR: {error}", file=sys.stderr)
        sys.exit(2)
