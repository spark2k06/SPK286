"""Reject isolated Phase 8 BIU/ESC RTL mutants with pristine controls.

The mutants are compiled from temporary copies outside the production RTL.
The audit deliberately uses the focused assertions for the two Phase 8
defects, then proves that the unchanged controls still pass and that no
production source bytes were modified.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


from tools.rtl_sources import ordered_rtl_sources

ROOT = Path(__file__).resolve().parents[1]

PROBES = (
    (
        "stale-hlda-release",
        "spk286_biu",
        "spk286_biu_hold_lock",
        "if (!hold_request || lock_request) hlda <= 1'b0;",
        "if (!hold_request) hlda <= 1'b0;",
        "LOCK releases stale HLDA",
    ),
    (
        "esc-decode-support",
        "spk286_decoder",
        "spk286_esc_instructions",
        "assign esc_instruction = opcode[7:3] == 5'b11011;",
        "assign esc_instruction = 1'b0;",
        "D8-DF opcode is not left at queue head",
    ),
)

PRISTINE = (
    "spk286_biu_hold_lock",
    "spk286_xchg_hold_lock",
    "spk286_esc_instructions",
)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--build-dir",
        type=Path,
        default=Path(os.environ.get("SPK286_BUILD_DIR", "build")),
    )
    args = parser.parse_args()

    subprocess.run(
        [sys.executable, "-m", "tools.microcode.compile_microcode", "--check"],
        cwd=ROOT,
        check=True,
    )

    output = args.build_dir.resolve() / "phase8-audit"
    output.mkdir(parents=True, exist_ok=True)
    sources = ordered_rtl_sources(ROOT)
    originals = {path: path.read_bytes() for path in sources}
    source_hashes = {
        path.relative_to(ROOT).as_posix(): hashlib.sha256(data).hexdigest()
        for path, data in originals.items()
    }
    results = []

    def execute(name, bench, mutation=None, reason=None):
        directory = output / name
        directory.mkdir(parents=True, exist_ok=True)
        inputs = list(sources)
        if mutation:
            module, old, new = mutation
            original = ROOT / "rtl" / f"{module}.sv"
            text = originals[original].decode()
            require(text.count(old) == 1, f"{name}: mutation anchor is not unique")
            mutant = directory / original.name
            mutant.write_text(text.replace(old, new), encoding="utf-8")
            inputs[inputs.index(original)] = mutant

        binary = directory / "test.vvp"
        build = subprocess.run(
            [
                "iverilog",
                "-g2012",
                "-Wall",
                "-Irtl",
                "-Isim/unit",
                "-s",
                f"{bench}_tb",
                "-o",
                str(binary),
                *map(str, inputs),
                str(ROOT / "sim/unit" / f"{bench}_tb.sv"),
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        (directory / "build.log").write_text(
            build.stdout + build.stderr, encoding="utf-8"
        )
        require(build.returncode == 0, f"{name}: compile failure is not mutation rejection")

        run = subprocess.run(
            [str(binary)], cwd=ROOT, capture_output=True, text=True, timeout=120
        )
        run_output = run.stdout + run.stderr
        (directory / "run.log").write_text(run_output, encoding="utf-8")
        if reason:
            require(run.returncode != 0, f"{name}: mutant unexpectedly passed")
            require(reason in run_output, f"{name}: intended assertion did not reject mutant")
        else:
            require(run.returncode == 0, f"{name}: pristine control failed")
            require("PASS:" in run_output, f"{name}: missing PASS marker")
        result = {
            "name": name,
            "bench": bench,
            "status": run.returncode,
            "expected_assertion": reason,
        }
        results.append(result)
        print(
            f"PHASE8_MUTATION {name}: "
            f"{'rejected' if reason else 'passed'} status={run.returncode}",
            flush=True,
        )

    for bench in PRISTINE:
        execute(f"pristine-{bench}", bench)
    for name, module, bench, old, new, reason in PROBES:
        execute(name, bench, (module, old, new), reason)

    require(
        all(path.read_bytes() == data for path, data in originals.items()),
        "production source bytes changed during Phase 8 mutation audit",
    )
    summary = {
        "validation": "PASS",
        "mutants": len(PROBES),
        "pristine": len(PRISTINE),
        "results": results,
        "source_sha256": source_hashes,
    }
    (output / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(
        f"PHASE8_AUDIT PASS: {len(PROBES)} rejected RTL mutants; "
        f"{len(PRISTINE)} pristine controls; production bytes unchanged"
    )


if __name__ == "__main__":
    main()
