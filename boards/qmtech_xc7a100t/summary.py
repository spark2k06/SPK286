# SPDX-License-Identifier: MIT
"""Print the utilization and clock results of one openXC7 build directory.

Usage: python3 summary.py build/qmtech_xc7a100t/<run>
"""
import json
import re
import sys
from pathlib import Path

CELLS = ("LUT1", "LUT2", "LUT3", "LUT4", "LUT5", "LUT6", "CARRY4", "MUXF7", "MUXF8",
         "FDRE", "FDSE", "FDCE", "FDPE", "RAMB18E1", "RAMB36E1", "DSP48E1", "BUFG")


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
                                                 "DSP48E1", "BUFG") if cells.get(k)))
    report = json.loads((run / "report.json").read_text())
    for name, use in sorted(report.get("utilization", {}).items()):
        if use.get("used"):
            print(f"  {name:16s} {use['used']:7d} / {use['available']}")
    for clock, f in sorted(report.get("fmax", {}).items()):
        verdict = "PASS" if f["achieved"] >= f["constraint"] else "FAIL"
        print(f"clock {clock}: achieved {f['achieved']:.2f} MHz, "
              f"constraint {f['constraint']:.2f} MHz, {verdict}")
    bit = run / "spk286_qmtech.bit"
    print(f"bitstream: {bit} ({bit.stat().st_size} bytes)" if bit.exists() else "bitstream: missing")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__.strip().splitlines()[-1])
    main(sys.argv[1])
