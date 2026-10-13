# SPDX-License-Identifier: MIT
"""Reject isolated spk286_native pin-adapter mutants with a pristine control.

Each mutant is compiled from a temporary copy of rtl/native/spk286_native.sv
and must be rejected by the intended assertion of the pin-level bench. The
audit then proves that no production source bytes were modified.
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
ADAPTER = ROOT / "rtl/native/spk286_native.sv"
BENCH = "spk286_native"

PROBES = (
    (
        "data-driven-in-ts",
        "                        {s1_n, s0_n} <= status_q;\n",
        "                        {s1_n, s0_n} <= status_q;\n                        d_oe <= write_q;\n",
        "data floats outside Tc",
    ),
    (
        "ready-ignored",
        "if (!ready_n) begin",
        "if (1'b1) begin",
        "Tc keeps status passive and the address held",
    ),
    (
        "no-address-setup",
        "                            halt_cycle_q <= 1'b0;\n",
        "                            halt_cycle_q <= 1'b0;\n"
        "                            {s1_n, s0_n} <= core_status[1:0];\n",
        "address and cycle type are valid one processor clock before Ts",
    ),
    (
        "hlda-with-float",
        "                            bus_oe <= 1'b0;\n",
        "                            bus_oe <= 1'b0;\n                            hlda <= 1'b1;\n",
        "the bus floats one processor clock before HLDA",
    ),
    (
        "drive-before-hlda-low",
        "                            hlda <= 1'b0;\n",
        "                            hlda <= 1'b0;\n                            bus_oe <= 1'b1;\n",
        "HLDA falls before the bus is driven again",
    ),
    (
        "lock-dropped",
        "lock_n <= !core_lock;",
        "lock_n <= 1'b1;",
        "LOCK# is active at Ts in the INTA chain",
    ),
    (
        "no-halt-cycle",
        "end else if ((halted || shutdown) &&",
        "end else if (1'b0 && (halted || shutdown) &&",
        "a halted core shows its halt cycle promptly",
    ),
    (
        "halt-a1-clear",
        "a <= halted ? 24'h000002 : 24'h000000;",
        "a <= 24'h000000;",
        "HLT issues a halt cycle with A1 set",
    ),
    (
        "bhe-forced",
        "bhe_n <= core_bhe_n;",
        "bhe_n <= 1'b0;",
        "the core holds its offered transaction until READY",
    ),
    (
        "swapped-read-lanes",
        "core_data_q <= d_in;",
        "core_data_q <= {d_in[7:0], d_in[15:8]};",
        "native bench timeout",
    ),
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

    output = args.build_dir.resolve() / "native-audit"
    output.mkdir(parents=True, exist_ok=True)
    sources = [*ordered_rtl_sources(ROOT), ADAPTER]
    originals = {path: path.read_bytes() for path in sources}
    source_hashes = {
        path.relative_to(ROOT).as_posix(): hashlib.sha256(data).hexdigest()
        for path, data in originals.items()
    }
    results = []

    def execute(name, mutation=None, reason=None):
        directory = output / name
        directory.mkdir(parents=True, exist_ok=True)
        inputs = list(sources)
        if mutation:
            old, new = mutation
            text = originals[ADAPTER].decode()
            require(text.count(old) == 1, f"{name}: mutation anchor is not unique")
            mutant = directory / ADAPTER.name
            mutant.write_text(text.replace(old, new), encoding="utf-8")
            inputs[inputs.index(ADAPTER)] = mutant

        binary = directory / "test.vvp"
        build = subprocess.run(
            [
                "iverilog",
                "-g2012",
                "-Irtl",
                "-Isim/unit",
                "-s",
                f"{BENCH}_tb",
                "-o",
                str(binary),
                *map(str, inputs),
                str(ROOT / "sim/unit" / f"{BENCH}_tb.sv"),
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
            ["vvp", str(binary)], cwd=ROOT, capture_output=True, text=True, timeout=600
        )
        run_output = run.stdout + run.stderr
        (directory / "run.log").write_text(run_output, encoding="utf-8")
        passed = "SPK286_NATIVE_PASS" in run_output
        if reason:
            require(not passed, f"{name}: mutant unexpectedly passed")
            require(reason in run_output, f"{name}: intended assertion did not reject mutant")
        else:
            require(passed, f"{name}: pristine control failed")
        results.append({"name": name, "status": run.returncode, "expected_assertion": reason})
        print(
            f"NATIVE_MUTATION {name}: {'rejected' if reason else 'passed'}",
            flush=True,
        )

    execute("pristine")
    for name, old, new, reason in PROBES:
        execute(name, (old, new), reason)

    require(
        all(path.read_bytes() == data for path, data in originals.items()),
        "production source bytes changed during the native mutation audit",
    )
    summary = {
        "validation": "PASS",
        "mutants": len(PROBES),
        "pristine": 1,
        "results": results,
        "source_sha256": source_hashes,
    }
    (output / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(
        f"NATIVE_AUDIT PASS: {len(PROBES)} rejected adapter mutants; "
        "1 pristine control; production bytes unchanged"
    )


if __name__ == "__main__":
    main()
