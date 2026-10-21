#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Print the utilization and clock results of one openXC7 build of the
ZXTRES+ demo, and fail when a clock misses its constraint.

  summary.py build/zxtres_plus_openxc7/<run>
"""
import json
import re
import sys
from pathlib import Path

CELLS = ("LUT1", "LUT2", "LUT3", "LUT4", "LUT5", "LUT6", "CARRY4", "MUXF7", "MUXF8",
         "FDRE", "FDSE", "FDCE", "FDPE", "RAMB18E1", "RAMB36E1", "DSP48E1", "BUFG", "PLLE2_ADV")


def main(run):
    run = Path(run).resolve()
    stat = (run / "yosys_stat.txt").read_text()
    cells = {name: int(n) for n, name in re.findall(r"^\s+(\d+)\s+(?:\S+\s+)?(\w+)$", stat, re.M)
             if name in CELLS}
    luts = sum(n for name, n in cells.items() if name.startswith("LUT"))
    ffs = sum(n for name, n in cells.items() if name.startswith("FD"))
    print(f"run: {run.name}")
    print(f"yosys cells: {luts} LUT, {ffs} FF, " +
          ", ".join(f"{cells[k]} {k}" for k in ("CARRY4", "MUXF7", "MUXF8", "RAMB18E1", "RAMB36E1",
                                                 "DSP48E1", "BUFG", "PLLE2_ADV") if cells.get(k)))
    report = json.loads((run / "report.json").read_text())
    for name, use in sorted(report.get("utilization", {}).items()):
        if use.get("used"):
            print(f"  {name:16s} {use['used']:7d} / {use['available']}")
    failed = False
    fmax = report.get("fmax", {})
    for clock, f in sorted(fmax.items()):
        ok = f["achieved"] >= f["constraint"]
        failed |= not ok
        print(f"clock {clock}: achieved {f['achieved']:.2f} MHz, "
              f"constraint {f['constraint']:.2f} MHz, {'PASS' if ok else 'FAIL'}")
    for net in ("clk_cpu", "clk_pix"):
        if not any(net in clock for clock in fmax):
            print(f"clock {net}: no timing result")
            failed = True
    for name in ("zxtres_demo.bit", "SPK286DEMO.ZX3"):
        path = run / name
        print(f"{name}: {path.stat().st_size} bytes" if path.exists() else f"{name}: missing")
        failed |= not path.exists()
    print("TIMING FAIL" if failed else "TIMING PASS")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__.strip().splitlines()[-1])
    sys.exit(main(sys.argv[1]))
